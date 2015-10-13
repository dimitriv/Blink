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





// Init <no> queues, each with a different size

ts_context *ts_init(int no, size_t *sizes, int *queue_sizes)
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
		locCont[j].alg_size = ST_CACHE_LINE * (locCont[j].size/ ST_CACHE_LINE);
		if (locCont[j].size % ST_CACHE_LINE > 0) locCont[j].alg_size += ST_CACHE_LINE;

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

		locCont[j].evReset = locCont[j].evFlush = locCont[j].evFinish = false;
		locCont[j].evProcessDone = true;
	}

	return locCont;
}








char *ts_reserve(ts_context *locCont, int num)
{
	char *buf;

	if (*valid(locCont->wptr, locCont->alg_size, 0)) {
		return NULL;
	}

	buf = data(locCont->wptr, locCont->alg_size, 0);


	// We set it to be valid on final push
	*valid(locCont->wptr, locCont->alg_size, 0) = false;
	locCont->evProcessDone = false;

	locCont->wptr += (ST_CACHE_LINE + locCont->alg_size);
	if ((locCont->wptr) == (locCont->buf) + locCont->queue_size*(ST_CACHE_LINE + locCont->alg_size))
		(locCont->wptr) = (locCont->buf);


	return buf;
}



bool ts_push(ts_context *locCont, int num)
{
	if (locCont->wdptr == locCont->wptr){
		return false;
	}

	*valid(locCont->wdptr, locCont->alg_size, 0) = true;
	locCont->evProcessDone = false;

	locCont->wdptr += (ST_CACHE_LINE + locCont->alg_size);
	if ((locCont->wdptr) == (locCont->buf) + locCont->queue_size*(ST_CACHE_LINE + locCont->alg_size))
		(locCont->wdptr) = (locCont->buf);


	return true;
}



// Called by the downlink thread
char *ts_acquire(ts_context *locCont, int num)
{
	char * buf = NULL;

	// if the synchronized buffer has no data, 
	// check whether there is reset/flush request
	//if (!(locCont->rptr)->valid)
	if (!(*valid(locCont->rptr, locCont->alg_size, 0)))
	{
		if (locCont->evReset)
		{
			//Next()->Reset();
			(locCont->evReset) = false;
		}
		if (locCont->evFlush)
		{
			//Next()->Flush();
			locCont->evFlush = false;
		}
		locCont->evProcessDone = true;
		// no data to process  
		return NULL;
	}
	else
	{
		// Otherwise, there are data. Pump the data to the output pin
		buf = data(locCont->rptr, locCont->alg_size, 0);

		*valid(locCont->rptr, locCont->alg_size, 0) = true;
		locCont->rptr += (ST_CACHE_LINE + locCont->alg_size);
		if ((locCont->rptr) == (locCont->buf) + locCont->queue_size*(ST_CACHE_LINE + locCont->alg_size))
		{
			(locCont->rptr) = (locCont->buf);
		}

		return buf;
	}
	return NULL;
}
// Called by the downlink thread


bool ts_release(ts_context *locCont, int num)
{
	if (locCont->rptr == locCont->rdptr)
	{
		return false;
	}

	*valid(locCont->rdptr, locCont->alg_size, 0) = false;
	locCont->rdptr += (ST_CACHE_LINE + locCont->alg_size);
	if ((locCont->rdptr) == (locCont->buf) + locCont->queue_size*(ST_CACHE_LINE + locCont->alg_size))
	{
		(locCont->rdptr) = (locCont->buf);
	}

	return true;
}









// Called by the uplink thread
//        BOOL_FUNC_PROCESS(ipin)
void ts_put(ts_context *locCont, char *input)
{
    // spin wait if the synchronized buffer is full
	while (*valid(locCont->wptr, locCont->alg_size, 0));


	// Copy only the actual amount of data (size) and not the entire buffer (alg_size)
	memcpy (data(locCont->wptr, locCont->alg_size, 0), input, sizeof(char)*locCont->size);

    * valid(locCont->wptr, locCont->alg_size, 0) = true;
    locCont->evProcessDone = false;

    locCont->wptr += (ST_CACHE_LINE+locCont->alg_size);
	if ((locCont->wptr) == (locCont->buf) + locCont->queue_size*(ST_CACHE_LINE + locCont->alg_size))
        (locCont->wptr) = (locCont->buf);
}




// Called by the uplink thread
// Blocking
void ts_putMany(ts_context *locCont, int n, char *input)
{
	int write = n;
	char *ptr = input;
	while (write > 0)
	{
		// Blocking:
		ts_put(locCont, ptr);
		ptr += locCont->size;
		write--;
	}
}



// Blocking
// unpack bits into one byte each, and put them into the queue 
void ts_putManyBits(ts_context *locCont, int n, char *input)
{
	unsigned char unpacked_bit[1];
	for (int i = 0; i < n; i++)
	{
		bitRead((BitArrPtr)input, i, unpacked_bit);
		ts_putMany(locCont, 1, (char *)unpacked_bit);
	}
}





// Called by the downlink thread
bool ts_get(ts_context *locCont, char *output)
{

	// if the synchronized buffer has no data, 
    // check whether there is reset/flush request
    //if (!(locCont->rptr)->valid)
    if (!(*valid(locCont->rptr, locCont->alg_size, 0)))
    {		
		if (locCont->evReset)
        {
            //Next()->Reset();
            (locCont->evReset) = false;
        }
        if (locCont->evFlush)
        {
            //Next()->Flush();
            locCont->evFlush = false;
        }
        locCont->evProcessDone = true;
		// no data to process  
        return false;
    }
	else
	{
		// Otherwise, there are data. Pump the data to the output pin
		//memcpy ( output, (locCont->rptr)->data, sizeof(char)*BURST);
		// Copy only the actual amount of data (size) and not the entire buffer (alg_size)
		memcpy ( output, data(locCont->rptr, locCont->alg_size, 0), sizeof(char)*locCont->size);


        * valid(locCont->rptr, locCont->alg_size, 0) = false;
		locCont->rptr += (ST_CACHE_LINE+locCont->alg_size);
		if ((locCont->rptr) == (locCont->buf) + locCont->queue_size*(ST_CACHE_LINE+locCont->alg_size))
        {
            (locCont->rptr) = (locCont->buf);
		}

		return true;
	}
    return false;
}





// Reads as many chunks as available but at most n, and returns the number of chunks read
int ts_getMany(ts_context *locCont, int n, char *output)
{
	int read = 0;
	char *ptr = output;
	while (read < n && ts_get(locCont, ptr))
	{
		ptr += locCont->size;
		read++;
	}

	return read;
}






// Reads n chunks and blocks if not available. Return number of chunks read (which could be less than n if finished)
int ts_getManyBlocking(ts_context *locCont, int n, char *output)
{
	int read = 0;
	char *ptr = output;
	while (read < n)
	{
		bool last = ts_get(locCont, ptr);
		if (last)
		{
			ptr += locCont->size;
			read++;
		}
		if (ts_isFinished(locCont))
		{
			break;
		}
	}

	return read;
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
int ts_getManyBits(ts_context *locCont, int n, char *output)
{
	char tmp_output[1];
	int read = 0;

	for (int i = 0; i<n; i++)
	{
		read += ts_getMany(locCont, 1, tmp_output);
		bitWrite((BitArrPtr)output, i, tmp_output[0]);
	}

	return read;
}







// Get n bits (stored in 1 byte each), and pack them into (n+7)/8 bytes
// Return number of bits read (which could be less than n if finished)
int ts_getManyBitsBlocking(ts_context *locCont, int n, char *output)
{
	char tmp_output[1];
	int read = 0;

	for (int i = 0; i<n; i++)
	{
		read += ts_getManyBlocking(locCont, 1, tmp_output);
		bitWrite((BitArrPtr) output, i, tmp_output[0]);
	}

	return read;
}





bool ts_isFinished(ts_context *locCont)
{
	// Return true to signal the end
	if (locCont->evFinish)
	{
	  locCont->evProcessDone = true;
	  return true;
	}
	return false;
}




bool ts_isFull(ts_context *locCont)
{
	return (*valid(locCont->wptr, locCont->alg_size, 0));
}


bool ts_isEmpty(ts_context *locCont)
{
  return (!(*valid(locCont->rptr, locCont->alg_size, 0)));
}







// Issued from upstream to downstream
void ts_reset(ts_context *locCont)
{
    // Set the reset event, spin-waiting for 
    // the downstream to process the event
    locCont->evReset = true;
	while (locCont->evReset);
}








// Issued from upstream to downstream
void ts_flush(ts_context *locCont)
{
	// Wait for all data in buf processed by downstreaming bricks
	while (!locCont->evProcessDone);

    // Set the flush event, spin-waiting for
    // the downstream to process the event
    locCont->evFlush = true;
	while (locCont->evFlush);
}



// Issued from upstream to downstream
void ts_finish(ts_context *locCont)
{
	// Set the reset event, spin-waiting for 
    // the downstream to process the event
    locCont->evFinish = true;
}




// WARNING: Unlike the rest of the code, this is not thread-safe 
// and might require a lock, depending on the use
void ts_clear(ts_context *locCont)
{
	size_t i;
	for (i = 0; i < locCont->queue_size; i++)
	{
		*valid(locCont->buf, locCont->alg_size, i) = false;
	}
	// This is not thread-safe because consumer might move the rptr while we reset
	// creating an inconsitent state. Check with Steffen whether this needs to be handled
	locCont->wptr = locCont->rptr;
}




// WARNING: Unlike the rest of the code, this is not thread-safe 
// and might require a lock, depending on the use
void ts_rollback(ts_context *locCont, int n)
{
	int i = n;

	// Stop when enough rolled back or we hit the top of the queue
	while (i > 0 && locCont->rptr != locCont->wptr)
	{
		// rptr points at the new location so we first need to decrease

		// This is not thread-safe because consumer might move the rptr while we reset
		// creating an inconsitent state. Check with Steffen whether this needs to be handled
		locCont->rptr -= (ST_CACHE_LINE + locCont->alg_size);
		if (locCont->rptr < locCont->buf)
		{
			locCont->rptr = (locCont->buf) + (locCont->queue_size - 1)*(ST_CACHE_LINE + locCont->alg_size);
		}

		if (*valid(locCont->rptr, locCont->alg_size, 0))
		{
			*valid(locCont->rptr, locCont->alg_size, 0) = false;
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




void ts_free(ts_context *locCont, int no)
{
	for (int nc=0; nc < no; nc++)
	{
		_aligned_free(locCont[nc].buf);
	}
}







