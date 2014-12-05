# 
# Copyright (c) Microsoft Corporation
# All rights reserved. 
#
# Licensed under the Apache License, Version 2.0 (the ""License""); you
# may not use this file except in compliance with the License. You may
# obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
# LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
# A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#

#!/bin/bash

set -e

export TOP=$(cd $(dirname $0)/.. && pwd -P)
source $TOP/scripts/common.sh

echo $1
#echo "Preprocessing..."
#gcc -x c -P -E $1 >$1.expanded
gcc $DEFINES -I $TOP/lib -w -x c -E $1 >$1.expanded


#echo "Running WPL compiler..."
$WPLC $WPLCFLAGS $EXTRAOPTS -i $1.expanded -o $1.c
cp $1.c $TOP/csrc/test.c


#echo "Compiling C code (WinDDK) ..."
pushd . && cd $TOP/csrc/CompilerDDK && ./bczcompile.bat && popd


if [[ $# -ge 2 ]]
then
    cp -f $DDKDIR/target/amd64/compilerddk.exe $2
fi


