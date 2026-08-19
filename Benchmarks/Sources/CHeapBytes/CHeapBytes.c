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
