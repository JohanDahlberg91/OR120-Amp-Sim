//! GL texture loading and textured-quad drawing for the baked GUI assets.
//!
//! The PNGs produced by `tools/bake_assets` are embedded in the plugin binary,
//! so the `.clap` stays a single self-contained file with no install-time asset
//! directory to go missing. They are decoded with stb_image and uploaded once
//! per GL context.
//!
//! Lifetime matters here: `Gui.setParent` tears down and re-creates the GL
//! context (a host may re-parent the editor), and texture names live in the
//! context. So a `Set` is owned by the `Gui` and re-created alongside the
//! context rather than cached in a global.

const std = @import("std");
const gl = @import("gl.zig");

const knob_png = @embedFile("knob_png");
const tolex_png = @embedFile("tolex_png");

extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

/// Frame grid of `assets/knob.png`. Must match the constants in the baker.
pub const knob_frames = 128;
pub const knob_cols = 16;
pub const knob_rows = knob_frames / knob_cols;

pub const Texture = struct {
    id: gl.GLuint = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn valid(self: Texture) bool {
        return self.id != 0;
    }
};

/// Decode a PNG from memory and upload it as an RGBA texture.
fn upload(png: []const u8, wrap: gl.GLint) ?Texture {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &comp, 4) orelse return null;
    defer stbi_image_free(pixels);
    if (w <= 0 or h <= 0) return null;

    var id: gl.GLuint = 0;
    gl.glGenTextures(1, @ptrCast(&id));
    if (id == 0) return null;

    gl.glBindTexture(gl.GL_TEXTURE_2D, id);
    // Rows are tightly packed 4-byte RGBA, but be explicit — the default is 4
    // and a stale value from elsewhere would shear the image.
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels);
    // No mipmaps: GL 1.1 has no glGenerateMipmap, and the assets are drawn close
    // enough to 1:1 that bilinear minification is clean. It also avoids frames
    // of the knob atlas bleeding into each other at coarse mip levels.
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, wrap);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, wrap);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);

    return .{ .id = id, .width = w, .height = h };
}

/// All textures the panel needs, tied to one GL context.
pub const Set = struct {
    knob: Texture = .{},
    tolex: Texture = .{},

    /// Upload every asset into the current GL context. Missing textures degrade
    /// to the procedural fallbacks in decor.zig rather than failing the GUI.
    pub fn load() Set {
        return .{
            .knob = upload(knob_png, gl.GL_CLAMP_TO_EDGE) orelse .{},
            .tolex = upload(tolex_png, gl.GL_REPEAT) orelse .{},
        };
    }

    pub fn unload(self: *Set) void {
        inline for (.{ &self.knob, &self.tolex }) |tex| {
            if (tex.id != 0) {
                gl.glDeleteTextures(1, @ptrCast(&tex.id));
                tex.id = 0;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// Draw `tex` into the screen-space rect with explicit UVs. `alpha` scales the
/// texture's own alpha (GL_MODULATE against the current colour).
pub fn drawQuadUv(
    tex: Texture,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    s0: f32,
    t0: f32,
    s1: f32,
    t1: f32,
    alpha: f32,
) void {
    if (!tex.valid()) return;
    gl.glEnable(gl.GL_TEXTURE_2D);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex.id);
    gl.glTexEnvi(gl.GL_TEXTURE_ENV, gl.GL_TEXTURE_ENV_MODE, gl.GL_MODULATE);
    gl.glColor4f(1.0, 1.0, 1.0, alpha);
    gl.glBegin(gl.GL_QUADS);
    gl.glTexCoord2f(s0, t0);
    gl.glVertex2f(x, y);
    gl.glTexCoord2f(s1, t0);
    gl.glVertex2f(x + w, y);
    gl.glTexCoord2f(s1, t1);
    gl.glVertex2f(x + w, y + h);
    gl.glTexCoord2f(s0, t1);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    gl.glDisable(gl.GL_TEXTURE_2D);
}

/// Draw the whole texture into a rect.
pub fn drawQuad(tex: Texture, x: f32, y: f32, w: f32, h: f32, alpha: f32) void {
    drawQuadUv(tex, x, y, w, h, 0, 0, 1, 1, alpha);
}

/// Fill a rect by repeating `tex` at `scale` pixels per texel. Relies on
/// GL_REPEAT, so only valid for textures uploaded with that wrap mode.
pub fn drawTiled(tex: Texture, x: f32, y: f32, w: f32, h: f32, scale: f32) void {
    if (!tex.valid()) return;
    const tw = @as(f32, @floatFromInt(tex.width)) * scale;
    const th = @as(f32, @floatFromInt(tex.height)) * scale;
    drawQuadUv(tex, x, y, w, h, 0, 0, w / tw, h / th, 1.0);
}

/// Draw frame `value` (0..1) of the knob filmstrip centred on (cx, cy).
///
/// UVs are inset by half a texel so bilinear filtering cannot sample across a
/// frame boundary and drag in a sliver of the neighbouring rotation.
pub fn drawKnobFrame(tex: Texture, cx: f32, cy: f32, radius: f32, value: f32) void {
    if (!tex.valid()) return;
    const v = std.math.clamp(value, 0.0, 1.0);
    const frame: usize = @intFromFloat(@round(v * @as(f32, knob_frames - 1)));
    const col = frame % knob_cols;
    const row = frame / knob_cols;

    const fw = 1.0 / @as(f32, knob_cols);
    const fh = 1.0 / @as(f32, knob_rows);
    const half_texel_u = 0.5 / @as(f32, @floatFromInt(tex.width));
    const half_texel_v = 0.5 / @as(f32, @floatFromInt(tex.height));

    const s0 = @as(f32, @floatFromInt(col)) * fw + half_texel_u;
    const t0 = @as(f32, @floatFromInt(row)) * fh + half_texel_v;
    const s1 = s0 + fw - 2.0 * half_texel_u;
    const t1 = t0 + fh - 2.0 * half_texel_v;

    // The baked frame reserves margin around the knob for its contact shadow,
    // so the quad is drawn larger than the nominal body radius.
    const half = radius / body_fraction;
    drawQuadUv(tex, cx - half, cy - half, half * 2.0, half * 2.0, s0, t0, s1, t1, 1.0);
}

/// Fraction of the baked frame's half-extent occupied by the knob body. Must
/// match `r_skirt` in the baker so `radius` still means the visible body radius.
const body_fraction: f32 = 0.82;
