// t10: exact replica of the engine's state at the failing fill.
// Usage: t10 <variant>
//   engine          probe + 30.4 GiB device + 46.84 GiB arena + 35.66 GiB plain pin (4424x8.5MiB) + HtoD
//   engine-noprobe  same, no probe preamble
//   engine-nopins   same, no registration
//   engine-mapped   same, MAPPED registration
//   engine-pin1     same, one big registration of the whole arena
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>

static void free_b() {
    size_t f = 0, t = 0;
    if (cudaMemGetInfo(&f, &t) == cudaSuccess)
        std::printf("  VRAM free: %.2f GiB\n", (double) f / 1073741824.0);
}

int main(int argc, char** argv) {
    const char* v = argc > 1 ? argv[1] : "engine";
    const bool probe   = !std::strcmp(v, "engine") || !std::strcmp(v, "engine-mapped") ||
                         !std::strcmp(v, "engine-pin1");
    const bool pin     = !std::strcmp(v, "engine") || !std::strcmp(v, "engine-mapped") ||
                         !std::strcmp(v, "engine-pin1");
    const bool mapped  = !std::strcmp(v, "engine-mapped");
    const bool pin1    = !std::strcmp(v, "engine-pin1");

    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }
    std::printf("variant: %s\n", v);

    // engine preamble: the PCIe probe does cudaHostAlloc + device buffer + copies BEFORE the arena
    if (probe) {
        void *ph = nullptr, *pd = nullptr;
        e = cudaHostAlloc(&ph, 256 << 20, cudaHostAllocDefault);
        if (e != cudaSuccess) { std::printf("probe hostAlloc: %s\n", cudaGetErrorString(e)); return 1; }
        if (cudaMalloc(&pd, 256 << 20) != cudaSuccess) { std::printf("probe devAlloc: %s\n",
                cudaGetErrorString(cudaGetLastError())); return 1; }
        e = cudaMemcpy(pd, ph, 256 << 20, cudaMemcpyHostToDevice);
        std::printf("probe HtoD 256 MiB: %s\n", cudaGetErrorString(e));
        if (e != cudaSuccess) { std::printf("  pending: %s\n", cudaGetErrorString(cudaGetLastError())); }
        cudaFree(pd);
    }

    // device occupancy: 22.39 GiB cache arena + ~8 GiB of the rest (MTP/Q5_K/PLE/KV/heads)
    const size_t d1 = (size_t) (22.39 * 1073741824.0);
    const size_t d2 = 8ull << 30;
    void *a1 = nullptr, *a2 = nullptr;
    if (cudaMalloc(&a1, d1) != cudaSuccess) { std::printf("cache cudaMalloc: %s\n",
            cudaGetErrorString(cudaGetLastError())); return 1; }
    if (cudaMalloc(&a2, d2) != cudaSuccess) { std::printf("rest cudaMalloc: %s\n",
            cudaGetErrorString(cudaGetLastError())); return 1; }
    free_b();

    // host arena: the engine's 46.84 GiB, fully faulted in
    const size_t arena = (size_t) (46.84 * 1073741824.0);
    uint8_t* base = (uint8_t*) malloc(arena);
    if (!base) { std::printf("malloc 46.84 GiB failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;
    std::printf("arena 46.84 GiB touched\n");

    // registration: the engine's 4424 runs of ~8.5 MiB (35.66 GiB) of the non-fixed half
    const size_t half = arena / 2;
    if (pin) {
        if (pin1) {
            e = cudaHostRegister(base, arena,
                    mapped ? (cudaHostRegisterPortable | cudaHostRegisterMapped) : cudaHostRegisterPortable);
            std::printf("whole-arena register: %s\n", cudaGetErrorString(e));
            if (e != cudaSuccess) (void) cudaGetLastError();
        } else {
            const int runs = 4424;
            const size_t run = half / runs;   // ~8.5 MiB
            int refused = 0, ok = 0;
            for (int r = 0; r < runs; ++r) {
                e = cudaHostRegister(base + half + r * run, run,
                        mapped ? (cudaHostRegisterPortable | cudaHostRegisterMapped) : cudaHostRegisterPortable);
                if (e != cudaSuccess) {
                    if (refused++ == 0) std::printf("first refused run: %s\n", cudaGetErrorString(cudaGetLastError()));
                } else ++ok;
            }
            std::printf("pinned %d/%d runs x %.1f MiB (%.2f GiB), %d refused\n", ok, runs,
                         (double) run / 1048576.0, (double) (ok * run) / 1073741824.0, refused);
        }
    }

    // the failing call: 1.38 MiB HtoD into the cache arena, source in the UNregistered half
    const size_t n = 1380000;
    e = cudaMemcpy(a1, base + 1024, n, cudaMemcpyHostToDevice);
    std::printf("FILL HtoD 1.38 MiB -> %s", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf(" (pending: %s)", cudaGetErrorString(cudaGetLastError()));
    std::printf("\n");
    free_b();
    return e == cudaSuccess ? 0 : 3;
}
