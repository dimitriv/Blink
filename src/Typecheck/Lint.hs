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
-- | Typecheck (and sanity check) core (rather than source)
--
-- TODO: If we define the type checker _in terms_ of the linter
-- (and I think we should), rather than reusing bits of the linter, we don't
-- have to export all the subcomponents of the linter.
--
-- TOOD: We should push error contexts in lintExpr and lintComp.
{-# OPTIONS_GHC -Wall -Wwarn #-}
module Lint (
    -- * Top-level API
    zonkLintComp
  , zonkLintExp
    -- * For use by the type checker
  , lintVal
  , lintUnOp
  , lintBinOp
  , lintExp
  , lintComp
  ) where

import Control.Applicative
import Control.Monad
import Text.PrettyPrint.HughesPJ
import Text.Parsec.Pos (SourcePos)

import AstComp
import AstExpr
import Outputable
import TcErrors
import TcMonad
import TcUnify


{-------------------------------------------------------------------------------
  Top-level API
-------------------------------------------------------------------------------}

zonkLintComp :: GComp CTy Ty a b -> TcM (GComp CTy Ty a b)
zonkLintComp comp = do
  void $ lintComp comp
  zonkComp comp

zonkLintExp :: GExp Ty a -> TcM (GExp Ty a)
zonkLintExp expr = do
  void $ lintExp expr
  zonkExpr expr

{-------------------------------------------------------------------------------
  The linter proper
-------------------------------------------------------------------------------}

lintVal :: Val -> TcM Ty
lintVal = go
  where
    go (VBit _)    = return TBit
    go (VInt _)    = TInt <$> freshBitWidth "bw"
    go (VDouble _) = return TDouble
    go (VBool _)   = return TBool
    go (VString _) = return TString
    go VUnit       = return TUnit

-- | Return the type of the result of applying a unary operator
--
-- TODO: The case for Neg is dubious: we should not check isScalarTy until all
-- unification constraints have been applied (where some of those constraints
-- might not be known at this point). See also comments for 'isScalarTy'.
lintUnOp :: Maybe SourcePos -> GUnOp Ty -> Ty -> TcM Ty
lintUnOp loc uop = zonkTy >=> go uop
  where
    go Neg argTy = do
      let msg = text "Expected scalar type but got" <+> ppr argTy
      checkWith loc (isScalarTy argTy) msg
      return argTy
    go Not argTy = do
      unify loc argTy TBool
      return argTy
    go BwNeg argTy = do
      firstToSucceed (unifyTInt' loc argTy)
                     (unify loc argTy TBit)
      return argTy
    go (Cast targetTy) argTy = do
      compat_test <- case (targetTy, argTy) of
        (TBit,       TInt _)     -> return True
        (TInt _,     TBit)       -> return True
        (TDouble,    TInt _)     -> return True
        (TInt _p,    TDouble)    -> return True
        (TInt _,     TInt _)     -> return True
        (TStruct {}, TStruct {}) -> return $ isComplexTy targetTy && isComplexTy argTy
        -- Otherwise just try to unify
        (t1,         t2)         -> unify loc t1 t2 >> return True
      checkWith loc compat_test $
        text "Invalid cast from type" <+> ppr argTy <+> text "to" <+> ppr targetTy
      return targetTy
    go ALength argTy = do
      void $ unifyTArray loc Infer Infer argTy
      return tint
    go NatExp _argTy =
      error "typeCheckExpr: NatExp not supported!"

lintBinOp :: Maybe SourcePos -> BinOp -> Ty -> Ty -> TcM Ty
lintBinOp loc bop = \argTy1 argTy2 -> do
    argTy1' <- zonkTy argTy1
    argTy2' <- zonkTy argTy2
    case () of
      () | isArithBinOp    bop -> goArith    argTy1' argTy2'
      () | isShiftBinOp    bop -> goShift    argTy1' argTy2'
      () | isLogicalBinOp  bop -> goLogical  argTy1' argTy2'
      () | isEqualityBinOp bop -> goEquality argTy1' argTy2'
      () | isRelBinOp      bop -> goRel      argTy1' argTy2'
      () | isBoolBinOp     bop -> goBool     argTy1' argTy2'
      () -> error $ "BUG: Forgot operator " ++ show bop ++ " in lintBinOp!"
  where
    -- Add / Sub / Mult / Div / Rem / Expon
    goArith argTy1 argTy2 = do
      -- liftIO $ putStrLn $ "argTy1 = " ++ show argTy1
      checkWith loc (supportsArithTy argTy1) mismatch
      unify loc argTy1 argTy2
      return argTy1

    -- ShL / ShR
    goShift argTy1 argTy2 = do
      unifyTInt' loc argTy1
      unifyTInt' loc argTy2
      return argTy1

    -- BwAnd / BwOr / BwXor (valid for either int or bit)
    goLogical argTy1 argTy2 = do
      unify loc argTy1 argTy2 -- order is important here!
      firstToSucceed (unifyTInt' loc argTy1)
                     (unify loc argTy1 TBit)
      return argTy1

    -- Eq / Neq
    goEquality argTy1 argTy2 = do
      checkWith loc (supportsEqTy argTy1) mismatch
      unify loc argTy1 argTy2
      return TBool

    -- Let / Leq / Gt / Geq
    goRel argTy1 argTy2 = do
      checkWith loc (supportsCmpTy argTy1) mismatch
      unify loc argTy1 argTy2
      return TBool

    -- And / Or
    goBool argTy1 argTy2 = do
      unify loc argTy1 TBool
      unify loc argTy2 TBool
      return TBool

    mismatch = text "Binary operator type mismatch:" <+> ppr bop


lintExp :: GExp Ty a -> TcM Ty
lintExp (MkExp exp0 loc _) = go exp0
  where
    go :: GExp0 Ty a -> TcM Ty
    go (EVal ty val) = do
      ty' <- lintVal val
      unify loc ty ty'
      return ty
    go (EValArr _ []) = do
      raiseErrNoVarCtx loc $ text "Empty array constant"
    go (EValArr ty vals) = do
      tys <- mapM lintVal vals
      unifyAll loc tys
      void $ unifyTArray loc (Check (Literal (length vals))) (Check (head tys)) ty
      return ty
    go (EVar x) =
      return (nameTyp x)
    go (EUnOp uop e) = do
      ty <- lintExp e
      lintUnOp loc uop ty
    go (EBinOp bop e1 e2) = do
      ty1 <- lintExp e1
      ty2 <- lintExp e2
      lintBinOp loc bop ty1 ty2
    go (EAssign e1 e2) = do
      ty1 <- lintExp e1
      ty2 <- lintExp e2
      unify loc ty1 ty2
      return TUnit
    go (EArrWrite arr idx li rhs) = do
      arrTy <- lintExp arr
      idxTy <- lintExp idx
      rhsTy <- lintExp rhs
      unifyTInt' loc idxTy
      (_n, a) <- unifyTArray loc Infer Infer arrTy
      case li of
        LISingleton -> unify loc rhsTy a
        LILength m  -> void $ unifyTArray loc (Check (Literal m)) (Check a) rhsTy
      return TUnit
    go (EArrRead arr idx li) = do
      arrTy <- lintExp arr
      idxTy <- lintExp idx
      unifyTInt' loc idxTy
      (_n, a) <- unifyTArray loc Infer Infer arrTy
      case li of
        LISingleton -> return a
        LILength m  -> return $ TArray (Literal m) a
    go (EIter ix x earr ebody) = do
      let ixTy = nameTyp ix
      let xTy  = nameTyp x
      earrTy  <- lintExp earr
      ebodyTy <- lintExp ebody
      void $ unifyTArray loc Infer (Check xTy) earrTy
      unifyTInt' loc ixTy
      unify loc ebodyTy TUnit
      -- If type of ix is not known after typecheck the body, default to tint32
      _ <- defaultTy loc ixTy tint32
      return TUnit
    go (EFor _ui x estart elen ebody) = do
      let xTy = nameTyp x
      unifyTInt' loc xTy
      estartTy <- lintExp estart
      elenTy   <- lintExp elen
      ebodyTy  <- lintExp ebody
      unifyAll loc [xTy, estartTy, elenTy]
      unify loc ebodyTy TUnit
      -- If type of x is not known after typecheck the body, default to tint32
      _ <- defaultTy loc xTy tint32
      return TUnit
    go (EWhile econd ebody) = do
      econdTy <- lintExp econd
      ebodyTy <- lintExp ebody
      unify loc econdTy TBool
      unify loc ebodyTy TUnit
      return TUnit
    go (ELet x _fi e1 e2) = do
      let xTy = nameTyp x
      e1Ty <- lintExp e1
      unify loc xTy e1Ty
      lintExp e2
    go (ELetRef x (Just e1) e2) = do
      let xTy = nameTyp x
      e1Ty <- lintExp e1
      unify loc xTy e1Ty
      lintExp e2
    go (ELetRef _x Nothing e2) =
      lintExp e2
    go (ESeq e1 e2) = do
      -- TODO: We might want to insist that e1 has type TUnit
      void $ lintExp e1
      lintExp e2
    go e@(ECall f args) = do
      -- The types of functions are always known before we call them
      fTy    <- instantiateCall =<< zonkTy (nameTyp f)
      actual <- mapM lintExp args
      case fTy of
        TArrow formal res -> do
          checkWith loc (length formal == length actual) $
            vcat [ text "Function" <+> ppr f
                 , text "Expecting" <+> int (length formal) <+>
                                        text "arguments"
                 , text "but was given" <+> int (length actual)
                 ]

          unifyMany loc formal actual
          return res
        _ ->
          raiseErrNoVarCtx loc $
            expActualErr (unknownTFun (length actual)) fTy e
    go (EIf be e1 e2) = do
      beTy <- lintExp be
      e1Ty <- lintExp e1
      e2Ty <- lintExp e2
      unify loc beTy TBool
      unify loc e1Ty e2Ty
      return e1Ty
    go (EPrint _ e) = do
      void $ lintExp e
      return TUnit
    go (EError t _) =
      return t
    go (ELUT _ e) =
      -- TODO: Should we check anything about the types in the ranges?
      lintExp e
    go (EBPerm earr eperm) = do
      earrTy  <- lintExp earr
      epermTy <- lintExp eperm
      (n, _)  <- unifyTArray loc Infer (Check TBit) earrTy
      ti <- TInt <$> freshBitWidth "bw"
      void $ unifyTArray loc (Check n) (Check ti) epermTy
      return earrTy
    go (EStruct tn flds) = do
      -- NOTE: Since we want to be able to call the linter at any point and
      -- on any kind of snippet, we don't want to rely on environments. Hence
      -- we cannot look up the definition of the struct; we have to assume
      -- that this is OK.
      fldTys <- mapM lintExp (map snd flds)
      return $ TStruct tn (zip (map fst flds) fldTys)
    go (EProj e fld) = do
      eTy <- zonkTy =<< lintExp e
      -- Since structs can share field names, we cannot infer a type here
      case eTy of
        TStruct nm flds ->
          case lookup fld flds of
            Nothing ->
              raiseErrNoVarCtx loc $
                text ("Unknown field " ++ fld ++ " projected out of type " ++ nm)
            Just fty ->
              return fty
        _other ->
          raiseErrNoVarCtx loc $
            text "Field projection from non-struct type: " <+> ppr eTy

-- | We return CTy0 rather than CTy because computations must always be
-- fully applied.
lintComp :: GComp CTy Ty a b -> TcM CTy0
lintComp (MkComp comp0 loc _) = go comp0
  where
    go :: GComp0 CTy Ty a b -> TcM CTy0
    go (Var c) =
      unifyBase loc (nameTyp c)
    go (BindMany c []) =
      lintComp c
    go (BindMany c ((x, c'):cs)) = do
      cty1 <- lintComp c
      cty2 <- go (BindMany c' cs)
      (_, a, b) <- unifyComp loc (Check (nameTyp x)) Infer Infer cty1
      void $ unifyCompOrTrans loc (Check a) (Check b) cty2
      return cty2
    go (Seq c1 c2) = do
      cty1 <- lintComp c1
      cty2 <- lintComp c2
      -- TODO: We might want to insist that c1 returns unit here
      --                         vvvvv
      (_, a, b) <- unifyComp loc Infer Infer Infer cty1
      void $ unifyCompOrTrans loc (Check a) (Check b) cty2
      return cty2
    go (Par _pi c1 c2) = do
      cty1 <- lintComp c1
      cty2 <- lintComp c2
      (mu1, a, b) <- unifyCompOrTrans loc Infer Infer cty1
      case mu1 of
        Just u -> do -- c1 is a computer
          (_, c) <- unifyTrans loc (Check b) Infer cty2
          return $ TComp u a c
        Nothing -> do -- c1 is a transformer
          (mu2, _, c) <- unifyCompOrTrans loc (Check b) Infer cty2
          case mu2 of
            Just u -> -- c2 is a computer
              return $ TComp u a c
            Nothing ->
              return $ TTrans a c
    go (Let x c1 c2) = do
      xTy <- unifyBase loc (nameTyp x)
      (mu, a, b) <- unifyCompOrTrans loc Infer Infer xTy
      cty1 <- lintComp c1
      case mu of
        Nothing -> void $ unifyTrans loc (Check a) (Check b) cty1
        Just u  -> void $ unifyComp loc (Check u) (Check a) (Check b) cty1
      lintComp c2
    go (LetE x _fi e c) = do
      ety <- lintExp e
      unify loc (nameTyp x) ety
      lintComp c
    go (LetERef x (Just e) c) = do
      ety <- lintExp e
      unify loc (nameTyp x) ety
      lintComp c
    go (LetERef _x Nothing c) = do
      lintComp c
    go (LetHeader fun c) = do
      void $ lintFun fun
      lintComp c
    go (LetFunC f args locals body rhs) = do
      lintLocals loc locals
      bodyCty <- lintComp body
      lintCFunTy loc (nameTyp f) (map nameTyp args) bodyCty
      lintComp rhs
    go (LetStruct _ c) =
      lintComp c
    go (Call f args) = do
      argTys <- forM args $ \arg -> case arg of
                  CAExp  e -> CAExp  <$> lintExp e
                  CAComp c -> CAComp <$> lintComp c
      lintCCall loc (nameTyp f) argTys
    go (Emit a e) = do
      b <- lintExp e
      return $ TComp TUnit a b
    go (Emits a e) = do
      ety <- lintExp e
      (_n, b) <- unifyTArray loc Infer Infer ety
      return $ TComp TUnit a b
    go (Return a b _fi e) = do
      u <- lintExp e
      return $ TComp u a b
    go (Interleave c1 c2) = do
      cty1 <- lintComp c1
      cty2 <- lintComp c2
      (a, b) <- unifyTrans loc Infer Infer cty1
      void $ unifyTrans loc (Check a) (Check b) cty2
      return cty1
    go (Branch e c1 c2) = do
      ety  <- lintExp e
      cty1 <- lintComp c1
      cty2 <- lintComp c2
      unify loc ety TBool
      unify_cty0 loc cty1 cty2
      return cty1
    go (Take1 a b) = do
      return $ TComp a a b
    go (Take a b n) = do
      return $ TComp (TArray (Literal n) a) a b
    go (Until e c) = do
      ety <- lintExp e
      cty <- lintComp c
      unify loc ety TBool
      void $ unifyComp loc Infer Infer Infer cty
      return cty
    go (While e c) = do
      ety <- lintExp e
      cty <- lintComp c
      unify loc ety TBool
      void $ unifyComp loc Infer Infer Infer cty
      return cty
    go (Times _ui estart elen x c) = do
      estartTy <- lintExp estart
      elenTy   <- lintExp elen
      cty      <- lintComp c
      void $ unifyTInt loc Infer (nameTyp x)
      unifyAll loc [estartTy, elenTy, nameTyp x]
      void $ unifyComp loc Infer Infer Infer cty
      return cty
    go (Repeat _ann c) = do
      cty <- lintComp c
      (_, a, b) <- unifyComp loc (Check TUnit) Infer Infer cty
      return $ TTrans a b
    go (VectComp _ c) =
      lintComp c
    go (Map _ f) = do
      a <- freshTy "a"
      b <- freshTy "b"
      let fTy = TArrow [a] b
      unify loc fTy (nameTyp f)
      return $ TTrans a b
    go (Filter f) = do
      a <- freshTy "a"
      let fTy = TArrow [a] TBool
      unify loc fTy (nameTyp f)
      return $ TTrans a a
    go (ReadSrc a) =
      return $ TTrans (TBuff (ExtBuf a)) a
    go (WriteSnk a) =
      return $ TTrans a (TBuff (ExtBuf a))
    go (ReadInternal a _bid _rt) =
      return $ TTrans (TBuff (IntBuf a)) a
    go (WriteInternal a _bid) =
      return $ TTrans a (TBuff (IntBuf a))
    go (Standalone c) =
      lintComp c
    go (Mitigate a n1 n2) =
      lintMitigator loc a n1 n2

lintFun :: GFun Ty a -> TcM Ty
lintFun (MkFun fun0 loc _) = go fun0
  where
    go :: GFun0 Ty a -> TcM Ty
    go (MkFunDefined f args locals body) = do
      lintLocals loc locals
      res <- lintExp body
      unify loc (nameTyp f) $ TArrow (map nameTyp args) res
      return (nameTyp f)
    go (MkFunExternal f args res) = do
      unify loc (nameTyp f) $ TArrow (map nameTyp args) res
      return (nameTyp f)

lintLocals :: Maybe SourcePos -> [(GName Ty, Maybe (GExp Ty a))] -> TcM ()
lintLocals loc = mapM_ (uncurry go)
  where
    go :: GName Ty -> Maybe (GExp Ty a) -> TcM ()
    go _ Nothing  = return ()
    go x (Just e) = unify loc (nameTyp x) =<< lintExp e

lintMitigator :: Maybe SourcePos -> Ty -> Int -> Int -> TcM CTy0
lintMitigator loc a n1 n2 = do
    unless (n1 `divides` n2 || n2 `divides` n1) $
      raiseErrNoVarCtx loc $
             text "Invalid mitigator arguments"
         <+> parens (hsep (punctuate comma [int n1, int n2]))
    return $ TTrans (toArray n1) (toArray n2)
  where
    toArray :: Int -> Ty
    toArray 1 = a
    toArray n = TArray (Literal n) a

{-------------------------------------------------------------------------------
  Working with computation functions

  TODO: This code is very awkward. It could be _much_ simpler if we collapsed
  CTy and CTy0, and introduced CTVar.
-------------------------------------------------------------------------------}

lintCFunTy :: Maybe SourcePos -> CTy -> [CallArg Ty CTy] -> CTy0 -> TcM ()
lintCFunTy loc funTy args' res' = do
  (args, res) <- lintSplitFun loc funTy
  args'0 <- forM args' $ \arg -> case arg of
    CAExp ty             -> return $ CAExp  ty
    CAComp (CTBase cty0) -> return $ CAComp cty0
    CAComp (CTArrow _ _) -> raiseErrNoVarCtx loc $
                              text "Higher order arguments not supported"
  lintFunArgs loc args args'0
  unify_cty0 loc res res'

-- TODO: Why don't we need to instantiate here? Don't we support polymorphism
-- in comp functions?
lintCCall :: Maybe SourcePos -> CTy -> [CallArg Ty CTy0] -> TcM CTy0
lintCCall loc funTy actualArgs = do
  (formalArgs, res) <- lintSplitFun loc funTy
  lintFunArgs loc formalArgs actualArgs
  return res

lintSplitFun :: Maybe SourcePos -> CTy -> TcM ([CallArg Ty CTy0], CTy0)
lintSplitFun loc funTy =
  case funTy of
    CTArrow args res -> return (args, res)
    _ -> raiseErrNoVarCtx loc $
      text "Expected function type but got" <+> ppr funTy

-- This is used both when we check a function declaration and when we check
-- a function call
lintFunArgs :: Maybe SourcePos -> [CallArg Ty CTy0] -> [CallArg Ty CTy0] -> TcM ()
lintFunArgs loc expecteds actuals = do
  unless (length expecteds == length actuals) $
    raiseErrNoVarCtx loc $
      text "Expected" <+> int (length expecteds)
                      <+> text "arguments, but got"
                      <+> int (length actuals)
  forM_ (zip expecteds actuals) $ \(expected, actual) ->
    case (expected, actual) of
      (CAExp ty, CAExp ty') ->
        unify loc ty ty'
      (CAComp cty0, CAComp cty0') ->
        unify_cty0 loc cty0 cty0'
      (CAExp _, CAComp _) ->
        raiseErrNoVarCtx loc $
          text "Expected expression but got computation"
      (CAComp _, CAExp _) ->
        raiseErrNoVarCtx loc $
          text "Expected computation but got expression"

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

divides :: Int -> Int -> Bool
n `divides` m = m `mod` n == 0
