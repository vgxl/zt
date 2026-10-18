//! Minimal Win32 platform helpers shared by the Windows backend, the ConPTY
//! process layer, and the POSIX compatibility shim.
//!
//! The actual bindings are produced by `addTranslateC` from `src/c_windows.h`
//! and imported as the `c_windows` module (see build.zig). This file only adds
//! the handful of helpers zt needs on top of the raw API.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("c_windows");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows.zig is only available on Windows targets");
    }
}

pub const HANDLE = c.HANDLE;

/// `MsgWaitForMultipleObjectsEx` wake mask: all posted messages, input, and
/// timers. Matches the traditional `QS_ALLINPUT`.
pub const QS_ALLINPUT: c.DWORD = 0x04FF;
/// `MsgWaitForMultipleObjectsEx` flag: return for messages already in the queue
/// instead of only for newly posted ones.
pub const MWMO_INPUTAVAILABLE: c.DWORD = 0x0004;
pub const INFINITE: c.DWORD = 0xFFFF_FFFF;

var qpc_frequency: i64 = 0;

/// Monotonic nanoseconds from QueryPerformanceCounter. The absolute origin is
/// arbitrary; zt only uses deltas.
pub fn nanoTimestamp() i128 {
    if (qpc_frequency == 0) {
        var freq: c.LARGE_INTEGER = undefined;
        if (c.QueryPerformanceFrequency(&freq) == 0) return 0;
        qpc_frequency = freq.QuadPart;
    }
    var counter: c.LARGE_INTEGER = undefined;
    if (c.QueryPerformanceCounter(&counter) == 0) return 0;
    const ticks = counter.QuadPart;
    return @divTrunc(@as(i128, ticks) * std.time.ns_per_s, @as(i128, qpc_frequency));
}

/// Block the calling thread for at least `nanoseconds`.
pub fn sleep(nanoseconds: u64) void {
    const ms64 = (nanoseconds + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    const ms: u32 = @intCast(@min(ms64, @as(u64, std.math.maxInt(u32))));
    c.Sleep(ms);
}

/// Convert UTF-16 to UTF-8, truncating at a code-point boundary when the
/// destination is too small. Returns a slice of `buf`.
pub fn utf16ToUtf8(buf: []u8, utf16: []const u16) []const u8 {
    if (utf16.len == 0 or buf.len == 0) return buf[0..0];
    const needed = c.WideCharToMultiByte(
        c.CP_UTF8,
        0,
        utf16.ptr,
        @intCast(utf16.len),
        null,
        0,
        null,
        null,
    );
    if (needed <= 0) return buf[0..0];
    const cap: c_int = @intCast(@min(buf.len, @as(usize, @intCast(needed))));
    const written = c.WideCharToMultiByte(
        c.CP_UTF8,
        0,
        utf16.ptr,
        @intCast(utf16.len),
        @ptrCast(buf.ptr),
        cap,
        null,
        null,
    );
    if (written <= 0) return buf[0..0];
    return buf[0..@intCast(written)];
}

/// Convert UTF-8 to UTF-16, truncating when the destination is too small.
pub fn utf8ToUtf16(buf: []u16, utf8: []const u8) []const u16 {
    if (utf8.len == 0 or buf.len == 0) return buf[0..0];
    const needed = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        utf8.ptr,
        @intCast(utf8.len),
        null,
        0,
    );
    if (needed <= 0) return buf[0..0];
    const cap: c_int = @intCast(@min(buf.len, @as(usize, @intCast(needed))));
    const written = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        utf8.ptr,
        @intCast(utf8.len),
        @ptrCast(buf.ptr),
        cap,
    );
    if (written <= 0) return buf[0..0];
    return buf[0..@intCast(written)];
}

/// Allocate a NUL-terminated UTF-16 string. Caller owns the memory.
pub fn utf8ToUtf16Alloc(allocator: std.mem.Allocator, utf8: []const u8) ![:0]u16 {
    if (utf8.len == 0) return try allocator.allocSentinel(u16, 0, 0);
    const needed = c.MultiByteToWideChar(c.CP_UTF8, 0, utf8.ptr, @intCast(utf8.len), null, 0);
    if (needed <= 0) return error.InvalidUtf8;
    const out = try allocator.allocSentinel(u16, @intCast(needed), 0);
    errdefer allocator.free(out);
    const written = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        utf8.ptr,
        @intCast(utf8.len),
        out.ptr,
        needed,
    );
    if (written != needed) return error.InvalidUtf8;
    return out;
}

threadlocal var env_buf: [32768]u8 = undefined;

/// Look up an environment variable through the Windows PEB (case-insensitive).
/// The returned slice is valid until the next call on the same thread.
pub fn getenv(key: []const u8) ?[]const u8 {
    if (!std.unicode.wtf8ValidateSlice(key)) return null;
    var key_buf: [256]u16 = undefined;
    const key_slice = utf8ToUtf16(&key_buf, key);
    if (key_slice.len == 0 or key_slice.len == key_buf.len) return null;
    key_buf[key_slice.len] = 0;
    const value = std.process.Environ.getWindows(.{ .block = .global }, key_buf[0..key_slice.len :0]) orelse return null;
    const utf8 = utf16ToUtf8(&env_buf, value);
    return utf8;
}

/// Write raw bytes to the process's standard error handle when one exists.
pub fn writeStderr(bytes: []const u8) void {
    const handle = c.GetStdHandle(c.STD_ERROR_HANDLE);
    if (handle == null or handle == c.INVALID_HANDLE_VALUE) return;
    var written: c.DWORD = 0;
    var rest = bytes;
    while (rest.len > 0) {
        const chunk: c.DWORD = @intCast(@min(rest.len, @as(usize, std.math.maxInt(c.DWORD))));
        if (c.WriteFile(handle, rest.ptr, chunk, &written, null) == 0) return;
        if (written == 0) return;
        rest = rest[written..];
    }
}

/// Format the last Win32 error for diagnostics.
pub fn errorName(code: c.DWORD) []const u8 {
    return switch (code) {
        c.ERROR_FILE_NOT_FOUND => "file not found",
        c.ERROR_PATH_NOT_FOUND => "path not found",
        c.ERROR_ACCESS_DENIED => "access denied",
        c.ERROR_INVALID_HANDLE => "invalid handle",
        c.ERROR_BROKEN_PIPE => "broken pipe",
        c.ERROR_PIPE_NOT_CONNECTED => "pipe not connected",
        c.ERROR_NOT_ENOUGH_MEMORY => "not enough memory",
        c.ERROR_INVALID_PARAMETER => "invalid parameter",
        else => "win32 error",
    };
}

/// Render an HRESULT as a friendly message for logs.
pub fn hresultOk(hr: c.HRESULT) bool {
    return hr >= 0;
}

/// Show a modal error dialog. The Windows build is GUI-subsystem, so stderr
/// may not exist; startup failures should not vanish silently.
pub fn messageBox(title: []const u8, body: []const u8) void {
    var title_buf: [128]u16 = undefined;
    var body_buf: [1024]u16 = undefined;
    const title_w = utf8ToUtf16(&title_buf, title);
    const body_w = utf8ToUtf16(&body_buf, body);
    if (title_w.len >= title_buf.len or body_w.len >= body_buf.len) return;
    title_buf[title_w.len] = 0;
    body_buf[body_w.len] = 0;
    _ = c.MessageBoxW(null, body_buf[0..body_w.len :0].ptr, title_buf[0..title_w.len :0].ptr, c.MB_OK | c.MB_ICONERROR);
}
