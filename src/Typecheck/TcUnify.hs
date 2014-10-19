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
{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE GADTs, MultiParamTypeClasses #-}
module TcUnify (
    -- * Unification
    unify
  , unifyMany
  , unifyAll
  , unify_cty0
  , unifyALen
    -- * Check that types have certain shapes
  , Hint(..)
  , unifyTInt
  , unifyTInt'
  , unifyTArray
  , unifyComp
  , unifyTrans
  , unifyCompOrTrans
  , unifyBase
    -- * Defaulting
  , defaultTy
  , defaultComp
    -- * Instantiation
  , instantiateCall
  ) where

import Control.Monad hiding (forM_)
import Text.Parsec.Pos (SourcePos)
import Text.PrettyPrint.HughesPJ
import qualified Data.Map as M
import qualified Data.Set as S

import AstComp
import AstExpr
import AstUnlabelled
import Outputable
import PpComp ()
import PpExpr ()
import TcMonad

{-------------------------------------------------------------------------------
  Unification
-------------------------------------------------------------------------------}

unifyErrGeneric :: Doc -> Maybe SourcePos -> Ty -> Ty -> TcM ()
unifyErrGeneric msg pos ty1 ty2
  = do { zty1 <- zonkTy ty1
       ; zty2 <- zonkTy ty2
       ; raiseErr True pos $
         vcat [ msg
              , text "Cannot unify type" <+>
                ppr zty1 <+> text "with" <+> ppr zty2
              ] }

unifyErr :: Maybe SourcePos -> Ty -> Ty -> TcM ()
unifyErr = unifyErrGeneric empty

occCheckErr :: Maybe SourcePos -> Ty -> Ty -> TcM ()
occCheckErr p = unifyErrGeneric (text "Occurs check error.") p


unify_cty0 :: Maybe SourcePos -> CTy0 -> CTy0 -> TcM ()
unify_cty0 p (TTrans a b) (TTrans a' b')
  = do { unify p a a'
       ; unify p b b'
       }
unify_cty0 p (TComp v a b) (TComp v' a' b')
  = do { unify p v v'
       ; unify p a a'
       ; unify p b b'
       }
unify_cty0 p cty0 cty1
  = do { zty1 <- zonkCTy (CTBase cty0)
       ; zty2 <- zonkCTy (CTBase cty1)
       ; raiseErr True p $
         vcat [ text "Cannot unify type" <+>
                ppr zty1 <+> text "with" <+> ppr zty2
              ]
       }


unify :: Maybe SourcePos -> Ty -> Ty -> TcM ()
unify p tya tyb = go tya tyb
  where
    go (TVar x) ty
       = do { tenv <- getTyEnv
            ; case M.lookup x tenv of
                Just xty -> go xty ty
                Nothing  -> goTyVar x ty }
    go ty (TVar x) = go (TVar x) ty
    go TUnit TUnit = return ()
    go TBit TBit   = return ()
    go (TInt bw1) (TInt bw2) = unifyBitWidth p bw1 bw2
    go TDouble TDouble = return ()
    go (TBuff (IntBuf ta))(TBuff (IntBuf tb))    = go ta tb
    go (TBuff (ExtBuf bta)) (TBuff (ExtBuf btb)) = go bta btb
    go (TInterval n)(TInterval n')
      | n == n'   = return ()
      | otherwise = unifyErr p tya tyb
    -- TODO: Should we check something about the fields?
    -- (TStructs are completed internally, so if the names are equal but the
    -- fields are not then this is a compiler bug, not a type error)
    go (TStruct n1 _) (TStruct n2 _)
      | n1 == n2  = return ()
      | otherwise = unifyErr p tya tyb
    go TBool TBool = return ()
    go (TArray n ty1) (TArray m ty2)
      = unifyALen p n m >> go ty1 ty2
    go (TArrow tys1 ty2) (TArrow tys1' ty2')
      | length tys1 /= length tys1'
      = unifyErr p tya tyb
      | otherwise
      = goMany tys1 tys1' >> go ty2 ty2'

    go _ _ = unifyErr p tya tyb

    goMany ts1 ts2
      = mapM (\(t1,t2) -> go t1 t2) (zip ts1 ts2)

    goTyVar x (TVar y)
      | x == y = return ()
      | otherwise
      = do { tenv <- getTyEnv
           ; case M.lookup y tenv of
               Just yty -> goTyVar x yty
               Nothing  -> updTyEnv [(x,(TVar y))]
           }

    goTyVar x ty
      | x `S.member` tyVarsOfTy ty
      = occCheckErr p tya tyb
      | otherwise
      = updTyEnv [(x,ty)]


unifyAll :: Maybe SourcePos -> [Ty] -> TcM ()
unifyAll p = go
  where
    go []         = return ()
    go [_]        = return ()
    go (t1:t2:ts) = unify p t1 t2 >> go (t2:ts)

unifyMany :: Maybe SourcePos -> [Ty] -> [Ty] -> TcM ()
unifyMany p t1s t2s = mapM_ (\(t1,t2) -> unify p t1 t2) (zip t1s t2s)



unifyBitWidth :: Maybe SourcePos -> BitWidth -> BitWidth -> TcM ()
unifyBitWidth p = go
  where
    go (BWUnknown bvar) bw
      = do { benv <- getBWEnv
           ; case M.lookup bvar benv of
               Just bw1 -> go bw1 bw
               Nothing  -> goBWVar bvar bw }
    go bw (BWUnknown bvar)
      = go (BWUnknown bvar) bw

    go b1 b2
      | b1 == b2
      = return ()
      | otherwise
      = raiseErr True p (text "Int width mismatch")

    goBWVar bvar1 (BWUnknown bvar2)
      | bvar1 == bvar2
      = return ()
      | otherwise
      = do { benv <- getBWEnv
           ; case M.lookup bvar2 benv of
               Just bw -> goBWVar bvar1 bw
               Nothing -> updBWEnv [(bvar1,BWUnknown bvar2)] }

    goBWVar bvar1 bw2
      = updBWEnv [(bvar1,bw2)]


unifyALen :: Maybe SourcePos -> NumExpr -> NumExpr -> TcM ()
unifyALen p = go
  where
    go (NVar n) nm2
      = do { alenv <- getALenEnv
           ; case M.lookup n alenv of
               Just nm1 -> go nm1 nm2
               Nothing  -> goNVar n nm2
           }

    go nm1 (NVar n)
      = go (NVar n) nm1

    go (Literal i) (Literal j)
      | i == j
      = return ()
      | otherwise
      = raiseErr True p (text "Array length mismatch")

    -- Invariant: num expression is never an array
    goNVar nvar1 (Literal i)
      = updALenEnv [(nvar1,Literal i)]

    goNVar nvar1 (NVar nvar2)
      | nvar1 == nvar2 = return ()
      | otherwise
      = do { alenv <- getALenEnv
           ; case M.lookup nvar2 alenv of
               Just nm2 ->
                 -- NB: not goNVar
                 go (NVar nvar1) nm2
               Nothing ->
                 updALenEnv [(nvar1, NVar nvar2)]
           }

{-------------------------------------------------------------------------------
  Defaulting
-------------------------------------------------------------------------------}

-- | @defaultTy p ty def@ defaults @ty@ to @tdef@ if @ty@ is a type variable
-- (after zonking).
--
-- Returns @ty@ if @ty@ is not a type variable and @def@ otherwise.
--
-- Be careful calling this: only call this if you are sure that later
-- unification equations will not instantiate this type variable.
defaultTy :: Maybe SourcePos -> Ty -> Ty -> TcM Ty
defaultTy p ty def = do
  ty' <- zonkTy ty
  case ty' of
    TVar _ -> do unify p ty' def ; return def
    _      -> return ty'

-- | Zonk all type variables and default the type of `EError` to `TUnit` when
-- it's still a type variable.
defaultExpr :: Exp -> TcM Exp
defaultExpr = mapExpM zonkTy return zonk_exp
  where
    zonk_exp :: Exp -> TcM Exp
    zonk_exp e
      | EError ty str <- unExp e
      = do { ty' <- defaultTy (expLoc e) ty TUnit
           ; return $ eError (expLoc e) ty' str
           }
      | otherwise
      = return e

defaultComp :: Comp -> TcM Comp
defaultComp = mapCompM zonkCTy zonkTy return return defaultExpr return

{-------------------------------------------------------------------------------
  Instantiation (of polymorphic functions)
-------------------------------------------------------------------------------}

-- | Instantiates the array length variables to fresh variables, to be used in
-- subsequent unifications.
--
-- Notice that these are only the ones bound by the parameters of the function
instantiateCall :: Ty -> TcM Ty
instantiateCall = go
  where
    go :: Ty -> TcM Ty
    go t@(TArrow tas tb) = do { let lvars = gatherPolyVars (tb:tas)
                              ; s <- mapM freshen lvars
                              ; mapTyM (subst_len s) t
                              }
    go other             = return other

    freshen :: LenVar -> TcM (LenVar, NumExpr)
    freshen lv
      = do { ne <- freshNumExpr lv
           ; return (lv, ne)
           }

    subst_len :: [(LenVar, NumExpr)] -> Ty -> TcM Ty
    subst_len s (TArray (NVar n) t) =
         case lookup n s of
           Nothing  -> return (TArray (NVar n) t)
           Just ne' -> return (TArray ne' t)
    subst_len _ ty = return ty

{-------------------------------------------------------------------------------
  Check that types have certain shapes

  We try to avoid generating unification variables where possible.
-------------------------------------------------------------------------------}

-- Type checking hints (isomorphic with Maybe)
data Hint a = Check a | Infer

check :: Hint a -> (a -> TcM ()) -> TcM ()
check Infer     _   = return ()
check (Check c) act = act c

unifyTInt :: Maybe SourcePos -> Hint BitWidth -> Ty -> TcM BitWidth
unifyTInt loc annBW = zonkTy >=> go
  where
    go (TInt bw) = do
      check annBW $ unifyBitWidth loc bw
      return bw
    go ty = do
      bw <- case annBW of Infer    -> freshBitWidth "bw"
                          Check bw -> return bw
      unify loc ty (TInt bw)
      return bw

-- Version of unifyTInt where we don't care about the bitwidths
unifyTInt' :: Maybe SourcePos -> Ty -> TcM ()
unifyTInt' loc ty = void $ unifyTInt loc Infer ty

unifyTArray :: Maybe SourcePos -> Hint NumExpr -> Hint Ty -> Ty -> TcM (NumExpr, Ty)
unifyTArray loc annN annA = zonkTy >=> go
  where
    go (TArray n a) = do
      check annN $ unifyALen loc n
      check annA $ unify loc a
      return (n, a)
    go ty = do
      n <- case annN of Infer   -> freshNumExpr "n"
                        Check n -> return n
      a <- case annA of Infer   -> freshTy "a"
                        Check a -> return a
      unify loc ty (TArray n a)
      return (n, a)

unifyComp :: Maybe SourcePos
          -> Hint Ty -> Hint Ty -> Hint Ty
          -> CTy0 -> TcM (Ty, Ty, Ty)
unifyComp loc annU annA annB = zonkCTy0 >=> go
  where
    go (TComp u a b) = do
      check annU $ unify loc u
      check annA $ unify loc a
      check annB $ unify loc b
      return (u, a, b)
    go (TTrans _ _) =
      raiseErr False loc $
        text "Expected computer but found transformer"

unifyTrans :: Maybe SourcePos
           -> Hint Ty -> Hint Ty
           -> CTy0 -> TcM (Ty, Ty)
unifyTrans loc annA annB = zonkCTy0 >=> go
  where
    go (TComp _ _ _) = do
      raiseErr False loc $
        text "Expected transformer but found computer"
    go (TTrans a b) = do
      check annA $ unify loc a
      check annB $ unify loc b
      return (a, b)

unifyCompOrTrans :: Maybe SourcePos
                 -> Hint Ty -> Hint Ty
                 -> CTy0 -> TcM (Maybe Ty, Ty, Ty)
unifyCompOrTrans loc annA annB = zonkCTy0 >=> go
  where
    go (TComp u a b) = do
      check annA $ unify loc a
      check annB $ unify loc b
      return (Just u, a, b)
    go (TTrans a b) = do
      check annA $ unify loc a
      check annB $ unify loc b
      return (Nothing, a, b)

unifyBase :: Maybe SourcePos -> CTy -> TcM CTy0
unifyBase loc = zonkCTy >=> go
  where
    go (CTBase cty0) = return cty0
    go _ = raiseErr False loc $ text "Function not fully applied"
