//! 2x oversampling wrapper for the non-linear stages.
//!
//! Non-linearities generate harmonics above the base Nyquist that would
//! otherwise fold back as aliasing. We upsample 2x (zero-stuffing + FIR
//! low-pass), evaluate the non-linearity at the higher rate, then FIR low-pass
//! again and decimate back down.
//!
//! A single linear-phase windowed-sinc low-pass (cutoff ≈ base Nyquist) is used
//! for both the interpolation and decimation filters. Coefficients are computed
//! at comptime with a Hamming window.

const std = @import("std");

/// Number of FIR taps. Odd so the filter is symmetric with an integer delay.
pub const num_taps = 31;

pub const coeffs: [num_taps]f32 = blk: {
    @setEvalBranchQuota(200000);
    var h: [num_taps]f32 = undefined;
    const m: f64 = @floatFromInt(num_taps - 1);
    // Cutoff normalised to the *oversampled* rate. 0.25 => base Nyquist.
    const fc: f64 = 0.25;
    var sum: f64 = 0.0;
    var i: usize = 0;
    while (i < num_taps) : (i += 1) {
        const fi: f64 = @floatFromInt(i);
        const n = fi - m / 2.0;
        var s: f64 = undefined;
        if (n == 0.0) {
            s = 2.0 * fc;
        } else {
            s = std.math.sin(2.0 * std.math.pi * fc * n) / (std.math.pi * n);
        }
        // Hamming window.
        const w = 0.54 - 0.46 * std.math.cos(2.0 * std.math.pi * fi / m);
        s *= w;
        h[i] = @floatCast(s);
        sum += s;
    }
    // Normalise DC gain to unity.
    i = 0;
    while (i < num_taps) : (i += 1) {
        h[i] = @floatCast(@as(f64, h[i]) / sum);
    }
    break :blk h;
};

/// A simple FIR delay line running the shared low-pass `coeffs`.
const Fir = struct {
    buf: [num_taps]f32 = [_]f32{0.0} ** num_taps,
    pos: usize = 0,

    inline fn process(self: *Fir, x: f32) f32 {
        self.buf[self.pos] = x;
        var acc: f32 = 0.0;
        var idx = self.pos;
        var k: usize = 0;
        while (k < num_taps) : (k += 1) {
            acc += coeffs[k] * self.buf[idx];
            idx = if (idx == 0) num_taps - 1 else idx - 1;
        }
        self.pos = if (self.pos == num_taps - 1) 0 else self.pos + 1;
        return acc;
    }

    fn reset(self: *Fir) void {
        self.buf = [_]f32{0.0} ** num_taps;
        self.pos = 0;
    }
};

/// 2x oversampler. Call `process` with the per-sample non-linearity to run.
pub const Oversampler2x = struct {
    up: Fir = .{},
    down: Fir = .{},

    pub fn reset(self: *Oversampler2x) void {
        self.up.reset();
        self.down.reset();
    }

    /// Process one base-rate sample through `shape`, evaluated twice at 2x rate.
    /// `shape` receives an upsampled sample and returns the shaped value.
    pub inline fn process(
        self: *Oversampler2x,
        x: f32,
        ctx: anytype,
        comptime shape: fn (@TypeOf(ctx), f32) f32,
    ) f32 {
        // Zero-stuffing upsample (scale by 2 to compensate for inserted zeros).
        const up0 = self.up.process(x * 2.0);
        const up1 = self.up.process(0.0);
        const s0 = shape(ctx, up0);
        const s1 = shape(ctx, up1);
        // Low-pass then decimate: keep the second sub-sample output.
        _ = self.down.process(s0);
        return self.down.process(s1);
    }
};

fn passthrough(_: void, x: f32) f32 {
    return x;
}

test "oversampler passes a low-frequency sine with near-unity gain" {
    var os = Oversampler2x{};
    const sr: f32 = 48000.0;
    const freq: f32 = 200.0;
    var peak: f32 = 0.0;
    var i: usize = 0;
    // Skip the FIR group-delay transient, then measure the peak.
    while (i < 4000) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const x = std.math.sin(2.0 * std.math.pi * freq * t / sr);
        const y = os.process(x, {}, passthrough);
        if (i > 200) peak = @max(peak, @abs(y));
    }
    try std.testing.expect(peak > 0.9);
    try std.testing.expect(peak < 1.1);
}

test "oversampler strongly attenuates content near Nyquist" {
    var os = Oversampler2x{};
    const sr: f32 = 48000.0;
    const freq: f32 = 23000.0; // just under Nyquist
    var peak: f32 = 0.0;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const x = std.math.sin(2.0 * std.math.pi * freq * t / sr);
        const y = os.process(x, {}, passthrough);
        if (i > 200) peak = @max(peak, @abs(y));
    }
    try std.testing.expect(peak < 0.5);
}
