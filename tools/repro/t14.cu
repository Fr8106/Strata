// t14: context-state replica.  t13 covers the pinned BYTES; this adds the engine's
// device-side state: hundreds of small cudaMallocs (KV heads, MTP, Q5_K, cache slots),
// a few streams, and kernel launches, BEFORE the big pin.  If t13 passed and t14 fails,
// the driver's user-memory table degrades with context age/size, not pinned bytes.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

__global__ void touch(uint8_t* p, size_t n) { p[0] = 1; (void) n; }

int main() {
    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }

    // the engine's ~30 GiB of device state: the 24 GiB cache arena + everything else as
    // hundreds of small allocations (KV/MTP/Q5_K/embeddings/heads), not two blocks
    void* cache = nullptr;
    if (cudaMalloc(&cache, (size_t) (24.0 * 1073741824.0)) != cudaSuccess) {
        std::printf("cache malloc: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 1;
    }
    const size_t smalls = 512;
    void** allocs = new void*[smalls];
    size_t small_bytes = 0;
    for (size_t i = 0; i < smalls; ++i) {
        const size_t want = (size_t) ((5.5 * 1073741824.0) / (double) smalls);
        if (cudaMalloc(&allocs[i], want) != cudaSuccess) {
            std::printf("small #%zu: %s\n", i, cudaGetErrorString(cudaGetLastError()));
            return 1;
        }
        small_bytes += want;
    }
    cudaStream_t s1 = nullptr, s2 = nullptr;
    (void) cudaStreamCreate(&s1);
    (void) cudaStreamCreate(&s2);
    touch<<<1, 32, 0, s1>>>((uint8_t*) cache, small_bytes);
    (void) cudaStreamSynchronize(s1);
    size_t fb = 0, tb = 0;
    cudaMemGetInfo(&fb, &tb);
    std::printf("device: 24 GiB cache + %zu smalls (%.1f GiB), VRAM free %.2f GiB\n",
                smalls, (double) small_bytes / 1073741824.0, (double) fb / 1073741824.0);

    // the engine's non-arena pinned blocks
    void* kv = nullptr;
    if (cudaHostAlloc(&kv, (size_t) (9.14 * 1073741824.0), cudaHostAllocDefault) != cudaSuccess) {
        std::printf("pre-pin 9.14 GiB: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 2;
    }

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
    std::printf("pinned %d/%d runs + 9.14 GiB pre-pin\n", ok, runs);

    const size_t n = 2176000;
    uint8_t* src = base + arena - pinned + run + 4096;
    e = cudaMemcpy(cache, src, n, cudaMemcpyHostToDevice);
    std::printf("HtoD from registered run -> %s", cudaGetErrorString(e));
    if (e != cudaSuccess) std::printf(" (pending: %s)", cudaGetErrorString(cudaGetLastError()));
    std::printf("\n");
    return e == cudaSuccess ? 0 : 3;
}
