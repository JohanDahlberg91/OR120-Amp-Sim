//! Compile-time real-time-safety audit for the audio-thread data types.
//!
//! Heap allocation is forbidden on the audio thread: `malloc`/`free` take a lock
//! and can wander into the OS page allocator, so their worst-case latency is
//! unbounded. A block that misses its deadline is an audible dropout, and the
//! failure is load-dependent, so it will not show up reliably in testing.
//!
//! Zig never allocates implicitly, so a DSP type can only reach the heap if it
//! holds a pointer or slice to memory somebody allocated for it. That makes the
//! invariant checkable from the type alone: every type on the audio path must be
//! a flat, fixed-size value — plain scalars nested in arrays, vectors, structs
//! and unions, with no indirection anywhere.
//!
//! `assertNoHeapOwnership` walks a type recursively and fails the build if it
//! finds any pointer field. Call it from a container-level `comptime` block so
//! the check runs during a normal `zig build`, not only under `zig build test`.

const std = @import("std");

/// Fail compilation if `T` (or anything nested inside it) can own heap memory.
pub fn assertNoHeapOwnership(comptime T: type) void {
    comptime audit(T, @typeName(T));
}

fn audit(comptime T: type, comptime path: []const u8) void {
    switch (@typeInfo(T)) {
        // Inline, fixed-size scalars: nothing to own.
        .bool,
        .int,
        .float,
        .void,
        .@"enum",
        .error_set,
        .comptime_int,
        .comptime_float,
        .type,
        .enum_literal,
        => {},

        .@"struct" => |info| {
            for (info.fields) |f| {
                // Comptime fields exist only in the type, never in memory.
                if (f.is_comptime) continue;
                audit(f.type, path ++ "." ++ f.name);
            }
        },
        .@"union" => |info| {
            for (info.fields) |f| audit(f.type, path ++ "." ++ f.name);
        },
        .array => |info| audit(info.child, path ++ "[_]"),
        .vector => |info| audit(info.child, path ++ "[lane]"),
        .optional => |info| audit(info.child, path ++ ".?"),
        .error_union => |info| audit(info.payload, path ++ "!"),

        .pointer => @compileError("real-time audit: " ++ path ++ " is a pointer/slice (" ++
            @typeName(T) ++ "). Audio-path types must be flat fixed-size values so " ++
            "they cannot own heap memory. Allocate up front in activate()/create() " ++
            "instead, or store the data inline as a fixed-size array."),

        else => @compileError("real-time audit: " ++ path ++ " has type " ++ @typeName(T) ++
            ", which this audit cannot prove is allocation-free. Extend " ++
            "src/dsp/rt_audit.zig if it is genuinely inline."),
    }
}

test "flat value types pass the audit" {
    const Flat = struct {
        a: f32,
        b: [4]f64,
        c: @Vector(2, f32),
        d: struct { e: bool, f: enum { x, y } },
        g: ?u32,
    };
    comptime assertNoHeapOwnership(Flat);
    comptime assertNoHeapOwnership(std.atomic.Value(f64));
}
