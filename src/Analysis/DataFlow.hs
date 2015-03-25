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
{-# LANGUAGE GeneralizedNewtypeDeriving, StandaloneDeriving,
    TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses #-}
{-# OPTIONS_GHC -Wall -fno-warn-orphans #-}


module Analysis.DataFlow ( inOutVars, debugDataFlow ) where

import Control.Applicative
import Control.Monad.Error
import Control.Monad.Reader
import Control.Monad.State

import Data.Set (Set)
import qualified Data.Set as Set
import Text.PrettyPrint.HughesPJ

import Data.List ( nub )

import AstExpr
import AstComp

import Outputable 
import Opts

import AbsInt
import NameEnv

import qualified Analysis.RangeAnal as RA

type VarSet = Set (GName Ty)

{---------------------------------------------------------------
  Value domain is the set of variables an expression depends on
----------------------------------------------------------------}
instance ValDom VarSet where
  aVal _         = Set.empty
  aArr vs        = Set.unions vs
  aUnOp _ v      = v
  aBinOp _ v1 v2 = v1 `Set.union` v2
  aStruct _ vs   = Set.unions (map snd vs)

{---------------------------------------------------------------
  Monadic infrastructure 
----------------------------------------------------------------}

-- | Environment
type DFEnv = VarSet
initDFEnv :: DFEnv 
initDFEnv = Set.empty

-- | The state of the monad
data DFState = DFState { usedefs :: NameMap Ty VarSet
                       , usefree :: VarSet }
initDFState :: DFState 
initDFState = DFState neEmpty Set.empty

-- | Main analysis monad
newtype DFM a = DFM (ReaderT DFEnv (StateT DFState (ErrorT Doc IO)) a)
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState DFState
           , MonadReader DFEnv
           , MonadError Doc
           , MonadIO
           )
-- | Run the monad
runDFM :: DFM a -> IO (Either Doc (a,DFState))
runDFM (DFM act) 
  = runErrorT $ runStateT (runReaderT act initDFEnv) initDFState

-- | Union of two states
unionDFState :: DFState -> DFState -> DFState
unionDFState (DFState ud1 uf1) (DFState ud2 uf2) = DFState ud uf
  where ud = neUnionWith ud1 ud2 (\_ s t -> Set.union s t)
        uf = Set.union uf1 uf2

instance POrd DFState where
 pleq (DFState ud1 uf1) (DFState ud2 uf2) 
   = ud1 `pleq` ud2 && uf1 `pleq` uf2

-- | Run action in extended control flow
extendFlowVars :: VarSet -> DFM a -> DFM a
extendFlowVars vs = local upd_env
  where upd_env env = env `Set.union` vs

-- | Run action but in the end delete variable from result
extendVar :: EId -> DFM a -> DFM a
extendVar v action = do 
  a <- action
  modify remove_var
  return a
  where
    -- Completely eliminate this variable as it goes out of scope
    remove_var s
      = s { usedefs = del_var (usedefs s)
          , usefree = Set.delete v (usefree s) } 
    del_var nm = neFromList $ concatMap remove (neToList nm)
      where remove (x,s)
                  -- Delete the whole entry
                | x == v    = [] 
                  -- Delete the dependence
                | otherwise = [(x, Set.delete v s)]


-- | Variable v depends on the variables in vs but /also/ on the flow
-- variables that are used to reach this assignment. Hence we also
-- need to append them to the usedefs.
insertUseDefs :: EId -> VarSet -> DFM ()
insertUseDefs v vs = do 
  fvs <- asks id -- flow variables
  modify (ins_ud fvs)
  where 
    ins_ud fvs s = s { usedefs = neUpdate v (ne_upd fvs) (usedefs s) }
    ne_upd fvs Nothing    = Just (vs `Set.union` fvs)
    ne_upd fvs (Just vs0) = Just (vs `Set.union` vs0 `Set.union` fvs)

insertUseFree :: EId -> DFM ()
insertUseFree v = modify ins_free
  where ins_free s = s { usefree = Set.insert v (usefree s) }

lookupVarDef :: EId -> DFM VarSet
lookupVarDef v = do
  maybe_vs <- gets $ \s -> neLookup v (usedefs s)
  -- Original:
  return $ maybe (Set.singleton v) id maybe_vs
  -- Question: What about the flow variables? Should we 
  -- append them in the final set? Or not?

{---------------------------------------------------------------
  Command domain
----------------------------------------------------------------}

instance CmdDom DFM VarSet where
  aAssign d varset = go d varset
    where
      go (GDVar _ _ x) vs = insertUseFree x >> insertUseDefs x vs
      go (GDArr _ _ d' idx_vs _) vs = go d' (idx_vs `Set.union` vs)
      go (GDProj _ _ d' _) vs       = go d' vs
      go (GDNewArray {}) _vs        = return ()
      go (GDNewStruct {}) _vs       = return ()

  aDerefRead d = go d
    where
      go (GDVar _ _ x)           = insertUseFree x >> lookupVarDef x
      go (GDArr _ _ d' vs _)     = go d' >>= \r -> return $ Set.union r vs
      go (GDProj _ _ d' _)       = go d'
      go (GDNewArray _ _ _ vs)   = return $ Set.unions vs
      go (GDNewStruct _ _ _ tfs) = return $ Set.unions (map snd tfs)
  

  
  withImmABind x vs m = extendVar x $
    do aAssign (GDVar Nothing () x) vs
       res_vs <- m
       return $ Set.delete x res_vs
      
  withMutABind x m = extendVar x $
    do res_vs <- m
       return $ Set.delete x res_vs

  aCall  _ _ = fail "Calls not supported in range analysis"
  aError     = fail "Error not supported in range analysis"
  aPrint _ _ = return ()


{---------------------------------------------------------------
  Abstract intepreter domain
----------------------------------------------------------------}

instance AbsInt DFM VarSet where
  aSkip = return Set.empty

  aJoin m1 m2 = do
   (vs1,post1) <- inCurrSt m1
   (vs2,post2) <- inCurrSt m2
   put $ unionDFState post1 post2
   return (vs1 `Set.union` vs2)

  aWithFact vs = extendFlowVars vs
  aWiden _ = aJoin



{---------------------------------------------------------------
  Running the analysis
----------------------------------------------------------------}
deriving instance MonadState DFState (AbsT DFM) 
deriving instance Monad   (AbsT DFM)
deriving instance MonadIO (AbsT DFM)


data VarUsePkg 
  = VarUsePkg { vs_invars   :: [EId]
              , vs_outvars  :: [EId]
              , vs_allvars  :: [EId] 
              }

inOutVars :: MonadIO m => Exp -> m (Either Doc VarUsePkg)
inOutVars e = do
  res <- liftIO $ runDFM (unAbsT action)
  case res of 
    Left err -> return $ Left err
    Right (varset, DFState udmap ufset) -> do
      let modified, impUsed, pureUsed, allVars :: [GName Ty]
          modified = neKeys udmap
          impUsed  = Set.toList $ Set.unions (map snd (neToList udmap))
          pureUsed = Set.toList varset
          allVars  = Set.toList ufset
      return $ Right $ VarUsePkg { vs_invars  = nub $ impUsed ++ pureUsed
                                 , vs_outvars = modified
                                 , vs_allvars = allVars }
  where action :: AbsT DFM VarSet
        action = absEval e

unlessErr :: MonadIO m => m (Either Doc a) -> (a -> m ()) -> m ()
unlessErr m f = do 
  res <- m
  case res of 
    Left doc -> liftIO $ print doc
    Right a  -> f a

debugDataFlow :: DynFlags -> Comp -> IO ()
debugDataFlow dfs comp = do
  _ <- mapCompM return return return return on_exp return comp
  return ()
  where on_exp = mapExpM return return on_exp'
        on_exp' e0 = do
          print $ vcat [ text "**** Debugging new dataflow analysis ****"
                       , text "Analyzing expression at location: " <+> text (show (expLoc e0))
                       ]
          verbose dfs $ nest 4 (ppr e0)

          unlessErr (inOutVars e0)    $ \(VarUsePkg invars outvars _allvars) ->
            unlessErr (RA.varRanges e0) $ \(rm,rng) -> do
              print $ vcat [ text "Input variables :" <+> sep (map ppr invars)
                           , text "Output variables:" <+> sep (map ppr outvars)
                           ]
              print $ vcat [ text "Ranges = "
                           , nest 2 (RA.pprRanges rm)
                           , text "Result range = "
                           , nest 2 (ppr rng) ]
          return e0
