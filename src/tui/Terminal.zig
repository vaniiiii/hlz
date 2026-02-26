//! Terminal abstraction — raw mode, alternate screen, size detection.
//!
//! Inspired by ratatui's backend, but direct POSIX — no crossterm.

const std = @import("std");
const posix = std.posix;

const Terminal = @This();

orig_termios: posix.termios,
width: u16,
height: u16,
is_raw: bool = false,
is_alt: bool = false,

/// Enter raw mode and alternate screen. Returns terminal dimensions.
pub fn init() !Terminal {
    const stdout = std.fs.File.stdout();
    const fd = stdout.handle;

    // Check if stdout and stdin are terminals
    if (!std.posix.isatty(fd)) return error.NotATerminal;
    if (!std.posix.isatty(std.fs.File.stdin().handle)) return error.NotATerminal;

    // Get original termios
    const orig = try posix.tcgetattr(fd);

    // Get terminal size
    const size = getSize(fd);

    // Enter raw mode
    var raw = orig;
    // Disable echo, canonical mode, signals, extended processing
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    // Disable CR→NL, flow control
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    // Disable output processing
    raw.oflag.OPOST = false;
    // Read returns after 1 byte, with 100ms timeout
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1;

    try posix.tcsetattr(fd, .FLUSH, raw);

    // Enter alternate screen + hide cursor
    stdout.writeAll("\x1b[?1049h\x1b[?25l") catch {};

    return .{
        .orig_termios = orig,
        .width = size.cols,
        .height = size.rows,
        .is_raw = true,
        .is_alt = true,
    };
}

/// Leave raw mode and alternate screen.
pub fn deinit(self: *Terminal) void {
    const stdout = std.fs.File.stdout();
    // Show cursor + leave alternate screen
    if (self.is_alt) {
        stdout.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        self.is_alt = false;
    }
    // Restore original termios
    if (self.is_raw) {
        posix.tcsetattr(stdout.handle, .FLUSH, self.orig_termios) catch {};
        self.is_raw = false;
    }
}

/// Refresh terminal size.
pub fn refreshSize(self: *Terminal) void {
    const size = getSize(std.fs.File.stdout().handle);
    self.width = size.cols;
    self.height = size.rows;
}

/// Move cursor to position.
pub fn moveTo(col: u16, row: u16) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

/// Clear the entire screen.
pub fn clear() void {
    std.fs.File.stdout().writeAll("\x1b[2J\x1b[1;1H") catch {};
}

const WinSize = struct { rows: u16, cols: u16 };

fn getSize(fd: posix.fd_t) WinSize {
    // ioctl TIOCGWINSZ
    var ws: extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 } = undefined;
    const TIOCGWINSZ: u32 = switch (@import("builtin").os.tag) {
        .macos => 0x40087468,
        .linux => 0x5413,
        else => 0x5413,
    };
    const ret = std.posix.system.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
    if (ret == 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return .{ .rows = 24, .cols = 80 }; // fallback
}


pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    esc,
    tab,
    backspace,
    unknown,
};

/// Non-blocking key read. Returns null if no key available.
pub fn pollKey() ?Key {
    var buf: [8]u8 = undefined;
    const n = std.posix.read(std.fs.File.stdin().handle, &buf) catch return null;
    if (n == 0) return null;

    if (buf[0] == 0x1b) {
        if (n == 1) return .esc;
        if (n >= 3 and buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                else => .unknown,
            };
        }
        return .esc;
    }

    return switch (buf[0]) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        127 => .backspace,
        else => .{ .char = buf[0] },
    };
}
