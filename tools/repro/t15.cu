// t15: the fix candidates, in the engine's full context shape.
// Usage: t15 <variant>
//   m1     ONE whole-arena Mapped registration (46.84 GiB, 1 zero-copy mapping)
//   m48    48 whole-layer Mapped registrations (~976 MiB each)
//   p1     ONE whole-arena PLAIN registration (the engine's shape, count=1)
// Context replicated: 24 GiB cache + 12 GiB in 512 smalls + 2 streams + a kernel,
// 9.14 GiB pre-pinned host, the 26.8 GiB PLE file mapping, and the 256 MiB PCIe probe.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>
#if !defined(_WIN32)
#include <sys/mman.h>
#include <fcntl.h>
#endif

__global__ void touch(uint8_t* p, size_t n) { p[0] = 1; (void) n; }

int main(int argc, char** argv) {
    const char* v = argc > 1 ? argv[1] : "m1";
    const bool mapped = !std::strncmp(v, "m", 1);
    const int runs = !std::strcmp(v, "m48") ? 48 : 1;

    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }
    std::printf("step 1: device\n");

    // the engine's device state
    void* cache = nullptr;
    if (cudaMalloc(&cache, (size_t) (24.0 * 1073741824.0)) != cudaSuccess) {
        std::printf("cache malloc: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 1;
    }
    void** allocs = new void*[512];
    for (int i = 0; i < 512; ++i)
        if (cudaMalloc(&allocs[i], (6ull << 30) / 512) != cudaSuccess) {
            std::printf("small #%d: %s\n", i, cudaGetErrorString(cudaGetLastError()));
            return 1;
        }
    cudaStream_t s1 = nullptr, s2 = nullptr;
    (void) cudaStreamCreate(&s1);
    (void) cudaStreamCreate(&s2);
    touch<<<1, 32, 0, s1>>>((uint8_t*) cache, 1 << 20);
    (void) cudaStreamSynchronize(s1);
    std::printf("step 2: device state (24 GiB + 512 smalls + streams + kernel)\n");

    // the PCIe probe: 256 MiB host + device, four copies, freed (the engine's preamble)
    {
        void* ph = nullptr, *pd = nullptr;
        if (cudaHostAlloc(&ph, 256 << 20, cudaHostAllocDefault) == cudaSuccess &&
            cudaMalloc(&pd, 256 << 20) == cudaSuccess) {
            for (int i = 0; i < 4; ++i)
                (void) cudaMemcpy(pd, ph, 256 << 20, cudaMemcpyHostToDevice);
            cudaFree(pd);
            cudaFreeHost(ph);
        }
    }

    std::printf("step 3: probe done\n");
    // the engine's non-arena pinned blocks
    void* kv = nullptr;
    if (cudaHostAlloc(&kv, (size_t) (9.14 * 1073741824.0), cudaHostAllocDefault) != cudaSuccess) {
        std::printf("pre-pin 9.14 GiB: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 2;
    }

    // the PLE table: 26.8 GiB of file mapping beside the arena
#if !defined(_WIN32)
    {
        const char* p = "/home/ai/strata-gguf/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf";
        int fd = open(p, O_RDONLY);
        if (fd >= 0) {
            void* pp = mmap(nullptr, (size_t) (26.8 * 1073741824.0), PROT_READ, MAP_PRIVATE, fd, 0);
            if (pp != MAP_FAILED) {
                for (uint64_t i = 0; i < (uint64_t) (26.8 * 1073741824.0); i += 1 << 20) ((volatile const uint8_t*) pp)[i];
                std::printf("step 4: PLE 26.8 GB mapped + touched\n");
            }
        }
    }
#endif

    const size_t arena = (size_t) (46.84 * 1073741824.0);
    std::printf("step 5: pre-pin + PLE done, KV = %p\n", (void*) kv);
    uint8_t* base = (uint8_t*) malloc(arena);
    if (!base) { std::printf("malloc arena failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;
    std::printf("step 6: arena touched\n");

    const unsigned flags = cudaHostRegisterPortable | (mapped ? cudaHostRegisterMapped : 0);
    int ok = 0, refused = 0;
    for (int r = 0; r < runs; ++r) {
        const size_t off = runs == 1 ? 0 : r * (arena / 48);
        const size_t len = runs == 1 ? arena : arena / 48;
        if (cudaHostRegister(base + off, len, flags) != cudaSuccess) {
            if (refused++ == 0) std::printf("first refused: %s\n", cudaGetErrorString(cudaGetLastError()));
            continue;
        }
        ++ok;
    }
    std::printf("%s: registered %d/%d %s runs (%.2f GiB)\n", v, ok, runs,
                mapped ? "MAPPED" : "plain", (double) runs * (runs == 1 ? (double) arena : (double) arena / 48) / 1073741824.0);

    std::printf("step 7: registration done\n");
    // the failing shape: 2.176 MiB HtoD from inside a registered run
    const size_t n = 2176000;
    uint8_t* src = base + 4096;
    e = cudaMemcpy(cache, src, n, cudaMemcpyHostToDevice);
    std::printf("HtoD from registered region -> %s", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf(" (pending: %s)", cudaGetErrorString(cudaGetLastError()));
    std::printf("\n");
    return e == cudaSuccess ? 0 : 3;
}
