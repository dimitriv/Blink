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
-- | Compute the type of function calls
--
-- Since functions can be length polymorphic this involves instantiating
-- type variables. Note that length polymorphism is the _only_ kind of
-- polymorphism that Ziria supports.
{-# OPTIONS_GHC -Wall #-}
module Ziria.ComputeType.CtCall (ctECall, ctCall, lookup') where

import Ziria.BasicTypes.AstComp
import Ziria.BasicTypes.AstExpr
import Ziria.BasicTypes.Outputable
import Ziria.BasicTypes.PpExpr ()
import Ziria.BasicTypes.PpComp ()
import Ziria.Utils.Utils

import Text.PrettyPrint.HughesPJ

ctECall :: EId -> Ty -> [Ty] -> Ty
ctECall _f (TArrow args res) args' 
  = let funtys = map argty_ty args
    in applyTy (matchAllTy (zip funtys args')) res
ctECall f t args = panic $ 
  vcat [ text "ctECall: Unexpected type:" <+> ppr t
       , text "Argument list types:"     <+> ppr args
       , text "Function type      :"     <+> ppr f ]

ctCall :: CId -> CTy -> [CallArg Ty CTy] -> CTy
ctCall _f (CTArrow args res) args' 
  = applyCTy (matchAllCA (zip funtys argtys)) res
  where funtys = map erase_mut args
        argtys = args'
        erase_mut (CAComp x) = CAComp x
        erase_mut (CAExp x)  = CAExp (argty_ty x)

ctCall f t cargs = panic $ 
  vcat [ text "ctCall: Unexpected type:" <+> ppr t
       , text "Argument list types:"     <+> ppr cargs
       , text "Function type      :"     <+> ppr f ]


{-------------------------------------------------------------------------------
  Substitutions

  NOTE: Any type variables left in the type will (necessarily) be left
  unsubstituted.
-------------------------------------------------------------------------------}

type Subst = [(LenVar, NumExpr)]

applyTy :: Subst -> Ty -> Ty
applyTy s (TArray n  t) = TArray (applyNumExpr s n)   (applyTy s t)
applyTy s (TArrow ts t) = TArrow (map (applyArgTy s) ts) (applyTy s t)
applyTy _ t             = t

applyArgTy :: Subst -> ArgTy -> ArgTy
applyArgTy s (GArgTy t m) = GArgTy (applyTy s t) m

applyNumExpr :: Subst -> NumExpr -> NumExpr
applyNumExpr s (NVar n) = lookup' n s
applyNumExpr _ e        = e

applyCTy :: Subst -> CTy -> CTy
applyCTy s (CTComp u a b) = CTComp (applyTy s u) (applyTy s a) (applyTy s b)
applyCTy s (CTTrans  a b) = CTTrans (applyTy s a) (applyTy s b)
applyCTy s (CTArrow ts t) = CTArrow (map (applyCA s) ts) (applyCTy s t)
applyCTy _ (CTVar x)      = CTVar x

applyCA :: Subst -> CallArg ArgTy CTy -> CallArg ArgTy CTy
applyCA s = callArg (CAExp . applyArgTy s) (CAComp . applyCTy s)

{-------------------------------------------------------------------------------
  Expression types
-------------------------------------------------------------------------------}

matchAllTy :: [(Ty, Ty)] -> Subst
matchAllTy = concatMap (uncurry matchTy)

matchTy :: Ty -> Ty -> Subst
matchTy (TArray n  t) (TArray n'  t') = matchNumExpr n n' ++ matchTy t t'
matchTy (TArrow ts t) (TArrow ts' t') = matchAllTy (zip (t:ts_no_mut) (t':ts_no_mut'))
  where ts_no_mut  = map argty_ty ts
        ts_no_mut' = map argty_ty ts'
matchTy _             _               = []

matchNumExpr :: NumExpr -> NumExpr -> Subst
matchNumExpr (NVar n) e = [(n, e)]
matchNumExpr _        _ = []

{-------------------------------------------------------------------------------
  Computation types
-------------------------------------------------------------------------------}

matchAllCA :: [(CallArg Ty CTy, CallArg Ty CTy)] -> Subst
matchAllCA = concatMap (uncurry matchCA)

matchCA :: CallArg Ty CTy -> CallArg Ty CTy -> Subst
matchCA (CAExp  t) (CAExp  t') = matchTy  t t'
matchCA (CAComp t) (CAComp t') = matchCTy t t'
matchCA t t' = panic $ text "matchCA: Unexpected" <+> ppr t <+> text "and" <+> ppr t'

matchCTy :: CTy -> CTy -> Subst
matchCTy (CTComp u a b) (CTComp u' a' b') = matchAllTy [(u,u'), (a,a'), (b,b')]
matchCTy (CTTrans  a b) (CTTrans   a' b') = matchAllTy [(a,a'), (b,b')]
matchCTy _              _                 = []

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

lookup' :: (Outputable a, Eq a) => a -> [(a, b)] -> b
lookup' a dict =
  case lookup a dict of
    Nothing -> panic $ text "lookup:" <+> ppr a <+> text "not found"
    Just b  -> b
