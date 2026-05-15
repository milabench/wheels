#pragma once

#include "../extensions.h"

#define CHECK_CUDA(x)                                                          \
  AT_ASSERTM(x.device().is_cuda(), #x " must be CUDA tensor")
#define CHECK_INPUT(x) AT_ASSERTM(x, "Input mismatch")

#ifdef USE_ROCM

__device__ __inline__ at::Half __ldg(const at::Half* ptr) {
  return __ldg(reinterpret_cast<const __half*>(ptr));
}

// ROCm 7.2+ requires explicit at::Half overloads to resolve ambiguity
// with new __half warp intrinsic overloads.
__device__ __inline__ at::Half
__shfl(const at::Half var, int srcLane, int width = warpSize) {
  return static_cast<at::Half>(
      __shfl(static_cast<__half>(var), srcLane, width));
}

__device__ __inline__ at::Half
__shfl_down(const at::Half var, unsigned int delta, int width = warpSize) {
  return static_cast<at::Half>(
      __shfl_down(static_cast<__half>(var), delta, width));
}

__device__ __inline__ at::Half
__shfl_up(const at::Half var, unsigned int delta, int width = warpSize) {
  return static_cast<at::Half>(
      __shfl_up(static_cast<__half>(var), delta, width));
}

#define SHFL_UP_SYNC(mask, var, delta) __shfl_up(var, delta)
#define SHFL_DOWN_SYNC(mask, var, delta) __shfl_down(var, delta)
#define SHFL_SYNC(mask, var, delta) __shfl(var, delta)

#else

__device__ __inline__ at::Half
__shfl_sync(const unsigned mask, const at::Half var, const int srcLane) {
  return __shfl_sync(mask, var.operator __half(), srcLane);
}

__device__ __inline__ at::Half __shfl_down_sync(const unsigned mask,
                                                const at::Half var,
                                                const unsigned int delta) {
  return __shfl_down_sync(mask, var.operator __half(), delta);
}

#define SHFL_UP_SYNC __shfl_up_sync
#define SHFL_DOWN_SYNC __shfl_down_sync
#define SHFL_SYNC __shfl_sync

#endif
