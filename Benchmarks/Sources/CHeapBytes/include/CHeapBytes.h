// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

#ifndef ASSAY_CHEAPBYTES_H
#define ASSAY_CHEAPBYTES_H
#include <stddef.h>

/// Live heap bytes, or 0 where the platform does not expose a figure.
///
/// This exists to keep a STRUCT RETURN on the C side of the boundary. glibc's `mallinfo2`
/// returns a ten-field struct by value, and how that is returned is ABI-specific: aarch64
/// passes it in registers, x86-64 SysV passes a hidden pointer. A Swift `@_silgen_name`
/// declaration cannot express that difference, so declaring the struct in Swift and calling
/// `mallinfo2` directly worked on aarch64 and silently corrupted memory on x86-64 — the
/// benchmark died in `swift_release` during teardown, nowhere near the call.
///
/// Letting the C compiler handle the struct and handing Swift a single `size_t` removes the
/// question entirely.
size_t assay_live_heap_bytes(void);

/// TOTAL malloc traffic — every allocation made, including ones freed again inside the
/// measured region. This is the metric `CLAUDE.md` records as "genuinely unmeasured": the
/// live-block gate structurally cannot see a transient allocation, and `.mallocCountTotal`
/// needs jemalloc installed beside the toolchain and cannot run on the musl or wasm legs.
///
/// Darwin has a first-class answer that needs no jemalloc and no interposition:
/// `malloc_logger`, the global hook `MallocStackLogging` itself uses. Setting it in-process
/// makes the allocator call us on every allocate and every deallocate, exactly, with no
/// batching — verified against a loop of 1000 mallocs and 1000 frees, which counts 1000 and
/// 1000 rather than the nano zone's approximation.
///
/// Symbol interposition was considered and rejected rather than untried. Defining `malloc`
/// in the executable works on Linux but NOT on Darwin: two-level namespace binding means
/// `swift_slowAlloc` in libswiftCore.dylib is already bound to libsystem_malloc's `malloc`,
/// so nothing the main executable defines is ever consulted. Making that work needs
/// `DYLD_INTERPOSE` in a separate dylib plus `DYLD_INSERT_LIBRARIES`, which `swift run`
/// cannot arrange.
///
/// Darwin only. Elsewhere `assay_total_alloc_supported()` returns 0 and the counters stay
/// at zero — never report a number the platform did not supply.
int assay_total_alloc_supported(void);

/// Begin counting. Resets both counters. Not reentrant and not thread-safe: the hook is a
/// single global, and the counters are plain non-atomic integers because making them atomic
/// would put a lock on the allocator's hot path and change what is being measured.
void assay_total_alloc_start(void);

/// Stop counting, and read back the totals since `start`.
void assay_total_alloc_stop(size_t *allocations, size_t *deallocations);

#endif
