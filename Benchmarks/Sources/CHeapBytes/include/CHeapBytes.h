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

#endif
