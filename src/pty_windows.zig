//! Windows pseudo-console (ConPTY) process layer.
//!
//! ConPTY exposes a pair of anonymous pipes: zt writes keyboard/paste bytes to
//! the input pipe and reads the VT-rendered output stream from the output pipe.
//! Anonymous pipes are synchronous, so dedicated reader/writer threads keep the
//! main event loop non-blocking. The reader signals a manual Win32 event that
//! the main loop waits on together with its message queue.

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const c = windows.c;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("pty_windows.zig is only available on Windows targets");
    }
}

const allocator = std.heap.page_allocator;

/// Explicit error set: main.zig switches on WouldBlock and treats every other
/// error as fatal, so the set must name both cases on every platform.
const PtyError = error{ WouldBlock, BrokenPipe, InputOutput, OutOfMemory };

const State = struct {
    pc: c.HPCON,
    process: c.HANDLE,
    process_id: c.DWORD,
    input_write: c.HANDLE,
    output_read: c.HANDLE,
    data_event: c.HANDLE,
    write_event: c.HANDLE,
    mutex: c.CRITICAL_SECTION,

    read_buf: std.ArrayListUnmanaged(u8) = .empty,
    read_head: usize = 0,
    eof: bool = false,

    write_buf: std.ArrayListUnmanaged(u8) = .empty,
    write_head: usize = 0,
    stopping: bool = false,

    reader: ?std.Thread = null,
    writer: ?std.Thread = null,
};

/// Non-owning handle to the pseudo console; `deinit` tears everything down.
pub const Pty = struct {
    st: *State,
    /// Kept for source compatibility with the POSIX PTY. Windows uses
    /// `waitHandle()` instead of an fd-based event loop.
    master_fd: i32 = -1,
    child_pid: i32 = 0,

    pub fn spawn(cols: u16, rows: u16, shell_path: [*:0]const u8, exec_argv: ?[]const [:0]const u8) !Pty {
        const st = try allocator.create(State);
        errdefer allocator.destroy(st);

        st.* = .{
            .pc = null,
            .process = null,
            .process_id = 0,
            .input_write = null,
            .output_read = null,
            .data_event = null,
            .write_event = null,
            .mutex = undefined,
        };
        c.InitializeCriticalSection(&st.mutex);
        errdefer c.DeleteCriticalSection(&st.mutex);

        // 1. Pipes. ConPTY duplicates the handles passed to CreatePseudoConsole,
        //    so no handle needs to be inheritable. CreateProcess below must be
        //    called with bInheritHandles=FALSE: inheriting the host's console
        //    handles makes the child attach to the host console instead of the
        //    pseudo console.
        var sa: c.SECURITY_ATTRIBUTES = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
        sa.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
        sa.bInheritHandle = c.FALSE;

        var input_read: c.HANDLE = null;
        var output_write: c.HANDLE = null;
        var input_write: c.HANDLE = null;
        var output_read: c.HANDLE = null;

        if (c.CreatePipe(&input_read, &input_write, &sa, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            if (input_read != null) _ = c.CloseHandle(input_read);
        }
        errdefer {
            if (input_write != null) _ = c.CloseHandle(input_write);
        }

        if (c.CreatePipe(&output_read, &output_write, &sa, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            if (output_write != null) _ = c.CloseHandle(output_write);
        }
        errdefer {
            if (output_read != null) _ = c.CloseHandle(output_read);
        }

        _ = c.SetHandleInformation(input_write, c.HANDLE_FLAG_INHERIT, 0);
        _ = c.SetHandleInformation(output_read, c.HANDLE_FLAG_INHERIT, 0);

        // 2. Create the pseudo console.
        var pc: c.HPCON = null;
        const size = c.COORD{ .X = @intCast(@min(cols, @as(u16, std.math.maxInt(i16)))), .Y = @intCast(@min(rows, @as(u16, std.math.maxInt(i16)))) };
        const hr = c.CreatePseudoConsole(size, input_read, output_write, 0, &pc);
        if (!windows.hresultOk(hr)) {
            std.log.err("CreatePseudoConsole failed: 0x{x}", .{@as(u32, @bitCast(hr))});
            return error.CreatePseudoConsoleFailed;
        }
        errdefer if (pc != null) c.ClosePseudoConsole(pc);

        // The console owns these ends now.
        _ = c.CloseHandle(input_read);
        input_read = null;
        _ = c.CloseHandle(output_write);
        output_write = null;

        // 3. Events used to wake the main loop / writer thread.
        const data_event = c.CreateEventW(null, c.FALSE, c.FALSE, null);
        if (data_event == null) return error.CreateEventFailed;
        errdefer _ = c.CloseHandle(data_event);
        const write_event = c.CreateEventW(null, c.FALSE, c.FALSE, null);
        if (write_event == null) return error.CreateEventFailed;
        errdefer _ = c.CloseHandle(write_event);

        // 4. Build the command line.
        var cmdline: std.ArrayListUnmanaged(u16) = .empty;
        defer cmdline.deinit(allocator);
        if (exec_argv) |argv| {
            if (argv.len == 0) return error.EmptyCommand;
            for (argv, 0..) |arg, idx| {
                if (idx > 0) try cmdline.append(allocator, ' ');
                try appendQuotedArg(&cmdline, arg);
            }
        } else {
            try appendQuotedArg(&cmdline, std.mem.span(shell_path));
        }
        try cmdline.append(allocator, 0);

        // 5. STARTUPINFOEX with the pseudo-console attribute.
        var attr_buf: [1024]u8 align(16) = undefined;
        var attr_size: usize = attr_buf.len;
        const attr_list: c.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(&attr_buf);
        if (c.InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == 0) {
            return error.AttributeListFailed;
        }
        defer c.DeleteProcThreadAttributeList(attr_list);
        if (c.UpdateProcThreadAttribute(
            attr_list,
            0,
            c.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            pc,
            @sizeOf(c.HPCON),
            null,
            null,
        ) == 0) {
            std.log.err("UpdateProcThreadAttribute failed: {d}", .{c.GetLastError()});
            return error.AttributeListFailed;
        }

        var si: c.STARTUPINFOEXW = std.mem.zeroes(c.STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
        // Null std handles + STARTF_USESTDHANDLES prevent the child from
        // inheriting the host's console. Without this, cmd.exe attaches to the
        // host console and the pseudo-console output pipe stays empty.
        si.StartupInfo.dwFlags = c.STARTF_USESTDHANDLES;
        si.lpAttributeList = attr_list;

        var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
        if (c.CreateProcessW(
            null,
            cmdline.items.ptr,
            null,
            null,
            c.FALSE,
            c.EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            &si.StartupInfo,
            &pi,
        ) == 0) {
            const code = c.GetLastError();
            std.log.err("CreateProcessW failed: {s} ({d})", .{ windows.errorName(code), code });
            return error.CreateProcessFailed;
        }
        _ = c.CloseHandle(pi.hThread);
        errdefer {
            _ = c.TerminateProcess(pi.hProcess, 1);
            _ = c.CloseHandle(pi.hProcess);
        }

        st.pc = pc;
        st.process = pi.hProcess;
        st.process_id = pi.dwProcessId;
        st.input_write = input_write;
        st.output_read = output_read;
        st.data_event = data_event;
        st.write_event = write_event;

        // Ownership transferred to `st`.
        input_write = null;
        output_read = null;

        st.reader = try std.Thread.spawn(.{}, readerMain, .{st});
        st.writer = try std.Thread.spawn(.{}, writerMain, .{st});

        return .{ .st = st, .child_pid = @intCast(pi.dwProcessId) };
    }

    pub fn deinit(self: *Pty) void {
        const st = self.st;

        // Wake the writer and tell both threads to stop.
        c.EnterCriticalSection(&st.mutex);
        st.stopping = true;
        c.LeaveCriticalSection(&st.mutex);
        _ = c.SetEvent(st.write_event);

        // Closing the pseudo console closes the console ends of both pipes,
        // which unblocks the reader's ReadFile.
        if (st.pc != null) {
            c.ClosePseudoConsole(st.pc);
            st.pc = null;
        }
        if (st.process != null) {
            _ = c.TerminateProcess(st.process, 1);
            _ = c.WaitForSingleObject(st.process, 2000);
        }
        if (st.reader) |t| {
            t.join();
            st.reader = null;
        }
        if (st.writer) |t| {
            t.join();
            st.writer = null;
        }

        if (st.process != null) {
            _ = c.CloseHandle(st.process);
            st.process = null;
        }
        if (st.input_write != null) {
            _ = c.CloseHandle(st.input_write);
            st.input_write = null;
        }
        if (st.output_read != null) {
            _ = c.CloseHandle(st.output_read);
            st.output_read = null;
        }
        if (st.data_event != null) {
            _ = c.CloseHandle(st.data_event);
            st.data_event = null;
        }
        if (st.write_event != null) {
            _ = c.CloseHandle(st.write_event);
            st.write_event = null;
        }

        st.read_buf.deinit(allocator);
        st.write_buf.deinit(allocator);
        c.DeleteCriticalSection(&st.mutex);
        allocator.destroy(st);
        self.st = undefined;
    }

    /// Handle that becomes signaled whenever output is available or the child
    /// has exited. The main loop passes this to MsgWaitForMultipleObjectsEx.
    pub fn waitHandle(self: *const Pty) c.HANDLE {
        return self.st.data_event;
    }

    /// True once the hosted process has exited. ConPTY keeps its output pipe
    /// open until ClosePseudoConsole, so EOF alone cannot end the session.
    pub fn childExited(self: *const Pty) bool {
        if (self.st.process == null) return true;
        return c.WaitForSingleObject(self.st.process, 0) == c.WAIT_OBJECT_0;
    }

    /// Ask ConPTY to emit its final frame and close the output pipe. The
    /// reader thread then reaches EOF, letting the main loop drain the last
    /// bytes before the window closes. Idempotent; deinit skips a closed
    /// console.
    pub fn closeConsole(self: *Pty) void {
        if (self.st.pc != null) {
            c.ClosePseudoConsole(self.st.pc);
            self.st.pc = null;
        }
    }

    pub fn read(self: *Pty, buf: []u8) PtyError!usize {
        const st = self.st;
        c.EnterCriticalSection(&st.mutex);
        defer c.LeaveCriticalSection(&st.mutex);

        const avail = st.read_buf.items.len - st.read_head;
        if (avail > 0) {
            const n = @min(avail, buf.len);
            @memcpy(buf[0..n], st.read_buf.items[st.read_head..][0..n]);
            st.read_head += n;
            if (st.read_head == st.read_buf.items.len) {
                st.read_buf.clearRetainingCapacity();
                st.read_head = 0;
            } else if (st.read_head > 1 << 20 and st.read_head * 2 > st.read_buf.items.len) {
                const remaining = st.read_buf.items.len - st.read_head;
                std.mem.copyForwards(u8, st.read_buf.items[0..remaining], st.read_buf.items[st.read_head..]);
                st.read_buf.items.len = remaining;
                st.read_head = 0;
            }
            return n;
        }
        if (st.eof) return 0;
        return error.WouldBlock;
    }

    pub fn write(self: *Pty, data: []const u8) PtyError!usize {
        if (data.len == 0) return 0;
        const st = self.st;
        c.EnterCriticalSection(&st.mutex);
        defer c.LeaveCriticalSection(&st.mutex);
        if (st.stopping) return error.BrokenPipe;
        try st.write_buf.appendSlice(allocator, data);
        _ = c.SetEvent(st.write_event);
        return data.len;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        const st = self.st;
        if (st.pc == null) return error.NotConnected;
        const size = c.COORD{
            .X = @intCast(@min(cols, @as(u16, std.math.maxInt(i16)))),
            .Y = @intCast(@min(rows, @as(u16, std.math.maxInt(i16)))),
        };
        const hr = c.ResizePseudoConsole(st.pc, size);
        if (!windows.hresultOk(hr)) return error.ResizeFailed;
    }
};

fn readerMain(st: *State) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        var n: c.DWORD = 0;
        if (c.ReadFile(st.output_read, &buf, buf.len, &n, null) == 0) break;
        if (n == 0) break;

        c.EnterCriticalSection(&st.mutex);
        st.read_buf.appendSlice(allocator, buf[0..n]) catch {};
        c.LeaveCriticalSection(&st.mutex);
        _ = c.SetEvent(st.data_event);
    }

    c.EnterCriticalSection(&st.mutex);
    st.eof = true;
    c.LeaveCriticalSection(&st.mutex);
    _ = c.SetEvent(st.data_event);
}

fn writerMain(st: *State) void {
    var chunk: [8192]u8 = undefined;
    while (true) {
        _ = c.WaitForSingleObject(st.write_event, windows.INFINITE);

        while (true) {
            c.EnterCriticalSection(&st.mutex);
            if (st.stopping) {
                c.LeaveCriticalSection(&st.mutex);
                return;
            }
            const avail = st.write_buf.items.len - st.write_head;
            if (avail == 0) {
                c.LeaveCriticalSection(&st.mutex);
                break;
            }
            const take = @min(avail, chunk.len);
            @memcpy(chunk[0..take], st.write_buf.items[st.write_head..][0..take]);
            st.write_head += take;
            if (st.write_head == st.write_buf.items.len) {
                st.write_buf.clearRetainingCapacity();
                st.write_head = 0;
            }
            c.LeaveCriticalSection(&st.mutex);

            var written: c.DWORD = 0;
            if (c.WriteFile(st.input_write, &chunk, @intCast(take), &written, null) == 0) {
                // The child closed its input; drop remaining writes.
                return;
            }
            if (written == 0) return;
        }
    }
}

fn appendQuotedArg(list: *std.ArrayListUnmanaged(u16), arg: []const u8) !void {
    const utf16 = try windows.utf8ToUtf16Alloc(allocator, arg);
    defer allocator.free(utf16);

    // Only quote when the argument actually needs it. Always quoting breaks
    // cmd.exe's own /c parsing (`cmd /c "ver"` tries to run a program whose
    // name includes the quote characters).
    var needs_quotes = utf16.len == 0;
    for (utf16) |unit| {
        switch (unit) {
            ' ', '\t', '\n', '\x0b', '"' => needs_quotes = true,
            else => {},
        }
    }
    if (!needs_quotes) {
        try list.appendSlice(allocator, utf16);
        return;
    }

    try list.append(allocator, '"');
    var backslashes: usize = 0;
    for (utf16) |unit| {
        switch (unit) {
            '\\' => backslashes += 1,
            '"' => {
                try list.appendNTimes(allocator, '\\', backslashes * 2 + 1);
                try list.append(allocator, '"');
                backslashes = 0;
            },
            else => {
                try list.appendNTimes(allocator, '\\', backslashes);
                try list.append(allocator, unit);
                backslashes = 0;
            },
        }
    }
    try list.appendNTimes(allocator, '\\', backslashes * 2);
    try list.append(allocator, '"');
}

test "Pty: command line quoting keeps simple args bare" {
    var list: std.ArrayListUnmanaged(u16) = .empty;
    defer list.deinit(allocator);

    try appendQuotedArg(&list, "cmd");
    try list.append(allocator, ' ');
    try appendQuotedArg(&list, "ver");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("cmd ver"), list.items);

    list.clearRetainingCapacity();
    try appendQuotedArg(&list, "echo hello");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\"echo hello\""), list.items);

    list.clearRetainingCapacity();
    try appendQuotedArg(&list, "a\"b");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\"a\\\"b\""), list.items);
}

test "Pty: ConPTY spawn and echo" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var pty = Pty.spawn(80, 24, "cmd.exe", null) catch |err| switch (err) {
        error.CreatePseudoConsoleFailed, error.CreateProcessFailed => return error.SkipZigTest,
        else => return err,
    };
    defer pty.deinit();

    _ = try pty.write("echo zt-conpty\r\n");
    var received: std.ArrayListUnmanaged(u8) = .empty;
    defer received.deinit(allocator);
    var buf: [4096]u8 = undefined;
    const deadline = windows.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (windows.nanoTimestamp() < deadline) {
        const n = pty.read(&buf) catch |err| switch (err) {
            error.WouldBlock => {
                _ = c.WaitForSingleObject(pty.waitHandle(), 20);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.TestUnexpectedResult;
        try received.appendSlice(allocator, buf[0..n]);
        if (std.mem.indexOf(u8, received.items, "zt-conpty") != null) return;
        if (received.items.len > 1 << 20) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}
