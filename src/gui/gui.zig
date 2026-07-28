//! GUI backend: a Win32 child window with a legacy OpenGL context that renders
//! the Clay-declared OR120 panel on a timer. This module owns all windowing and
//! rendering state; the CLAP `clap.gui` vtable in clap_plugin.zig drives it.

const std = @import("std");
const win32 = @import("win32.zig");
const gl = @import("gl.zig");
const clay = @import("clay.zig");
const renderer = @import("renderer.zig");
const decor = @import("decor.zig");
const panel = @import("panel.zig");
const font = @import("font.zig");
const params = @import("../params.zig");
const c_abi = @import("../c.zig");
const c = clay.c;

pub const default_width: u32 = 720;
pub const default_height: u32 = 300;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("OR120AmpSimGLWindow");
const timer_id: usize = 1;

var class_registered: bool = false;

/// The plugin-side hooks the GUI needs: the shared parameter store, a queue for
/// forwarding GUI edits to the host, and a callback that asks the host to flush
/// output parameter events even while audio is stopped.
pub const Bridge = struct {
    state: *params.State,
    queue: *params.ChangeQueue,
    request_flush_ctx: ?*anyopaque = null,
    request_flush_fn: ?*const fn (?*anyopaque) void = null,

    fn requestFlush(self: Bridge) void {
        if (self.request_flush_fn) |f| f(self.request_flush_ctx);
    }
};

/// Vertical drag distance (pixels) that sweeps a knob across its full range.
const drag_full_range_px: f32 = 220.0;

pub const Gui = struct {
    allocator: std.mem.Allocator,
    bridge: Bridge,

    hwnd: win32.HWND = null,
    hdc: win32.HDC = null,
    hglrc: win32.HGLRC = null,

    clay_memory: []u8 = &.{},
    clay_ctx: ?*c.Clay_Context = null,

    width: u32 = default_width,
    height: u32 = default_height,

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,

    // Knob interaction state.
    knob_boxes: [params.count]clay.BoundingBox = [_]clay.BoundingBox{.{ .x = 0, .y = 0, .width = 0, .height = 0 }} ** params.count,
    dragging: ?usize = null,
    drag_start_y: f32 = 0,
    drag_start_norm: f32 = 0,

    pub fn create(allocator: std.mem.Allocator, bridge: Bridge) !*Gui {
        const self = try allocator.create(Gui);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .bridge = bridge };

        // Set up Clay with its own arena and a text-measurement callback.
        // Clay sizes its internal arrays from the max element count (default
        // 8192, needing several MB) independent of the buffer we hand it, so we
        // cap the count for this small panel and then allocate exactly the size
        // Clay reports it requires. Passing a smaller buffer lets layout overrun
        // it and corrupt the heap — which crashes the host when the GUI opens.
        c.Clay_SetMaxElementCount(1024);
        const arena_size = c.Clay_MinMemorySize();
        self.clay_memory = try allocator.alloc(u8, arena_size);
        const arena = c.Clay_CreateArenaWithCapacityAndMemory(self.clay_memory.len, self.clay_memory.ptr);
        self.clay_ctx = c.Clay_Initialize(
            arena,
            .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) },
            .{ .errorHandlerFunction = clayError, .userData = null },
        );
        c.Clay_SetMeasureTextFunction(measureText, null);
        return self;
    }

    pub fn destroy(self: *Gui) void {
        self.teardownWindow();
        // Clay tracks the "current" context in a single global pointer that
        // lives inside our arena. Freeing the arena would leave that global
        // dangling, so a later Gui.create() (e.g. when the host re-opens the
        // editor) would have Clay_SetMaxElementCount/Clay_MinMemorySize touch
        // freed memory and crash. Clear it if it still points at us.
        if (self.clay_ctx != null and c.Clay_GetCurrentContext() == self.clay_ctx) {
            c.Clay_SetCurrentContext(null);
        }
        self.clay_ctx = null;
        if (self.clay_memory.len != 0) self.allocator.free(self.clay_memory);
        self.allocator.destroy(self);
    }

    pub fn getSize(self: *Gui, width: *u32, height: *u32) void {
        width.* = self.width;
        height.* = self.height;
    }

    pub fn setSize(self: *Gui, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowPos(hwnd, null, 0, 0, @intCast(width), @intCast(height), win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        }
        if (self.clay_ctx) |ctx| {
            c.Clay_SetCurrentContext(ctx);
            c.Clay_SetLayoutDimensions(.{ .width = @floatFromInt(width), .height = @floatFromInt(height) });
        }
    }

    /// Create the child window under `parent` and bring up its GL context.
    pub fn setParent(self: *Gui, parent: win32.HWND) bool {
        // Be idempotent: a host may call set_parent again without destroying the
        // GUI first. Tear down any previous window/GL state before re-creating.
        self.teardownWindow();
        registerClass();

        const hwnd = win32.CreateWindowExW(
            0,
            class_name,
            null,
            win32.WS_CHILD | win32.WS_VISIBLE | win32.WS_CLIPSIBLINGS | win32.WS_CLIPCHILDREN,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            parent,
            null,
            win32.GetModuleHandleW(null),
            null,
        );
        if (hwnd == null) return false;
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        if (!self.initGl()) {
            self.teardownWindow();
            return false;
        }
        _ = win32.SetTimer(hwnd, timer_id, 16, null);
        return true;
    }

    pub fn show(self: *Gui) void {
        if (self.hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    }

    pub fn hide(self: *Gui) void {
        if (self.hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
    }

    fn initGl(self: *Gui) bool {
        const hdc = win32.GetDC(self.hwnd);
        if (hdc == null) return false;
        self.hdc = hdc;

        var pfd = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = win32.PFD_DRAW_TO_WINDOW | win32.PFD_SUPPORT_OPENGL | win32.PFD_DOUBLEBUFFER;
        pfd.iPixelType = win32.PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cAlphaBits = 8;
        pfd.cDepthBits = 24;
        pfd.iLayerType = win32.PFD_MAIN_PLANE;

        const pf = win32.ChoosePixelFormat(hdc, &pfd);
        if (pf == 0) return false;
        if (win32.SetPixelFormat(hdc, pf, &pfd) == 0) return false;

        const rc = win32.wglCreateContext(hdc);
        if (rc == null) return false;
        self.hglrc = rc;
        _ = win32.wglMakeCurrent(hdc, rc);
        return true;
    }

    fn teardownWindow(self: *Gui) void {
        if (self.hwnd) |hwnd| _ = win32.KillTimer(hwnd, timer_id);
        _ = win32.wglMakeCurrent(null, null);
        if (self.hglrc) |rc| _ = win32.wglDeleteContext(rc);
        if (self.hdc) |hdc| _ = win32.ReleaseDC(self.hwnd, hdc);
        if (self.hwnd) |hwnd| _ = win32.DestroyWindow(hwnd);
        self.hglrc = null;
        self.hdc = null;
        self.hwnd = null;
    }

    fn renderFrame(self: *Gui) void {
        if (self.hdc == null or self.hglrc == null or self.clay_ctx == null) return;
        _ = win32.wglMakeCurrent(self.hdc, self.hglrc);

        c.Clay_SetCurrentContext(self.clay_ctx);
        c.Clay_SetLayoutDimensions(.{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) });
        c.Clay_SetPointerState(.{ .x = self.mouse_x, .y = self.mouse_y }, self.mouse_down);
        c.Clay_BeginLayout();

        var values: [params.count]f32 = undefined;
        for (0..params.count) |i| {
            const id: params.ParamId = @enumFromInt(i);
            const d = params.descriptors[i];
            const span: f64 = d.max - d.min;
            const raw: f64 = self.bridge.state.get(id);
            values[i] = if (span > 0) @floatCast((raw - d.min) / span) else 0;
        }
        panel.build();

        const commands = c.Clay_EndLayout();

        // Cache each knob's bounding box for hit-testing on the next click.
        for (0..params.count) |i| {
            const data = c.Clay_GetElementData(panel.knobId(i));
            if (data.found) self.knob_boxes[i] = data.boundingBox;
        }

        gl.glClearColor(0.06, 0.05, 0.04, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        decor.drawTolexBackground(@intCast(self.width), @intCast(self.height));
        renderer.render(commands, @intCast(self.width), @intCast(self.height));

        // Knob overlay: draw the shaded knob into each cached box on top of the
        // Clay pass (which left the top-left ortho projection in place).
        for (0..params.count) |i| {
            const b = self.knob_boxes[i];
            if (b.width <= 0) continue;
            const cx = b.x + b.width * 0.5;
            const cy = b.y + b.height * 0.5;
            const r = @min(b.width, b.height) * 0.5 - 2.0;
            decor.drawKnob(cx, cy, r, values[i], panel.tickCount(i));
        }

        _ = win32.SwapBuffers(self.hdc);
    }

    /// Return the index of the knob whose cached box contains (x, y), if any.
    fn hitTest(self: *Gui, x: f32, y: f32) ?usize {
        for (self.knob_boxes, 0..) |b, i| {
            if (x >= b.x and x <= b.x + b.width and y >= b.y and y <= b.y + b.height) return i;
        }
        return null;
    }

    /// Current normalised (0..1) value of parameter `index`.
    fn normalizedValue(self: *Gui, index: usize) f32 {
        const d = params.descriptors[index];
        const span: f64 = d.max - d.min;
        const raw: f64 = self.bridge.state.get(@enumFromInt(index));
        return if (span > 0) @floatCast((raw - d.min) / span) else 0;
    }

    /// Begin dragging the knob under the pointer, if there is one.
    fn beginDrag(self: *Gui, x: f32, y: f32) void {
        const index = self.hitTest(x, y) orelse return;
        self.dragging = index;
        self.drag_start_y = y;
        self.drag_start_norm = self.normalizedValue(index);
        if (self.hwnd) |hwnd| _ = win32.SetCapture(hwnd);
        self.bridge.queue.push(.{ .id = @intCast(index), .kind = .gesture_begin });
        self.bridge.requestFlush();
    }

    /// Update the dragged knob from the current pointer position.
    fn updateDrag(self: *Gui, y: f32) void {
        const index = self.dragging orelse return;
        const d = params.descriptors[index];
        const delta = (self.drag_start_y - y) / drag_full_range_px;
        const norm = std.math.clamp(self.drag_start_norm + delta, 0.0, 1.0);
        var raw: f64 = d.min + @as(f64, norm) * (d.max - d.min);
        if ((d.flags & c_abi.clap.CLAP_PARAM_IS_STEPPED) != 0) raw = @round(raw);
        self.bridge.state.setRaw(@intCast(index), raw);
        self.bridge.queue.push(.{ .id = @intCast(index), .kind = .value, .value = raw });
        self.bridge.requestFlush();
    }

    /// Finish the active drag, if any.
    fn endDrag(self: *Gui) void {
        const index = self.dragging orelse return;
        self.dragging = null;
        _ = win32.ReleaseCapture();
        self.bridge.queue.push(.{ .id = @intCast(index), .kind = .gesture_end });
        self.bridge.requestFlush();
    }
};

fn registerClass() void {
    if (class_registered) return;
    var wc = std.mem.zeroes(win32.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win32.WNDCLASSEXW);
    wc.style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = win32.GetModuleHandleW(null);
    wc.lpszClassName = class_name;
    _ = win32.RegisterClassExW(&wc);
    class_registered = true;
}

fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(win32.WINAPI) win32.LRESULT {
    const raw = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (raw != 0) {
        const self: *Gui = @ptrFromInt(@as(usize, @bitCast(raw)));
        switch (msg) {
            win32.WM_TIMER => {
                self.renderFrame();
                return 0;
            },
            win32.WM_MOUSEMOVE => {
                self.mouse_x = @floatFromInt(loWord(lparam));
                self.mouse_y = @floatFromInt(hiWord(lparam));
                if (self.dragging != null) self.updateDrag(self.mouse_y);
                return 0;
            },
            win32.WM_LBUTTONDOWN => {
                self.mouse_down = true;
                self.mouse_x = @floatFromInt(loWord(lparam));
                self.mouse_y = @floatFromInt(hiWord(lparam));
                self.beginDrag(self.mouse_x, self.mouse_y);
                return 0;
            },
            win32.WM_LBUTTONUP => {
                self.mouse_down = false;
                self.endDrag();
                return 0;
            },
            else => {},
        }
    }
    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Extract the signed low 16 bits of an LPARAM (mouse x).
fn loWord(lp: win32.LPARAM) i32 {
    const v: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp)) & 0xFFFF)));
    return v;
}

/// Extract the signed high 16 bits of an LPARAM (mouse y).
fn hiWord(lp: win32.LPARAM) i32 {
    const v: i16 = @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lp)) >> 16) & 0xFFFF)));
    return v;
}

fn measureText(text: c.Clay_StringSlice, config: [*c]c.Clay_TextElementConfig, user_data: ?*anyopaque) callconv(.c) c.Clay_Dimensions {
    _ = user_data;
    const chars = text.chars[0..@intCast(text.length)];
    const size: f32 = @floatFromInt(config.*.fontSize);
    return font.measure(chars, size);
}

fn clayError(data: c.Clay_ErrorData) callconv(.c) void {
    _ = data;
}
