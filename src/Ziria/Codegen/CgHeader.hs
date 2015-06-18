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
{-# LANGUAGE  QuasiQuotes #-}

module Ziria.Codegen.CgHeader where

sKIP, yIELD, dONE, dONEMask :: Int
sKIP  = 0x0
yIELD = 0x1
dONE  = 0x3
dONEMask = yIELD

cONSUME, iMMEDIATE, cONTINUE :: Int
cONSUME   = 0x0
iMMEDIATE = 0x1

-- NB: CONTINUE is used as flags in the outermost go wrapper
-- of the main thread of pipelined programs.
-- See CgSetupThreads.hs for more information.
cONTINUE  = 0x3

inValOf, yldValOf, whatIsOf :: String -> String
-- NB: inVal and yldVal share the same suffix, with the result that
-- inValOf s = yldValOf s, for all s.  This is useful when the yldVal
-- of what component, say c1 in c1 >>> c2, is the inVal of another
-- component (c2)
inValOf      = (++ "_buf")
yldValOf     = (++ "_buf")
whatIsOf     = (++ "_whatIs")

-- Not used:
yldValPtrOf, whatIsPtrOf :: String -> String
yldValPtrOf  = (++ "_yldValPtr")
whatIsPtrOf  = (++ "_whatIsPtr")
-- end not used

initNmOf, tickNmOf, processNmOf, doneValOf :: String -> String
initNmOf     = (++ "_init")
tickNmOf     = (++ "_tick")
processNmOf  = (++ "_process")
doneValOf    = (++ "_doneVal")

globalYldValPtr, globalWhatIsPtr, globalTickNmPtr, globalProcessNmPtr :: String
globalYldValPtr = "__globalYldValPtr"
globalWhatIsPtr = "__globalWhatIsPtr"
globalTickNmPtr = "__globalTickNmPtr"
globalProcessNmPtr = "__globalProcessNmPtr"

globalWhatIs :: String
globalWhatIs = "__globalWhatIs"

globalInHdl, globalYldHdl, globalDoneHdl :: String
globalInHdl   = "__global_"
globalYldHdl  = "__global_"
globalDoneHdl = "__global_"

threadIdOf :: String -> String -> String
threadIdOf ident s = s ++ ident

globalYldVal, globalDoneVal :: String
globalYldVal  = yldValOf globalYldHdl
globalDoneVal = doneValOf globalDoneHdl

cHeader :: String
cHeader = unlines l
  where l = [ "#include \"common.h\""                   -- All required header files are to be added here

            , ""
            , "#define SKIP " ++ show sKIP
            , "#define YIELD " ++ show yIELD
            , "#define DONE " ++ show dONE
            , "#define IMMEDIATE " ++ show iMMEDIATE
            , "#define CONSUME " ++ show cONSUME
            , "#define FALSE 0"
            , "#define TRUE 1"
            , "#define UNIT 0"
            ]
