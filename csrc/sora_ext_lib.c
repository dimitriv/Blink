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
#include "types.h"
#include "string.h"
#include <assert.h>


#include <sora.h>
#include <vector128.h>
#include <fft.h>
#include "viterbicore.h"
#include "tpltrick.h"
#include "ieee80211a_cmn.h"
#include "ieee80211facade.hpp"
#include "demapper11a.hpp"
#include <demapper.h>

#include <xmmintrin.h>
#include <emmintrin.h>

#include "const.h"
#include "stdbrick.hpp"
#include "ieee80211facade.hpp"
#include "depuncturer.hpp"
#include "PHY_11a.hpp"
#include "PHY_11b.hpp"
#include "pilot.hpp"
#include "channel_11a.hpp"
#include "cca.hpp"
#include "freqoffset.hpp"
#include "scramble.hpp"
#include "deinterleaver.hpp"
#include "samples.hpp"
#include "sampling.hpp"
#include "sora_ext_bricks.h"
#include "sora_ext_lib_fft.h"

#include "utils.h"






// Functions here are not explicitly inline but
// aggressive optimization will make them all inline


// c = a + b
//FINL 
int __ext_v_add_complex16(struct complex16* c, int len, struct complex16* a,
          int __unused_2, struct complex16* b, int __unused_1)
{
	const int wlen = sizeof(vcs) / sizeof(complex16);
	for (int i = 0; i < len / wlen; i++)
	{
		vcs *pa = (vcs *)(a + wlen*i);
		vcs *pc = (vcs *)(c + wlen*i);
		vcs *pb = (vcs *)(b + wlen*i);

		//*pc = (*pa) + (*pb); 
		*pc = (vcs)_mm_add_epi16(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i].re = a[i].re + b[i].re;
		c[i].im = a[i].im + b[i].im;
	}
	return 0;
}

int __ext_v_add_complex32(struct complex32* c, int len, struct complex32* a,
	int __unused_2, struct complex32* b, int __unused_1)
{
	const int wlen = sizeof(vci) / sizeof(complex32);
	for (int i = 0; i < len / wlen; i++)
	{
		vci *pa = (vci *)(a + wlen*i);
		vci *pc = (vci *)(c + wlen*i);
		vci *pb = (vci *)(b + wlen*i);

		//*pc = (*pa) + (*pb); 
		*pc = (vci)_mm_add_epi32(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i].re = a[i].re + b[i].re;
		c[i].im = a[i].im + b[i].im;
	}
	return 0;
}

int __ext_v_add_int16(int16* c, int len, int16* a,
	int __unused_2, int16* b, int __unused_1)
{
	const int wlen = sizeof(vs) / sizeof(int16);
	for (int i = 0; i < len / wlen; i++)
	{
		vs *pa = (vs *)(a + wlen*i);
		vs *pc = (vs *)(c + wlen*i);
		vs *pb = (vs *)(b + wlen*i);

		//*pc = (*pa) + (*pb); 
		*pc = (vs)_mm_add_epi32(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i] = a[i] + b[i];
	}
	return 0;
}

int __ext_v_add_int32(int32* c, int len, int32* a,
	int __unused_2, int32* b, int __unused_1)
{
	const int wlen = sizeof(vi) / sizeof(int32);
	for (int i = 0; i < len / wlen; i++)
	{
		vi *pa = (vi *)(a + wlen*i);
		vi *pc = (vi *)(c + wlen*i);
		vi *pb = (vi *)(b + wlen*i);

		//*pc = (*pa) + (*pb); 
		*pc = (vi)_mm_add_epi32(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i] = a[i] + b[i];
	}
	return 0;
}





// c = a - b
//FINL 
int __ext_v_sub_complex16(struct complex16* c, int len, struct complex16* a,
          int __unused_2, struct complex16* b, int __unused_1)
 {
	const int wlen = sizeof(vcs) / sizeof(complex16);
	for (int i = 0; i < len / wlen; i++)
	{
		vcs *pa = (vcs *)(a + wlen*i);
		vcs *pc = (vcs *)(c + wlen*i);
		vcs *pb = (vcs *)(b + wlen*i);

		//*pc = (*pa) - (*pb); 
		*pc = (vcs)_mm_sub_epi16(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i].re = a[i].re - b[i].re;
		c[i].im = a[i].im - b[i].im;
	}
	return 0;	
 }

int __ext_v_sub_complex32(struct complex32* c, int len, struct complex32* a,
	int __unused_2, struct complex32* b, int __unused_1)
{
	const int wlen = sizeof(vci) / sizeof(complex32);
	for (int i = 0; i < len / wlen; i++)
	{
		vci *pa = (vci *)(a + wlen*i);
		vci *pc = (vci *)(c + wlen*i);
		vci *pb = (vci *)(b + wlen*i);

		//*pc = (*pa) - (*pb); 
		*pc = (vci)_mm_sub_epi32(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i].re = a[i].re - b[i].re;
		c[i].im = a[i].im - b[i].im;
	}
	return 0;
}

int __ext_v_sub_int16(int16* c, int len, int16* a,
	int __unused_2, int16* b, int __unused_1)
{
	const int wlen = sizeof(vs) / sizeof(int16);
	for (int i = 0; i < len / wlen; i++)
	{
		vs *pa = (vs *)(a + wlen*i);
		vs *pc = (vs *)(c + wlen*i);
		vs *pb = (vs *)(b + wlen*i);

		//*pc = (*pa) - (*pb); 
		*pc = (vs)_mm_sub_epi32(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i] = a[i] - b[i];
	}
	return 0;
}

int __ext_v_sub_int32(int32* c, int len, int32* a,
	int __unused_2, int32* b, int __unused_1)
{
	const int wlen = sizeof(vi) / sizeof(int32);
	for (int i = 0; i < len / wlen; i++)
	{
		vi *pa = (vi *)(a + wlen*i);
		vi *pc = (vi *)(c + wlen*i);
		vi *pb = (vi *)(b + wlen*i);

		//*pc = (*pa) - (*pb); 
		*pc = (vi)_mm_sub_epi32(*pa, *pb);
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		c[i] = a[i] - b[i];
	}
	return 0;
}


//equivalent to sora hadd :
//Sum all components of vector x and stores it in all components of z
// z(i) = sum(x) for all i
//FINL 
int __ext_v_hadd_complex16(struct complex16* z, int __unused_2, struct complex16* x,
          int __unused_1)
{
	 vcs output;
	 vcs *xi = (vcs *)x;
	 output = hadd (*xi);
	 
	 memcpy((void *)z,(void *)(&output),sizeof(vcs));

	 return 0;
}

//FINL 
int __ext_v_hadd_int32(int* z, int __unused_21, int* x, int __unused_20)
{

	vi output;
	vi *xi = (vi *)x;
	output = hadd (*xi);
	 
	memcpy((void *)z,(void *)(&output),sizeof(vi));

	return 0;
}





//FINL 
struct complex16 __ext_v_sum_complex16(struct complex16* x, int len)
{
	struct complex16 ret;

	const int wlen = sizeof(vcs) / sizeof(complex16);
	for (int i = 0; i < len / wlen; i++)
	{
		vcs *px = (vcs *)(x + wlen*i);
		vcs output = hadd(*px);

		if (i == 0)
		{
			ret.re = ((struct complex16*) &output)->re;
			ret.im = ((struct complex16*) &output)->im;
		}
		else
		{
			ret.re += ((struct complex16*) &output)->re;
			ret.im += ((struct complex16*) &output)->im;
		}
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		ret.re += x[i].re;
		ret.im += x[i].im;
	}

	return ret;
}

/* Not supported by Sora (yet?)
//FINL 
struct complex32 __ext_v_sum_complex32(struct complex32* x, int len)
{
	struct complex32 ret;

	const int wlen = sizeof(vci) / sizeof(complex32);
	for (int i = 0; i < len / wlen; i++)
	{
		vci *px = (vci *)(x + wlen*i);
		vci output = hadd(*px);

		if (i == 0)
		{
			ret.re = ((struct complex32*) &output)->re;
			ret.im = ((struct complex32*) &output)->im;
		}
		else
		{
			ret.re += ((struct complex32*) &output)->re;
			ret.im += ((struct complex32*) &output)->im;
		}
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		ret.re += x[i].re;
		ret.im += x[i].im;
	}

	return ret;
}
*/

/* Not supported by Sora (yet?)
//FINL 
int16 __ext_v_sum_int16(int16* x, int len)
{
	int16 ret;

	const int wlen = sizeof(vs) / sizeof(int16);
	for (int i = 0; i < len / wlen; i++)
	{
		vs *px = (vs *)(x + wlen*i);
		vs output = hadd(*px);

		if (i == 0)
		{
			ret = *((int16*)&output);
		}
		else
		{
			ret += *((int16*)&output);
		}
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		ret += x[i];
	}

	return ret;
}
*/

//FINL 
int32 __ext_v_sum_int32(int32* x, int len)
{
	int32 ret;

	const int wlen = sizeof(vi) / sizeof(int32);
	for (int i = 0; i < len / wlen; i++)
	{
		vi *px = (vi *)(x + wlen*i);
		vi output = hadd(*px);

		if (i == 0)
		{
			ret = *((int32*) &output);
		}
		else
		{
			ret += *((int32*) &output);
		}
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		ret += x[i];
	}

	return ret;
}







//FINL 
int __ext_v_shift_right_complex32(struct complex32* z, int __unused_3, struct complex32* x, int len, int shift)
{
	const int wlen = sizeof(vci) / sizeof(complex32);
	for (int i = 0; i < len / wlen; i++)
	{
		vci *xi = (vci *)(x + wlen*i);

		vci output = (shift_right(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vci));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i].re = x[i].re >> shift;
		z[i].im = x[i].im >> shift;
	}
	return 0;
}

//FINL 
int __ext_v_shift_left_complex32(struct complex32* z, int __unused_3, struct complex32* x, int len, int shift)
{
	const int wlen = sizeof(vci) / sizeof(complex32);
	for (int i = 0; i < len / wlen; i++)
	{
		vci *xi = (vci *)(x + wlen*i);

		vci output = (shift_left(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vci));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i].re = x[i].re << shift;
		z[i].im = x[i].im << shift;
	}
	return 0;
}



//FINL 
int __ext_v_shift_right_complex16(struct complex16* z, int __unused_3, struct complex16* x, int len, int shift)
{
	const int wlen = sizeof(vcs) / sizeof(complex16);
	for (int i = 0; i < len / wlen; i++)
	{
		//vcs *xi = (vcs *)(x + wlen*i);

		//vcs output = (shift_right(*xi, shift));
		//memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vcs));



		__m128i mx = _mm_loadu_si128((__m128i *)(x + wlen*i));
		_mm_storeu_si128((__m128i *) (z + wlen*i), _mm_srai_epi16(mx,shift));

	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i].re = x[i].re >> shift;
		z[i].im = x[i].im >> shift;
	}
	return 0;
}

//FINL 
int __ext_v_shift_left_complex16(struct complex16* z, int __unused_3, struct complex16* x, int len, int shift)
{
	const int wlen = sizeof(vcs) / sizeof(complex16);
	for (int i = 0; i < len / wlen; i++)
	{
		vcs *xi = (vcs *)(x + wlen*i);

		vcs output = (shift_left(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vcs));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i].re = x[i].re << shift;
		z[i].im = x[i].im << shift;
	}
	return 0;
}



//FINL 
int __ext_v_shift_right_int32(int32* z, int __unused_3, int32* x, int len, int shift)
{
	const int wlen = sizeof(vi) / sizeof(int32);
	for (int i = 0; i < len / wlen; i++)
	{
		vi *xi = (vi *)(x + wlen*i);

		vi output = (shift_right(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vi));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i] = x[i] >> shift;
	}
	return 0;
}


//FINL 
int __ext_v_shift_left_int32(int32* z, int __unused_3, int32* x, int len, int shift)
{
	const int wlen = sizeof(vi) / sizeof(int32);
	for (int i = 0; i < len / wlen; i++)
	{
		vi *xi = (vi *)(x + wlen*i);

		vi output = (shift_left(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vi));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i] = x[i] << shift;
	}
	return 0;
}



//FINL 
int __ext_v_shift_right_int16(int16* z, int __unused_3, int16* x, int len, int shift)
{
	const int wlen = sizeof(vs) / sizeof(int16);
	for (int i = 0; i < len / wlen; i++)
	{
		vs *xi = (vs *)(x + wlen*i);

		vs output = (shift_right(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vs));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i] = x[i] >> shift;
	}
	return 0;
}


//FINL 
int __ext_v_shift_left_int16(int16* z, int __unused_3, int16* x, int len, int shift)
{
	const int wlen = sizeof(vs) / sizeof(int16);
	for (int i = 0; i < len / wlen; i++)
	{
		vs *xi = (vs *)(x + wlen*i);

		vs output = (shift_left(*xi, shift));
		memcpy((void *)(z + wlen*i), (void *)(&output), sizeof(vs));
	}
	for (int i = (len / wlen) * wlen; i < len; i++)
	{
		z[i] = x[i] << shift;
	}
	return 0;
}




//
// This was v_mul_complex16_shift but I changed the name for consistency with v_conj_mul
// and the fact that the old v_mul_complex16 was never called
//
int __ext_v_mul_complex16(struct complex16* out, int lenout,
								struct complex16* x, int len1,
								struct complex16* y, int len2, int shift)
{
	
	const int wlen = sizeof(vcs) / sizeof(complex16);
	
		const __m128i conj = _mm_set_epi16(-1, 1, -1, 1, -1, 1, -1, 1);
		const __m128i xmm6 = _mm_set1_epi32(0x0000FFFF);		//0x0000FFFF0000FFFF0000FFFF0000FFFF
		for (int i = 0; i < len1 / wlen; i++){

			/*
			vcs *vx = (vcs *)(x + wlen*i);
			vcs *vy = (vcs *)(y + wlen*i);
			vcs *vout = (vcs *)(out + wlen*i);

			vcs vs1 = conj0(*vy);

			vcs vs2 = (vcs)permutate_low<1, 0, 3, 2>(*vy);
			vs2 = permutate_high<1, 0, 3, 2>(vs2);

			vi re32 = muladd(*vx, vs1);
			vi im32 = muladd(*vx, vs2);

			re32 = shift_right(re32, shift);
			im32 = shift_right(im32, shift);

			*vout = (vcs)pack(re32, im32);
			//*/
			//*
			__m128i mx = _mm_loadu_si128((__m128i *)(x + wlen*i));
			__m128i my = _mm_loadu_si128((__m128i *)(y + wlen*i));
			

			__m128i ms1 = _mm_sign_epi16(mx, conj);

			__m128i ms2 = _mm_shufflehi_epi16(mx, _MM_SHUFFLE(2, 3, 0, 1));
			ms2 = _mm_shufflelo_epi16(ms2, _MM_SHUFFLE(2, 3, 0, 1));

			__m128i mre = _mm_srai_epi32(_mm_madd_epi16(ms1, my), shift);
			__m128i mim = _mm_srai_epi32(_mm_madd_epi16(ms2, my), shift);

			mre = _mm_and_si128(mre,xmm6);
			mim = _mm_and_si128(mim,xmm6);

			mim = _mm_slli_epi32(mim,0x10);


			__m128i mout = _mm_or_si128(mre, mim);

			_mm_storeu_si128((__m128i *) (out + wlen*i), mout);
			//*/
		}

		for (int i = (len1 / wlen) * wlen; i < len1; i++){
			out[i].re = x[i].re * y[i].re - x[i].im * y[i].im >> shift;
			out[i].im = x[i].re * y[i].im + x[i].im * y[i].re >> shift;
		};
	
	return 0;

}

//
// multiplies two complex vectors and returns the real and imaginary parts 
// as two 32 bit integers.
//
int __ext_v_conj_mul_complex16_int32(int32* re, int lenout1, int32* im, int lenout2, 
				struct complex16* x, int len1, struct complex16* y, int len2 )
{

	const int wlen = sizeof(vcs) / sizeof(complex16);

	for (int i = 0; i < len1 / wlen; i++){

		vcs *vx = (vcs *)(x + wlen*i);
		vcs *vy = (vcs *)(y + wlen*i);
		vi *reout = (vi *)(re + wlen*i);
		vi *imout = (vi *)(im + wlen*i);

		vcs vs2 = conj0(*vy);

	    vs2 = permutate_low<1, 0, 3, 2>(vs2);
		vs2 = permutate_high<1, 0, 3, 2>(vs2);

		*reout = (vcs)muladd(*vx, *vy);
		*imout = (vcs)muladd(*vx, vs2);


	}

	for (int i = (len1 / wlen) * wlen; i < len1; i++){
		re[i] = x[i].re * y[i].re + x[i].im * y[i].im ;
		im[i] = x[i].im * y[i].re - x[i].re * y[i].im ;
	};

	return 0;

}
// Multiply the first source vector by the conjugate of the second source vector
// ie. re + j * im = a * conj(b)
//Return by reference for performance
int __ext_v_conj_mul_complex16(struct complex16* out, int lenout,
								struct complex16* x, int len1,
								struct complex16* y, int len2, int shift){
			
	const int wlen = sizeof(vcs) / sizeof(complex16);

	for (int i = 0; i < len1 / wlen; i++){

		vcs *vx = (vcs *)(x + wlen*i);
		vcs *vy = (vcs *)(y + wlen*i);
		vcs *vout = (vcs *)(out + wlen*i);

		
		vcs vs2 = conj0(*vy);

		vs2 = permutate_low<1, 0, 3, 2>(vs2);
		vs2 = permutate_high<1, 0, 3, 2>(vs2);

		vi re32 = muladd(*vx, *vy);
		vi im32 = muladd(*vx, vs2);
		
		re32 = shift_right(re32, shift);
		im32 = shift_right(im32, shift);

		*vout = (vcs)pack(re32, im32);
	}

	for (int i = (len1 / wlen) * wlen; i < len1; i++){
		out[i].re = x[i].re * y[i].re + x[i].im * y[i].im >> shift;
		out[i].im = x[i].im * y[i].re - x[i].re * y[i].im >> shift;
	};

	return 0;
}




// This function is called in code/WiFi/receiver/downSample.blk
//FINL 
int __ext_permutatew1313 (struct complex16* x,
               int __unused_2,  struct complex16* y, int __unused_1)
{
	assert (__unused_2 == 4);
	assert (__unused_1 == 4);
	vcs *pi = (vcs *)x;
	int tmp = 1;
	vcs t1 = permutate<1,3,1,3>(pi[0]);
	// tried to use this to avoid making a template, 
	// but the mm function also requires a constant expression as the second argument
	//vcs t1 = (vcs)_mm_shuffle_epi32(pi[0], (((a3) << 6) | ((a2) << 4) | ((a1) << 2) | ((a0))));
	//int mvp;
	//vcs t1 = (vcs)_mm_shuffle_epi32(pi[0], mvp);
	vcs *po = (vcs *)y;
	*po = t1;
	return 0;
}
// This function is called in code/WiFi/receiver/downSample.blk
//FINL 
int __ext_interleave_loww( struct complex16* x, int __unused_5,
                     struct complex16* y, int __unused_4,
                     struct complex16* z, int __unused_3)
{
	assert (__unused_4 == 4);
	assert (__unused_3 == 4);
	assert (__unused_5 == 4);

	vcs t1 = *( (vcs*)x );
	vcs t2 = *( (vcs*)y );

	vcs *po = (vcs *)z;

	*po = (vcs)(interleave_low ((vcui&)t1, (vcui&)t2));

	return 0;
}

//FINL 
int __ext_pairwise_muladdw(struct complex16* x, int __unused_15, struct complex16* y,
                     int __unused_14, int* z, int __unused_13)
{
	vcs *a = (vcs*)x;
	vcs *b = (vcs*)y;

	calign vi output = pairwise_muladd((vs&)(*a), (vs&)(*b));
	memcpy((void *)z,(void *)(&output),sizeof(vi));

	return 0;
}


//FINL 
int __ext_v_pack_int32_complex16(struct complex16* z, int len, int32* re, int len1, int32* im, int len2)
{
	const int wlen = sizeof(vi) / sizeof(complex16);
	for (int i = 0; i < len / wlen; i++)
	{
		vi *vre = (vi *)re + i;
		vi *vim = (vi *)im + i;

		vcs output = (vcs)pack(*vre, *vim);

		memcpy((void *)(z + i*wlen), (void *)(&output), sizeof(vcs));
	}
	return 0;
}


//FINL 
void __ext_v_pack_complex16_complex8(struct complex8* output, int lenout, complex16* input, int lenin)
{
	const int wlen = sizeof(vcs) / sizeof(complex16);
	int i;
	vcs *pinput = (vcs *) input;
	vcb *poutput = (vcb *) output;
	for (i = 0; i < lenin / wlen / 2; i++)
	{
		*poutput = (vcb)saturated_pack(*pinput, *(pinput + 1));
		poutput++;
		pinput += 2;
	}
	for (int j = i * 2 * wlen; j < lenin; j++)
	{
		output[j].re = input[j].re;
		output[j].im = input[j].im;
	}
}



// equivallent to sum(a .* conj(b))
struct complex32 __ext_sum_conj_mulw32(struct complex16* x, int __unused_20, struct complex16* y, int __unused_22) {
	struct complex32 ret;
	vi r1, r2;
	vcs *vx = (vcs *) x;
	vcs *vy = (vcs *) y;
	vcs vs1, vs2, sign;

	// xr*sr + xi*si, xi*si - xr*si
    vs1 = conj0(*vx);
    vs1 = permutate_low<1, 0, 3, 2>(vs1);
    vs1 = permutate_high<1, 0, 3, 2>(vs1);
	// pairwise_muladd takes most of the time here
    r1 = pairwise_muladd(*((vs*)vx), *((vs*)vy));
    r2 = pairwise_muladd((vs)vs1, *((vs*)vy));
	r1 = hadd(r1);
	r2 = hadd(r2);
	ret.re = ((struct complex32*) &r1) -> re;
	ret.im = ((struct complex32*) &r2) -> im;
	return ret;			  
}


// Sum 4 complex32 numbers
struct complex32 __ext_sumc32(struct complex32* x, int __unused_20) {
	struct complex32 ret;
	/*
	vi r1, r2;
	r1 = add(*((vi*)x),*((vi*)(x+2)));
	r2 = _mm_shuffle_epi32(r1, _MM_SHUFFLE(1, 0, 3, 2));
	r1 = add(r1, r2);
	ret = *((struct complex32*)(&r1));
	*/

	// The same speed as above - small vector
	ret.re = x[0].re + x[1].re + x[2].re + x[3].re;
	ret.im = x[0].im + x[1].im + x[2].im + x[3].im;
	return ret;
}

// Sum 4 complex16 numbers
struct complex16 __ext_sumc16(struct complex16* x, int __unused_20) {
	struct complex16 ret;
	/*
	vi r1, r2;
	r1 = add(*((vi*)x),*((vi*)(x+2)));
	r2 = _mm_shuffle_epi32(r1, _MM_SHUFFLE(1, 0, 3, 2));
	r1 = add(r1, r2);
	ret = *((struct complex32*)(&r1));
	*/

	// The same speed as above - small vector
	ret.re = x[0].re + x[1].re + x[2].re + x[3].re;
	ret.im = x[0].im + x[1].im + x[2].im + x[3].im;
	return ret;
}


FINL 
int32 __ext_sumi32(int32* x, int __unused_21)
{
	/*assert (__unused_21 == 4);
	assert (__unused_20 == 4);*/

	int16 ret = 0;

	
	//vi output;
	//vi *xi = (vi *)x;
	//output = hadd (*xi);
	//output = _mm_hadd_epi32(*xi,*xi);
	//output = _mm_hadd_epi32(output,output);
	//ret = *((int16*) (&output));
	
	// BOZIDAR: This is actually faster for a small array:
	for(int i=0; i<4; i++)
		ret += x[i];

	return ret;
}


// For some reason this particular FINL confuses the compiler/linker
//FINL
int16 __ext_sumi16(int16* x, int __unused_21)
{
	int16 ret = 0;

	//vi output;
	//vi *xi = (vi *)x;
	//output = hadd (*xi);
	//output = _mm_hadd_epi32(*xi,*xi);
	//output = _mm_hadd_epi32(output,output);
	//ret = *((int16*) (&output));

	// BOZIDAR: This is actually faster for a small array:
	for (int i = 0; i<4; i++)
		ret += x[i];

	return ret;
}



///// SSE bit operations



FORCE_INLINE
void __ext_v_or_48(uchar *output, uchar *input1, uchar *input2)
{
	unsigned __int32 i1, i2;
	unsigned __int16 j1, j2;

	i1 = *(unsigned __int32 *)input1;
	i2 = *(unsigned __int32 *)input2;
	*(unsigned __int32 *)output = i1 | i2;

	j1 = *(unsigned __int16 *)(input1 + 4);
	j2 = *(unsigned __int16 *)(input2 + 4);
	*(unsigned __int16 *)(output + 4) = j1 | j2;
}

FORCE_INLINE
void __ext_v_or_96(uchar *output, uchar *input1, uchar *input2)
{
	unsigned __int64 i1, i2;
	unsigned __int32 j1, j2;

	i1 = *(unsigned __int64 *)input1;
	i2 = *(unsigned __int64 *)input2;
	*(unsigned __int64 *)output = i1 | i2;

	j1 = *(unsigned __int32 *)(input1 + 8);
	j2 = *(unsigned __int32 *)(input2 + 8);
	*(unsigned __int32 *)(output + 8) = j1 | j2;
}

FORCE_INLINE
void __ext_v_or_192(uchar *output, uchar *input1, uchar *input2)
{

	unsigned __int64 i1, i2;

    // Strangely crashes ... 
	// vcs *pi1 = (vcs *)input1; 
	// vcs *pi2 = (vcs *)input2; 
	// vcs *po = (vcs *)output; 
	// *po = (vcs)_mm_and_si128(*pi1, *pi2); 

	i1 = *(unsigned __int64 *)(input1);
	i2 = *(unsigned __int64 *)(input2);
	*(unsigned __int64 *)(output) = i1 | i2;

	i1 = *(unsigned __int64 *)(input1+8);
	i2 = *(unsigned __int64 *)(input2+8);
	*(unsigned __int64 *)(output+8) = i1 | i2;

	i1 = *(unsigned __int64 *)(input1+16);
	i2 = *(unsigned __int64 *)(input2+16);
	*(unsigned __int64 *)(output+16) = i1 | i2;


}

FORCE_INLINE
void __ext_v_or_288(uchar *output, uchar *input1, uchar *input2)
{
	__ext_v_or_192(output, input1, input2);
	__ext_v_or_96(output + 24, input1 + 24, input2 + 24);

}


FORCE_INLINE
void __ext_v_or(uchar *output, int outlen, uchar *input1, int inlen1, uchar *input2, int inlen2) 
{
	int cnt;
	switch (inlen1) {
	case 48:
		__ext_v_or_48(output, input1, input2);
		break;
	case 96:
		__ext_v_or_96(output, input1, input2);
		break;
	case 192:
		__ext_v_or_192(output, input1, input2);
		break;
	case 288:
		__ext_v_or_288(output, input1, input2);
		break;

	default:
		for (cnt = 0; cnt < (inlen1 + 7) / 8; cnt++) 
		{
			output[cnt] = input1[cnt] | input2[cnt];
		}
		return;
	}
	return;

}




void __ext_v_and(uchar *output, int outlen, uchar *input1, int inlen1, uchar *input2, int inlen2)
{
	int cnt = 0;
	int bytelen1 = inlen1 / 8 + ((inlen1 % 8) > 0);
	vcs *pi1 = (vcs *)input1;
	vcs *pi2 = (vcs *)input2;
	vcs *po = (vcs *)output;

	while (cnt + 16 <= bytelen1)
	{
		*po = (vcs)_mm_and_si128(*pi1, *pi2);
		pi1++;
		pi2++;
		po++;
		cnt += 16;
	}

	while (cnt < bytelen1)
	{
		output[cnt] = input1[cnt] & input2[cnt];
		cnt++;
	}
	outlen = inlen1;
}


void __ext_v_andnot(uchar *output, int outlen, uchar *input1, int inlen1, uchar *input2, int inlen2)
{
	int cnt = 0;
	int bytelen1 = inlen1 / 8 + ((inlen1 % 8) > 0);
	vcs *pi1 = (vcs *)input1;
	vcs *pi2 = (vcs *)input2;
	vcs *po = (vcs *)output;

	while (cnt + 16 <= bytelen1)
	{
		*po = (vcs)_mm_andnot_si128(*pi1, *pi2);
		pi1++;
		pi2++;
		po++;
		cnt += 16;
	}

	while (cnt < bytelen1)
	{
		output[cnt] = (~input1[cnt]) & input2[cnt];
		cnt++;
	}
	outlen = inlen1;
}


void __ext_v_xor(uchar *output, int outlen, uchar *input1, int inlen1, uchar *input2, int inlen2)
{
	int cnt = 0;
	int bytelen1 = inlen1 / 8 + ((inlen1 % 8) > 0);
	vcs *pi1 = (vcs *)input1;
	vcs *pi2 = (vcs *)input2;
	vcs *po = (vcs *)output;

	while (cnt + 16 <= bytelen1)
	{
		*po = (vcs)_mm_xor_si128(*pi1, *pi2);
		pi1++;
		pi2++;
		po++;
		cnt += 16;
	}

	while (cnt < bytelen1)
	{
		output[cnt] = input1[cnt] ^ input2[cnt];
		cnt++;
	}
	outlen = inlen1;
}








///// Interface to Sora integer trigonometry


int16 __ext_cos_int16 ( int16 y ) {
  return (int16) ucos(y);
}


int16 __ext_sin_int16 ( int16 y ) {
  return (int16) usin(y);
}


int16 __ext_atan2_int16 ( int16 y, int16 x ) {
  return (int16) uatan2((int)y, (int)x);
}

int32 __ext_atan2_int32 ( int32 y, int32 x ) {
  return uatan2((int)y, (int)x);
}





// *** FFT


//FINL 
// int __ext_sora_fft(short nFFTSize, struct complex16 * input, int unused1, struct complex16* output, int unused2)
void __ext_sora_fft(struct complex16* output, int nFFTSize, struct complex16 * input, int unused1)
{
	vcs *in = (vcs*)input;
	vcs *out = (vcs*)output;

	// We use the safe version to respect Blink's semantic
	switch (nFFTSize) {
	case 16:
		FFTSafe<16>(in, out);
		break;
	case 32:
		FFTSafe<32>(in, out);
		break;
	case 64:
		FFTSafe<64>(in, out);
		break;
	case 128:
		FFTSafe<128>(in, out);
		break;
	case 256:
		FFTSafe<256>(in, out);
		break;
	case 512:
		FFTSafe<512>(in, out);
		break;
	case 1024:
		FFTSafe<1024>(in, out);
		break;
	case 2048:
		FFTSafe<2048>(in, out);
		break;
	// LTE compatibility
	case 12:
		FFTSafe<12>(in, out);
		break;
	case 24:
		FFTSafe<24>(in, out);
		break;
	case 36:
		FFTSafe<36>(in, out);
		break;
	case 48:
		FFTSafe<48>(in, out);
		break;
	case 60:
		FFTSafe<60>(in, out);
		break;
	case 72:
		FFTSafe<72>(in, out);
		break;
	case 96:
		FFTSafe<96>(in, out);
		break;
	case 108:
		FFTSafe<108>(in, out);
		break;
	case 120:
		FFTSafe<120>(in, out);
		break;
	case 144:
		FFTSafe<144>(in, out);
		break;
	case 180:
		FFTSafe<180>(in, out);
		break;
	case 192:
		FFTSafe<192>(in, out);
		break;
	case 216:
		FFTSafe<216>(in, out);
		break;
	case 240:
		FFTSafe<240>(in, out);
		break;
	case 288:
		FFTSafe<288>(in, out);
		break;
	case 300:
		FFTSafe<300>(in, out);
		break;
	case 324:
		FFTSafe<324>(in, out);
		break;
	case 360:
		FFTSafe<360>(in, out);
		break;
	case 384:
		FFTSafe<384>(in, out);
		break;
	case 432:
		FFTSafe<432>(in, out);
		break;
	case 480:
		FFTSafe<480>(in, out);
		break;
	case 540:
		FFTSafe<540>(in, out);
		break;
	case 576:
		FFTSafe<576>(in, out);
		break;
	case 600:
		FFTSafe<600>(in, out);
		break;
	case 648:
		FFTSafe<648>(in, out);
		break;
	case 720:
		FFTSafe<720>(in, out);
		break;
	case 768:
		FFTSafe<768>(in, out);
		break;
	case 864:
		FFTSafe<864>(in, out);
		break;
	case 900:
		FFTSafe<900>(in, out);
		break;
	case 960:
		FFTSafe<960>(in, out);
		break;
	case 972:
		FFTSafe<972>(in, out);
		break;
	case 1080:
		FFTSafe<1080>(in, out);
		break;
	case 1152:
		FFTSafe<1152>(in, out);
		break;
	case 1200:
		FFTSafe<1200>(in, out);
		break;
	default:
		printf("__ext_sora_fft error: fft size %d not supported!\n", nFFTSize);
		break;
	}

	// because UNIT is 0
	//return 0;
}

void __ext_sora_fft_dynamic(struct complex16* output, int unused2, int16 nFFTSize, struct complex16 * input, int unused1)
{
	__ext_sora_fft(output, nFFTSize, input, unused1);
}




//int __ext_sora_ifft(short nFFTSize, struct complex16 * input, int unused1, struct complex16* output, int unused2)
void __ext_sora_ifft(struct complex16* output, int nFFTSize, struct complex16 * input, int unused1)
{
	vcs *in = (vcs*)input;
	vcs *out = (vcs*)output;

	// We use the safe version to respect Blink's semantic
	//	IFFT<128> (temp, pcOutput );
	switch (nFFTSize) {
	case 16:
		IFFTSafe<16>(in, out);
		break;
	case 32:
		IFFTSafe<32>(in, out);
		break;
	case 64:
		IFFTSafe<64>(in, out);
		break;
	case 128:
		IFFTSafe<128>(in, out);
		break;
	case 256:
		IFFTSafe<256>(in, out);
		break;
	case 512:
		IFFTSafe<512>(in, out);
		break;
	case 1024:
		IFFTSafe<1024>(in, out);
		break;
	case 2048:
		IFFTSafe<2048>(in, out);
		break;
	// LTE compatibility
		// LTE compatibility
	case 12:
		IFFTSafe<12>(in, out);
		break;
	case 24:
		IFFTSafe<24>(in, out);
		break;
	case 36:
		IFFTSafe<36>(in, out);
		break;
	case 48:
		IFFTSafe<48>(in, out);
		break;
	case 60:
		IFFTSafe<60>(in, out);
		break;
	case 72:
		IFFTSafe<72>(in, out);
		break;
	case 96:
		IFFTSafe<96>(in, out);
		break;
	case 108:
		IFFTSafe<108>(in, out);
		break;
	case 120:
		IFFTSafe<120>(in, out);
		break;
	case 144:
		IFFTSafe<144>(in, out);
		break;
	case 180:
		IFFTSafe<180>(in, out);
		break;
	case 192:
		IFFTSafe<192>(in, out);
		break;
	case 216:
		IFFTSafe<216>(in, out);
		break;
	case 240:
		IFFTSafe<240>(in, out);
		break;
	case 288:
		IFFTSafe<288>(in, out);
		break;
	case 300:
		IFFTSafe<300>(in, out);
		break;
	case 324:
		IFFTSafe<324>(in, out);
		break;
	case 360:
		IFFTSafe<360>(in, out);
		break;
	case 384:
		IFFTSafe<384>(in, out);
		break;
	case 432:
		IFFTSafe<432>(in, out);
		break;
	case 480:
		IFFTSafe<480>(in, out);
		break;
	case 540:
		IFFTSafe<540>(in, out);
		break;
	case 576:
		IFFTSafe<576>(in, out);
		break;
	case 600:
		IFFTSafe<600>(in, out);
		break;
	case 648:
		IFFTSafe<648>(in, out);
		break;
	case 720:
		IFFTSafe<720>(in, out);
		break;
	case 768:
		IFFTSafe<768>(in, out);
		break;
	case 864:
		IFFTSafe<864>(in, out);
		break;
	case 900:
		IFFTSafe<900>(in, out);
		break;
	case 960:
		IFFTSafe<960>(in, out);
		break;
	case 972:
		IFFTSafe<972>(in, out);
		break;
	case 1080:
		IFFTSafe<1080>(in, out);
		break;
	case 1152:
		IFFTSafe<1152>(in, out);
		break;
	case 1200:
		IFFTSafe<1200>(in, out);
		break;
	default:
		printf("__ext_sora_ifft error: fft size %d not supported!\n", nFFTSize);
		break;
	}

	//return 0;
}

void __ext_sora_ifft_dynamic(struct complex16* output, int unused2, int16 nFFTSize, struct complex16 * input, int unused1)
{
	__ext_sora_ifft(output, nFFTSize, input, unused1);
}







// Currently we only support one Viterbi running at a time
ViterbiContext ctx;

int __ext_viterbi_brick_init(int frame_len, int16 code_rate) {
	initViterbi(&ctx, frame_len, (ushort) code_rate);
	return 0;
}

int __ext_viterbiSig11a_brick_init(int frame_len, int16 code_rate) {
	initViterbiSig11a(&ctx, frame_len, (ushort)code_rate);
	return 0;
}

int16 __ext_viterbi_brick_decode(char* intInput, int len1, uchar* bit, int len2)
{
	return processViterbi(&ctx, intInput, bit);
}




// Time-related

extern TimeMeasurements measurementInfo;

// TODO: Once 64-bits numbers are supported convert this into getTime 
// and return the time as a 64-bit number
int __ext_print_time() {
	ULONGLONG time = SoraGetCPUTimestamp(&measurementInfo.tsinfo);
	printf("%ul\n", time);
	fflush(stdout);
	return 0;
}

ULONGLONG record_time = 0;
int __ext_record_time_start() {
	record_time = SoraGetCPUTimestamp(&measurementInfo.tsinfo);
	return 0;
}
int __ext_record_time_stop() {
	ULONGLONG record_end_time = SoraGetCPUTimestamp(&measurementInfo.tsinfo);
	printf("Elapsed(ns):%ul\n", record_end_time - record_time);
	fflush(stdout);
	return 0;
}

#include <time.h>

int __ext_populate_rand_array(BitArrPtr arr, int siz) {

	srand(time(NULL));
	for (int i = 0; i < siz/8; i++)
	{
		arr[i] = (unsigned char)rand(); // it's random anyway
	}
	return 0;
}

