//! OpenGL decoration drawn around the Clay-declared panel:
//!   * a woven-vinyl tolex background with a soft vignette and corner screws,
//!     rendered behind the Clay pass (the panel root is transparent);
//!   * knobs with a silkscreen tick ring, rendered as an overlay on top of the
//!     Clay pass using the knob bounding boxes cached from the layout.
//!
//! The tolex and the knob bodies come from baked textures (`assets/`, built by
//! `tools/bake_assets`), which buys per-pixel lighting and supersampled edges
//! that fixed-function GL cannot produce live. The tick ring stays procedural
//! because its tick count varies per parameter.
//!
//! Every textured path keeps its original immediate-mode drawing as a fallback,
//! used when a texture failed to load, so the GUI degrades instead of vanishing.

const std = @import("std");
const gl = @import("gl.zig");
const theme = @import("theme.zig");
const texture = @import("texture.zig");

const tau = std.math.tau;

/// Knob pointer sweep in degrees each side of straight-up.
const sweep_deg: f32 = 140.0;
/// Normalised light direction (screen space, y down): upper-left key light.
const light_x: f32 = -0.55;
const light_y: f32 = -0.83;

fn color(r: f32, g: f32, b: f32, a: f32) void {
    gl.glColor4f(r / 255.0, g / 255.0, b / 255.0, a / 255.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn setOrtho(w: f32, h: f32) void {
    gl.glMatrixMode(gl.GL_PROJECTION);
    gl.glLoadIdentity();
    gl.glOrtho(0.0, w, h, 0.0, -1.0, 1.0);
    gl.glMatrixMode(gl.GL_MODELVIEW);
    gl.glLoadIdentity();
}

// ---------------------------------------------------------------------------
// Background
// ---------------------------------------------------------------------------

/// Screen pixels per texel when tiling the tolex swatch. Kept at 1.0 so the
/// swatch is never minified — there are no mipmaps, and the weave is baked at
/// the pitch it should appear at on screen.
const tolex_tile_scale: f32 = 1.0;

/// Fill the framebuffer with tiled tolex, a soft edge vignette and four corner
/// screws. Falls back to the original flat fill plus cross-hatch if the texture
/// is unavailable.
pub fn drawTolexBackground(tex: *const texture.Set, width: i32, height: i32) void {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    setOrtho(w, h);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_LINE_SMOOTH);
    gl.glHint(gl.GL_LINE_SMOOTH_HINT, gl.GL_NICEST);

    if (tex.tolex.valid()) {
        texture.drawTiled(tex.tolex, 0, 0, w, h, tolex_tile_scale);
    } else {
        drawTolexFallback(w, h);
    }

    drawVignette(w, h);

    // Corner screws, inset into the picture-frame border.
    const inset: f32 = 15.0;
    drawScrew(inset, inset);
    drawScrew(w - inset, inset);
    drawScrew(inset, h - inset);
    drawScrew(w - inset, h - inset);
}

/// Flat tolex fill with an interleaved cross-hatch weave. Used only when the
/// baked swatch is missing; the texture path supersedes it.
fn drawTolexFallback(w: f32, h: f32) void {
    color(theme.tolex.r, theme.tolex.g, theme.tolex.b, 255);
    gl.glBegin(gl.GL_QUADS);
    gl.glVertex2f(0, 0);
    gl.glVertex2f(w, 0);
    gl.glVertex2f(w, h);
    gl.glVertex2f(0, h);
    gl.glEnd();

    const spacing: f32 = 7.0;
    gl.glLineWidth(1.0);
    color(150, 60, 12, 26);
    gl.glBegin(gl.GL_LINES);
    var d: f32 = -h;
    while (d < w) : (d += spacing) {
        gl.glVertex2f(d, h);
        gl.glVertex2f(d + h, 0);
    }
    gl.glEnd();
    color(255, 168, 96, 22);
    gl.glBegin(gl.GL_LINES);
    d = 0;
    while (d < w + h) : (d += spacing) {
        gl.glVertex2f(d - h, 0);
        gl.glVertex2f(d, h);
    }
    gl.glEnd();
}

/// Darken the framebuffer edges with a centre-transparent fan for depth.
fn drawVignette(w: f32, h: f32) void {
    const cx = w * 0.5;
    const cy = h * 0.5;
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    color(0, 0, 0, 0);
    gl.glVertex2f(cx, cy);
    color(0, 0, 0, 70);
    const segs = 32;
    var i: usize = 0;
    while (i <= segs) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, segs) * tau;
        // Reach past the corners so the darkening only bites near the edges.
        gl.glVertex2f(cx + std.math.cos(a) * w * 0.75, cy + std.math.sin(a) * h * 0.75);
    }
    gl.glEnd();
}

fn drawScrew(cx: f32, cy: f32) void {
    const r: f32 = 5.0;
    discFlat(cx + 0.6, cy + 0.8, r, 0, 0, 0, 70); // shadow
    discShaded(cx, cy, r, .{ 60, 54, 46 }, .{ 150, 140, 120 }, .{ 120, 112, 96 });
    // Slot.
    gl.glLineWidth(1.4);
    color(30, 26, 22, 200);
    gl.glBegin(gl.GL_LINES);
    gl.glVertex2f(cx - r * 0.6, cy - r * 0.2);
    gl.glVertex2f(cx + r * 0.6, cy + r * 0.2);
    gl.glEnd();
    gl.glLineWidth(1.0);
}

// ---------------------------------------------------------------------------
// Knobs
// ---------------------------------------------------------------------------

/// Flat-shaded filled disc.
fn discFlat(cx: f32, cy: f32, r: f32, cr: f32, cg: f32, cb: f32, ca: f32) void {
    const segs = 40;
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    color(cr, cg, cb, ca);
    gl.glVertex2f(cx, cy);
    var i: usize = 0;
    while (i <= segs) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, segs) * tau;
        gl.glVertex2f(cx + std.math.cos(a) * r, cy + std.math.sin(a) * r);
    }
    gl.glEnd();
}

/// Spherically lit disc: `center` colour in the middle, rim shaded between
/// `rim` (away from the light) and `lit` (toward the light).
fn discShaded(cx: f32, cy: f32, r: f32, rim: [3]f32, lit: [3]f32, center: [3]f32) void {
    const segs = 48;
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    color(center[0], center[1], center[2], 255);
    gl.glVertex2f(cx, cy);
    var i: usize = 0;
    while (i <= segs) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, segs) * tau;
        const ca = std.math.cos(a);
        const sa = std.math.sin(a);
        const dp = ca * light_x + sa * light_y; // -1..1
        const t = std.math.clamp(0.5 + 0.5 * dp, 0.0, 1.0);
        color(lerp(rim[0], lit[0], t), lerp(rim[1], lit[1], t), lerp(rim[2], lit[2], t), 255);
        gl.glVertex2f(cx + ca * r, cy + sa * r);
    }
    gl.glEnd();
}

fn ring(cx: f32, cy: f32, r: f32, width: f32, cr: f32, cg: f32, cb: f32, ca: f32) void {
    const segs = 48;
    gl.glLineWidth(width);
    color(cr, cg, cb, ca);
    gl.glBegin(gl.GL_LINE_LOOP);
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, segs) * tau;
        gl.glVertex2f(cx + std.math.cos(a) * r, cy + std.math.sin(a) * r);
    }
    gl.glEnd();
    gl.glLineWidth(1.0);
}

/// Draw one knob centred at (cx, cy) with body radius `r`. `value` is the
/// normalised 0..1 parameter value (selects the filmstrip frame, which carries
/// the pointer) and `ticks` is the number of position marks around the sweep.
pub fn drawKnob(tex: *const texture.Set, cx: f32, cy: f32, r: f32, value: f32, ticks: usize) void {
    if (tex.knob.valid()) {
        // Body, cap, pointer, contact shadow and all shading are baked in.
        texture.drawKnobFrame(tex.knob, cx, cy, r, value);
    } else {
        drawKnobFallback(cx, cy, r, value);
    }
    drawTickRing(cx, cy, r, ticks);
}

/// Silkscreen tick marks around the knob sweep. Kept procedural: the count
/// varies per parameter, so baking it would need a strip per tick count.
fn drawTickRing(cx: f32, cy: f32, r: f32, ticks: usize) void {
    if (ticks < 2) return;
    gl.glLineWidth(1.5);
    color(theme.label.r, theme.label.g, theme.label.b, 235);
    gl.glBegin(gl.GL_LINES);
    var i: usize = 0;
    while (i < ticks) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ticks - 1));
        const a = std.math.degreesToRadians(-sweep_deg + t * (2.0 * sweep_deg));
        const dx = std.math.sin(a);
        const dy = -std.math.cos(a);
        gl.glVertex2f(cx + dx * r * 1.08, cy + dy * r * 1.08);
        gl.glVertex2f(cx + dx * r * 1.20, cy + dy * r * 1.20);
    }
    gl.glEnd();
    gl.glLineWidth(1.0);
}

/// The original vertex-shaded knob. Used only when the baked filmstrip is
/// missing.
fn drawKnobFallback(cx: f32, cy: f32, r: f32, value: f32) void {
    // Drop shadow.
    discFlat(cx + 1.5, cy + 2.5, r * 1.03, 0, 0, 0, 90);

    // Skirt (wider base) — dark, spherically lit.
    discShaded(cx, cy, r, .{ 12, 10, 9 }, .{ 70, 63, 54 }, .{ 30, 27, 23 });
    ring(cx, cy, r, 1.5, 8, 7, 6, 200);

    // Raised cap.
    const cap = r * 0.66;
    discShaded(cx, cy, cap, .{ 20, 18, 15 }, .{ 92, 84, 70 }, .{ 52, 47, 40 });
    ring(cx, cy, cap, 1.5, theme.knob_edge.r, theme.knob_edge.g, theme.knob_edge.b, 220);

    // Specular glint, upper-left.
    discFlat(cx - r * 0.3, cy - r * 0.36, r * 0.16, 255, 250, 240, 45);

    // Pointer on the cap. (The tick ring is drawn by the caller either way.)
    const a = std.math.degreesToRadians(-sweep_deg + std.math.clamp(value, 0.0, 1.0) * (2.0 * sweep_deg));
    const dx = std.math.sin(a);
    const dy = -std.math.cos(a);
    gl.glLineWidth(3.5);
    color(theme.cream.r, theme.cream.g, theme.cream.b, 255);
    gl.glBegin(gl.GL_LINES);
    gl.glVertex2f(cx + dx * r * 0.12, cy + dy * r * 0.12);
    gl.glVertex2f(cx + dx * cap * 0.98, cy + dy * cap * 0.98);
    gl.glEnd();
    gl.glLineWidth(1.0);
    discFlat(cx + dx * cap * 0.98, cy + dy * cap * 0.98, 2.6, theme.cream.r, theme.cream.g, theme.cream.b, 255);
}
