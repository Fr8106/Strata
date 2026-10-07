// t11: the registered-region copy matrix (the engine's actual failure shape).
// All variants: 29 GiB device + 46.84 GiB anonymous arena + pinning + a 2.176 MiB HtoD copy.
// Usage: t11 <variant>
//   reg4424-plain    4424 plain-pin runs, copy FROM a registered region (host ptr)
//   reg4424-mapped   4424 MAPPED runs, copy FROM a registered region (host ptr)
//   reg4424-alias    4424 MAPPED runs, copy FROM the device alias (D2D)
//   reg48-mapped     48 whole-layer MAPPED runs, copy FROM a registered region (host ptr)
//   reg1-mapped      one whole-arena MAPPED registration, copy FROM a registered region (host ptr)
//   unreg4424        4424 MAPPED runs, copy FROM the unregistered half (host ptr)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>

int main(int argc, char** argv) {
    const char* v = argc > 1 ? argv[1] : "reg4424-plain";
    const bool mapped = std::strstr(v, "mapped") != nullptr;
    const int nruns = !std::strcmp(v, "reg48-mapped") ? 48
                  : !std::strcmp(v, "reg1-mapped") ? 1 : 4424;
    const bool alias = !std::strcmp(v, "reg4424-alias");
    const bool unreg = !std::strcmp(v, "unreg4424");

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

    const size_t arena = (size_t) (46.84 * 1073741824.0);
    uint8_t* base = (uint8_t*) malloc(arena);
    if (!base) { std::printf("malloc arena failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;

    const unsigned flags = cudaHostRegisterPortable | (mapped ? cudaHostRegisterMapped : 0);
    std::vector<uint64_t> offs;
    std::vector<uint64_t> lens;
    if (nruns == 48) {   // whole layers: the arena is 48 layers of arena/48
        const size_t L = arena / 48;
        for (int l = 0; l < 48; ++l) { offs.push_back(l * L); lens.push_back(L); }
    } else {
        const size_t half = arena / 2;
        const size_t run = half / 4424;
        for (int r = 0; r < 4424; ++r) { offs.push_back(half + r * run); lens.push_back(run); }
    }
    std::vector<void*> aliases;
    int refused = 0;
    for (size_t i = 0; i < offs.size(); ++i) {
        void* a = nullptr;
        e = cudaHostRegister(base + offs[i], lens[i], flags);
        if (e != cudaSuccess) { if (refused++ == 0) std::printf("first refused: %s\n",
                cudaGetErrorString(cudaGetLastError())); continue; }
        if (mapped && cudaHostGetDevicePointer(&a, base + offs[i], 0) != cudaSuccess) a = nullptr;
        aliases.push_back(a);
    }
    std::printf("pinned %zu/%zu runs%s\n", offs.size() - refused, offs.size(), mapped ? " (mapped)" : "");

    // the copy: 2.176 MiB into the cache arena
    const size_t n = 2176000;
    uint8_t* src = base + arena / 2 + 4096;   // inside a registered run
    if (unreg) src = base + 4096;            // inside the unregistered half
    void* srcp = src;
    if (alias) {   // copy from run 0's start via its device alias (D2D over the zero-copy alias)
        if (aliases.empty() || aliases[0] == nullptr) { std::printf("no alias for run 0\n"); return 4; }
        srcp = aliases[0];
    }
    e = alias ? cudaMemcpy(d1, srcp, n, cudaMemcpyDeviceToDevice)
              : cudaMemcpy(d1, srcp, n, cudaMemcpyHostToDevice);
    std::printf("copy %s -> %s\n", alias ? "alias D2D" : "host HtoD", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf("  pending: %s\n", cudaGetErrorString(cudaGetLastError()));
    return e == cudaSuccess ? 0 : 3;
}
