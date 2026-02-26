//! Terminal output formatting for the `hl` CLI.
//!
//! Three modes: pretty (colored tables), json (for piping), csv.
//! Auto-detects TTY — if stdout is piped, defaults to json.

const std = @import("std");
const args_mod = @import("args.zig");
const Decimal = @import("hyperzig").math.decimal.Decimal;

const OutputFormat = args_mod.OutputFormat;


pub const Style = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
    pub const bold_cyan = "\x1b[1;36m";
    pub const bold_green = "\x1b[1;32m";
    pub const bold_red = "\x1b[1;31m";
    pub const bold_yellow = "\x1b[1;33m";
};

pub const Writer = struct {
    is_tty: bool,
    format: OutputFormat,

    pub fn init(format: OutputFormat) Writer {
        const is_tty = std.posix.isatty(std.fs.File.stdout().handle);
        return .{ .is_tty = is_tty, .format = format };
    }

    pub fn initAuto(format: OutputFormat, explicit: bool) Writer {
        const is_tty = std.posix.isatty(std.fs.File.stdout().handle);
        // Auto-detect: if piped and format wasn't explicitly set, use json
        const effective = if (!is_tty and !explicit and format == .pretty) .json else format;
        return .{ .is_tty = is_tty, .format = effective };
    }

    /// Write to stdout, replacing \n with \r\n when on a TTY.
    /// This ensures correct rendering even when OPOST is disabled
    /// (e.g. after a TUI session or in certain terminal states).
    fn out(self: *Writer, data: []const u8) !void {
        if (!self.is_tty) {
            std.fs.File.stdout().writeAll(data) catch return error.BrokenPipe;
            return;
        }
        // Scan for \n and emit \r\n
        const stdout = std.fs.File.stdout();
        var start: usize = 0;
        for (data, 0..) |byte, i| {
            if (byte == '\n') {
                if (i > start) stdout.writeAll(data[start..i]) catch return error.BrokenPipe;
                stdout.writeAll("\r\n") catch return error.BrokenPipe;
                start = i + 1;
            }
        }
        if (start < data.len) stdout.writeAll(data[start..]) catch return error.BrokenPipe;
    }

    fn ew(_: *Writer, data: []const u8) !void {
        std.fs.File.stderr().writeAll(data) catch return error.BrokenPipe;
    }

    // ── Styled output (only when TTY) ─────────────────────────

    pub fn style(self: *Writer, s: []const u8) !void {
        if (self.is_tty) try self.out(s);
    }

    pub fn styled(self: *Writer, s: []const u8, text: []const u8) !void {
        if (self.is_tty) try self.out(s);
        try self.out(text);
        if (self.is_tty) try self.out(Style.reset);
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, a: anytype) !void {
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, a) catch return error.Overflow;
        try self.out(s);
    }

    pub fn nl(self: *Writer) !void {
        try self.out("\n");
    }

    // ── Table rendering ───────────────────────────────────────

    pub fn heading(self: *Writer, title: []const u8) !void {
        if (self.format != .pretty) return;
        try self.style(Style.bold_cyan);
        try self.out("\xe2\x95\xad\xe2\x94\x80 "); // ╭─
        try self.out(title);
        try self.out(" ");
        const title_len = title.len + 4;
        if (title_len < 60) {
            var i: usize = title_len;
            while (i < 60) : (i += 1) try self.out("\xe2\x94\x80"); // ─
        }
        try self.out("\xe2\x95\xae"); // ╮
        try self.style(Style.reset);
        try self.out("\n");
    }

    pub fn footer(self: *Writer) !void {
        if (self.format != .pretty) return;
        try self.style(Style.dim);
        try self.out("\xe2\x95\xb0"); // ╰
        var i: usize = 0;
        while (i < 60) : (i += 1) try self.out("\xe2\x94\x80"); // ─
        try self.out("\xe2\x95\xaf"); // ╯
        try self.style(Style.reset);
        try self.out("\n");
    }

    pub fn tableRow(self: *Writer, columns: []const Column) !void {
        if (self.format == .json) return;
        try self.out("\xe2\x94\x82 "); // │
        for (columns) |col| {
            if (col.color) |c| {
                if (self.is_tty) try self.out(c);
            }
            try self.padWrite(col.text, col.width, col.align_right);
            if (col.color != null) {
                if (self.is_tty) try self.out(Style.reset);
            }
            try self.out("  ");
        }
        try self.out("\n");
    }

    pub fn tableHeader(self: *Writer, columns: []const Column) !void {
        if (self.format != .pretty) return;
        if (self.is_tty) {
            try self.out(Style.bold);
            try self.out(Style.dim);
        }
        try self.out("\xe2\x94\x82 "); // │
        for (columns) |col| {
            try self.padWrite(col.text, col.width, col.align_right);
            try self.out("  ");
        }
        if (self.is_tty) try self.out(Style.reset);
        try self.out("\n");
    }

    fn padWrite(self: *Writer, text: []const u8, width: usize, right: bool) !void {
        const display_len = displayWidth(text);
        const pad = if (width > display_len) width - display_len else 0;
        if (right) {
            var i: usize = 0;
            while (i < pad) : (i += 1) try self.out(" ");
        }
        try self.out(text);
        if (!right) {
            var i: usize = 0;
            while (i < pad) : (i += 1) try self.out(" ");
        }
    }

    // ── Pagination footer ─────────────────────────────────────

    pub fn paginate(self: *Writer, shown: usize, total: usize) !void {
        return self.paginatePage(shown, total, 0, 0);
    }

    pub fn paginatePage(self: *Writer, shown: usize, total: usize, page: usize, pages: usize) !void {
        if (self.format != .pretty) return;
        try self.style(Style.dim);
        var buf: [96]u8 = undefined;
        const s = if (page > 0 and pages > 1)
            std.fmt.bufPrint(&buf, "\xe2\x94\x82 Showing {d}/{d} \xe2\x80\xa2 page {d}/{d} \xe2\x80\xa2 --page N | --all", .{ shown, total, page, pages }) catch return
        else
            std.fmt.bufPrint(&buf, "\xe2\x94\x82 Showing {d}/{d} \xe2\x80\xa2 --page N | --all", .{ shown, total }) catch return;
        try self.out(s);
        try self.style(Style.reset);
        try self.out("\n");
    }

    // ── PnL coloring ──────────────────────────────────────────

    pub fn pnlColor(d: ?Decimal) ?[]const u8 {
        if (d) |val| {
            if (val.isNegative()) return Style.bold_red;
            if (val.mantissa != 0) return Style.bold_green;
        }
        return Style.dim;
    }

    // ── JSON output helpers ───────────────────────────────────

    pub fn jsonRaw(self: *Writer, body: []const u8) !void {
        try self.out(body);
        try self.out("\n");
    }

    // ── Error/success messages ────────────────────────────────

    pub fn err(self: *Writer, msg: []const u8) !void {
        if (self.is_tty) {
            try self.ew(Style.bold_red);
            try self.ew("error: ");
            try self.ew(Style.reset);
        } else {
            try self.ew("error: ");
        }
        try self.ew(msg);
        try self.ew("\n");
    }

    pub fn errFmt(self: *Writer, comptime fmt: []const u8, a: anytype) !void {
        if (self.is_tty) {
            try self.ew(Style.bold_red);
            try self.ew("error: ");
            try self.ew(Style.reset);
        } else {
            try self.ew("error: ");
        }
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, a) catch return error.Overflow;
        try self.ew(s);
        try self.ew("\n");
    }

    pub fn success(self: *Writer, msg: []const u8) !void {
        if (self.is_tty) {
            try self.out(Style.bold_green);
            try self.out("\xe2\x9c\x93 "); // ✓
            try self.out(Style.reset);
        }
        try self.out(msg);
        try self.out("\n");
    }
};

/// Count display columns (not bytes). Each UTF-8 codepoint = 1 column.
pub fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            i += 1;
        } else if (byte < 0xE0) {
            i += 2;
        } else if (byte < 0xF0) {
            i += 3;
        } else {
            i += 4;
        }
        cols += 1;
    }
    return cols;
}

pub const Column = struct {
    text: []const u8,
    width: usize = 12,
    align_right: bool = false,
    color: ?[]const u8 = null,
};
