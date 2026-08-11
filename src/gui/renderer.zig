//! Translates the Clay render-command array into legacy OpenGL draw calls.
//!
//! Handles solid and rounded rectangles, plain and rounded borders, scissor
//! clipping, text (drawn with the vector stroke font) and images. Custom
//! commands are ignored.
//!
//! Image elements carry their `texture.Texture` through Clay's opaque
//! `imageData` pointer, so a layout can place baked art the same way it places
//! a rectangle. Whoever declares the element owns the texture and must keep it
//! alive for the frame.

const std = @import("std");
const gl = @import("gl.zig");
const clay = @import("clay.zig");
const font = @import("font.zig");
const texture = @import("texture.zig");
const c = clay.c;

const arc_segments = 6;

fn setColor(color: clay.Color) void {
    gl.glColor4f(color.r / 255.0, color.g / 255.0, color.b / 255.0, color.a / 255.0);
}

fn fillRect(x: f32, y: f32, w: f32, h: f32) void {
    gl.glBegin(gl.GL_QUADS);
    gl.glVertex2f(x, y);
    gl.glVertex2f(x + w, y);
    gl.glVertex2f(x + w, y + h);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
}

/// Largest corner radius, clamped so opposing corners never overlap.
fn clampRadius(r: c.Clay_CornerRadius, w: f32, h: f32) c.Clay_CornerRadius {
    const limit = @min(w, h) * 0.5;
    return .{
        .topLeft = @min(r.topLeft, limit),
        .topRight = @min(r.topRight, limit),
        .bottomLeft = @min(r.bottomLeft, limit),
        .bottomRight = @min(r.bottomRight, limit),
    };
}

fn anyRadius(r: c.Clay_CornerRadius) bool {
    return r.topLeft > 0 or r.topRight > 0 or r.bottomLeft > 0 or r.bottomRight > 0;
}

/// Emit an arc of `radius` about (cx, cy) from `a0` to `a1` radians as vertices.
fn arcVerts(cx: f32, cy: f32, radius: f32, a0: f32, a1: f32) void {
    var i: usize = 0;
    while (i <= arc_segments) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, arc_segments);
        const a = a0 + (a1 - a0) * t;
        gl.glVertex2f(cx + std.math.cos(a) * radius, cy + std.math.sin(a) * radius);
    }
}

/// Trace the rounded-rectangle outline (screen space, y down) as vertices.
fn roundedOutline(x: f32, y: f32, w: f32, h: f32, r: c.Clay_CornerRadius) void {
    const pi = std.math.pi;
    // Top-left, top-right, bottom-right, bottom-left arcs, in order.
    arcVerts(x + r.topLeft, y + r.topLeft, r.topLeft, pi, pi * 1.5);
    arcVerts(x + w - r.topRight, y + r.topRight, r.topRight, pi * 1.5, pi * 2.0);
    arcVerts(x + w - r.bottomRight, y + h - r.bottomRight, r.bottomRight, 0.0, pi * 0.5);
    arcVerts(x + r.bottomLeft, y + h - r.bottomLeft, r.bottomLeft, pi * 0.5, pi);
}

fn fillRounded(x: f32, y: f32, w: f32, h: f32, radius: c.Clay_CornerRadius) void {
    const r = clampRadius(radius, w, h);
    if (!anyRadius(r)) {
        fillRect(x, y, w, h);
        return;
    }
    gl.glBegin(gl.GL_TRIANGLE_FAN);
    gl.glVertex2f(x + w * 0.5, y + h * 0.5);
    roundedOutline(x, y, w, h, r);
    // Close the fan back to the first outline vertex (top-left arc start).
    gl.glVertex2f(x, y + r.topLeft);
    gl.glEnd();
}

/// Draw a rounded border by stroking the outline with a thick line loop.
fn strokeRounded(x: f32, y: f32, w: f32, h: f32, radius: c.Clay_CornerRadius, width: f32) void {
    const r = clampRadius(radius, w, h);
    const inset = width * 0.5;
    gl.glLineWidth(@max(width, 1.0));
    gl.glBegin(gl.GL_LINE_LOOP);
    roundedOutline(x + inset, y + inset, w - width, h - width, r);
    gl.glEnd();
    gl.glLineWidth(1.0);
}

/// Draw one frame worth of Clay commands. `fb_width`/`fb_height` are the pixel
/// dimensions of the framebuffer, used to set the projection and to flip
/// scissor rectangles into OpenGL's bottom-left origin.
pub fn render(commands: clay.RenderCommandArray, fb_width: i32, fb_height: i32) void {
    gl.glViewport(0, 0, fb_width, fb_height);
    gl.glMatrixMode(gl.GL_PROJECTION);
    gl.glLoadIdentity();
    // Top-left origin, y increasing downward — matches Clay's coordinate space.
    gl.glOrtho(0.0, @floatFromInt(fb_width), @floatFromInt(fb_height), 0.0, -1.0, 1.0);
    gl.glMatrixMode(gl.GL_MODELVIEW);
    gl.glLoadIdentity();

    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_LINE_SMOOTH);
    gl.glHint(gl.GL_LINE_SMOOTH_HINT, gl.GL_NICEST);

    var i: i32 = 0;
    while (i < commands.length) : (i += 1) {
        const cmd = c.Clay_RenderCommandArray_Get(@constCast(&commands), i);
        const bb = cmd.*.boundingBox;
        switch (cmd.*.commandType) {
            c.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const rd = cmd.*.renderData.rectangle;
                setColor(rd.backgroundColor);
                fillRounded(bb.x, bb.y, bb.width, bb.height, rd.cornerRadius);
            },
            c.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const bd = cmd.*.renderData.border;
                setColor(bd.color);
                if (anyRadius(clampRadius(bd.cornerRadius, bb.width, bb.height))) {
                    const wmax: f32 = @floatFromInt(@max(@max(bd.width.left, bd.width.right), @max(bd.width.top, bd.width.bottom)));
                    strokeRounded(bb.x, bb.y, bb.width, bb.height, bd.cornerRadius, wmax);
                } else {
                    const wl: f32 = @floatFromInt(bd.width.left);
                    const wr: f32 = @floatFromInt(bd.width.right);
                    const wt: f32 = @floatFromInt(bd.width.top);
                    const wb: f32 = @floatFromInt(bd.width.bottom);
                    if (wt > 0) fillRect(bb.x, bb.y, bb.width, wt);
                    if (wb > 0) fillRect(bb.x, bb.y + bb.height - wb, bb.width, wb);
                    if (wl > 0) fillRect(bb.x, bb.y, wl, bb.height);
                    if (wr > 0) fillRect(bb.x + bb.width - wr, bb.y, wr, bb.height);
                }
            },
            c.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const td = cmd.*.renderData.text;
                setColor(td.textColor);
                const size: f32 = @floatFromInt(td.fontSize);
                gl.glLineWidth(@max(size / 14.0, 1.2));
                const chars = td.stringContents.chars[0..@intCast(td.stringContents.length)];
                font.draw(chars, bb.x, bb.y, size);
                gl.glLineWidth(1.0);
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                gl.glEnable(gl.GL_SCISSOR_TEST);
                const sy = fb_height - @as(i32, @intFromFloat(bb.y + bb.height));
                gl.glScissor(
                    @intFromFloat(bb.x),
                    sy,
                    @intFromFloat(bb.width),
                    @intFromFloat(bb.height),
                );
            },
            c.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => {
                gl.glDisable(gl.GL_SCISSOR_TEST);
            },
            c.CLAY_RENDER_COMMAND_TYPE_IMAGE => {
                const id = cmd.*.renderData.image;
                // `imageData` is an opaque user pointer; we always store a
                // *const texture.Texture there. A null means the element was
                // declared without art, so there is simply nothing to draw.
                const raw = id.imageData orelse continue;
                const tex: *const texture.Texture = @ptrCast(@alignCast(raw));
                const tint = id.backgroundColor;
                // A zeroed backgroundColor means "no tint" rather than
                // "transparent" — Clay leaves it zeroed unless it is set.
                const alpha: f32 = if (tint.a == 0) 1.0 else tint.a / 255.0;
                texture.drawQuad(tex.*, bb.x, bb.y, bb.width, bb.height, alpha);
            },
            else => {
                // CUSTOM: not drawn.
            },
        }
    }

    gl.glDisable(gl.GL_SCISSOR_TEST);
    gl.glFlush();
}
