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
#pragma once 

// Input-output types
typedef enum  { 
  TY_FILE  = 0,
  TY_DUMMY = 1,
  TY_SDR = 2,
  TY_IP = 3,
  TY_MEM = 4, 
  TY_BLADERF = 5
} BlinkFileType;

// Binary or debug (human-readable) file format
typedef enum {
  MODE_DBG = 0,
  MODE_BIN = 1
} BlinkFileMode;




#ifdef SORA_PLATFORM
#include <soratime.h>
#include <thread_func.h>
#endif
#include <stdlib.h>
#include <time.h>
#include "types.h"
#include "wpl_alloc.h"
#include "utils.h"



#ifdef SORA_RF
typedef struct _SoraRadioParams {
	// RX
	SORA_RADIO_RX_STREAM RxStream;
} SoraRadioParam;
#endif

#ifdef BLADE_RF
#include <libbladeRF.h>
#endif

#ifdef ADI_RF
#include <iio.h>
#endif

#ifdef LIME_RF
//#include <iris_device.hpp>
#include <SoapySDR/Device.hpp>
#include <SoapySDR/Formats.hpp>
#endif

/**********************************************
	Radio parameters (generic for all radios)
***********************************************/ 

// We keep two sets of parameters in case we want to do full-duplex 
// one radio each. Otherwise, we only use one set for common parameters.
typedef struct {
	unsigned long radioId;
	long TXgain;
	long RXpa;
	long RXgain;
	unsigned long CentralFrequency;
	long FreqencyOffset;
	unsigned long SampleRate;
	unsigned long TXBufferSize;
	unsigned long Bandwidth;
	long DCBias;

#ifdef SORA_RF
	SoraRadioParam *dev;
#endif

#ifdef BLADE_RF
	struct bladerf *dev;
#endif

#ifdef ADI_RF
	struct iio_context *ctx;
	struct iio_device *rxdev, *txdev, *phy;
	struct iio_channel *rxch0, *txch0, *rxch1, *txch1, *phych0;
	struct iio_buffer *Txbuf, *Rxbuf;
	char * host;
#ifdef PL_CCA
	struct iio_channel *rxch2, *rxch3;
#endif

#endif

#ifdef LIME_RF
	SoapySDR::Device *iris;
	SoapySDR::Stream *rxStream;
	SoapySDR::Stream *txStream;
	unsigned long clockRate;
	char * host;
#ifdef PL_CS
	char * corr_thr;
	char * rst_countdown;
#endif
#endif

} SDRParameters;





/* How many times should we iterate the input dummy sample, 
 *  or the input samples that come from a file? 
 *  - Some n=0 means an infinite number of times
 *  - Some n>0 means exactly n times
 **********************************************************/
typedef unsigned long Repetitions;
#define INF_REPEAT 0 

typedef struct _BlinkParams {
	BlinkFileType inType;       // type of input
	BlinkFileType outType;      // type of output
	BlinkFileMode inFileMode;   // input file mode 
	BlinkFileMode outFileMode;  // output file mode 
	char *inFileName;           // input file name 
	char *outFileName;          // output file name 
	Repetitions inFileRepeats;  // #times to repeat the input buffer
	Repetitions dummySamples;   // #dummy samples (if inType == TY_DUMMY)
	unsigned int inMemorySize;	// Size of memory buffer for input
	unsigned int outMemorySize;	// Size of memory buffer for output
	unsigned int outBufSize;    // size of buffer we serve output from
	memsize_int heapSize;      // heap size for blink/wpl program
	unsigned long latencySampling;		// space between latency sampling in #writes (0 - no latency measurements)
	unsigned long latencyCDFSize;		// How many latency samples to be stored in the CDF table
	int debug;					// Level of debug info to print (0 - lowest)

	SDRParameters radioParams;

	// SDR buffers
	void * pRxBuf;				// RX
	void * TXBuffer;			// TX

	// Latency measurements
	int timeStampAtRead;

#ifdef SORA_PLATFORM
	TimeMeasurements measurementInfo;
#endif
} BlinkParams;




FILE * try_open(char *name, char *mode);
void try_parse_args(BlinkParams *params, int argc, char ** argv);
void try_read_filebuffer(HeapContextBlock *hblk, char *filename, BlinkFileMode mode, char **fb, memsize_int *len);

typedef struct {
  char * param_str;               // Name of param (for parsing)
  char * param_use;               // Use
  char * param_descr;             // Description
  char * param_dflt;              // Initialization value as string
  void (*param_init) (BlinkParams* Params, char *prm);  // Initializer
} BlinkParamInfo;

void print_blink_usage(void);
