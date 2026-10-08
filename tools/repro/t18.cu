// t18 - the copy-semantics matrix over registration geometries (hardening T4, docs/HARDENING-PLAN-2026-10-08.md)
//
// t16/t17 settled two cells of this matrix on this box (driver 610.57.04): straddling TWO ADJACENT
// Mapped registrations is refused, and a one-page unregistered GAP between the runs is accepted.
// The engine's whole hardening design rests on those being stable properties of THIS driver, not of
// CUDA.  This program fills the rest of the matrix so the assumption register can say what is
// measured and what is believed:
//   flags : Portable|Mapped (the engine's L0)  vs  Portable ONLY (the 4255b29 shape).  If a
//           straddle over two adjacent PLAIN registrations is accepted, `Mapped` - not adjacency -
//           is what triggers the refusal, and the fixed run never needs Mapped at all (R12).
//   shape : inside a run (control) / copy ending exactly at the run end / +1 byte and +1 page past
//           it / a deep straddle from four different page offsets
//   size  : 4 KiB / 64 KiB / 2 MiB (the driver stages small and large copies differently)
//   U arm : a fully UNregistered anonymous source, no registrations at all - the isolated re-test of
//           the 9ad8c44 claim "unregistered HtoD dies under memory pressure" (R11).  This arm alone
//           cannot manufacture that pressure; it records the no-pressure baseline for that cell.
//
// Build: /usr/local/cuda/bin/nvcc -O2 -arch=sm_120 tools/repro/t18.cu -o tools/repro/t18
// Run:   ./tools/repro/t18 | tee tools/repro/probe-matrix-results.txt
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cuda_runtime.h>
#include <sys/mman.h>

static const char* es(cudaError_t e) { return cudaGetErrorString(e); }
static const size_t page = 4096;
static size_t ceil4k(size_t x) { return (x + page - 1) & ~(page - 1); }
static size_t floor4k(size_t x) { return x & ~(page - 1); }

static uint8_t* g_arena = nullptr;
static size_t g_total = 0;
static uint8_t* g_dev = nullptr;
static cudaStream_t g_s = nullptr;

// One matrix cell: copy `bytes` from arena+off to the device, async on the side stream, then sync.
// "accepted" = launch and sync both clean.  Clears the last-error slot so the next cell is honest.
static bool cell(size_t off, size_t bytes) {
    cudaError_t l = cudaMemcpyAsync(g_dev, g_arena + off, bytes, cudaMemcpyHostToDevice, g_s);
    cudaError_t s2 = cudaStreamSynchronize(g_s);
    (void) cudaGetLastError();
    return l == cudaSuccess && s2 == cudaSuccess;
}

static void run_geometry(const char* flags_name, uint32_t flags, bool gap, const size_t* sizes, int n_sizes) {
    const size_t bnd = (1u << 25) + 3328;                 // a misaligned tier boundary (t17's shape)
    const size_t fb = floor4k(bnd), cb = ceil4k(bnd);
    const size_t r1end = gap ? fb : cb;                   // run 1's registered end under this layout
    const cudaError_t e1 = cudaHostRegister(g_arena, r1end, flags);
    const cudaError_t e2 = cudaHostRegister(g_arena + cb, g_total - cb, flags);
    std::printf("\n== flags=%s layout=%s ==  register: [%zu,%zu)=%s [%zu,%zu)=%s\n",
                 flags_name, gap ? "gap  (64ff01e shape)" : "adjacent (pre-fix shape)",
                 (size_t) 0, r1end, es((cudaError_t) e1), cb, g_total, es((cudaError_t) e2));
    if (e1 != cudaSuccess || e2 != cudaSuccess) { std::printf("  registration failed - matrix invalid here\n"); return; }
    for (int i = 0; i < n_sizes; ++i) {
        const size_t S = sizes[i];
        std::printf("  size %7zu B:\n", S);
        std::printf("    inside run 1                    : %s\n", cell(r1end - S - 65600, S) ? "ACCEPTED" : "REFUSED");
        if (i == 0) std::printf("    (other sizes control = same as the first)\n");
        std::printf("    end exactly at run-1 end        : %s\n", cell(r1end - S, S) ? "ACCEPTED" : "REFUSED");
        std::printf("    end +1 byte past run-1 end      : %s\n", cell(r1end + 1 - S, S) ? "ACCEPTED" : "REFUSED");
        std::printf("    end +1 page  past run-1 end     : %s\n", cell(r1end + page - S, S) ? "ACCEPTED" : "REFUSED");
        const size_t offs[4] = {0, 1, 2048, 4095};
        for (int o = 0; o < 4; ++o)
            std::printf("    deep straddle, start -%-4zu of page: %s\n", offs[o],
                        cell(r1end - offs[o], S) ? "ACCEPTED" : "REFUSED");
    }
    cudaHostUnregister(g_arena);
    cudaHostUnregister(g_arena + cb);
    (void) cudaGetLastError();
}

int main(int argc, char** argv) {
    const size_t MB = 1u << 20;
    g_total = 64 * MB;
    void* raw = mmap(nullptr, g_total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) { std::printf("mmap failed\n"); return 1; }
    g_arena = (uint8_t*) raw;
    for (size_t o = 0; o < g_total; o += page) ((volatile uint8_t*) g_arena)[o] = (uint8_t) (o * 31 + 7);
    if (cudaMalloc((void**) &g_dev, 4 * MB) != cudaSuccess) { std::printf("device alloc failed\n"); return 1; }
    cudaStreamCreateWithFlags(&g_s, cudaStreamNonBlocking);

    const size_t sizes[3] = {page, 64 * 1024, 2 * MB};
    run_geometry("Portable|Mapped", cudaHostRegisterPortable | cudaHostRegisterMapped, false, sizes, 3);
    run_geometry("Portable|Mapped", cudaHostRegisterPortable | cudaHostRegisterMapped, true,  sizes, 3);
    run_geometry("Portable only",   cudaHostRegisterPortable,                                 false, sizes, 3);
    run_geometry("Portable only",   cudaHostRegisterPortable,                                 true,  sizes, 3);

    // U arm: no registrations at all - the isolated half of R11 (the 9ad8c44 pressure claim cannot be
    // manufactured here; this records the no-pressure baseline: HMM makes pageable copies work).
    {
        const size_t big = 1u * MB * 1024;   // 1 GiB of touched anonymous RAM (swift15 is live: stay gentle)
        void* m = mmap(nullptr, big, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (m != MAP_FAILED) {
            for (size_t o = 0; o < big; o += page) ((volatile uint8_t*) m)[o] = 3;
            cudaError_t l = cudaMemcpy(g_dev, (uint8_t*) m + 123 * MB, 2 * MB, cudaMemcpyHostToDevice);
            std::printf("\n== U arm == unregistered 1 GiB anonymous source, no registrations: %s "
                        "(no-pressure baseline; 9ad8c44's refusal needs pressure - not manufactured here)\n",
                        es(l));
            munmap(m, big);
        } else std::printf("\n== U arm == the 4 GiB mmap failed, arm skipped\n");
    }

    // One more cell worth having: a straddle where run 1 has already been RELEASED (unregistered) -
    // the fixed-tier state.  Expect: accepted (the source's left half is pageable now).
    {
        const size_t bnd = (1u << 25) + 3328, fb = floor4k(bnd), cb = ceil4k(bnd);
        cudaHostRegister(g_arena, fb, cudaHostRegisterPortable | cudaHostRegisterMapped);
        cudaHostRegister(g_arena + cb, g_total - cb, cudaHostRegisterPortable | cudaHostRegisterMapped);
        cudaHostUnregister(g_arena);                    // the fixed run goes away (release_fixed_tier)
        (void) cudaGetLastError();
        std::printf("\n== release arm == straddle over [released run | gap | live run]: %s\n",
                    cell(fb - 2 * MB, 2 * MB) ? "ACCEPTED" : "REFUSED");
        cudaHostUnregister(g_arena + cb);
    }

    cudaFree(g_dev);
    munmap(raw, g_total);
    return 0;
}
