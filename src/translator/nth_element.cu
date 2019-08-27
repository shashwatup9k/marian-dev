/* All or part of this file was contributed by Intel under license:
 *   Copyright (C) 2017-2018 Intel Corporation
 *   SPDX-License-Identifier: MIT
 */

#include <iostream>

#include "translator/nth_element.h"

#include <cuda.h>
#include "tensors/gpu/cuda_helpers.h"

namespace marian {

#define UNROLL_MAXARG_LOOP(n, max)       \
  if(tid < (n) && tid + (n) < (max)) {   \
    if(sdata[tid + (n)] > sdata[tid]) {  \
      sdata[tid] = sdata[tid + (n)];     \
      indices[tid] = indices[tid + (n)]; \
    }                                    \
  }

template <typename T>
__global__ void gMaxElement(float* d_out,
                            int* d_ind,
                            T* d_in, // this is the probs array, only one with type float or half
                            int numBatches,
                            int* batchFirstElementIdxs,
                            float minimal) {
  extern __shared__ float sdata[];
  __shared__ int indices[512];

  int tid = threadIdx.x;

  for(int batchIdx = 0; batchIdx < numBatches; ++batchIdx) {
    int begin = batchFirstElementIdxs[batchIdx];
    int end = batchFirstElementIdxs[batchIdx + 1];

    int i = begin + blockIdx.x * (blockDim.x * 2) + tid;

    sdata[tid] = minimal;

    if(i < end) {
      sdata[tid] = (float)d_in[i];
      indices[tid] = i;
    }

    if(i + blockDim.x < end) {
      float a = (float)d_in[i];
      float b = (float)d_in[i + blockDim.x];
      if(a > b) {
        sdata[tid] = a;
        indices[tid] = i;
      } else {
        sdata[tid] = b;
        indices[tid] = i + blockDim.x;
      }
    }

    while(i + 2 * gridDim.x * blockDim.x < end) {
      i += 2 * gridDim.x * blockDim.x;

      float a = (float)d_in[i];
      if(a > sdata[tid]) {
        sdata[tid] = a;
        indices[tid] = i;
      }

      if(i + blockDim.x < end) {
        float b = (float)d_in[i + blockDim.x];
        if(b > sdata[tid]) {
          sdata[tid] = b;
          indices[tid] = i + blockDim.x;
        }
      }
    }

    __syncthreads();

    for(int s = (blockDim.x >> 1); s > 32; s >>= 1) {
      if(tid < s && tid + s < end) {
        if(sdata[tid + s] > sdata[tid]) {
          sdata[tid] = sdata[tid + s];
          indices[tid] = indices[tid + s];
        }
      }
      __syncthreads();
    }

    UNROLL_MAXARG_LOOP(32, end);
    UNROLL_MAXARG_LOOP(16, end);
    UNROLL_MAXARG_LOOP(8, end);
    UNROLL_MAXARG_LOOP(4, end);
    UNROLL_MAXARG_LOOP(2, end);
    UNROLL_MAXARG_LOOP(1, end);

    if(tid == 0) {
      d_out[blockIdx.x + batchIdx * gridDim.x] = sdata[0];
      d_ind[blockIdx.x + batchIdx * gridDim.x] = indices[0];
    }
    __syncthreads();
  }
}

template <typename T>
__global__ void gMaxElementUpdate(float* binCosts,
                                  int* binIdxs,
                                  T* probs, // should work well enough with half, uses float everywhere else
                                  int* batchFirstElements,
                                  float* outCosts,
                                  int* outIdxs,
                                  int* cummulatedBeamSizes,
                                  int NUM_BLOCKS,
                                  float minimal) {
  extern __shared__ float sdata[];
  __shared__ int indices[512];
  __shared__ float bestBinCost;
  __shared__ int bestBinCostIdx;

  const int tid = threadIdx.x;
  const int batchIdx = blockIdx.x;
  const int N = batchFirstElements[batchIdx + 1] - batchFirstElements[batchIdx];
  int num_bins = int(N / (2 * 512)) + int(N % (2 * 512) != 0);
  if(num_bins > 500) {
    num_bins = 500;
  }

  for(int pos = cummulatedBeamSizes[batchIdx];
      pos < cummulatedBeamSizes[batchIdx + 1];
      ++pos) {
    int i = tid;

    sdata[tid] = minimal;

    if(i < num_bins) {
      sdata[tid] = binCosts[batchIdx * NUM_BLOCKS + i];
      indices[tid] = i;
    }

    if(i + blockDim.x < num_bins) {
      float a = binCosts[batchIdx * NUM_BLOCKS + i];
      float b = binCosts[batchIdx * NUM_BLOCKS + i + blockDim.x];
      if(a > b) {
        sdata[tid] = a;
        indices[tid] = i;
      } else {
        sdata[tid] = b;
        indices[tid] = i + blockDim.x;
      }
    }

    while(i + 2 * blockDim.x < num_bins) {
      i += 2 * blockDim.x;

      float a = binCosts[batchIdx * NUM_BLOCKS + i];
      if(a > sdata[tid]) {
        sdata[tid] = a;
        indices[tid] = i;
      }

      if(i + blockDim.x < num_bins) {
        float b = binCosts[batchIdx * NUM_BLOCKS + i + blockDim.x];
        if(b > sdata[tid]) {
          sdata[tid] = b;
          indices[tid] = i + blockDim.x;
        }
      }
    }

    __syncthreads();

    for(int s = (blockDim.x >> 1); s > 32; s >>= 1) {
      if(tid < s && tid + s < num_bins) {
        if(sdata[tid + s] > sdata[tid]) {
          sdata[tid] = sdata[tid + s];
          indices[tid] = indices[tid + s];
        }
      }
      __syncthreads();
    }

    UNROLL_MAXARG_LOOP(32, num_bins);
    UNROLL_MAXARG_LOOP(16, num_bins);
    UNROLL_MAXARG_LOOP(8, num_bins);
    UNROLL_MAXARG_LOOP(4, num_bins);
    UNROLL_MAXARG_LOOP(2, num_bins);
    UNROLL_MAXARG_LOOP(1, num_bins);

    if(tid == 0) {
      bestBinCost = sdata[0];
      bestBinCostIdx = batchIdx * NUM_BLOCKS + indices[0];

      probs[binIdxs[bestBinCostIdx]] = minimal;

      outIdxs[pos] = binIdxs[bestBinCostIdx];
      outCosts[pos] = bestBinCost;
    }

    __syncthreads();

    i = batchFirstElements[batchIdx]
        + (bestBinCostIdx - batchIdx * NUM_BLOCKS) * (blockDim.x * 2) + tid;
    const int dist = num_bins * 2 * blockDim.x;

    sdata[tid] = minimal;

    if(i < batchFirstElements[batchIdx + 1]) {
      sdata[tid] = (float)probs[i];
      indices[tid] = i;
    }

    if(i + blockDim.x < batchFirstElements[batchIdx + 1]) {
      float a = (float)probs[i];
      float b = (float)probs[i + blockDim.x];
      if(a > b) {
        sdata[tid] = a;
        indices[tid] = i;
      } else {
        sdata[tid] = b;
        indices[tid] = i + blockDim.x;
      }
    }

    while(i + dist < batchFirstElements[batchIdx + 1]) {
      i += dist;

      float a = (float)probs[i];
      if(a > sdata[tid]) {
        sdata[tid] = a;
        indices[tid] = i;
      }

      if(i + blockDim.x < batchFirstElements[batchIdx + 1]) {
        float b = (float)probs[i + blockDim.x];
        if(b > sdata[tid]) {
          sdata[tid] = b;
          indices[tid] = i + blockDim.x;
        }
      }
    }

    __syncthreads();

    for(int s = (blockDim.x >> 1); s > 32; s >>= 1) {
      if(tid < s && tid + s < batchFirstElements[batchIdx + 1]) {
        if(sdata[tid + s] > sdata[tid]) {
          sdata[tid] = sdata[tid + s];
          indices[tid] = indices[tid + s];
        }
      }
      __syncthreads();
    }

    UNROLL_MAXARG_LOOP(32, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(16, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(8, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(4, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(2, batchFirstElements[batchIdx + 1]);
    UNROLL_MAXARG_LOOP(1, batchFirstElements[batchIdx + 1]);

    if(tid == 0) {
      binCosts[bestBinCostIdx] = sdata[0];
      binIdxs[bestBinCostIdx] = indices[0];
    }
    __syncthreads();
  }
}

class NthElementGPU {
public:
  NthElementGPU() = delete;
  NthElementGPU(const NthElementGPU& copy) = delete;

  NthElementGPU(size_t maxBeamSize,
                size_t maxBatchSize,
                DeviceId deviceId)
      : deviceId_(deviceId),
        NUM_BLOCKS(std::min(
            500,
            int(maxBeamSize* MAX_VOCAB_SIZE / (2 * BLOCK_SIZE))
                + int(maxBeamSize* MAX_VOCAB_SIZE % (2 * BLOCK_SIZE) != 0))) {
    // std::cerr << "NthElement::NthElement" << std::endl;

    cudaSetDevice(deviceId_.no);

    CUDA_CHECK(cudaMalloc((void**)&d_ind, maxBatchSize * NUM_BLOCKS * sizeof(int)));
    CUDA_CHECK(cudaMalloc((void**)&d_out, maxBatchSize * NUM_BLOCKS * sizeof(float)));

    CUDA_CHECK(cudaMalloc((void**)&d_res_idx, maxBatchSize * maxBeamSize * sizeof(int)));
    CUDA_CHECK(cudaMalloc((void**)&d_res,     maxBatchSize * maxBeamSize * sizeof(float)));

    CUDA_CHECK(cudaHostAlloc((void**)&h_res,     maxBeamSize * maxBatchSize * sizeof(float), cudaHostAllocDefault));
    CUDA_CHECK(cudaHostAlloc((void**)&h_res_idx, maxBeamSize * maxBatchSize * sizeof(int), cudaHostAllocDefault));

    CUDA_CHECK(cudaMalloc((void**)&d_breakdown, maxBeamSize * sizeof(float)));
    CUDA_CHECK(cudaMalloc((void**)&d_batchPosition, (maxBatchSize + 1) * sizeof(int)));
    CUDA_CHECK(cudaMalloc((void**)&d_cumBeamSizes,  (maxBatchSize + 1) * sizeof(int)));
  }

  ~NthElementGPU() {
    cudaSetDevice(deviceId_.no);

    CUDA_CHECK(cudaFree(d_cumBeamSizes));
    CUDA_CHECK(cudaFree(d_batchPosition));
    CUDA_CHECK(cudaFree(d_breakdown));
    CUDA_CHECK(cudaFreeHost(h_res_idx));
    CUDA_CHECK(cudaFreeHost(h_res));
    CUDA_CHECK(cudaFree(d_res));
    CUDA_CHECK(cudaFree(d_res_idx));
    CUDA_CHECK(cudaFree(d_out));
    CUDA_CHECK(cudaFree(d_ind));
  }

private:
  template <typename T>
  void getNBestList(T* probs,
                    const std::vector<int>& batchFirstElementIdxs,
                    const std::vector<int>& cummulatedBeamSizes,
                    float minimal) {

    cudaSetDevice(deviceId_.no);
    CUDA_CHECK(cudaMemcpyAsync(d_batchPosition,
                               batchFirstElementIdxs.data(),
                               batchFirstElementIdxs.size() * sizeof(int),
                               cudaMemcpyHostToDevice,
                               /* stream_ */ 0));
    CUDA_CHECK(cudaMemcpyAsync(d_cumBeamSizes,
                               cummulatedBeamSizes.data(),
                               cummulatedBeamSizes.size() * sizeof(int),
                               cudaMemcpyHostToDevice,
                               /* stream_ */ 0));

    const int numBatches = batchFirstElementIdxs.size() - 1;

    gMaxElement<<<NUM_BLOCKS,
                  BLOCK_SIZE,
                  BLOCK_SIZE * sizeof(float), // shared memory size
                  /* stream_ */ 0>>>(
        d_out, d_ind, probs, numBatches, d_batchPosition, minimal);

    gMaxElementUpdate<<<numBatches,
                        BLOCK_SIZE,
                        BLOCK_SIZE * sizeof(float),  // shared memory size
                        /* stream_ */ 0>>>(d_out,
                                           d_ind,
                                           probs,
                                           d_batchPosition,
                                           d_res,
                                           d_res_idx,
                                           d_cumBeamSizes,
                                           NUM_BLOCKS,
                                           minimal);
  }

public:
  void getNBestList(const std::vector<size_t>& beamSizes,
                    Tensor Probs,
                    std::vector<float>& outCosts,
                    std::vector<unsigned>& outKeys,
                    const bool isFirst) {
    cudaSetDevice(deviceId_.no);

    std::vector<int> cummulatedBeamSizes(beamSizes.size() + 1, 0);
    std::vector<int> batchFirstElementIdxs(beamSizes.size() + 1, 0);

    const size_t vocabSize = Probs->shape()[-1];
    ABORT_IF(vocabSize > MAX_VOCAB_SIZE, "Reached maximum vocab size. File an issue on gitub");

    for(size_t i = 0; i < beamSizes.size(); ++i) {
      cummulatedBeamSizes[i + 1] = cummulatedBeamSizes[i] + beamSizes[i];
      batchFirstElementIdxs[i + 1]
          += ((isFirst) ? (i + 1) : cummulatedBeamSizes[i + 1]) * vocabSize;
    }

    if(Probs->type() == Type::float32) {
      float minimal = std::numeric_limits<float>::lowest();
      getNBestList(Probs->data<float>(), batchFirstElementIdxs, cummulatedBeamSizes, minimal);
    } else if(Probs->type() == Type::float16) {
      float minimal = std::numeric_limits<float16>::lowest();
      getNBestList(Probs->data<half>(), batchFirstElementIdxs, cummulatedBeamSizes, minimal);
    } else {
      ABORT("getNBestList not implemented for type {}", Probs->type());
    }
    getPairs(cummulatedBeamSizes.back(), outKeys, outCosts);
  }

private:
  void getPairs(size_t number,
                std::vector<unsigned>& outKeys,
                std::vector<float>& outCosts) {
    cudaSetDevice(deviceId_.no);
    CUDA_CHECK(cudaMemcpyAsync(h_res,
                               d_res,
                               number * sizeof(float),
                               cudaMemcpyDeviceToHost,
                               /* stream_ */ 0));
    CUDA_CHECK(cudaMemcpyAsync(h_res_idx,
                               d_res_idx,
                               number * sizeof(int),
                               cudaMemcpyDeviceToHost,
                               /* stream_ */ 0));
    cudaStreamSynchronize(/* stream_ */ 0);

    for(size_t i = 0; i < number; ++i) {
      outKeys.push_back(h_res_idx[i]);
      outCosts.push_back(h_res[i]);
    }

    lastN = number;
  }

  DeviceId deviceId_;

  const int MAX_VOCAB_SIZE = 100000;

  const int BLOCK_SIZE = 512;
  const int NUM_BLOCKS;
  int* d_ind;

  float* d_out;

  int* d_res_idx;
  float* d_res;

  int* h_res_idx;
  float* h_res;

  float* d_breakdown;
  int* d_batchPosition;
  int* d_cumBeamSizes;
  size_t lastN;
};

// factory function
// Returns a lambda with the same signature as the getNBestList() function.
GetNBestListFn createGetNBestListGPUFn(size_t beamSize, size_t dimBatch, DeviceId deviceId) {
  auto nth = New<NthElementGPU>(beamSize, dimBatch, deviceId);
  return [nth](const std::vector<size_t>& beamSizes,
      Tensor logProbs,
      std::vector<float>& outCosts,
      std::vector<unsigned>& outKeys,
      const bool isFirst) {
      return nth->getNBestList(beamSizes, logProbs, outCosts, outKeys, isFirst);
  };
}

}  // namespace marian
