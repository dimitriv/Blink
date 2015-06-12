module AutomataModel where

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (maybeToList)

import Data.Graph.Inductive.Graph  ( Node )
import qualified Data.Graph.Inductive.Graph  as G
import Data.Graph.Inductive.PatriciaTree as G

import Control.Exception
import Control.Monad.Reader
import Control.Monad.State

import AtomComp -- simplified Ziria model
import AstExpr (nameTyp)
import Opts


--type Node = Int --defined in FGL
type LNode = G.LNode NodeLabel
type Chan = VarName

data NodeLabel
  = NodeLabel { node_id   :: Node
              , node_kind :: NodeKind
              }

data NodeKind
  = Action { action_in   :: Set Chan
           , action_out  :: Set Chan
           , action_code :: FunName
           }

  | Loop { loop_times :: Maybe Int }

  | Branch { branch_in   :: Set Chan
           , branch_code :: FunName
           , branch_next :: (Node,Node)
           }

data Automaton
  = Automaton { autom_init  :: Node
              , autom_final :: Set Node }

type ZirGraph = Gr NodeLabel ()

type GraphM a = StateT ZirGraph (ReaderT (CompEnv ()) IO) a


mkNode :: NodeKind -> GraphM LNode
mkNode kind = do
  g <- get
  let [node] = G.newNodes 1 g
  let lnode = (node, NodeLabel node kind)
  put (G.insNode lnode g)
  return lnode

--mkDummyNode :: GraphM LNode
--mkDummyNode = mkNode $ Action Set.empty Set.empty (eint32 0) []

--mkDummyAutomaton :: GraphM Automaton
--mkDummyAutomaton = do
--  (node,_) <- mkDummyNode
--  return $ Automaton node (Set.singleton node)

singletonAutomaton :: Node -> Automaton
singletonAutomaton node = Automaton node (Set.singleton node)

--extendChan :: (EId,Chan) -> GraphM a -> GraphM a
--extendChan (x,c) = local add_bnd
--  where add_bnd (ZirEnv binds sym) = ZirEnv ((x,c):binds) sym

----lookupChan :: EId -> GraphM Chan
----lookupChan x = do
----   env <- ask
----   case lookup x (chan_binds env) of
----      Nothing   -> fail ("Automata generation: unbound variable " ++ (show x))
----      Just chan -> return chan

---- TODO: use proper exception
--lookupChan :: ZirEnv -> EId -> Chan
--lookupChan env x =
--   case lookup x (chan_binds env) of
--      Nothing   -> assert False undefined
--      Just chan -> chan

--freshChan :: EId -> GraphM Chan
--freshChan x = do
--  u <- liftIO . GS.genSymStr =<< asks chan_gensym
--  return $ x { uniqId = MkUniq u }

--runGraphM :: GraphM a -> IO (a,ZirGraph)
--runGraphM m = do
--   new_sym <- GS.initGenSym "automata"
--   runReaderT (runStateT m (G.empty)) (ZirEnv [] new_sym)

{-------------------- Translation --------------------}

concatAutomata :: Automaton -> Automaton -> GraphM Automaton
concatAutomata a1 a2 = do
    let edges = map (\x -> (x, autom_init a2, ())) (Set.toList $ autom_final a1)
    modify (G.insEdges edges)
    return $ Automaton (autom_init a1) (autom_final a2)

data Channels = Channels { in_chan   :: Chan
                         , out_chan  :: Chan
                         , ctrl_chan :: Maybe Chan }


-- need to define some standard functions
-- discard t : t -> () = NOP
-- identity t : t -> t = Var
-- 

-- builds discard function of the appropriate type
mkDiscard :: Ty -> GraphM FunName
mkDiscard t = fail "not implemented"

-- builds identity function of the appropriate type
mkIdentity :: Ty -> GraphM FunName
mkIdentity t = fail "not implemented"

getVarType :: VarName -> GraphM Ty
getVarType x = do
  env <- ask
  case lookup x (var_binds env) of Nothing -> fail "variable not found"
                                   Just var -> return $ nameTyp var

mkAutomaton :: DynFlags -> Channels -> Comp a b -> GraphM Automaton
mkAutomaton dfs chans comp = go chans (unComp comp)
  where
    go chans (Take1 t) = do
      let inp = Set.singleton (in_chan chans)
      case ctrl_chan chans of
        Nothing -> do
          let outp = Set.empty
          code <- mkDiscard t
          (node,_) <- mkNode (Action inp outp code)
          return $ singletonAutomaton node
        Just ctrlc -> do
          let outp = Set.singleton ctrlc
          code <- mkIdentity t
          (node,_) <- mkNode (Action inp outp code)
          return $ singletonAutomaton node

    go chans (TakeN _ n) = fail "not implemented"

    go chans (Emit1 x) = do
      let inp = Set.singleton x
      let outp = Set.singleton (out_chan chans)
      t <- getVarType x
      code <- mkIdentity t
      (node,_) <- mkNode (Action inp outp code)
      return $ singletonAutomaton node



    go chans (EmitN x) = fail "not implemented" 
    go chans (Return e) = fail "not implemented" 

    go chans (NewVar x_spec c) = fail "not implemented"
    go chans (Bind x c) = fail "not implemented"

    go chans (Seq c1 c2) = fail "not implemented"
    go chans (Par _ c1 c2) = fail "not implemented" 

    go chans (AtomComp.Branch x c1 c2) = fail "not implemented" 

    go chans (RepeatN n c) = fail "not implemented" 
    go chans (Repeat c) = fail "not implemented"

    go chans (While x c) = fail "not implemented"
    go chans (Until x c) = fail "not implemented"
