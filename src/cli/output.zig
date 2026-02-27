//! Terminal output — "artifact" theme.
//! Heavy top border + floating tab title, left accent rail,
//! pill badges, sparse dot separators. Hyperliquid palette.

const std = @import("std");
const args_mod = @import("args.zig");
const Decimal = @import("hlz").math.decimal.Decimal;

const OutputFormat = args_mod.OutputFormat;

pub const Style = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    pub const green = "\x1b[38;2;31;166;125m";
    pub const red = "\x1b[38;2;237;112;136m";
    pub const cyan = "\x1b[38;2;80;210;193m";
    pub const yellow = "\x1b[38;2;245;195;68m";
    pub const white = "\x1b[38;2;255;255;255m";
    pub const muted = "\x1b[38;2;100;110;108m";
    pub const subtle = "\x1b[38;2;60;72;68m";

    pub const bold_green = "\x1b[1m\x1b[38;2;31;166;125m";
    pub const bold_red = "\x1b[1m\x1b[38;2;237;112;136m";
    pub const bold_cyan = "\x1b[1m\x1b[38;2;80;210;193m";
    pub const bold_yellow = "\x1b[1m\x1b[38;2;245;195;68m";
    pub const bold_white = "\x1b[1m\x1b[38;2;255;255;255m";

    pub const bg_green = "\x1b[48;2;30;93;82m";
    pub const bg_red = "\x1b[48;2;115;42;54m";

    pub const rail = "\x1b[38;2;80;210;193m\xe2\x96\x90"; // ▐ cyan
    pub const rail_dim = "\x1b[38;2;39;48;53m\xe2\x96\x90"; // ▐ dim
};

pub const Writer = struct {
    is_tty: bool,
    format: OutputFormat,
    quiet: bool = false,
    cmd: []const u8 = "",
    start_ns: i128 = 0,

    pub fn init(format: OutputFormat) Writer {
        const is_tty = std.posix.isatty(std.fs.File.stdout().handle) and !noColor();
        return .{ .is_tty = is_tty, .format = format };
    }

    pub fn initAuto(format: OutputFormat, explicit: bool) Writer {
        const raw_tty = std.posix.isatty(std.fs.File.stdout().handle);
        const is_tty = raw_tty and !noColor();
        const effective = if (!raw_tty and !explicit and format == .pretty) .json else format;
        return .{ .is_tty = is_tty, .format = effective };
    }

    fn noColor() bool {
        return std.posix.getenv("NO_COLOR") != null;
    }

    fn out(self: *Writer, data: []const u8) !void {
        if (!self.is_tty) {
            std.fs.File.stdout().writeAll(data) catch return error.BrokenPipe;
            return;
        }
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

    // ── Panel ─────────────────────────────────────────────────

    pub fn heading(self: *Writer, title: []const u8) !void {
        if (self.format != .pretty or self.quiet) return;
        try self.style(Style.subtle);
        try self.out("  \xe2\x94\x81\xe2\x94\x81\xe2\x94\x81"); // ━━━
        try self.style(Style.reset);
        try self.style(Style.bold_cyan);
        try self.out("\xe2\x94\xab "); // ┫
        try self.out(title);
        try self.out(" \xe2\x94\xa3"); // ┣
        try self.style(Style.reset);
        try self.style(Style.subtle);
        var i: usize = 8 + title.len;
        while (i < 68) : (i += 1) try self.out("\xe2\x94\x81"); // ━
        try self.style(Style.reset);
        try self.out("\n");
    }

    pub fn footer(self: *Writer) !void {
        if (self.format != .pretty or self.quiet) return;
        try self.out("\n");
    }

    pub fn panelSep(self: *Writer) !void {
        if (self.format != .pretty or self.quiet) return;
        try self.style(Style.subtle);
        try self.out("  ");
        var i: usize = 0;
        while (i < 34) : (i += 1) try self.out("\xc2\xb7 ");
        try self.style(Style.reset);
        try self.out("\n");
    }

    fn emitRail(self: *Writer, bright: bool) !void {
        if (self.is_tty) {
            try self.out("  ");
            try self.out(if (bright) Style.rail else Style.rail_dim);
            try self.out(Style.reset);
        } else {
            try self.out("  ");
        }
        try self.out(" ");
    }

    pub fn tableRow(self: *Writer, columns: []const Column) !void {
        if (self.format == .json) return;
        try self.emitRail(false);
        for (columns) |col| {
            if (col.color) |c| try self.style(c);
            try self.padWrite(col.text, col.width, col.align_right);
            if (col.color != null) try self.style(Style.reset);
            try self.out(" ");
        }
        try self.out("\n");
    }

    pub fn tableHeader(self: *Writer, columns: []const Column) !void {
        if (self.format != .pretty) return;
        try self.emitRail(true);
        try self.style(Style.muted);
        for (columns) |col| {
            try self.padWrite(col.text, col.width, col.align_right);
            try self.out(" ");
        }
        try self.style(Style.reset);
        try self.out("\n");
    }

    fn padWrite(self: *Writer, text: []const u8, width: usize, right: bool) !void {
        const dw = displayWidth(text);
        if (dw > width) {
            var cols: usize = 0;
            var i: usize = 0;
            while (i < text.len and cols < width) {
                const byte = text[i];
                const clen: usize = if (byte < 0x80) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
                if (cols + 1 > width) break;
                const end = @min(i + clen, text.len);
                try self.out(text[i..end]);
                i = end;
                cols += 1;
            }
            return;
        }
        const pad = width - dw;
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

    // ── Visual elements ───────────────────────────────────────

    pub fn bar(self: *Writer, value: f64, max_val: f64, max_width: usize, color: []const u8) !void {
        if (!self.is_tty or max_val <= 0) return;
        const ratio = @min(1.0, @max(0.0, value / max_val));
        const fill_f = ratio * @as(f64, @floatFromInt(max_width));
        const full: usize = @intFromFloat(fill_f);
        const frac = fill_f - @as(f64, @floatFromInt(full));
        try self.out(color);
        var i: usize = 0;
        while (i < full) : (i += 1) try self.out("\xe2\x96\x88");
        if (full < max_width) {
            const blocks = [_][]const u8{ " ", "\xe2\x96\x8f", "\xe2\x96\x8e", "\xe2\x96\x8d", "\xe2\x96\x8c", "\xe2\x96\x8b", "\xe2\x96\x8a", "\xe2\x96\x89" };
            try self.out(blocks[@intFromFloat(frac * 7.0)]);
            i = full + 1;
            while (i < max_width) : (i += 1) try self.out(" ");
        }
        try self.out(Style.reset);
    }

    pub fn kv(self: *Writer, label: []const u8, value: []const u8) !void {
        try self.emitRail(false);
        try self.style(Style.muted);
        try self.padWrite(label, 14, false);
        try self.style(Style.reset);
        try self.styled(Style.bold_white, value);
        try self.out("\n");
    }

    // ── Pagination ────────────────────────────────────────────

    pub fn paginate(self: *Writer, shown: usize, total: usize) !void {
        return self.paginatePage(shown, total, 0, 0);
    }

    pub fn paginatePage(self: *Writer, shown: usize, total: usize, page: usize, pages: usize) !void {
        if (self.format != .pretty) return;
        try self.style(Style.muted);
        var buf: [96]u8 = undefined;
        const s = if (page > 0 and pages > 1)
            std.fmt.bufPrint(&buf, "  {d}/{d} \xc2\xb7 page {d}/{d} \xc2\xb7 --page N | --all", .{ shown, total, page, pages }) catch return
        else
            std.fmt.bufPrint(&buf, "  {d}/{d} \xc2\xb7 --page N | --all", .{ shown, total }) catch return;
        try self.out(s);
        try self.style(Style.reset);
        try self.out("\n");
    }

    pub fn pnlColor(d: ?Decimal) ?[]const u8 {
        if (d) |val| {
            if (val.isNegative()) return Style.bold_red;
            if (val.mantissa != 0) return Style.bold_green;
        }
        return Style.muted;
    }

    pub fn jsonRaw(self: *Writer, body: []const u8) !void {
        if (self.cmd.len > 0) {
            try self.out("{\"v\":1,\"status\":\"ok\",\"cmd\":\"");
            try self.out(self.cmd);
            try self.out("\",\"data\":");
            try self.out(body);
            var ms_buf: [32]u8 = undefined;
            const ms = self.elapsedMs();
            const ms_str = std.fmt.bufPrint(&ms_buf, ",\"timing_ms\":{d}}}\n", .{ms}) catch ",\"timing_ms\":0}\n";
            try self.out(ms_str);
        } else {
            try self.out(body);
            try self.out("\n");
        }
    }

    pub fn rawJson(self: *Writer, data: []const u8) !void {
        try self.out(data);
        try self.out("\n");
    }

    pub fn jsonFmt(self: *Writer, comptime fmt: []const u8, fmtargs: anytype) !void {
        var buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, fmt, fmtargs) catch return;
        try self.jsonRaw(body);
    }

    pub fn elapsedMs(self: *Writer) u64 {
        if (self.start_ns == 0) return 0;
        const now = std.time.nanoTimestamp();
        const delta = now - self.start_ns;
        return if (delta > 0) @intCast(@divFloor(delta, 1_000_000)) else 0;
    }

    pub fn err(self: *Writer, msg: []const u8) !void {
        if (self.is_tty) {
            try self.ew(Style.bold_red);
            try self.ew("\xe2\x9c\x97 ");
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
            try self.ew("\xe2\x9c\x97 ");
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
            try self.out("\xe2\x9c\x93 ");
            try self.out(Style.reset);
        }
        try self.out(msg);
        try self.out("\n");
    }
};

pub fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) i += 1 else if (text[i] < 0xE0) i += 2 else if (text[i] < 0xF0) i += 3 else i += 4;
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
