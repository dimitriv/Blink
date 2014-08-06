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
#include <stdlib.h>
#include <errno.h>
#include <string.h>

#include "params.h"
#include "types.h"
#include "buf.h"

#include "wpl_alloc.h"

#ifdef SORA_PLATFORM
#include "sora_radio.h"
#endif


static int16 *num16_input_buffer;
static unsigned int num16_input_entries;
static unsigned int num16_input_idx = 0;
static unsigned int num16_input_repeats = 1;

static unsigned int num16_input_dummy_samples = 0;
static unsigned int num16_max_dummy_samples; 

unsigned int parse_dbg_int16(char *dbg_buf, int16 *target)
{
	

  char *s = NULL;
  unsigned int i = 0;
  long val;

  s = strtok(dbg_buf, ",");

  if (s == NULL) 
  {
	  fprintf(stderr,"Input (debug) file contains no samples.");
	  exit(1);
  }

  val = strtol(s,NULL,10);
  if (errno == EINVAL) 
  {
      fprintf(stderr,"Parse error when loading debug file.");
      exit(1);
  }

  target[i++] = (num16) val; 

  while (s = strtok(NULL, ",")) 
  {
	  val = strtol(s,NULL,10);
	  if (errno == EINVAL) 
      {
		  fprintf(stderr,"Parse error when loading debug file.");
		  exit(1);
      }
	  target[i++] = (num16) val;
  }
  return i; // total number of entries
}

void init_getint16()
{
	if (Globals.inType == TY_DUMMY)
	{
		num16_max_dummy_samples = Globals.dummySamples;
	}

	if (Globals.inType == TY_FILE)
	{
		unsigned int sz; 
		char *filebuffer;
		try_read_filebuffer(Globals.inFileName, &filebuffer, &sz);

		// How many bytes the file buffer has * sizeof should be enough
		num16_input_buffer = (int16 *) try_alloc_bytes(sz * sizeof(int16));

		if (Globals.inFileMode == MODE_BIN)
		{ 
			unsigned int i;
			int16 *typed_filebuffer = (int16 *) filebuffer;
			for (i=0; i < sz; i++)
			{
				num16_input_buffer[i] =  typed_filebuffer[i];
			}
			num16_input_entries = i;
		}
		else 
		{
			num16_input_entries = parse_dbg_int16(filebuffer, num16_input_buffer);
		}
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		InitSoraRx(Globals.radioParams);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}
GetStatus _buf_getint16(int16 *x)
{
	if (Globals.inType == TY_DUMMY)
	{
		if (num16_input_dummy_samples >= num16_max_dummy_samples && Globals.dummySamples != INF_REPEAT) return GS_EOF;
		num16_input_dummy_samples++;
		*x = 0;
		return GS_SUCCESS;
	}

	if (Globals.inType == TY_FILE)
	{
		// If we reached the end of the input buffer 
		if (num16_input_idx >= num16_input_entries)
		{
			// If no more repetitions are allowed 
			if (Globals.inFileRepeats != INF_REPEAT && num16_input_repeats >= Globals.inFileRepeats)
			{
				return GS_EOF;
			}
			// Otherwise we set the index to 0 and increase repetition count
			num16_input_idx = 0;
			num16_input_repeats++;
		}

		*x = num16_input_buffer[num16_input_idx++];

		return GS_SUCCESS;
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora RX supports only Complex16 type.\n");
		exit(1);
#endif
	}

	return GS_EOF;
}

GetStatus buf_getint16(int16 *x)
{
#ifdef STAMP_AT_READ
	write_time_stamp();
#endif
	return _buf_getint16(x);
}

GetStatus _buf_getarrint16(int16 *x, unsigned int vlen)
{
	if (Globals.inType == TY_DUMMY)
	{
		if (num16_input_dummy_samples >= num16_max_dummy_samples && Globals.dummySamples != INF_REPEAT) return GS_EOF;
		num16_input_dummy_samples += vlen;
		memset(x,0,vlen*sizeof(int16));
		return GS_SUCCESS;
	}

	if (Globals.inType == TY_FILE)
	{
		if (num16_input_idx + vlen > num16_input_entries)
		{
			if (Globals.inFileRepeats != INF_REPEAT && num16_input_repeats >= Globals.inFileRepeats)
			{
				if (num16_input_idx != num16_input_entries)
					fprintf(stderr, "Warning: Unaligned data in input file, ignoring final get()!\n");
				return GS_EOF;
			}
			// Otherwise ignore trailing part of the file, not clear what that part may contain ...
			num16_input_idx = 0;
			num16_input_repeats++;
		}
	
		memcpy(x,& num16_input_buffer[num16_input_idx], vlen * sizeof(int16));
		num16_input_idx += vlen;
		return GS_SUCCESS;
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora RX supports only Complex16 type.\n");
		exit(1);
#endif
	}

	return GS_EOF;
}

GetStatus buf_getarrint16(int16 *x, unsigned int vlen)
{
#ifdef STAMP_AT_READ
	write_time_stamp();
#endif
	return _buf_getarrint16(x, vlen);
}

void init_getcomplex16()
{
	init_getint16();                              // we just need to initialize the input buffer in the same way
	num16_max_dummy_samples = Globals.dummySamples * 2; // since we will be doing this in integer granularity
}

GetStatus buf_getcomplex16(complex16 *x) 
{
#ifdef STAMP_AT_READ
	write_time_stamp();
#endif
	if (Globals.inType == TY_DUMMY || Globals.inType == TY_FILE)
	{
		GetStatus gs1 = _buf_getint16(& (x->re));
		if (gs1 == GS_EOF) 
		{ 
			return GS_EOF;
		}
		else
		{
			return (_buf_getint16(& (x->im)));
		}
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		readSora(x, 1);
		return GS_SUCCESS;
#endif
	}

	return GS_EOF;
}

GetStatus buf_getarrcomplex16(complex16 *x, unsigned int vlen)
{
#ifdef STAMP_AT_READ
	write_time_stamp();
#endif
	if (Globals.inType == TY_DUMMY || Globals.inType == TY_FILE)
	{
		return (_buf_getarrint16((int16*) x,vlen*2));
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		readSora(x, vlen);
		return GS_SUCCESS;
#endif
	}

	return GS_EOF;
}

void fprint_int16(FILE *f, int16 val)
{
	static int isfst = 1;
	if (isfst) 
	{
		fprintf(f,"%d",val);
		isfst = 0;
	}
	else fprintf(f,",%d",val);
}
void fprint_arrint16(FILE *f, int16 *val, unsigned int vlen)
{
	unsigned int i;
	for (i=0; i < vlen; i++)
	{
		fprint_int16(f,val[i]);
	}
}

static int16 *num16_output_buffer;
static unsigned int num16_output_entries;
static unsigned int num16_output_idx = 0;
static FILE *num16_output_file;

void init_putint16()
{
	if (Globals.outType == TY_DUMMY || Globals.outType == TY_FILE)
	{
		num16_output_buffer = (int16 *) malloc(Globals.outBufSize * sizeof(int16));
		num16_output_entries = Globals.outBufSize;
		if (Globals.outType == TY_FILE)
			num16_output_file = try_open(Globals.outFileName,"w");
	}

	if (Globals.outType == TY_SORA) 
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora TX supports only Complex16 type.\n");
		exit(1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}

}


FINL
void _buf_putint16(int16 x)
{
	if (Globals.outType == TY_DUMMY)
	{
		return;
	}

	if (Globals.outType == TY_FILE)
	{
		if (Globals.outFileMode == MODE_DBG)
			fprint_int16(num16_output_file,x);
		else 
		{
			if (num16_output_idx == num16_output_entries)
			{
				fwrite(num16_output_buffer,num16_output_entries, sizeof(int16),num16_output_file);
				num16_output_idx = 0;
			}
			num16_output_buffer[num16_output_idx++] = (int16) x;
		}
	}

	if (Globals.outType == TY_SORA) 
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora TX supports only Complex16 type.\n");
		exit(1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}


void buf_putint16(int16 x)
{
#ifndef STAMP_AT_READ
	write_time_stamp();
#endif
	_buf_putint16(x);
}


FINL
void _buf_putarrint16(int16 *x, unsigned int vlen)
{

	if (Globals.outType == TY_DUMMY) return;

	if (Globals.outType == TY_FILE)
	{
		if (Globals.outFileMode == MODE_DBG) 
			fprint_arrint16(num16_output_file,x,vlen);
		else
		{
			if (num16_output_idx + vlen >= num16_output_entries)
			{
				// first write the first (num16_output_entries - vlen) entries
				unsigned int i;
				unsigned int m = num16_output_entries - num16_output_idx;

				for (i = 0; i < m; i++)
					num16_output_buffer[num16_output_idx + i] = x[i];

				// then flush the buffer
				fwrite(num16_output_buffer,num16_output_entries,sizeof(int16),num16_output_file);

				// then write the rest
				for (num16_output_idx = 0; num16_output_idx < vlen - m; num16_output_idx++)
					num16_output_buffer[num16_output_idx] = x[num16_output_idx + m];
			}
		}
	}

	if (Globals.outType == TY_SORA) 
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora TX supports only Complex16 type.\n");
		exit(1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}



void buf_putarrint16(int16 *x, unsigned int vlen)
{
#ifndef STAMP_AT_READ
	write_time_stamp();
#endif
	_buf_putarrint16(x, vlen);
}


void flush_putint16()
{
	if (Globals.outType == TY_FILE)
	{
		if (Globals.outFileMode == MODE_BIN) {
			fwrite(num16_output_buffer,sizeof(int16), num16_output_idx,num16_output_file);
			num16_output_idx = 0;
		}
		fclose(num16_output_file);
	}
}


void init_putcomplex16() 
{
#ifndef STAMP_AT_READ
	write_time_stamp();
#endif

	if (Globals.outType == TY_DUMMY || Globals.outType == TY_FILE)
	{
		num16_output_buffer = (int16 *) malloc(2*Globals.outBufSize * sizeof(int16));
		num16_output_entries = Globals.outBufSize*2;
		if (Globals.outType == TY_FILE)
			num16_output_file = try_open(Globals.outFileName,"w");
	}

	if (Globals.outType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		InitSoraTx(Globals.radioParams);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}

void buf_putcomplex16(struct complex16 x)
{
#ifndef STAMP_AT_READ
	write_time_stamp();
#endif

	if (Globals.outType == TY_DUMMY) return;

	if (Globals.outType == TY_FILE)
	{
		_buf_putint16(x.re);
		_buf_putint16(x.im);
	}

	if (Globals.outType == TY_SORA) 
	{
#ifdef SORA_PLATFORM
		writeSora(&x, 1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}

}
void buf_putarrcomplex16(struct complex16 *x, unsigned int vlen)
{
#ifndef STAMP_AT_READ
	write_time_stamp();
#endif

	if (Globals.outType == TY_DUMMY || Globals.outType == TY_FILE)
	{
		_buf_putarrint16((int16 *)x,vlen*2);
	}

	if (Globals.outType == TY_SORA) 
	{
#ifdef SORA_PLATFORM
		writeSora(x, vlen);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}
void flush_putcomplex16()
{
	flush_putint16();
}
