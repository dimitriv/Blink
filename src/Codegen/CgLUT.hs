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
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE QuasiQuotes #-}
{-# OPTIONS_GHC -Wall #-}

module CgLUT ( codeGenLUTExp ) where

import Opts
import AstExpr
import AstUnlabelled
import CtExpr
import CgMonad
import CgTypes
import Control.Applicative ( (<$>) )
import Data.Loc
import Data.Maybe ( isJust, catMaybes, fromJust )
import Language.C.Quote.C
import qualified Language.C.Syntax as C
import Text.PrettyPrint.HughesPJ 
import LUTAnalysis
import qualified Data.Hashable as H
import PpExpr ()
import Outputable 
import Data.Bits
import Data.Word
import Utils
import Control.Monad.Identity ( runIdentity )

-- import Debug.Trace

{----------------------------------------------------------------------------
   Infrastructure 
----------------------------------------------------------------------------}

lutIndexTypeByWidth :: Monad m => Int -> m C.Type
-- ^ 
-- Input: input width
-- Returns: type to use for the LUT index
-- Note:
--   The default MAX LUT size at the moment (Opts.mAX_LUT_SIZE_DEFAULT)
--   is 256*1024 bytes which is 2^18 entries, so right just above 16
--   bits, when we emit 1 byte worth of output. So we have to be able to
--   support indexes higher than 16 bits.
lutIndexTypeByWidth n
    | n <= 8    = return [cty|typename uint8|]
    | n <= 16   = return [cty|typename uint16|]
    | n <= 32   = return [cty|typename uint32|]
    | otherwise
    = fail "lutIndexTypeByWidth: can use at most 32 bits for the LUT index"

-- | Shift ce by n bits left.
cExpShL :: C.Exp -> Int -> C.Exp
cExpShL ce 0 = ce
cExpShL ce n = [cexp| $ce << $int:n |]

-- | Shift ce by n bits right.
cExpShR :: C.Exp -> Int -> C.Exp
cExpShR ce 0 = ce
cExpShR ce n = [cexp| $ce >> $int:n |]

-- | Keep the low n bits of ce only when ce fits in a register.
cMask :: C.Exp -> Int -> C.Exp
cMask ce w = assert "cMask" (w <= 32 && w >= 0) $ [cexp| $ce & $int:mask|]
  where mask :: Int = 2^w - 1

-- | Cast this variable to bit array pointer.
varToBitArrPtr :: EId -> Cg C.Exp
varToBitArrPtr v = do
  varexp <- lookupVarEnv v
  let is_ptr = isStructPtrType ty
  if isArrayTy ty || is_ptr
      then return [cexp| (typename BitArrPtr) $varexp    |]
      else return [cexp| (typename BitArrPtr) (& $varexp)|]
  where ty = nameTyp v



cgBitArrLUTMask :: C.Exp -- ^ output variable BitArrPtr
                -> C.Exp -- ^ mask BitArrPtr  (1 means 'set')
                -> C.Exp -- ^ LUT entry BitArrPtr
                -> Int   -- ^ BitWidth
                -> Cg ()
-- ^ Implements: vptr = (lptr & mptr) | (vptr & ~ mptr)
cgBitArrLUTMask vptr mptr lptr width
  = let vptrs = cgBreakDown width vptr
        mptrs = cgBreakDown width mptr
        lptrs = cgBreakDown width lptr
        mk_stmt ((v,w),(m,_),(l,_))
          | w == 128
          = [cstm| lutmask128($v,$m,$l);|] -- SSE
          | otherwise
          = [cstm| * $v = (* $l & * $m) | (* $v & ~ * $m);|]

        -- Optimizing for the sparse writes:
        -- mk_stmt (v,m,l) = [cstm| if (*$m) *$v = (* $l & * $m) | (* $v & ~ * $m);|]
        -- Optimizing for the dense writes:
        -- mk_stmt (v,m,l) = [cstm| if (*$m == -1) { *$v = *$l; } else
        --                                        { *$v = (* $l & * $m) | (* $v & ~ * $m);}|]

    in sequence_ $ map (appendStmt . mk_stmt) (zip3 vptrs mptrs lptrs)



{---------------------------------------------------------------------------
   Packing index variables (see also Note [LUT Packing Strategy])
---------------------------------------------------------------------------}
packIdx :: VarUsePkg
        -> [EId]   -- ^ Variables to pack
        -> C.Exp   -- ^ A C expression for the index variable
        -> C.Type  -- ^ The actual index type (lutIndeTypeByWidth)
        -> Cg ()
packIdx pkg invars idx idx_ty = go invars 0
  where go [] _w    = return ()
        go (v:vs) w = pack_idx_var pkg v idx idx_ty w >>= go vs

pack_idx_var :: VarUsePkg -- ^ Variable use package
             -> EId       -- ^ Variable to pack
             -> C.Exp     -- ^ Index
             -> C.Type    -- ^ Index type (lutIndexTypeByWidth)
             -> Int       -- ^ Offset to place the variable at
             -> Cg Int    -- ^ Final offset (for the next variable)
pack_idx_var pkg v idx idx_ty pos
  | Just (vstart',vlen') <- inArrSliceBitWidth pkg v
  , let vstart :: Int = fromIntegral vstart'
  , let vlen   :: Int = fromIntegral vlen'
  = do varexp <- lookupVarEnv v -- must be pointer! 
       let byte_start = vstart `div` 8

           -- | NB: Observe the uint32 below. Why?
           -- We will do the calculation with uint32 because if we
           -- start addressing in this particular position we may have
           -- to spill over to the next byte -- so cast the current 
           -- location to a pointer for the maximum index type (uint32), 
           -- and only once you've got the final value truncate
           -- back. Sigh ...
       let cast_ty = [cty| $ty:idx_ty * |]
{- 
               if vlen <= 8  then [cty| typename uint8*  |] else 
               if vlen <= 16 then [cty| typename uint16* |] else [cty|typename uint32*|]
-}
           tmp_var = [cexp| ( * ($ty:cast_ty) 
                                              (& ((typename BitArrPtr) $varexp)[$int:byte_start]))
                     |]

           slice_shift = vstart - byte_start * 8
           slice   = tmp_var `cExpShR` slice_shift `cMask` vlen
           rhs     = slice `cExpShL` pos
       appendStmt $ [cstm| $idx |= ( $ty:idx_ty ) $rhs; |]
       return (pos+vlen)
  | isArrayTy (nameTyp v)
  = do w <- fromIntegral <$> inVarBitWidth pkg v
       varexp <- lookupVarEnv v
       let tmp_var = [cexp| * ($ty:idx_ty *) $varexp |]
       let rhs = tmp_var `cMask` w `cExpShL` pos
       appendStmt $ [cstm| $idx |= ( $ty:idx_ty ) $rhs; |]
       return (pos+w)

  | otherwise
  = do w <- fromIntegral <$> inVarBitWidth pkg v
       varexp <- lookupVarEnv v
       let rhs = [cexp|(($ty:idx_ty) $varexp)|] `cMask` w `cExpShL` pos
       appendStmt $ [cstm| $idx |= $rhs; |]
       return (pos+w)

{----------------------------------------------------------------------------
   Unpacking index variables (see also Note [LUT Packing Strategy])
----------------------------------------------------------------------------}
unpackIdx :: VarUsePkg 
          -> [EId]     -- ^ Variables to unpack
          -> C.Exp     -- ^ A C expression for the index variable
          -> Cg ()
-- ^ NB: Destructively updates the index variable!
unpackIdx pkg invars idx = go invars
  where go []     = return ()
        go (v:vs) = unpack_idx_var pkg v idx >> go vs

unpack_idx_var :: VarUsePkg -- ^ Variable use package
               -> EId       -- ^ Variable to pack
               -> C.Exp     -- ^ Index
               -> Cg ()     -- ^ Final offset (for the next variable)
-- ^ NB: Unpacking index variables is not performance critical since
-- it is only used during LUT generation but not during execution. So
-- there aren't any clever fast paths here.
-- ^ NB: Mutates the index
unpack_idx_var pkg v idx
  | Just (vstart',vlen') <- inArrSliceBitWidth pkg v
  , let vstart :: Int = fromIntegral vstart'
  , let vlen   :: Int = fromIntegral vlen'
  = do vptr <- varToBitArrPtr v
       appendStmt $ 
         [cstm|bitArrWrite($idx_ptr,$int:vstart,$int:vlen,$vptr);|]
       let new_idx = idx `cExpShR` vlen
       appendStmt $ [cstm| $idx = $new_idx;|]
  | otherwise
  = do w    <- fromIntegral <$> inVarBitWidth pkg v
       vptr <- varToBitArrPtr v
       appendStmt $ [cstm| memset($vptr,0, $int:((w + 7) `div` 8));|]
       appendStmt $
         [cstm| bitArrWrite($idx_ptr,0,$int:w,$vptr);|]
       let new_idx = idx `cExpShR` w
       appendStmt $ [cstm| $idx = $new_idx;|]
  where idx_ptr      = [cexp| (typename BitArrPtr) & $idx |]

{----------------------------------------------------------------------------
   Packing (byte-aligned) output variables (see Note [LUT Packing Strategy])
----------------------------------------------------------------------------}

packOutVars :: VarUsePkg          -- ^ Usage info
            -> [(EId, Maybe EId)] -- ^ Output vars and assign-masks 
                                 --  ^ NB: Masks are of type BitArrPtr
            -> C.Exp              -- ^ Of BitArrPtr type
            -> Cg C.Exp           -- ^ Final BitArrPtr for final result
-- ^ NB: This is not perf critical as it is only used for LUT generation.
packOutVars pkg outvars tgt = do
  final_bit_idx <- go outvars 0
  let final_byte_idx = (final_bit_idx + 7) `div` 8
  return $ [cexp| & $tgt[$int:final_byte_idx]|]

  where go [] w       = return w
        go (v:vs) pos = pack_out_var pkg v tgt pos >>= go vs

pack_out_var :: VarUsePkg
             -> (EId, Maybe EId)
             -> C.Exp
             -> Int
             -> Cg Int
pack_out_var pkg (v,v_asgn_mask) tgt pos = do
  vptr <- varToBitArrPtr v
  total_width <- fromIntegral <$> outVarBitWidth (vu_ranges pkg) v
  -- ^ NB: w includes width for v_asgn_mask already!
  let w = if isJust v_asgn_mask then total_width `div` 2 else total_width
  appendStmt [cstm|bitArrWrite($vptr,$int:pos,$int:w,$tgt); |]
  -- | Write the mask if there is one
  case v_asgn_mask of
    Just v' -> do 
      vexp' <- lookupVarEnv v'
      appendStmt [cstm| bitArrWrite($vexp',$int:(pos+w),$int:w,$tgt);|]
    Nothing -> return ()
  -- | Return new position
  return (pos+total_width)

{---------------------------------------------------------------------------
   Unpacking (byte-aligned) output vars (see aNote [LUT Packing Strategy])
---------------------------------------------------------------------------}

unpackOutVars :: VarUsePkg          -- ^ Usage info
              -> [(EId, Maybe EId)] -- ^ Output vars and assign-masks
              -> C.Exp              -- ^ Already of BitArrPtr type
              -> Cg C.Exp           -- ^ Final BitArrPtr for final result
unpackOutVars pkg outvars src = do
  final_bit_idx <- go outvars 0
  let final_byte_idx = (final_bit_idx + 7) `div` 8
  return $ [cexp| & $src[$int:final_byte_idx]|]

  where go [] n      = return n
        go (v:vs) pos = unpack_out_var pkg v src pos >>= go vs

unpack_out_var :: VarUsePkg
               -> (EId, Maybe EId)
               -> C.Exp
               -> Int
               -> Cg Int
unpack_out_var pkg (v, Nothing) src pos = do
  vptr <- varToBitArrPtr v
  w    <- fromIntegral <$> outVarBitWidth (vu_ranges pkg) v -- ^ Post: w is multiple of 8
  cgBitArrRead src pos w vptr
  return (pos+w)

unpack_out_var pkg (v, Just {}) src pos = do
  vptr    <- varToBitArrPtr v
  total_w <- fromIntegral <$> outVarBitWidth (vu_ranges pkg) v
  let w  = total_w `div` 2
  let mask_ptr = [cexp| & $src[$int:((pos+w) `div` 8)]|]
  let src_ptr  = [cexp| & $src[$int:(pos `div` 8)]     |]
  cgBitArrLUTMask vptr mask_ptr src_ptr w
  return (pos + total_w)


{---------------------------------------------------------------------------
   Compile an epxression to LUTs
---------------------------------------------------------------------------}

codeGenLUTExp :: CodeGen   -- ^ Main code generator 
              -> DynFlags
              -> LUTStats  -- ^ LUT stats for the expression to LUT-compile
              -> Exp       -- ^ The expression to LUT-compile
              -> Maybe EId -- ^ If set then use this variable as output
              -> Cg C.Exp
codeGenLUTExp cg_expr dflags stats e mb_resname

    -- | We simply cannot LUT, fullstop.
  | Left err <- lutShould stats
  = do let msg = text "Compiling without LUT."
       verbose dflags $ cannot_lut (text err) msg
       cg_expr dflags e

    -- | Below we were forced to LUT although analysis recommends we don't
  | Right False <- lutShould stats
  , lutTableSize stats >= aBSOLUTE_MAX_LUT_SIZE
  = do let msg = text "LUT size way too large, compiling without LUT!"
       verbose dflags $ cannot_lut empty msg
       cg_expr dflags e

    -- | Otherwise just LUT it
  | otherwise = lutIt

  where
    cannot_lut d what_next
      = vcat [ text "Asked to LUT an expression we would not LUT." <+> d
             , nest 4 (ppr e)
             , text "At location" <+> ppr (expLoc e)
             , what_next ]

    aBSOLUTE_MAX_LUT_SIZE :: Integer
    aBSOLUTE_MAX_LUT_SIZE = 1024 * 1024

    hashGenLUT :: Cg LUTGenInfo
    -- ^ Call genLUT, but use existing LUT if we have compiled
    -- ^ this expression before to a LUT.
    hashGenLUT
      | isDynFlagSet dflags NoLUTHashing = genLUT cg_expr dflags stats e
      | otherwise
      = do hs <- getLUTHashes
           let h = H.hash (show e)
           case lookup h hs of
             Just clut -> do
               verbose dflags $ 
                 vcat [ text "Expression to LUT is already lutted!"
                      , text "At location" <+> ppr (expLoc e)
                      ]
               return clut
             Nothing -> do
               verbose dflags $
                 vcat [ text "Creating LUT for expression:"
                      , nest 4 $ ppr e
                      , nest 4 $ vcat [ text "LUT stats"
                                      , ppr stats ] ]

               lgi <- genLUT cg_expr dflags stats e
               setLUTHashes $ (h,lgi):hs
               return lgi

    lutIt :: Cg C.Exp
    lutIt = do
      clut <- hashGenLUT
      -- Do generate LUT lookup code.
      genLUTLookup dflags (expLoc e) stats clut (ctExp e) mb_resname


{---------------------------------------------------------------------------
   Generate the code for looking up a LUT value
---------------------------------------------------------------------------}

genLUTLookup :: DynFlags
             -> SrcLoc
             -> LUTStats
             -> LUTGenInfo -- ^ LUT table information
             -> Ty         -- ^ Expression type
             -> Maybe EId  -- ^ If set, store result here
             -> Cg C.Exp
-- ^ Returns () if result has been already stored in mb_resname,
-- ^ otherwise it returns the actual expression.
genLUTLookup _dflags _loc stats lgi ety mb_resname = do
   
   -- | Declare local index variable
   idx <- freshVar "idx"
   idx_ty <- lutIndexTypeByWidth (fromIntegral $ lutInBitWidth stats)
   appendDecl [cdecl| $ty:idx_ty $id:idx;|]
   -- | Initialize the index to 0 entry in case invars is empty!
   appendStmt [cstm| $id:idx = 0;|]

   -- | Pack input variables to index
   let vupkg = lutVarUsePkg stats

   packIdx vupkg (vu_invars vupkg) [cexp|$id:idx|] idx_ty

   -- DEBUG: appendStmt [cstm| printf("lut index = %d",$id:idx);|]

    -- | LUT lookup and unpack output variables
   let outvars = lgi_masked_outvars lgi
   let lkup_val = [cexp|(typename BitArrPtr) $clut[$id:idx]|]

   cres <- unpackOutVars vupkg outvars lkup_val 

   -- | The result is either an existing output variable or @cres@
   result <- case lutResultInOutVars stats of
     Just v  -> lookupVarEnv v
     Nothing -> do
       let c_ty = codeGenTyOcc ety 
           -- NB: See LUTAnalysis (non-nested arrays in LUT output types)
           cres_well_typed
             | TUnit     <- ety = [cexp|UNIT|]
             | TArray {} <- ety = [cexp|   ($ty:c_ty)   $cres |]
             | otherwise        = [cexp| *(($ty:c_ty *) $cres)|]
       return cres_well_typed
   -- | Store the result if someone has given us a location 
   store_var mb_resname ety result

   where
     clut = lgi_lut_var lgi

store_var :: Maybe EId -> Ty -> C.Exp -> Cg C.Exp
-- | If (Just var) then store the result in this var 
-- and return unit else return result
store_var Nothing _ety cres = return cres
store_var (Just res_var) ety cres = do 
   cres_var <- lookupVarEnv res_var
   assignByVal ety cres_var cres
   return [cexp|UNIT|]


{---------------------------------------------------------------------------
   Generate the code for generating a LUT 
---------------------------------------------------------------------------}

genLUT :: CodeGen        -- ^ Main code generator
       -> DynFlags
       -> LUTStats       -- ^ LUT stats and info
       -> Exp            -- ^ The expression to LUT
       -> Cg LUTGenInfo  -- ^ Generated LUT handles
genLUT cg_expr dflags stats e = do
   let vupkg = lutVarUsePkg stats
       ety   = ctExp e
       -- NB: ety is a non-nested array (if an array), see LUTAnalysis
       c_ty  = codeGenTyOcc ety 
       loc   = expLoc e

       lutInBw  = fromIntegral (lutInBitWidth stats)
       lutOutBw = fromIntegral (lutOutBitWidth stats)
  
   clut <- freshVar "clut"
   -- | Temporary variable for one lut entry
   clutentry <- freshVar "clutentry"
   let clutentry_ty = TArray (Literal lutOutBw) TBit
   -- | LUT index
   cidx <- freshVar "idx"
   cidx_ty <- lutIndexTypeByWidth lutInBw
   -- | Function name that will populate this LUT
   clutgen <- freshVar "clut_gen"
   -- | Generate mask variables for output
   mask_eids <- mapM (genOutVarMask (vu_ranges vupkg)) (vu_outvars vupkg)
   (lut_defs,(lut_decls,lut_stms,_)) <-
      collectDefinitions $ inNewBlock $
      genLocalVarInits dflags (vu_allvars vupkg) $
      genLocalMaskInits dflags mask_eids $ do 
         -- | Unpack the index into the input variables
         -- However, since unpacking is mutating the index we
         -- first have to copy the index to debug later.
         orig_cidx <- freshVar "orig_idx"
         appendDecl [cdecl| $ty:cidx_ty $id:orig_cidx;|]
         appendStmt [cstm|  $id:orig_cidx = $id:cidx; |]
         unpackIdx vupkg (vu_invars vupkg) [cexp|$id:orig_cidx|]
         -- | Debug the LUT
         cgDebugLUTIdxPack [cexp|$id:cidx|] cidx_ty vupkg loc
         -- | Initialize clutentry
         appendCodeGenDeclGroup clutentry clutentry_ty ZeroOut

         -- | Instrument e and compile
         e' <- lutInstrument mask_eids e
         ce <- cg_expr dflags e'
         clut_fin <- packOutVars vupkg mask_eids [cexp| $id:clutentry|]

         -- | For debugging let us try to unpack to the outvars
         _ <- unpackOutVars vupkg mask_eids [cexp|$id:clutentry|]
         dbg_clutentry <- freshVar "dbg_lutentry"
         appendCodeGenDeclGroup dbg_clutentry clutentry_ty ZeroOut

         _ <- packOutVars vupkg mask_eids [cexp| $id:dbg_clutentry|]
         appendStmt $
            [cstm| if (0 != memcmp($id:dbg_clutentry,
                                   $id:clutentry,
                                   $int:(lutOutBitWidth stats `div` 8))) {
                     printf("Fatal bug in LUT generation: un/packOutVars mismatch.\n");
                     printf("Location: %s\n", $string:(displayLoc (locOf loc)));
                     exit(-1);
                   }
            |]

         -- | The result is either an existing output variable or @clut_fin@
         case lutResultInOutVars stats of
           Just _v -> return ()
           Nothing
             | TUnit <- ety
             -> return ()
             | TArray {} <- ety
             -> assignByVal ety [cexp| ($ty:c_ty) $clut_fin |] ce
             | otherwise
             -> assignByVal ety [cexp| *(($ty:c_ty *) $clut_fin)|] ce

   -- | make lut entry be 2-byte aligned
   let lutEntryByteLen 
        = ((((lutOutBw + 7) `div` 8) + 1) `div` 2) * 2
   let idxLen = (1::Word) `shiftL` lutInBw
       lutbasety = namedCType $ "calign unsigned char"
       clutDecl = [cdecl| $ty:lutbasety
                              $id:clut[$int:idxLen][$int:lutEntryByteLen];|]
   cbidx <- freshVar "bidx"

   -- | LUT Generation Function Proper
   let clutgen_def
         = [cedecl|void $id:clutgen() {
               for (unsigned long _lidx = 0; _lidx < $int:idxLen; _lidx++)
               {
                  $ty:cidx_ty $id:cidx = ($ty:cidx_ty) _lidx;

                  $decls:lut_decls
                  unsigned int $id:cbidx;
                  $stms:lut_stms
                  for ($id:cbidx = 0; 
                          $id:cbidx < $int:(lutEntryByteLen); $id:cbidx++) 
                  { 
                      $id:clut[$id:cidx][$id:cbidx] = 
                                      $id:clutentry[$id:cbidx]; 
                  }

               }
           }
           |]
   appendTopDecl clutDecl
   appendTopDefs lut_defs
   appendTopDef clutgen_def
   return $ LUTGenInfo { lgi_lut_var        = [cexp|$id:clut|]
                       , lgi_lut_gen        = [cstm|$id:clutgen();|]
                       , lgi_masked_outvars = mask_eids }

genOutVarMask :: RngMap -> EId -> Cg (EId, Maybe EId)
-- ^ Generate a new output mask variable
genOutVarMask rmap x = 
  case outVarMaskWidth rmap x x_ty of
    Nothing -> return (x, Nothing)
    Just bw -> do
      let bitarrty = TArray (Literal $ fromIntegral bw) TBit
      x_mask  <- freshName (name x ++ "_mask") bitarrty Mut
      return (x, Just x_mask)
  where x_ty = nameTyp x

genLocalMaskInits :: DynFlags -> [(EId, Maybe EId)] -> Cg a -> Cg a
-- ^ Declare the mask variables, initialize them and extend the environment
genLocalMaskInits _dfs mask_vars action = do 
  let new_bind (_x,Nothing) = return Nothing
      new_bind (_x,Just mx) = do
         mcx <- freshVar (name mx)
         appendCodeGenDeclGroup mcx (nameTyp mx) ZeroOut
         return $ Just (mx,[cexp|$id:mcx|])
  var_env <- catMaybes <$> mapM new_bind mask_vars
  extendVarEnv var_env action


genLocalVarInits :: DynFlags -> [EId] -> Cg a -> Cg a
-- ^ Declare local variables and extend the environment
genLocalVarInits _dflags variables action = do 
  let new_bind v = do 
         cv <- freshVar (name v); 
         appendCodeGenDeclGroup cv (nameTyp v) ZeroOut
         return (v,[cexp|$id:cv|])
  var_env <- mapM new_bind variables
  extendVarEnv var_env action

-- | Debugging lut index packing
cgDebugLUTIdxPack :: C.Exp            -- ^ original index
                  -> C.Type           -- ^ type of index
                  -> VarUsePkg        -- ^ var use info
                  -> SrcLoc           -- ^ location
                  -> Cg ()
cgDebugLUTIdxPack cidx cidx_ty vupkg loc = do
   dbg_cidx <- freshVar "dbg_idx"
   appendDecl [cdecl| $ty:cidx_ty $id:dbg_cidx = 0;|]
   packIdx vupkg (vu_invars vupkg) [cexp|$id:dbg_cidx|] cidx_ty
   appendStmt [cstm| 
     if ($cidx != $id:dbg_cidx) {
        printf("Fatal bug in LUT generation: packIdx/unpackIdx mismatch.\n");
        printf("Location: %s\n", $string:(displayLoc (locOf loc)));
        exit(-1); } |]


{---------------------------------------------------------------------------
   Instrument an expression to update the assign-masks
---------------------------------------------------------------------------}

bIT1 :: Exp
bIT1 = eVal noLoc TBit (VBit True)

tyBitWidth' :: Ty -> Int
tyBitWidth' t = fromIntegral $ runIdentity (tyBitWidth t)

eMultBy :: Exp -> Int -> Exp
eMultBy e n = eBinOp loc Mult e (eVal loc ety (VInt ni Signed))
  where ety = ctExp e
        loc = expLoc e
        ni  = fromIntegral n

eAddBy :: Exp -> Int -> Exp
eAddBy e n = eBinOp loc Add e (eVal loc ety (VInt ni Signed))
  where ety = ctExp e
        loc = expLoc e
        ni  = fromIntegral n

----------------------------------------------------------------------------

-- | Return the bit width of this array slice
bitArrRng :: Ty -> LengthInfo -> Int
bitArrRng base_ty LISingleton  = tyBitWidth' base_ty
bitArrRng base_ty (LILength n) = n * tyBitWidth' base_ty
bitArrRng _base_ty (LIMeta {}) = panicStr "bitArrRng: can't happen"

-- | Return the bit interval that this field corresponds to.
fldBitArrRng :: [(FldName,Ty)] -> FldName -> (Int, Int)
fldBitArrRng vs the_fld = go 0 vs
  where go _ [] = error "fldBitArrRng: not in struct!"
        go n ((f,ty):rest)
          | f == the_fld = (n, tyBitWidth' ty)
          | otherwise    = go (n + tyBitWidth' ty) rest

-- | Set some bits in this bit array
eBitArrSet :: EId -> Exp -> Int -> Exp
eBitArrSet bitarr start width 
  = eArrWrite noLoc bitarr_exp start width_linfo arrval
  where
   bitarr_exp = eVar noLoc bitarr
   (arrval, width_linfo)
     | width == 1 = (bIT1,                LISingleton   )
     | otherwise  = (eValArr noLoc bIT1s, LILength width)
   bIT1s = replicate width bIT1


-- | Expression instrumentation, see also Note [LUT OutOfRangeTests]
lutInstrument :: [(EId, Maybe EId)] -> Exp -> Cg Exp
lutInstrument mask_eids = mapExpM return return do_instr
  where
    do_instr e
      | EAssign elhs erhs <- unExp e 
      = do let lval = fromJust $ isMutGDerefExp elhs
           instrAsgn mask_eids loc lval erhs
      | EArrWrite earr es l erhs <- unExp e
      = do let lval = fromJust $ isMutGDerefExp (eArrRead loc earr es l)
           instrAsgn mask_eids loc lval erhs
      | EPrint nl eargs <- unExp e
      = return $ ePrint loc nl (eargs ++ [io_msg])
      | otherwise = return e
    -- NB: we should also be checking for EArrRead or we may get access violations?
      where loc = expLoc e 
            io_msg = eVal loc TString (VString " (NB: IO from LUT _generator_)")

int32Val :: Int -> Exp
int32Val n = eVal noLoc tint (VInt (fromIntegral n) Signed)

instrAsgn :: [(EId, Maybe EId)] -> SrcLoc 
          -> LVal Exp -> Exp -> Cg Exp
instrAsgn mask_eids loc d' erhs' = do
  (bnds, eassigns) <- instrLVal loc mask_eids d'
  let eassign = mk_asgn d' erhs'
  return $ mk_lets bnds $ eseqs (eassign : eassigns)
  where 
    mk_asgn (GDArr d es l) erhs = eArrWrite loc (derefToExp loc d) es l erhs
    mk_asgn d erhs              = eAssign loc (derefToExp loc d) erhs

    mk_lets [] ebody = ebody
    mk_lets ((x,e,test):bnds) ebody =
      eLet loc x AutoInline e $ eIf loc test (mk_lets bnds ebody) eunit
    eunit = eVal loc TUnit VUnit -- Too verbose: ePrint loc True [emsg]
    -- emsg  = eVal loc TString (VString "Bounds exceeded during LUT generation!")

    eseqs :: [Exp] -> Exp
    eseqs [e]    = e
    eseqs (e:es) = eSeq loc e (eseqs es)
    eseqs []     = panicStr "eseqs: empty"


-- | MaskRange: a compact representation of bitmasks 
data MaskRange 
  = -- | Full range
    MRFull
    -- | Field projection
  | MRField [(FldName,Ty)] MaskRange FldName
    -- | Array slice (Ty is the *element* type of array)
  | MRArr Ty MaskRange Exp LengthInfo

maskRangeToRng :: Int         -- ^ Full mask bitwidth
               -> MaskRange   -- ^ Range to set
               -> (Exp, Int)  -- ^ Width to set
maskRangeToRng width = go
  where
    go MRFull 
      = (int32Val 0, width)

    go (MRField fltys mr fld) 
      = let (offset,_) = go mr                  
            (i,j)      = fldBitArrRng fltys fld
        in (offset `eAddBy` i, j)

    go (MRArr basety mr estart len) =
       let (offset,_)  = go mr
           blen         = bitArrRng basety len
           sidx        = estart `eMultBy` tyBitWidth' basety
       in (eBinOp noLoc Add offset sidx, blen)
       
writeMask :: EId
          -> [(EId,Maybe EId)]
          -> MaskRange
          -> [Exp]
writeMask x mask_map rng 
  | Just (Just mask_var) <- lookup x mask_map
                               -- outVarMaskWidth (nameTyp x)
  , Just w <- fromIntegral <$> tyBitWidth_ByteAlign (nameTyp x) 
  , let (estart,mask_len) = maskRangeToRng w rng
  = [eBitArrSet mask_var estart mask_len]
  | otherwise
  = []

-- | Instrument an lvalue for assignment. Mainly two things
--   a) write the appropriate range in the corresponding bitmask
--   b) guard for out-of-bounds writing
instrLVal :: SrcLoc
          -> [(EId, Maybe EId)] -> LVal Exp -> Cg ([(EId,Exp,Exp)], [Exp])
-- Returns let binding, numerical expression, bounds-check plus a set
-- of assignments.
instrLVal loc ms lval = go lval [] MRFull
  where
    go (GDVar x) bnds r = return (bnds, writeMask x ms r)

    go (GDProj d fld) bnds r = do
      let TStruct _ tflds = ctDerefExp d
      go d bnds (MRField tflds r fld)

    go (GDArr d estart l) bnds r = do
      tmp <- freshName "tmp" (ctExp estart) Imm
      let tmpexp = eVar loc tmp
          TArray (Literal arrsiz) basety = ctDerefExp d
          rngtest = mk_rangetest arrsiz tmpexp l
      go d ((tmp,estart,rngtest):bnds) (MRArr basety r tmpexp l)

    mk_rangetest :: Int           -- ^ array size
                 -> Exp           -- ^ start expression
                 -> LengthInfo    -- ^ length to address
                 -> Exp           -- ^ boolean check
    mk_rangetest array_len estart len = case len of 
      LISingleton -> 
             eBinOp loc And estart_non_neg $
             eBinOp loc Lt estart earray_len
      LILength n  -> 
             eBinOp loc And estart_non_neg $
             eBinOp loc Leq (eAddBy estart n) earray_len
      LIMeta {}   -> panicStr "mk_rangetest: LIMeta!"
      where earray_len = eVal loc (ctExp estart) varray_len
            varray_len = VInt (fromIntegral array_len) Signed
            estart_non_neg = eBinOp loc Geq estart $ 
                             eVal loc (ctExp estart) (VInt 0 Signed)






{- | Note [LUT OutOfRangeTests]
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~

   When we generate a LUT we are possibly iterating over the full
   input space e.g. a 32-bit integer. However, in an actual execution,
   because of some programmer invariant the actual space of inputs we
   care about may be smaller -- e.g. because of some complex programmer
   invariant -- and our analysis cannot necessarily detect that. However
   we must avoid out-of-bounds writes, hence we have to implement dynamic
   checks for in-bounds-ranges and not perform potentially dangerous
   out-of-bounds memory accesses.

-}

