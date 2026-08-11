# OR120-Amp-Sim

An **Orange OR120** guitar-amplifier simulation, written from scratch in
[Zig](https://ziglang.org/) with a [Clay](https://github.com/nicbarker/clay)
immediate-mode UI. It models the full signal path of the classic OR120 "Graphic"
head — cascaded 12AX7 preamp stages, the passive tone stack, the F.A.C.
(Frequency Analysing Circuit) voicing switch, an EL34 class-AB push-pull power
section with power-supply sag, and a global negative-feedback loop.

The plugin ships in two formats:

- **CLAP** — native, 100 % pure Zig (DSP, GUI, and the CLAP ABI are all hand-written Zig).
- **VST3** — a thin [clap-wrapper](https://github.com/free-audio/clap-wrapper)
  bridge around the _same_ CLAP binary. The wrapper is the only C++ in the
  project; at load time it locates the same-named `OR120AmpSim.clap` and forwards
  the VST3 protocol to it at runtime.

---

## What it models

The amp is simulated per-channel as a chain of analog-inspired stages. Signal
flows top to bottom:

| Stage              | Emulation                                                                              |
| ------------------ | -------------------------------------------------------------------------------------- |
| **V1A preamp**     | 12AX7 triode wave-shaping (`tanh`-based), 2× oversampled                               |
| **Tone stack**     | **James network** (passive Baxandall) solved as the real circuit — see below            |
| **F.A.C.**         | 6-position stepped high-pass "voicing" filter (25 / 55 / 100 / 180 / 340 / 600 Hz)     |
| **HF Drive**       | Bright high-shelf (~1.5 kHz) feeding a second 12AX7 (V1B) triode stage, 2× oversampled |
| **Phase inverter** | Cathodyne (unity-gain) splitter                                                        |
| **EL34 power amp** | Class-AB push-pull wave-shaper with adjustable bias/crossover, 2× oversampled          |
| **Power supply**   | Dynamic sag envelope that dips the rail under load                                     |
| **Global NFB**     | Negative-feedback loop solved per-sample (Newton iteration)                            |
| **Output**         | DC blocker + output trim                                                               |

### The tone stack

The OR120 does **not** use a Fender/Marshall-style ("FMV") stack. It uses a
**James network** — the passive Baxandall — which is why its Bass and Treble
controls are largely independent and why the response can be set genuinely flat,
neither of which an FMV stack can do.

Rather than approximate it with shelving filters, `src/dsp/tonestack.zig` solves
the actual circuit. Each capacitor is replaced by its trapezoidal companion model
(a conductance in parallel with a current source carrying the branch history),
which reduces the network to a resistive one; the 6×6 conductance matrix is
inverted once whenever a knob moves, leaving the audio path a matrix-vector
product and four state updates.

Because it *is* the network, the control interaction, the frequency-dependent
insertion loss and the asymmetry between boost and cut all emerge on their own
instead of having to be dialled in. Notably:

- The stack is **passive, so it always attenuates** — roughly −13 dB through the
  midband, bottoming out at `R3/(R1+R3)` = −14.9 dB. `midband_makeup` stands in
  for V1B's recovery gain in the real amp.
- **Full treble cut keeps falling** (≈ −50 dB at 12 kHz) rather than levelling
  onto a shelf.
- With **both controls at zero** the surviving peak sits at ~130–200 Hz — a
  thick low-mid honk, not a mid-forward one.

Component values are the '72/'74 Graphic MkII set (R1 100k, R2 1M bass pot,
R3 22k, R4 100k, R6 1M treble pot; C1 2200p, C2 22n, C3 1500p, C4 10n). The
implementation is verified against an independent complex nodal analysis of the
same netlist: it tracks the analog response to within **0.5 dB below 6 kHz**,
with the only larger deviation (−2.1 dB at 12 kHz, treble fully cut) being
ordinary bilinear frequency warping in a region already 50 dB down.

### Parameters

| Knob         | Range         | Default | Notes                               |
| ------------ | ------------- | ------- | ----------------------------------- |
| **Gain**     | 0–10          | 5       | Preamp drive                        |
| **Bass**     | 0–10          | 5       | Tone stack low-shelf                |
| **Treble**   | 0–10          | 5       | Tone stack high-shelf               |
| **HF Drive** | 0–10          | 5       | Bright boost into V1B               |
| **F.A.C.**   | 1–6 (stepped) | 3       | Frequency Analysing Circuit voicing |
| **Volume**   | 0–10          | 5       | Power-amp drive                     |
| **Output**   | −24…+24 dB    | 0       | Final level trim                    |
| **Bypass**   | on/off        | off     | Host-recognised bypass              |

All parameters are automatable. Values are held in a thread-safe atomic store and
handed to the audio thread through a lock-free change queue, so the GUI never
blocks or races the DSP.

### User interface

Clay lays out the panel; a small OpenGL (1.1, fixed-function) overlay draws the
tolex-covered chassis and the knobs. Knobs are click-and-drag; the F.A.C. control
detents to its six positions.

The tolex swatch and the knob bodies come from **baked raster assets** in
`assets/`, generated offline by `tools/bake_assets` (see
[Baked GUI assets](#baked-gui-assets)). Baking buys per-pixel lighting,
supersampled edges, anisotropic brushing and ambient occlusion — none of which
fixed-function GL can produce live. The vignette, corner screws and the knob tick
rings are still drawn procedurally, and every textured path keeps its original
procedural drawing as a fallback if a texture fails to load.

The assets are embedded into the binary with `@embedFile`, so the `.clap` ships
as a single self-contained file with no external asset directory to go missing.

---

## Prerequisites

- **Zig** 0.16.0 (dev) — builds the CLAP, GUI, DSP, and the asset baker.
- **git** — fetches the vendored dependencies.
- **PowerShell** (`pwsh`, or Windows PowerShell) — runs the two helper scripts.
- For the VST3 target only: **CMake** 3.21+ and a **C++17 toolchain** (MSVC on
  Windows).

Vendored automatically by `scripts/vendor.ps1`: the CLAP headers, Clay,
`stb_image` / `stb_image_write`, and clap-wrapper.

> The project currently targets **Windows** (Win32 + OpenGL windowing). The DSP
> and CLAP core are portable; only the GUI windowing layer is platform-specific.

---

## Installation guide

### 1. Clone

```powershell
git clone <repo-url> OR120-Amp-Sim
cd OR120-Amp-Sim
```

### 2. Fetch vendored dependencies

This pulls the third-party sources into `vendor/` (CLAP headers, Clay, the stb
image codecs, and — for the VST3 build — clap-wrapper). `vendor/` is git-ignored,
so this step is required after a fresh clone.

```powershell
.\scripts\vendor.ps1
```

> From a non-PowerShell shell, use `powershell -File scripts\vendor.ps1` (or
> `pwsh -File …` if you have PowerShell 7 installed).

### 3. Build the CLAP

```powershell
# Build the CLAP plugin (Debug by default)
zig build

# Optimized build for actual use
zig build -Doptimize=ReleaseFast

# (optional) run the unit-test suite
zig build test
```

Output: **`zig-out/clap/OR120AmpSim.clap`**

> The build embeds `assets/knob.png` and `assets/tolex.png`, which are committed
> to the repo — no bake step is needed for a normal build. If you delete or
> change them, regenerate with `zig build assets`.

### 4. Build the VST3 (optional)

```powershell
.\scripts\build-vst3.ps1
```

This first builds the CLAP, then configures and builds clap-wrapper. The **first**
CMake configure downloads the CLAP and VST3 SDKs, so it needs network access and
takes a few minutes. See [VST3](#vst3) for the build-configuration options.

Output: **`zig-out/vst3/OR120AmpSim.vst3`**

Because the VST3 is a thin wrapper that forwards to the CLAP at runtime, you must
**install both files together** for the VST3 to work.

### 5. Install (Windows)

| File               | Destination                                                              |
| ------------------ | ------------------------------------------------------------------------ |
| `OR120AmpSim.clap` | `%CommonProgramFiles%\CLAP\` (or `%LOCALAPPDATA%\Programs\Common\CLAP\`) |
| `OR120AmpSim.vst3` | `%CommonProgramFiles%\VST3\`                                             |

```powershell
Copy-Item zig-out\clap\OR120AmpSim.clap "$env:CommonProgramFiles\CLAP\" -Force
Copy-Item -Recurse zig-out\vst3\OR120AmpSim.vst3 "$env:CommonProgramFiles\VST3\" -Force
```

> **Note:** if the plugin is already loaded in a running DAW, the file is locked
> and the copy will fail with _"being used by another process."_ Close the DAW
> first, then re-run the copy.

### 6. Run

Rescan plugins in your DAW (REAPER, Bitwig, etc.), then insert **OR120AmpSim** on
a guitar track. For a full rig, feed it a cabinet impulse response or amp-cab
capture downstream — this plugin models the amp head only.

---

## Command reference

Every build step lives in `build.zig`; `zig build --help` lists them.

### Build

| Command                            | What it does                                            |
| ---------------------------------- | ------------------------------------------------------- |
| `zig build`                        | Build the CLAP (Debug) → `zig-out/clap/OR120AmpSim.clap` |
| `zig build -Doptimize=ReleaseFast` | Optimized build — use this for anything you actually play through |
| `zig build -Doptimize=ReleaseSafe` | Optimized, but keeps safety checks (good for bug hunts)  |
| `zig build -Doptimize=ReleaseSmall`| Optimized for binary size                                |
| `zig build uninstall`              | Remove build artifacts from the prefix                   |
| `.\scripts\vendor.ps1`             | Fetch/refresh vendored third-party sources into `vendor/`|

Add `--summary all` to any step to see what actually ran, and `--verbose` to see
the underlying compiler invocations.

### Test

| Command                              | What it does                                          |
| ------------------------------------ | ------------------------------------------------------ |
| `zig build test`                     | DSP + params unit tests (silent output means everything passed) |
| `zig build test --summary all`       | Same, but prints a per-step pass/fail summary          |

The test step covers `src/dsp/engine.zig` (and the filter/oversampler/waveshaper
modules it imports) plus `src/params.zig`.

Some invariants are enforced at **compile time** rather than by a test — the
real-time audit in `src/dsp/rt_audit.zig` fails the build if any audio-thread
type gains a pointer or slice field (i.e. becomes able to own heap memory). It
runs during an ordinary `zig build`, so a violation shows up as a compile error
naming the offending field.

### Validate (CLAP conformance)

The repo vendors `clap-validator` under `tools/`.

```powershell
# Full validation run
.\tools\clap-validator\clap-validator.exe validate .\zig-out\clap\OR120AmpSim.clap

# Only show what failed
.\tools\clap-validator\clap-validator.exe validate --only-failed .\zig-out\clap\OR120AmpSim.clap

# Run a subset by regex (e.g. just the state tests)
.\tools\clap-validator\clap-validator.exe validate -t state .\zig-out\clap\OR120AmpSim.clap

# Machine-readable output
.\tools\clap-validator\clap-validator.exe validate --json .\zig-out\clap\OR120AmpSim.clap
```

Note that the validator does **not** open the editor, so the GUI and its OpenGL
texture path are not exercised by it — a host is still the first real test.

### Benchmark

```powershell
zig build bench -Doptimize=ReleaseFast
```

Runs `src/bench.zig`: verifies the channel-parallel SIMD engine
(`src/dsp/engine_vec.zig`) matches the scalar reference sample-for-sample, then
times both and reports throughput, speedup and realtime headroom. Always build it
optimized — Debug numbers are meaningless.

### Baked GUI assets

```powershell
zig build assets
```

Runs `tools/bake_assets`, which renders the GUI art offline and writes it to
`assets/`:

| File                | Size      | Purpose                                        |
| ------------------- | --------- | ---------------------------------------------- |
| `knob.png`          | 2048×1024 | 128-frame knob filmstrip, laid out as a 16×8 grid |
| `tolex.png`         | 256×256   | Seamlessly tiling woven-vinyl swatch            |
| `knob_preview.png`  | —         | Dev aid: five frames at 3× on a grey card       |
| `panel_preview.png` | —         | Dev aid: the art composited as an assembled panel |

A grid atlas rather than the traditional vertical filmstrip because 128 stacked
frames would exceed `GL_MAX_TEXTURE_SIZE` on most GPUs.

The two `*_preview.png` files are development aids for judging the art — they are
not loaded by the plugin. Only `knob.png` and `tolex.png` are embedded.

These renders are **meant to be replaced**. Anything that writes a PNG with the
same dimensions and grid layout (Blender, KeyShot, Photoshop) can be dropped in
over the top; no plugin code depends on how the pixels were produced. If you
change the frame count or grid, update the constants in both
`tools/bake_assets/main.zig` and `src/gui/texture.zig` — they must agree.

The baker is always compiled `ReleaseFast` regardless of `-Doptimize`, because it
is sampling-heavy and takes minutes in Debug.

### VST3

```powershell
# Release (default)
.\scripts\build-vst3.ps1

# Other configurations
.\scripts\build-vst3.ps1 -Config Debug
.\scripts\build-vst3.ps1 -Config RelWithDebInfo
```

The script builds the CLAP first, vendors clap-wrapper if missing, then
configures and builds it via CMake into `build/vst3/`, and copies the result to
`zig-out/vst3/OR120AmpSim.vst3`.

The first CMake configure downloads the CLAP and VST3 SDKs, so it needs network
access and takes a few minutes. Subsequent builds are incremental. To force a
clean reconfigure, delete `build/vst3/`.

---

## Debugging

**Symbols.** `zig build` emits `zig-out/clap/OR120AmpSim.pdb` next to the plugin.
Keep the two together — copy both when installing if you want to debug in a host.

**Attaching to a DAW.** The plugin is a DLL loaded by the host, so debug it by
attaching to the host process (Visual Studio: *Debug → Attach to Process*; or
launch the DAW under the debugger). Build Debug or `ReleaseSafe` first —
`ReleaseFast` inlines most of the DSP away.

**Debugging without a DAW.** The validator can host the plugin inside its own
process, which is far easier to attach a debugger to:

```powershell
.\tools\clap-validator\clap-validator.exe validate --in-process .\zig-out\clap\OR120AmpSim.clap
```

By default the validator runs each plugin out-of-process so a crash doesn't take
the validator down with it — useful on its own, since a crashing test is reported
rather than silently killing the run.

**Crashes on editor open.** Almost always Clay arena sizing or GL context
lifetime. `Gui.create` caps Clay's element count and then allocates exactly what
Clay reports it needs; handing it a smaller buffer lets layout overrun the arena
and corrupt the heap. GL objects (textures) belong to the GL context and are
released in `teardownWindow` while the context is still current.

**Silent GUI, no art.** If a baked texture fails to decode or upload, the GUI
falls back to the procedural drawing rather than failing — so a panel that looks
like the old vector rendering means the texture path is broken, not the layout.

**Checking real-time safety.** Heap allocation on the audio thread is a build
error by construction (see [Test](#test)). For anything else, the benchmark's
"realtime x" figure is the quickest signal that a DSP change got expensive.

---

## Project layout

- `src/dsp/` — signal chain: preamp/power-amp wave-shaping, tone stack, filters,
  oversampling, and the amp engine.
  - `engine.zig` — the scalar amp engine used by the plugin.
  - `tonestack.zig` — the James network, solved as the real circuit.
  - `engine_vec.zig` — channel-parallel SIMD prototype of the same chain, used
    only by the benchmark.
  - `rt_audit.zig` — compile-time real-time-safety audit (no heap ownership on
    the audio thread).
- `src/gui/` — Clay UI, Win32/OpenGL windowing, panel/knob rendering, and knob
  interaction.
  - `texture.zig` — PNG decode, GL texture upload, textured-quad and filmstrip
    drawing.
  - `decor.zig` — tolex background, screws, vignette, knobs (textured, with
    procedural fallbacks).
- `src/params.zig` — parameter definitions, atomic state store, lock-free change queue.
- `src/clap_abi.zig`, `src/clap_plugin.zig` — the CLAP ABI and the plugin implementation.
- `src/bench.zig` — scalar-vs-SIMD DSP benchmark (`zig build bench`).
- `assets/` — baked GUI art, embedded into the binary at build time. Committed.
- `tools/bake_assets/` — the offline renderer that generates `assets/`.
- `tools/clap-validator/` — bundled CLAP conformance validator.
- `scripts/` — dependency vendoring (`vendor.ps1`) and the VST3 build (`build-vst3.ps1`).
- `vendor/` — fetched third-party sources (git-ignored).
- `docs/CODEBASE_GUIDE.md` — deeper tour of the code.
