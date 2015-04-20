{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StandaloneDeriving #-}
module Orphans where

import Control.DeepSeq
import Control.DeepSeq.Generics (NFData(..), genericRnf)
import Data.Loc
import Data.Map (Map)
import GHC.Generics (Generic)
import Text.Parsec.Pos
import Text.Parsec.Pos
import Text.Show.Pretty (PrettyVal(..), Value(Con))
import qualified Data.Map as Map

import qualified Text.PrettyPrint.HughesPJ as HughesPJ
import Control.Monad.Error.Class 

{-------------------------------------------------------------------------------
  Generic orphans
-------------------------------------------------------------------------------}

deriving instance Generic Pos
deriving instance Generic Loc
deriving instance Generic SrcLoc

{-------------------------------------------------------------------------------
  PrettyVal orphans
-------------------------------------------------------------------------------}

instance PrettyVal a => PrettyVal (Maybe a)
instance (PrettyVal a, PrettyVal b) => PrettyVal (Either a b)
instance PrettyVal Bool
instance PrettyVal ()

instance PrettyVal Pos
instance PrettyVal Loc
instance PrettyVal SrcLoc

instance PrettyVal SourcePos where
  prettyVal pos = Con (show 'newPos) [
                      prettyVal (sourceName pos)
                    , prettyVal (sourceLine pos)
                    , prettyVal (sourceColumn pos)
                    ]

instance (PrettyVal k, PrettyVal a) => PrettyVal (Map k a) where
  prettyVal mp = Con (show 'Map.toList) [prettyVal (Map.toList mp)]

{-------------------------------------------------------------------------------
  NFData orphans
-------------------------------------------------------------------------------}

instance NFData Pos         where rnf = genericRnf
instance NFData Loc         where rnf = genericRnf
instance NFData SrcLoc      where rnf = genericRnf

instance NFData SourcePos where
  rnf p = let !line = sourceLine p
              !col  = sourceColumn p
              !name = force sourceName
          in ()

{-------------------------------------------------------------------------------
  Error orphans
-------------------------------------------------------------------------------}

instance Error HughesPJ.Doc where
  noMsg  = HughesPJ.empty
  strMsg = HughesPJ.text

instance Eq HughesPJ.Doc where 
  d1 == d2 = show d1 == show d2

instance Ord HughesPJ.Doc where 
  d1 <= d2 = show d1 <= show d2
