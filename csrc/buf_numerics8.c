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


static int8 *num8_input_buffer;
static unsigned int num8_input_entries;
static unsigned int num8_input_idx = 0;
static unsigned int num8_input_repeats = 1;

static unsigned int num8_input_dummy_samples = 0;
static unsigned int num8_max_dummy_samples;

unsigned int parse_dbg_int8(char *dbg_buf, int8 *target)
{


	char *s = NULL;
	unsigned int i = 0;
	long val;

	s = strtok(dbg_buf, ",");

	if (s == NULL)
	{
		fprintf(stderr, "Input (debug) file contains no samples.");
		exit(1);
	}

	val = strtol(s, NULL, 10);
	if (errno == EINVAL)
	{
		fprintf(stderr, "Parse error when loading debug file.");
		exit(1);
	}

	target[i++] = (num8)val;

	while (s = strtok(NULL, ","))
	{
		val = strtol(s, NULL, 10);
		if (errno == EINVAL)
		{
			fprintf(stderr, "Parse error when loading debug file.");
			exit(1);
		}
		target[i++] = (num8)val;
	}
	return i; // total number of entries
}

void init_getint8()
{
	if (Globals.inType == TY_DUMMY)
	{
		num8_max_dummy_samples = Globals.dummySamples;
	}

	if (Globals.inType == TY_FILE)
	{
		unsigned int sz;
		char *filebuffer;
		try_read_filebuffer(Globals.inFileName, &filebuffer, &sz);

		// How many bytes the file buffer has * sizeof should be enough
		num8_input_buffer = (int8 *)try_alloc_bytes(sz * sizeof(int8));

		if (Globals.inFileMode == MODE_BIN)
		{
			unsigned int i;
			int8 *typed_filebuffer = (int8 *)filebuffer;
			for (i = 0; i < sz; i++)
			{
				num8_input_buffer[i] = typed_filebuffer[i];
			}
			num8_input_entries = i;
		}
		else
		{
			num8_input_entries = parse_dbg_int8(filebuffer, num8_input_buffer);
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
GetStatus buf_getint8(int8 *x)
{

	if (Globals.inType == TY_DUMMY)
	{
		if (num8_input_dummy_samples >= num8_max_dummy_samples && Globals.dummySamples != INF_REPEAT) return GS_EOF;
		num8_input_dummy_samples++;
		*x = 0;
		return GS_SUCCESS;
	}

	if (Globals.inType == TY_FILE)
	{
		// If we reached the end of the input buffer 
		if (num8_input_idx >= num8_input_entries)
		{
			// If no more repetitions are allowed 
			if (Globals.inFileRepeats != INF_REPEAT && num8_input_repeats >= Globals.inFileRepeats)
			{
				return GS_EOF;
			}
			// Otherwise we set the index to 0 and increase repetition count
			num8_input_idx = 0;
			num8_input_repeats++;
		}

		*x = num8_input_buffer[num8_input_idx++];

		return GS_SUCCESS;
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora RX supports only complex8 type.\n");
		exit(1);
#endif
	}

	return GS_EOF;
}
GetStatus buf_getarrint8(int8 *x, unsigned int vlen)
{

	if (Globals.inType == TY_DUMMY)
	{
		if (num8_input_dummy_samples >= num8_max_dummy_samples && Globals.dummySamples != INF_REPEAT) return GS_EOF;
		num8_input_dummy_samples += vlen;
		memset(x, 0, vlen*sizeof(int8));
		return GS_SUCCESS;
	}

	if (Globals.inType == TY_FILE)
	{
		if (num8_input_idx + vlen > num8_input_entries)
		{
			if (Globals.inFileRepeats != INF_REPEAT && num8_input_repeats >= Globals.inFileRepeats)
			{
				if (num8_input_idx != num8_input_entries)
					fprintf(stderr, "Warning: Unaligned data in input file, ignoring final get()!\n");
				return GS_EOF;
			}
			// Otherwise ignore trailing part of the file, not clear what that part may contain ...
			num8_input_idx = 0;
			num8_input_repeats++;
		}

		memcpy(x, &num8_input_buffer[num8_input_idx], vlen * sizeof(int8));
		num8_input_idx += vlen;
		return GS_SUCCESS;
	}

	if (Globals.inType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora RX supports only complex8 type.\n");
		exit(1);
#endif
	}

	return GS_EOF;
}

void init_getcomplex8()
{
	init_getint8();                              // we just need to initialize the input buffer in the same way
	num8_max_dummy_samples = Globals.dummySamples * 2; // since we will be doing this in integer granularity
}

GetStatus buf_getcomplex8(complex8 *x)
{
	if (Globals.inType == TY_DUMMY || Globals.inType == TY_FILE)
	{
		GetStatus gs1 = buf_getint8(&(x->re));
		if (gs1 == GS_EOF)
		{
			return GS_EOF;
		}
		else
		{
			return (buf_getint8(&(x->im)));
		}
	}

	if (Globals.inType == TY_SORA)
	{
		fprintf(stderr, "Error: Sora does not support 8-bit receive\n");
		exit(1);
	}

	return GS_EOF;
}

GetStatus buf_getarrcomplex8(complex8 *x, unsigned int vlen)
{
	if (Globals.inType == TY_DUMMY || Globals.inType == TY_FILE)
	{
		return (buf_getarrint8((int8*)x, vlen * 2));
	}

	if (Globals.inType == TY_SORA)
	{
		fprintf(stderr, "Error: Sora RX does not support Complex8\n");
		exit(1);
	}

	return GS_EOF;
}

void fprint_int8(FILE *f, int8 val)
{
	static int isfst = 1;
	if (isfst)
	{
		fprintf(f, "%d", val);
		isfst = 0;
	}
	else fprintf(f, ",%d", val);
}
void fprint_arrint8(FILE *f, int8 *val, unsigned int vlen)
{
	unsigned int i;
	for (i = 0; i < vlen; i++)
	{
		fprint_int8(f, val[i]);
	}
}

static int8 *num8_output_buffer;
static unsigned int num8_output_entries;
static unsigned int num8_output_idx = 0;
static FILE *num8_output_file;

void init_putint8()
{
	if (Globals.outType == TY_DUMMY || Globals.outType == TY_FILE)
	{
		num8_output_buffer = (int8 *)malloc(Globals.outBufSize * sizeof(int8));
		num8_output_entries = Globals.outBufSize;
		if (Globals.outType == TY_FILE)
			num8_output_file = try_open(Globals.outFileName, "w");
	}

	if (Globals.outType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora TX supports only int16 type.\n");
		exit(1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}

}


FINL
void _buf_putint8(int8 x)
{
	if (Globals.outType == TY_DUMMY)
	{
		return;
	}

	if (Globals.outType == TY_FILE)
	{
		if (Globals.outFileMode == MODE_DBG)
			fprint_int8(num8_output_file, x);
		else
		{
			if (num8_output_idx == num8_output_entries)
			{
				fwrite(num8_output_buffer, num8_output_entries, sizeof(int8), num8_output_file);
				num8_output_idx = 0;
			}
			num8_output_buffer[num8_output_idx++] = (int8)x;
		}
	}

	if (Globals.outType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora TX supports only int16 type.\n");
		exit(1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}


void buf_putint8(int8 x)
{
	write_time_stamp();
	_buf_putint8(x);
}


FINL
void _buf_putarrint8(int8 *x, unsigned int vlen)
{

	if (Globals.outType == TY_DUMMY) return;

	if (Globals.outType == TY_FILE)
	{
		if (Globals.outFileMode == MODE_DBG)
			fprint_arrint8(num8_output_file, x, vlen);
		else
		{
			if (num8_output_idx + vlen >= num8_output_entries)
			{
				// first write the first (num8_output_entries - vlen) entries
				unsigned int i;
				unsigned int m = num8_output_entries - num8_output_idx;

				for (i = 0; i < m; i++)
					num8_output_buffer[num8_output_idx + i] = x[i];

				// then flush the buffer
				fwrite(num8_output_buffer, num8_output_entries, sizeof(int8), num8_output_file);

				// then write the rest
				for (num8_output_idx = 0; num8_output_idx < vlen - m; num8_output_idx++)
					num8_output_buffer[num8_output_idx] = x[num8_output_idx + m];
			}
		}
	}

	if (Globals.outType == TY_SORA)
	{
#ifdef SORA_PLATFORM
		fprintf(stderr, "Sora TX supports only complex8 type.\n");
		exit(1);
#else
		fprintf(stderr, "Sora supported only on WinDDK platform.\n");
		exit(1);
#endif
	}
}



void buf_putarrint8(int8 *x, unsigned int vlen)
{
	write_time_stamp();
	_buf_putarrint8(x, vlen);
}


void flush_putint8()
{
	if (Globals.outType == TY_FILE)
	{
		if (Globals.outFileMode == MODE_BIN) {
			fwrite(num8_output_buffer, sizeof(int8), num8_output_idx, num8_output_file);
			num8_output_idx = 0;
		}
		fclose(num8_output_file);
	}
}


void init_putcomplex8()
{
	write_time_stamp();

	if (Globals.outType == TY_DUMMY || Globals.outType == TY_FILE)
	{
		num8_output_buffer = (int8 *)malloc(2 * Globals.outBufSize * sizeof(int8));
		num8_output_entries = Globals.outBufSize * 2;
		if (Globals.outType == TY_FILE)
			num8_output_file = try_open(Globals.outFileName, "w");
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

void buf_putcomplex8(struct complex8 x)
{
	write_time_stamp();

	if (Globals.outType == TY_DUMMY) return;

	if (Globals.outType == TY_FILE)
	{
		_buf_putint8(x.re);
		_buf_putint8(x.im);
	}

	if (Globals.outType == TY_SORA)
	{
		fprintf(stderr, "Error: Sora TX does not support Complex8\n");
		exit(1);
	}


}
void buf_putarrcomplex8(struct complex8 *x, unsigned int vlen)
{
	write_time_stamp();

	if (Globals.outType == TY_DUMMY || Globals.outType == TY_FILE)
	{
		_buf_putarrint8((int8 *)x, vlen * 2);
	}

	if (Globals.outType == TY_SORA)
	{
		fprintf(stderr, "Error: Sora TX does not support Complex8\n");
		exit(1);
	}
}
void flush_putcomplex8()
{
	flush_putint8();
}
