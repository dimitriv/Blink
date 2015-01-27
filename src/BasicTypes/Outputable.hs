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
{-# LANGUAGE FlexibleInstances, OverlappingInstances #-}
module Outputable where

import Text.PrettyPrint.HughesPJ
import qualified Data.Map as M

class Outputable a where
  ppr :: a -> Doc

instance Outputable Int where
  ppr = integer . fromIntegral

instance Outputable Integer where
  ppr = integer . fromIntegral

instance Outputable a => Outputable [a] where
  ppr = sep . punctuate comma . map ppr

instance (Outputable a, Outputable b) => Outputable (a,b) where
  ppr (a,b) = parens (ppr a <> comma <+> ppr b)

instance Outputable String where
  ppr = text 

pretty :: Outputable a => a -> String
pretty = show . ppr

instance (Outputable k, Outputable v) => Outputable (M.Map k v) where
  ppr = vcat . map ppr_kv . M.toList
   where ppr_kv (k,v) = ppr k <+> text "|->" <+> ppr v

emptydoc :: Doc 
emptydoc = empty
