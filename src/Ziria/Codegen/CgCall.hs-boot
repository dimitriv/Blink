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

module Ziria.Codegen.CgCall ( cgCall ) where

import Data.Loc
import qualified Language.C.Syntax as C

import Ziria.BasicTypes.AstExpr
import Ziria.Codegen.CgMonad
import Ziria.Codegen.CgValDom

import Opts

cgCall :: DynFlags 
       -> SrcLoc
       -> Ty
       -> [ArgTy]
       -> GName Ty -> [(Either (LVal ArrIdx) C.Exp)]
       -> Cg C.Exp
