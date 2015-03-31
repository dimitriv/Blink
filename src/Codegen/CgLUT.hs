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
import Text.Parsec.Pos
import {-# SOURCE #-} CgExpr
import CgMonad
import CgTypes
import Analysis.DataFlow
import Control.Applicative ( (<$>) )
import Data.Maybe ( isJust, fromJust, catMaybes )
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
cMask ce w = assert "cMask" (w <= 32) $ [cexp| $ce & $int:mask|]
  where mask :: Int = 2^w - 1

-- | Cast this variable to bit array pointer.
varToBitArrPtr :: EId -> Cg C.Exp
varToBitArrPtr v = do
  varexp <- lookupVarEnv v
  is_ptr <- isStructPtrType ty
  if isArrayTy ty || is_ptr
      then return [cexp| (typename BitArrPtr) $varexp    |]
      else return [cexp| (typename BitArrPtr) (& $varexp)|]
  where ty = nameTyp v


cgBreakDown :: Int -> C.Exp -> [C.Exp]
-- ^ Breakdown to 64,32,16,8 ... (later we should also add SSE 128/256)
cgBreakDown 8  ptr = [ ptr ]
cgBreakDown 16 ptr = [ [cexp| (typename uint16 *) $ptr |] ]
cgBreakDown 32 ptr = [ [cexp| (typename uint32 *) $ptr |] ]
cgBreakDown 64 ptr = [ [cexp| (typename uint64 *) $ptr |] ]
cgBreakDown n  ptr
  | n - 64 > 0 
  = [cexp| (typename uint64 *) $ptr |] : cgBreakDown (n-64) [cexp| $ptr + 8 |]
  | n - 32 > 0 
  = [cexp| (typename uint32 *) $ptr |] : cgBreakDown (n-32) [cexp| $ptr + 4 |] 
  | n - 16 > 0 
  = [cexp| (typename uint16 *) $ptr |] : cgBreakDown (n-16) [cexp| $ptr + 2 |]
  | n - 8 > 0  
  = [ ptr ]
  | otherwise = []

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
        mk_stmt (v,m,l) = [cstm| * $v = (* $l & * $m) | (* $v & ~ * $m);|]
    in sequence_ $ map (appendStmt . mk_stmt) (zip3 vptrs mptrs lptrs)

cgBitArrRead :: C.Exp -> Int -> Int -> C.Exp -> Cg ()
-- ^ Pre: pos and len are multiples of 8; src, tgt are of type BitArrPtr
cgBitArrRead src_base pos len tgt
  | len >= 288
  = appendStmt $ 
    [cstm| blink_copy((void *) $tgt, $int:byte_len, (void *) $src);|]
  | otherwise
  = sequence_ $ map (appendStmt . mk_stmt) (zip src_ptrs tgt_ptrs)
  where
    src_ptrs      = cgBreakDown len src
    tgt_ptrs      = cgBreakDown len tgt
    mk_stmt (s,t) = [cstm| * $t = * $s;|]
    sidx          = pos `div` 8
    src           = [cexp| & ($src_base[$int:sidx])|]
    byte_len      = (len+7) `div` 8


{----------------------------------------------------------------------------
   Packing index variables (see also Note [LUT Packing Strategy])
----------------------------------------------------------------------------}
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
  | TArray _ base_ty <- nameTyp v
  , Just (lidx,hidx) <- inArrSlice pkg v
  = do base_w <- tyBitWidth base_ty
       let slice_w = (hidx-lidx+1)*base_w -- ^ slice width
       varexp <- lookupVarEnv v
       let tmp_var = [cexp|(($ty:idx_ty) (* $varexp))|]
           slice   = tmp_var `cExpShR` (lidx*base_w) `cMask` slice_w
           rhs     = slice `cExpShL` pos
       appendStmt $ [cstm| $idx |= $rhs; |]
       return (pos+slice_w)
  | otherwise
  = do w <- inVarBitWidth pkg v
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
unpack_idx_var pkg v idx
  | TArray _ base_ty <- nameTyp v
  , Just (lidx,hidx) <- inArrSlice pkg v
  = do base_w <- tyBitWidth base_ty
       vptr <- varToBitArrPtr v
       let slice_w = base_w*(hidx-lidx+1)
       appendStmt $ 
         [cstm|bitArrWrite($idx_ptr,$int:(lidx*base_w),$slice_w,$vptr);|]
       let new_idx = idx `cExpShR` slice_w
       appendStmt $ [cstm| $idx = $new_idx;|]
  | otherwise
  = do w    <- inVarBitWidth pkg v
       vptr <- varToBitArrPtr v
       appendStmt $
         [cstm| bitArrWrite((BitArrPtr) & $idx,0,$int:w,$vptr);|]
       let new_idx = idx `cExpShR` w
       appendStmt $ [cstm| $idx = $new_idx;|]
  where idx_ptr      = [cexp| (BitArrPtr) & $idx |]

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
  return $ [cexp| & tgt[$int:final_byte_idx]|]

  where go [] w       = return w
        go (v:vs) pos = pack_out_var pkg v tgt pos >>= go vs

pack_out_var :: VarUsePkg
             -> (EId, Maybe EId)
             -> C.Exp
             -> Int
             -> Cg Int
pack_out_var _pkg (v,v_asgn_mask) tgt pos = do
  vptr <- varToBitArrPtr v
  total_width <- outVarBitWidth v
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

{----------------------------------------------------------------------------
   Unpacking (byte-aligned) output vars (see aNote [LUT Packing Strategy])
----------------------------------------------------------------------------}

unpackOutVars :: VarUsePkg          -- ^ Usage info
              -> [(EId, Maybe EId)] -- ^ Output vars and assign-masks
              -> C.Exp              -- ^ Already of BitArrPtr type
              -> Cg C.Exp           -- ^ Final BitArrPtr for final result
unpackOutVars pkg outvars src = do
  final_bit_idx <- go outvars 0
  let final_byte_idx = (final_bit_idx + 7) `div` 8
  return $ [cexp| & src[$int:final_byte_idx]|]

  where go [] n      = return n
        go (v:vs) pos = unpack_out_var pkg v src pos >>= go vs

unpack_out_var :: VarUsePkg
               -> (EId, Maybe EId)
               -> C.Exp
               -> Int
               -> Cg Int
unpack_out_var _pkg (v, Nothing) src pos = do
  vptr <- varToBitArrPtr v
  w    <- outVarBitWidth v -- ^ Post: w is multiple of 8
  cgBitArrRead src pos w vptr
  return (pos+w)

unpack_out_var _pkg (v, Just {}) src pos = do
  vptr    <- varToBitArrPtr v
  total_w <- outVarBitWidth v
  let w  = total_w `div` 2
  let mask_ptr = [cexp| & src[$int:((pos+w) `div` 8)]|]
  cgBitArrLUTMask vptr mask_ptr src w
  return (pos + total_w)


{----------------------------------------------------------------------------
   Compile an epxression to LUTs
----------------------------------------------------------------------------}

codeGenLUTExp :: DynFlags
              -> LUTStats  -- ^ LUT stats for the expression to LUT-compile
              -> Exp       -- ^ The expression to LUT-compile
              -> Maybe EId -- ^ If set then use this variable as output
              -> Cg C.Exp
codeGenLUTExp dflags stats e mb_resname

    -- | We simply cannot LUT, fullstop.
  | Left err <- lutShould stats
  = do let msg = text "Compiling without LUT."
       verbose dflags $ cannot_lut (text err) msg
       codeGenExp dflags e

    -- | Below we were forced to LUT although analysis recommends we don't
  | Right False <- lutShould stats
  , lutTableSize stats >= aBSOLUTE_MAX_LUT_SIZE
  = do let msg = text "LUT size way too large, compiling without LUT!"
       verbose dflags $ cannot_lut empty msg
       codeGenExp dflags e

    -- | Otherwise just LUT it
  | otherwise = lutIt

  where
    cannot_lut d what_next
      = vcat [ text "Asked to LUT an expression we would not LUT." <+> d
             , nest 4 (ppr e)
             , text "At location" <+> text (show (expLoc e))
             , what_next ]

    aBSOLUTE_MAX_LUT_SIZE :: Integer
    aBSOLUTE_MAX_LUT_SIZE = 1024 * 1024

    hashGenLUT :: Cg LUTGenInfo
    -- ^ Call genLUT, but use existing LUT if we have compiled
    -- ^ this expression before to a LUT.
    hashGenLUT
      | isDynFlagSet dflags NoLUTHashing = genLUT dflags stats e
      | otherwise
      = do hs <- getLUTHashes
           let h = H.hash (show e)
           case lookup h hs of
             Just clut -> do
               verbose dflags $ text "Expression to LUT is already lutted!"
               return clut
             Nothing -> do
               verbose dflags $ text "Invoking LUT generation (genLUT)"
               lgi <- genLUT dflags stats e
               setLUTHashes $ (h,lgi):hs
               return lgi

    lutIt :: Cg C.Exp
    lutIt = do

      verbose dflags $
        vcat [ text "Creating LUT for expression:"
             , nest 4 $ ppr e
             , nest 4 $ vcat [ text "LUT stats"
                             , ppr stats ] ]

      -- Generate code that will generate the LUT at init
      -- time and return the LUT table name.
      clut <- hashGenLUT

      -- Generate LUT lookup code.
      genLUTLookup dflags stats clut (ctExp e) mb_resname


{----------------------------------------------------------------------------
   Generate the code for looking up a LUT value
----------------------------------------------------------------------------}

genLUTLookup :: DynFlags
             -> LUTStats
             -> LUTGenInfo -- ^ LUT table information
             -> Ty         -- ^ Expression type
             -> Maybe EId  -- ^ If set, store result here
             -> Cg C.Exp
-- ^ Returns () if result has been already stored in mb_resname,
-- ^ otherwise it returns the actual expression.
genLUTLookup _dflags stats lgi ety mb_resname = do
   
   -- | Declare local index variable
   idx <- freshVar "idx"
   idx_ty <- lutIndexTypeByWidth (lutInBitWidth stats)
   appendDecl [cdecl| $ty:idx_ty $id:idx;|]
   appendStmt [cstm| $id:idx = 0;|]

   -- | Pack input variables to index
   let vupkg = lutVarUsePkg stats
   packIdx vupkg (vu_invars vupkg) [cexp|$id:idx|] idx_ty

    -- | LUT lookup and unpack output variables
   let outvars = lgi_masked_outvars lgi
   let lkup_val = [cexp|(typename BitArrPtr) $clut[$id:idx]|]
   cres <- unpackOutVars vupkg outvars lkup_val 

   -- | The result is either an existing output variable or @cres@
   result <- case lutResultInOutVars stats of
     Just v  -> lookupVarEnv v
     Nothing -> do
       let c_ty = codeGenTy ety
           cres_well_typed
             | TUnit     <- ety = [cexp|UNIT|]
             | TArray {} <- ety = [cexp|   ($ty:c_ty) $cres |]
             | otherwise        = [cexp| *(($ty:c_ty) $cres)|]
       return cres_well_typed

   -- | Store the resul if someone has given us a location 
   store_var mb_resname result

   where
     clut = lgi_lut_var lgi
     store_var Nothing cres = return cres
     store_var (Just res_var) cres = do 
        cres_var <- lookupVarEnv res_var
        assignByVal ety ety cres_var cres
        return [cexp|UNIT|]


{----------------------------------------------------------------------------
   Generate the code for generating a LUT 
----------------------------------------------------------------------------}

genLUT :: DynFlags
       -> LUTStats       -- ^ LUT stats and info
       -> Exp            -- ^ The expression to LUT
       -> Cg LUTGenInfo  -- ^ Generated LUT handles
genLUT dflags stats e = do
   let vupkg = lutVarUsePkg stats
       ety   = ctExp e
       c_ty  = codeGenTy ety
       loc   = expLoc e

   clut <- freshVar "clut"
   -- | Temporary variable for one lut entry
   clutentry <- freshVar "clutentry"
   let clutentry_ty = TArray (Literal (lutOutBitWidth stats)) TBit
   -- | LUT index
   cidx <- freshVar "idx"
   cidx_ty <- lutIndexTypeByWidth (lutInBitWidth stats)
   -- | Function name that will populate this LUT
   clutgen <- freshVar "clut_gen"
   -- | Generate mask variables for output
   mask_eids <- mapM genOutVarMask (vu_outvars vupkg)
   (lut_defs,(lut_decls,lut_stms,_)) <-
      collectDefinitions $ inNewBlock $
      genLocalVarInits dflags (vu_allvars vupkg) $
      genLocalMaskInits dflags mask_eids $ do 
         -- | Unpack the index into the input variables
         unpackIdx vupkg (vu_invars vupkg) [cexp|$id:cidx|]
         -- | Debug the LUT
         cgDebugLUTIdxPack [cexp|$id:cidx|] cidx_ty vupkg loc
         -- | Initialize clutentry
         let bit0 = eVal Nothing TBit (VBit False)
         codeGenArrVal clutentry clutentry_ty [bit0] >>= appendDecl
         -- | Instrument e and compile
         e' <- lutInstrument mask_eids e
         ce <- codeGenExp dflags e'
         clut_fin <- packOutVars vupkg mask_eids [cexp| $id:clutentry|]
         -- | The result is either an existing output variable or @clut_fin@
         case lutResultInOutVars stats of
           Just _v -> return ()
           Nothing
             | TArray {} <- ety
             -> assignByVal ety ety [cexp| ($ty:c_ty) $clut_fin   |] ce
             | otherwise
             -> assignByVal ety ety [cexp| *(($ty:c_ty) $clut_fin)|] ce

   -- | make lut entry be 2-byte aligned
   let lutEntryByteLen = ((((lutOutBitWidth stats + 7) `div` 8) + 1) `div` 2) * 2
   let idxLen = (1::Word) `shiftL` (lutInBitWidth stats)
       lutbasety = namedCType $ "calign unsigned char"
       clutDecl = [cdecl| $ty:lutbasety
                              $id:clut[$int:idxLen][$int:lutEntryByteLen];|]
   cbidx <- freshVar "bidx"
   let clutgen_def
         = [cedecl|void $id:clutgen() {
               for($ty:cidx_ty $id:cidx = 0;
                        $id:cidx < $int:idxLen;
                        ($id:cidx)++)
               {
                  $decls:lut_decls
                  unsigned int $id:cbidx;
                  $stms:lut_stms
                  for ($id:cbidx = 0; 
                          $id:cbidx < $int:(lutEntryByteLen); $id:cbidx++) 
                  { 
                      $id:clut[$id:cidx][$id:cbidx] = 
                                      $id:clutentry[$id:cbidx]; 
                  }
               }}
           |]
   appendTopDecl clutDecl
   appendTopDefs lut_defs
   appendTopDef clutgen_def
   return $ LUTGenInfo { lgi_lut_var        = [cexp|$id:clut|]
                       , lgi_lut_gen        = [cstm|$id:clutgen();|]
                       , lgi_masked_outvars = mask_eids }

genOutVarMask :: EId -> Cg (EId, Maybe EId)
-- ^ Generate a new output mask variable
genOutVarMask x
  | isArrayTy x_ty || isStructTy x_ty
  = do bw <- outVarBitWidth x
       let bitarrty = TArray (Literal bw) TBit 
       x_mask  <- freshName (name x ++ "_mask") bitarrty Mut
       return (x, Just x_mask)
  | otherwise = return (x, Nothing)
  where x_ty = nameTyp x

genLocalMaskInits :: DynFlags -> [(EId, Maybe EId)] -> Cg a -> Cg a
-- ^ Declare the mask variables, initialize them and extend the environment
genLocalMaskInits _dfs mask_vars action = do 
  let new_bind (_x,Nothing) = return Nothing
      new_bind (_x,Just mx) = do
         mcx <- freshVar (name mx)
         g <- codeGenArrVal mcx (nameTyp mx) [bIT0]
         appendDecl g
         return $ Just (mx,[cexp|$id:mcx|])
  var_env <- catMaybes <$> mapM new_bind mask_vars
  extendVarEnv var_env action


genLocalVarInits :: DynFlags -> [EId] -> Cg a -> Cg a
-- ^ Declare local variables and extend the environment
genLocalVarInits _dflags variables action = do 
  let new_bind v = do 
         cv <- freshVar (name v); 
         codeGenDeclGroup cv (nameTyp v) >>= appendDecl
         return (v,[cexp|$id:cv|])
  var_env <- mapM new_bind variables
  extendVarEnv var_env action

-- | Debugging lut index packing
cgDebugLUTIdxPack :: C.Exp            -- ^ original index
                  -> C.Type           -- ^ type of index
                  -> VarUsePkg        -- ^ var use info
                  -> Maybe SourcePos  -- ^ location
                  -> Cg ()
cgDebugLUTIdxPack cidx cidx_ty vupkg loc = do
   dbg_cidx <- freshVar "dbg_idx"
   appendDecl [cdecl| $ty:cidx_ty $id:dbg_cidx;|]
   packIdx vupkg (vu_invars vupkg) [cexp|$id:dbg_cidx|] cidx_ty
   appendStmt [cstm| 
     if ($cidx != $id:dbg_cidx) {
        printf("Fatal bug in LUT generation: packIdx/unpackIdx mismatch.\n");
        printf("Location: %s", $string:(show loc));
        exit(-1); } |]


{----------------------------------------------------------------------------
   Instrument an expression to update the assign-masks
----------------------------------------------------------------------------}

bIT0 :: Exp
bIT0 = eVal Nothing TBit (VBit False)

bIT1 :: Exp
bIT1 = eVal Nothing TBit (VBit True)


bitArrRng :: Ty -> LengthInfo -> Int
-- ^ Return the bit width of this array slice
bitArrRng base_ty LISingleton  = tyBitWidth' base_ty
bitArrRng base_ty (LILength n) = n * tyBitWidth' base_ty
bitArrRng _base_ty (LIMeta {}) = panicStr "bitArrRng: can't happen"

tyBitWidth' :: Ty -> Int
tyBitWidth' = runIdentity . tyBitWidth

fldBitArrRng :: [(FldName,Ty)] -> FldName -> (Int, Int)
-- ^ Return the bit interval that this field 
-- ^ corresponds to in a bit array mask
fldBitArrRng vs the_fld = go 0 vs
  where go _ [] = error "fldBitArrRng: not in struct!"
        go n ((f,ty):rest)
          | f == the_fld = (n, tyBitWidth' ty)
          | otherwise    = go (n + tyBitWidth' ty) rest

eBitArrSet :: EId -> Exp -> Int -> Exp
-- ^ Set some bits in this bit array
eBitArrSet bitarr start width 
  = eArrWrite Nothing bitarr_exp start width_linfo arrval
  where 
    bitarr_exp  = eVar Nothing bitarr
    arrval      = eValArr Nothing (replicate width bIT1)
    width_linfo = if width == 1 then LISingleton else LILength width

eMultBy :: Exp -> Int -> Exp
eMultBy e n = eBinOp loc Mult e (eVal loc ety (VInt ni))
  where ety = ctExp e
        loc = expLoc e
        ni  = fromIntegral n

eArrWriteUpdateMask :: EId                -- ^ the array
                    -> [(EId, Maybe EId)] -- ^ the mask map
                    -> Exp                -- ^ start index (pre: pure)
                    -> LengthInfo         -- ^ length info
                    -> [Exp]              -- ^ assignment
eArrWriteUpdateMask x mask_map estart len
  | TArray _ basety      <- nameTyp x
  , Just (Just mask_var) <- lookup x mask_map
  , let start = estart `eMultBy` tyBitWidth' basety
  = [ eBitArrSet mask_var start (bitArrRng basety len) ]
  | otherwise 
  = []

eFldWriteUpdateMask :: EId                -- ^ the struct
                    -> [(EId, Maybe EId)] -- ^ the mask map
                    -> FldName            -- ^ field name
                    -> [Exp]              -- ^ assignment
eFldWriteUpdateMask x mask_map fld
  | TStruct _ fltys      <- nameTyp x
  , Just (Just mask_var) <- lookup x mask_map
  , let (i,j) = fldBitArrRng fltys fld
  , let start = eVal Nothing tint (VInt $ fromIntegral i)
  = [ eBitArrSet mask_var start j ]
  | otherwise 
  = []

-- | Main expression instrumentation
lutInstrument :: [(EId, Maybe EId)] -> Exp -> Cg Exp
lutInstrument mask_eids = mapExpM return return do_asgn
  where
    do_asgn e
      | EAssign elhs erhs <- unExp e
      = do let lval = parse_deref elhs
           (bnds, lval') <- liftLValEffects lval
           es <- procPureLVal mask_eids lval'
           return $ eLetMany bnds $
                    eSeqs (eAssign loc (derefToExp lval') erhs : es)
      | EArrWrite earr estart len rhs <- unExp e
      = do let lval = parse_deref (eArrRead loc earr estart len)
           (bnds, lval') <- liftLValEffects lval
           es <- procPureLVal mask_eids lval'
           let (GDArr _ () de estart' len') = lval
           let earr' = derefToExp de
           return $ eLetMany bnds $
                    eSeqs (eArrWrite loc earr' estart' len' rhs : es)
      | otherwise
      = return e
      where loc = expLoc e

    parse_deref = fromJust . isMutGDerefExp 

procPureLVal :: [(EId, Maybe EId)] -- ^ Mask map
             -> GDerefExp Ty ()    -- ^ LVal
             -> Cg [Exp]           -- ^ Assignments
procPureLVal mask_map (GDVar _loc () x)
  | Just (Just mvar) <- lookup x mask_map
  , let start = eVal Nothing tint (VInt 0)
  , let len   = tyBitWidth' (nameTyp x)
  = return [ eBitArrSet mvar start len ]
  | otherwise = return []
procPureLVal mask_map (GDArr _loc () (GDVar _ () x) estart len)
  = return $ eArrWriteUpdateMask x mask_map estart len
procPureLVal mask_map (GDProj _loc () (GDVar _ () x) fld)
  = return $ eFldWriteUpdateMask x mask_map fld
procPureLVal mask_map (GDArr _loc () d _ _) = procPureLVal mask_map d
procPureLVal mask_map (GDProj _loc () d _)  = procPureLVal mask_map d
procPureLVal _mask_map (GDNewArray {})  = return []
procPureLVal _mask_map (GDNewStruct {}) = return []


liftLValEffects :: GDerefExp Ty () -> Cg ([(EId,Exp)],GDerefExp Ty ())
liftLValEffects d@(GDVar {}) = return ([],d)
liftLValEffects (GDProj loc a de fld) = do
  (bnds,de') <- liftLValEffects de
  return (bnds, GDProj loc a de' fld)
liftLValEffects (GDArr loc a de e len) = do
  nm <- freshName "n" (ctExp e) Imm
  let nmexp = eVar loc nm
  (bnds,de') <- liftLValEffects de
  let bnds' = (nm,e) : bnds
  return (bnds', GDArr loc a de' nmexp len)
liftLValEffects other = return ([],other)


eLetMany :: [(EId,Exp)] -> Exp -> Exp
eLetMany [] e = e
eLetMany ((nm1,e1):bnds) e
  = eLet Nothing nm1 AutoInline e1 (eLetMany bnds e)

eSeqs :: [Exp] -> Exp
eSeqs [e]     = e
eSeqs (e1:es) = eSeq Nothing e1 (eSeqs es)
eSeqs _       = panicStr "eSeqs: empty"

