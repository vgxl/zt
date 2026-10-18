//! Native Windows backend: a Win32 window backed by a GDI DIB section, with
//! keyboard/mouse/IME input translated into the same event stream the X11,
//! Wayland, and Cocoa backends expose to main.zig.
//!
//! Rendering is software-only: the terminal core paints BGRA pixels into the
//! DIB (exactly like fbdev/SHM) and `present` blits the damaged rows to the
//! window.

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../windows.zig");
const c = windows.c;
const config = @import("config");
const input_mod = @import("../input.zig");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows.zig backend is only available on Windows targets");
    }
}

// =============================================================================
// Event types (shared with main.zig — keep in sync with macos.zig / x11.zig)
// =============================================================================

pub const MouseEvent = struct {
    x: u32,
    y: u32,
    button: Button,
    action: Action,
    modifiers: input_mod.Modifiers,

    pub const Button = enum(u3) {
        left = 0,
        middle = 1,
        right = 2,
        none = 3,
        wheel_up = 4,
        wheel_down = 5,
        wheel_left = 6,
        wheel_right = 7,
    };

    pub const Action = enum(u2) {
        press,
        release,
        motion,
    };
};

pub const PreeditEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,
    caret: u32 = 0,
    active: bool = false,
    feedback: [128]u8 = @splat(0),

    pub fn slice(self: *const PreeditEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    preedit: PreeditEvent,
    mouse: MouseEvent,
    copy_selection: void,
    new_window: void,
    paste: PasteEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
};

pub const PasteEvent = struct {
    ptr: [*]const u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const PasteEvent) []const u8 {
        if (self.len == 0) return &.{};
        return self.ptr[0..self.len];
    }
};

pub const TextEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const TextEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const KeyEvent = struct {
    keycode: u16,
    pressed: bool,
    modifiers: input_mod.Modifiers,
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

// =============================================================================
// Helpers
// =============================================================================

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zt-terminal-window");
const default_title = std.unicode.utf8ToUtf16LeStringLiteral("zt");

/// Single-window-per-process backend pointer used by the window procedure.
/// Set in postInit() once the struct has reached its final address.
var g_backend: ?*WindowsBackend = null;

fn lowordSigned(value: usize) i32 {
    const u: u16 = @truncate(value);
    return @as(i16, @bitCast(u));
}

fn hiword(value: usize) u16 {
    return @truncate(value >> 16);
}

fn keyDown(vk: i32) bool {
    return c.GetKeyState(vk) < 0;
}

fn currentModifiers() input_mod.Modifiers {
    return .{
        .shift = keyDown(c.VK_SHIFT),
        .ctrl = keyDown(c.VK_CONTROL),
        .alt = keyDown(c.VK_MENU),
        .meta = keyDown(c.VK_LWIN) or keyDown(c.VK_RWIN),
    };
}

fn isSpecialKey(kc: u16) bool {
    return switch (kc) {
        input_mod.KEY.ESC,
        input_mod.KEY.ENTER,
        input_mod.KEY.BACKSPACE,
        input_mod.KEY.TAB,
        input_mod.KEY.UP,
        input_mod.KEY.DOWN,
        input_mod.KEY.LEFT,
        input_mod.KEY.RIGHT,
        input_mod.KEY.HOME,
        input_mod.KEY.END,
        input_mod.KEY.PAGEUP,
        input_mod.KEY.PAGEDOWN,
        input_mod.KEY.INSERT,
        input_mod.KEY.DELETE,
        input_mod.KEY.F1,
        input_mod.KEY.F2,
        input_mod.KEY.F3,
        input_mod.KEY.F4,
        input_mod.KEY.F5,
        input_mod.KEY.F6,
        input_mod.KEY.F7,
        input_mod.KEY.F8,
        input_mod.KEY.F9,
        input_mod.KEY.F10,
        input_mod.KEY.F11,
        input_mod.KEY.F12,
        => true,
        else => false,
    };
}

// =============================================================================
// WindowsBackend
// =============================================================================

pub const WindowsBackend = struct {
    const Self = @This();
    const QUEUE_SIZE = 256;

    hwnd: c.HWND,
    hinstance: c.HINSTANCE,
    memdc: c.HDC,
    dib: c.HBITMAP,
    old_bitmap: c.HGDIOBJ,
    bits: [*]u8,
    buffer: []u8,
    width: u32,
    height: u32,
    stride: u32,

    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    event_queue: [QUEUE_SIZE]Event = undefined,
    event_head: u32 = 0,
    event_tail: u32 = 0,
    close_requested: bool = false,

    paste_buf_data: std.ArrayListUnmanaged(u8) = .empty,
    ime_x: u32 = 0,
    ime_y: u32 = config.cell_height,
    pending_high_surrogate: ?u16 = null,

    // =========================================================================
    // Construction
    // =========================================================================

    pub fn init() !Self {
        if (c.SetProcessDpiAwarenessContext(c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
            _ = c.SetProcessDPIAware();
        }

        const hinstance = c.GetModuleHandleW(null);

        var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
        wc.cbSize = @sizeOf(c.WNDCLASSEXW);
        wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinstance;
        wc.hCursor = null;
        wc.hbrBackground = null;
        wc.lpszClassName = class_name;
        if (c.RegisterClassExW(&wc) == 0) {
            const err = c.GetLastError();
            if (err != c.ERROR_CLASS_ALREADY_EXISTS) return error.RegisterClassFailed;
        }

        const client_w: u32 = 80 * config.cell_width;
        const client_h: u32 = 24 * config.cell_height;
        const style = c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN;
        var rect = c.RECT{ .left = 0, .top = 0, .right = @intCast(client_w), .bottom = @intCast(client_h) };
        _ = c.AdjustWindowRectEx(&rect, style, c.FALSE, 0);
        const win_w = rect.right - rect.left;
        const win_h = rect.bottom - rect.top;

        const hwnd = c.CreateWindowExW(
            0,
            class_name,
            default_title,
            style,
            c.CW_USEDEFAULT,
            c.CW_USEDEFAULT,
            win_w,
            win_h,
            null,
            null,
            hinstance,
            null,
        );
        if (hwnd == null) return error.CreateWindowFailed;

        var client_rect: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &client_rect);
        // Use the real client area for the framebuffer. The terminal grid is
        // floored to whole cells; any sub-cell remainder stays black instead
        // of leaving an unpainted strip at the window edge.
        const width: u32 = @intCast(@max(client_rect.right - client_rect.left, 1));
        const height: u32 = @intCast(@max(client_rect.bottom - client_rect.top, 1));

        var self = Self{
            .hwnd = hwnd,
            .hinstance = hinstance,
            .memdc = null,
            .dib = null,
            .old_bitmap = null,
            .bits = undefined,
            .buffer = &.{},
            .width = width,
            .height = height,
            .stride = width * 4,
        };
        errdefer _ = c.DestroyWindow(hwnd);
        try self.createSurface(width, height);
        return self;
    }

    pub fn postInit(self: *Self) void {
        g_backend = self;
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, @as(c.LONG_PTR, @intCast(@intFromPtr(self))));
        _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
        _ = c.UpdateWindow(self.hwnd);
    }

    pub fn deinit(self: *Self) void {
        g_backend = null;
        self.paste_buf_data.deinit(std.heap.page_allocator);
        self.destroySurface();
        if (self.hwnd != null) {
            _ = c.DestroyWindow(self.hwnd);
            self.hwnd = null;
        }
        _ = c.UnregisterClassW(class_name, self.hinstance);
    }

    fn createSurface(self: *Self, w: u32, h: u32) !void {
        var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(w);
        bmi.bmiHeader.biHeight = -@as(c.LONG, @intCast(h));
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits: ?*anyopaque = null;
        const dib = c.CreateDIBSection(null, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
        if (dib == null or bits == null) return error.CreateDibFailed;
        errdefer _ = c.DeleteObject(dib);

        const memdc = c.CreateCompatibleDC(null);
        if (memdc == null) return error.CreateDcFailed;
        errdefer _ = c.DeleteDC(memdc);

        const old = c.SelectObject(memdc, dib);
        const stride = w * 4;
        const bytes = @as(usize, stride) * @as(usize, h);
        const ptr: [*]u8 = @ptrCast(bits.?);

        self.memdc = memdc;
        self.dib = dib;
        self.old_bitmap = old;
        self.bits = ptr;
        self.buffer = ptr[0..bytes];
        self.width = w;
        self.height = h;
        self.stride = stride;
        @memset(self.buffer, 0);
    }

    fn destroySurface(self: *Self) void {
        if (self.memdc != null) {
            if (self.old_bitmap != null) _ = c.SelectObject(self.memdc, self.old_bitmap);
            _ = c.DeleteDC(self.memdc);
            self.memdc = null;
        }
        if (self.dib != null) {
            _ = c.DeleteObject(self.dib);
            self.dib = null;
        }
        self.old_bitmap = null;
        self.buffer = &.{};
        self.bits = undefined;
    }

    // =========================================================================
    // Buffer accessors / dirty tracking
    // =========================================================================

    pub fn getBuffer(self: *Self) []u8 {
        return self.buffer;
    }

    pub fn getStride(self: *Self) u32 {
        return self.stride;
    }

    pub fn getWidth(self: *Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *Self) u32 {
        return self.height;
    }

    pub fn getFd(_: *Self) ?i32 {
        return null;
    }

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
        if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
    }

    pub fn present(self: *Self) void {
        if (self.dirty_y_min > self.dirty_y_max) return;
        const y0 = @min(self.dirty_y_min, self.height - 1);
        const y1 = @min(self.dirty_y_max, self.height - 1);
        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
        if (self.memdc == null or self.hwnd == null) return;

        const hdc = c.GetDC(self.hwnd);
        if (hdc == null) return;
        defer _ = c.ReleaseDC(self.hwnd, hdc);

        _ = c.BitBlt(
            hdc,
            0,
            @intCast(y0),
            @intCast(self.width),
            @intCast(y1 - y0 + 1),
            self.memdc,
            0,
            @intCast(y0),
            c.SRCCOPY,
        );
    }

    fn paint(self: *Self) void {
        var ps: c.PAINTSTRUCT = undefined;
        const hdc = c.BeginPaint(self.hwnd, &ps);
        if (hdc == null) return;
        defer _ = c.EndPaint(self.hwnd, &ps);
        if (self.memdc == null) return;
        _ = c.BitBlt(hdc, 0, 0, @intCast(self.width), @intCast(self.height), self.memdc, 0, 0, c.SRCCOPY);
    }

    pub fn flush(_: *Self) void {}

    // =========================================================================
    // Event queue
    // =========================================================================

    fn pushEvent(self: *Self, event: Event) void {
        const next = (self.event_tail + 1) % QUEUE_SIZE;
        if (next == self.event_head) return; // full: drop newest
        self.event_queue[self.event_tail] = event;
        self.event_tail = next;
    }

    fn popEvent(self: *Self) ?Event {
        if (self.event_head == self.event_tail) return null;
        const ev = self.event_queue[self.event_head];
        self.event_head = (self.event_head + 1) % QUEUE_SIZE;
        return ev;
    }

    pub fn pollEvents(self: *Self) ?Event {
        if (self.close_requested) {
            self.close_requested = false;
            return .close;
        }
        if (self.popEvent()) |ev| return ev;

        var msg: c.MSG = undefined;
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) {
                self.close_requested = true;
                break;
            }
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
            if (self.close_requested or self.event_head != self.event_tail) break;
        }
        if (self.close_requested) {
            self.close_requested = false;
            return .close;
        }
        return self.popEvent();
    }

    fn pushKey(self: *Self, vk: u16) void {
        const evdev = input_mod.windowsToEvdev(vk);
        if (evdev == 0) return;
        self.pushEvent(.{ .key = .{
            .keycode = evdev,
            .pressed = true,
            .modifiers = currentModifiers(),
        } });
    }

    fn pushMouse(self: *Self, action: MouseEvent.Action, button: MouseEvent.Button, x: i32, y: i32) void {
        self.pushEvent(.{ .mouse = .{
            .x = @intCast(@max(x, 0)),
            .y = @intCast(@max(y, 0)),
            .button = button,
            .action = action,
            .modifiers = currentModifiers(),
        } });
    }

    /// Push UTF-8 text in chunks that fit TextEvent.
    fn pushText(self: *Self, text: []const u8) void {
        var rest = text;
        while (rest.len > 0) {
            var ev = TextEvent{};
            var take: usize = @min(rest.len, ev.data.len);
            // Never split a UTF-8 sequence across events.
            while (take > 0 and take < rest.len and (rest[take] & 0xC0) == 0x80) take -= 1;
            if (take == 0) take = @min(rest.len, ev.data.len);
            @memcpy(ev.data[0..take], rest[0..take]);
            ev.len = @intCast(take);
            self.pushEvent(.{ .text = ev });
            rest = rest[take..];
        }
    }

    fn pushCodepoint(self: *Self, cp: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        self.pushText(buf[0..len]);
    }

    fn handleChar(self: *Self, unit: u16) void {
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            self.pending_high_surrogate = unit;
            return;
        }
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            if (self.pending_high_surrogate) |hi| {
                self.pending_high_surrogate = null;
                const cp: u21 = @intCast(0x10000 + ((@as(u32, hi) - 0xD800) << 10) + (@as(u32, unit) - 0xDC00));
                self.pushCodepoint(cp);
            }
            return;
        }
        self.pending_high_surrogate = null;
        self.pushCodepoint(unit);
    }

    // =========================================================================
    // Keyboard / IME / clipboard
    // =========================================================================

    fn handleKeyDown(self: *Self, vk: u16, sys_key: bool) bool {
        const mods = currentModifiers();

        // Alt+F4 closes the window through the default system path.
        if (sys_key and mods.alt and vk == c.VK_F4) return false;

        // Ctrl+Shift shortcuts: copy / paste / new window.
        if (mods.ctrl and mods.shift) {
            switch (vk) {
                'C', c.VK_INSERT => {
                    self.pushEvent(.copy_selection);
                    return true;
                },
                'V' => {
                    self.readClipboard();
                    return true;
                },
                'N' => {
                    self.pushEvent(.new_window);
                    return true;
                },
                else => {},
            }
        }
        if (mods.shift and vk == c.VK_INSERT) {
            self.readClipboard();
            return true;
        }

        const evdev = input_mod.windowsToEvdev(vk);
        if (evdev == 0) return true;

        // Printable keys normally arrive through WM_CHAR, which applies the
        // active keyboard layout and dead-key composition. Emit a key event
        // only for special keys and for Ctrl/Alt combinations (which never
        // produce printable WM_CHAR input). Ctrl+Alt is treated as AltGr.
        const altgr = mods.ctrl and mods.alt;
        if (isSpecialKey(evdev) or ((mods.ctrl or mods.alt) and !altgr)) {
            self.pushKey(vk);
            return true;
        }
        return true;
    }

    fn readClipboard(self: *Self) void {
        if (c.OpenClipboard(self.hwnd) == 0) return;
        defer _ = c.CloseClipboard();

        const handle = c.GetClipboardData(c.CF_UNICODETEXT);
        if (handle == null) return;
        const ptr = c.GlobalLock(handle);
        if (ptr == null) return;
        defer _ = c.GlobalUnlock(handle);

        const utf16: [*:0]const u16 = @ptrCast(@alignCast(ptr));
        const len = std.mem.len(utf16);
        if (len == 0) return;

        self.paste_buf_data.clearRetainingCapacity();
        self.paste_buf_data.resize(std.heap.page_allocator, len * 3 + 1) catch return;
        const utf8 = windows.utf16ToUtf8(self.paste_buf_data.items, utf16[0..len]);
        self.paste_buf_data.items.len = utf8.len;
        if (utf8.len == 0) return;
        self.pushEvent(.{ .paste = .{
            .ptr = self.paste_buf_data.items.ptr,
            .len = @intCast(utf8.len),
        } });
    }

    /// Copy terminal selection / OSC 52 payload to the Windows clipboard.
    pub fn setClipboard(self: *Self, data: []const u8) void {
        if (data.len == 0) return;
        const utf16 = windows.utf8ToUtf16Alloc(std.heap.page_allocator, data) catch return;
        defer std.heap.page_allocator.free(utf16);

        // Allocate and fill the shared clipboard block before taking the
        // clipboard, so an allocation failure does not destroy its contents.
        const bytes = (utf16.len + 1) * @sizeOf(u16);
        const hmem = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes);
        if (hmem == null) return;
        const dst = c.GlobalLock(hmem);
        if (dst == null) {
            _ = c.GlobalFree(hmem);
            return;
        }
        const out: [*]u16 = @ptrCast(@alignCast(dst));
        @memcpy(out[0..utf16.len], utf16);
        out[utf16.len] = 0;
        _ = c.GlobalUnlock(hmem);

        if (c.OpenClipboard(self.hwnd) == 0) {
            std.log.err("OpenClipboard failed: {d}", .{c.GetLastError()});
            _ = c.GlobalFree(hmem);
            return;
        }
        defer _ = c.CloseClipboard();
        _ = c.EmptyClipboard();
        if (c.SetClipboardData(c.CF_UNICODETEXT, hmem) == null) {
            std.log.err("SetClipboardData failed: {d}", .{c.GetLastError()});
            _ = c.GlobalFree(hmem);
        }
    }

    fn positionIme(self: *Self) void {
        const himc = c.ImmGetContext(self.hwnd);
        if (himc == null) return;
        defer _ = c.ImmReleaseContext(self.hwnd, himc);

        var cf: c.COMPOSITIONFORM = std.mem.zeroes(c.COMPOSITIONFORM);
        cf.dwStyle = c.CFS_POINT;
        cf.ptCurrentPos.x = @intCast(@min(self.ime_x, @as(u32, std.math.maxInt(i32))));
        cf.ptCurrentPos.y = @intCast(@min(self.ime_y, @as(u32, std.math.maxInt(i32))));
        _ = c.ImmSetCompositionWindow(himc, &cf);

        var cand: c.CANDIDATEFORM = std.mem.zeroes(c.CANDIDATEFORM);
        cand.dwStyle = c.CFS_CANDIDATEPOS;
        cand.ptCurrentPos = cf.ptCurrentPos;
        _ = c.ImmSetCandidateWindow(himc, &cand);
    }

    fn handleImeComposition(self: *Self, lparam: c.LPARAM) void {
        const flags: u32 = @intCast(@as(usize, @bitCast(lparam)));
        if (flags & c.GCS_RESULTSTR == 0) return;
        const himc = c.ImmGetContext(self.hwnd);
        if (himc == null) return;
        defer _ = c.ImmReleaseContext(self.hwnd, himc);

        const byte_len = c.ImmGetCompositionStringW(himc, c.GCS_RESULTSTR, null, 0);
        if (byte_len <= 0) return;
        var wbuf: [1024]u16 = undefined;
        const max_bytes: c.DWORD = @intCast(wbuf.len * @sizeOf(u16));
        const want: c.DWORD = @intCast(@min(@as(c.DWORD, @intCast(byte_len)), max_bytes));
        const copied = c.ImmGetCompositionStringW(himc, c.GCS_RESULTSTR, &wbuf, want);
        if (copied <= 0) return;
        var units: usize = @intCast(@divTrunc(copied, @sizeOf(u16)));
        // The returned string is NUL-terminated; do not forward the terminator
        // to the PTY as a NUL byte.
        while (units > 0 and wbuf[units - 1] == 0) units -= 1;
        if (units == 0) return;
        var ubuf: [4096]u8 = undefined;
        const utf8 = windows.utf16ToUtf8(&ubuf, wbuf[0..units]);
        if (utf8.len > 0) self.pushText(utf8);
    }

    pub fn updateImeCursorPos(self: *Self, x: u32, y: u32) void {
        if (self.ime_x == x and self.ime_y == y) return;
        self.ime_x = x;
        self.ime_y = y;
        self.positionIme();
    }

    // =========================================================================
    // Window management
    // =========================================================================

    pub fn updateTitle(self: *Self, title: []const u8) void {
        var buf: [512]u16 = undefined;
        const utf16 = windows.utf8ToUtf16(&buf, title);
        if (utf16.len >= buf.len) return;
        buf[utf16.len] = 0;
        _ = c.SetWindowTextW(self.hwnd, buf[0..utf16.len :0].ptr);
    }

    pub fn bell(_: *Self) void {
        _ = c.MessageBeep(c.MB_OK);
    }

    /// Ctrl+Shift+N: launch another copy of the executable.
    pub fn openNewWindow(_: *Self) void {
        var path_buf: [32768]u16 = undefined;
        const len = c.GetModuleFileNameW(null, &path_buf, @intCast(path_buf.len));
        if (len == 0 or len >= path_buf.len) return;
        path_buf[len] = 0;

        var si: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
        si.cb = @sizeOf(c.STARTUPINFOW);
        var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(path_buf[0..len :0].ptr, null, null, null, c.FALSE, 0, null, null, &si, &pi) != 0) {
            _ = c.CloseHandle(pi.hThread);
            _ = c.CloseHandle(pi.hProcess);
        }
    }

    pub fn queryGeometry(self: *Self) struct { w: u32, h: u32 } {
        return .{ .w = self.width, .h = self.height };
    }

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        const width = @max(w, 1);
        const height = @max(h, 1);
        if (width == self.width and height == self.height) return;

        self.destroySurface();
        try self.createSurface(width, height);
        self.markDirtyRows(0, height - 1);
        _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    }

    // =========================================================================
    // No-ops (VT-console-specific)
    // =========================================================================

    pub fn saveConsoleState(_: *Self) !void {}
    pub fn restoreConsoleState(_: *Self) void {}
    pub fn setupVtSwitching(_: *Self) !void {}
    pub fn releaseVt(_: *Self) void {}
    pub fn acquireVt(_: *Self) void {}
};

// =============================================================================
// Window procedure
// =============================================================================

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self_opt: ?*WindowsBackend = blk: {
        const raw = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
        if (raw == 0) break :blk g_backend;
        break :blk @ptrFromInt(@as(usize, @intCast(raw)));
    };
    const self = self_opt orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        c.WM_CLOSE => {
            self.close_requested = true;
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_PAINT => {
            self.paint();
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_SIZE => {
            if (wparam == c.SIZE_MINIMIZED) return 0;
            const l = @as(usize, @bitCast(lparam));
            const w: u32 = @intCast(@max(lowordSigned(l), 0));
            const h: u32 = @intCast(@max(lowordSigned(l >> 16), 0));
            if (w > 0 and h > 0) {
                self.pushEvent(.{ .resize = .{ .width = w, .height = h } });
            }
            return 0;
        },
        c.WM_SETFOCUS => {
            self.pushEvent(.focus_in);
            return 0;
        },
        c.WM_KILLFOCUS => {
            self.pushEvent(.focus_out);
            return 0;
        },
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            const vk: u16 = @intCast(wparam & 0xFFFF);
            if (!self.handleKeyDown(vk, msg == c.WM_SYSKEYDOWN)) {
                return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            return 0;
        },
        c.WM_CHAR => {
            const unit: u16 = @intCast(wparam & 0xFFFF);
            if (unit < 0x20 or unit == 0x7F) return 0;
            const mods = currentModifiers();
            // Pure Ctrl chords are handled as key events; AltGr (Ctrl+Alt)
            // must keep its WM_CHAR so international layouts can type.
            if (mods.ctrl and !mods.alt) return 0;
            self.handleChar(unit);
            return 0;
        },
        c.WM_SYSCHAR => {
            // AltGr generates WM_SYSCHAR on some layouts; plain Alt+key is
            // already forwarded as an ESC-prefixed key event.
            const mods = currentModifiers();
            if (mods.ctrl and mods.alt) {
                const unit: u16 = @intCast(wparam & 0xFFFF);
                if (unit >= 0x20 and unit != 0x7F) self.handleChar(unit);
            }
            return 0;
        },
        c.WM_IME_STARTCOMPOSITION => {
            self.positionIme();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_IME_COMPOSITION => {
            self.handleImeComposition(lparam);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_IME_ENDCOMPOSITION => {
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_IME_CHAR => return 0, // committed text arrives via GCS_RESULTSTR
        c.WM_COPY => {
            self.pushEvent(.copy_selection);
            return 0;
        },
        c.WM_PASTE => {
            self.readClipboard();
            return 0;
        },
        c.WM_MOUSEMOVE => {
            const l = @as(usize, @bitCast(lparam));
            self.pushMouse(.motion, .none, lowordSigned(l), lowordSigned(l >> 16));
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONUP, c.WM_RBUTTONDOWN, c.WM_RBUTTONUP, c.WM_MBUTTONDOWN, c.WM_MBUTTONUP => {
            const l = @as(usize, @bitCast(lparam));
            const button: MouseEvent.Button = switch (msg) {
                c.WM_LBUTTONDOWN, c.WM_LBUTTONUP => .left,
                c.WM_RBUTTONDOWN, c.WM_RBUTTONUP => .right,
                else => .middle,
            };
            const action: MouseEvent.Action = switch (msg) {
                c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN => .press,
                else => .release,
            };
            if (action == .press) {
                _ = c.SetCapture(hwnd);
            } else {
                _ = c.ReleaseCapture();
            }
            self.pushMouse(action, button, lowordSigned(l), lowordSigned(l >> 16));
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(hiword(wparam));
            if (delta == 0) return 0;
            const l = @as(usize, @bitCast(lparam));
            var pt = c.POINT{ .x = lowordSigned(l), .y = lowordSigned(l >> 16) };
            _ = c.ScreenToClient(hwnd, &pt);
            const button: MouseEvent.Button = if (delta > 0) .wheel_up else .wheel_down;
            self.pushMouse(.press, button, pt.x, pt.y);
            return 0;
        },
        c.WM_SETCURSOR => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
        c.WM_GETMINMAXINFO => {
            const mmi: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            mmi.ptMinTrackSize.x = @intCast(20 * config.cell_width);
            mmi.ptMinTrackSize.y = @intCast(5 * config.cell_height);
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
