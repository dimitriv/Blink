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
{-# LANGUAGE  QuasiQuotes, GADTs, ScopedTypeVariables, RecordWildCards #-}
{-# OPTIONS_GHC -fwarn-unused-binds -Werror #-}

module CgExpr ( codeGenExp ) where

import Opts
import AstExpr
import AstUnlabelled
import AstComp
import PpExpr
import PpComp
import qualified GenSym as GS
import CgHeader
import CgRuntime
import CgMonad
import CgTypes
import CgLUT
import Utils
import CtExpr
import {-# SOURCE #-} CgCall

import Outputable

import Control.Applicative
import Control.Monad ( when, unless )
import Control.Monad.IO.Class (liftIO)
import Data.Bits
import Data.List (elemIndex, foldl', isPrefixOf )
import Data.Loc
import qualified Data.Symbol
import qualified Language.C.Syntax as C
import Language.C.Quote.C
import Language.C.Quote.Base (ToConst(..))
import qualified Language.C.Pretty as P
import Numeric (showHex)
import qualified Data.Map as M
import Text.PrettyPrint.HughesPJ
import Data.Maybe

import LUTAnalysis
import Analysis.DataFlow

import CgBoundsCheck
import CgValDom
import CgCmdDom
import CgPrint 
import CgCall

{------------------------------------------------------------------------
  Code Generation Proper
------------------------------------------------------------------------}

cgLetBind :: DynFlags -> SrcLoc -> EId -> Exp -> Cg a -> Cg a
cgLetBind dfs loc x e m = do
  ce <- cgEvalRVal dfs e
  case unExp e of 
    -- Reuse allocated space if we will not be mutating this (let bound)
    EValArr {} -> extendVarEnv [(x,ce)] m
    _          -> do 
      x_name <- genSym $ name x ++ getLnNumInStr loc
      let ty = ctExp e
      appendCodeGenDeclGroup x_name ty ZeroOut   
      let cx = [cexp| $id:x_name|]
      assignByVal ty cx ce
      extendVarEnv [(x,cx)] m

cgMutBind :: DynFlags -> SrcLoc -> EId -> Maybe Exp -> Cg a -> Cg a
cgMutBind dfs loc x mbe m = do
  case mbe of 
    -- NB: the following code is plain wrong because of mutation!
    -- We can only do something like this if we have an immutable
    -- let-binding (see above)
    -- 
    -- Just e@(MkExp (EValArr {}) _ _) -> do 
    --     x_binding <- cgEvalRVal dfs e
    --     extendVarEnv [(x,x_binding)] m

    Just e -> do 
      x_name <- genSym $ name x ++ getLnNumInStr loc
      let ty = ctExp e
      ce <- cgEvalRVal dfs e
      appendCodeGenDeclGroup x_name ty ZeroOut 
      let cx = [cexp| $id:x_name|]
      assignByVal ty cx ce
      let x_binding = cx
      extendVarEnv [(x,x_binding)] m

    Nothing -> do
      x_name <- genSym $ name x ++ getLnNumInStr loc
      appendCodeGenDeclGroup x_name (nameTyp x) ZeroOut
      let x_binding = [cexp| $id:x_name|]
      extendVarEnv [(x,x_binding)] m


cgIf :: DynFlags -> C.Exp -> Cg C.Exp -> Cg C.Exp -> Cg C.Exp
cgIf _dfs ccond act1 act2 = do
   condvar <- genSym "__c"
   appendDecl [cdecl| int $id:condvar;|]
   appendStmt [cstm|  $id:condvar = $ccond;|]

   (e2_decls, e2_stmts, ce2) <- inNewBlock act1
   (e3_decls, e3_stmts, ce3) <- inNewBlock act2

   appendDecls e2_decls
   appendDecls e3_decls

   unless (null e2_stmts && null e3_stmts) $ 
      appendStmt [cstm|if ($id:condvar) {
                         $stms:e2_stmts
                       } else {
                         $stms:e3_stmts
                       } |]

   return [cexp| $id:condvar?$ce2:$ce3|]


codeGenExp :: DynFlags -> Exp -> Cg C.Exp
codeGenExp = cgEvalRVal  

cgEvalRVal :: DynFlags -> Exp -> Cg C.Exp
cgEvalRVal dfs e = cgEval dfs e >>= do_ret
 where do_ret (Left lval) = cgDeref dfs (expLoc e) lval
       do_ret (Right ce)  = return ce

cgEvalLVal :: DynFlags -> Exp -> Cg (LVal ArrIdx)
cgEvalLVal dfs e = cgEval dfs e >>= do_ret
 where do_ret (Left lval) = return lval
       do_ret (Right ce)  = error "cgEvalLVal"

cgEval :: DynFlags -> Exp -> Cg (Either (LVal ArrIdx) C.Exp)
cgEval dfs e = go (unExp e) where
  loc = expLoc e

  -- Any variable is byte aligned 
  is_lval_aligned (GDVar {}) _ = True 
  -- Any non-bit array deref exp is not aligned (NB: we could improve that)
  is_lval_aligned _ TBit            = False
  is_lval_aligned _ (TArray _ TBit) = False

  -- Any other 
  is_lval_aligned _ _ = True

  go_assign :: DynFlags -> SrcLoc -> LVal ArrIdx -> Exp -> Cg C.Exp
  go_assign dfs loc clhs erhs
    | is_lval_aligned clhs (ctExp erhs)
    , ECall nef eargs <- unExp erhs
    = do clhs_c <- cgDeref dfs loc clhs
         _ <- cgCall_aux dfs loc (ctExp erhs) nef eargs (Just clhs_c)
         return [cexp|UNIT|]
    | otherwise = do
         mrhs <- cgEval dfs erhs
         case mrhs of
           Left rlval -> do
             -- | lvalAlias_exact clhs rlval -> do 
             --     crhs <- cgDeref dfs loc rlval
             --     cgAssignAliasing dfs loc clhs crhs
             -- | otherwise -> do 
                 crhs <- cgDeref dfs loc rlval
                 cgAssign dfs loc clhs crhs
           Right crhs -> cgAssign dfs loc clhs crhs
         -- crhs <- cgEvalRVal dfs erhs
         -- cgAssign dfs loc clhs crhs
         return [cexp|UNIT|]
             

  go :: Exp0 -> Cg (Either (LVal ArrIdx) C.Exp) 

  go (EVar x)   = return (Left (GDVar x))
  go (EVal _ v) = return (Right (codeGenVal v)) 

  go (EValArr vs)    = Right <$> cgArrVal dfs loc (ctExp e) vs
  go (EStruct t tes) = do 
      ctes <- mapM (\(f,ef) -> 
        do cef <- cgEvalRVal dfs ef 
           return (f,cef)) tes
      Right <$> cgStruct dfs loc t ctes

  go (EUnOp u e1) = do 
     ce1 <- cgEvalRVal dfs e1
     Right <$> return (cgUnOp (ctExp e) u ce1 (ctExp e1))

  go (EBinOp b e1 e2) = do 
     ce1 <- cgEvalRVal dfs e1
     ce2 <- cgEvalRVal dfs e2
     Right <$> return (cgBinOp (ctExp e) b ce1 (ctExp e1) ce2 (ctExp e2))

  go (EAssign elhs erhs) = do
    clhs <- cgEvalLVal dfs elhs
    Right <$> go_assign dfs loc clhs erhs 

  go (EArrWrite earr ei rng erhs) 
    = go (EAssign (eArrRead loc earr ei rng) erhs)

  go (EArrRead earr ei rng) 
    | EVal _t (VInt i Signed) <- unExp ei
    , let ii :: Int = fromIntegral i
    , let aidx = AIdxStatic ii
    = mk_arr_read (ctExp e) (ctExp earr) aidx
    | otherwise 
    = do aidx <- AIdxCExp <$> cgEvalRVal dfs ei
         mk_arr_read (ctExp e) (ctExp earr) aidx
    where 
      mk_arr_read exp_ty arr_ty aidx = do 
        d <- cgEval dfs earr
        case d of 
          Left lval -> return (Left (GDArr lval aidx rng))
          Right ce 
            -> Right <$> cgArrRead dfs loc exp_ty ce arr_ty aidx rng 

  go (EProj e0 f) = do 
    d <- cgEval dfs e0
    case d of 
      Left lval -> Left  <$> return (GDProj lval f)
      Right ce  -> Right <$> return (cgStrProj (ctExp e) ce (ctExp e0) f)

  go elet@(ELet x _fi e1 e2)
     = cgLetBind dfs loc x e1 (cgEvalRVal dfs e2 >>= (return . Right))

  go (ELetRef x mb_e1 e2)
     = cgMutBind dfs loc x mb_e1 (cgEvalRVal dfs e2 >>= (return . Right))

  go (ESeq e1 e2) = do
      _ce1 <- cgEval dfs e1
      Right <$> cgEvalRVal dfs e2

  go (EIf e1 e2 e3) = do
     ce1 <- cgEvalRVal dfs e1
     Right <$> cgIf dfs ce1 (cgEvalRVal dfs e2) (cgEvalRVal dfs e3)

  go (EPrint nl e1s) = do 
      printExps nl dfs e1s
      Right <$> return [cexp|UNIT|]

  go (EError ty str) = do
      appendStmt [cstm|printf("RUNTIME ERROR: %s\n", $str);|]
      appendStmt [cstm|exit(1);|]
      -- We allocate a new variable of the appropriate type just
      -- because error is polymorphic and this is a cheap way to 
      -- return "the right type"
      x <- genSym "__err"
      appendCodeGenDeclGroup x ty ZeroOut
      Right <$> return [cexp|$id:x|]
  
  go (ELUT r e1) 
     | isDynFlagSet dfs NoLUT 
     = cgEval dfs e1
     | isDynFlagSet dfs MockLUT
     = cgPrintVars dfs loc (lutVarUsePkg r) $
       cgEval dfs e1
     | otherwise
     = Right <$> codeGenLUTExp dfs r e1 Nothing

  go (EWhile econd ebody) = do
      (init_decls,init_stms,cecond) <- inNewBlock (cgEvalRVal dfs econd)
      (body_decls,body_stms,cebody) <- inNewBlock (cgEvalRVal dfs ebody)

      appendDecls init_decls
      appendDecls body_decls
      appendStmts init_stms

      appendStmt [cstm|while ($cecond) {
                         $stms:body_stms
                         $stms:init_stms
                  }|]
      Right <$> return [cexp|UNIT|]

  go (EFor _ui k estart elen ebody) = do

      k_new <- freshName (name k) (ctExp estart) Imm

      (init_decls, init_stms, (ceStart, ceLen)) <- inNewBlock $ do
          ceStart <- cgEvalRVal dfs estart
          ceLen   <- cgEvalRVal dfs elen
          return (ceStart, ceLen)

      (body_decls, body_stms, cebody) <- inNewBlock $
          extendVarEnv [(k, [cexp|$id:(name k_new)|])] $ cgEvalRVal dfs ebody

      appendDecls init_decls
      appendDecls body_decls
      appendStmts init_stms
      let idx_ty = codeGenTyOcc (ctExp estart)
      appendStmt [cstm|for ($ty:(idx_ty) $id:(name k_new) = $ceStart; 
                            $id:(name k_new) < ($ceStart + $ceLen); 
                            $id:(name k_new)++) {
                         $stms:init_stms
                         $stms:body_stms
                       }|]
      Right <$> return [cexp|UNIT|]

  go (ECall nef eargs) = Right <$> cgCall_aux dfs loc (ctExp e) nef eargs Nothing


cgCall_aux :: DynFlags -> SrcLoc -> Ty -> EId -> [Exp] -> Maybe C.Exp -> Cg C.Exp
cgCall_aux dfs loc res_ty fn eargs mb_ret = do 
  let funtys = map ctExp eargs
  let (TArrow formal_argtys _) = nameTyp fn
  let argfuntys = zipWith (\(GArgTy _ m) t -> GArgTy t m) formal_argtys funtys
  let tys_args = zip argfuntys eargs
 
  ceargs <- mapM (cgEvalArg dfs) tys_args
  CgCall.cgCall dfs loc res_ty argfuntys fn ceargs mb_ret


  -- extendVarEnv [(retn,cretn)] $
  --    CgCall.cgCall dfs loc res_ty argfuntys fn ceargs cretn


cgEvalArg :: DynFlags -> (ArgTy, Exp) -> Cg (Either (LVal ArrIdx) C.Exp)
cgEvalArg dfs (GArgTy _ Mut, earg) = Left <$> cgEvalLVal dfs earg 
cgEvalArg dfs (_, earg) = Right <$> cgEvalRVal dfs earg
 


