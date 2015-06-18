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
{-# OPTIONS_GHC -Wall -Werror #-}

module Ziria.Codegen.CgPrint ( printExps ) where

import Control.Monad ( when )
import Data.Loc
import Language.C.Quote.C
import qualified Language.C.Syntax as C

import Ziria.BasicTypes.AstExpr
import Ziria.BasicTypes.AstUnlabelled
import {-# SOURCE #-} Ziria.Codegen.CgExpr
import Ziria.Codegen.CgMonad
import Ziria.Codegen.CgTypes
import Ziria.ComputeType.CtExpr

import Opts
-- TODO (minor): cg-prefix the function definitions in this module

printExps :: Bool -> DynFlags -> [Exp] -> Cg ()
printExps nl dflags es = do
  _ <- mapM (printExp dflags) es
  when nl $ appendStmt [cstm|printf("\n");|]

printExp :: DynFlags -> Exp -> Cg ()
printExp dflags e1 = go e1 (ctExp e1)
  where
    go :: Exp -> Ty -> Cg ()
    go e (TArray l t) = printArray dflags e cUpperBound t
      where cUpperBound
              | Literal len <- l = [cexp|$exp:len|]
              | NVar len    <- l = [cexp|$id:len|]
              | otherwise = error "printExp: unknown upper bound!"
    go e _ = printScalar dflags e

printArray :: DynFlags -> Exp -> C.Exp -> Ty -> Cg ()
printArray dflags e cupper t
  | TBit <- t
  = do { ce <- codeGenExp dflags e
       ; appendStmt [cstm|printBitArr($ce, $cupper); |]
       }
  | otherwise
  = do { pcdeclN <- freshName ("__print_cnt_") tint Mut
       ; pvdeclN <- freshName ("__print_val_") t Mut

       ; let pcdeclN_c = name pcdeclN
             pvdeclN_c = name pvdeclN

       ; let pcDeclE  = eVar noLoc pcdeclN
             pvDeclE  = eVar noLoc pvdeclN
             pvAssign = eAssign noLoc
                           pvDeclE (eArrRead noLoc e pcDeclE LISingleton)

         -- Declare the value
       ; appendCodeGenDeclGroup pvdeclN_c t ZeroOut

       ; extendVarEnv [(pcdeclN, [cexp|$id:pcdeclN_c|])
                      ,(pvdeclN, [cexp|$id:pvdeclN_c|])] $ do 

           (e1_decls, e1_stms, _ce1) <- inNewBlock $ codeGenExp dflags pvAssign
           (e2_decls, e2_stms, _ce2) <- inNewBlock $ printScalar dflags pvDeclE
           (e3_decls, e3_stms, _ce3) <- inNewBlock $ 
               printScalar dflags (eVal noLoc TString (VString ","))

           appendDecls e1_decls
           appendDecls e2_decls
           appendDecls e3_decls

           appendStmt [cstm|for(int $id:pcdeclN_c=0; 
                              $id:pcdeclN_c < $exp:cupper ; $id:pcdeclN_c++) {
                              $stms:e1_stms
                              $stms:e2_stms
                              $stms:e3_stms
                            }|]
       }

printScalar :: DynFlags -> Exp -> Cg ()
printScalar dflags e = do
   ce1 <- codeGenExp dflags e
   appendStmt $
     case ctExp e of
       TUnit        -> [cstm|printf("UNIT");      |]
       TBit         -> [cstm| printf("%d", $ce1); |]
       TBool        -> [cstm| printf("%d", $ce1); |]
       TString      -> [cstm| printf("%s", $ce1); |]
       TInt {}      -> [cstm| printf("%ld", $ce1);|]
       TDouble      -> [cstm| printf("%f", $ce1); |]
       ty | isComplexTy ty
          -> [cstm| printf("(%ld,%ld)", $ce1.re, $ce1.im);|]
          | otherwise
          -> error $ "Don't know how to print value of type " ++ show ty
