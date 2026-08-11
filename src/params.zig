//! Parameter definitions and a thread-safe value store for the OR120 amp sim.
//!
//! The store is the bridge between threads: the main/GUI thread and incoming
//! host parameter events (on the audio thread) write values; the audio thread
//! reads them. Each value is an atomic f64, which is all CLAP requires for the
//! Phase 2 parameter set.

const std = @import("std");
const c = @import("c.zig");
const rt_audit = @import("dsp/rt_audit.zig");

pub const ParamId = enum(u32) {
    gain = 0,
    bass = 1,
    treble = 2,
    hf_drive = 3,
    fac = 4,
    volume = 5,
    output = 6,
    bypass = 7,
};

pub const count = 8;

pub const Descriptor = struct {
    id: ParamId,
    name: []const u8,
    min: f64,
    max: f64,
    default: f64,
    flags: u32,
};

const automatable = c.clap.CLAP_PARAM_IS_AUTOMATABLE;

pub const descriptors = [count]Descriptor{
    .{ .id = .gain, .name = "Gain", .min = 0, .max = 10, .default = 5, .flags = automatable },
    .{ .id = .bass, .name = "Bass", .min = 0, .max = 10, .default = 5, .flags = automatable },
    .{ .id = .treble, .name = "Treble", .min = 0, .max = 10, .default = 5, .flags = automatable },
    .{ .id = .hf_drive, .name = "HF Drive", .min = 0, .max = 10, .default = 5, .flags = automatable },
    .{ .id = .fac, .name = "F.A.C.", .min = 0, .max = 5, .default = 2, .flags = automatable | c.clap.CLAP_PARAM_IS_STEPPED },
    .{ .id = .volume, .name = "Volume", .min = 0, .max = 10, .default = 5, .flags = automatable },
    .{ .id = .output, .name = "Output", .min = -24, .max = 24, .default = 0, .flags = automatable },
    .{ .id = .bypass, .name = "Bypass", .min = 0, .max = 1, .default = 0, .flags = automatable | c.clap.CLAP_PARAM_IS_STEPPED | c.clap.CLAP_PARAM_IS_BYPASS },
};

pub fn descriptorFor(id: ParamId) Descriptor {
    return descriptors[@intFromEnum(id)];
}

/// Thread-safe parameter store. Written by the main/GUI thread and by param
/// events on the audio thread; read by the audio thread.
pub const State = struct {
    values: [count]std.atomic.Value(f64),

    pub fn init() State {
        var s: State = undefined;
        for (descriptors, 0..) |d, i| {
            s.values[i] = std.atomic.Value(f64).init(d.default);
        }
        return s;
    }

    pub fn get(self: *const State, id: ParamId) f64 {
        return self.values[@intFromEnum(id)].load(.monotonic);
    }

    pub fn set(self: *State, id: ParamId, value: f64) void {
        self.setRaw(@intFromEnum(id), value);
    }

    /// Set by numeric id (as received from a host parameter event). Unknown ids
    /// are ignored; values are clamped to the parameter's declared range.
    pub fn setRaw(self: *State, raw_id: u32, value: f64) void {
        if (raw_id >= count) return;
        const d = descriptors[raw_id];
        const clamped = std.math.clamp(value, d.min, d.max);
        self.values[raw_id].store(clamped, .monotonic);
    }
};

/// A single parameter change originating from the GUI, to be forwarded to the
/// host as CLAP events.
pub const Change = struct {
    pub const Kind = enum(u8) { gesture_begin, value, gesture_end };
    id: u32,
    kind: Kind,
    value: f64 = 0,
};

/// Lock-free single-producer / single-consumer ring buffer carrying GUI
/// parameter changes to the audio (or main) thread, where they are emitted to
/// the host's output event queue. The GUI thread is the sole producer; the
/// consumer is the audio thread during `process` or the main thread during
/// `flush` (CLAP guarantees these never run concurrently).
pub const ChangeQueue = struct {
    const capacity = 256;

    buf: [capacity]Change = undefined,
    head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn push(self: *ChangeQueue, change: Change) void {
        const tail = self.tail.load(.monotonic);
        const next = (tail + 1) % capacity;
        if (next == self.head.load(.acquire)) return; // full: drop
        self.buf[tail] = change;
        self.tail.store(next, .release);
    }

    pub fn pop(self: *ChangeQueue) ?Change {
        const head = self.head.load(.monotonic);
        if (head == self.tail.load(.acquire)) return null; // empty
        const change = self.buf[head];
        self.head.store((head + 1) % capacity, .release);
        return change;
    }
};

// Both of these are read/written by the audio thread during `process`, so like
// the DSP engine they must be flat fixed-size values with no heap ownership.
// The ring buffer in particular must keep its inline `buf`: switching it to an
// allocated slice would put a `free`/`realloc` on the audio thread.
comptime {
    rt_audit.assertNoHeapOwnership(State);
    rt_audit.assertNoHeapOwnership(ChangeQueue);
}

test "state initializes to defaults and clamps" {
    var s = State.init();
    try std.testing.expectEqual(@as(f64, 5), s.get(.gain));
    try std.testing.expectEqual(@as(f64, 0), s.get(.output));

    s.set(.gain, 99);
    try std.testing.expectEqual(@as(f64, 10), s.get(.gain));

    s.set(.output, -100);
    try std.testing.expectEqual(@as(f64, -24), s.get(.output));

    s.setRaw(999, 1.0); // out-of-range id is a no-op
}

test "change queue is FIFO and drops on overflow" {
    var q = ChangeQueue{};
    try std.testing.expect(q.pop() == null);

    q.push(.{ .id = 0, .kind = .gesture_begin });
    q.push(.{ .id = 0, .kind = .value, .value = 3.5 });
    q.push(.{ .id = 0, .kind = .gesture_end });

    try std.testing.expectEqual(params_change_begin, q.pop().?.kind);
    const v = q.pop().?;
    try std.testing.expectEqual(@as(f64, 3.5), v.value);
    try std.testing.expectEqual(Change.Kind.gesture_end, q.pop().?.kind);
    try std.testing.expect(q.pop() == null);
}

const params_change_begin = Change.Kind.gesture_begin;
