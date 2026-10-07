// t7: reproduce "fill_slot_blocking: invalid argument" after selective cudaHostRegister.
// Sequence mimics the engine: device allocs + copies first (probe-like), then
// register selected runs of an anonymous arena, then HtoD copies from host pointer and from alias.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) \
    { std::printf("FAIL @%d: %s -> %s\n", __LINE__, #x, cudaGetErrorString(e_)); return 1; } } while (0)

int main() {
    CK(cudaSetDevice(0));
    // 1) probe-like preamble: device alloc + a couple of HtoD copies (the engine's PCIe probe does this)
    void *dev = nullptr;
    CK(cudaMalloc(&dev, 8 << 20));
    std::vector<uint8_t> hb(8 << 20, 0xAB);
    CK(cudaMemcpy(dev, hb.data(), hb.size(), cudaMemcpyHostToDevice));
    CK(cudaMemcpy(hb.data(), dev, hb.size(), cudaMemcpyDeviceToHost));

    // 2) anonymous arena, 256 MiB, touched
    const size_t arena = 256ull << 20;
    uint8_t *base = (uint8_t *) malloc(arena);
    if (!base) { std::printf("malloc failed\n"); return 2; }
    for (size_t i = 0; i < arena; i += 4096) base[i] = 1;

    // 3) register a "run" (page aligned), like register_pcie_alias does
    const size_t off = 0, len = 264ull << 20;
    void *d = nullptr;
    cudaError_t er = cudaHostRegister(base + off, len, cudaHostRegisterPortable | cudaHostRegisterMapped);
    std::printf("register: %s\n", cudaGetErrorString(er));
    cudaError_t ep = cudaHostGetDevicePointer(&d, base + off, 0);
    std::printf("getdevptr: %s (d=%p)\n", cudaGetErrorString(ep), d);
    if (er != cudaSuccess || ep != cudaSuccess) { cudaGetLastError(); }

    // 4) HtoD copy FROM THE HOST POINTER (what fill_slot_blocking does)
    uint8_t *dst = (uint8_t *) dev;
    cudaError_t c1 = cudaMemcpy(dst, base + off, len, cudaMemcpyHostToDevice);
    std::printf("HtoD from host ptr after register: %s\n", cudaGetErrorString(c1));
    if (c1 != cudaSuccess) { std::printf("  sticky cleared: %s\n", cudaGetErrorString(cudaGetLastError())); }

    // 5) HtoD copy FROM THE DEVICE ALIAS
    cudaError_t c2 = cudaMemcpy(dst, (uint8_t *) d, len, cudaMemcpyHostToDevice);
    std::printf("HtoD from device alias: %s\n", cudaGetErrorString(c2));
    if (c2 != cudaSuccess) { std::printf("  sticky cleared: %s\n", cudaGetErrorString(cudaGetLastError())); }

    // 6) unregistered anonymous region as source (pageable)
    uint8_t *pageable = (uint8_t *) malloc(64 << 20);
    cudaError_t c3 = cudaMemcpy(dst, pageable, 64 << 20, cudaMemcpyHostToDevice);
    std::printf("HtoD from unregistered pageable: %s\n", cudaGetErrorString(c3));
    if (c3 != cudaSuccess) { std::printf("  sticky cleared: %s\n", cudaGetErrorString(cudaGetLastError())); }

    // 7) zero-length copy (the n==0 case)
    cudaError_t c4 = cudaMemcpy(dst, base, 0, cudaMemcpyHostToDevice);
    std::printf("HtoD zero bytes: %s\n", cudaGetErrorString(c4));
    if (c4 != cudaSuccess) { std::printf("  sticky cleared: %s\n", cudaGetErrorString(cudaGetLastError())); }

    std::printf("done\n");
    return 0;
}
