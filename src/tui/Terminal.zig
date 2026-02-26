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
    // Non-blocking: return immediately with 0 bytes if nothing available
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

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

// Input byte ring buffer — survives across pollKey() calls
var ring: [64]u8 = undefined;
var ring_r: usize = 0;
var ring_w: usize = 0;

fn ringLen() usize {
    return ring_w -% ring_r;
}

fn ringPush(data: []const u8) void {
    for (data) |b| {
        if (ringLen() >= ring.len) return; // full, drop
        ring[ring_w % ring.len] = b;
        ring_w +%= 1;
    }
}

fn ringPeek(offset: usize) ?u8 {
    if (offset >= ringLen()) return null;
    return ring[(ring_r +% offset) % ring.len];
}

fn ringConsume(n: usize) void {
    ring_r +%= n;
}

/// Non-blocking key read with proper escape sequence handling.
pub fn pollKey() ?Key {
    // Fill ring from stdin (non-blocking)
    var tmp: [32]u8 = undefined;
    const n = std.posix.read(std.fs.File.stdin().handle, &tmp) catch 0;
    if (n > 0) ringPush(tmp[0..n]);

    if (ringLen() == 0) return null;

    const b0 = ringPeek(0).?;

    if (b0 == 0x1b) {
        // ESC — could be escape key or start of CSI sequence
        if (ringLen() >= 3) {
            if (ringPeek(1).? == '[') {
                const b2 = ringPeek(2).?;
                const key: Key = switch (b2) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .{ .char = '0' }, // Home
                    'F' => .{ .char = '$' }, // End
                    else => .unknown,
                };
                ringConsume(3);
                return key;
            }
        }
        if (ringLen() >= 2 and ringPeek(1).? == '[') {
            // Have ESC+[ but missing final byte — wait for more data
            return null;
        }
        // Lone ESC with no [ following — real Esc key
        ringConsume(1);
        return .esc;
    }

    ringConsume(1);
    return switch (b0) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        127 => .backspace,
        else => .{ .char = b0 },
    };
}
