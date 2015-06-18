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
{-# LANGUAGE ScopedTypeVariables #-}
module Ziria.Vectorize.VecScaleDn ( doVectCompDD ) where

import Control.Monad.State

import Ziria.BasicTypes.AstComp
import Ziria.BasicTypes.AstExpr
import Ziria.BasicTypes.AstFM
import Ziria.BasicTypes.AstUnlabelled
import Ziria.ComputeType.CtComp
import Ziria.Vectorize.CardAnalysis
import Ziria.Vectorize.VecM
import Ziria.Vectorize.VecSF
import Ziria.Vectorize.VecRewriter

import Opts

doVectCompDD :: DynFlags -> CTy -> LComp -> SFDD -> VecM DelayedVectRes
doVectCompDD dfs cty lcomp (SFDD0 {})
  = vect_dd0 dfs cty lcomp
doVectCompDD dfs cty lcomp (SFDD1 (DivsOf i i0 i1))
  = vect_dd1 dfs cty lcomp i i0 i1
doVectCompDD dfs cty lcomp (SFDD2 (DivsOf j j0 j1))
  = vect_dd2 dfs cty lcomp j j0 j1
doVectCompDD dfs cty lcomp (SFDD3 (DivsOf i i0 i1) (DivsOf j j0 j1))
  = vect_dd3 dfs cty lcomp i i0 i1 j j0 j1


{-------------------------------------------------------------------------------
  [DD0] ==> no rewriting (when i <= 1, j <= 1)
-------------------------------------------------------------------------------}
vect_dd0 :: DynFlags -> CTy -> LComp -> VecM DelayedVectRes
vect_dd0 _ cty lcomp
  = return $ mkSelf lcomp (inTyOfCTy cty) (yldTyOfCTy cty) 

{-------------------------------------------------------------------------------
  [DD1] a^(i0*i1)   -> X ~~~> (a*i0)^i1 -> X
-------------------------------------------------------------------------------}
vect_dd1 :: DynFlags
         -> CTy -> LComp -> Int -> NDiv -> NDiv -> VecM DelayedVectRes
vect_dd1 _ cty lcomp i (NDiv i0) (NDiv i1)
  = mkDVRes zirbody "DD1" loc vin_ty vout_ty
  where
    loc        = compLoc lcomp
    orig_inty  = inTyOfCTy cty
    vin_ty     = mkVectTy orig_inty  arin
    vout_ty    = yldTyOfCTy cty
    arin       = i0

    vin_ty_big = mkVectTy orig_inty i

    act venv st = rwTakeEmitIO venv st lcomp

    zirbody :: VecEnv -> Zr EId
    zirbody venv = do
      let eqtys = vin_ty_big == vin_ty
      xa <- if eqtys then ftake vin_ty else fneweref ("xa" ::: vin_ty_big)
      unless eqtys $
        ftimes zERO i1 $ \cnt -> 
          do x <- ftake vin_ty
             vectAssign xa cnt arin x

      let offin = eint32 (0)
          st    = RwState { rws_in = DoRw xa offin, rws_out = DoNotRw }
      fembed (act venv st)


{-------------------------------------------------------------------------------
  [DD2] X -> b^(j0*j1)   ~~~> X -> (b*j0)^j1
-------------------------------------------------------------------------------}
vect_dd2 :: DynFlags
         -> CTy -> LComp -> Int -> NDiv -> NDiv -> VecM DelayedVectRes
vect_dd2 _ cty lcomp _j (NDiv j0) (NDiv j1)
  = if is_unit_comp 
      then mkDVRes zirbody1 "DD2" loc orig_inty vout_ty
      else mkDVRes zirbody2 "DD2" loc orig_inty vout_ty
  where
    loc        = compLoc lcomp
    orig_inty  = inTyOfCTy cty
    orig_outty = yldTyOfCTy cty
    vout_ty    = mkVectTy orig_outty arout
    arout      = j0

    is_unit_comp = case doneTyOfCTy $ ctComp lcomp of
                      Just TUnit -> True 
                      _ -> False

    vout_ty_big = mkVectTy orig_outty (j0*j1)
    act venv st = rwTakeEmitIO venv st lcomp

    -- Slightly annoying duplication with specal-casing on unit
    zirbody1 :: VecEnv -> Zr ()
    zirbody1 venv = do 
      ya <- fneweref ("ya" ::: vout_ty_big)
      let offout = eint32(0)
          st     = RwState { rws_in = DoNotRw, rws_out = DoRw ya offout }
      (_ :: ()) <- fembed (act venv st)

      if vout_ty == vout_ty_big 
        then femit ya
        else ftimes zERO j1 $ \cnt -> vectEmit ya cnt arout 

    zirbody2 :: VecEnv -> Zr EId
    zirbody2 venv = do 
      ya <- fneweref ("ya" ::: vout_ty_big)
      let offout = eint32(0)
          st     = RwState { rws_in = DoNotRw, rws_out = DoRw ya offout }
      v <- fembed (act venv st)

      if vout_ty == vout_ty_big
        then femit ya
        else ftimes zERO j1 $ \cnt -> vectEmit ya cnt arout

      freturn _aI v


{-------------------------------------------------------------------------------
  [DD3] a^(i0*i1) -> b^(j0*j1) ~~~>    (a*i0)^i1 -> (b*j0)^j1
-------------------------------------------------------------------------------}
vect_dd3 :: DynFlags -> CTy -> LComp
         -> Int -> NDiv -> NDiv
         -> Int -> NDiv -> NDiv -> VecM DelayedVectRes
vect_dd3 _ cty lcomp _i (NDiv i0) (NDiv i1)
                     _j (NDiv j0) (NDiv j1) 
  = if is_unit_comp 
       then mkDVRes zirbody1 "DD3" loc vin_ty vout_ty
       else mkDVRes zirbody2 "DD3" loc vin_ty vout_ty
  where
    loc        = compLoc lcomp
    orig_inty  = inTyOfCTy cty
    orig_outty = yldTyOfCTy cty
    vin_ty     = mkVectTy orig_inty  arin
    vout_ty    = mkVectTy orig_outty arout
    arin       = i0
    arout      = j0

    vin_ty_big  = mkVectTy orig_inty (i0*i1)
    vout_ty_big = mkVectTy orig_outty (j0*j1)

    act venv st = rwTakeEmitIO venv st lcomp

    is_unit_comp = case doneTyOfCTy $ ctComp lcomp of
                      Just TUnit -> True 
                      _ -> False


    zirbody1 :: VecEnv -> Zr ()
    zirbody1 venv = do
      let eqtys = vin_ty_big == vin_ty
      xa <- if eqtys then ftake vin_ty else fneweref ("xa" ::: vin_ty_big)
      unless eqtys $
         ftimes zERO i1 $ \cnt -> 
            do x <- ftake vin_ty
               vectAssign xa cnt arin x

      ya <- fneweref ("ya" ::: vout_ty_big)

      let offin  = eint32 (0)
          offout = eint32 (0) 
          st     = RwState { rws_in = DoRw xa offin, rws_out = DoRw ya offout }

      (_ :: ()) <- fembed (act venv st)


      if vout_ty == vout_ty_big
        then femit ya
        else ftimes zERO j1 $ \cnt -> vectEmit ya cnt arout


    zirbody2 :: VecEnv -> Zr EId
    zirbody2 venv = do
      let eqtys = vin_ty_big == vin_ty
      xa <- if eqtys then ftake vin_ty else fneweref ("xa" ::: vin_ty_big)
      unless eqtys $
         ftimes zERO i1 $ \cnt -> 
            do x <- ftake vin_ty
               vectAssign xa cnt arin x

      ya <- fneweref ("ya" ::: vout_ty_big)

      let offin  = eint32 (0)
          offout = eint32 (0) 
          st     = RwState { rws_in = DoRw xa offin, rws_out = DoRw ya offout }

      v <- fembed (act venv st)

      if vout_ty == vout_ty_big
        then femit ya
        else ftimes zERO j1 $ \cnt -> vectEmit ya cnt arout

      freturn _aI v
