// t8: isolate what breaks HtoD cudaMemcpy after selective pinning on a near-full GPU.
// Usage: t8 <scenario>
//   full      29 GiB device allocs + arena touched + HtoD from UNregistered host ptr
//   full-pin4424  full + 4424 plain-pin runs (~8.5 MiB each)
//   full-pin1     full + one big pin of the whole arena
//   full-pin1-mapped  full + one big MAPPED pin
//   light-pin4424  small device allocs + 4424 plain-pin runs + HtoD
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>

static uint8_t *dev_buf = nullptr;
static size_t dev_bytes = 0;

int main(int argc, char** argv) {
    const char* sc = argc > 1 ? argv[1] : "full";
    const bool big_dev = !std::strcmp(sc, "full") || !std::strcmp(sc, "full-pin4424") ||
                         !std::strcmp(sc, "full-pin1") || !std::strcmp(sc, "full-pin1-mapped");
    const bool pin4424 = !std::strcmp(sc, "full-pin4424") || !std::strcmp(sc, "light-pin4424");
    const bool pin1 = !std::strcmp(sc, "full-pin1");
    const bool pin1m = !std::strcmp(sc, "full-pin1-mapped");

    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }
    size_t free_b = 0, tot_b = 0;
    cudaMemGetInfo(&free_b, &tot_b);
    std::printf("VRAM: %.2f GiB free of %.2f GiB\n", (double) free_b / 1073741824.0,
                (double) tot_b / 1073741824.0);

    // device occupancy
    dev_bytes = big_dev ? 29ull << 30 : 512ull << 20;
    if (cudaMalloc((void**) &dev_buf, dev_bytes) != cudaSuccess) {
        std::printf("cudaMalloc(%.1f GiB): %s\n", (double) dev_bytes / 1073741824.0,
                    cudaGetErrorString(cudaGetLastError()));
        return 1;
    }
    std::printf("device: %.1f GiB allocated\n", (double) dev_bytes / 1073741824.0);

    // host arena: 8 GiB is enough (the engine's 46.84 GiB is the same class of object)
    const size_t arena = 8ull << 30;
    uint8_t* base = (uint8_t*) malloc(arena);
    if (!base) { std::printf("malloc arena failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;   // touch every page

    int refused = 0, runs = 0;
    if (pin4424) {
        // mimic the engine: ~4424 runs of ~8.5 MiB (non-fixed blobs of a 50/50 split)
        const size_t nruns = 4424, run = (arena / 2) / nruns;   // ~916 KiB each of the non-fixed half
        for (size_t r = 0; r < nruns; ++r) {
            const size_t off = (arena / 2) + r * run;
            if (cudaHostRegister(base + off, run, cudaHostRegisterPortable) != cudaSuccess) {
                if (refused++ == 0) std::printf("run0 register: %s\n", cudaGetErrorString(cudaGetLastError()));
            } else ++runs;
        }
        std::printf("pinned %d/%zu runs (%.1f MiB each), %d refused\n", runs, nruns,
                     (double) run / 1048576.0, refused);
    }
    if (pin1 || pin1m) {
        const unsigned flags = pin1m ? (cudaHostRegisterPortable | cudaHostRegisterMapped)
                                     : cudaHostRegisterPortable;
        e = cudaHostRegister(base, arena, flags);
        std::printf("big %s register: %s\n", pin1m ? "MAPPED" : "plain", cudaGetErrorString(e));
        if (e != cudaSuccess) (void) cudaGetLastError();
    }

    // the failing call: HtoD of 1.38 MiB (an expert blob size) from the host arena
    const size_t n = 1380000;
    uint8_t* src = base + 1024;   // inside the unregistered half (pin4424 pins the upper half)
    e = cudaMemcpy(dev_buf, src, n, cudaMemcpyHostToDevice);
    std::printf("HtoD 1.38 MiB -> %s", cudaGetErrorString(e));
    if (e != cudaSuccess)
        std::printf(" (pending: %s)", cudaGetErrorString(cudaGetLastError()));
    std::printf("\n");
    return e == cudaSuccess ? 0 : 3;
}
