// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

#include "include/CHeapBytes.h"

#if defined(__linux__) && defined(__GLIBC__)
#include <malloc.h>
size_t assay_live_heap_bytes(void) {
    // uordblks: total allocated space, in bytes. There is no live BLOCK count here, which
    // is why the allocation gate stays macOS-only and reports "unavailable" rather than
    // guessing one.
    return mallinfo2().uordblks;
}
#else
size_t assay_live_heap_bytes(void) { return 0; }
#endif


// MARK: - Total malloc traffic

#if defined(__APPLE__)
#include <stdint.h>

// The hook the allocator calls on every operation. Declared here rather than included: it
// lives in <malloc/malloc.h> on some SDK versions and only in private headers on others,
// and the symbol has been stable since it was introduced.
typedef void assay_malloc_logger_t(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                                   uintptr_t result, uint32_t skip);
extern assay_malloc_logger_t *malloc_logger;

// From the allocator's own log-type bits.
#define ASSAY_LOG_ALLOCATE   2
#define ASSAY_LOG_DEALLOCATE 4

static size_t assay_alloc_count = 0;
static size_t assay_free_count = 0;

static void assay_counting_logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3,
                                  uintptr_t result, uint32_t skip) {
    (void)a1; (void)a2; (void)a3; (void)result; (void)skip;
    // A realloc reports BOTH bits in one call, which is correct for both counters: it is one
    // allocation and one deallocation.
    if (type & ASSAY_LOG_ALLOCATE)   assay_alloc_count++;
    if (type & ASSAY_LOG_DEALLOCATE) assay_free_count++;
}

int assay_total_alloc_supported(void) { return 1; }

void assay_total_alloc_start(void) {
    assay_alloc_count = 0;
    assay_free_count = 0;
    malloc_logger = assay_counting_logger;
}

void assay_total_alloc_stop(size_t *allocations, size_t *deallocations) {
    malloc_logger = 0;
    if (allocations)   *allocations = assay_alloc_count;
    if (deallocations) *deallocations = assay_free_count;
}

#else

int assay_total_alloc_supported(void) { return 0; }
void assay_total_alloc_start(void) {}
void assay_total_alloc_stop(size_t *allocations, size_t *deallocations) {
    if (allocations)   *allocations = 0;
    if (deallocations) *deallocations = 0;
}

#endif
