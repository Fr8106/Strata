// t16: standalone replay of the 96 tier-run registration + canary sequence (the Option B L0 failure).
// Parses the engine's STRATA_PCIE_REGLOG geometry (tools/repro/reglog-run1.txt), registers a subset of
// the runs exactly as register_tier_runs does, and runs the engine's canary samples - so the L0 failure
// can be bisected WITHOUT stopping the LLM (a small context coexists with the swift15 container's VRAM;
// only the registered prefix is pinned, ~8 GiB for layers 0..6).
//
// Usage: t16 <reglog> <what> <K>
//   what = both|nf|fx|one   (register both runs / non-fixed only / fixed only / only layer K)
//   K    = last layer index (0..47; `one` uses it as the single layer)
// Prints every sample's rc (the engine's canary is the same sequence: 64 KiB HtoD + 256 B read-back at
// k=0 run-start, k=1 middle, k=2 near-end, sample layers 0,6,12,...).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>
#include <sys/mman.h>

struct Layer {
    uint64_t off, nfix, end;   // logical: layer start, fixed-tier bytes, aligned end
};

// minimal: one Mapped registration of ~size MiB, HtoD the middle and the last page.  Usage: t16 minimal <MiB>
static int minimal(int mib) {
    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }
    uint8_t* va = (uint8_t*) mmap(nullptr, (size_t) mib << 20, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (va == MAP_FAILED) { std::printf("mmap failed\n"); return 1; }
    const size_t bytes = (size_t) mib << 20;
    const cudaError_t rr = cudaHostRegister(va, bytes, cudaHostRegisterPortable | cudaHostRegisterMapped);
    std::printf("register %d MiB: %s\n", mib, cudaGetErrorString(rr));
    if (rr != cudaSuccess) return 1;
    uint8_t* scratch = nullptr;
    cudaMalloc(&scratch, 1u << 20);
    auto probe = [&](const char* what, uint64_t p) {
        const cudaError_t rc = cudaMemcpy(scratch, va + p, 65536, cudaMemcpyHostToDevice);
        std::printf("  %s (0x%llx): %s\n", what, (unsigned long long) p, cudaGetErrorString(rc));
        (void) cudaGetLastError();
    };
    probe("middle", bytes / 2 & ~(uint64_t) 4095);
    probe("last page - 64K", bytes - 65536);
    probe("last page start", (bytes + 4095) & ~(uint64_t) 4095);
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 3 && !std::strcmp(argv[1], "minimal")) return minimal(std::atoi(argv[2]));
    if (argc < 4) { std::printf("usage: t16 <reglog> <both|nf|fx|one> <K> | t16 minimal <MiB>\n"); return 1; }
    const char* what = argv[2];
    const int K = std::atoi(argv[3]);

    // parse the reglog: a line is a layer's non-fixed run when its off falls inside the previous line's
    // range (the two runs overlap at the shared edge page); otherwise it starts a new layer (fixed run).
    // The engine log's "fixed tier per layer: 81..166 experts" (all < 512) means every layer has BOTH a
    // fixed and a non-fixed run: one pass is 48 strict pairs (fixed_i, non-fixed_i).  The reglog records
    // EVERY registration attempt, so after the L0 pass (flags=3) the canary ladder's L1 pass (flags=1)
    // re-logs the same 96 runs - stop at the first non-Mapped line and use only the L0 geometry.
    static uint64_t offl[128], szl[128];
    int nlines = 0;
    FILE* f = std::fopen(argv[1], "r");
    if (f == nullptr) { std::printf("cannot open %s\n", argv[1]); return 1; }
    char line[256];
    while (std::fgets(line, sizeof line, f)) {
        uint64_t off = 0, size = 0;
        char tok[32] = "";
        unsigned flags = 0;
        if (std::sscanf(line, "%*f off=%llu %*s size=%llu %31s",
                        (unsigned long long*)&off, (unsigned long long*)&size, tok) != 3)
            continue;
        flags = (unsigned) std::atol(tok + 6);  // tok is "flags=N"
        if (flags != 3) break;  // the L0 pass is Portable|Mapped (3); the L1 pass (Portable, 1) starts here
        offl[nlines] = off;
        szl[nlines] = size;
        ++nlines;
    }
    if (nlines == 0 || nlines % 2) { std::printf("reglog has %d L0 lines - expected 96 (48 fixed,non-fixed pairs)\n", nlines); return 1; }
    for (int i = 0; i < 8 && i < nlines; ++i)
        std::printf("  line %d: off=%llu size=%llu\n", i, (unsigned long long) offl[i], (unsigned long long) szl[i]);
    static Layer L[64];
    const int nl = nlines / 2;
    for (int i = 0; i < nl; ++i) {
        L[i].off = offl[2 * i];
        L[i].nfix = offl[2 * i + 1] - offl[2 * i];
        L[i].end = offl[2 * i + 1] + szl[2 * i + 1];
        if (i && L[i].off < L[i - 1].end) {
            std::printf("layer %d (off=%llu) not after layer %d (end=%llu) - pairing broken\n",
                        i, (unsigned long long) L[i].off, i - 1, (unsigned long long) L[i - 1].end);
            return 1;
        }
    }
    std::fclose(f);
    std::printf("parsed %d layers from %s\n", nl, argv[1]);

    cudaError_t e = cudaSetDevice(0);
    if (e != cudaSuccess) { std::printf("setdevice: %s\n", cudaGetErrorString(e)); return 1; }
    uint8_t* va = (uint8_t*) mmap(nullptr, 1ULL << 36, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (va == MAP_FAILED) { std::printf("va mmap failed\n"); return 1; }

    uint8_t* scratch = nullptr;
    uint8_t* back = nullptr;
    cudaMalloc(&scratch, 1u << 20);
    cudaHostAlloc((void**) &back, 256, cudaHostAllocDefault);

    const uint32_t flags = cudaHostRegisterPortable | cudaHostRegisterMapped;  // the engine's L0 shape
    auto reg = [&](uint64_t s, uint64_t t) -> bool {
        const cudaError_t rc = cudaHostRegister(va + s, (size_t) (t - s), flags);
        if (rc != cudaSuccess) { std::printf("  register [%.1fMiB,%.1fMiB): %s\n", s/1048576.0, t/1048576.0, cudaGetErrorString(rc)); (void) cudaGetLastError(); return false; }
        void* d = nullptr;
        cudaHostGetDevicePointer(&d, va + s, 0);
        return d != nullptr;
    };
    auto sample = [&](int l, int k) {
        const uint64_t off0 = L[l].off, nfix = L[l].nfix, end = L[l].end;
        // the engine bug (pre-fix): floor4k of the fixed end lands on the fixed run's LAST page, and the 64 KiB
        // copy from there straddles the registration boundary (the driver refuses a zero-copy HtoD that
        // crosses two Mapped runs).  The non-fixed run starts at CEIL4k - sample there.
        const uint64_t o = (nfix > 0 && nfix < end - off0)
                              ? ((off0 + nfix + 4095) & ~(uint64_t) 4095)
                              : (off0 & ~(uint64_t) 4095);
        const uint64_t en = (end + 4095) & ~(uint64_t) 4095;
        const uint64_t ffe = (off0 + nfix + 4095) & ~(uint64_t) 4095;  // the fixed run's aligned end
        const uint64_t p = k == 0 ? o : (k == 1 ? ((o + en) >> 1) & ~(uint64_t) 4095 :
                          (k == 2 ? en - 65536 :
                          (k == 3 ? (off0 + nfix / 2) & ~(uint64_t) 4095 :
                          (k == 4 ? ffe - 65536 : ffe - 4096))));       // k=3 fixed middle, k=4/5 fixed tail
        const cudaError_t rc = cudaMemcpy(scratch, va + p, 65536, cudaMemcpyHostToDevice);
        if (rc != cudaSuccess) { std::printf("L%02d k=%d off=0x%llx: HtoD %s\n", l, k, (unsigned long long) p, cudaGetErrorString(rc)); (void) cudaGetLastError(); return; }
        const cudaError_t rc2 = cudaMemcpy(back, scratch, 256, cudaMemcpyDeviceToHost);
        if (rc2 != cudaSuccess || std::memcmp(back, va + p, 256) != 0) { std::printf("L%02d k=%d: read-back %s\n", l, k, cudaGetErrorString(rc2)); (void) cudaGetLastError(); return; }
        std::printf("L%02d k=%d off=0x%llx: ok\n", l, k, (unsigned long long) p);
    };

    for (int l = 0; l < nl; ++l) {
        const uint64_t off0 = L[l].off, nfix = L[l].nfix;
        const bool dofx = !std::strcmp(what, "fx") || (!std::strcmp(what, "both") && nfix > 0) ||
                          (!std::strcmp(what, "one") && l == K && nfix > 0);
        const bool donf = !std::strcmp(what, "nf") || (!std::strcmp(what, "both") && nfix < L[l].end - off0) ||
                          (!std::strcmp(what, "one") && l == K && nfix < L[l].end - off0);
        if (!std::strcmp(what, "one") && l != K) continue;  // one: layer K only
        if (std::strcmp(what, "one") && l > K) break;        // both/nf/fx: layers 0..K
        if (dofx && nfix > 0) {
            const uint64_t fs = off0 & ~(uint64_t) 4095, fe = (off0 + nfix + 4095) & ~(uint64_t) 4095;
            if (!reg(fs, fe)) { std::printf("fixed run L%02d refused\n", l); }
        }
        if (donf && nfix < L[l].end - off0) {
            const uint64_t ns = nfix == 0 ? (off0 & ~(uint64_t) 4095) : (off0 + nfix + 4095) & ~(uint64_t) 4095;
            const uint64_t ne = (L[l].end + 4095) & ~(uint64_t) 4095;
            if (!reg(ns, ne)) { std::printf("non-fixed run L%02d refused\n", l); }
        }
    }
    std::printf("--- canary samples (%s, K=%d) ---\n", what, K);
    if (!std::strcmp(what, "one"))
        for (int k = 0; k < 6; ++k) sample(K, k);
    else {
        for (int l = 0; l < nl; l += 6)
            if (l <= K) { sample(l, 0); sample(l, 1); sample(l, 2); }
    }
    return 0;
}
