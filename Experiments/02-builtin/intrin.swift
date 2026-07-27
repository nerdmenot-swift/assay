// Assay — a decoder for Swift that tells you what went wrong.
// Copyright 2026 Srinivas Iyer. Licensed under the Apache License, Version 2.0.
// See LICENSE and NOTICE at the repository root for terms.

import Builtin
import Swift

// Experiment #2 — do the Builtin.int_* intrinsics resolve, and with what suffix?
// perf-simd-and-c.md §2.1-2.2 says yes via Feature::BuiltinModule.

@inline(never)
public func movemask16(_ v: SIMD16<UInt8>) -> UInt16 {
    UInt16(Builtin.bitcast_Vec16xInt1_Int16(
        Builtin.cmp_slt_Vec16xInt8(v._storage._value, Builtin.zeroInitializer())
    ))
}

@inline(never)
public func movemask32(_ v: SIMD32<UInt8>) -> UInt32 {
    UInt32(Builtin.bitcast_Vec32xInt1_Int32(
        Builtin.cmp_slt_Vec32xInt8(v._storage._value, Builtin.zeroInitializer())
    ))
}

@inline(never)
public func eqMask16(_ v: SIMD16<UInt8>, _ needle: UInt8) -> UInt16 {
    let n = SIMD16<UInt8>(repeating: needle)
    return UInt16(Builtin.bitcast_Vec16xInt1_Int16(
        Builtin.cmp_eq_Vec16xInt8(v._storage._value, n._storage._value)
    ))
}
