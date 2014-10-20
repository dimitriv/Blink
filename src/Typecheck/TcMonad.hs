{-
   Copyright (c) Microsoft Corporation
   All rights reserved.

   Licensed under the Apache License, Version 2.0 (the ""License""); you
   may not use this file except in compliance with the License. You may
   obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
   CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
   LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
   A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

   See the Apache Version 2.0 License for specific language governing
   permissions and limitations under the License.
-}
-- TODOs:
--
-- * We should remove TcMState from the public API completely, and keep it
--   entirely internal
-- * The section "working with types" feels like it belongs in a different
--   module.
-- * In firstToSucceed, when both computations fail the error that is reported
--   is the error from the second computation. This might be misleading, as
--   it might mean we might tell the user "cannot unify Foo with Baz" while
--   we should really say "cannot unify Foo with Bar or Baz"
{-# OPTIONS_GHC -Wall -fno-warn-orphans #-}
{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances #-}
module TcMonad (
    -- * TcM monad
    TcM -- opaque
  , TcMState -- opaque.
  , runTcM
  , firstToSucceed
  , emptyTcMState
    -- * Environments
    -- ** Type definition environment
  , TyDefEnv
  , mkTyDefEnv
  , lookupTDefEnv
  , extendTDefEnv
    -- ** Expression variable binding environment
  , Env
  , mkEnv
  , lookupEnv
  , extendEnv
    -- ** Computation variable binding environment
  , CEnv
  , mkCEnv
  , lookupCEnv
  , extendCEnv
    -- ** Type variable environment (substitutions)
  , TyEnv
  , mkTyEnv
  , getTyEnv
  , updTyEnv
    -- ** Computation type variable environment (substitutions)
  , CTyEnv
  , mkCTyEnv
  , getCTyEnv
  , updCTyEnv
    -- ** Array length variable environment (substitutions)
  , ALenEnv
  , getALenEnv
  , updALenEnv
    -- ** Bit width variable environment (substitutions)
  , BWEnv
  , getBWEnv
  , updBWEnv
    -- * Error reporting
  , getErrCtx
  , pushErrCtx
  , raiseErr
  , raiseErrNoVarCtx
  , checkWith
    -- * Name generation
  , genSym
    -- * Creating types with type variables
  , freshTy
  , freshCTy
  , freshNumExpr
  , freshBitWidth
    -- * Interaction with the renamer
  , liftRenM
    -- * Working with types
    -- ** Zonking
  , Zonk(..)
    -- ** Collecting type variables
  , tyVarsOfTy
  , tyVarsOfCTy
  ) where

import Prelude hiding (exp)
import Control.Applicative hiding (empty)
import Control.Arrow ((***))
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Error
import Text.Parsec.Pos
import Text.PrettyPrint.HughesPJ
import qualified Data.Map as M
import qualified Data.Set as S

import AstComp
import AstExpr
import Outputable
import PpExpr (ppName)
import TcErrors
import Rename (RenM, runRenM)
import qualified GenSym as GS

{-------------------------------------------------------------------------------
  The type checker monad
-------------------------------------------------------------------------------}

data TcMEnv = TcMEnv {
    tcm_tydefenv :: TyDefEnv
  , tcm_env      :: Env
  , tcm_cenv     :: CEnv
  , tcm_sym      :: GS.Sym
  , tcm_errctx   :: ErrCtx
  }

data TcMState = TcMState {
    tcm_tyenv    :: TyEnv
  , tcm_ctyenv   :: CTyEnv
  , tcm_alenenv  :: ALenEnv
  , tcm_bwenv    :: BWEnv
  }

newtype TcM a = TcM {
    unTcM :: ReaderT TcMEnv (StateT TcMState (ErrorT Doc IO)) a
  }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadIO
           , MonadError Doc
           , MonadState TcMState
           , MonadReader TcMEnv
           )

instance Error Doc where
  noMsg  = empty
  strMsg = text

runTcM :: TcM a
       -> TyDefEnv
       -> Env
       -> CEnv
       -> GS.Sym
       -> ErrCtx
       -> TcMState
       -> IO (Either Doc (a, TcMState))
runTcM act tenv env cenv sym ctx st =
    runErrorT (runStateT (runReaderT (unTcM act) readerEnv) st)
  where
    readerEnv = TcMEnv {
        tcm_tydefenv = tenv
      , tcm_env      = env
      , tcm_cenv     = cenv
      , tcm_sym      = sym
      , tcm_errctx   = ctx
      }

firstToSucceed :: TcM a -> TcM a -> TcM a
firstToSucceed m1 m2 = get >>= \st -> catchError m1 (\_ -> put st >> m2)

emptyTcMState :: TcMState
emptyTcMState = TcMState {
      tcm_tyenv   = mkTyEnv   []
    , tcm_ctyenv  = mkCTyEnv  []
    , tcm_alenenv = mkALenEnv []
    , tcm_bwenv   = mkBWEnv   []
    }

{-------------------------------------------------------------------------------
  Type definition environment
-------------------------------------------------------------------------------}

-- Maps names to structure definitions
type TyDefEnv = M.Map String StructDef

mkTyDefEnv :: [(TyName,StructDef)] -> TyDefEnv
mkTyDefEnv = M.fromList

getTDefEnv :: TcM TyDefEnv
getTDefEnv = asks tcm_tydefenv

lookupTDefEnv :: String -> Maybe SourcePos -> TcM StructDef
lookupTDefEnv s pos = getTDefEnv >>= lookupTcM s pos msg
  where msg = text "Unbound type definition:" <+> text s

extendTDefEnv :: [(String,StructDef)] -> TcM a -> TcM a
extendTDefEnv binds = local $ \env -> env {
      tcm_tydefenv = updBinds binds (tcm_tydefenv env)
    }

{-------------------------------------------------------------------------------
  Expression variable binding environment
-------------------------------------------------------------------------------}

--- maps program variables to types
type Env = M.Map String Ty

mkEnv :: [(String,Ty)] -> Env
mkEnv = M.fromList

getEnv :: TcM Env
getEnv = asks tcm_env

lookupEnv :: String -> Maybe SourcePos -> TcM Ty
lookupEnv s pos = getEnv >>= lookupTcM s pos msg
  where msg = text "Unbound variable:" <+> text s

extendEnv :: [GName Ty] -> TcM a -> TcM a
extendEnv binds = local $ \env -> env {
      tcm_env = updBinds binds' (tcm_env env)
    }
  where
    binds' = map (\nm -> (name nm, nameTyp nm)) binds

{-------------------------------------------------------------------------------
  Computation variable binding environment
-------------------------------------------------------------------------------}

-- maps computation variables to computation types
type CEnv = M.Map String CTy

mkCEnv :: [(String,CTy)] -> CEnv
mkCEnv = M.fromList

getCEnv :: TcM CEnv
getCEnv = asks tcm_cenv

lookupCEnv :: String -> Maybe SourcePos -> TcM CTy
lookupCEnv s pos = getCEnv >>= lookupTcM s pos msg
  where msg = text "Unbound computation variable:" <+> text s

extendCEnv :: [GName CTy] -> TcM a -> TcM a
extendCEnv binds = local $ \env -> env {
      tcm_cenv = updBinds binds' (tcm_cenv env)
    }
  where
    binds' = map (\nm -> (name nm, nameTyp nm)) binds

{-------------------------------------------------------------------------------
  Type variable environment (substitutions)
-------------------------------------------------------------------------------}

-- maps type variables to types
type TyEnv = M.Map String Ty

mkTyEnv :: [(String,Ty)] -> TyEnv
mkTyEnv = M.fromList

getTyEnv :: TcM TyEnv
getTyEnv = gets tcm_tyenv

updTyEnv :: [(String,Ty)] -> TcM ()
updTyEnv binds = modify $ \st -> st {
      tcm_tyenv = updBinds binds (tcm_tyenv st)
    }

{-------------------------------------------------------------------------------
  Computation variable environment (substitutions)
-------------------------------------------------------------------------------}

-- maps type variables to computation types
type CTyEnv = M.Map String CTy

mkCTyEnv :: [(String,CTy)] -> CTyEnv
mkCTyEnv = M.fromList

getCTyEnv :: TcM CTyEnv
getCTyEnv = gets tcm_ctyenv

updCTyEnv :: [(String,CTy)] -> TcM ()
updCTyEnv binds = modify $ \st -> st {
      tcm_ctyenv = updBinds binds (tcm_ctyenv st)
    }


{-------------------------------------------------------------------------------
  Array length variable environment (substitutions)
-------------------------------------------------------------------------------}

-- maps array lengths to ints
type ALenEnv = M.Map LenVar NumExpr

mkALenEnv :: [(LenVar, NumExpr)] -> ALenEnv
mkALenEnv = M.fromList

getALenEnv :: TcM ALenEnv
getALenEnv = gets tcm_alenenv

updALenEnv :: [(LenVar, NumExpr)] -> TcM ()
updALenEnv binds = modify $ \st -> st {
      tcm_alenenv = updBinds binds (tcm_alenenv st)
    }

{-------------------------------------------------------------------------------
  Bit width variable environment (substitutions)
-------------------------------------------------------------------------------}

-- maps bitwidth precisions to BitWidths
type BWEnv = M.Map BWVar BitWidth

mkBWEnv :: [(BWVar,BitWidth)] -> BWEnv
mkBWEnv = M.fromList

getBWEnv :: TcM BWEnv
getBWEnv = gets tcm_bwenv

updBWEnv :: [(BWVar,BitWidth)] -> TcM ()
updBWEnv binds = modify $ \st -> st {
      tcm_bwenv = updBinds binds (tcm_bwenv st)
    }

{-------------------------------------------------------------------------------
  Error reporting
-------------------------------------------------------------------------------}

getErrCtx :: TcM ErrCtx
getErrCtx = asks tcm_errctx

pushErrCtx :: ErrCtx -> TcM a -> TcM a
pushErrCtx ctxt = local $ \env -> env { tcm_errctx = ctxt }

raiseErr :: Bool -> Maybe SourcePos -> Doc -> TcM a
raiseErr print_vartypes p msg = do
    ctx <- getErrCtx
    vartypes_msg <- ppVarTypes print_vartypes ctx
    let doc = ppTyErr $ TyErr ctx p msg vartypes_msg
    failTcM doc
  where
    ppVarTypes :: Bool -> ErrCtx -> TcM Doc
    ppVarTypes False _
      = return empty
    ppVarTypes True (CompErrCtx comp)
      = pp_vars $ (S.elems *** S.elems) (compFVs comp)
    ppVarTypes True (ExprErrCtx exp)
      = pp_vars $ ([], S.elems (exprFVs exp))
    ppVarTypes _ _
      = return empty

    -- Since error contexts are _source_ level terms, they carry source types
    --
    pp_cvar :: GName (Maybe (GCTy SrcTy)) -> TcM Doc
    pp_cvar v = do
      cty  <- lookupCEnv (name v) p
      zcty <- zonk cty
      return $ ppName v <+> colon <+> ppr zcty

    pp_var :: GName (Maybe SrcTy) -> TcM Doc
    pp_var v = do
      ty  <- lookupEnv (name v) p
      zty <- zonk ty
      return $ ppName v <+> colon <+> ppr zty

    pp_vars :: ([GName (Maybe (GCTy SrcTy))], [GName (Maybe SrcTy)]) -> TcM Doc
    pp_vars (cvars, vars)
     = do { cdocs <- mapM pp_cvar cvars
          ; docs  <- mapM pp_var  vars
          ; return $ vcat [ text "Variable bindings:"
                          , nest 2 $ vcat (cdocs ++ docs)
                          ] }

raiseErrNoVarCtx :: Maybe SourcePos -> Doc -> TcM a
raiseErrNoVarCtx = raiseErr False

failTcM :: Doc -> TcM a
failTcM = throwError

checkWith :: Maybe SourcePos -> Bool -> Doc -> TcM ()
checkWith _   True  _   = return ()
checkWith pos False err = raiseErr False pos err

{-------------------------------------------------------------------------------
  Name generation

  Most of these are for internal use in the fresh* functions.
-------------------------------------------------------------------------------}

getSym :: TcM GS.Sym
getSym = asks tcm_sym

genSym :: String -> TcM String
genSym prefix = do
  sym <- getSym
  str <- liftIO $ GS.genSymStr sym
  return (prefix ++ str)

newTyVar :: String -> TcM TyVar
newTyVar = genSym

newCTyVar :: String -> TcM CTyVar
newCTyVar = genSym

newBWVar :: String -> TcM BWVar
newBWVar = genSym

newALenVar :: String -> TcM LenVar
newALenVar = genSym

{-------------------------------------------------------------------------------
  Creating types with type variables
-------------------------------------------------------------------------------}

freshTy :: String -> TcM Ty
freshTy prefix = TVar <$> newTyVar prefix

freshCTy :: String -> TcM CTy
freshCTy prefix = CTVar <$> newCTyVar prefix

freshBitWidth :: String -> TcM BitWidth
freshBitWidth prefix = BWUnknown <$> newBWVar prefix

freshNumExpr :: String -> TcM NumExpr
freshNumExpr prefix = NVar <$> newALenVar prefix

{-------------------------------------------------------------------------------
  Zonking

  NOTE: Zonking of expressions and computations _previously_ also defaulted the
  type of `EError` to `TUnit` when it was still a free variable. However, we
  don't do this anymore here but we do this in `defaultExpr` instead. This is
  important, because we should have the invariant that we can zonk at any point
  during type checking without changing the result.
-------------------------------------------------------------------------------}

class Outputable a => Zonk a where
  zonk :: a -> TcM a

instance Zonk Ty where
  zonk = mapTyM do_zonk
    where
      do_zonk (TVar x)
        = do { tenv <- getTyEnv
             ; case M.lookup x tenv of
                  Nothing  -> return (TVar x)
                  Just xty -> zonk xty
             }
      do_zonk (TInt bw)
        = do { bw' <- zonk bw
             ; return (TInt bw')
             }
      do_zonk (TArray n ty)
        = do { n' <- zonk n
               -- NB: No need to recurse, mapTyM will do it for us
             ; return (TArray n' ty)
             }
      do_zonk ty = return ty

instance Zonk BitWidth where
  zonk (BWUnknown x)
    = do { benv <- getBWEnv
         ; case M.lookup x benv of
             Just bw -> zonk bw
             Nothing -> return (BWUnknown x)
         }
  zonk other_bw = return other_bw

instance Zonk NumExpr where
  zonk (NVar n)
    = do { env <- getALenEnv
         ; case M.lookup n env of
             Nothing -> return $ NVar n
             Just ne -> zonk ne
         }
  zonk (Literal i)
    = return (Literal i)

instance (Zonk a, Zonk b) => Zonk (CallArg a b) where
  zonk (CAExp  e) = CAExp  <$> zonk e
  zonk (CAComp c) = CAComp <$> zonk c

instance Zonk (GCTy Ty) where
  zonk (CTVar x)
    = do { tenv <- getCTyEnv
         ; case M.lookup x tenv of
             Nothing  -> return (CTVar x)
             Just xty -> zonk xty
         }

  zonk (CTComp u a b)
    = do { u' <- zonk u
         ; a' <- zonk a
         ; b' <- zonk b
         ; return (CTComp u' a' b')
         }

  zonk (CTTrans a b)
    = do { a' <- zonk a
         ; b' <- zonk b
         ; return (CTTrans a' b')
         }

  zonk (CTArrow args res)
    = do { args' <- mapM zonk args
         ; res'  <- zonk res
         ; return (CTArrow args' res')
         }

instance Zonk t => Zonk (GExp t a) where
  zonk = mapExpM zonk return return

instance (Zonk tc, Zonk t) => Zonk (GComp tc t a b) where
  zonk = mapCompM zonk zonk return return zonk return

{-------------------------------------------------------------------------------
  Collecting type variables
-------------------------------------------------------------------------------}

tyVarsOfTy :: Ty -> S.Set TyVar
tyVarsOfTy t = snd $ runState (mapTyM collect_var t) S.empty
 where collect_var :: Ty -> State (S.Set TyVar) Ty
       collect_var (TVar x)
        = do { modify (S.union (S.singleton x))
             ; return (TVar x) }
       collect_var ty
        = return ty

tyVarsOfCTy :: CTy -> (S.Set TyVar, S.Set CTyVar)
tyVarsOfCTy (CTVar x) =
    (S.empty, S.singleton x)
tyVarsOfCTy (CTTrans a b) =
    (tyVarsOfTy a `S.union` tyVarsOfTy b, S.empty)
tyVarsOfCTy (CTComp v a b) =
    (S.unions [tyVarsOfTy a, tyVarsOfTy b, tyVarsOfTy v], S.empty)
tyVarsOfCTy (CTArrow tys ct0) =
    tvs_args tys `unionPair` tyVarsOfCTy ct0

tvs_arg :: CallArg Ty CTy -> (S.Set TyVar, S.Set CTyVar)
tvs_arg (CAExp  ty)  = (tyVarsOfTy ty, S.empty)
tvs_arg (CAComp cty) = tyVarsOfCTy cty

tvs_args :: [CallArg Ty CTy] -> (S.Set TyVar, S.Set CTyVar)
tvs_args = unionsPair . map tvs_arg

{-------------------------------------------------------------------------------
  Interaction with the renamer
-------------------------------------------------------------------------------}

-- | Lift the renamer monad to the TcM
liftRenM :: RenM a -> TcM a
liftRenM ren = do
  sym <- getSym
  liftIO $ runRenM sym ren

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- Lookups
lookupTcM :: Ord a => a -> Maybe SourcePos -> Doc -> M.Map a b -> TcM b
lookupTcM s pos err env
  | Just res <- M.lookup s env
  = return res
  | otherwise = raiseErr False pos err

updBinds :: Ord x => [(x,a)] -> M.Map x a -> M.Map x a
updBinds newbinds binds = M.union (M.fromList newbinds) binds

unionPair :: (Ord a, Ord b) => (S.Set a, S.Set b) -> (S.Set a, S.Set b) -> (S.Set a, S.Set b)
unionPair (as, bs) (as', bs') = (as `S.union` as', bs `S.union` bs')

unionsPair :: (Ord a, Ord b) => [(S.Set a, S.Set b)] -> (S.Set a, S.Set b)
unionsPair ss = let (ass, bss) = unzip ss in (S.unions ass, S.unions bss)
