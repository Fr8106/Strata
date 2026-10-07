// t9: reproduce the engine's fill failure WITHOUT stopping the LLM (1.36 GiB free regime).
// Usage: t9 <dev-gib> <runs> <run-mib> [mapped]
//   dev-gib  device memory to allocate first (0 = none)
//   runs     number of pinned runs (0 = no pin)
//   run-mib  size of each run
//   mapped   add cudaHostRegisterMapped
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>

int main(int argc, char** argv) {
    const double dev_gib = argc > 1 ? atof(argv[1]) : 0.0;
    const int runs = argc > 2 ? atoi(argv[2]) : 0;
    const double run_mib = argc > 3 ? atof(argv[3]) : 5.5;
    const bool mapped = argc > 4 && !strcmp(argv[4], "mapped");

    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }
    size_t free_b = 0, tot_b = 0;
    cudaMemGetInfo(&free_b, &tot_b);
    std::printf("VRAM: %.2f GiB free\n", (double) free_b / 1073741824.0);

    uint8_t* dev = nullptr;
    if (dev_gib > 0) {
        if (cudaMalloc(&dev, (size_t) (dev_gib * 1073741824.0)) != cudaSuccess) {
            std::printf("cudaMalloc: %s\n", cudaGetErrorString(cudaGetLastError()));
            return 1;
        }
    }
    cudaMemGetInfo(&free_b, &tot_b);
    std::printf("after device alloc: %.2f GiB free\n", (double) free_b / 1073741824.0);

    const size_t run = (size_t) (run_mib * 1048576.0);
    const size_t arena = (size_t) runs * run;
    uint8_t* base = (uint8_t*) malloc(arena ? arena : 4096);
    if (!base) { std::printf("malloc %.0f GiB arena failed\n", (double) arena / 1073741824.0); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;

    int refused = 0;
    for (int r = 0; r < runs; ++r) {
        const unsigned flags = cudaHostRegisterPortable | (mapped ? cudaHostRegisterMapped : 0);
        if (cudaHostRegister(base + r * run, run, flags) != cudaSuccess) {
            if (refused++ == 0) std::printf("first refused register: %s\n", cudaGetErrorString(cudaGetLastError()));
        }
    }
    std::printf("pinned %d/%d runs x %.1f MiB%s, %d refused\n", runs - refused, runs, run_mib,
                mapped ? " (mapped)" : "", refused);

    const size_t n = 1380000;
    e = cudaMemcpy(dev ? (void*) dev : (void*) base, base + 1024, n, cudaMemcpyHostToDevice);
    std::printf("HtoD 1.38 MiB -> %s", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf(" (pending: %s)", cudaGetErrorString(cudaGetLastError()));
    std::printf("\n");
    return e == cudaSuccess ? 0 : 3;
}
