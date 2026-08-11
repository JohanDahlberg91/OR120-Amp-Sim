//! DSP engine for the OR120 amp simulation.
//!
//! The per-channel chain follows the real OR120 signal path:
//!
//!   input → V1A gain stage (2x OS triode)
//!         → James tone stack (passive Baxandall, solved as the real network)
//!         → F.A.C. stepped low-cut (coupling-cap ladder)
//!         → HF Drive bright boost → V1B gain stage (2x OS triode)
//!         → Cathodyne phase inverter (clean, unity — no shaping)
//!         → power section: 4x EL34 with global negative feedback and
//!           supply sag (2x OS), driven by Volume
//!         → DC blocker → output level
//!
//! The two stereo channels are independent instances of the same chain sharing
//! the control coefficients.

const std = @import("std");
const filters = @import("filters.zig");
const waveshaper = @import("waveshaper.zig");
const oversample = @import("oversample.zig");
const tonestack = @import("tonestack.zig");
const rt_audit = @import("rt_audit.zig");

const Biquad = filters.Biquad;
const OnePole = filters.OnePole;
const Oversampler2x = oversample.Oversampler2x;

/// Raw parameter values as presented by the host (knob ranges 0..10 unless
/// noted). The engine maps these onto internal gains and filter coefficients.
pub const Controls = struct {
    gain: f32 = 5.0,
    bass: f32 = 5.0,
    treble: f32 = 5.0,
    hf_drive: f32 = 5.0,
    fac: f32 = 2.0,
    volume: f32 = 5.0,
    output_db: f32 = 0.0,
    bypass: bool = false,
};

/// First-order DC blocker: `y[n] = x[n] - x[n-1] + r * y[n-1]`.
const DcBlocker = struct {
    r: f32 = 0.9975,
    x1: f32 = 0.0,
    y1: f32 = 0.0,

    inline fn process(self: *DcBlocker, x: f32) f32 {
        const y = filters.flushDenormal(x - self.x1 + self.r * self.y1);
        self.x1 = x;
        self.y1 = y;
        return y;
    }

    fn reset(self: *DcBlocker) void {
        self.x1 = 0.0;
        self.y1 = 0.0;
    }
};

const TriodeCtx = struct { drive: f32, bias: f32 };

fn triodeShape(ctx: TriodeCtx, x: f32) f32 {
    return waveshaper.triode(x, ctx.drive, ctx.bias);
}

/// The 4x EL34 power section. Models a class-AB push-pull pair, a global
/// negative-feedback loop and a drooping (sagging) supply. The NFB loop is
/// memoryless (the OT is lumped into the shelving elsewhere), so
/// `y = f(drive * supply * (x - nfb * y))` is solved per sample with a few
/// Newton steps — stable even at high loop gain and with no artificial
/// one-sample delay in the loop.
const PowerStage = struct {
    drive: f32 = 1.0,
    nfb: f32 = 0.0,
    bias: f32 = 0.0, // class-AB operating point (crossover character)
    supply: f32 = 1.0, // 0..1 sag scale, refreshed each base sample
    y1: f32 = 0.0, // last solved output (feedback state + Newton warm start)

    inline fn shape(self: *PowerStage, x: f32) f32 {
        const g = self.drive * self.supply;
        var y = self.y1;
        var it: u8 = 0;
        while (it < 4) : (it += 1) {
            const u = g * (x - self.nfb * y);
            const f = waveshaper.pushPull(u, self.bias);
            const df = waveshaper.pushPullDeriv(u, self.bias);
            const fval = y - f;
            const dfval = 1.0 + df * g * self.nfb;
            y -= fval / dfval;
        }
        self.y1 = filters.flushDenormal(y);
        // Sag also dips the delivered level as the supply collapses under load.
        return y * self.supply;
    }
};

fn powerShape(ctx: *PowerStage, x: f32) f32 {
    return ctx.shape(x);
}

/// One complete amp channel. Coefficients are written by `Engine.setControls`;
/// only the internal delay/envelope state is per-channel.
const Channel = struct {
    v1a: Oversampler2x = .{},
    /// Capacitor state of the James tone stack. Its coefficients live on the
    /// Engine (they depend only on the knobs, which both channels share).
    tone: tonestack.State = .{},
    fac: OnePole = .{},
    bright: Biquad = .{},
    v1b: Oversampler2x = .{},
    power: Oversampler2x = .{},
    power_state: PowerStage = .{},
    sag_env: f32 = 0.0,
    dc: DcBlocker = .{},

    fn reset(self: *Channel) void {
        self.v1a.reset();
        self.tone.reset();
        self.fac.reset();
        self.bright.reset();
        self.v1b.reset();
        self.power.reset();
        self.power_state.y1 = 0.0;
        self.sag_env = 0.0;
        self.dc.reset();
    }

    inline fn process(self: *Channel, eng: *const Engine, x: f32) f32 {
        // V1A first gain stage.
        var s = self.v1a.process(x, TriodeCtx{ .drive = eng.pre_drive, .bias = eng.pre_bias }, triodeShape);
        // James (passive Baxandall) tone stack, solved as the real network.
        // It is lossy by nature; `midband_makeup` stands in for V1B's recovery
        // gain in the real amp. The loss is frequency-dependent, so what reaches
        // the next stage varies with the knobs — that is the point.
        s = self.tone.process(&eng.tone, s) * tonestack.midband_makeup;
        // F.A.C. progressive low-cut before the second stage.
        s = self.fac.processHighpass(s);
        // HF Drive bright emphasis feeding V1B.
        s = self.bright.process(s);
        // V1B second gain stage.
        s = self.v1b.process(s, TriodeCtx{ .drive = eng.v1b_drive, .bias = eng.v1b_bias }, triodeShape);
        // Cathodyne phase inverter: stays clean, so it is a unity pass-through.

        // Update the sag envelope from the demand hitting the power section, then
        // let the supply droop accordingly for this sample.
        const demand = @abs(s);
        const coef = if (demand > self.sag_env) eng.sag_atk else eng.sag_rel;
        self.sag_env = filters.flushDenormal(self.sag_env + coef * (demand - self.sag_env));
        self.power_state.drive = eng.power_drive;
        self.power_state.nfb = eng.nfb;
        self.power_state.bias = eng.power_bias;
        self.power_state.supply = 1.0 - eng.sag_depth * @min(self.sag_env, 1.0);

        // Power section (oversampled) with NFB + sag.
        s = self.power.process(s, &self.power_state, powerShape);
        s = self.dc.process(s);
        return s * eng.out_gain;
    }
};

pub const Engine = struct {
    sample_rate: f64 = 44100.0,
    bypass: bool = false,

    // Mapped control values.
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

    /// Tone-stack solve matrix. Shared: it depends only on the knob positions.
    tone: tonestack.Coeffs = .{},

    channels: [2]Channel = .{ .{}, .{} },

    pub fn init() Engine {
        var e = Engine{};
        e.setControls(.{});
        return e;
    }

    /// Called from activate() with the negotiated sample rate.
    pub fn prepare(self: *Engine, sample_rate: f64) void {
        self.sample_rate = sample_rate;
        self.setControls(.{});
    }

    /// Reset all time-varying state.
    pub fn reset(self: *Engine) void {
        self.channels[0].reset();
        self.channels[1].reset();
    }

    /// Map raw parameter values onto internal gains and filter coefficients.
    pub fn setControls(self: *Engine, controls: Controls) void {
        self.bypass = controls.bypass;

        // V1A drive from the Gain knob. Kept relatively clean so the power
        // section does most of the sag/bloom work (authentic OR120 behaviour).
        self.pre_drive = 0.55 * std.math.pow(f32, 10.0, (controls.gain / 10.0) * 1.3);
        self.pre_bias = 0.12 + 0.02 * controls.gain;

        // HF Drive sets V1B drive; V1B recovers tone-stack loss and adds grit.
        self.v1b_drive = 0.5 * std.math.pow(f32, 10.0, (controls.hf_drive / 10.0) * 0.9);
        self.v1b_bias = 0.10 + 0.015 * controls.hf_drive;

        // Volume drives the power section.
        self.power_drive = 0.6 * std.math.pow(f32, 10.0, controls.volume / 10.0);

        // Overall makeup plus the Output level control (dB).
        self.out_gain = 0.7 * std.math.pow(f32, 10.0, controls.output_db / 20.0);

        const sr: f32 = @floatCast(self.sample_rate);

        // Sag time constants: fast-ish attack, slow recovery.
        self.sag_atk = 1.0 - std.math.exp(-1.0 / (0.005 * sr));
        self.sag_rel = 1.0 - std.math.exp(-1.0 / (0.150 * sr));

        // James tone stack: rebuild the network solve for the new knob
        // positions. The boost/cut range, the corner frequencies and the
        // insertion loss are all properties of the components, so there is
        // nothing to scale here — the knobs map straight onto the wipers.
        self.tone.set(controls.bass / 10.0, controls.treble / 10.0, self.sample_rate);

        // HF Drive brightness: a top-end lift into V1B (boost only).
        const bright_db = (controls.hf_drive / 10.0) * 10.0;

        // F.A.C.: a 6-position coupling-cap ladder → stepped high-pass cutoff.
        // Position 0 = largest cap (full sub-bass); position 5 = smallest cap
        // (bright, thin chime). It is a genuine 6-step rotary switch.
        const fac_cutoffs = [_]f32{ 25.0, 55.0, 100.0, 180.0, 340.0, 600.0 };
        const step: usize = @intFromFloat(@round(std.math.clamp(controls.fac, 0.0, 5.0)));
        const fac_hz = fac_cutoffs[step];

        for (&self.channels) |*ch| {
            ch.bright.setHighShelf(1500.0, bright_db, sr);
            ch.fac.setLowpass(fac_hz, sr);
        }
    }

    /// Process a de-interleaved stereo block in place. Runs on the audio thread:
    /// no allocation, no locks, no syscalls — see `rt_audit.zig`.
    pub fn processBlock(self: *Engine, left: []f32, right: []f32) void {
        if (self.bypass) return;
        const n = @min(left.len, right.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            left[i] = self.channels[0].process(self, left[i]);
            right[i] = self.channels[1].process(self, right[i]);
        }
    }
};

// The engine lives inline in the plugin struct and is the only state the audio
// thread mutates, so it must not own heap memory. Enforced at build time.
comptime {
    rt_audit.assertNoHeapOwnership(Engine);
}

test "bypass leaves buffer untouched" {
    var eng = Engine.init();
    eng.prepare(48000.0);
    eng.reset();
    eng.setControls(.{ .bypass = true });
    var l = [_]f32{ 0.1, -0.2, 0.3, -0.4 };
    var r = [_]f32{ -0.1, 0.2, -0.3, 0.4 };
    const l_before = l;
    const r_before = r;
    eng.processBlock(&l, &r);
    try std.testing.expectEqualSlices(f32, &l_before, &l);
    try std.testing.expectEqualSlices(f32, &r_before, &r);
}

test "output stays bounded and finite under heavy drive" {
    var eng = Engine.init();
    eng.prepare(48000.0);
    eng.reset();
    eng.setControls(.{ .gain = 10.0, .volume = 10.0, .output_db = 12.0 });
    var l: [512]f32 = undefined;
    var r: [512]f32 = undefined;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const v = 4.0 * std.math.sin(2.0 * std.math.pi * 220.0 * t / 48000.0);
        l[i] = v;
        r[i] = v;
    }
    eng.processBlock(&l, &r);
    for (l) |s| {
        try std.testing.expect(std.math.isFinite(s));
        try std.testing.expect(@abs(s) < 8.0);
    }
}

test "small signal produces finite non-zero output" {
    var eng = Engine.init();
    eng.prepare(48000.0);
    eng.reset();
    eng.setControls(.{});
    var l: [1024]f32 = undefined;
    var r: [1024]f32 = undefined;
    var i: usize = 0;
    while (i < l.len) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const v = 0.01 * std.math.sin(2.0 * std.math.pi * 440.0 * t / 48000.0);
        l[i] = v;
        r[i] = v;
    }
    eng.processBlock(&l, &r);
    var peak: f32 = 0.0;
    for (l) |s| {
        try std.testing.expect(std.math.isFinite(s));
        peak = @max(peak, @abs(s));
    }
    try std.testing.expect(peak > 0.0);
}

test "dc blocker removes a steady offset" {
    var dc = DcBlocker{};
    var y: f32 = 0.0;
    var i: usize = 0;
    while (i < 20000) : (i += 1) y = dc.process(1.0);
    try std.testing.expect(@abs(y) < 0.05);
}
