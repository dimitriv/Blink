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
{-# LANGUAGE GADTs, TemplateHaskell,
             MultiParamTypeClasses,
             RankNTypes,
             ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -Wwarn #-}
module BlinkParseComp (parseProgram, parseComp, parseTopLevel, runParseM) where

import Control.Applicative ((<$>), (<*>), (<$), (<*), (*>))
import Control.Monad (join)
import Control.Monad.Reader.Class
import Text.Parsec
import Text.Parsec.Expr

import AstComp
import AstExpr
import AstUnlabelled
import BlinkParseExpr
import BlinkLexer
import BlinkParseM
import Eval (evalInt)

import Utils ( uncurry4 )

{-------------------------------------------------------------------------------
  Top-level
-------------------------------------------------------------------------------}

-- | > <program> ::= <decls> <let-decls>*
--
-- TODO: Update the grammar
parseProgram :: BlinkParser SrcProg
parseProgram =
    join $ mkProg <$ startOfFile <* many fileNameChange
       <*> parseTopLevel <* eof
  where
    mkProg ([],     _)  = fail "No main found"
    mkProg (_:_:_,  _)  = fail "More than one main found"
    mkProg ([main], bs) = MkProg <$> foldCommands (map Left bs ++ [Right main])

-- | Parse a list of top level declarations
--
-- We return the list of declarations of 'main' separately so that we can
-- construct a single SrcComp in `parseProgram`.
--
parseTopLevel :: BlinkParser ([SrcComp], [SrcComp -> SrcComp])
parseTopLevel =
    withPos cLetDecl' <*> parseLetDecl `bindExtend` \d -> append d <$> more
  where
    more = topLevelSep *> (parseTopLevel <|> return ([], []))

    append (decl, fun) (mains, funs) =
      case decl of
        LetDeclComp Nothing nm c | name nm == "main" -> (c:mains, funs)
        _                                            -> (mains, fun:funs)

    cLetDecl' p d = let (env, f) = cLetDecl p d in (env, (d, f))

topLevelSep :: BlinkParser ()
topLevelSep = many fileNameChange *> optional semi <* many fileNameChange


-- parseProgram :: BlinkParser SrcProg
-- parseProgram = parseTopLevel $
--     join $ mkProg <$ cppPragmas AllowFilenameChange <*> parseTopLevelDecls
--   where
--     mkProg ([],     _)  = fail "No main found"
--     mkProg (_:_:_,  _)  = fail "More than one main found"
--     mkProg ([main], bs) = MkProg <$> foldCommands (map Left bs ++ [Right main])

-- -- | Parse a list of top level declarations
-- --
-- -- We return the list of declarations of 'main' separately so that we can
-- -- construct a single SrcComp in `parseProgram`.
-- --
-- parseTopLevelDecls :: BlinkParser ([SrcComp], [SrcComp -> SrcComp])
-- parseTopLevelDecls =
--     withPos cLetDecl' <*> parseLetDecl `bindExtend` \d -> append d <$> more
--   where
--     more = topLevelSep *> (parseTopLevelDecls <|> return ([], []))

--     append (decl, fun) (mains, funs) =
--       case decl of
--         LetDeclComp Nothing nm c | name nm == "main" -> (c:mains, funs)
--         _                                            -> (mains, fun:funs)

--     cLetDecl' p d = let (env, f) = cLetDecl p d in (env, (d, f))

-- topLevelSep :: BlinkParser ()
-- topLevelSep = many fileNameChange *> optional semi <* many fileNameChange

-- | Parse a computation expression
--
-- > <comp> ::=
-- >     "standalone" <comp>
-- >   | "repeat" <vect-ann>? <comp>
-- >   | "until" <expr> <comp>
-- >   | "while" <expr> <comp>
-- >   | ("unroll" | "nounroll")? "times" <expr> <comp>
-- >   | ("unroll" | "nounroll")? "for" <var-bind> "in" "[" <interval> "]" <comp>
-- >
-- >   | <comp> ">>>" <comp>
-- >   | <comp> "|>>>|" <comp>
-- >
-- >   | <term>
--
-- where
--
-- * the prefix operators `standalone`, `repeat`, `until`, `while`, `times` and
--   `for` all have the same precedence, and all bind stronger than the infix
--   operators `>>>` and `|>>>|`
-- * `>>>` and `|>>>|` are both left associative
-- * `>>>` binds stronger than `|>>>|`
--
-- TODOs:
-- * Is the relative precedence of `>>>` and `|>>>|` intended?
-- * We don't have any tests at all for 'standalone'. Is it obsolete?
parseComp :: BlinkParser SrcComp
parseComp =
    buildExpressionParser table parseCompTerm
  where
    table =
      [ [ xPrefix $ withPos cStandalone <*  reserved "standalone"
        , xPrefix $ withPos cRepeat     <*  reserved "repeat" <*> optVectAnn
        , xPrefix $ withPos cUntil      <*  reserved "until"  <*> parseExpr
        , xPrefix $ withPos cWhile      <*  reserved "while"  <*> parseExpr
        , xPrefix $ withPos cTimes'     <*> timesPref
        , xPrefix $ withPos cTimes'     <*> forPref
        ]
      , [ lInfix $ withPos cPar <*> opMaybePipeline  ]
      , [ lInfix $ withPos cPar <*> opAlwaysPipeline ]
      ]

    cTimes' = uncurry4 . cTimes

-- | A term in a computation expression
--
-- > term ::=
-- >     "(" <comp> ")"
-- >   | "return" <inl-ann>? <expr>"
-- >   | "emit" <expr>
-- >   | "emits" <expr>
-- >   | "takes" <expr>
-- >   | "filter" <expr>
-- >   | "read" <type-ann>?
-- >   | "write" <type-ann>?
-- >   | "map" <vect-ann>? <var-bind>
-- >   | "take"
-- >   | "if" <expr> "then" <comp> "else" <comp>
-- >   | <let-decl> "in" <comp>
-- >   | "do" <stmt-block>
-- >   | "seq"? "{" <commands> "}"
-- >   | <var-or-call>
--
-- `<stmt_block>` comes from the expression language.
parseCompTerm :: BlinkParser SrcComp
parseCompTerm = choice
    [ parens parseComp

    , withPos cReturn' <*> optInlAnn <* reserved "return" <*> parseExpr
    , withPos cEmit'    <* reserved "emit"   <*> parseExpr
    , withPos cEmits'   <* reserved "emits"  <*> parseExpr
    , join $ withPos cTake' <* reserved "takes"  <*> parseExpr
    , withPos cFilter   <* reserved "filter" <*> parseVarBind

    , withPos cReadSrc  <* reserved "read"   <*> optTypeAnn
    , withPos cWriteSnk <* reserved "write"  <*> optTypeAnn
    , withPos cMap      <* reserved "map"    <*> optVectAnn <*> parseVarBind
    , withPos cTake1'   <* reserved "take"

    , withPos cBranch' <* reserved "if"   <*> parseExpr
                       <* reserved "then" <*> parseComp
                       <*> optionMaybe (reserved "else" *> parseComp)
    , withPos cLetDecl <*> parseLetDecl `bindExtend` \f ->
                              f <$ reserved "in" <*> parseComp
    , withPos cReturn' <*> return AutoInline <* reserved "do" <*> parseStmtBlock
    , optional (reserved "seq") >> braces parseCommands

    , parseVarOrCall
    ] <?> "computation"
  where
    cReturn' p = cReturn p
    cEmit'   p = cEmit   p
    cEmits'  p = cEmits  p
    cTake1'  p = cTake1  p SrcTyUnknown

    cTake' p e = do
      case evalInt e of
        Just n  -> return $ cTake p SrcTyUnknown (fromInteger n)
        Nothing -> fail "Non-constant argument to takes"

    cBranch' p cond true (Just false) = cBranch p cond true false
    cBranch' p cond true Nothing      = cBranch p cond true (cunit p)


{-------------------------------------------------------------------------------
  Operators (used to build parseComp)

  These are not assigned non-terminals of their own in the grammar.
-------------------------------------------------------------------------------}

-- > ">>>"
opMaybePipeline :: BlinkParser ParInfo
opMaybePipeline = mkParInfo MaybePipeline <$ reservedOp ">>>"

-- > "|>>>|"
opAlwaysPipeline :: BlinkParser ParInfo
opAlwaysPipeline = mkParInfo (AlwaysPipeline 0 0) <$ reservedOp "|>>>|"

-- > ("unroll" | "nounroll")? "times" <expr>
timesPref :: BlinkParser (UnrollInfo, SrcExp, SrcExp, GName SrcTy)
timesPref =
    (withPos mkTimes <*> parseFor (reserved "times") <*> parseExpr) <?> "times"
  where
    -- NOTE: It doesn't matter that we only have 32-bit iterators here, since
    -- in a 'times' loop the code doesn't get access to the iterator anyway,
    -- so there is no possibility to cast the iterator to a different type.
    mkTimes p ui e =
      let nm = toName "_tmp_count" p tintSrc
      in (ui, eVal p tintSrc (VInt 0), e, nm)

-- > ("unroll" | "nounroll")? "for" <var-bind> "in" "[" <interval> "]"
forPref :: BlinkParser (UnrollInfo, SrcExp, SrcExp, GName SrcTy)
forPref =
    (withPos mkFor <*> parseFor (reserved "for") <*> parseVarBind
                   <* reserved "in" <*> brackets genIntervalParser) <?> "for"
  where
    mkFor _p ui k (estart, elen) = (ui, estart,elen,k)

{-------------------------------------------------------------------------------
  Variable or call
-------------------------------------------------------------------------------}

-- | Variable or function call
parseVarOrCall :: BlinkParser SrcComp
parseVarOrCall = go <?> "variable or function call"
  where
    go = do
      p <- getPosition
      x <- identifier
      let xnm = toName x (Just p) SrcCTyUnknown
      choice [ do notFollowedBy (symbol "(")
                  notFollowedBy (reservedOp "<-")
                  return (cVar (Just p) xnm)
             , withPos (\pos -> cCall pos xnm) <*> parseArgs xnm
             ] <?> "variable or function call"

-- | Parse an argument list
--
-- If `xnm` is not a known defined function, this is simply
--
-- > <arglist> ::= "(" <expr>*"," ")"
--
-- If however `xnm` is a known function we expect a comma-separated list of
-- as many arguments as the function expect, which can either be computations
-- `<comp>` or expressions `<expr>`.
parseArgs :: GName SrcCTy -> BlinkParser [CallArg SrcExp SrcComp]
parseArgs xnm = parens $ do
    penv <- ask
    let spec = case lookup xnm penv of
                 Just argInfo -> map (parseArg . nameTyp) argInfo
                              ++ repeat (CAExp <$> parseExpr)
                 Nothing      -> repeat (CAExp <$> parseExpr)
    spec `sepsBy` comma
  where
    parseArg :: CallArg t tc -> BlinkParser (CallArg SrcExp SrcComp)
    parseArg (CAExp  _) = CAExp  <$> parseExpr
    parseArg (CAComp _) = CAComp <$> parseComp

{-------------------------------------------------------------------------------
  Let statements

  This is the equivalent of GELetDecl and co in the expression parser.
-------------------------------------------------------------------------------}

data GLetDecl tc t a b =
    LetDeclERef (GName t, Maybe (GExp t b))
  | LetDeclStruct (GStructDef t)
  | LetDeclExternal String [GName t] t
  | LetDeclFunComp (Maybe (Int, Int)) (GName tc) [GName (CallArg t tc)] (GComp tc t a b)
  | LetDeclFunExpr (GName t) [GName t] (GExp t b)
  | LetDeclComp (Maybe (Int, Int)) (GName tc) (GComp tc t a b)
  | LetDeclExpr (GName t) (GExp t b)

type LetDecl = GLetDecl SrcCTy SrcTy () ()

-- | The thing that is being declared in a let-statemnt
--
-- Comparable to `parseELetDecl`.
--
-- > <let-decl> ::=
-- >   | <decl>
-- >   | <struct>
-- >   | "let" "external" IDENT <params> ":" <base-type>
-- >   | "fun" <comp-ann> <cvar-bind> <comp-params> "{" <decl>* <commands> "}"
-- >   | "fun" <var-bind> <params> "{" <decl>* <stmts> "}"
-- >   | "let" <comp-ann> <cvar-bind> "=" <comp>
-- >   | "let" <var-bind> "=" <expr>
parseLetDecl :: BlinkParser LetDecl
parseLetDecl = choice
    [ LetDeclERef   <$> declParser
    , LetDeclStruct <$> parseStruct
    , try $ LetDeclExternal <$ reserved "let" <* reserved "external" <*> identifier <*> paramsParser <* reservedOp ":" <*> parseBaseType
    , try $ LetDeclFunComp  <$ reserved "fun" <*> parseCompAnn <*> parseCVarBind <*> compParamsParser <*> braces parseCommands
    , try $ LetDeclFunExpr  <$ reserved "fun"                  <*> parseVarBind <*> paramsParser     <*> braces parseStmts
    , try $ LetDeclComp     <$ reserved "let" <*> parseCompAnn <*> parseCVarBind <* reservedOp "=" <*> parseComp
    , try $ LetDeclExpr     <$ reserved "let"                  <*> parseVarBind <* reservedOp "=" <*> parseExpr
    ]

-- > <struct> ::= "struct" IDENT "=" "{" (IDENT ":" <base-type>)*";" "}"
parseStruct :: BlinkParser (GStructDef SrcTy)
parseStruct = do
    reserved "struct"
    x <- identifier
    reservedOp "="
    braces $ StructDef x <$> parseField `sepBy` semi
  where
    parseField = (,) <$> identifier <* colon <*> parseBaseType

-- | Like `parseVarBind` but for computation types
--
-- > <cvar-bind> ::= IDENT | "(" IDENT ":" <comp-base-type> ")"
parseCVarBind :: BlinkParser (GName SrcCTy)
parseCVarBind = choice
    [ withPos mkName <*> identifier
    , parens $
      withPos mkNameTy <*> identifier <* symbol ":" <*> parseCompBaseType
    ] <?> "variable binding"
  where
    mkName   p i    = toName i p SrcCTyUnknown
    mkNameTy p i ty = toName i p ty

-- | Parameters to a (comp) function
--
-- > <comp-params> ::= "(" (IDENT ":" (<base-type> | <comp-base-type>))*"," ")"
--
-- (<base-type> comes from the expr parser; <comp-base-type> is defined here).
compParamsParser :: BlinkParser [GName (CallArg SrcTy SrcCTy)]
compParamsParser = parens $ sepBy paramParser (symbol ",")
  where
    paramParser = withPos mkParam <*> identifier <* colon <*> parseType
    parseType   = choice [ CAExp  <$> parseBaseType
                         , CAComp <$> parseCompBaseType
                         ] <?> "computation parameter type"

    mkParam p x mty = toName x p mty

-- | Computation type
--
-- > <comp-base-type> ::= "ST" ("T" | "C" <base-type>) <base-type> <base-type>
parseCompBaseType :: BlinkParser SrcCTy
parseCompBaseType = choice
    [ mkCTy <$ reserved "ST" <*> parse_idx <*> parseBaseType <*> parseBaseType
    , parens parseCompBaseType
    ] <?> "computation type"
  where
    parse_idx = choice
      [ Nothing <$ reserved "T"
      , Just    <$ reserved "C" <*> parseBaseType
      , parens parse_idx
      ] <?> "computation type index"

    mkCTy Nothing   ti ty = SrcCTyKnown $ CTTrans ti ty
    mkCTy (Just tv) ti ty = SrcCTyKnown $ CTComp tv ti ty

-- | Smart constructor for LetDecl
--
-- Comparable to `eLetDecl`.
cLetDecl :: Maybe SourcePos -> LetDecl -> (ParseCompEnv, SrcComp -> SrcComp)
cLetDecl p (LetDeclERef (x, e)) =
    ([], cLetERef p x e)
cLetDecl p (LetDeclStruct sdef) =
    ([], cLetStruct p sdef)
cLetDecl p (LetDeclExternal x params ty) =
    ([], cLetHeader p fun)
  where
    fn  = toName x p SrcTyUnknown
    fun = mkFunExternal p fn params ty
cLetDecl p (LetDeclFunComp h x params c) =
    ([(x, params)], cLetFunC p x params (mkVectComp c h))
cLetDecl p (LetDeclFunExpr x params e) =
    ([], cLetHeader p fun)
  where
    fun = mkFunDefined p x params e
cLetDecl p (LetDeclComp h x c) =
    ([], cLet p x (mkVectComp c h))
cLetDecl p (LetDeclExpr x e) =
    ([], cLetE p x AutoInline e)

mkVectComp :: SrcComp -> Maybe (Int,Int) -> SrcComp
mkVectComp sc Nothing  = sc
mkVectComp sc (Just h) = cVectComp (compLoc sc) h sc

{-------------------------------------------------------------------------------
  Commands
-------------------------------------------------------------------------------}

type Command = Either (SrcComp -> SrcComp) SrcComp

-- | A list of commands
--
-- Technically speaking, we cannot give a context free grammar here because the
-- parser for function calls depends on the functions that are in scope.
-- However, we ignore this in the documentation where we simply say
--
-- > <commands> ::= (<command> ";")*
--
-- The last <command> must be a computation.
parseCommands :: BlinkParser SrcComp
parseCommands = foldCommands =<< go
  where
    go   = parseCommand `bindExtend` \c -> (c:) <$> more
    more = optional semi *> (go <|> return [])

foldCommands :: [Command] -> BlinkParser SrcComp
foldCommands []           = error "This cannot happen"
foldCommands [Left _]     = fail "last statement in a seq block should be a computation"
foldCommands [Right c]    = return c
foldCommands (Left k:cs)  = k       <$> foldCommands cs
foldCommands (Right c:cs) = cSeq' c <$> foldCommands cs
  where
    cSeq' c1 c2 = cSeq (compLoc c2) c1 c2

-- | Commands
--
-- Comparable to `parseStmt`.
--
-- > <command> ::=
-- >     <let-decl>
-- >   | <var-bind> "<-" <comp>
-- >   | <comp>
parseCommand :: BlinkParser (ParseCompEnv, Command)
parseCommand = choice
    [ try $ withPos cLetDecl'  <*> parseLetDecl <* notFollowedBy (reserved "in")
    , try $ withPos cBindMany' <*> parseVarBind <* reservedOp "<-" <*> parseComp
    , (\c -> ([], Right c)) <$> parseComp
    ] <?> "command"
  where
    cLetDecl' loc decl = (env, Left k)  -- Used to be: second Left .: cLetDecl
      where (env,k) = cLetDecl loc decl
    cBindMany' loc x c  = ([], Left $ \c' -> cBindMany loc c [(x, c')])

cunit :: Maybe SourcePos -> SrcComp
cunit p = cReturn p ForceInline (eunit p)

{-------------------------------------------------------------------------------
  Annotations
-------------------------------------------------------------------------------}

-- | Optional type annotation
--
-- > <type-ann> ::= "[" <base-type> "]"
optTypeAnn :: BlinkParser SrcTy
optTypeAnn = mkTypeAnn <$> optionMaybe (brackets parseBaseType)
  where
    mkTypeAnn Nothing  = SrcTyUnknown
    mkTypeAnn (Just t) = t

-- | Vectorization annotation
--
-- > <vect-ann> ::= "<="? "!"? <range>
parseVectAnn :: BlinkParser VectAnn
parseVectAnn =
    mkVectAnn <$> optionMaybe (reservedOp "<=") <*> parseVectAnnFlag
  where
    mkVectAnn Nothing   = uncurry Rigid
    mkVectAnn (Just ()) = uncurry UpTo


-- | Parses just the @[(i,j)]@ annotation
parseVectAnnFlag :: BlinkParser (Bool, (Int, Int))
parseVectAnnFlag =
    mkFlag <$> optionMaybe (reservedOp "!") <*> parseRange
  where
    mkFlag Nothing   v = (True,  v)
    mkFlag (Just ()) v = (False, v)

-- | Range
--
-- > <range> ::= "[" <int> "," <int> "]"
parseRange :: BlinkParser (Int, Int)
parseRange = brackets $ mkRange <$> integer <* comma <*> integer
  where
    mkRange i j = (fromInteger i, fromInteger j)

-- | Shorthand for @<vect-ann>?@
optVectAnn :: BlinkParser (Maybe VectAnn)
optVectAnn = optionMaybe parseVectAnn

-- | Shorthand for @<inl-ann>?@
-- > <inl-ann> ::= "forceinline" | "autoinline" | "noinline"
optInlAnn :: BlinkParser ForceInline
optInlAnn = choice
   [ NoInline    <$ reserved "noinline"
   , ForceInline <$ reserved "forceinline"
   , AutoInline  <$ reserved "autoinline"
   , return AutoInline
   ]

-- > <comp-ann> ::= "comp" <range>?
parseCompAnn :: BlinkParser (Maybe (Int, Int))
parseCompAnn = reserved "comp" *> optionMaybe parseRange

