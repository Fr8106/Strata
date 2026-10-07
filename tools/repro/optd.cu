// Option-D microtest (docs/reviews/OPTIMIZATION-SUGGESTIONS-2026-10-07, direction: HMM direct reads).
// This box: PageableMemoryAccess = YES (HMM, 5090 + open kernel module).  Question: does an UNregistered
// (pageable) HtoD copy reach the bandwidth of a registered one?  If yes, the "no registration at all"
// shape (P1-like memory, P0-like speed) is viable.  Small VRAM footprint (~128 MiB) so it runs with the
// swift15 container live.
#include <cuda_runtime.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>

using clk = std::chrono::steady_clock;

// HtoD `bytes` from host into dev, return GB/s (3 timed runs, best)
static double hto_d_GBps(void* dev, const void* host, size_t bytes, const char* label) {
    // warm the path once, untimed (first copy can allocate driver resources)
    if (cudaMemcpy(dev, host, (1u << 20), cudaMemcpyHostToDevice) != cudaSuccess) {
        std::fprintf(stderr, "%s: warm-up copy failed: %s\n", label, cudaGetErrorString(cudaGetLastError()));
        return -1;
    }
    double best = 0;
    for (int r = 0; r < 3; ++r) {
        const auto t0 = clk::now();
        if (cudaMemcpy(dev, host, bytes, cudaMemcpyHostToDevice) != cudaSuccess) {
            std::fprintf(stderr, "%s: copy failed: %s\n", label, cudaGetErrorString(cudaGetLastError()));
            return -1;
        }
        cudaDeviceSynchronize();
        best = std::max(best, (double) bytes / std::chrono::duration<double>(clk::now() - t0).count() / 1e9);
    }
    std::printf("%-28s %.2f GB/s\n", label, best);
    return best;
}

int main() {
    const size_t MB = 1u << 20, bytes = 128ull << 20;
    void* dev = nullptr;
    if (cudaMalloc(&dev, bytes) != cudaSuccess) {
        std::fprintf(stderr, "cudaMalloc(%zu MiB) failed: %s (not enough free VRAM with the other workload)\n",
                     bytes / MB, cudaGetErrorString(cudaGetLastError()));
        return 2;
    }
    // 1) pageable: a plain malloc, NO registration (the HMM path)
    void* host = std::malloc(bytes);
    if (!host) { std::fprintf(stderr, "malloc failed\n"); return 2; }
    for (size_t i = 0; i < bytes; i += 4096) ((char*) host)[i] = (char) i;
    const double page = hto_d_GBps(dev, host, bytes, "pageable (HMM, unregistered)");
    std::free(host);
    // 2) registered: the same shape, pinned
    double reg = -1;
    void* pinned = nullptr;
    if (cudaHostAlloc(&pinned, bytes, cudaHostAllocDefault) == cudaSuccess) {
        reg = hto_d_GBps(dev, pinned, bytes, "registered (cudaHostAlloc)");
        cudaFreeHost(pinned);
    }
    cudaFree(dev);
    if (page > 0 && reg > 0)
        std::printf("pageable/registered ratio: %.2f\n", page / reg);
    return 0;
}
