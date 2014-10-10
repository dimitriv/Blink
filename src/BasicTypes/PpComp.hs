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
{-# OPTIONS_GHC -Wall -fno-warn-orphans -fno-warn-name-shadowing #-}
-- | Pretty-printing type classes instances
module PpComp (
    ppCompPipeline
  , ppCompShortFold
  , ppCompAst
  , ppCompLoc
  , ppCompTyped
  , ppCompTypedVect
  , isSimplComp
  ) where

import Text.PrettyPrint.HughesPJ

import AstExpr
import AstComp
import PpExpr

import Outputable

{-------------------------------------------------------------------------------
  Outputable instances
-------------------------------------------------------------------------------}

instance Outputable ty => Outputable (GCTy0 ty) where
  ppr cty = case cty of
    TComp t1 t2 t3 ->
      text "ST" <+> parens (text "C" <+> ppr t1) <+> ppr t2 <+> ppr t3
    TTrans t1 t2 ->
      text "ST" <+> text "T" <+> ppr t1 <+> ppr t2

instance Outputable ty => Outputable (GCTy ty) where
  ppr cty = case cty of
    CTBase cty      -> ppr cty
    CTArrow tys cty ->
      parens (hsep (punctuate comma (map ppr tys))) <+>
      text "->" <+>
      ppr cty

instance Outputable ty => Outputable (GComp ty a b) where
  ppr = ppComp0 ppr False False False . unComp

instance (Outputable a, Outputable b) => Outputable (CallArg a b) where
  ppr (CAExp  e) = ppr e
  ppr (CAComp c) = ppr c

instance Outputable ParInfo where
  ppr info =
    let comb = case plInfo info of
                 AlwaysPipeline _ _ -> text "|>>>|"
                 NeverPipeline -> text ".>>>."
                 MaybePipeline -> text ">>>"
        inBurst  = maybe empty (\sz -> int sz <> text "_") (inBurstSz info)
        outBurst = maybe empty (\sz -> int sz <> text "_") (outBurstSz info)
    in inBurst <> comb <> outBurst

instance Outputable VectAnn where
  ppr (Rigid _r ann) = ppWidth ann
  ppr (UpTo _r ann)  = text "<=" <> ppWidth ann

instance Outputable ty => Outputable (GProg ty a b) where
  ppr p = case p of
    MkProg globs c ->
      ppDecls globs $$
      ppr c

{-------------------------------------------------------------------------------
  Util
-------------------------------------------------------------------------------}

pprpedName :: Outputable ty => GName ty -> Doc
pprpedName nm =
  case mbtype nm of
    Just ty -> parens $ ppName nm <+> text ":" <+> ppr ty
    Nothing -> ppName nm

ppComp0 :: Outputable ty => (GComp ty a b -> Doc) -> Bool -> Bool -> Bool -> GComp0 ty a b -> Doc
ppComp0 ppComp _printtypes ignorelet ignoreexp c =
  case c of
    Var x ->
      ppName x
    BindMany c1 xs_cs ->

         let go_pp c [] = ppComp c
             go_pp c ((x,c2):rest) =
               pprpedName x <+> text "<-" <+> ppComp c <> semi $$
               go_pp c2 rest
         in text "seq" <+> vcat [ text "{" <+> go_pp c1 xs_cs
                                , text "}" ]

    Seq c1 c2 ->
      ppComp c1 <> semi $$
      ppComp c2

    Par parInfo c1 c2 ->
{-
      parens ( ppComp c1 <+> ppr parInfo $$
               ppComp c2
             )
-}
      ppComp c1 <+> ppr parInfo $$
      ppComp c2

    Let x c1 c2
      | ignorelet
      -> ppComp c2
      | otherwise
      -> text "let comp" <+> pprpedName x <+> text "=" <+> ppComp c1 $$
         text "in" $$ ppComp c2

    LetStruct sdef c1
      | ignorelet || ignoreexp
      -> ppComp c1
      | otherwise
      -> text "struct " <+> text (struct_name sdef) <+> text "=" <+>
            (hsep $ punctuate (text ",") (map (\(f,t) ->
               text f <> colon <+> ppr t) (struct_flds sdef))) $$
         text "in" $$
         ppComp c1

    LetE x _ e c
      | ignorelet || ignoreexp
      -> ppComp c
      | otherwise
      -> text "let" <+> pprpedName x <+> text "=" <+> ppr e $$
         text "in" $$
         ppComp c

    -- CL
    LetERef x ty Nothing c
       | ignorelet || ignoreexp
       -> ppComp c
       | otherwise
       -> text "letref" <+> ppName x <+> colon <+> ppr ty $$
          text "in" $$
          ppComp c

    -- TODO: We should pretty-print the type annotation
    LetERef x _ty (Just e) c
       | ignorelet || ignoreexp
       -> ppComp c
       | otherwise
       -> text "letref" <+> assign ":=" (ppName x) (ppr e) $$
          text "in" $$
          ppComp c

    LetHeader _ fn c
      | ignorelet || ignoreexp
      -> ppComp c
      | otherwise
      -> text "let" <+> ppr fn $$
         text "in" $$
         ppComp c
    --
    LetFunC f params locls c1 c2
      | ignorelet || (ignoreexp && not (nested_letfuns c1))
      -> ppComp c2
      | otherwise
      -> text "let comp" <+> ppName f <+>
                           parens (ppCompParams params) <+> text "=" $$
           (if not ignoreexp then (nest nestingDepth (ppDecls locls))
            else empty) $$
           nest nestingDepth (ppComp c1) $$
         text "in" $$
         ppComp c2
    Call f eargs ->
      ppName f <+> parens (ppEs ppr comma eargs)
    Emit e
      | ignoreexp -> text "emit ..."
      | otherwise -> text "emit" <+> ppr e
    Emits e
      | ignoreexp -> text "emits ..."
      | otherwise -> text "emits" <+> ppr e
    Return _ e
      | ignoreexp -> text "return ..."
      | otherwise -> text "return" <+> ppr e
    Interleave c1 c2 ->
      ppComp c1 <+> text "<|>" <+> ppComp c2
    Branch e c1 c2 ->
      text "if" <+> ppr e $$
      text "then" <+> ppComp c1 $$
      text "else" <+> ppComp c2
    Take1 ->
      text "take"
    Take e ->
      text "takes" <+> ppr e
    Until e c ->
      text "until" <+> parens (ppr e) <+> ppComp c
    While e c ->
      text "while" <+> parens (ppr e) <+> ppComp c

    Times ui estart elen ix c ->
      ppr ui <+>
       text "for" <+>
         ppIx ix <+> text "in" <+>
            brackets (ppr estart <> comma <+> ppr elen) $$
         nest nestingDepth (ppComp c)

    Repeat wdth c ->
      text "repeat" <> maybe empty ppr wdth <+>
                       ppComp c

    VectComp (n1,n2) c ->
      text "repeat" <> ppWidth (n1,n2) <+>
                       ppComp c

    Map wdth nm ->
      text "map" <> maybe empty ppr wdth <+> ppName nm
    Filter e ->
      text "filter" <+> ppr e

    ReadSrc {} ->
      text "read"
    WriteSnk {} ->
      text "write"

    ReadInternal bid _typ _mq ->
      text "read_internal[sq]" <> parens (text bid)
    WriteInternal bid _mq ->
      text "write_internal[sq]" <> parens (text bid)

    Standalone c1 ->
      text "standalone" <> braces (ppComp c1)

    Sync _snfo ->
      text "{- sync -}"

    Mitigate t n1 n2 ->
      int n1 <> text "-mitigate" <> brackets (ppr t) <> text "-" <> int n2
    -- CL
    where assign s e1 e2 = e1 <+> text s <+> e2
    --


ppWidth :: (Int, Int) -> Doc
ppWidth (i,j) = brackets $ (int i) <> text "," <> (int j)



ppCompPipeline :: Comp a b -> Doc
ppCompPipeline = ppComp0 ppCompPipeline False True False . unComp

ppCompShortFold :: Comp a b -> Doc
ppCompShortFold = ppComp0 ppCompShortFold False False True . unComp


ppCompAst :: Comp a b -> Doc
ppCompAst cmp =
   brackets (text $ compShortName cmp) <+>
   ppComp0 (\c -> brackets (text $ compShortName c) <+> ppr c)
           False False False (unComp cmp)

ppCompLoc :: Comp a b -> Doc
ppCompLoc c =
  (case compLoc c of
    Just pos -> text (show pos)
    Nothing -> empty)


ppCompTyped :: Outputable a => Comp a b -> Doc
ppCompTyped x =
  let p1 = ppComp0 ppCompTyped True False False $ unComp x
      pty = ppr (compInfo x)
  in parens (p1 <+> text "::" <+> pty)

ppCompParams :: (Outputable ty, Outputable a, Outputable b) => [(GName ty, CallArg a b)] -> Doc
ppCompParams params =
  case params of
    [] -> empty
    (x, ty) : [] -> ppName x <> text ":" <+> ppr ty
    (x, ty) : params' ->
       ppName x <> text ":" <+> ppr ty <> comma <+> ppCompParams params'

ppCompTypedVect :: Comp CTy b -> Doc
ppCompTypedVect x =
  let p1  = ppComp0 ppCompTypedVect False True True $ unComp x
      cty  = compInfo x
      inty  = inTyOfCTyBase cty
      yldty = yldTyOfCTyBase cty
      arity (TArr (Literal n) _) = show n
      arity _                    = "1"
      ain   = arity inty
      ayld  = arity yldty

  in if isSimplComp (unComp x)
     then text ain <> text "-" <> braces p1 <> text "-" <> text ayld
     else p1

isSimplComp :: Comp0 a b -> Bool
isSimplComp (Var {})      = True
isSimplComp (Call {})     = True
isSimplComp (Emit {})     = True
isSimplComp (Return {})   = True
isSimplComp (Take1 {})    = True
isSimplComp (Take {})     = True
isSimplComp (Map {})      = True
isSimplComp (Filter {})   = True
isSimplComp (ReadSrc {})  = True
isSimplComp (WriteSnk {}) = True
isSimplComp _             = False

nested_letfuns :: GComp ty a b -> Bool
nested_letfuns c
  = case mapCompM_ return aux c of
      Nothing -> True
      Just _  -> False
  where aux c | LetFunC {} <- unComp c = Nothing
              | Let {}     <- unComp c = Nothing
              | otherwise              = Just c

{-------------------------------------------------------------------------------
  Show instances
-------------------------------------------------------------------------------}

instance Outputable ty => Show (GCTy0 ty)     where show = render . ppr
instance Outputable ty => Show (GCTy ty)      where show = render . ppr
instance Outputable ty => Show (GComp ty a b) where show = render . ppr
instance Outputable ty => Show (GProg ty a b) where show = render . ppr

instance Outputable ty => Show (GComp0 ty a b) where
  show = render . ppComp0 ppr False False False
