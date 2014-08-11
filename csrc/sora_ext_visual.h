/* 
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
*/
#include <stdio.h>
#include "types.h"
#include "numerics.h"
#include "DebugPlotU.h"

FINL void initDbgPlot();
int32 __ext_dbgplot_real_line(int16 *item, int len);
int32 __ext_dbgplot_complex_line(complex16 *line, int len, int16 real);
int32 __ext_dbgplot_spectrum(complex16 *line, int len);
int32 __ext_dbgplot_dots(complex16 *data, int len);
int32 __ext_dbgplot_dot(complex16 data);



