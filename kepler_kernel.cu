/* Copyright (C) 2013 David G. Andersen. All rights reserved.
 * with modifications by Christian Buchner
 *
 * Use of this code is covered under the Apache 2.0 license, which
 * can be found in the file "LICENSE"
 */

// TODO: attempt V.Volkov style ILP (factor 4)

#ifdef WIN32
#include <windows.h>
#endif
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <inttypes.h>

#include <cuda.h>

#include "miner.h"
#include "kepler_kernel.h"

#define TEXWIDTH 32768

// scratchbuf constants (pointers to scratch buffer for each warp, i.e. 32 hashes)
__constant__ uint32_t* c_V[1024];

// iteration count N
__constant__ uint32_t c_N;
__constant__ uint32_t c_N_1;                  // N-1
// scratch buffer size SCRATCH
__constant__ uint32_t c_SCRATCH;
__constant__ uint32_t c_SCRATCH_WU_PER_WARP;  // SCRATCH * WU_PER_WARP

// using texture references for the "tex" variants of the B kernels
texture<uint4, 1, cudaReadModeElementType> texRef1D_4_V;
texture<uint4, 2, cudaReadModeElementType> texRef2D_4_V;

static const int THREADS_PER_SCRYPT_BLOCK = 4;

static __host__ __device__ uint4& operator^=(uint4& left, const uint4& right)
{
    left.x ^= right.x;
    left.y ^= right.y;
    left.z ^= right.z;
    left.w ^= right.w;
    return left;
}

static __host__ __device__ uint4& operator+=(uint4& left, const uint4& right)
{
    left.x += right.x;
    left.y += right.y;
    left.z += right.z;
    left.w += right.w;
    return left;
}

/* write_keys writes the 8 keys being processed by a warp to the global
 * scratchpad. To effectively use memory bandwidth, it performs the writes
 * (and reads, for read_keys) 128 bytes at a time per memory location
 * by __shfl'ing the 4 entries in bx to the threads in the next-up
 * thread group. It then has eight threads together perform uint4
 * (128 bit) writes to the destination region. This seems to make
 * quite effective use of memory bandwidth. An approach that spread
 * uint32s across more threads was slower because of the increased
 * computation it required.
 *
 * "start" is the loop iteration producing the write - the offset within
 * the block's memory.
 *
 * Internally, this algorithm first __shfl's the 4 bx entries to
 * the next up thread group, and then uses a conditional move to
 * ensure that odd-numbered thread groups exchange the b/bx ordering
 * so that the right parts are written together.
 *
 * Thanks to Babu for helping design the 128-bit-per-write version.
 *
 * _direct lets the caller specify the absolute start location instead of
 * the relative start location, as an attempt to reduce some recomputation.
 */

__device__ __forceinline__
void write_keys_direct(const uint4 &b, const uint4 &bx, uint32_t start) {

  start += 4*(threadIdx.x%4);

  uint32_t *scratch = c_V[(blockIdx.x*blockDim.x + threadIdx.x)/(THREADS_PER_SCRYPT_BLOCK * warpSize)];

  *((uint4 *)(&scratch[ start    %(c_SCRATCH_WU_PER_WARP)])) = b;
  *((uint4 *)(&scratch[(start+16)%(c_SCRATCH_WU_PER_WARP)])) = bx;
}

template <int TEX_DIM> __device__  __forceinline__ void read_keys_direct(uint4 &b, uint4 &bx, uint32_t start) {

  start += 4*(threadIdx.x%4);

  uint32_t *scratch;
  if (TEX_DIM == 0) scratch = c_V[(blockIdx.x*blockDim.x + threadIdx.x)/(THREADS_PER_SCRYPT_BLOCK * warpSize)];

  unsigned int loc =  start     / ((TEX_DIM > 0) ? 4 : 1);
       if (TEX_DIM == 0) b = *((uint4 *)(&scratch[loc%(c_SCRATCH_WU_PER_WARP)]));
  else if (TEX_DIM == 1) b = tex1Dfetch(texRef1D_4_V, loc);
  else if (TEX_DIM == 2) b = tex2D(texRef2D_4_V, 0.5f + (loc%TEXWIDTH), 0.5f + (loc/TEXWIDTH));
               loc = (start+16) / ((TEX_DIM > 0) ? 4 : 1);
       if (TEX_DIM == 0) bx = *((uint4 *)(&scratch[loc%(c_SCRATCH_WU_PER_WARP)]));
  else if (TEX_DIM == 1) bx = tex1Dfetch(texRef1D_4_V, loc);
  else if (TEX_DIM == 2) bx = tex2D(texRef2D_4_V, 0.5f + (loc%TEXWIDTH), 0.5f + (loc/TEXWIDTH));
}


template <int TEX_DIM> __device__  __forceinline__ void read_xor_keys_direct(uint4 &b, uint4 &bx, uint32_t start) {

  start += 4*(threadIdx.x%4);

  uint32_t *scratch;
  if (TEX_DIM == 0) scratch = c_V[(blockIdx.x*blockDim.x + threadIdx.x)/(THREADS_PER_SCRYPT_BLOCK * warpSize)];

  unsigned int loc =  start     / ((TEX_DIM > 0) ? 4 : 1);
       if (TEX_DIM == 0) b ^= *((uint4 *)(&scratch[loc%(c_SCRATCH_WU_PER_WARP)]));
  else if (TEX_DIM == 1) b ^= tex1Dfetch(texRef1D_4_V, loc);
  else if (TEX_DIM == 2) b ^= tex2D(texRef2D_4_V, 0.5f + (loc%TEXWIDTH), 0.5f + (loc/TEXWIDTH));
               loc = (start+16) / ((TEX_DIM > 0) ? 4 : 1);
       if (TEX_DIM == 0) bx ^= *((uint4 *)(&scratch[loc%(c_SCRATCH_WU_PER_WARP)]));
  else if (TEX_DIM == 1) bx ^= tex1Dfetch(texRef1D_4_V, loc);
  else if (TEX_DIM == 2) bx ^= tex2D(texRef2D_4_V, 0.5f + (loc%TEXWIDTH), 0.5f + (loc/TEXWIDTH));
}


__device__  __forceinline__ void primary_order_shuffle(uint4 &b, uint4 &bx) {
  /* Inner loop shuffle targets */
  int x1_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+1)&0x3);
  int x2_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+2)&0x3);
  int x3_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+3)&0x3);
  
  b.w = __shfl((int)b.w, x1_target_lane);
  b.z = __shfl((int)b.z, x2_target_lane);
  b.y = __shfl((int)b.y, x3_target_lane);
  uint32_t tmp = b.y; b.y = b.w; b.w = tmp;
  
  bx.w = __shfl((int)bx.w, x1_target_lane);
  bx.z = __shfl((int)bx.z, x2_target_lane);
  bx.y = __shfl((int)bx.y, x3_target_lane);
  tmp = bx.y; bx.y = bx.w; bx.w = tmp;
}

/*
 * load_key loads a 32*32bit key from a contiguous region of memory in B.
 * The input keys are in external order (i.e., 0, 1, 2, 3, ...).
 * After loading, each thread has its four b and four bx keys stored
 * in internal processing order.
 */

__device__  __forceinline__ void load_key_salsa(const uint32_t *B, uint4 &b, uint4 &bx) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int key_offset = scrypt_block * 32;
  uint32_t thread_in_block = threadIdx.x % 4;

  // Read in permuted order. Key loads are not our bottleneck right now.
  b.x = B[key_offset + 4*thread_in_block + (thread_in_block+0)%4];
  b.y = B[key_offset + 4*thread_in_block + (thread_in_block+1)%4];
  b.z = B[key_offset + 4*thread_in_block + (thread_in_block+2)%4];
  b.w = B[key_offset + 4*thread_in_block + (thread_in_block+3)%4];
  bx.x = B[key_offset + 4*thread_in_block + (thread_in_block+0)%4 + 16];
  bx.y = B[key_offset + 4*thread_in_block + (thread_in_block+1)%4 + 16];
  bx.z = B[key_offset + 4*thread_in_block + (thread_in_block+2)%4 + 16];
  bx.w = B[key_offset + 4*thread_in_block + (thread_in_block+3)%4 + 16];

  primary_order_shuffle(b, bx);
}

/*
 * store_key performs the opposite transform as load_key, taking
 * internally-ordered b and bx and storing them into a contiguous
 * region of B in external order.
 */

__device__  __forceinline__ void store_key_salsa(uint32_t *B, uint4 &b, uint4 &bx) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int key_offset = scrypt_block * 32;
  uint32_t thread_in_block = threadIdx.x % 4;

  primary_order_shuffle(b, bx);

  B[key_offset + 4*thread_in_block + (thread_in_block+0)%4] = b.x;
  B[key_offset + 4*thread_in_block + (thread_in_block+1)%4] = b.y;
  B[key_offset + 4*thread_in_block + (thread_in_block+2)%4] = b.z;
  B[key_offset + 4*thread_in_block + (thread_in_block+3)%4] = b.w;
  B[key_offset + 4*thread_in_block + (thread_in_block+0)%4 + 16] = bx.x;
  B[key_offset + 4*thread_in_block + (thread_in_block+1)%4 + 16] = bx.y;
  B[key_offset + 4*thread_in_block + (thread_in_block+2)%4 + 16] = bx.z;
  B[key_offset + 4*thread_in_block + (thread_in_block+3)%4 + 16] = bx.w;
}


/*
 * load_key loads a 32*32bit key from a contiguous region of memory in B.
 * The input keys are in external order (i.e., 0, 1, 2, 3, ...).
 * After loading, each thread has its four b and four bx keys stored
 * in internal processing order.
 */

__device__  __forceinline__ void load_key_chacha(const uint32_t *B, uint4 &b, uint4 &bx) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int key_offset = scrypt_block * 32;
  uint32_t thread_in_block = threadIdx.x % 4;

  // Read in permuted order. Key loads are not our bottleneck right now.
  b.x = B[key_offset + 4*0 + thread_in_block%4];
  b.y = B[key_offset + 4*1 + thread_in_block%4];
  b.z = B[key_offset + 4*2 + thread_in_block%4];
  b.w = B[key_offset + 4*3 + thread_in_block%4];
  bx.x = B[key_offset + 4*0 + thread_in_block%4 + 16];
  bx.y = B[key_offset + 4*1 + thread_in_block%4 + 16];
  bx.z = B[key_offset + 4*2 + thread_in_block%4 + 16];
  bx.w = B[key_offset + 4*3 + thread_in_block%4 + 16];
}

/*
 * store_key performs the opposite transform as load_key, taking
 * internally-ordered b and bx and storing them into a contiguous
 * region of B in external order.
 */

__device__  __forceinline__ void store_key_chacha(uint32_t *B, const uint4 &b, const uint4 &bx) {
  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int key_offset = scrypt_block * 32;
  uint32_t thread_in_block = threadIdx.x % 4;

  B[key_offset + 4*0 + thread_in_block%4] = b.x;
  B[key_offset + 4*1 + thread_in_block%4] = b.y;
  B[key_offset + 4*2 + thread_in_block%4] = b.z;
  B[key_offset + 4*3 + thread_in_block%4] = b.w;
  B[key_offset + 4*0 + thread_in_block%4 + 16] = bx.x;
  B[key_offset + 4*1 + thread_in_block%4 + 16] = bx.y;
  B[key_offset + 4*2 + thread_in_block%4 + 16] = bx.z;
  B[key_offset + 4*3 + thread_in_block%4 + 16] = bx.w;
}


/*
 * salsa_xor_core (Salsa20/8 cypher)
 * The original scrypt called:
 * xor_salsa8(&X[0], &X[16]); <-- the "b" loop
 * xor_salsa8(&X[16], &X[0]); <-- the "bx" loop
 * This version is unrolled to handle both of these loops in a single
 * call to avoid unnecessary data movement.
 */

#define XOR_ROTATE_ADD(dst, s1, s2, amt) { uint32_t tmp = s1+s2; dst ^= ((tmp<<amt)|(tmp>>(32-amt))); }

__device__  __forceinline__ void salsa_xor_core(uint4 &b, uint4 &bx,
                                 const int x1_target_lane,
                                 const int x2_target_lane,
                                 const int x3_target_lane) {
    uint4 x;

    b ^= bx;
    x = b;

    // Enter in "primary order" (t0 has  0,  4,  8, 12)
    //                          (t1 has  5,  9, 13,  1)
    //                          (t2 has 10, 14,  2,  6)
    //                          (t3 has 15,  3,  7, 11)

#pragma unroll 4
    for (int j = 0; j < 4; j++) {
    
      // Mixing phase of salsa
      XOR_ROTATE_ADD(x.y, x.x, x.w, 7);
      XOR_ROTATE_ADD(x.z, x.y, x.x, 9);
      XOR_ROTATE_ADD(x.w, x.z, x.y, 13);
      XOR_ROTATE_ADD(x.x, x.w, x.z, 18);
      
      /* Transpose rows and columns. */
      /* Unclear if this optimization is needed: These are ordered based
       * upon the dependencies needed in the later xors. Compiler should be
       * able to figure this out, but might as well give it a hand. */
      x.y = __shfl((int)x.y, x3_target_lane);
      x.w = __shfl((int)x.w, x1_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
      
      /* The next XOR_ROTATE_ADDS could be written to be a copy-paste of the first,
       * but the register targets are rewritten here to swap x[1] and x[3] so that
       * they can be directly shuffled to and from our peer threads without
       * reassignment. The reverse shuffle then puts them back in the right place.
       */
      
      XOR_ROTATE_ADD(x.w, x.x, x.y, 7);
      XOR_ROTATE_ADD(x.z, x.w, x.x, 9);
      XOR_ROTATE_ADD(x.y, x.z, x.w, 13);
      XOR_ROTATE_ADD(x.x, x.y, x.z, 18);
      
      x.w = __shfl((int)x.w, x3_target_lane);
      x.y = __shfl((int)x.y, x1_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
    }

    b += x;
    // The next two lines are the beginning of the BX-centric loop iteration
    bx ^= b;
    x = bx;

    // This is a copy of the same loop above, identical but stripped of comments.
    // Duplicated so that we can complete a bx-based loop with fewer register moves.
#pragma unroll 4
    for (int j = 0; j < 4; j++) {
      XOR_ROTATE_ADD(x.y, x.x, x.w, 7);
      XOR_ROTATE_ADD(x.z, x.y, x.x, 9);
      XOR_ROTATE_ADD(x.w, x.z, x.y, 13);
      XOR_ROTATE_ADD(x.x, x.w, x.z, 18);
      
      x.y = __shfl((int)x.y, x3_target_lane);
      x.w = __shfl((int)x.w, x1_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
      
      XOR_ROTATE_ADD(x.w, x.x, x.y, 7);
      XOR_ROTATE_ADD(x.z, x.w, x.x, 9);
      XOR_ROTATE_ADD(x.y, x.z, x.w, 13);
      XOR_ROTATE_ADD(x.x, x.y, x.z, 18);
      
      x.w = __shfl((int)x.w, x3_target_lane);
      x.y = __shfl((int)x.y, x1_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
    }

    // At the end of these iterations, the data is in primary order again.
#undef XOR_ROTATE_ADD

    bx += x;
}


/*
 * chacha_xor_core (ChaCha20/8 cypher)
 * This version is unrolled to handle both of these loops in a single
 * call to avoid unnecessary data movement.
 * 
 * load_key and store_key must not use primary order when
 * using ChaCha20/8, but rather the basic transposed order
 * (referred to as "column mode" below)
 */

#define CHACHA_PRIMITIVE(pt, rt, ps, amt) { uint32_t tmp = rt ^ (pt += ps); rt = ((tmp<<amt)|(tmp>>(32-amt))); }

__device__  __forceinline__ void chacha_xor_core(uint4 &b, uint4 &bx,
                                 const int x1_target_lane,
                                 const int x2_target_lane,
                                 const int x3_target_lane) {
    uint4 x;

    b ^= bx;
    x = b;

    // Enter in "column" mode (t0 has 0, 4,  8, 12)
    //                        (t1 has 1, 5,  9, 13)
    //                        (t2 has 2, 6, 10, 14)
    //                        (t3 has 3, 7, 11, 15)

#pragma unroll 4
    for (int j = 0; j < 4; j++) {
    
      // Column Mixing phase of chacha
      CHACHA_PRIMITIVE(x.x ,x.w, x.y, 16)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w, 12)
      CHACHA_PRIMITIVE(x.x ,x.w, x.y,  8)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w,  7)
      
      x.y = __shfl((int)x.y, x1_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
      x.w = __shfl((int)x.w, x3_target_lane);
      
      // Diagonal Mixing phase of chacha
      CHACHA_PRIMITIVE(x.x ,x.w, x.y, 16)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w, 12)
      CHACHA_PRIMITIVE(x.x ,x.w, x.y,  8)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w,  7)
      
      x.y = __shfl((int)x.y, x3_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
      x.w = __shfl((int)x.w, x1_target_lane);
    }

    b += x;
    // The next two lines are the beginning of the BX-centric loop iteration
    bx ^= b;
    x = bx;

#pragma unroll 4
    for (int j = 0; j < 4; j++) {

      // Column Mixing phase of chacha
      CHACHA_PRIMITIVE(x.x ,x.w, x.y, 16)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w, 12)
      CHACHA_PRIMITIVE(x.x ,x.w, x.y,  8)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w,  7)
      
      x.y = __shfl((int)x.y, x1_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
      x.w = __shfl((int)x.w, x3_target_lane);
      
      // Diagonal Mixing phase of chacha
      CHACHA_PRIMITIVE(x.x ,x.w, x.y, 16)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w, 12)
      CHACHA_PRIMITIVE(x.x ,x.w, x.y,  8)
      CHACHA_PRIMITIVE(x.z ,x.y, x.w,  7)
      
      x.y = __shfl((int)x.y, x3_target_lane);
      x.z = __shfl((int)x.z, x2_target_lane);
      x.w = __shfl((int)x.w, x1_target_lane);
    }

#undef CHACHA_PRIMITIVE

    bx += x;
}


/*
 * The hasher_gen_kernel operates on a group of 1024-bit input keys
 * in B, stored as:
 * B = { k1B k1Bx k2B k2Bx ... }
 * and fills up the scratchpad with the iterative hashes derived from
 * those keys:
 * scratch { k1h1B k1h1Bx K1h2B K1h2Bx ... K2h1B K2h1Bx K2h2B K2h2Bx ... }
 * scratch is 1024 times larger than the input keys B.
 * It is extremely important to stream writes effectively into scratch;
 * less important to coalesce the reads from B.
 *
 * Key ordering note: Keys are input from B in "original" order:
 * K = {k1, k2, k3, k4, k5, ..., kx15, kx16, kx17, ..., kx31 }
 * After inputting into kernel_gen, each component k and kx of the
 * key is transmuted into a permuted internal order to make processing faster:
 * K = k, kx with:
 * k = 0, 4, 8, 12, 5, 9, 13, 1, 10, 14, 2, 6, 15, 3, 7, 11
 * and similarly for kx.
 */

template <int ALGO> __global__
void kepler_scrypt_core_kernelA(const uint32_t *d_idata, int begin, int end) {

  /* Each thread operates on four of the sixteen B and Bx variables. Thus,
   * each key is processed by four threads in parallel. salsa_scrypt_core
   * internally shuffles the variables between threads (and back) as
   * needed.
   */
  uint4 b, bx;

  /* Inner loop shuffle targets */
  int x1_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+1)&0x3);
  int x2_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+2)&0x3);
  int x3_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+3)&0x3);

  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int start = scrypt_block*c_SCRATCH;

  int i=begin;

  if (i == 0)
  {
      switch(ALGO) {
        case ALGO_SCRYPT:      load_key_salsa(d_idata, b, bx); break;
        case ALGO_SCRYPT_JANE: load_key_chacha(d_idata, b, bx); break;
      }
      write_keys_direct(b, bx, start);
      ++i;
  }
  else
  {
      read_keys_direct<0>(b, bx, start+32*(i-1));
  }
  
  while (i < end) {
    switch(ALGO) {
      case ALGO_SCRYPT:      salsa_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane); break;
      case ALGO_SCRYPT_JANE: chacha_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane); break;
    }
    write_keys_direct(b, bx, start+32*i);
    ++i;
  }
}


/*
 * hasher_hash_kernel runs the second phase of scrypt after the scratch
 * buffer is filled with the iterative hashes: It bounces through
 * the scratch buffer in pseudorandom order, mixing the key as it goes.
 */

template <int ALGO, int TEX_DIM> __global__
void kepler_scrypt_core_kernelB(uint32_t *d_odata, int begin, int end) {

  /* Each thread operates on a group of four variables that must be processed
   * together. Shuffle between threaads in a warp between iterations.
   */
  uint4 b, bx;

  int scrypt_block = (blockIdx.x*blockDim.x + threadIdx.x)/THREADS_PER_SCRYPT_BLOCK;
  int start = scrypt_block*c_SCRATCH;

  /* Inner loop shuffle targets */
  int x1_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+1)&0x3);
  int x2_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+2)&0x3);
  int x3_target_lane = (threadIdx.x & 0x1c) + (((threadIdx.x & 0x03)+3)&0x3);

  if (begin == 0)
  {
      read_keys_direct<TEX_DIM>(b, bx, start+32*(c_N_1));

      switch(ALGO) {
        case ALGO_SCRYPT:      salsa_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane); break;
        case ALGO_SCRYPT_JANE: chacha_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane); break;
      }
  }
  else
  {
      switch(ALGO) {
        case ALGO_SCRYPT:      load_key_salsa(d_odata, b, bx); break;
        case ALGO_SCRYPT_JANE: load_key_chacha(d_odata, b, bx); break;
      }
  }

  for (int i = begin; i < end; i++) {

    // Bounce through the key space and XOR the new keys in.
    // Critical thing: (X[16] & (c_N_1)) tells us the next slot to read.
    // X[16] in the original is bx.x
    read_xor_keys_direct<TEX_DIM>(b, bx, start+32*(__shfl((int)bx.x, (threadIdx.x & 0x1c)) & (c_N_1)));
    switch(ALGO) {
      case ALGO_SCRYPT:      salsa_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane); break;
      case ALGO_SCRYPT_JANE: chacha_xor_core(b, bx, x1_target_lane, x2_target_lane, x3_target_lane); break;
    }
  }

  switch(ALGO) {
    case ALGO_SCRYPT:      store_key_salsa(d_odata, b, bx); break;
    case ALGO_SCRYPT_JANE: store_key_chacha(d_odata, b, bx); break;
  }
}

KeplerKernel::KeplerKernel() : KernelInterface()
{
}

bool KeplerKernel::bindtexture_1D(uint32_t *d_V, size_t size)
{
    cudaChannelFormatDesc channelDesc4 = cudaCreateChannelDesc<uint4>();
    texRef1D_4_V.normalized = 0;
    texRef1D_4_V.filterMode = cudaFilterModePoint;
    texRef1D_4_V.addressMode[0] = cudaAddressModeClamp;
    checkCudaErrors(cudaBindTexture(NULL, &texRef1D_4_V, d_V, &channelDesc4, size));
    return true;
}

bool KeplerKernel::bindtexture_2D(uint32_t *d_V, int width, int height, size_t pitch)
{
    cudaChannelFormatDesc channelDesc4 = cudaCreateChannelDesc<uint4>();
    texRef2D_4_V.normalized = 0;
    texRef2D_4_V.filterMode = cudaFilterModePoint;
    texRef2D_4_V.addressMode[0] = cudaAddressModeClamp;
    texRef2D_4_V.addressMode[1] = cudaAddressModeClamp;
    // maintain texture width of TEXWIDTH (max. limit is 65000)
    while (width > TEXWIDTH) { width /= 2; height *= 2; pitch /= 2; }
    while (width < TEXWIDTH) { width *= 2; height = (height+1)/2; pitch *= 2; }
//    fprintf(stderr, "total size: %u, %u bytes\n", pitch * height, width * sizeof(uint32_t) * 4 * height);
//    fprintf(stderr, "binding width width=%d, height=%d, pitch=%d\n", width, height,pitch);
    checkCudaErrors(cudaBindTexture2D(NULL, &texRef2D_4_V, d_V, &channelDesc4, width, height, pitch));
    return true;
}

bool KeplerKernel::unbindtexture_1D()
{
    checkCudaErrors(cudaUnbindTexture(texRef1D_4_V));
    return true;
}

bool KeplerKernel::unbindtexture_2D()
{
    checkCudaErrors(cudaUnbindTexture(texRef2D_4_V));
    return true;
}

void KeplerKernel::set_scratchbuf_constants(int MAXWARPS, uint32_t** h_V)
{
    checkCudaErrors(cudaMemcpyToSymbol(c_V, h_V, MAXWARPS*sizeof(uint32_t*), 0, cudaMemcpyHostToDevice));
}

bool KeplerKernel::run_kernel(dim3 grid, dim3 threads, int WARPS_PER_BLOCK, int thr_id, cudaStream_t stream, uint32_t* d_idata, uint32_t* d_odata, unsigned int N, bool interactive, bool benchmark, int texture_cache)
{
    bool success = true;

    // clear CUDA's error variable
    cudaGetLastError();

    // this kernel needs 4 threads per work unit. 
    switch(opt_algo) {
      case ALGO_SCRYPT: grid.x *= 4; break; // scrypt: We scale up the grid x dimension to compensate.
      case ALGO_SCRYPT_JANE: threads.x *= 4; break; // scrypt-jane: we scale up thread block size
    }
    
    // make some constants available to kernel, update only initially and when changing
    static int prev_N = 0;
    if (N != prev_N) {
        uint32_t h_N = N;
        checkCudaErrors(cudaMemcpyToSymbolAsync(c_N, &h_N, sizeof(uint32_t), 0, cudaMemcpyHostToDevice, stream));
        prev_N = N;
        uint32_t h_N_1 = N-1;
        checkCudaErrors(cudaMemcpyToSymbolAsync(c_N_1, &h_N_1, sizeof(uint32_t), 0, cudaMemcpyHostToDevice, stream));
        uint32_t h_SCRATCH = SCRATCH;
        checkCudaErrors(cudaMemcpyToSymbolAsync(c_SCRATCH, &h_SCRATCH, sizeof(uint32_t), 0, cudaMemcpyHostToDevice, stream));
        uint32_t h_SCRATCH_WU_PER_WARP = SCRATCH * WU_PER_WARP;
        checkCudaErrors(cudaMemcpyToSymbolAsync(c_SCRATCH_WU_PER_WARP, &h_SCRATCH_WU_PER_WARP, sizeof(uint32_t), 0, cudaMemcpyHostToDevice, stream));
    }

    // First phase: Sequential writes to scratchpad.

    int batch = device_batchsize[thr_id];
    int num_sleeps = 2* ((N + (batch-1)) / batch);
    int sleeptime = 100;
    int situation = 0;

    // Optional sleep in between kernels
    if (!benchmark && interactive) {
        checkCudaErrors(MyStreamSynchronize(stream, ++situation, thr_id));
        usleep(sleeptime);
    }

    int pos = 0;
    do 
    {
        switch(opt_algo) {
          case ALGO_SCRYPT: kepler_scrypt_core_kernelA<ALGO_SCRYPT><<< grid, threads, 0, stream >>>(d_idata, pos, min(pos+batch, N)); break;
          case ALGO_SCRYPT_JANE: kepler_scrypt_core_kernelA<ALGO_SCRYPT_JANE><<< grid, threads, 0, stream >>>(d_idata, pos, min(pos+batch, N)); break;
        }

        // Optional sleep in between kernels
        if (!benchmark && interactive) {
            checkCudaErrors(MyStreamSynchronize(stream, ++situation, thr_id));
            usleep(sleeptime);
        }
        pos += batch;
    } while (pos < N);

    // Second phase: Random read access from scratchpad.

    pos = 0;
    do
    {
        // Optional sleep in between kernels
        if (pos > 0 && !benchmark && interactive) {
            checkCudaErrors(MyStreamSynchronize(stream, ++situation, thr_id));
            usleep(sleeptime);
        }

        if (texture_cache)
        {
            if (texture_cache == 1)
                switch(opt_algo) {
                    case ALGO_SCRYPT: kepler_scrypt_core_kernelB<ALGO_SCRYPT,1><<< grid, threads, 0, stream >>>(d_odata, pos, min(pos+batch, N)); break;
                    case ALGO_SCRYPT_JANE: kepler_scrypt_core_kernelB<ALGO_SCRYPT_JANE,1><<< grid, threads, 0, stream >>>(d_odata, pos, min(pos+batch, N)); break;
                }
            else if (texture_cache == 2)
                switch(opt_algo) {
                    case ALGO_SCRYPT: kepler_scrypt_core_kernelB<ALGO_SCRYPT,2><<< grid, threads, 0, stream >>>(d_odata, pos, min(pos+batch, N)); break;
                    case ALGO_SCRYPT_JANE: kepler_scrypt_core_kernelB<ALGO_SCRYPT_JANE,2><<< grid, threads, 0, stream >>>(d_odata, pos, min(pos+batch, N)); break;
                }
        }
        else
            switch(opt_algo) {
                case ALGO_SCRYPT: kepler_scrypt_core_kernelB<ALGO_SCRYPT,0><<< grid, threads, 0, stream >>>(d_odata, pos, min(pos+batch, N)); break;
                case ALGO_SCRYPT_JANE: kepler_scrypt_core_kernelB<ALGO_SCRYPT_JANE,0><<< grid, threads, 0, stream >>>(d_odata, pos, min(pos+batch, N)); break;
        }
        pos += batch;
    } while (pos < N);

    // catch any kernel launch failures
    if (cudaPeekAtLastError() != cudaSuccess) success = false;

    return success;
}
