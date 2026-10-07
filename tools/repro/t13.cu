// t13: total-pinned-bytes hypothesis.  The engine pins ~44 GiB of host memory in total
// (34.87 GiB arena runs + 3.09 GiB KV + 6.14 GiB conversation cache + 0.26 GiB probe)
// beside a ~30 GiB device context.  Replicate the TOTAL, not the run shape:
//   29 GiB device + 9.14 GiB pre-pinned host (the KV/convcache analogue) + 4628 runs x 8 MiB.
// If this fails where t10 (same runs, no pre-pin) passed, the driver's user-memory
// byte total is the limit, not the run count.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

int main() {
    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }

    void* d1 = nullptr;
    if (cudaMalloc(&d1, (size_t) (29.0 * 1073741824.0)) != cudaSuccess) {
        std::printf("cudaMalloc 29 GiB: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 1;
    }
    size_t fb = 0, tb = 0;
    cudaMemGetInfo(&fb, &tb);
    std::printf("VRAM free after device: %.2f GiB\n", (double) fb / 1073741824.0);

    // the engine's non-arena pinned blocks, before the arena registration
    void* kv = nullptr;
    if (cudaHostAlloc(&kv, (size_t) (9.14 * 1073741824.0), cudaHostAllocDefault) != cudaSuccess) {
        std::printf("pre-pin 9.14 GiB: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 2;
    }
    std::printf("pre-pinned 9.14 GiB (KV/convcache analogue)\n");

    const size_t arena = (size_t) (46.84 * 1073741824.0);
    uint8_t* base = (uint8_t*) malloc(arena);
    if (!base) { std::printf("malloc arena failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;

    const int runs = 4628;
    const size_t run = (size_t) (8 * 1048576.0);
    const size_t pinned = (size_t) (34.87 * 1073741824.0);
    int ok = 0;
    for (int r = 0; r < runs; ++r) {
        const size_t off = arena - pinned + r * run;
        if (off + run > arena) break;
        if (cudaHostRegister(base + off, run, cudaHostRegisterPortable) != cudaSuccess) {
            if (ok == 0) std::printf("first refused: %s\n", cudaGetErrorString(cudaGetLastError()));
            continue;
        }
        ++ok;
    }
    std::printf("pinned %d/%d runs x 8 MiB (%.2f GiB) + 9.14 GiB pre-pin\n", ok, runs,
                (double) (pinned) / 1073741824.0);

    const size_t n = 2176000;
    uint8_t* src = base + arena - pinned + run + 4096;   // inside a registered run
    e = cudaMemcpy(d1, src, n, cudaMemcpyHostToDevice);
    std::printf("HtoD from registered run -> %s", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf(" (pending: %s)", cudaGetErrorString(cudaGetLastError()));
    std::printf("\n");
    return e == cudaSuccess ? 0 : 3;
}
