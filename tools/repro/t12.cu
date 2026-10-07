// t12: pin-total + RAM-coexistence + alias-D2D matrix (the engine's remaining untested dimensions).
// Usage: t12 <variant>
//   p76          4424 MAPPED runs pinning 76% (35.66 GiB) + HtoD from a registered region
//   p76-ple      p76 + the 26.8 GB PLE gguf mapped and touched (the engine's RAM state)
//   p76-alias    p76 + D2D copy from run 0's device alias
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>
#if !defined(_WIN32)
#include <sys/mman.h>
#include <fcntl.h>
#endif

int main(int argc, char** argv) {
    const char* v = argc > 1 ? argv[1] : "p76";
    const bool ple = !std::strcmp(v, "p76-ple");
    const bool alias = !std::strcmp(v, "p76-alias");

    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }

    void* d1 = nullptr, *d2 = nullptr;
    if (cudaMalloc(&d1, (size_t) (22.39 * 1073741824.0)) != cudaSuccess ||
        cudaMalloc(&d2, 8ull << 30) != cudaSuccess) {
        std::printf("device alloc: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 1;
    }
    size_t fb = 0, tb = 0;
    cudaMemGetInfo(&fb, &tb);
    std::printf("%s: VRAM %.2f GiB free\n", v, (double) fb / 1073741824.0);

#if !defined(_WIN32)
    if (ple) {   // the engine's PLE table: a 26.8 GB file mapped read-only beside the arena
        const char* p = "/home/ai/strata-gguf/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf";
        int fd = open(p, O_RDONLY);
        if (fd < 0) { std::printf("PLE open failed\n"); return 2; }
        void* pp = mmap(nullptr, 26ull << 30, PROT_READ, MAP_PRIVATE, fd, 0);
        if (pp == MAP_FAILED) { std::printf("PLE mmap failed\n"); return 2; }
        for (uint64_t i = 0; i < 26ull << 30; i += 1 << 20) ((volatile uint8_t*) pp)[i] = 0;   // touch
        std::printf("PLE 26.8 GB mapped + touched\n");
    }
#endif

    const size_t arena = (size_t) (46.84 * 1073741824.0);
    uint8_t* base = (uint8_t*) malloc(arena);
    if (!base) { std::printf("malloc arena failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;

    // 4424 runs covering the top 76% of the arena (= the engine's 35.66 GiB of non-fixed experts)
    const size_t pinned = (size_t) (35.66 * 1073741824.0);
    const int runs = 4424;
    const size_t run = pinned / runs;
    std::vector<void*> aliases(runs, nullptr);
    int ok = 0;
    for (int r = 0; r < runs; ++r) {
        const size_t off = arena - pinned + r * run;
        if (cudaHostRegister(base + off, run, cudaHostRegisterPortable | cudaHostRegisterMapped) != cudaSuccess) {
            if (ok == 0 && r == 0) std::printf("first refused: %s\n", cudaGetErrorString(cudaGetLastError()));
            continue;
        }
        void* a = nullptr;
        if (cudaHostGetDevicePointer(&a, base + off, 0) == cudaSuccess) aliases[r] = a;
        ++ok;
    }
    std::printf("pinned %d/%d runs x %.1f MiB (%.2f GiB)\n", ok, runs, (double) run / 1048576.0,
                (double) pinned / 1073741824.0);

    const size_t n = 2176000;
    void* srcp = base + arena - pinned + run + 4096;   // inside a registered run
    if (alias) srcp = aliases[0];                      // run 0's device alias
    e = alias ? cudaMemcpy(d1, srcp, n, cudaMemcpyDeviceToDevice)
              : cudaMemcpy(d1, srcp, n, cudaMemcpyHostToDevice);
    std::printf("copy %s -> %s\n", alias ? "alias D2D" : "host HtoD", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf("  pending: %s\n", cudaGetErrorString(cudaGetLastError()));
    return e == cudaSuccess ? 0 : 3;
}
