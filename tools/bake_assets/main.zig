//! Offline asset baker for the amp GUI.
//!
//! Renders the GUI's raster assets once, ahead of time, and writes them to
//! `assets/` as PNGs that the plugin embeds and uploads as GL textures:
//!
//!   * `knob.png`  – a 128-frame knob filmstrip laid out as a 16x8 grid atlas.
//!     Frame `i` is the knob drawn with its pointer at normalised value
//!     `i / (frames - 1)`. A grid rather than the traditional vertical strip
//!     because 128 stacked frames would exceed GL_MAX_TEXTURE_SIZE.
//!   * `tolex.png` – a seamlessly tiling woven-vinyl swatch for the background.
//!
//! Why bake at all: the live renderer is fixed-function OpenGL, so its shading
//! is limited to per-vertex colour interpolation. Doing the work offline buys
//! per-pixel lighting, supersampled edges, anisotropic brushing and ambient
//! occlusion for free at runtime — the same reason commercial amp sims ship
//! pre-rendered knob strips instead of drawing them procedurally.
//!
//! These renders are meant to be *replaceable*. Anything that writes a PNG of
//! the same dimensions and layout (Blender, KeyShot, Photoshop) can drop in
//! over the top; nothing in the plugin depends on how the pixels were made.
//!
//! Run with `zig build assets` (built in ReleaseFast — it is sampling-heavy).

const std = @import("std");

extern fn stbi_write_png(
    filename: [*:0]const u8,
    w: c_int,
    h: c_int,
    comp: c_int,
    data: *const anyopaque,
    stride_bytes: c_int,
) c_int;

// ---------------------------------------------------------------------------
// Small vector / shading helpers
// ---------------------------------------------------------------------------

const Vec3 = @Vector(3, f32);

fn v3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn normalize(a: Vec3) Vec3 {
    const len = @sqrt(dot(a, a));
    if (len <= 1e-8) return v3(0, 0, 1);
    return a / @as(Vec3, @splat(len));
}

fn saturate(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn mix3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a + (b - a) * @as(Vec3, @splat(t));
}

/// Hermite smoothstep from `e0` to `e1`. Also used as a soft coverage test:
/// `smoothstep(edge + w, edge - w, r)` gives an antialiased inside/outside mask.
fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    if (e0 == e1) return if (x < e0) 0.0 else 1.0;
    const t = saturate((x - e0) / (e1 - e0));
    return t * t * (3.0 - 2.0 * t);
}

/// Deterministic hash-based value noise in 0..1 for a 2D integer lattice point.
fn hash2(ix: i32, iy: i32) f32 {
    var h: u32 = @bitCast(ix *% 374761393 +% iy *% 668265263);
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xFFFFFF)) / @as(f32, 0xFFFFFF);
}

/// Bilinear value noise on a lattice of `period` cells that wraps seamlessly,
/// so anything built from it tiles without a visible seam.
fn wrappedNoise(x: f32, y: f32, period: i32) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const tx = x - fx;
    const ty = y - fy;
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const x0 = @mod(ix, period);
    const y0 = @mod(iy, period);
    const x1 = @mod(ix + 1, period);
    const y1 = @mod(iy + 1, period);
    const sx = tx * tx * (3.0 - 2.0 * tx);
    const sy = ty * ty * (3.0 - 2.0 * ty);
    const n00 = hash2(x0, y0);
    const n10 = hash2(x1, y0);
    const n01 = hash2(x0, y1);
    const n11 = hash2(x1, y1);
    return mix(mix(n00, n10, sx), mix(n01, n11, sx), sy);
}

/// Linear colour -> 8-bit sRGB-ish. A plain 1/2.2 curve is close enough here and
/// keeps the baker free of a full sRGB transform.
fn encode(x: f32) u8 {
    const v = std.math.pow(f32, saturate(x), 1.0 / 2.2);
    return @intFromFloat(@round(saturate(v) * 255.0));
}

// ---------------------------------------------------------------------------
// Shared lighting rig
// ---------------------------------------------------------------------------
//
// Screen space, y increasing downward, +z out of the screen toward the viewer.
// A key light from the upper-left (matching the old procedural shading in
// decor.zig) plus a dim lower-right fill so shadowed sides never go flat black.

const key_dir = normalize(v3(-0.55, -0.83, 0.75));
const fill_dir = normalize(v3(0.45, 0.55, 0.60));
const view_dir = v3(0, 0, 1);

/// Blinn-Phong specular for a normal, light direction and roughness exponent.
fn specular(n: Vec3, l: Vec3, power: f32) f32 {
    const h = normalize(l + view_dir);
    return std.math.pow(f32, saturate(dot(n, h)), power);
}

// ---------------------------------------------------------------------------
// Knob filmstrip
// ---------------------------------------------------------------------------

const knob_frames = 128;
const knob_cols = 16;
const knob_rows = knob_frames / knob_cols;
const knob_size = 128; // pixels per frame
const knob_ss = 4; // supersampling factor per axis

/// Pointer sweep each side of straight-up, in degrees. Must match
/// `decor.sweep_deg` so the baked pointer lines up with the live tick ring.
const sweep_deg: f32 = 140.0;

// Radii in frame-local units where 1.0 is half the frame extent.
const r_skirt: f32 = 0.82;
const r_cap: f32 = 0.50;
const cham: f32 = 0.05; // outer chamfer width on the skirt
const wall: f32 = 0.045; // vertical wall where the cap steps up

/// Surface height as a function of radius. Differentiating this gives the
/// normal, so the profile is what actually produces the relief: a chamfered
/// skirt rim, a near-flat skirt top, a steep step up to the cap, then a gently
/// domed cap face.
fn knobHeight(r: f32) f32 {
    if (r >= r_skirt) return 0.0;
    if (r > r_skirt - cham) {
        // Outer chamfer: climbs from the base plane to the skirt top.
        const t = (r_skirt - r) / cham;
        return 0.10 * smoothstep(0.0, 1.0, t);
    }
    if (r > r_cap) {
        // Skirt top, very slightly crowned toward the centre.
        const t = (r_skirt - cham - r) / @max(r_skirt - cham - r_cap, 1e-5);
        return 0.10 + 0.02 * t;
    }
    if (r > r_cap - wall) {
        // The step up to the raised cap.
        const t = (r_cap - r) / wall;
        return 0.12 + 0.16 * smoothstep(0.0, 1.0, t);
    }
    // Cap face: shallow spherical dome.
    const u = r / @max(r_cap - wall, 1e-5);
    return 0.28 + 0.085 * @sqrt(@max(0.0, 1.0 - u * u));
}

/// Signed distance to the pointer bar, in frame-local units. Negative inside.
/// The bar runs from near the cap centre out toward the cap edge at `angle`.
fn pointerDistance(x: f32, y: f32, angle: f32) f32 {
    // Rotate the sample into the pointer's frame: +Y along the pointer.
    const s = @sin(angle);
    const c = @cos(angle);
    const px = x * c + y * s;
    const py = -x * s + y * c;
    const inner: f32 = 0.06;
    const outer: f32 = r_cap - wall - 0.045;
    const half_w: f32 = 0.036;
    // Capsule: distance to the segment from (0, -inner) to (0, -outer) in a
    // frame where the pointer points toward -Y (screen up at value 0.5).
    const cy = std.math.clamp(py, -outer, -inner);
    const d = @sqrt(px * px + (py - cy) * (py - cy));
    return d - half_w;
}

/// Shade one supersample of the knob. Returns premultiplied-by-coverage linear
/// RGB plus its coverage, so the caller can accumulate straight averages.
fn shadeKnob(x: f32, y: f32, angle: f32, px: f32) struct { rgb: Vec3, a: f32 } {
    const r = @sqrt(x * x + y * y);

    // --- Contact shadow, cast down-right onto whatever is behind the knob ----
    const sx = x - 0.035;
    const sy = y - 0.055;
    const sr = @sqrt(sx * sx + sy * sy);
    const shadow = smoothstep(r_skirt + 0.13, r_skirt - 0.02, sr) * 0.55;

    const body = smoothstep(r_skirt + px, r_skirt - px, r);
    if (body <= 0.0) {
        // Outside the knob: shadow only, over transparent.
        return .{ .rgb = v3(0, 0, 0), .a = shadow };
    }

    // --- Normal from the height profile -------------------------------------
    const eps: f32 = 0.0035;
    const dhdr = (knobHeight(r + eps) - knobHeight(r - eps)) / (2.0 * eps);
    const inv_r = if (r > 1e-5) 1.0 / r else 0.0;
    var n = normalize(v3(-dhdr * x * inv_r, -dhdr * y * inv_r, 1.0));

    // --- Material selection --------------------------------------------------
    const on_cap = r < r_cap - wall * 0.5;
    const pd = pointerDistance(x, y, angle);
    const on_pointer = on_cap and pd < 0.0;
    const pointer_mask = if (on_cap) smoothstep(px, -px, pd) else 0.0;

    var albedo: Vec3 = undefined;
    var spec_strength: f32 = undefined;
    var spec_power: f32 = undefined;

    if (on_cap) {
        // Dark anodised aluminium cap with circular (anisotropic) brushing:
        // fine tangential streaks that catch the key light as it sweeps around.
        const theta = std.math.atan2(y, x);
        const brush = wrappedNoise(theta * 42.0 / std.math.tau * 64.0, r * 90.0, 64) - 0.5;
        albedo = mix3(v3(0.048, 0.044, 0.039), v3(0.082, 0.077, 0.069), saturate(brush + 0.5));
        // Perturb the normal tangentially so the brushing reads as relief.
        const tangent = v3(-y * inv_r, x * inv_r, 0);
        n = normalize(n + tangent * @as(Vec3, @splat(brush * 0.13)));
        spec_strength = 0.78;
        spec_power = 62.0;
    } else {
        // Skirt: matte black phenolic with a faint moulding grain.
        const grain = (wrappedNoise(x * 55.0 + 11.0, y * 55.0 + 7.0, 64) - 0.5) * 0.008;
        albedo = v3(0.028 + grain, 0.025 + grain, 0.021 + grain);
        spec_strength = 0.30;
        spec_power = 22.0;
    }

    if (on_pointer) {
        // Cream pointer, inlaid: brighter, softer highlight than the metal.
        albedo = mix3(albedo, v3(0.86, 0.82, 0.72), pointer_mask);
        spec_strength = mix(spec_strength, 0.30, pointer_mask);
        spec_power = mix(spec_power, 24.0, pointer_mask);
    }

    // --- Ambient occlusion ---------------------------------------------------
    // Darken the crease where the cap meets the skirt, and the outer chamfer.
    var ao: f32 = 1.0;
    ao *= mix(0.38, 1.0, smoothstep(r_cap, r_cap + 0.09, r)); // outside the step
    ao *= mix(0.60, 1.0, smoothstep(r_cap - wall - 0.02, r_cap - wall - 0.14, r)); // inside it
    ao *= mix(0.62, 1.0, smoothstep(r_skirt, r_skirt - 0.10, r)); // outer rim

    // --- Lighting ------------------------------------------------------------
    const key_diff = saturate(dot(n, key_dir));
    const fill_diff = saturate(dot(n, fill_dir));
    // Kept low deliberately: these are near-black mouldings, so the shape has to
    // come from the speculars, not from lifting the whole silhouette.
    const ambient: f32 = 0.05;

    var lit = albedo * @as(Vec3, @splat((key_diff * 1.00 + fill_diff * 0.18 + ambient) * ao));
    lit += @as(Vec3, @splat(specular(n, key_dir, spec_power) * spec_strength * ao));
    lit += @as(Vec3, @splat(specular(n, fill_dir, spec_power * 0.6) * spec_strength * 0.16 * ao));

    // Fresnel rim: grazing angles pick up sky light, which is what sells the
    // rounded edge of a moulded knob.
    const fres = std.math.pow(f32, 1.0 - saturate(n[2]), 4.0);
    lit += @as(Vec3, @splat(fres * 0.075 * ao));

    // Composite the knob over the contact shadow so the shadow shows in the
    // antialiased fringe rather than leaving a bright halo.
    const a = body + shadow * (1.0 - body);
    const rgb = lit * @as(Vec3, @splat(body));
    return .{ .rgb = rgb, .a = a };
}

/// Returns the atlas pixels; the caller owns them (reused by the panel preview).
fn bakeKnob(allocator: std.mem.Allocator, out_dir: []const u8) ![]u8 {
    const w = knob_cols * knob_size;
    const h = knob_rows * knob_size;
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    // Half a pixel in frame-local units, for the soft coverage test.
    const px_half: f32 = 1.0 / @as(f32, knob_size);
    const inv_ss: f32 = 1.0 / @as(f32, knob_ss);
    const samples: f32 = @as(f32, knob_ss) * @as(f32, knob_ss);

    var frame: usize = 0;
    while (frame < knob_frames) : (frame += 1) {
        const value = @as(f32, @floatFromInt(frame)) / @as(f32, knob_frames - 1);
        // Value 0 points to the lower-left, 1 to the lower-right, matching the
        // live tick ring in decor.zig.
        const angle = std.math.degreesToRadians(-sweep_deg + value * 2.0 * sweep_deg);

        const col = frame % knob_cols;
        const row = frame / knob_cols;
        const ox = col * knob_size;
        const oy = row * knob_size;

        var py: usize = 0;
        while (py < knob_size) : (py += 1) {
            var pxi: usize = 0;
            while (pxi < knob_size) : (pxi += 1) {
                var acc_rgb: Vec3 = v3(0, 0, 0);
                var acc_a: f32 = 0.0;

                var sy: usize = 0;
                while (sy < knob_ss) : (sy += 1) {
                    var sx: usize = 0;
                    while (sx < knob_ss) : (sx += 1) {
                        const fx = (@as(f32, @floatFromInt(pxi)) + (@as(f32, @floatFromInt(sx)) + 0.5) * inv_ss) / @as(f32, knob_size);
                        const fy = (@as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) * inv_ss) / @as(f32, knob_size);
                        // Map to -1..1 frame-local coordinates.
                        const s = shadeKnob(fx * 2.0 - 1.0, fy * 2.0 - 1.0, angle, px_half);
                        acc_rgb += s.rgb;
                        acc_a += s.a;
                    }
                }

                const a = acc_a / samples;
                const rgb = acc_rgb / @as(Vec3, @splat(samples));
                // Un-premultiply so the runtime can use ordinary src-alpha blending.
                const inv_a = if (a > 1e-4) 1.0 / a else 0.0;
                const idx = ((oy + py) * @as(usize, w) + (ox + pxi)) * 4;
                pixels[idx + 0] = encode(rgb[0] * inv_a);
                pixels[idx + 1] = encode(rgb[1] * inv_a);
                pixels[idx + 2] = encode(rgb[2] * inv_a);
                pixels[idx + 3] = @intFromFloat(@round(saturate(a) * 255.0));
            }
        }
    }

    try writePng(allocator, out_dir, "knob.png", pixels, w, h);
    std.debug.print("  knob.png    {d}x{d}  ({d} frames, {d}x{d} grid)\n", .{ w, h, knob_frames, knob_cols, knob_rows });

    try writeKnobPreview(allocator, out_dir, pixels, w);
    return pixels;
}

/// Development aid: pull a few representative frames out of the atlas and write
/// them magnified onto a mid-grey card, so the shading can actually be judged.
/// Not consumed by the plugin.
fn writeKnobPreview(allocator: std.mem.Allocator, out_dir: []const u8, atlas: []const u8, atlas_w: i32) !void {
    const picks = [_]usize{ 0, 32, 64, 96, 127 };
    const zoom = 3;
    const cell = knob_size * zoom;
    const w: i32 = @intCast(cell * picks.len);
    const h: i32 = @intCast(cell);
    const pixels = try allocator.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4);
    defer allocator.free(pixels);

    for (picks, 0..) |frame, slot| {
        const src_ox = (frame % knob_cols) * knob_size;
        const src_oy = (frame / knob_cols) * knob_size;
        var py: usize = 0;
        while (py < cell) : (py += 1) {
            var px: usize = 0;
            while (px < cell) : (px += 1) {
                const sx = src_ox + px / zoom;
                const sy = src_oy + py / zoom;
                const si = (sy * @as(usize, @intCast(atlas_w)) + sx) * 4;
                const di = (py * @as(usize, @intCast(w)) + slot * cell + px) * 4;
                // Composite over a mid-grey card so alpha and shadow are visible.
                const a = @as(f32, @floatFromInt(atlas[si + 3])) / 255.0;
                inline for (0..3) |ch| {
                    const fg: f32 = @floatFromInt(atlas[si + ch]);
                    pixels[di + ch] = @intFromFloat(@round(fg * a + 110.0 * (1.0 - a)));
                }
                pixels[di + 3] = 255;
            }
        }
    }

    try writePng(allocator, out_dir, "knob_preview.png", pixels, w, h);
    std.debug.print("  knob_preview.png  {d}x{d}  (dev aid: frames 0/32/64/96/127 at {d}x)\n", .{ w, h, zoom });
}

// ---------------------------------------------------------------------------
// Tolex tile
// ---------------------------------------------------------------------------

const tolex_size = 256;
const tolex_ss = 3;
/// Thread pitch in pixels. `tolex_size` must be a multiple of this for the weave
/// to meet itself across the tile boundary.
const weave_pitch: f32 = 8.0;

/// Base tolex colour. Deliberately more saturated than a straight linearisation
/// of theme.tolex (232, 104, 26): the white sheen added below desaturates every
/// channel equally, and the 1/2.2 encode lifts the weak green/blue channels far
/// more than the strong red one. Compensating here keeps the result orange
/// instead of drifting to tan.
const tolex_base = v3(0.88, 0.235, 0.030);

/// Height of the woven surface at a point, built from two diagonal thread
/// families that alternate over/under per cell. Periodic in both axes.
fn tolexHeight(x: f32, y: f32) f32 {
    const u = (x + y) / weave_pitch;
    const v = (x - y) / weave_pitch;

    // Rounded thread profile: peak at the centre of each thread.
    const tu = u - @floor(u);
    const tv = v - @floor(v);
    const ridge_u = @sin(tu * std.math.pi);
    const ridge_v = @sin(tv * std.math.pi);

    // Which family sits on top in this cell of the weave.
    const cell = @as(i32, @intFromFloat(@floor(u))) + @as(i32, @intFromFloat(@floor(v)));
    const u_over = @mod(cell, 2) == 0;

    const hu = ridge_u * ridge_u;
    const hv = ridge_v * ridge_v;
    const h = if (u_over) hu * 0.75 + hv * 0.25 else hu * 0.25 + hv * 0.75;

    // Vinyl grain on top of the weave.
    const grain = wrappedNoise(x / 8.0, y / 8.0, tolex_size / 8) * 0.10;
    return h + grain;
}

fn shadeTolex(x: f32, y: f32) Vec3 {
    const eps: f32 = 0.35;
    const hx = (tolexHeight(x + eps, y) - tolexHeight(x - eps, y)) / (2.0 * eps);
    const hy = (tolexHeight(x, y + eps) - tolexHeight(x, y - eps)) / (2.0 * eps);
    // Scale the gradient into a believable bump strength.
    const n = normalize(v3(-hx * 2.6, -hy * 2.6, 1.0));

    const key_diff = saturate(dot(n, key_dir));
    const fill_diff = saturate(dot(n, fill_dir));

    // Per-thread colour jitter keeps the weave from looking rubber-stamped.
    const jitter = (wrappedNoise(x / 6.0 + 3.0, y / 6.0 + 9.0, tolex_size / 6) - 0.5) * 0.14;
    const albedo = tolex_base * @as(Vec3, @splat(1.0 + jitter));

    // Creases between threads sit in shadow.
    const ao = mix(0.42, 1.0, saturate(tolexHeight(x, y)));

    var lit = albedo * @as(Vec3, @splat((key_diff * 0.88 + fill_diff * 0.16 + 0.10) * ao));
    // Vinyl has a broad, weak sheen rather than a tight highlight. Tinted toward
    // the albedo rather than pure white so it lifts the weave without bleaching
    // the colour out of it.
    const sheen = specular(n, key_dir, 14.0) * 0.09 * ao;
    lit += mix3(v3(1, 1, 1), albedo, 0.55) * @as(Vec3, @splat(sheen));
    return lit;
}

/// Returns the tile pixels; the caller owns them (reused by the panel preview).
fn bakeTolex(allocator: std.mem.Allocator, out_dir: []const u8) ![]u8 {
    const w = tolex_size;
    const h = tolex_size;
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    errdefer allocator.free(pixels);

    const inv_ss: f32 = 1.0 / @as(f32, tolex_ss);
    const samples: f32 = @as(f32, tolex_ss) * @as(f32, tolex_ss);

    var py: usize = 0;
    while (py < h) : (py += 1) {
        var pxi: usize = 0;
        while (pxi < w) : (pxi += 1) {
            var acc: Vec3 = v3(0, 0, 0);
            var sy: usize = 0;
            while (sy < tolex_ss) : (sy += 1) {
                var sx: usize = 0;
                while (sx < tolex_ss) : (sx += 1) {
                    const fx = @as(f32, @floatFromInt(pxi)) + (@as(f32, @floatFromInt(sx)) + 0.5) * inv_ss;
                    const fy = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) * inv_ss;
                    acc += shadeTolex(fx, fy);
                }
            }
            const rgb = acc / @as(Vec3, @splat(samples));
            const idx = (py * @as(usize, w) + pxi) * 4;
            pixels[idx + 0] = encode(rgb[0]);
            pixels[idx + 1] = encode(rgb[1]);
            pixels[idx + 2] = encode(rgb[2]);
            pixels[idx + 3] = 255;
        }
    }

    try writePng(allocator, out_dir, "tolex.png", pixels, w, h);
    std.debug.print("  tolex.png   {d}x{d}  (seamless, {d}px weave pitch)\n", .{ w, h, @as(u32, @intFromFloat(weave_pitch)) });
    return pixels;
}

// ---------------------------------------------------------------------------

fn writePng(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    name: []const u8,
    pixels: []const u8,
    w: i32,
    h: i32,
) !void {
    const path = try std.fs.path.joinZ(allocator, &.{ out_dir, name });
    defer allocator.free(path);
    if (stbi_write_png(path.ptr, w, h, 4, pixels.ptr, w * 4) == 0) {
        std.debug.print("error: failed to write {s}\n", .{path});
        return error.WriteFailed;
    }
}

// ---------------------------------------------------------------------------
// Assembled panel preview
// ---------------------------------------------------------------------------

/// Development aid: composite the baked art roughly the way the GUI arranges it
/// — tiled tolex, a dark control strip, a row of knobs — so the combination can
/// be judged without loading the plugin in a host.
///
/// This approximates the layout in panel.zig; it is not driven by it, so treat
/// it as an art check rather than a rendering test.
fn bakePanelPreview(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    knob_atlas: []const u8,
    atlas_w: i32,
    tolex: []const u8,
) !void {
    const w = 720;
    const h = 300;
    const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    defer allocator.free(pixels);

    // Background: tiled tolex at the same scale decor.zig uses.
    const tile_scale = 1.0;
    var py: usize = 0;
    while (py < h) : (py += 1) {
        var px: usize = 0;
        while (px < w) : (px += 1) {
            const sx: usize = @intFromFloat(@mod(@as(f32, @floatFromInt(px)) / tile_scale, tolex_size));
            const sy: usize = @intFromFloat(@mod(@as(f32, @floatFromInt(py)) / tile_scale, tolex_size));
            const si = (sy * tolex_size + sx) * 4;
            const di = (py * w + px) * 4;
            @memcpy(pixels[di .. di + 4], tolex[si .. si + 4]);
        }
    }

    // Control strip: the near-black panel face the knobs sit on.
    const strip_x: usize = 28;
    const strip_y: usize = 96;
    const strip_w: usize = w - 56;
    const strip_h: usize = 170;
    py = strip_y;
    while (py < strip_y + strip_h) : (py += 1) {
        var px: usize = strip_x;
        while (px < strip_x + strip_w) : (px += 1) {
            const di = (py * w + px) * 4;
            pixels[di + 0] = 22;
            pixels[di + 1] = 19;
            pixels[di + 2] = 16;
        }
    }

    // Knob row: eight knobs at a plausible spread of values.
    const values = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0.4, 0.5, 0.5, 0.0 };
    const draw_px: usize = 74; // on-screen size of one baked frame
    const spacing = strip_w / values.len;
    for (values, 0..) |value, i| {
        const frame: usize = @intFromFloat(@round(value * @as(f32, knob_frames - 1)));
        const src_ox = (frame % knob_cols) * knob_size;
        const src_oy = (frame / knob_cols) * knob_size;
        const cx = strip_x + spacing * i + spacing / 2;
        const cy = strip_y + strip_h / 2 - 12;

        var dy: usize = 0;
        while (dy < draw_px) : (dy += 1) {
            var dx: usize = 0;
            while (dx < draw_px) : (dx += 1) {
                const tx = cx + dx - draw_px / 2;
                const ty = cy + dy - draw_px / 2;
                if (tx >= w or ty >= h) continue;
                // Nearest-neighbour resample of the source frame.
                const sx = src_ox + dx * knob_size / draw_px;
                const sy = src_oy + dy * knob_size / draw_px;
                const si = (sy * @as(usize, @intCast(atlas_w)) + sx) * 4;
                const di = (ty * w + tx) * 4;
                const a = @as(f32, @floatFromInt(knob_atlas[si + 3])) / 255.0;
                inline for (0..3) |ch| {
                    const fg: f32 = @floatFromInt(knob_atlas[si + ch]);
                    const bg: f32 = @floatFromInt(pixels[di + ch]);
                    pixels[di + ch] = @intFromFloat(@round(fg * a + bg * (1.0 - a)));
                }
            }
        }
    }

    try writePng(allocator, out_dir, "panel_preview.png", pixels, w, h);
    std.debug.print("  panel_preview.png {d}x{d}  (dev aid: assembled art check)\n", .{ w, h });
}

pub fn main() !void {
    // A short-lived batch tool: the OS reclaims everything on exit.
    const allocator = std.heap.page_allocator;

    // Fixed by project convention; the build step runs this from the repo root.
    // The directory is checked into the repo, so it is not created here — a
    // missing one surfaces as a clear write failure in `writePng`.
    const out_dir = "assets";

    std.debug.print("baking GUI assets into {s}/\n", .{out_dir});
    const knob_atlas = try bakeKnob(allocator, out_dir);
    defer allocator.free(knob_atlas);
    const tolex_tile = try bakeTolex(allocator, out_dir);
    defer allocator.free(tolex_tile);
    try bakePanelPreview(allocator, out_dir, knob_atlas, knob_cols * knob_size, tolex_tile);
    std.debug.print("done.\n", .{});
}
