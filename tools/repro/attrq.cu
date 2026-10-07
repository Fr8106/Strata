// Attribute queries for the HMM / Option-D feasibility check (P4-A phase 0).
// No allocations, no VRAM used — safe to run with other GPU workloads live.
#include <cuda_runtime.h>
#include <cstdio>

#define Q(attr, name)                                                       \
  do {                                                                      \
    int v = 0;                                                            \
    cudaError_t rc = cudaDeviceGetAttribute(&v, (attr), 0);               \
    printf("%-52s %s (rc=%d)\n", (name), rc == cudaSuccess ? (v ? "YES" : "no") : "query-failed", rc); \
  } while (0)
#define QI(attr, name)                                                      \
  do {                                                                      \
    int v = 0;                                                            \
    cudaError_t rc = cudaDeviceGetAttribute(&v, (attr), 0);               \
    printf("%-52s %d (rc=%d)\n", (name), v, (int) rc);                    \
  } while (0)

int main() {
  cudaFree(0); // init context without allocating
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, 0);
  printf("device: %s\n", prop.name);
  Q(cudaDevAttrPageableMemoryAccess, "PageableMemoryAccess");
  Q(cudaDevAttrPageableMemoryAccessUsesHostPageTables, "PageableMemoryAccessUsesHostPageTables");
  Q(cudaDevAttrConcurrentManagedAccess, "ConcurrentManagedAccess");
  Q(cudaDevAttrManagedMemory, "ManagedMemory");
  Q(cudaDevAttrGPUDirectRDMAWritesOrdering, "GPUDirectRDMAWritesOrdering");
  Q(cudaDevAttrHostRegisterSupported, "HostRegisterSupported");
  QI(cudaDevAttrClockRate, "ClockRate (kHz)");
  return 0;
}
