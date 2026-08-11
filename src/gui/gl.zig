//! Minimal legacy OpenGL 1.1 bindings. These entry points are exported directly
//! by `opengl32.dll`, so no extension loader is required. Immediate-mode drawing
//! (glBegin/glEnd) is enough for the flat rectangles and borders Clay emits.

const std = @import("std");
const WINAPI: std.builtin.CallingConvention = .winapi;

pub const GLenum = c_uint;
pub const GLbitfield = c_uint;
pub const GLint = c_int;
pub const GLuint = c_uint;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLdouble = f64;
pub const GLubyte = u8;

pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_POINTS: GLenum = 0x0000;
pub const GL_LINES: GLenum = 0x0001;
pub const GL_LINE_LOOP: GLenum = 0x0002;
pub const GL_LINE_STRIP: GLenum = 0x0003;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_TRIANGLE_FAN: GLenum = 0x0006;
pub const GL_QUADS: GLenum = 0x0007;
pub const GL_PROJECTION: GLenum = 0x1701;
pub const GL_MODELVIEW: GLenum = 0x1700;
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_SCISSOR_TEST: GLenum = 0x0C11;
pub const GL_MULTISAMPLE: GLenum = 0x809D;
pub const GL_LINE_SMOOTH: GLenum = 0x0B20;
pub const GL_POLYGON_SMOOTH: GLenum = 0x0B41;
pub const GL_LINE_SMOOTH_HINT: GLenum = 0x0C52;
pub const GL_POLYGON_SMOOTH_HINT: GLenum = 0x0C53;
pub const GL_NICEST: GLenum = 0x1102;

// --- Texturing (all GL 1.1, exported directly by opengl32.dll) --------------
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_NEAREST: GLint = 0x2600;
pub const GL_LINEAR: GLint = 0x2601;
pub const GL_REPEAT: GLint = 0x2901;
/// GL 1.2, but present on every real driver. The software fallback renderer is
/// the only thing that lacks it, and it cannot run this GUI anyway.
pub const GL_CLAMP_TO_EDGE: GLint = 0x812F;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
pub const GL_TEXTURE_ENV: GLenum = 0x2300;
pub const GL_TEXTURE_ENV_MODE: GLenum = 0x2200;
pub const GL_MODULATE: GLint = 0x2100;

pub extern "opengl32" fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei) callconv(WINAPI) void;
pub extern "opengl32" fn glClearColor(r: GLfloat, g: GLfloat, b: GLfloat, a: GLfloat) callconv(WINAPI) void;
pub extern "opengl32" fn glClear(mask: GLbitfield) callconv(WINAPI) void;
pub extern "opengl32" fn glMatrixMode(mode: GLenum) callconv(WINAPI) void;
pub extern "opengl32" fn glLoadIdentity() callconv(WINAPI) void;
pub extern "opengl32" fn glOrtho(l: GLdouble, r: GLdouble, b: GLdouble, t: GLdouble, n: GLdouble, f: GLdouble) callconv(WINAPI) void;
pub extern "opengl32" fn glBegin(mode: GLenum) callconv(WINAPI) void;
pub extern "opengl32" fn glEnd() callconv(WINAPI) void;
pub extern "opengl32" fn glColor4f(r: GLfloat, g: GLfloat, b: GLfloat, a: GLfloat) callconv(WINAPI) void;
pub extern "opengl32" fn glVertex2f(x: GLfloat, y: GLfloat) callconv(WINAPI) void;
pub extern "opengl32" fn glEnable(cap: GLenum) callconv(WINAPI) void;
pub extern "opengl32" fn glDisable(cap: GLenum) callconv(WINAPI) void;
pub extern "opengl32" fn glBlendFunc(sfactor: GLenum, dfactor: GLenum) callconv(WINAPI) void;
pub extern "opengl32" fn glScissor(x: GLint, y: GLint, width: GLsizei, height: GLsizei) callconv(WINAPI) void;
pub extern "opengl32" fn glLineWidth(width: GLfloat) callconv(WINAPI) void;
pub extern "opengl32" fn glHint(target: GLenum, mode: GLenum) callconv(WINAPI) void;
pub extern "opengl32" fn glFlush() callconv(WINAPI) void;
pub extern "opengl32" fn glGenTextures(n: GLsizei, textures: [*]GLuint) callconv(WINAPI) void;
pub extern "opengl32" fn glDeleteTextures(n: GLsizei, textures: [*]const GLuint) callconv(WINAPI) void;
pub extern "opengl32" fn glBindTexture(target: GLenum, texture: GLuint) callconv(WINAPI) void;
pub extern "opengl32" fn glTexImage2D(
    target: GLenum,
    level: GLint,
    internalformat: GLint,
    width: GLsizei,
    height: GLsizei,
    border: GLint,
    format: GLenum,
    type_: GLenum,
    pixels: ?*const anyopaque,
) callconv(WINAPI) void;
pub extern "opengl32" fn glTexParameteri(target: GLenum, pname: GLenum, param: GLint) callconv(WINAPI) void;
pub extern "opengl32" fn glTexEnvi(target: GLenum, pname: GLenum, param: GLint) callconv(WINAPI) void;
pub extern "opengl32" fn glTexCoord2f(s: GLfloat, t: GLfloat) callconv(WINAPI) void;
pub extern "opengl32" fn glPixelStorei(pname: GLenum, param: GLint) callconv(WINAPI) void;
