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
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}
-- | Lexical analysis
module BlinkLexer (
    braces
  , brackets
  , colon
  , comma
  , commaSep
  , commaSep1
  , fileNameChange
  , float
  , identifier
  , identifier'
  , integer
  , parens
  , reserved
  , reservedOp
  , semi
  , startOfFile
  , stringLiteral
  , symbol
  ) where

import Control.Applicative hiding ((<|>))
import Control.Monad
import Text.Parsec.Prim
import Text.Parsec.Pos
import Text.Parsec.Combinator

import BlinkParseM
import ZiriaLexerMonad

{-------------------------------------------------------------------------------
  Identifiers and literals
-------------------------------------------------------------------------------}

-- | Identifiers
--
-- Note that we allow reserved keywords to be used as identifiers as well (#40)
identifier :: BlinkParser String
identifier = (lClass LVarId <|> lClass LReservedId) <?> "varid"

integer :: BlinkParser Integer
integer = mkInteger <$> optionMaybe (reservedOp "-") <*> (lClass LInteger <?> "integer literal")
  where
    mkInteger :: Maybe () -> String -> Integer
    mkInteger Nothing   str = read str
    mkInteger (Just ()) str = negate (read str)

float :: BlinkParser Double
float = read <$> (lClass LFloat <?> "float literal")

stringLiteral :: BlinkParser String
stringLiteral = read <$> (lClass LString <?> "string literal")

{-------------------------------------------------------------------------------
  Parentheses and co
-------------------------------------------------------------------------------}

parens, braces, brackets :: BlinkParser a -> BlinkParser a
parens   = between (lSpecial "(") (lSpecial ")")
braces   = between (lSpecial "{") (lSpecial "}")
brackets = between (lSpecial "[") (lSpecial "]")

colon :: BlinkParser ()
colon = lReservedOp ":"

comma :: BlinkParser ()
comma = lSpecial ","

semi :: BlinkParser ()
semi = lSpecial ";"

commaSep, commaSep1 :: BlinkParser a -> BlinkParser [a]
commaSep  = (`sepBy`  comma)
commaSep1 = (`sepBy1` comma)

{-------------------------------------------------------------------------------
  Reserved operators
-------------------------------------------------------------------------------}

reservedOp :: String -> BlinkParser ()
reservedOp = lReservedOp

reserved :: String -> BlinkParser ()
reserved = lReservedId

symbol :: String -> BlinkParser ()
symbol = lSpecial

-- Type names are sometimes considered identifiers (for example, in the
-- definition of structs) and sometimes as reserved keywords (for example in
-- types). For now we just treat these all uniformly as identifiers in the
-- lexer, and offer a parser that parses a _specific_ identifier.
identifier' :: String -> BlinkParser ()
identifier' = lVarId

{-------------------------------------------------------------------------------
  Position information
-------------------------------------------------------------------------------}

fileNameChange :: BlinkParser ()
fileNameChange = do
    fn  <- lFileChange
    pos <- getPosition
    setPosition $ setSourceName pos fn

startOfFile :: BlinkParser ()
startOfFile = lSatisfy aux
  where
    aux StartOfFile = Just ()
    aux (L _ _ _)   = Nothing

{-------------------------------------------------------------------------------
  Low-level interface to Alex
-------------------------------------------------------------------------------}

-- | The most primitive function to match against a lexeme
lSatisfy :: (Lexeme -> Maybe a) -> BlinkParser a
lSatisfy getTok = tokenPrim show nextPos getTok
  where
    nextPos :: SourcePos -> Lexeme -> ZiriaStream -> SourcePos
    nextPos pos _tok st =
      case unconsZiriaStream st of
        Nothing           -> pos
        Just (tok', _st') -> updatePos tok' pos

    updatePos :: Lexeme -> SourcePos -> SourcePos
    updatePos (L (AlexPn _ l c) _ _) pos = newPos (sourceName pos) l c
    updatePos StartOfFile            _   = error "unexpected StartOfFile"

lSatisfy' :: (LexemeClass -> String -> Maybe a) -> BlinkParser a
lSatisfy' getTok = lSatisfy getTok'
  where
    getTok' (L _ c s)   = getTok c s
    getTok' StartOfFile = Nothing

lClass :: LexemeClass -> BlinkParser String
lClass c = lSatisfy' $ \c' s -> guard (c' == c) >> return s

lSpecial :: String -> BlinkParser ()
lSpecial s = (lSatisfy' $ \c' s' -> guard (c' == LSpecial && s' == s)) <?> show s

lReservedOp :: String -> BlinkParser ()
lReservedOp s = (lSatisfy' $ \c' s' -> guard (c' == LReservedOp && s' == s)) <?> show s

lReservedId :: String -> BlinkParser ()
lReservedId s = (lSatisfy' $ \c' s' -> guard (c' == LReservedId && s' == s)) <?> show s

lVarId :: String -> BlinkParser ()
lVarId s = (lSatisfy' $ \c' s' -> guard (c' == LVarId && s' == s)) <?> show s

lFileChange :: BlinkParser String
lFileChange = lSatisfy' $ \c' s' -> guard (c' == LFileChange) >> return s'
