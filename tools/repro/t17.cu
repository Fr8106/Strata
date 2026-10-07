// t17 - the ASYNC variant of the cross-registration refusal (t16's synchronous sibling).
//
// The tier-ordered arena registers two ADJACENT Mapped runs per layer; the tier boundary is not a 4K
// multiple, so the page holding it is shared.  Verifier::fetch_dma copies expert blobs from the arena
// to device staging with cudaMemcpyAsync on a side stream and does NOT check the result - the copy
// that straddles the boundary is refused by the driver, the flag never rises and the verify graph
// spins into its 20 s timeout (#267).  This program reproduces that in isolation and tests candidate
// fixes:
//   A  copy fully inside run 1                       -> expect OK
//   B  straddling copy, adjacent runs (the engine's layout) -> expect refused
//   C  straddling copy with an unregistered GAP page at the boundary -> ?
//   D  straddling copy through a pinned bounce       -> expect OK
// and, for B, whether a cudaLaunchHostFunc queued after the failed copy still fires (the flag B path)
// and whether the stream stays poisoned afterwards.
//
// Build: /usr/local/cuda/bin/nvcc -O2 -arch=sm_120 tools/repro/t17.cu -o tools/repro/t17
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cuda_runtime.h>
#include <sys/mman.h>

static const char* es(cudaError_t e) { return cudaGetErrorString(e); }

static volatile int g_fired = 0;
static void host_fn(void*) { g_fired = 1; }

__global__ void touch_kernel(const unsigned char* p, long n, unsigned* out) {
    unsigned s = 0;
    for (long i = 0; i < n; i += 64) s += p[i];
    *out = s;
}

static size_t page = 4096;
static size_t ceil4k(size_t x) { return (x + page - 1) & ~(page - 1); }
static size_t floor4k(size_t x) { return x & ~(page - 1); }

int main() {
    const size_t MB = 1u << 20;
    const size_t layer = 64 * MB;
    const size_t total = 2 * layer;
    const size_t nfix = 30 * MB + 3328;          // misaligned tier boundary (like L9's 3328)
    const size_t bnd = nfix, cb = ceil4k(bnd), fb = floor4k(bnd);
    const size_t blob = 2 * MB;
    const size_t soff = bnd - 2768;              // a blob whose bytes cross the boundary

    void* raw = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) { printf("mmap failed\n"); return 1; }
    uint8_t* arena = (uint8_t*) raw;
    for (size_t o = 0; o < total; o += page) ((volatile uint8_t*) arena)[o] = 1;   // fault the pages in

    uint8_t* dev = nullptr;
    if (cudaMalloc(&dev, 4 * MB) != cudaSuccess) { printf("device alloc failed\n"); return 1; }
    cudaStream_t s;
    cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking);

    printf("geometry: boundary=%zu ceil4k=%zu (shared page %zu..%zu), blob=%zu at %zu..%zu\n",
           bnd, cb, fb, cb, blob, soff, soff + blob);

    // --- A/B: the engine's layout - two adjacent Mapped runs sharing the boundary page ---
    cudaError_t r1 = cudaHostRegister(arena, cb, cudaHostRegisterPortable | cudaHostRegisterMapped);
    cudaError_t r2 = cudaHostRegister(arena + cb, total - cb, cudaHostRegisterPortable | cudaHostRegisterMapped);
    printf("register adjacent runs: [0,%zu)=%s [%zu,%zu)=%s\n", cb, es(r1), cb, total, es(r2));

    cudaError_t a = cudaMemcpyAsync(dev, arena + 1 * MB, blob, cudaMemcpyHostToDevice, s);
    cudaError_t as = cudaStreamSynchronize(s);
    printf("A inside-run copy      : launch=%s sync=%s\n", es(a), es(as));

    g_fired = 0;
    cudaError_t b = cudaMemcpyAsync(dev, arena + soff, blob, cudaMemcpyHostToDevice, s);
    printf("B straddling  copy     : launch=%s (async launch usually succeeds)\n", es(b));
    cudaLaunchHostFunc(s, host_fn, nullptr);
    cudaError_t bs = cudaStreamSynchronize(s);
    printf("B result               : sync=%s  host-func-fired=%d  sticky=%s\n",
           es(bs), g_fired, es(cudaGetLastError()));
    cudaError_t after = cudaMemcpyAsync(dev, arena + 2 * MB, blob, cudaMemcpyHostToDevice, s);
    cudaError_t afters = cudaStreamSynchronize(s);
    printf("B stream afterwards    : next-copy launch=%s sync=%s (poisoned stream?)\n", es(after), es(afters));

    // --- C: leave an unregistered gap page at the boundary (fixed run ends at floor4k, non-fixed starts at ceil4k) ---
    cudaHostUnregister(arena);
    cudaHostUnregister(arena + cb);
    cudaError_t g1 = cudaHostRegister(arena, fb, cudaHostRegisterPortable | cudaHostRegisterMapped);
    cudaError_t g2 = cudaHostRegister(arena + cb, total - cb, cudaHostRegisterPortable | cudaHostRegisterMapped);
    printf("register with gap page : [0,%zu)=%s [%zu,%zu)=%s (gap %zu bytes unregistered)\n",
           fb, es(g1), cb, total, es(g2), cb - fb);
    cudaError_t c = cudaMemcpyAsync(dev, arena + soff, blob, cudaMemcpyHostToDevice, s);
    cudaError_t cs = cudaStreamSynchronize(s);
    printf("C straddling w/ gap    : launch=%s sync=%s  sticky=%s\n", es(c), es(cs), es(cudaGetLastError()));
    cudaMemcpy(dev, arena + soff, blob, cudaMemcpyHostToDevice);   // reference (synchronous) for D/E
    uint8_t* ref = (uint8_t*) malloc(blob);
    if (cudaMemcpy(ref, dev, blob, cudaMemcpyDeviceToHost) != cudaSuccess) printf("  (ref read failed)\n");

    // --- D: bounce through pinned memory onto the SAME adjacent layout ---
    cudaHostUnregister(arena);
    cudaHostUnregister(arena + cb);
    cudaHostRegister(arena, cb, cudaHostRegisterPortable | cudaHostRegisterMapped);
    cudaHostRegister(arena + cb, total - cb, cudaHostRegisterPortable | cudaHostRegisterMapped);
    void* bounce = nullptr;
    cudaHostAlloc(&bounce, blob, cudaHostAllocPortable);
    std::memcpy(bounce, arena + soff, blob);
    cudaError_t d = cudaMemcpyAsync(dev, bounce, blob, cudaMemcpyHostToDevice, s);
    cudaError_t ds = cudaStreamSynchronize(s);
    printf("D straddling via bounce: launch=%s sync=%s\n", es(d), es(ds));
    uint8_t* got = (uint8_t*) malloc(blob);
    cudaMemcpy(got, dev, blob, cudaMemcpyDeviceToHost);
    printf("D bounce data matches  : %s\n", std::memcmp(got, ref, blob) == 0 ? "yes" : "no");

    // --- E/F/G: the KERNEL-read variant (the zero-copy alias path the GPU uses for the pcie_frac share) ---
    // The boundary blob's host UVA starts BEFORE its registered run: a kernel dereferencing the alias reads a
    // range only partially covered by the registration (t17-E with the engine's adjacent layout, t17-F with
    // the gap layout).  Control: a read fully inside the run.
    unsigned* out_d = nullptr;
    cudaMalloc(&out_d, sizeof(unsigned));
    const unsigned char* dptr = nullptr;
    cudaError_t dptr_rc = cudaHostGetDevicePointer((void**) &dptr, (void*) (arena + cb), 0);
    unsigned long long host_sum = 0, dev_sum = 0;
    for (size_t i = 0; i < blob; i += 64) host_sum += (arena + soff)[i];
    printf("alias: cudaHostGetDevicePointer(run start)=%s ptr=%p (run starts at %zu; the blob starts at %zu)\n",
           es(dptr_rc), (void*) dptr, cb, soff);
    cudaGetLastError();
    // The engine RELEASES the fixed tier: the fixed run (which held the boundary page) is unregistered, so the
    // blob's head page has no device mapping any more - exactly the state the failing config runs in.
    cudaHostUnregister(arena);
    (void) cudaGetLastError();
    printf("released the fixed run (unregistered [0,%zu)); the boundary page is now unregistered\n", cb);

    // G: control read, from the registered run's own start
    touch_kernel<<<1, 1>>>(dptr, (long) blob, out_d);
    cudaError_t g_launch = cudaGetLastError();
    cudaError_t g_sync = cudaDeviceSynchronize();
    cudaMemcpy(&dev_sum, out_d, 4, cudaMemcpyDeviceToHost);
    printf("G kernel read INSIDE run : launch=%s sync=%s (sum %llu vs host %llu)\n",
           es(g_launch), es(g_sync), dev_sum, host_sum);

    // E: the boundary alias: negative offset into the page before the run (the shared/gap page)
    const long neg = -(long) (cb - soff);
    touch_kernel<<<1, 1>>>((const unsigned char*) ((const char*) dptr + neg), (long) blob, out_d);
    cudaError_t e_launch = cudaGetLastError();
    cudaError_t e_sync = cudaDeviceSynchronize();
    printf("E kernel read STRADDLE   : launch=%s sync=%s (offset %ld, sticky=%s)\n",
           es(e_launch), es(e_sync), neg, es(cudaGetLastError()));

    cudaFree(out_d);
    cudaFreeHost(bounce);
    cudaFree(dev);
    munmap(raw, total);
    return 0;
}
