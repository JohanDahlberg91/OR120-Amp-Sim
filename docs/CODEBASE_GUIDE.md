# OR120-Amp-Sim — Codebase Learning Guide

A guided tour of the whole project, written to teach three things at once:

1. **Zig** — the language, its syntax, and its idioms.
2. **DSP / audio engineering** — how a guitar amplifier is turned into maths and code.
3. **Low-level programming** — ABIs, calling conventions, pointers, memory ownership, threads.

Read it top to bottom the first time. After that, use it as a reference: every
section maps to real files so you can jump between the explanation and the code.

---

## Table of contents

1. [The big picture](#1-the-big-picture)
2. [How the pieces fit together](#2-how-the-pieces-fit-together)
3. [Zig crash course (as used in this repo)](#3-zig-crash-course-as-used-in-this-repo)
4. [Low-level concepts you need](#4-low-level-concepts-you-need)
5. [The build system (`build.zig`)](#5-the-build-system-buildzig)
6. [The CLAP plugin layer](#6-the-clap-plugin-layer)
7. [Parameters, atomics, and the lock-free queue](#7-parameters-atomics-and-the-lock-free-queue)
8. [DSP theory and the audio engine](#8-dsp-theory-and-the-audio-engine)
9. [The GUI layer](#9-the-gui-layer)
10. [Glossary](#10-glossary)
11. [A suggested learning path / exercises](#11-a-suggested-learning-path--exercises)

---

## 1. The big picture

This project is an **audio plugin** that simulates an Orange OR120 guitar
amplifier. A plugin is a shared library (`.dll` / `.clap` on Windows) that a
**host** program (a DAW like REAPER or Bitwig) loads at runtime. The host feeds
the plugin blocks of audio samples; the plugin transforms them and hands them
back.

Two "plugin formats" are supported:

- **CLAP** — a modern, open plugin standard. Our plugin _is_ a CLAP, written
  entirely in Zig.
- **VST3** — an older, more widespread standard. We don't write any VST3 code;
  instead a small open-source C++ shim (`clap-wrapper`) presents our CLAP to the
  host as a VST3 and forwards every call.

So the mental model is:

```
DAW (host)  ──audio + events──▶  our plugin  ──processed audio──▶  DAW
                                    │
                          ┌─────────┼──────────┐
                          ▼         ▼          ▼
                        CLAP      DSP        GUI (Clay + OpenGL)
                        glue     engine      knobs you can drag
```

Three big subsystems, three folders:

| Subsystem      | Where                                                                                  | Job                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **CLAP glue**  | [src/clap_plugin.zig](../src/clap_plugin.zig), [src/clap_abi.zig](../src/clap_abi.zig) | Speak the host's protocol: expose parameters, process audio, save/load state, host the GUI.              |
| **DSP engine** | [src/dsp/](../src/dsp/)                                                                | The actual amp: gain stages, tone controls, power-amp saturation, oversampling. Pure maths, no OS calls. |
| **GUI**        | [src/gui/](../src/gui/)                                                                | A window with draggable knobs, drawn with OpenGL and laid out with the Clay library.                     |

The **parameter store** ([src/params.zig](../src/params.zig)) sits in the middle:
it is the shared truth about knob values that all three subsystems read and write.

---

## 2. How the pieces fit together

A single stereo audio buffer makes this trip every few milliseconds:

1. The host calls `pluginProcess` ([src/clap_plugin.zig](../src/clap_plugin.zig)).
2. That function reads any incoming **parameter events** (the user automated a
   knob) and writes them into the `params.State` store.
3. It pushes the current parameter values into the DSP engine (`syncEngine`).
4. It calls `engine.processBlock(left, right)`, which runs every sample through
   the amp model.
5. Meanwhile, a **timer** on the GUI thread redraws the panel ~60×/second. When
   you drag a knob, the GUI writes the new value into the _same_ `params.State`
   and also queues an event so the host learns about the edit.

The tricky part — and a recurring theme in audio programming — is that steps 1–4
run on a **real-time audio thread** that must never block, while the GUI runs on
a **normal thread**. They share the parameter store. Section 7 explains how that
is made safe without locks.

---

## 3. Zig crash course (as used in this repo)

Zig is a small language: no hidden control flow, no garbage collector, no
exceptions. This section covers exactly the features the codebase uses, with
pointers to where each one appears.

### 3.1 Files are structs; `@import` and `pub`

Every `.zig` file is implicitly a `struct`. You pull one in with `@import`, and a
declaration is only visible to other files if marked `pub`:

```zig
const filters = @import("filters.zig");   // engine.zig line ~19
const Biquad = filters.Biquad;            // grab one public decl out of it
```

`pub fn`, `pub const` = part of the module's public API. Everything else is
file-private. See the tidy re-exports at the top of
[src/dsp/engine.zig](../src/dsp/engine.zig).

### 3.2 `const` vs `var`

- `const` — immutable binding (most things).
- `var` — mutable.

Zig forces you to use `const` unless you actually mutate. Unused locals are a
**compile error** — a deliberate nudge toward clean code.

### 3.3 Structs, default field values, and methods

Zig structs can give fields default values, which makes "zero-config"
construction easy:

```zig
pub const OnePole = struct {         // filters.zig
    a: f32 = 1.0,
    z: f32 = 0.0,

    pub fn setLowpass(self: *OnePole, cutoff_hz: f32, sample_rate: f32) void { ... }
    pub inline fn processLowpass(self: *OnePole, x: f32) f32 { ... }
};
```

- `var lp = OnePole{};` creates one with all defaults.
- Methods are just functions whose first parameter is the receiver. By
  convention it's called `self`. `*OnePole` means "pointer to a mutable
  `OnePole`" — needed because the method changes `self.z`.
- `OnePole{ .a = 0.5 }` is **struct literal** syntax; unnamed fields take their
  defaults.

You'll see `.{}` a lot: it's a struct literal whose type is _inferred_ from
context. `channels: [2]Channel = .{ .{}, .{} }` is an array of two
default-constructed `Channel`s.

### 3.4 `inline fn` and why it matters for audio

`inline fn` asks the compiler to paste the function body into the call site
instead of making a real call. In hot per-sample DSP loops that removes call
overhead and lets the optimiser fuse the maths. Almost every per-sample function
here is `inline` (`process`, `shape`, `triode`, …).

### 3.5 Optionals: `?T`, `orelse`, `if (x) |v|`

Zig has no `null` for ordinary pointers. Instead an **optional** type `?T` either
holds a `T` or is `null`. This makes "might be missing" explicit in the type.

```zig
gui: ?*guimod.Gui = null,          // Plugin may or may not have a GUI open

const ev = in_events orelse return; // if null, bail out of the function
if (self.gui) |g| g.destroy();      // if non-null, bind it to `g` and use it
```

- `orelse` provides a fallback (or `return`, `break`, etc.) when the optional is
  null.
- `if (opt) |unwrapped| { ... }` runs the block only when non-null, giving you
  the unwrapped value.

This pattern is everywhere in the CLAP glue, because host-supplied function
pointers can legitimately be absent:
`const size_fn = ev.size orelse return;`.

### 3.6 Error unions: `!T`, `try`, `catch`

A function that can fail returns `!T` (an _error union_). The caller must handle
it:

```zig
pub fn create(...) !*Gui {              // may fail (allocation)
    const self = try allocator.create(Gui); // `try` = propagate error upward
    ...
}
```

- `try expr` — if `expr` errored, return that error from the current function;
  otherwise unwrap the value.
- `catch` — handle the error inline. The CLAP callbacks can't propagate Zig
  errors across the C boundary, so they convert them to a boolean:
  `... catch return false;`.

### 3.7 Slices and arrays

- `[N]T` — a fixed-size array (size known at compile time), e.g. `[2]Channel`.
- `[]T` — a **slice**: a pointer + a length. This is Zig's safe "view into
  memory". `left: []f32` in `processBlock` is a slice of the host's audio buffer.
- `left[i]`, `left.len`, `left[0..n]` (sub-slice) all work as you'd expect and
  are bounds-checked in safe builds.

### 3.8 `comptime`: running code at compile time

Zig can execute ordinary Zig _during compilation_. The FIR filter coefficients
are computed once at compile time and baked into the binary:

```zig
const coeffs: [num_taps]f32 = blk: {   // oversample.zig
    @setEvalBranchQuota(200000);       // allow the comptime loop to run long
    var h: [num_taps]f32 = undefined;
    ... // full windowed-sinc design, executed by the compiler
    break :blk h;                      // the block "returns" h into coeffs
};
```

`blk: { ... break :blk value; }` is a **labelled block that yields a value** —
Zig's way of doing "compute something with statements, then use it as an
expression." Here it runs at comptime because it initialises a `const`.

`@setEvalBranchQuota` raises the compiler's loop-iteration budget so the design
loop is allowed to finish.

### 3.9 Builtins (`@...`)

Functions starting with `@` are compiler builtins. The ones you'll meet:

| Builtin                                      | Meaning                                                       |
| -------------------------------------------- | ------------------------------------------------------------- |
| `@import`                                    | pull in another file/module                                   |
| `@floatFromInt`, `@intFromFloat`             | numeric conversions (explicit — Zig never converts silently)  |
| `@floatCast`, `@intCast`, `@truncate`        | narrow/convert between sizes                                  |
| `@ptrCast`, `@alignCast`                     | reinterpret a pointer's type / assert alignment               |
| `@bitCast`                                   | reinterpret the raw bits as another type (e.g. `f64` ↔ `u64`) |
| `@intFromEnum`, `@enumFromInt`               | enum ↔ integer                                                |
| `@sizeOf`, `@memcpy`, `@abs`, `@min`, `@max` | as named                                                      |
| `@setEvalBranchQuota`                        | raise the comptime evaluation budget                          |

Zig is strict: you can't assign an `i32` to an `f32` without `@floatFromInt`.
This verbosity is intentional — every conversion is visible and auditable, which
matters a lot in low-level code.

### 3.10 `switch` is exhaustive

`switch` must cover every case (or have an `else`). Enums make this a superpower:
add a variant and the compiler shows you every switch that needs updating. See
`drainChanges` in [src/clap_plugin.zig](../src/clap_plugin.zig), which switches on
`change.kind`.

### 3.11 Testing lives next to the code

Zig has a built-in test runner. `test "name" { ... }` blocks are compiled only
when you run `zig build test`, so they cost nothing in the shipped binary. Every
DSP file ends with tests; `std.testing.expect(...)` asserts. This is idiomatic
Zig — colocated unit tests. (See the bottom of every file in `src/dsp/`.)

---

## 4. Low-level concepts you need

The CLAP layer is where Zig meets the raw C world. These are the concepts that
make it work.

### 4.1 What an "ABI" is

An **ABI** (Application Binary Interface) is the binary contract two compiled
modules agree on: how structs are laid out in memory, how function arguments are
passed, what a pointer looks like. The host was compiled separately (maybe by a
different compiler), so our plugin must match CLAP's ABI _exactly_ to
interoperate.

[src/clap_abi.zig](../src/clap_abi.zig) is a hand-written mirror of CLAP's C
structs. The doc comment explains _why_ it's hand-written: Zig's automatic C
translator chokes on CLAP's headers, and since the 1.x ABI is frozen, mirroring
the layouts by hand is safe and keeps the project 100% Zig.

### 4.2 `extern struct` — guaranteed C layout

A normal Zig `struct` may be reordered by the compiler for efficiency. An
`extern struct` is laid out in declared order with C rules, so it can be shared
with C code:

```zig
pub const clap_version = extern struct {  // clap_abi.zig
    major: u32,
    minor: u32,
    revision: u32,
};
```

Every type that crosses the host boundary is `extern struct`.

### 4.3 Calling conventions: `callconv(.c)` and `callconv(.winapi)`

When the host calls one of our functions, both sides must agree on how arguments
land in registers/stack. That agreement is the **calling convention**.

- `callconv(.c)` — the C calling convention. Every function the host invokes is
  marked this way, e.g. `fn pluginProcess(...) callconv(.c) ...`.
- `callconv(.winapi)` (aliased as `WINAPI` in [src/gui/gl.zig](../src/gui/gl.zig)
  and [src/gui/win32.zig](../src/gui/win32.zig)) — the Windows API convention,
  required for Win32 and OpenGL entry points.

Get this wrong and you get instant crashes, because the two sides disagree about
where the arguments are.

### 4.4 C pointer types: `[*c]`, `?*`, `*`, `anyopaque`

Zig distinguishes pointer flavours that C blurs together:

| Type          | Meaning                                                                                            |
| ------------- | -------------------------------------------------------------------------------------------------- |
| `*T`          | pointer to exactly one `T`, never null                                                             |
| `?*T`         | nullable pointer to one `T`                                                                        |
| `[*]T`        | pointer to many `T` (an array, unknown length)                                                     |
| `[*c]T`       | a **C pointer** — may be null, may be one or many; the "anything goes" type used at the C boundary |
| `?*anyopaque` | C's `void*` — a type-erased pointer                                                                |

You'll see `[*c]const c.clap.clap_plugin_t` all over the CLAP glue: that's how a
C `const clap_plugin_t *` maps into Zig.

### 4.5 Recovering `self` from a C callback

CLAP callbacks are plain C function pointers — they don't know about our `Plugin`
struct. The trick: we store a pointer to our data _inside_ the CLAP struct
(`plugin_data`), and every callback fishes it back out:

```zig
fn fromClap(plugin: [*c]const c.clap.clap_plugin_t) *Plugin {
    return @ptrCast(@alignCast(plugin.*.plugin_data));
}
```

- `plugin.*` dereferences the C pointer.
- `plugin_data` is a `?*anyopaque` (void\*) we set at creation time to point at
  our `Plugin`.
- `@ptrCast` reinterprets it as `*Plugin`; `@alignCast` asserts it's properly
  aligned. This is the standard "C gives you a void\* context pointer" pattern.

The GUI uses the same trick on Windows: it stashes `self` in the window's
`GWLP_USERDATA` and recovers it in `wndProc` ([src/gui/gui.zig](../src/gui/gui.zig)).

### 4.6 Manual memory management

There is no garbage collector. Memory is explicitly allocated and freed:

```zig
const self = allocator.create(Plugin) catch return null; // malloc a Plugin
...
allocator.destroy(self);                                  // free it
```

The plugin uses `std.heap.c_allocator` (C's `malloc`/`free`) because the host
already links libc. The GUI takes an `allocator` parameter so its lifetime is
controlled by whoever created it. **Ownership** — who is responsible for freeing
each allocation — is something you must track yourself; the `create`/`destroy`
pairs make it explicit.

### 4.7 The exported entry point

A host finds the plugin by looking up one exported symbol, `clap_entry`:

```zig
export const clap_entry = c.clap.clap_plugin_entry_t{ ... }; // clap_plugin.zig
```

`export` gives it C linkage with that exact name. From that single symbol the
host reaches the factory → the descriptor → `create_plugin` → your `Plugin`.
Everything cascades from there.

---

## 5. The build system (`build.zig`)

Zig projects are built by a Zig program: [build.zig](../build.zig). `zig build`
compiles and runs its `build` function, which _describes_ the build graph.

Key steps in our `build`:

1. **Create a module** for the plugin source, linking libc:

   ```zig
   const plugin_mod = b.createModule(.{
       .root_source_file = b.path("src/clap_plugin.zig"),
       .target = target, .optimize = optimize, .link_libc = true,
   });
   ```

   `target` and `optimize` come from `standardTargetOptions` /
   `standardOptimizeOption`, which read `-Dtarget=...` and `-Doptimize=...` from
   the command line (this is how you pick Debug vs ReleaseFast).

2. **Add the C dependencies** the GUI needs — the Clay library
   (`clay_impl.c`) and the Windows system libraries (`user32`, `gdi32`,
   `opengl32`, `kernel32`).

3. **Build a shared library** and install it renamed to `OR120AmpSim.clap`
   (a `.clap` is just a DLL with a different extension):

   ```zig
   const plugin = b.addLibrary(.{ .name = "OR120AmpSim", .root_module = plugin_mod, .linkage = .dynamic });
   ```

4. **Define the test step.** The DSP and params modules are compiled _separately_
   as test binaries and wired to a named step, so `zig build test` runs them:
   ```zig
   const test_step = b.step("test", "Run unit tests");
   test_step.dependOn(&run_dsp_tests.step);
   test_step.dependOn(&run_params_tests.step);
   ```

Note the tests build only the pure-DSP modules — they don't touch Win32/OpenGL,
so they run fast and cross-platform.

---

## 6. The CLAP plugin layer

File: [src/clap_plugin.zig](../src/clap_plugin.zig). This is the "translator"
between the host and our engine. CLAP is organised as a **core interface** plus
optional **extensions**, each of which is a struct of function pointers (a vtable).

### 6.1 The descriptor and factory

- `descriptor` — static metadata: id, name, vendor, and a null-terminated array
  of _feature_ strings (`audio-effect`, `distortion`, `stereo`). The host shows
  these in its browser.
- `plugin_factory` — three functions letting the host enumerate and instantiate
  plugins. `factoryCreatePlugin` allocates a `Plugin`, fills in its core vtable
  (`init`, `process`, `get_extension`, …), and returns a pointer to the embedded
  `clap_plugin_t`.

### 6.2 The `Plugin` struct

```zig
const Plugin = struct {
    clap_plugin: c.clap.clap_plugin_t, // the C-visible vtable (must be first-class)
    host: [*c]const c.clap.clap_host_t, // handle back to the host
    engine: dsp.Engine,                 // the amp
    params: params.State,               // shared parameter store
    changes: params.ChangeQueue = .{},  // GUI→host event queue
    gui: ?*guimod.Gui = null,           // optional open editor
};
```

Everything the plugin owns lives here. `fromClap` recovers it in every callback
(section 4.5).

### 6.3 `pluginProcess` — the real-time heart

```zig
self.applyInputEvents(process.*.in_events); // 1. absorb host param changes
self.syncEngine();                          // 2. copy params → engine coefficients
self.drainChanges(process.*.out_events);    // 3. emit GUI edits back to host
... copy inputs to outputs ...
self.engine.processBlock(l, r);             // 4. run the amp on the buffer
```

Things to notice, all of which are audio-programming rules:

- **No allocation, no locks, no file/OS calls** on this path. It must complete in
  bounded time or you get audible glitches ("xruns").
- Events carry a `time` (sample offset within the block). This simple version
  applies them at block granularity; a fancier one would split the block at each
  event.
- Buffers are **de-interleaved**: `data32[0]` is the whole left channel,
  `data32[1]` the right. That's why the engine works on two `[]f32` slices.
- Input and output buffers may be the _same_ memory (in-place processing), hence
  the `if (dst != src)` guard before `@memcpy`.

### 6.4 The params extension

`params_ext` exposes six callbacks. The interesting ones:

- `paramsGetInfo` — describes each parameter (id, name, min/max/default, flags)
  straight from `params.descriptors`.
- `value_to_text` / `text_to_value` — how the host formats a value for display
  and parses typed input. **These two must be exact inverses**, or CLAP
  validators fail. The F.A.C. control shows positions 1–6 to the user but stores
  0–5 internally, so `value_to_text` adds 1 and `text_to_value` subtracts 1:
  ```zig
  .fac => std.fmt.bufPrint(dst, "{d:.0}", .{@round(value) + 1}),   // display
  out_value.* = if (id == .fac) v - 1.0 else v;                    // parse back
  ```
  This "display offset must be inverted on parse" is a classic gotcha.

### 6.5 State save/load

`stateSave` / `stateLoad` serialise all parameter values to a byte stream so the
host can store them in a project file. The format is deliberately simple:

```
[u32 version][u32 count][count × f64 values]  // all little-endian
```

`@bitCast` turns each `f64` into a `u64` for byte-exact storage. On load, after
restoring values, `notifyParamsRescan()` tells the host "re-read everything" so
its automation lanes refresh. Writing/reading loops (`writeAll`/`readAll`) handle
partial writes — a stream may accept fewer bytes than asked, so you loop until
done. That defensive loop is standard for any stream I/O.

### 6.6 The GUI extension

`gui_ext` is a big vtable, but most of it is boilerplate returning fixed sizes
(the window is non-resizable, `720×300`). The important calls:

- `guiCreate` — constructs a `Gui`, handing it a `Bridge` (the shared param
  store, the change queue, and the flush callback).
- `guiSetParent` — the host passes a native window handle; we create our child
  window inside it.
- `guiDestroy` — tears the GUI down and nulls the pointer.

The comment blocks around `guiCreate`/`destroy` in
[src/gui/gui.zig](../src/gui/gui.zig) record two real crash bugs and their fixes
(Clay arena sizing and a dangling global context pointer) — worth reading as
cautionary tales about manual resource management.

---

## 7. Parameters, atomics, and the lock-free queue

File: [src/params.zig](../src/params.zig). This is the shared state between the
audio thread and the GUI thread, and it's where **concurrency** shows up.

### 7.1 The parameter table

An `enum` gives each parameter a stable numeric id; a parallel array of
`Descriptor`s holds the metadata:

```zig
pub const ParamId = enum(u32) { gain = 0, bass = 1, ..., bypass = 7 };
pub const count = 8;

pub const descriptors = [count]Descriptor{
    .{ .id = .gain, .name = "Gain", .min = 0, .max = 10, .default = 5, .flags = automatable },
    ...
    .{ .id = .fac, .name = "F.A.C.", .min = 0, .max = 5, .default = 2,
       .flags = automatable | c.clap.CLAP_PARAM_IS_STEPPED },
    ...
};
```

Using `enum(u32)` means the id _is_ the array index (`@intFromEnum(id)`), so
lookups are O(1) and the host's integer ids map straight through. `flags` is a
bitfield combined with `|`; `CLAP_PARAM_IS_STEPPED` makes F.A.C. a detented
6-position switch instead of a continuous knob.

### 7.2 Atomics: sharing a value between threads safely

Both threads read and write parameter values. If they did so with a plain `f64`,
you could get a **torn read** (half-old, half-new bits) or the compiler could
cache the value in a register and never see the other thread's update. The fix is
`std.atomic.Value(f64)`:

```zig
pub const State = struct {
    values: [count]std.atomic.Value(f64),

    pub fn get(self: *const State, id: ParamId) f64 {
        return self.values[@intFromEnum(id)].load(.monotonic);
    }
};
```

`load`/`store` with `.monotonic` ordering guarantee each value is read/written as
one indivisible unit. `.monotonic` is the weakest (cheapest) ordering — fine here
because each parameter is independent and we don't need them ordered relative to
each other.

### 7.3 The lock-free SPSC ring buffer

When you drag a knob, the GUI must tell the host. But the GUI can't call into the
host directly on its own thread; the edit has to be delivered during `process` or
`flush`. So the GUI **produces** change events and the audio/main thread
**consumes** them. A mutex would risk blocking the audio thread, so instead we
use a lock-free **single-producer / single-consumer (SPSC) ring buffer**:

```zig
pub const ChangeQueue = struct {
    const capacity = 256;
    buf: [capacity]Change = undefined,
    head: std.atomic.Value(usize) = ...init(0), // consumer advances this
    tail: std.atomic.Value(usize) = ...init(0), // producer advances this

    pub fn push(self: *ChangeQueue, change: Change) void {
        const tail = self.tail.load(.monotonic);
        const next = (tail + 1) % capacity;
        if (next == self.head.load(.acquire)) return; // full → drop
        self.buf[tail] = change;
        self.tail.store(next, .release);   // publish AFTER writing the slot
    }

    pub fn pop(self: *ChangeQueue) ?Change { ... }
};
```

Why this is correct:

- Only the GUI writes `tail`; only the consumer writes `head`. Neither writes the
  other's index, so no lock is needed.
- The **release/acquire** pairing is the crucial bit. The producer writes the
  slot data, _then_ does a `.release` store to `tail`. The consumer does an
  `.acquire` load of `tail` _before_ reading the slot. Release-before-acquire
  guarantees the consumer sees the slot data once it sees the new `tail`. This is
  the standard memory-ordering handshake for a lock-free queue.
- If full, it drops the event rather than blocking — the right trade-off for
  real-time audio.

This is a genuinely advanced topic; if the memory-ordering part is fuzzy, that's
normal. The takeaway: **audio threads never lock, so cross-thread messaging uses
lock-free queues with acquire/release ordering.**

---

## 8. DSP theory and the audio engine

Now the fun part: turning "an Orange amp" into arithmetic. Folder:
[src/dsp/](../src/dsp/). We build from the smallest pieces up to the full chain.

### 8.1 First, the mental model of digital audio

Audio is a stream of numbers ("samples"), one per channel per time-step, at a
**sample rate** (e.g. 48000 samples/second). Each sample is a `f32` roughly in
`[-1, 1]`. "Processing audio" means computing each output sample from the input
samples. A filter or amp stage is a little function with **memory** (state) that
runs once per sample.

The highest frequency representable is **Nyquist** = sample_rate / 2. Anything
above it can't exist digitally — and if a process _tries_ to create it, it folds
back down as false low frequencies. That folding is **aliasing**, and it's the
enemy of distortion effects (section 8.5).

### 8.2 Filters — `filters.zig`

File: [src/dsp/filters.zig](../src/dsp/filters.zig).

**One-pole filter.** The simplest useful filter — a running weighted average:

```zig
y[n] = y[n-1] + a * (x[n] - y[n-1]);
```

`a` between 0 and 1 sets how fast it tracks the input. Small `a` = slow = low-pass
(smooths out fast changes). We compute `a` from a cutoff frequency:
`a = 1 - exp(-2π·fc/fs)`. A **high-pass** is just "input minus the low-passed
part" (`processHighpass`) — what passes through is the fast wiggle the low-pass
removed. The F.A.C. control uses this to cut bass.

**Biquad filter.** A second-order filter — two poles, two zeros — flexible enough
to make shelves and bells. It implements:

```zig
y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2];
```

but stored in **transposed direct-form II**, which only needs two state variables
(`z1`, `z2`) and has good numerical behaviour:

```zig
pub inline fn process(self: *Biquad, x: f32) f32 {
    const y = self.b0 * x + self.z1;
    self.z1 = flushDenormal(self.b1 * x - self.a1 * y + self.z2);
    self.z2 = flushDenormal(self.b2 * x - self.a2 * y);
    return y;
}
```

The five coefficients (`b0,b1,b2,a1,a2`) define the filter's _shape_. Computing
them from "I want +6 dB shelf at 1.6 kHz" is done by the **RBJ cookbook**
formulas — an industry-standard set of equations (Robert Bristow-Johnson's). See
`setLowShelf`, `setHighShelf`, `setPeaking`. You don't need to memorise the
algebra; recognise that these functions _design_ a filter to a spec. Coefficients
are computed in `f64` for precision, then stored as `f32`.

The tone stack uses two shelves: bass (low-shelf @ 300 Hz) and treble (high-shelf
@ 1.6 kHz), each ±14 dB — a "Baxandall" style tone control.

**Denormals.** `flushDenormal` guards against _subnormal_ floats — tiny values
(< 1e-25) that appear when a filter fed silence decays toward zero. On many CPUs,
arithmetic on subnormals is 10–100× slower, and they leave tiny nonzero noise in
the output. Flushing them to zero fixes both. Wrapping every feedback state in
`flushDenormal` is a standard audio-DSP hygiene trick.

### 8.3 Waveshapers — `waveshaper.zig`

File: [src/dsp/waveshaper.zig](../src/dsp/waveshaper.zig). This is where the
"tube" sound comes from. A **waveshaper** is a memoryless nonlinear function
`y = f(x)`: it bends the signal, and bending a waveform _creates harmonics_ —
that's distortion.

**Triode (preamp tube):**

```zig
pub inline fn triode(x: f32, drive: f32, bias: f32) f32 {
    const v = x * drive + bias;
    return std.math.tanh(v) - std.math.tanh(bias);
}
```

- `tanh` is an S-curve: near zero it's ~linear (clean); as `|x|` grows it
  flattens toward ±1 (soft clipping). That soft knee is why tanh models tubes
  well.
- `drive` pushes the signal further up the curve → more clipping → more grit.
- `bias` shifts the operating point so positive and negative swings clip
  _differently_. Asymmetry produces **even harmonics** (the "warm" ones). The
  `- tanh(bias)` term removes the DC offset the bias would otherwise add, keeping
  the signal centred.

**Push-pull power section (EL34 output tubes):**

```zig
pub inline fn pushPull(x: f32, bias: f32) f32 {
    return 0.5 * (std.math.tanh(x + bias) + std.math.tanh(x - bias));
}
```

A real power amp uses two tubes in opposition. Summing two symmetric curves gives
an **odd** function (f(-x) = -f(x)), so even harmonics cancel and **odd** ones
dominate — the "chewy" power-amp crunch. `bias` sets the class-AB operating
point: near 0 the two knees merge (smooth, class-A-like); larger values pull them
apart and open a low-gain **crossover** region between them (colder bias, more
crossover grit).

Each shaper has a matching **derivative** (`pushPullDeriv`, `powerAmpDeriv`). Why
you need the derivative is the negative-feedback trick in section 8.6.

### 8.4 A note on odd vs even harmonics

- **Even harmonics** (2nd, 4th, …) sound "musical/warm" — added by _asymmetric_
  shaping (biased triode).
- **Odd harmonics** (3rd, 5th, …) sound "aggressive/compressed" — added by
  _symmetric_ shaping (push-pull pair).

The amp deliberately uses asymmetric preamp stages and a symmetric power stage,
mirroring the real circuit's harmonic signature.

### 8.5 Oversampling — `oversample.zig`

File: [src/dsp/oversample.zig](../src/dsp/oversample.zig). This solves the
aliasing problem from 8.1.

When you run a signal through `tanh`, you create harmonics at 2×, 3×, 4×… the
input frequency. If any land above Nyquist, they alias back as inharmonic junk.
The fix: temporarily run the nonlinearity at a **higher sample rate** so those
harmonics fit, filter off the part above the original Nyquist, then come back
down.

The 2× oversampler does exactly that per sample:

```zig
pub inline fn process(self, x, ctx, comptime shape) f32 {
    const up0 = self.up.process(x * 2.0); // zero-stuff + low-pass = upsample
    const up1 = self.up.process(0.0);
    const s0 = shape(ctx, up0);           // run the nonlinearity at 2× rate
    const s1 = shape(ctx, up1);
    _ = self.down.process(s0);            // low-pass again…
    return self.down.process(s1);         // …and decimate back to 1× rate
}
```

- **Upsampling** = insert a zero between each sample (doubling the rate) then
  low-pass to fill it in smoothly. The `× 2.0` compensates for the energy lost to
  the inserted zeros.
- The `shape` callback is the nonlinearity to evaluate. Passing it as
  `comptime shape: fn(...)` means the compiler _inlines the specific shaper_ into
  the oversampler — zero indirection cost. That's a neat Zig trick: generic over
  a function, resolved at compile time.
- **Downsampling** = low-pass (to kill everything above the original Nyquist)
  then throw away every other sample.

The low-pass used for both directions is a **31-tap FIR** filter whose
coefficients are a **windowed sinc** computed at comptime (section 3.8). A sinc is
the ideal "brick-wall" low-pass; windowing it (Hamming) makes it finite and
well-behaved. The `Fir.process` function is a textbook FIR: a circular buffer of
recent samples dotted with the coefficients.

The two tests at the bottom verify the two things that matter: a low tone passes
through at unity gain, and a near-Nyquist tone is strongly attenuated.

### 8.6 The amp engine — `engine.zig`

File: [src/dsp/engine.zig](../src/dsp/engine.zig). This assembles the pieces into
the OR120 signal path. Read the doc comment at the top — it's the block diagram.

**Per-channel chain** (`Channel.process`), in order:

1. **V1A** — first 12AX7 gain stage: `triode` inside a 2× oversampler.
2. **Tone stack** — bass + treble biquad shelves.
3. **F.A.C.** — the one-pole high-pass low-cut (6 stepped cutoffs).
4. **HF Drive** — a bright high-shelf feeding **V1B**, the second oversampled
   triode stage.
5. **Phase inverter** — modelled as a clean unity pass (no code, just a comment).
6. **Power stage** — the EL34 push-pull with negative feedback + supply sag,
   oversampled.
7. **DC blocker** — removes any DC offset the asymmetric shaping introduced.
8. **Output gain**.

**Supply sag.** Real amps' power supplies sag under load, softening transients.
Modelled with an envelope follower:

```zig
const demand = @abs(s);
const coef = if (demand > self.sag_env) eng.sag_atk else eng.sag_rel;
self.sag_env = flushDenormal(self.sag_env + coef * (demand - self.sag_env));
self.power_state.supply = 1.0 - eng.sag_depth * @min(self.sag_env, 1.0);
```

The envelope rises fast (`sag_atk`) and falls slowly (`sag_rel`) — a one-pole
smoother again — and dips the "supply voltage" fed to the power stage. Louder
playing → more sag → more compression and bloom.

**Negative feedback solved without delay (the clever bit).** A real power amp
wraps a **negative-feedback** loop around the output tubes: the output is fed back
and subtracted from the input. In equations the output `y` depends on itself:

```
y = f( drive · supply · (x - nfb · y) )
```

Naively you'd break the loop with a one-sample delay, but that colours the sound.
Instead `PowerStage.shape` **solves the equation each sample** with a few
**Newton–Raphson** iterations:

```zig
while (it < 4) : (it += 1) {
    const u = g * (x - self.nfb * y);
    const f  = waveshaper.pushPull(u, self.bias);
    const df = waveshaper.pushPullDeriv(u, self.bias); // ← why we need derivatives
    const fval  = y - f;                 // we want y - f(...) = 0
    const dfval = 1.0 + df * g * self.nfb; // its derivative w.r.t. y
    y -= fval / dfval;                    // Newton step
}
```

Newton's method finds the root of `g(y) = y - f(...) = 0` by repeatedly stepping
`y ← y - g(y)/g'(y)`. It converges in ~4 steps here. The previous sample's answer
(`y1`) is reused as the starting guess ("warm start"), which makes convergence
even faster. This is a lovely example of applying first-year calculus to make
audio sound right.

**`setControls` — mapping knobs to coefficients.** The knobs are 0–10 dials; the
engine needs gains and cutoff frequencies. `setControls` does that translation,
mostly with exponential curves so the knobs feel natural (our ears are
logarithmic):

```zig
self.pre_drive  = 0.55 * std.math.pow(f32, 10.0, (controls.gain / 10.0) * 1.3);
self.out_gain   = 0.7  * std.math.pow(f32, 10.0, controls.output_db / 20.0); // dB → linear
```

`10^(dB/20)` is the standard decibels-to-linear-amplitude conversion. The F.A.C.
switch indexes a table of six cutoff frequencies:

```zig
const fac_cutoffs = [_]f32{ 25, 55, 100, 180, 340, 600 };
const step: usize = @intFromFloat(@round(std.math.clamp(controls.fac, 0.0, 5.0)));
const fac_hz = fac_cutoffs[step];
```

Note the `@round` + `clamp` + `@intFromFloat` dance: `@intFromFloat` requires an
in-range, integral float, so you clamp and round _before_ converting or the build
traps. That ordering is a Zig gotcha worth remembering.

**Stereo.** Two independent `Channel`s share the same coefficients (written once
in `setControls`) but keep separate state — so the left and right filter
histories don't bleed into each other.

**The tests** at the bottom encode the invariants that must always hold: bypass
leaves the buffer untouched; heavy drive stays finite and bounded (`< 8.0`); a
small signal produces nonzero output; the DC blocker actually removes DC. These
are your safety net when you tweak the maths.

---

## 9. The GUI layer

Folder: [src/gui/](../src/gui/). The GUI is a native child window with a legacy
OpenGL context. Layout is done by the **Clay** library; drawing is done by our own
OpenGL code. There is no UI framework doing the heavy lifting — it's all here.

### 9.1 Windowing — `win32.zig` + `gui.zig`

[src/gui/win32.zig](../src/gui/win32.zig) declares the handful of Win32 functions
we call (`CreateWindowExW`, `GetDC`, timers, mouse capture, …) as `extern`
declarations with `callconv(.winapi)`. This is raw OS programming — no wrapper
crate.

[src/gui/gui.zig](../src/gui/gui.zig) drives it:

- `setParent` creates a `WS_CHILD` window inside the host's window and starts a
  16 ms **timer** (`SetTimer`) — that's the ~60 fps redraw clock.
- `initGl` sets up an OpenGL 1.1 rendering context the old-fashioned way: choose a
  pixel format, create a `wglCreateContext`, make it current.
- `wndProc` is the **window procedure** — Windows calls it for every event
  (`WM_TIMER` → redraw, `WM_LBUTTONDOWN`/`MOUSEMOVE`/`LBUTTONUP` → knob drag). It
  recovers `self` from `GWLP_USERDATA` (section 4.5) and dispatches with a
  `switch`.

### 9.2 Knob interaction

A knob drag is pure arithmetic over the shared param store:

```zig
fn updateDrag(self: *Gui, y: f32) void {
    const d = params.descriptors[index];
    const delta = (self.drag_start_y - y) / drag_full_range_px; // 220 px = full sweep
    const norm = std.math.clamp(self.drag_start_norm + delta, 0.0, 1.0);
    var raw: f64 = d.min + norm * (d.max - d.min);
    if ((d.flags & CLAP_PARAM_IS_STEPPED) != 0) raw = @round(raw); // detent F.A.C./Bypass
    self.bridge.state.setRaw(index, raw);          // update shared state
    self.bridge.queue.push(.{ .id = ..., .kind = .value, .value = raw }); // tell host
    self.bridge.requestFlush();
}
```

Dragging up increases the value; the distance is normalised so 220 px sweeps the
whole range. Stepped params snap with `@round`. Every edit goes into the
`ChangeQueue` (section 7.3) and asks the host to flush, closing the automation
loop. `beginDrag`/`endDrag` bracket the gesture with `gesture_begin`/`gesture_end`
events so the host records it as one movement.

### 9.3 Clay layout — `clay.zig` + `panel.zig`

**Clay** is an immediate-mode layout library: every frame you _declare_ the UI
tree, and Clay computes bounding boxes. It's a C single-header library. Because
its normal API is macro-based (and macros don't survive Zig's C importer),
[src/gui/clay.zig](../src/gui/clay.zig) calls Clay's internal
open/configure/close functions directly and wraps them in tidy helpers
(`open`/`close`/`box`/`text`, `sizingFixed`, `sizingGrow`).

[src/gui/panel.zig](../src/gui/panel.zig) builds the panel each frame in `build()`:
a root (orange tolex + border) → a header ("ORANGE OR120") → a black control strip
→ one column per parameter. Each knob column is just an **invisible** 64×64
box that carries a stable id:

```zig
open(std.mem.zeroInit(clay.ElementDeclaration, .{
    .id = knobId(index),
    .layout = .{ .sizing = .{ .width = clay.sizingFixed(64), .height = clay.sizingFixed(64) } },
    .backgroundColor = theme.transparent,
}));
```

Why invisible? Because the _visible_ knob is drawn separately by our own OpenGL
overlay (9.5). Clay's only job for a knob is to reserve space and provide a
bounding box for hit-testing. After layout, `gui.zig` reads each box back with
`Clay_GetElementData(panel.knobId(i))`.

`std.mem.zeroInit(T, .{ ... })` is a handy Zig idiom: zero-initialise a big C
struct and then set just the fields you care about — avoids listing dozens of
zero fields.

### 9.4 Turning layout into pixels — `renderer.zig` + `font.zig`

[src/gui/renderer.zig](../src/gui/renderer.zig) walks Clay's output
(`RenderCommandArray`) and issues OpenGL calls: rectangles, rounded rectangles
(triangle fans + arc vertices), borders (stroked outlines or four edge rects),
scissor clipping, and text.

- It sets a **top-left-origin orthographic projection** (`glOrtho(0, w, h, 0,…)`)
  so Clay's screen coordinates map straight to pixels. (OpenGL is normally
  bottom-left origin; the flipped ortho fixes that, and the scissor rect is
  flipped back with `fb_height - y - h`.)
- Everything is **immediate-mode** OpenGL 1.1 (`glBegin/glVertex2f/glEnd`) — the
  simplest possible drawing, no shaders, no buffers. Perfect for learning how
  rasterised UI works underneath modern frameworks.

[src/gui/font.zig](../src/gui/font.zig) is a **vector stroke font**: each letter
is a list of polylines on a unit cell, drawn with `GL_LINE_STRIP`. No font file,
no glyph atlas — the labels are literally little line drawings. `measure` returns
a glyph's size so Clay can lay text out.

### 9.5 The procedural knob overlay — `decor.zig` + `theme.zig`

[src/gui/decor.zig](../src/gui/decor.zig) draws everything that needs to look
"real," entirely procedurally (no images):

- **Background**: fills the tolex colour, overlays a woven diagonal cross-hatch,
  a soft **vignette** (a centre-transparent triangle fan darkening the edges), and
  four **corner screws**.
- **Knobs** (`drawKnob`): a drop shadow, a **spherically-shaded** body
  (`discShaded` fakes a 3-D sphere by brightening the rim toward an upper-left
  light direction), a raised cap, a specular glint, a silkscreen **tick ring**,
  and a cream **pointer** rotated to the current value.

The shading maths is worth a look: for each rim vertex it computes
`dot(normal, lightDir)` and lerps the colour between a dark "rim" and a light
"lit" colour. That dot-product-with-a-light-direction is the essence of all
diffuse lighting.

The overlay is drawn in `gui.zig`'s `renderFrame` **after** Clay's render pass,
reusing the projection the renderer left set, looping over the cached knob boxes:

```zig
for (0..params.count) |i| {
    const b = self.knob_boxes[i];
    const cx = b.x + b.width * 0.5;
    const cy = b.y + b.height * 0.5;
    const r  = @min(b.width, b.height) * 0.5 - 2.0;
    decor.drawKnob(cx, cy, r, values[i], panel.tickCount(i));
}
```

[src/gui/theme.zig](../src/gui/theme.zig) is just the colour palette (0–255 RGBA
to match Clay), including the amp's signature orange.

### 9.6 The full frame, start to finish

`renderFrame` in [src/gui/gui.zig](../src/gui/gui.zig) ties it together each timer
tick:

1. Make the GL context current; tell Clay the layout size and pointer state.
2. Read all parameter values into a local `values` array (normalised 0–1).
3. `panel.build()` declares the tree; `Clay_EndLayout()` computes it.
4. Cache each knob's bounding box.
5. Clear the framebuffer → `decor.drawTolexBackground` → `renderer.render`
   (Clay's rects/text) → the `decor.drawKnob` overlay.
6. `SwapBuffers` presents the frame.

---

## 10. Glossary

| Term                     | Meaning                                                                     |
| ------------------------ | --------------------------------------------------------------------------- |
| **Sample / sample rate** | One audio value; how many per second (e.g. 48 kHz).                         |
| **Nyquist**              | Highest representable frequency = sample_rate / 2.                          |
| **Aliasing**             | Frequencies above Nyquist folding back as false tones.                      |
| **Buffer / block**       | A chunk of consecutive samples processed together.                          |
| **De-interleaved**       | Each channel stored in its own contiguous array.                            |
| **Filter**               | A stage that shapes frequency content (has memory/state).                   |
| **Biquad**               | A 2-pole/2-zero filter; building block for EQ.                              |
| **Coefficients**         | The numbers defining a filter's response.                                   |
| **Waveshaper**           | Memoryless nonlinearity `y=f(x)` that adds harmonics.                       |
| **Harmonics**            | Integer multiples of a frequency created by nonlinearity.                   |
| **Oversampling**         | Temporarily raising the rate to avoid aliasing in nonlinear stages.         |
| **FIR / windowed sinc**  | A tap-based linear-phase filter; ideal low-pass, windowed to finite length. |
| **Denormal**             | A tiny subnormal float that's slow on CPUs; flushed to 0.                   |
| **NFB**                  | Negative feedback: output subtracted from input around the power amp.       |
| **Newton's method**      | Iterative root-finder used to solve the feedback equation per sample.       |
| **Sag**                  | Power-supply voltage dropping under load, causing compression.              |
| **ABI**                  | Binary contract (layout, calling convention) between compiled modules.      |
| **Calling convention**   | How arguments/return values are passed at the machine level.                |
| **Atomic**               | A value that can be read/written indivisibly across threads.                |
| **SPSC ring buffer**     | Single-producer/single-consumer lock-free FIFO queue.                       |
| **Acquire/release**      | Memory-ordering pair that makes lock-free hand-offs correct.                |
| **Immediate-mode**       | Rebuild-the-UI-every-frame style (Clay, legacy OpenGL).                     |
| **CLAP / VST3**          | Audio-plugin standards; VST3 here is a wrapper over the CLAP.               |

---

## 11. A suggested learning path / exercises

Work through these in order; each is small and gives fast feedback via
`zig build test`.

1. **Read + run the tests.** `zig build test`. Open
   [src/dsp/filters.zig](../src/dsp/filters.zig) and read each test — they're the
   clearest spec of what the code does.
2. **Add a parameter.** Add a "Master" knob: extend `ParamId` and `descriptors`
   in [src/params.zig](../src/params.zig), map it in `syncEngine`
   ([src/clap_plugin.zig](../src/clap_plugin.zig)) and `setControls`
   ([src/dsp/engine.zig](../src/dsp/engine.zig)). Watch how the GUI and host pick
   it up automatically (the panel iterates `descriptors`). This teaches how the
   layers connect.
3. **Change a filter.** Move the treble shelf frequency, or add a mid **peaking**
   filter using the existing `setPeaking`. Write a test with `biquadMagnitude` to
   prove it does what you intend.
4. **Feel the oversampler.** Temporarily bypass the oversampling (call the shaper
   directly instead of through `Oversampler2x`) and A/B the sound with heavy
   drive — you'll hear aliasing appear.
5. **Play with the power stage.** Change `power_bias`, `nfb`, or `sag_depth` in
   the `Engine` defaults and listen. Then read `PowerStage.shape` again — the
   Newton loop will make more sense once you've heard what it controls.
6. **Draw something.** Add a small detail in
   [src/gui/decor.zig](../src/gui/decor.zig) (e.g. a logo dot). This is a safe
   sandbox for OpenGL immediate-mode drawing.

If you get stuck on Zig syntax, section 3 is your reference; for a DSP concept,
section 8; for the C/host boundary, sections 4 and 6.
