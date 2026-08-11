//! Channel-parallel (SIMD) prototype of the OR120 DSP engine.
//!
//! This mirrors `engine.zig` exactly, but instead of processing the left and
//! right channels as two independent scalar passes, it packs them into a
//! `@Vector(2, f32)` and runs the whole chain once per sample with both
//! channels living in separate lanes. Filter coefficients and drive/bias values
//! are shared across channels (they come from the same knobs), so they stay
//! scalar and are broadcast (`@splat`) into the vector math. Only the per-lane
//! *state* (filter memories, FIR delay lines, sag envelope, NFB warm-start) is
//! vectorized.
//!
//! The transfer curves use a `@exp`-based `tanh` identity so the non-linearity
//! also runs 2-wide, whereas the scalar engine calls `std.math.tanh`. The two
//! are mathematically identical; any difference is float rounding only.
//!
//! This file is a benchmark/experimentation prototype — it is not wired into
//! the plugin. See `src/bench.zig`.

const std = @import("std");
const filters = @import("filters.zig");
const oversample = @import("oversample.zig");
const scalar = @import("engine.zig");
const tonestack = @import("tonestack.zig");
const rt_audit = @import("rt_audit.zig");

pub const Controls = scalar.Controls;

const num_taps = oversample.num_taps;

/// Two-lane vector: lane 0 = left channel, lane 1 = right channel.
const Vec = @Vector(2, f32);

inline fn splat(x: f32) Vec {
    return @splat(x);
}

/// Vectorized denormal flush (see `filters.flushDenormal`).
inline fn flushVec(x: Vec) Vec {
    const thr: Vec = @splat(1.0e-25);
    const zero: Vec = @splat(0.0);
    return @select(f32, @abs(x) < thr, zero, x);
}

/// SIMD `tanh` via the exact identity `tanh(x) = (e^2x - 1)/(e^2x + 1)`, with
/// the argument clamped to keep `@exp` from overflowing to inf (tanh has
/// already saturated to +-1 well before then).
inline fn vtanh(x: Vec) Vec {
    const lim: Vec = @splat(20.0);
    const c = @min(@max(x, -lim), lim);
    const e = @exp(c * @as(Vec, @splat(2.0)));
    const one: Vec = @splat(1.0);
    return (e - one) / (e + one);
}

// --- Vectorized waveshapers (mirror waveshaper.zig) -------------------------

inline fn triodeVec(x: Vec, drive: f32, bias: f32) Vec {
    const v = x * splat(drive) + splat(bias);
    return vtanh(v) - splat(std.math.tanh(bias));
}

inline fn pushPullVec(x: Vec, bias: f32) Vec {
    const b = splat(bias);
    return splat(0.5) * (vtanh(x + b) + vtanh(x - b));
}

inline fn pushPullDerivVec(x: Vec, bias: f32) Vec {
    const b = splat(bias);
    const a = vtanh(x + b);
    const c = vtanh(x - b);
    const one: Vec = @splat(1.0);
    return splat(0.5) * ((one - a * a) + (one - c * c));
}

// --- Vectorized stateful blocks --------------------------------------------

const DcBlockerVec = struct {
    r: f32 = 0.9975,
    x1: Vec = @splat(0.0),
    y1: Vec = @splat(0.0),

    inline fn process(self: *DcBlockerVec, x: Vec) Vec {
        const y = flushVec(x - self.x1 + splat(self.r) * self.y1);
        self.x1 = x;
        self.y1 = y;
        return y;
    }

    fn reset(self: *DcBlockerVec) void {
        self.x1 = @splat(0.0);
        self.y1 = @splat(0.0);
    }
};

const OnePoleVec = struct {
    a: f32 = 1.0,
    z: Vec = @splat(0.0),

    inline fn processHighpass(self: *OnePoleVec, x: Vec) Vec {
        self.z = flushVec(self.z + splat(self.a) * (x - self.z));
        return x - self.z;
    }

    fn setLowpass(self: *OnePoleVec, cutoff_hz: f32, sample_rate: f32) void {
        var s = filters.OnePole{};
        s.setLowpass(cutoff_hz, sample_rate);
        self.a = s.a;
    }

    fn reset(self: *OnePoleVec) void {
        self.z = @splat(0.0);
    }
};

const BiquadVec = struct {
    b0: f32 = 1.0,
    b1: f32 = 0.0,
    b2: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    z1: Vec = @splat(0.0),
    z2: Vec = @splat(0.0),

    inline fn process(self: *BiquadVec, x: Vec) Vec {
        const y = splat(self.b0) * x + self.z1;
        self.z1 = flushVec(splat(self.b1) * x - splat(self.a1) * y + self.z2);
        self.z2 = flushVec(splat(self.b2) * x - splat(self.a2) * y);
        return y;
    }

    fn copyCoeffs(self: *BiquadVec, src: filters.Biquad) void {
        self.b0 = src.b0;
        self.b1 = src.b1;
        self.b2 = src.b2;
        self.a1 = src.a1;
        self.a2 = src.a2;
    }

    fn setLowShelf(self: *BiquadVec, freq_hz: f32, gain_db: f32, sr: f32) void {
        var b = filters.Biquad{};
        b.setLowShelf(freq_hz, gain_db, sr);
        self.copyCoeffs(b);
    }

    fn setHighShelf(self: *BiquadVec, freq_hz: f32, gain_db: f32, sr: f32) void {
        var b = filters.Biquad{};
        b.setHighShelf(freq_hz, gain_db, sr);
        self.copyCoeffs(b);
    }

    fn reset(self: *BiquadVec) void {
        self.z1 = @splat(0.0);
        self.z2 = @splat(0.0);
    }
};

const FirVec = struct {
    buf: [num_taps]Vec = [_]Vec{@splat(0.0)} ** num_taps,
    pos: usize = 0,

    inline fn process(self: *FirVec, x: Vec) Vec {
        self.buf[self.pos] = x;
        var acc: Vec = @splat(0.0);
        var idx = self.pos;
        var k: usize = 0;
        while (k < num_taps) : (k += 1) {
            acc += splat(oversample.coeffs[k]) * self.buf[idx];
            idx = if (idx == 0) num_taps - 1 else idx - 1;
        }
        self.pos = if (self.pos == num_taps - 1) 0 else self.pos + 1;
        return acc;
    }

    fn reset(self: *FirVec) void {
        self.buf = [_]Vec{@splat(0.0)} ** num_taps;
        self.pos = 0;
    }
};

const OversamplerVec = struct {
    up: FirVec = .{},
    down: FirVec = .{},

    inline fn process(
        self: *OversamplerVec,
        x: Vec,
        ctx: anytype,
        comptime shape: fn (@TypeOf(ctx), Vec) Vec,
    ) Vec {
        const up0 = self.up.process(x * @as(Vec, @splat(2.0)));
        const up1 = self.up.process(@as(Vec, @splat(0.0)));
        const s0 = shape(ctx, up0);
        const s1 = shape(ctx, up1);
        _ = self.down.process(s0);
        return self.down.process(s1);
    }

    fn reset(self: *OversamplerVec) void {
        self.up.reset();
        self.down.reset();
    }
};

const PowerStageVec = struct {
    drive: f32 = 1.0,
    nfb: f32 = 0.0,
    bias: f32 = 0.0,
    supply: Vec = @splat(1.0),
    y1: Vec = @splat(0.0),

    inline fn shape(self: *PowerStageVec, x: Vec) Vec {
        const g = splat(self.drive) * self.supply;
        var y = self.y1;
        var it: u8 = 0;
        while (it < 4) : (it += 1) {
            const u = g * (x - splat(self.nfb) * y);
            const f = pushPullVec(u, self.bias);
            const df = pushPullDerivVec(u, self.bias);
            const fval = y - f;
            const dfval = @as(Vec, @splat(1.0)) + df * g * splat(self.nfb);
            y -= fval / dfval;
        }
        self.y1 = flushVec(y);
        return y * self.supply;
    }
};

const TriodeCtx = struct { drive: f32, bias: f32 };

fn triodeShapeVec(ctx: TriodeCtx, x: Vec) Vec {
    return triodeVec(x, ctx.drive, ctx.bias);
}

fn powerShapeVec(ctx: *PowerStageVec, x: Vec) Vec {
    return ctx.shape(x);
}

// --- Engine -----------------------------------------------------------------

pub const EngineVec = struct {
    sample_rate: f64 = 44100.0,
    bypass: bool = false,

    pre_drive: f32 = 2.5,
    pre_bias: f32 = 0.2,
    v1b_drive: f32 = 1.5,
    v1b_bias: f32 = 0.15,
    power_drive: f32 = 1.5,
    out_gain: f32 = 0.6,
    nfb: f32 = 0.3,
    power_bias: f32 = 0.25,
    sag_depth: f32 = 0.33,
    sag_atk: f32 = 0.02,
    sag_rel: f32 = 0.001,

    // Shared-coefficient filters (scalar coeffs, vector state).
    tone_coeffs: tonestack.Coeffs = .{},
    tone: tonestack.StateVec = .{},
    bright: BiquadVec = .{},
    fac: OnePoleVec = .{},

    // Per-lane state.
    v1a: OversamplerVec = .{},
    v1b: OversamplerVec = .{},
    power: OversamplerVec = .{},
    power_state: PowerStageVec = .{},
    sag_env: Vec = @splat(0.0),
    dc: DcBlockerVec = .{},

    pub fn init() EngineVec {
        var e = EngineVec{};
        e.setControls(.{});
        return e;
    }

    pub fn prepare(self: *EngineVec, sample_rate: f64) void {
        self.sample_rate = sample_rate;
        self.setControls(.{});
    }

    pub fn reset(self: *EngineVec) void {
        self.tone.reset();
        self.bright.reset();
        self.fac.reset();
        self.v1a.reset();
        self.v1b.reset();
        self.power.reset();
        self.power_state.y1 = @splat(0.0);
        self.sag_env = @splat(0.0);
        self.dc.reset();
    }

    /// Identical mapping to `engine.zig`'s `setControls`.
    pub fn setControls(self: *EngineVec, controls: Controls) void {
        self.bypass = controls.bypass;

        self.pre_drive = 0.55 * std.math.pow(f32, 10.0, (controls.gain / 10.0) * 1.3);
        self.pre_bias = 0.12 + 0.02 * controls.gain;

        self.v1b_drive = 0.5 * std.math.pow(f32, 10.0, (controls.hf_drive / 10.0) * 0.9);
        self.v1b_bias = 0.10 + 0.015 * controls.hf_drive;

        self.power_drive = 0.6 * std.math.pow(f32, 10.0, controls.volume / 10.0);
        self.out_gain = 0.7 * std.math.pow(f32, 10.0, controls.output_db / 20.0);

        const sr: f32 = @floatCast(self.sample_rate);

        self.sag_atk = 1.0 - std.math.exp(-1.0 / (0.005 * sr));
        self.sag_rel = 1.0 - std.math.exp(-1.0 / (0.150 * sr));

        self.tone_coeffs.set(controls.bass / 10.0, controls.treble / 10.0, self.sample_rate);
        const bright_db = (controls.hf_drive / 10.0) * 10.0;

        const fac_cutoffs = [_]f32{ 25.0, 55.0, 100.0, 180.0, 340.0, 600.0 };
        const step: usize = @intFromFloat(@round(std.math.clamp(controls.fac, 0.0, 5.0)));
        const fac_hz = fac_cutoffs[step];

        self.bright.setHighShelf(1500.0, bright_db, sr);
        self.fac.setLowpass(fac_hz, sr);
    }

    inline fn processSample(self: *EngineVec, x: Vec) Vec {
        // V1A first gain stage.
        var s = self.v1a.process(x, TriodeCtx{ .drive = self.pre_drive, .bias = self.pre_bias }, triodeShapeVec);
        // James tone stack, solved as the real network (see tonestack.zig).
        s = self.tone.process(&self.tone_coeffs, s) * splat(tonestack.midband_makeup);
        // F.A.C. progressive low-cut.
        s = self.fac.processHighpass(s);
        // HF Drive bright emphasis.
        s = self.bright.process(s);
        // V1B second gain stage.
        s = self.v1b.process(s, TriodeCtx{ .drive = self.v1b_drive, .bias = self.v1b_bias }, triodeShapeVec);

        // Sag envelope (per lane).
        const demand = @abs(s);
        const coef = @select(f32, demand > self.sag_env, splat(self.sag_atk), splat(self.sag_rel));
        self.sag_env = flushVec(self.sag_env + coef * (demand - self.sag_env));
        self.power_state.drive = self.power_drive;
        self.power_state.nfb = self.nfb;
        self.power_state.bias = self.power_bias;
        self.power_state.supply = @as(Vec, @splat(1.0)) - splat(self.sag_depth) * @min(self.sag_env, @as(Vec, @splat(1.0)));

        // Power section (oversampled) with NFB + sag.
        s = self.power.process(s, &self.power_state, powerShapeVec);
        s = self.dc.process(s);
        return s * splat(self.out_gain);
    }

    /// Process a de-interleaved stereo block in place.
    pub fn processBlock(self: *EngineVec, left: []f32, right: []f32) void {
        if (self.bypass) return;
        const n = @min(left.len, right.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const y = self.processSample(Vec{ left[i], right[i] });
            left[i] = y[0];
            right[i] = y[1];
        }
    }
};

// Same audio-thread invariant as the scalar engine: no heap ownership.
comptime {
    rt_audit.assertNoHeapOwnership(EngineVec);
}
