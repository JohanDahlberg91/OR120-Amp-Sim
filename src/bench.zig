//! Scalar-vs-SIMD benchmark for the OR120 DSP engine.
//!
//! Builds two engines with identical controls, verifies the vectorized engine
//! matches the scalar reference sample-for-sample (within float tolerance),
//! then times both over many blocks and reports throughput + speedup.
//!
//! Build with an optimized mode for meaningful numbers:
//!     zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const scalar = @import("dsp/engine.zig");
const vecmod = @import("dsp/engine_vec.zig");

const block = 512;
const blocks = 40_000; // total blocks per engine
const sample_rate = 48_000.0;

const controls = scalar.Controls{
    .gain = 8.0,
    .bass = 6.0,
    .treble = 7.0,
    .hf_drive = 6.5,
    .fac = 2.0,
    .volume = 8.0,
    .output_db = 0.0,
    .bypass = false,
};

extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;

fn qpc() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

/// A repeatable, distortion-exercising input: mixed sines + a little noise.
fn fillSource(src_l: []f32, src_r: []f32) void {
    var prng = std.Random.DefaultPrng.init(0x120);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < src_l.len) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const a = std.math.sin(2.0 * std.math.pi * 110.0 * t / sample_rate);
        const b = std.math.sin(2.0 * std.math.pi * 220.0 * t / sample_rate);
        const n = (rnd.float(f32) - 0.5) * 0.05;
        const sig = 0.7 * (0.6 * a + 0.4 * b) + n;
        src_l[i] = sig;
        src_r[i] = sig * 0.98; // slight L/R difference so both lanes do real work
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const total = block * blocks;
    const src_l = try alloc.alloc(f32, total);
    defer alloc.free(src_l);
    const src_r = try alloc.alloc(f32, total);
    defer alloc.free(src_r);
    fillSource(src_l, src_r);

    const buf_l = try alloc.alloc(f32, total);
    defer alloc.free(buf_l);
    const buf_r = try alloc.alloc(f32, total);
    defer alloc.free(buf_r);

    const print = std.debug.print;

    // ---- Correctness: compare scalar vs vector over the whole signal --------
    {
        var e1 = scalar.Engine.init();
        e1.prepare(sample_rate);
        e1.reset();
        e1.setControls(controls);

        var e2 = vecmod.EngineVec.init();
        e2.prepare(sample_rate);
        e2.reset();
        e2.setControls(controls);

        @memcpy(buf_l, src_l);
        @memcpy(buf_r, src_r);
        const out2_l = try alloc.alloc(f32, total);
        defer alloc.free(out2_l);
        const out2_r = try alloc.alloc(f32, total);
        defer alloc.free(out2_r);
        @memcpy(out2_l, src_l);
        @memcpy(out2_r, src_r);

        var off: usize = 0;
        while (off < total) : (off += block) {
            e1.processBlock(buf_l[off .. off + block], buf_r[off .. off + block]);
            e2.processBlock(out2_l[off .. off + block], out2_r[off .. off + block]);
        }

        var max_diff: f32 = 0.0;
        var i: usize = 0;
        while (i < total) : (i += 1) {
            max_diff = @max(max_diff, @abs(buf_l[i] - out2_l[i]));
            max_diff = @max(max_diff, @abs(buf_r[i] - out2_r[i]));
        }
        print("correctness: max |scalar - vector| = {e:.3}\n", .{max_diff});
    }

    // ---- Timing: scalar ------------------------------------------------------
    var checksum: f64 = 0.0;
    const scalar_ticks = blk: {
        var e = scalar.Engine.init();
        e.prepare(sample_rate);
        e.reset();
        e.setControls(controls);

        const start = qpc();
        var off: usize = 0;
        while (off < total) : (off += block) {
            @memcpy(buf_l[off .. off + block], src_l[off .. off + block]);
            @memcpy(buf_r[off .. off + block], src_r[off .. off + block]);
            e.processBlock(buf_l[off .. off + block], buf_r[off .. off + block]);
        }
        const end = qpc();
        for (buf_l) |v| checksum += v;
        break :blk end - start;
    };

    // ---- Timing: vector ------------------------------------------------------
    const vector_ticks = blk: {
        var e = vecmod.EngineVec.init();
        e.prepare(sample_rate);
        e.reset();
        e.setControls(controls);

        const start = qpc();
        var off: usize = 0;
        while (off < total) : (off += block) {
            @memcpy(buf_l[off .. off + block], src_l[off .. off + block]);
            @memcpy(buf_r[off .. off + block], src_r[off .. off + block]);
            e.processBlock(buf_l[off .. off + block], buf_r[off .. off + block]);
        }
        const end = qpc();
        for (buf_l) |v| checksum += v;
        break :blk end - start;
    };

    var freq_i: i64 = 0;
    _ = QueryPerformanceFrequency(&freq_i);
    const freq: f64 = @floatFromInt(freq_i);
    const samples: f64 = @floatFromInt(total);
    const scalar_s = @as(f64, @floatFromInt(scalar_ticks)) / freq;
    const vector_s = @as(f64, @floatFromInt(vector_ticks)) / freq;
    const scalar_msps = samples / scalar_s / 1e6;
    const vector_msps = samples / vector_s / 1e6;

    print("frames per engine: {d} stereo samples ({d} blocks x {d})\n", .{ total, blocks, block });
    print("scalar : {d:.3} ms  ({d:.1} Msamp/s)\n", .{ scalar_s * 1e3, scalar_msps });
    print("vector : {d:.3} ms  ({d:.1} Msamp/s)\n", .{ vector_s * 1e3, vector_msps });
    print("speedup: {d:.2}x\n", .{scalar_s / vector_s});
    // Realtime headroom at 48 kHz (higher = more CPU to spare).
    const rt_scalar = samples / sample_rate / scalar_s;
    const rt_vector = samples / sample_rate / vector_s;
    print("realtime x: scalar {d:.0}x, vector {d:.0}x\n", .{ rt_scalar, rt_vector });
    print("(checksum {d:.6})\n", .{checksum});
}
