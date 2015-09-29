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
#include <const.h>
#include <stdlib.h>
#include <stdio.h>
//#include <sora.h>
//#include "sora_threads.h"
#include "sora_thread_queues.h"
#include "bit.h"
#include "numerics.h"

#define ST_QUEUE_SIZE	64


// Assuming char is 1B
//#define __VALID(buf, size, i) *((bool*) ((buf) + (ST_CACHE_LINE+(size))*(i)))
//#define __DATA(buf, size, i) ((buf) + (ST_CACHE_LINE+(size))*(i) + ST_CACHE_LINE)

volatile bool* valid(char *buf, int size, int i) {
	return ((bool*) ((buf) + (ST_CACHE_LINE+(size))*(i)));
}
char *data(char *buf, int size, int i) {
	return ((buf) + (ST_CACHE_LINE+(size))*(i) + ST_CACHE_LINE);
}





ts_context *contexts;
int no_contexts = 0;


// Sora needed to yield in WinXP because of the scheduler issues
// In Win7 this does not seem necessary. 
// However, after thorough measurements we concluded that 
// SoraThreadYield doesn't affect the performance on many cores
// and help performance on a few cores, so we decided to keep it
//#define USE_SORA_YIELD


//Uncomment to display statistics about ts_queues
//#define TS_DEBUG

#ifdef TS_DEBUG
#define MAX_TS	10
calign LONG queueSize[MAX_TS*16];
LONG queueCum[MAX_TS];
LONG queueSam[MAX_TS];
LONG almostFull[MAX_TS];
LONG full[MAX_TS];
LONG fstalled[MAX_TS];
LONG esamples[MAX_TS];
LONG empty[MAX_TS];
#endif



// Init <no> queues, each with a different size

ts_context *s_ts_init_batch(int no, size_t *sizes, int *queue_sizes, int *batch_sizes)
{
	ts_context *locCont;

	locCont = (ts_context *) (malloc(no * sizeof(ts_context)));
	if (locCont == NULL)
	{
		return 0;
	}

#ifdef TS_DEBUG
		memset(queueSize, 0, MAX_TS*16 * sizeof(LONG));
		memset(queueCum, 0, MAX_TS * sizeof(LONG));
		memset(queueSam, 0, MAX_TS * sizeof(LONG));
		memset(almostFull, 0, MAX_TS * sizeof(LONG));
		memset(full, 0, MAX_TS * sizeof(LONG));
		memset(fstalled, 0, MAX_TS * sizeof(LONG));
		memset(esamples, 0, MAX_TS * sizeof(LONG));
		memset(empty, 0, MAX_TS * sizeof(LONG));
#endif

	for (int j=0; j<no; j++)
	{
		// All queues have default size
		if (queue_sizes == NULL)
		{
			locCont[j].queue_size = ST_QUEUE_SIZE;
		}
		else
		{
			locCont[j].queue_size = queue_sizes[j];
		}

		// Buffer size should be a multiple of ST_CACHE_LINE
		locCont[j].size = sizes[j];
		if (batch_sizes == NULL)
		{
			locCont[j].batch_size = 1;
		}
		else
		{
			locCont[j].batch_size = batch_sizes[j];
		}
		locCont[j].alg_size = ST_CACHE_LINE * ((locCont[j].size * locCont[j].batch_size) / ST_CACHE_LINE);
		if ((locCont[j].size * locCont[j].batch_size) % ST_CACHE_LINE > 0) locCont[j].alg_size += ST_CACHE_LINE;

		// Allocate one cache line for valid field and the rest for the data
		locCont[j].buf = (char *)_aligned_malloc((ST_CACHE_LINE + locCont[j].alg_size)*locCont[j].queue_size, ST_CACHE_LINE);
		if (locCont[j].buf == NULL)
		{
			printf("Cannot allocate thread separator buffer! Exiting... \n");
			exit (-1);
		}

		size_t i;
		for (i = 0; i < locCont[j].queue_size; i++)
		{
			* valid(locCont[j].buf, locCont[j].alg_size, i) = false;
		}
		locCont[j].wptr = locCont[j].wdptr = locCont[j].rptr = locCont[j].rdptr = locCont[j].buf;
		locCont[j].wind = locCont[j].wdind = locCont[j].rind = locCont[j].rdind = 0;

		locCont[j].evReset = locCont[j].evFlush = locCont[j].evFinish = false;
		locCont[j].evProcessDone = true;
	}

	return locCont;
}



// Init <no> queues
// Legacy API, assumes all queues have the same <batch_size> = 1
ts_context *s_ts_init_var(int no, size_t *sizes, int *queue_sizes)
{
	return s_ts_init_batch(no, sizes, queue_sizes, NULL);
}

// Init <no> queues
// Legacy API, assumes all queues have the same size of ST_QUEUE_SIZE and <batch_size> = 1
ts_context *s_ts_init(int no, size_t *sizes)
{
	return s_ts_init_batch(no, sizes, NULL, NULL);
}





// Init <no> queues, each with a different size
int ts_init_batch(int no, size_t *sizes, int *queue_sizes, int *batch_sizes)
{
	contexts = s_ts_init_batch(no, sizes, queue_sizes, batch_sizes);
	no_contexts = no;
	return no;
}


// Init <no> queues, each with a different size
int ts_init_var(int no, size_t *sizes, int *queue_sizes)
{
	contexts = s_ts_init_var(no, sizes, queue_sizes);
	no_contexts = no;
	return no;
}


// Init <no> queues
int ts_init(int no, size_t *sizes)
{
	contexts = s_ts_init(no, sizes);
	no_contexts = no;
	return no;
}







char *s_ts_reserve(ts_context *locCont, int nc, int num)
{
	char *buf;

	if (*valid(locCont[nc].wptr, locCont[nc].alg_size, 0)) {
		return NULL;
	}

	// copy a burst of input data into the synchronized buffer
	//memcpy ((locCont[nc].wptr)->data, input, sizeof(char)*BURST);
	// Copy only the actual amount of data (size) and not the entire buffer (alg_size)
	buf = data(locCont[nc].wptr, locCont[nc].alg_size, 0);


	// We set it to be valid on final push
	*valid(locCont[nc].wptr, locCont[nc].alg_size, 0) = false;
	locCont[nc].evProcessDone = false;

	locCont[nc].wptr += (ST_CACHE_LINE + locCont[nc].alg_size);
	if ((locCont[nc].wptr) == (locCont[nc].buf) + locCont[nc].queue_size*(ST_CACHE_LINE + locCont[nc].alg_size))
		(locCont[nc].wptr) = (locCont[nc].buf);

	return buf;
}




void s_ts_push(ts_context *locCont, int nc, int num)
{
	while (locCont[nc].wdptr == locCont[nc].wptr){
	}

	*valid(locCont[nc].wdptr, locCont[nc].alg_size, 0) = true;
	locCont[nc].evProcessDone = false;


	locCont[nc].wdptr += (ST_CACHE_LINE + locCont[nc].alg_size);
	if ((locCont[nc].wdptr) == (locCont[nc].buf) + locCont[nc].queue_size*(ST_CACHE_LINE + locCont[nc].alg_size))
		(locCont[nc].wdptr) = (locCont[nc].buf);
}






// Called by the downlink thread
char *s_ts_acquire(ts_context *locCont, int nc, int num)
{
	char * buf = NULL;

	// if the synchronized buffer has no data, 
	// check whether there is reset/flush request
	//if (!(locCont[nc].rptr)->valid)
	if (!(*valid(locCont[nc].rptr, locCont[nc].alg_size, 0)))
	{
		if (locCont[nc].evReset)
		{
			//Next()->Reset();
			(locCont[nc].evReset) = false;
		}
		if (locCont[nc].evFlush)
		{
			//Next()->Flush();
			locCont[nc].evFlush = false;
		}
		locCont[nc].evProcessDone = true;
		// no data to process  
		return NULL;
	}
	else
	{
		// Otherwise, there are data. Pump the data to the output pin
		buf = data(locCont[nc].rptr, locCont[nc].alg_size, 0);


		* valid(locCont[nc].rptr, locCont[nc].alg_size, 0) = true;
		locCont[nc].rptr += (ST_CACHE_LINE + locCont[nc].alg_size);
		if ((locCont[nc].rptr) == (locCont[nc].buf) + locCont[nc].queue_size*(ST_CACHE_LINE + locCont[nc].alg_size))
		{
			(locCont[nc].rptr) = (locCont[nc].buf);
		}

		return buf;
	}
	return NULL;
}



// Called by the downlink thread
void s_ts_release(ts_context *locCont, int nc, int num)
{
	char * buf = NULL;

	if (locCont[nc].rptr != locCont[nc].rdptr)
	{
		*valid(locCont[nc].rdptr, locCont[nc].alg_size, 0) = false;
		locCont[nc].rdptr += (ST_CACHE_LINE + locCont[nc].alg_size);
		if ((locCont[nc].rdptr) == (locCont[nc].buf) + locCont[nc].queue_size*(ST_CACHE_LINE + locCont[nc].alg_size))
		{
			(locCont[nc].rdptr) = (locCont[nc].buf);
		}
	}
}



char *ts_reserve(int nc, int num)
{
	return s_ts_reserve(contexts, nc, num);
}

void ts_push(int nc, int num)
{
	s_ts_push(contexts, nc, num);
}

char *ts_acquire(int nc, int num)
{
	return s_ts_acquire(contexts, nc, num);
}

void ts_release(int nc, int num)
{
	s_ts_release(contexts, nc, num);
}










// s_ts_put* and s_ts_get* are obsolete and should not be used
// Will be removed soon
// Instead, use s_ts_reserve, s_ts_push, s_ts_acquire, s_ts_release




// Called by the uplink thread
//        BOOL_FUNC_PROCESS(ipin)
void s_ts_put(ts_context *locCont, int nc, char *input)
{

	/*
	// DEBUG
	printf("%u, nc: %d, wptr: %x, rptr: %x, buf: %x, wptr valid=%d\n", GetCurrentThreadId(), 
		nc, locCont[nc].wptr, locCont[nc].rptr, locCont[nc].buf,
		*valid(locCont[nc].wptr, locCont[nc].alg_size, 0));
	*/

#ifdef TS_DEBUG
	if (*valid(locCont[nc].wptr, locCont[nc].alg_size, 0)) {
		full[nc]++;
	}
#endif

    // spin wait if the synchronized buffer is full
    //while ((locCont[nc].wptr)->valid) { SoraThreadYield(TRUE); }
    while (*valid(locCont[nc].wptr, locCont[nc].alg_size, 0)) { 
#ifdef TS_DEBUG
		fstalled[nc]++;
#endif
#ifdef USE_SORA_YIELD
		SoraThreadYield(TRUE); 
#endif
	}


	// copy a burst of input data into the synchronized buffer
	//memcpy ((locCont[nc].wptr)->data, input, sizeof(char)*BURST);
	// Copy only the actual amount of data (size) and not the entire buffer (alg_size)
	memcpy (data(locCont[nc].wptr, locCont[nc].alg_size, 0), input, sizeof(char)*locCont[nc].size);

    * valid(locCont[nc].wptr, locCont[nc].alg_size, 0) = true;
    locCont[nc].evProcessDone = false;


#ifdef TS_DEBUG
	InterlockedIncrement(queueSize + (nc*16));
	queueCum[nc] += queueSize[nc*16];
	queueSam[nc]++;
	if (queueSize[nc * 16] > (locCont[nc].queue_size * 0.9)) almostFull[nc]++;
#endif


	// advance the write pointer
    //(locCont[nc].wptr)++;
    //if ((locCont[nc].wptr) == (locCont[nc].buf) + locCont[nc].queue_size)
    //    (locCont[nc].wptr) = (locCont[nc].buf);
    locCont[nc].wptr += (ST_CACHE_LINE+locCont[nc].alg_size);
	if ((locCont[nc].wptr) == (locCont[nc].buf) + locCont[nc].queue_size*(ST_CACHE_LINE + locCont[nc].alg_size))
        (locCont[nc].wptr) = (locCont[nc].buf);
}





// Called by the uplink thread
//        BOOL_FUNC_PROCESS(ipin)
void ts_put(int nc, char *input)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues!, %d\n", no_contexts, nc);
		return;
	}

	s_ts_put(contexts, nc, input);
}





// Called by the uplink thread
// Blocking
void s_ts_putMany(ts_context *locCont, int nc, int n, char *input)
{
	int write = n;
	char *ptr = input;
	while (write > 0)
	{
		// Blocking:
		s_ts_put(locCont, nc, ptr);
		ptr += locCont[nc].size;
		write--;
	}
}



// Blocking
void ts_putMany(int nc, int n, char *input)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return;
	}

	s_ts_putMany(contexts, nc, n, input);
}


// Blocking
// unpack bits into one byte each, and put them into the queue 
void s_ts_putManyBits(ts_context *locCont, int nc, int n, char *input)
{
	unsigned char unpacked_bit[1];
	for (int i = 0; i < n; i++)
	{
		bitRead((BitArrPtr)input, i, unpacked_bit);
		s_ts_putMany(locCont, nc, 1, (char *)unpacked_bit);
	}
}

// Blocking
void ts_putManyBits(int nc, int n, char *input)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return;
	}

	s_ts_putManyBits(contexts, nc, n, input);
}





// Called by the downlink thread
bool s_ts_get(ts_context *locCont, int nc, char *output)
{
#ifdef TS_DEBUG
	esamples[nc]++;
#endif

	// if the synchronized buffer has no data, 
    // check whether there is reset/flush request
    //if (!(locCont[nc].rptr)->valid)
    if (!(*valid(locCont[nc].rptr, locCont[nc].alg_size, 0)))
    {		
#ifdef TS_DEBUG
		empty[nc]++;
#endif
		if (locCont[nc].evReset)
        {
            //Next()->Reset();
            (locCont[nc].evReset) = false;
        }
        if (locCont[nc].evFlush)
        {
            //Next()->Flush();
            locCont[nc].evFlush = false;
        }
        locCont[nc].evProcessDone = true;
		// no data to process  
        return false;
    }
	else
	{
		// Otherwise, there are data. Pump the data to the output pin
		//memcpy ( output, (locCont[nc].rptr)->data, sizeof(char)*BURST);
		// Copy only the actual amount of data (size) and not the entire buffer (alg_size)
		memcpy ( output, data(locCont[nc].rptr, locCont[nc].alg_size, 0), sizeof(char)*locCont[nc].size);

        //(locCont[nc].rptr)->valid = false;
	    //(locCont[nc].rptr)++;
        //if ((locCont[nc].rptr) == (locCont[nc].buf) + locCont[nc].queue_size)


#ifdef TS_DEBUG
		InterlockedDecrement(queueSize + (nc*16));
#endif

        * valid(locCont[nc].rptr, locCont[nc].alg_size, 0) = false;
		locCont[nc].rptr += (ST_CACHE_LINE+locCont[nc].alg_size);
		if ((locCont[nc].rptr) == (locCont[nc].buf) + locCont[nc].queue_size*(ST_CACHE_LINE+locCont[nc].alg_size))
        {
            (locCont[nc].rptr) = (locCont[nc].buf);
#ifdef USE_SORA_YIELD
            // Periodically yielding in busy processing to prevent OS hanging
            SoraThreadYield(TRUE);
#endif
		}

        //bool rc = Next()->Process(opin0());
        //if (!rc) return rc;
		return true;
	}
    return false;
}



bool ts_get(int nc, char *output)
//FINL bool Process() // ISource::Process
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return false;
	}

	return s_ts_get(contexts, nc, output);
}







// Reads as many chunks as available but at most n, and returns the number of chunks read
int s_ts_getMany(ts_context *locCont, int nc, int n, char *output)
{
	int read = 0;
	char *ptr = output;
	while (read < n && s_ts_get(locCont, nc, ptr))
	{
		ptr += locCont[nc].size;
		read++;
	}

	return read;
}



int ts_getMany(int nc, int n, char *output)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return false;
	}

	return s_ts_getMany(contexts, nc, n, output);
}





// Reads n chunks and blocks if not available. Return number of chunks read (which could be less than n if finished)
int s_ts_getManyBlocking(ts_context *locCont, int nc, int n, char *output)
{
	int read = 0;
	char *ptr = output;
	while (read < n)
	{
		bool last = s_ts_get(locCont, nc, ptr);
		if (last)
		{
			ptr += locCont[nc].size;
			read++;
		}
		if (s_ts_isFinished(locCont, nc))
		{
			break;
		}
	}

	return read;
}


int ts_getManyBlocking(int nc, int n, char *output)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return false;
	}

	return s_ts_getManyBlocking(contexts, nc, n, output);
}


void packBitsIntoByte(BitArrPtr bits, unsigned char *byte)
{
	for (int i = 0; i < 8; i++)
	{
		bitWrite(byte, i, bits[i]);
	}
}



// Get n bits (stored in 1 byte each), and pack them into (n+7)/8 bytes
// Return number of bits read (which could be less than n if finished)
int s_ts_getManyBits(ts_context *locCont, int nc, int n, char *output)
{
	char tmp_output[1];
	int read = 0;

	for (int i = 0; i<n; i++)
	{
		read += s_ts_getMany(locCont, nc, 1, tmp_output);
		bitWrite((BitArrPtr)output, i, tmp_output[0]);
	}

	return read;
}



int ts_getManyBits(int nc, int n, char *output)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return false;
	}

	return s_ts_getManyBits(contexts, nc, n, output);
}






// Get n bits (stored in 1 byte each), and pack them into (n+7)/8 bytes
// Return number of bits read (which could be less than n if finished)
int s_ts_getManyBitsBlocking(ts_context *locCont, int nc, int n, char *output)
{
	char tmp_output[1];
	int read = 0;

	for (int i = 0; i<n; i++)
	{
		read += s_ts_getManyBlocking(locCont, nc, 1, tmp_output);
		bitWrite((BitArrPtr) output, i, tmp_output[0]);
	}

	return read;
}



int ts_getManyBitsBlocking(int nc, int n, char *output)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues! %d\n", no_contexts, nc);
		return false;
	}

	return s_ts_getManyBitsBlocking(contexts, nc, n, output);
}



bool s_ts_isFinished(ts_context *locCont, int nc)
{
	// Return true to signal the end
	if (locCont[nc].evFinish)
	{
	  //previously: locCont[nc].evFinish = false;
	  locCont[nc].evProcessDone = true;
	  return true;
	}
	return false;
}

// Called by the downlink thread
bool ts_isFinished(int nc)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues!\n", no_contexts);
		return false;
	}

	return s_ts_isFinished(contexts, nc);
}






bool s_ts_isFull(ts_context *locCont, int nc)
{
	return (*valid(locCont[nc].wptr, locCont[nc].alg_size, 0));
}

bool ts_isFull(int nc)
{
	return s_ts_isFull(contexts, nc);
}




bool s_ts_isEmpty(ts_context *locCont, int nc)
{
  return (!(*valid(locCont[nc].rptr, locCont[nc].alg_size, 0)));
}

bool ts_isEmpty(int nc)
{
	return s_ts_isEmpty(contexts, nc);
}






// Issued from upstream to downstream
void s_ts_reset(ts_context *locCont, int nc)
{
    // Set the reset event, spin-waiting for 
    // the downstream to process the event
    locCont[nc].evReset = true;
    while (locCont[nc].evReset) { 
#ifdef USE_SORA_YIELD
		SoraThreadYield(TRUE); 
#endif
	}
}

// Issued from upstream to downstream
void ts_reset(int nc)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues!\n", no_contexts);
		return;
	}
	s_ts_reset(contexts, nc);
}






// Issued from upstream to downstream
void s_ts_flush(ts_context *locCont, int nc)
{
	// Wait for all data in buf processed by downstreaming bricks
    while (!locCont[nc].evProcessDone) { 
#ifdef USE_SORA_YIELD
		SoraThreadYield(TRUE); 
#endif
	}

    // Set the flush event, spin-waiting for
    // the downstream to process the event
    locCont[nc].evFlush = true;
	while (locCont[nc].evFlush) { 
#ifdef USE_SORA_YIELD
		SoraThreadYield(TRUE); 
#endif
	}
}


// Issued from upstream to downstream
void ts_flush(int nc)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues!\n", no_contexts);
		return;
	}

	s_ts_flush(contexts, nc);
}









// Issued from upstream to downstream
void s_ts_finish(ts_context *locCont, int nc)
{
	// Set the reset event, spin-waiting for 
    // the downstream to process the event
    locCont[nc].evFinish = true;
    //previously: while (locCont[nc].evFinish) { SoraThreadYield(TRUE); }
}

// Issued from upstream to downstream
void ts_finish(int nc)
{
	if (nc >= no_contexts)
	{
		printf("There are only %d queues!\n", no_contexts);
		return;
	}
	s_ts_finish(contexts, nc);
}





// WARNING: Unlike the rest of the code, this is not thread-safe 
// and might require a lock, depending on the use
void s_ts_clear(ts_context *locCont, int nc)
{
	size_t i;
	for (i = 0; i < locCont[nc].queue_size; i++)
	{
		*valid(locCont[nc].buf, locCont[nc].alg_size, i) = false;
	}
	// This is not thread-safe because consumer might move the rptr while we reset
	// creating an inconsitent state. Check with Steffen whether this needs to be handled
	locCont[nc].wptr = locCont[nc].rptr;
}

void ts_clear(int nc)
{
	return s_ts_clear(contexts, nc);
}








// WARNING: Unlike the rest of the code, this is not thread-safe 
// and might require a lock, depending on the use
void s_ts_rollback(ts_context *locCont, int nc, int n)
{
	int i = n;

	// Stop when enough rolled back or we hit the top of the queue
	while (i > 0 && locCont[nc].rptr != locCont[nc].wptr)
	{
		// rptr points at the new location so we first need to decrease

		// This is not thread-safe because consumer might move the rptr while we reset
		// creating an inconsitent state. Check with Steffen whether this needs to be handled
		locCont[nc].rptr -= (ST_CACHE_LINE + locCont[nc].alg_size);
		if (locCont[nc].rptr < locCont[nc].buf)
		{
			locCont[nc].rptr = (locCont[nc].buf) + (locCont[nc].queue_size - 1)*(ST_CACHE_LINE + locCont[nc].alg_size);
		}

		if (*valid(locCont[nc].rptr, locCont[nc].alg_size, 0))
		{
			*valid(locCont[nc].rptr, locCont[nc].alg_size, 0) = false;
		}
		else
		{
			// This should really not happen because 
			// we should hit the top of the queue before seeing false
			break;
		}

		i--;
	}
}

void ts_rollback(int nc, int n)
{
	return s_ts_rollback(contexts, nc, n);
}




void s_ts_free(ts_context *locCont, int no)
{
	for (int nc=0; nc < no; nc++)
	{
#ifdef TS_DEBUG
	printf("queue=%u, avg queue=%.3f, avg alm.full=%.3f, full=%.3f (%u), fstalled=%u, avg_stall=%.3f, empty=%.3f(%u), total samples=%u\n", 
		(long) queueSize[nc*16], (double) queueCum[nc] / (double) queueSam[nc], 
		(double) almostFull[nc] / (double) queueSam[nc], 
		(double) full[nc] / (double) queueSam[nc], full[nc], fstalled[nc], 
		(double) fstalled[nc] / (double) full[nc], 
		(double) empty[nc] / (double) esamples[nc], empty[nc], 
		queueSam[nc]);
#endif
		_aligned_free(locCont[nc].buf);
	}
}

void ts_free()
{
	s_ts_free(contexts, no_contexts);
}






