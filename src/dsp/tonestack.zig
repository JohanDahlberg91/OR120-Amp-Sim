//! The OR120 tone stack, solved as the actual circuit.
//!
//! The OR120 does not use a Fender/Marshall-style ("FMV") stack. It uses a
//! **James network** — the passive Baxandall — which is why its Bass and Treble
//! controls are largely independent and why the response can be set genuinely
//! flat, neither of which an FMV stack can do.
//!
//! Topology (fig. 1 of Ramon Vargas Patron, "The James-Baxandall Passive
//! Tone-Control Network"), with the '72/'74 Orange Graphic MkII component
//! values:
//!
//!     R1 100k : IN  - A           C1 2200p : A   - WB
//!     R2 1M   : bass pot, A - B   C2 22n   : B   - WB
//!     R3 22k  : B   - GND         C3 1500p : IN  - T
//!     R4 100k : WB  - OUT         C4 10n   : U   - GND
//!     R6 1M   : treble pot, T - U
//!     R5 1M   : OUT - GND         (load: next stage's grid resistor)
//!
//! `WB` is the bass pot's wiper; the treble pot's wiper *is* the output node.
//! Both pots are split by their wiper into two series halves whose ratio is the
//! knob position.
//!
//! ## How it is solved
//!
//! Each capacitor is replaced by its trapezoidal (bilinear) companion model — a
//! conductance `2C/T` in parallel with a current source carrying the branch
//! history. That turns the whole network into a purely resistive one, so a
//! sample is a single linear solve. The conductance matrix depends only on the
//! knob positions and the sample rate, so it is inverted once in `setControls`
//! and the audio path is left with a 6x6 matrix-vector product plus four state
//! updates.
//!
//! Solving the network rather than approximating it with shelving filters means
//! the control interaction, the frequency-dependent insertion loss and the
//! asymmetry between boost and cut all fall out for free, because they are
//! properties of the circuit rather than things that have to be dialled in.
//!
//! ## Insertion loss
//!
//! Being passive, the stack always attenuates: about -13 dB through the midband,
//! bottoming out near -15 dB (`R3 / (R1 + R3)` = 22k/122k). In the real amp V1B
//! makes that back up. `midband_makeup` below plays that role so the rest of the
//! engine's gain staging keeps its existing calibration.

const std = @import("std");
const filters = @import("filters.zig");

// ---------------------------------------------------------------------------
// Component values — '72/'74 Orange Graphic MkII
// ---------------------------------------------------------------------------

const R1: f64 = 100.0e3;
const R2: f64 = 1.0e6; // bass pot
const R3: f64 = 22.0e3;
const R4: f64 = 100.0e3;
const R5: f64 = 1.0e6; // load presented by the following stage
const R6: f64 = 1.0e6; // treble pot
const C1: f64 = 2200.0e-12;
const C2: f64 = 22.0e-9;
const C3: f64 = 1500.0e-12;
const C4: f64 = 10.0e-9;

/// A fully-rotated pot would leave a 0-ohm branch and a singular matrix; clamp
/// each half to a wiper contact resistance instead.
const min_pot_ohms: f64 = 1.0;

/// Linear gain that offsets the stack's midband insertion loss, standing in for
/// V1B's recovery gain in the real amp. Without it the whole plugin would drop
/// ~13 dB and every other control's calibration would shift.
pub const midband_makeup: f32 = 4.47; // ≈ +13 dB

/// Pot taper. The Graphic's pots are marked "1M B", which in the usual
/// nomenclature is a *linear* taper — so knob position maps straight to the
/// wiper split. Set `audio_taper` if you have a unit with log pots; it gives the
/// classic 10 %-at-midpoint law.
const audio_taper = false;

fn taper(x: f32) f64 {
    const v = std.math.clamp(x, 0.0, 1.0);
    if (!audio_taper) return v;
    // (81^x - 1) / 80 — passes through 0.1 at x = 0.5.
    return (std.math.pow(f64, 81.0, v) - 1.0) / 80.0;
}

// ---------------------------------------------------------------------------
// Node numbering
// ---------------------------------------------------------------------------

const n_nodes = 6;
const A = 0;
const B = 1;
const WB = 2; // bass pot wiper
const T = 3;
const U = 4;
const OUT = 5; // also the treble pot wiper

/// Sentinels for the two terminals that are not unknowns.
const gnd: i32 = -1;
const in: i32 = -2;

const n_caps = 4;

// ---------------------------------------------------------------------------
// Coefficients (shared across channels — they depend only on the knobs)
// ---------------------------------------------------------------------------

pub const Coeffs = struct {
    /// Inverse of the nodal conductance matrix.
    minv: [n_nodes][n_nodes]f32 = blk: {
        var m: [n_nodes][n_nodes]f32 = undefined;
        for (&m) |*row| row.* = [_]f32{0.0} ** n_nodes;
        break :blk m;
    },
    /// Per-node current injected by the input source, per volt of input.
    g_in: [n_nodes]f32 = [_]f32{0.0} ** n_nodes,
    /// Companion conductances of C1..C4, times two (the state-update factor).
    two_geq: [n_caps]f32 = [_]f32{0.0} ** n_caps,

    pub fn init(sample_rate: f64) Coeffs {
        var c = Coeffs{};
        c.set(0.5, 0.5, sample_rate);
        return c;
    }

    /// Rebuild the solve matrix for the given knob positions (0..1).
    pub fn set(self: *Coeffs, bass: f32, treble: f32, sample_rate: f64) void {
        const ts = 1.0 / sample_rate;
        // Trapezoidal companion conductance for each capacitor.
        const geq = [n_caps]f64{
            2.0 * C1 / ts,
            2.0 * C2 / ts,
            2.0 * C3 / ts,
            2.0 * C4 / ts,
        };

        // Pot wiper splits. Fraction 1 puts the wiper at the "boost" end: the
        // top of the bass pot, and the input side of the treble pot.
        const fb = taper(bass);
        const ft = taper(treble);
        const r2a = @max(R2 * (1.0 - fb), min_pot_ohms); // A  - WB
        const r2b = @max(R2 * fb, min_pot_ohms); //          WB - B
        const r6a = @max(R6 * (1.0 - ft), min_pot_ohms); // T  - OUT
        const r6b = @max(R6 * ft, min_pot_ohms); //          OUT - U

        var g: [n_nodes][n_nodes]f64 = undefined;
        for (&g) |*row| row.* = [_]f64{0.0} ** n_nodes;
        var gin: [n_nodes]f64 = [_]f64{0.0} ** n_nodes;

        // Stamp an admittance between two terminals. Branches touching the
        // source contribute to `gin` instead of the matrix, because the input
        // voltage is known rather than solved for.
        const S = struct {
            fn stamp(gm: *[n_nodes][n_nodes]f64, gi: *[n_nodes]f64, a: i32, b: i32, y: f64) void {
                if (a >= 0) gm[@intCast(a)][@intCast(a)] += y;
                if (b >= 0) gm[@intCast(b)][@intCast(b)] += y;
                if (a >= 0 and b >= 0) {
                    gm[@intCast(a)][@intCast(b)] -= y;
                    gm[@intCast(b)][@intCast(a)] -= y;
                }
                if (a >= 0 and b == in) gi[@intCast(a)] += y;
                if (b >= 0 and a == in) gi[@intCast(b)] += y;
            }
        };

        S.stamp(&g, &gin, in, A, 1.0 / R1);
        S.stamp(&g, &gin, A, WB, 1.0 / r2a);
        S.stamp(&g, &gin, WB, B, 1.0 / r2b);
        S.stamp(&g, &gin, B, gnd, 1.0 / R3);
        S.stamp(&g, &gin, WB, OUT, 1.0 / R4);
        S.stamp(&g, &gin, T, OUT, 1.0 / r6a);
        S.stamp(&g, &gin, OUT, U, 1.0 / r6b);
        S.stamp(&g, &gin, OUT, gnd, 1.0 / R5);
        // Capacitor companion conductances.
        S.stamp(&g, &gin, A, WB, geq[0]);
        S.stamp(&g, &gin, B, WB, geq[1]);
        S.stamp(&g, &gin, in, T, geq[2]);
        S.stamp(&g, &gin, U, gnd, geq[3]);

        const inv = invert(g);
        for (0..n_nodes) |i| {
            for (0..n_nodes) |j| self.minv[i][j] = @floatCast(inv[i][j]);
            self.g_in[i] = @floatCast(gin[i]);
        }
        for (0..n_caps) |k| self.two_geq[k] = @floatCast(2.0 * geq[k]);
    }
};

/// Gauss-Jordan inversion with partial pivoting. Only ever runs from
/// `setControls`, never on the audio thread.
fn invert(m_in: [n_nodes][n_nodes]f64) [n_nodes][n_nodes]f64 {
    var a = m_in;
    var inv: [n_nodes][n_nodes]f64 = undefined;
    for (&inv, 0..) |*row, i| {
        row.* = [_]f64{0.0} ** n_nodes;
        row[i] = 1.0;
    }

    for (0..n_nodes) |col| {
        // Pivot on the largest magnitude in this column.
        var pivot = col;
        var best = @abs(a[col][col]);
        for (col + 1..n_nodes) |r| {
            const v = @abs(a[r][col]);
            if (v > best) {
                best = v;
                pivot = r;
            }
        }
        if (best == 0.0) continue; // singular; leave the row as-is
        if (pivot != col) {
            std.mem.swap([n_nodes]f64, &a[col], &a[pivot]);
            std.mem.swap([n_nodes]f64, &inv[col], &inv[pivot]);
        }

        const d = a[col][col];
        for (0..n_nodes) |j| {
            a[col][j] /= d;
            inv[col][j] /= d;
        }
        for (0..n_nodes) |r| {
            if (r == col) continue;
            const f = a[r][col];
            if (f == 0.0) continue;
            for (0..n_nodes) |j| {
                a[r][j] -= f * a[col][j];
                inv[r][j] -= f * inv[col][j];
            }
        }
    }
    return inv;
}

// ---------------------------------------------------------------------------
// Per-channel state
// ---------------------------------------------------------------------------

pub const State = struct {
    /// One companion current-source term per capacitor.
    s: [n_caps]f32 = [_]f32{0.0} ** n_caps,

    pub fn reset(self: *State) void {
        self.s = [_]f32{0.0} ** n_caps;
    }

    /// Advance the network by one sample. Pure arithmetic on fixed-size arrays:
    /// no allocation, no branches on data.
    pub inline fn process(self: *State, c: *const Coeffs, x: f32) f32 {
        // Right-hand side: the input source plus each capacitor's history.
        var b: [n_nodes]f32 = undefined;
        inline for (0..n_nodes) |i| b[i] = c.g_in[i] * x;
        // C1: A -> WB, C2: B -> WB, C3: IN -> T, C4: U -> GND.
        b[A] += self.s[0];
        b[WB] -= self.s[0];
        b[B] += self.s[1];
        b[WB] -= self.s[1];
        b[T] -= self.s[2];
        b[U] += self.s[3];

        var v: [n_nodes]f32 = undefined;
        inline for (0..n_nodes) |i| {
            var acc: f32 = 0.0;
            inline for (0..n_nodes) |j| acc += c.minv[i][j] * b[j];
            v[i] = acc;
        }

        // Trapezoidal state update: s <- 2*Geq*v_branch - s.
        self.s[0] = filters.flushDenormal(c.two_geq[0] * (v[A] - v[WB]) - self.s[0]);
        self.s[1] = filters.flushDenormal(c.two_geq[1] * (v[B] - v[WB]) - self.s[1]);
        self.s[2] = filters.flushDenormal(c.two_geq[2] * (x - v[T]) - self.s[2]);
        self.s[3] = filters.flushDenormal(c.two_geq[3] * v[U] - self.s[3]);

        return v[OUT];
    }
};

/// Two-lane (stereo) version of `State`, for the channel-parallel engine. The
/// `Coeffs` are shared unchanged — both channels see the same knobs, so only the
/// capacitor history is per-lane.
pub const StateVec = struct {
    pub const Vec = @Vector(2, f32);

    s: [n_caps]Vec = [_]Vec{@splat(0.0)} ** n_caps,

    pub fn reset(self: *StateVec) void {
        self.s = [_]Vec{@splat(0.0)} ** n_caps;
    }

    inline fn flush(x: Vec) Vec {
        const thr: Vec = @splat(1.0e-25);
        const zero: Vec = @splat(0.0);
        return @select(f32, @abs(x) < thr, zero, x);
    }

    pub inline fn process(self: *StateVec, c: *const Coeffs, x: Vec) Vec {
        var b: [n_nodes]Vec = undefined;
        inline for (0..n_nodes) |i| b[i] = @as(Vec, @splat(c.g_in[i])) * x;
        b[A] += self.s[0];
        b[WB] -= self.s[0];
        b[B] += self.s[1];
        b[WB] -= self.s[1];
        b[T] -= self.s[2];
        b[U] += self.s[3];

        var v: [n_nodes]Vec = undefined;
        inline for (0..n_nodes) |i| {
            var acc: Vec = @splat(0.0);
            inline for (0..n_nodes) |j| acc += @as(Vec, @splat(c.minv[i][j])) * b[j];
            v[i] = acc;
        }

        self.s[0] = flush(@as(Vec, @splat(c.two_geq[0])) * (v[A] - v[WB]) - self.s[0]);
        self.s[1] = flush(@as(Vec, @splat(c.two_geq[1])) * (v[B] - v[WB]) - self.s[1]);
        self.s[2] = flush(@as(Vec, @splat(c.two_geq[2])) * (x - v[T]) - self.s[2]);
        self.s[3] = flush(@as(Vec, @splat(c.two_geq[3])) * v[U] - self.s[3]);

        return v[OUT];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Measure the stack's steady-state gain at `freq` by driving it with a sine and
/// taking the peak once the transient has passed.
fn measureDb(bass: f32, treble: f32, freq: f32, sr: f64) f32 {
    var c = Coeffs.init(sr);
    c.set(bass, treble, sr);
    var st = State{};
    const srf: f32 = @floatCast(sr);
    // Long enough for the 22n/1M corner (~7 ms) to settle many times over.
    const warmup: usize = @intFromFloat(sr * 0.5);
    const measure: usize = @intFromFloat(sr / @as(f64, freq) * 4.0);
    var peak: f32 = 0.0;
    var i: usize = 0;
    while (i < warmup + measure) : (i += 1) {
        const t: f32 = @floatFromInt(i);
        const y = st.process(&c, std.math.sin(2.0 * std.math.pi * freq * t / srf));
        if (i >= warmup) peak = @max(peak, @abs(y));
    }
    return 20.0 * std.math.log10(@max(peak, 1e-9));
}

test "passive stack always attenuates" {
    const sr: f64 = 48000.0;
    // No knob position anywhere can produce gain — it is a passive network.
    for ([_]f32{ 0.0, 0.5, 1.0 }) |bass| {
        for ([_]f32{ 0.0, 0.5, 1.0 }) |treble| {
            for ([_]f32{ 100.0, 1000.0, 5000.0 }) |freq| {
                try testing.expect(measureDb(bass, treble, freq, sr) <= 0.1);
            }
        }
    }
}

test "midband insertion loss matches the R1/R3 divider" {
    // With both controls centred the midband sits near -13 dB, and the network
    // can never do better than R3/(R1+R3) = -14.9 dB at its lossiest.
    const d = measureDb(0.5, 0.5, 600.0, 48000.0);
    try testing.expect(d < -11.0);
    try testing.expect(d > -16.0);
}

test "controls move their own band in the right direction" {
    const sr: f64 = 48000.0;
    // Bass control moves the low end.
    const bass_lo = measureDb(0.0, 0.5, 80.0, sr);
    const bass_hi = measureDb(1.0, 0.5, 80.0, sr);
    try testing.expect(bass_hi > bass_lo + 6.0);

    // Treble control moves the top end.
    const treb_lo = measureDb(0.5, 0.0, 6000.0, sr);
    const treb_hi = measureDb(0.5, 1.0, 6000.0, sr);
    try testing.expect(treb_hi > treb_lo + 6.0);
}

test "controls are largely independent" {
    const sr: f64 = 48000.0;
    // The James topology's defining property: moving Treble barely touches the
    // bass end. (An FMV stack would fail this badly.)
    const a = measureDb(0.5, 0.0, 80.0, sr);
    const b = measureDb(0.5, 1.0, 80.0, sr);
    try testing.expect(@abs(a - b) < 4.0);
}

test "full treble cut rolls off far harder than a shelf" {
    const sr: f64 = 48000.0;
    // The real circuit keeps falling at high frequency rather than levelling
    // onto a shelf — this is what the old biquad pair got wrong.
    const at_3k = measureDb(0.5, 0.0, 3000.0, sr);
    const at_12k = measureDb(0.5, 0.0, 12000.0, sr);
    try testing.expect(at_12k < at_3k - 6.0);
}

test "discrete solve tracks the analog circuit" {
    // Spot-checks against an independent nodal analysis of the same netlist
    // (exact complex solve, no discretisation). Below 6 kHz the trapezoidal
    // network matches to within 0.5 dB; the tolerance here is deliberately
    // looser so the test does not become a tripwire for harmless rounding.
    const sr: f64 = 48000.0;
    const Case = struct { bass: f32, treble: f32, freq: f32, analog_db: f32 };
    const cases = [_]Case{
        .{ .bass = 0.5, .treble = 0.5, .freq = 80.0, .analog_db = -17.13 },
        .{ .bass = 0.5, .treble = 0.5, .freq = 593.0, .analog_db = -12.97 },
        .{ .bass = 0.5, .treble = 0.5, .freq = 6000.0, .analog_db = -11.67 },
        .{ .bass = 0.0, .treble = 0.0, .freq = 130.0, .analog_db = -21.59 },
        .{ .bass = 1.0, .treble = 1.0, .freq = 3000.0, .analog_db = -0.62 },
        .{ .bass = 1.0, .treble = 0.0, .freq = 80.0, .analog_db = -8.09 },
        .{ .bass = 0.0, .treble = 1.0, .freq = 3000.0, .analog_db = -0.47 },
    };
    for (cases) |c| {
        const got = measureDb(c.bass, c.treble, c.freq, sr);
        try testing.expect(@abs(got - c.analog_db) < 1.0);
    }
}

test "state resets to silence" {
    var c = Coeffs.init(48000.0);
    var st = State{};
    var i: usize = 0;
    while (i < 1000) : (i += 1) _ = st.process(&c, 1.0);
    st.reset();
    try testing.expectEqual(@as(f32, 0.0), st.process(&c, 0.0));
}
