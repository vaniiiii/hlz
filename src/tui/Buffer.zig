//! Double-buffered cell grid for TUI rendering. Widgets write to Buffer,
//! Terminal diffs and flushes only changed cells.

const std = @import("std");

const Buffer = @This();

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,

    pub const RESET = Style{};
};

pub const Color = enum(u8) {
    default = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_cyan = 96,
    bright_white = 97,
    grey = 90,
};

pub const Cell = struct {
    char: [4]u8 = .{ ' ', 0, 0, 0 },
    char_len: u2 = 1,
    style: Style = .{},

    pub fn setChar(self: *Cell, ch: u8) void {
        self.char = .{ ch, 0, 0, 0 };
        self.char_len = 1;
    }

    pub fn setUtf8(self: *Cell, bytes: []const u8) void {
        self.char_len = @intCast(@min(bytes.len, 4));
        @memcpy(self.char[0..self.char_len], bytes[0..self.char_len]);
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return std.mem.eql(u8, &a.char, &b.char) and a.char_len == b.char_len and
            a.style.fg == b.style.fg and a.style.bg == b.style.bg and
            a.style.bold == b.style.bold and a.style.dim == b.style.dim;
    }
};

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn area(self: Rect) u32 {
        return @as(u32, self.w) * @as(u32, self.h);
    }

    /// Split horizontally into N equal parts.
    pub fn splitH(self: Rect, n: u16) [8]Rect {
        var result: [8]Rect = undefined;
        const part_w = self.w / n;
        for (0..@min(n, 8)) |i| {
            const idx: u16 = @intCast(i);
            result[i] = .{
                .x = self.x + idx * part_w,
                .y = self.y,
                .w = if (idx == n - 1) self.w - idx * part_w else part_w,
                .h = self.h,
            };
        }
        return result;
    }

    /// Split vertically: top gets `top_h` rows, bottom gets the rest.
    pub fn splitV(self: Rect, top_h: u16) [2]Rect {
        const th = @min(top_h, self.h);
        return .{
            .{ .x = self.x, .y = self.y, .w = self.w, .h = th },
            .{ .x = self.x, .y = self.y + th, .w = self.w, .h = self.h -| th },
        };
    }

    /// Shrink by margin on all sides.
    pub fn inner(self: Rect, margin: u16) Rect {
        const m2 = margin * 2;
        if (self.w <= m2 or self.h <= m2) return .{ .x = self.x, .y = self.y, .w = 0, .h = 0 };
        return .{
            .x = self.x + margin,
            .y = self.y + margin,
            .w = self.w - m2,
            .h = self.h - m2,
        };
    }
};

cells: []Cell,
width: u16,
height: u16,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
    const size = @as(usize, width) * @as(usize, height);
    const cells = try allocator.alloc(Cell, size);
    @memset(cells, Cell{});
    return .{ .cells = cells, .width = width, .height = height, .allocator = allocator };
}

pub fn deinit(self: *Buffer) void {
    self.allocator.free(self.cells);
}

pub fn resize(self: *Buffer, width: u16, height: u16) !void {
    self.allocator.free(self.cells);
    const size = @as(usize, width) * @as(usize, height);
    self.cells = try self.allocator.alloc(Cell, size);
    @memset(self.cells, Cell{});
    self.width = width;
    self.height = height;
}

pub fn clear(self: *Buffer) void {
    @memset(self.cells, Cell{});
}

pub fn get(self: *Buffer, x: u16, y: u16) *Cell {
    const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    return &self.cells[idx];
}

pub fn getConst(self: *const Buffer, x: u16, y: u16) Cell {
    const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    return self.cells[idx];
}

/// Write a string at (x, y) with a style. Clips to buffer width.
pub fn putStr(self: *Buffer, x: u16, y: u16, text: []const u8, style: Style) void {
    if (y >= self.height) return;
    var col = x;
    var i: usize = 0;
    while (i < text.len and col < self.width) {
        const byte = text[i];
        const cell = self.get(col, y);
        if (byte < 0x80) {
            cell.setChar(byte);
            cell.style = style;
            col += 1;
            i += 1;
        } else {
            // UTF-8 multi-byte
            const len: usize = if (byte >= 0xF0) 4 else if (byte >= 0xE0) 3 else 2;
            const end = @min(i + len, text.len);
            cell.setUtf8(text[i..end]);
            cell.style = style;
            col += 1; // Assume single-width for now
            i = end;
        }
    }
}

/// Write a right-aligned string.
pub fn putStrRight(self: *Buffer, x: u16, y: u16, width: u16, text: []const u8, style: Style) void {
    if (text.len >= width) {
        self.putStr(x, y, text[0..width], style);
    } else {
        const offset: u16 = width - @as(u16, @intCast(text.len));
        self.putStr(x + offset, y, text, style);
    }
}

/// Draw a horizontal bar chart segment using block characters.
/// value/max determines fill, width is max characters.
pub fn putBar(self: *Buffer, x: u16, y: u16, value: f64, max_value: f64, width: u16, style: Style) void {
    if (max_value <= 0 or width == 0) return;
    const ratio = @min(value / max_value, 1.0);
    var total_eighths: usize = @intFromFloat(ratio * @as(f64, @floatFromInt(width)) * 8.0);
    // Minimum: show at least ▏ for any non-zero value
    if (value > 0 and total_eighths == 0) total_eighths = 1;
    const full = total_eighths / 8;
    const remainder = total_eighths % 8;

    // Block chars (horizontal): █ ▉ ▊ ▋ ▌ ▍ ▎ ▏
    const partials = [7][3]u8{
        .{ 0xe2, 0x96, 0x8f }, // ▏
        .{ 0xe2, 0x96, 0x8e }, // ▎
        .{ 0xe2, 0x96, 0x8d }, // ▍
        .{ 0xe2, 0x96, 0x8c }, // ▌
        .{ 0xe2, 0x96, 0x8b }, // ▋
        .{ 0xe2, 0x96, 0x8a }, // ▊
        .{ 0xe2, 0x96, 0x89 }, // ▉
    };
    const full_block = [3]u8{ 0xe2, 0x96, 0x88 }; // █

    var col = x;
    var i: usize = 0;
    while (i < full and col < x + width and col < self.width) : ({ i += 1; col += 1; }) {
        const cell = self.get(col, y);
        cell.setUtf8(&full_block);
        cell.style = style;
    }
    if (remainder > 0 and col < x + width and col < self.width) {
        const cell = self.get(col, y);
        cell.setUtf8(&partials[remainder - 1]);
        cell.style = style;
    }
}

/// Draw a background-fill bar (N cells with colored background, space char).
pub fn putBgBar(self: *Buffer, x: u16, y: u16, width: u16, style: Style) void {
    if (y >= self.height) return;
    var col = x;
    while (col < x + width and col < self.width) : (col += 1) {
        const cell = self.get(col, y);
        cell.setChar(' ');
        cell.style = style;
    }
}

/// Draw a sparkline from values.
pub fn putSparkline(self: *Buffer, x: u16, y: u16, values: []const f64, style: Style) void {
    // Vertical bar chars: ▁▂▃▄▅▆▇█
    const ticks = [8][3]u8{
        .{ 0xe2, 0x96, 0x81 }, // ▁
        .{ 0xe2, 0x96, 0x82 }, // ▂
        .{ 0xe2, 0x96, 0x83 }, // ▃
        .{ 0xe2, 0x96, 0x84 }, // ▄
        .{ 0xe2, 0x96, 0x85 }, // ▅
        .{ 0xe2, 0x96, 0x86 }, // ▆
        .{ 0xe2, 0x96, 0x87 }, // ▇
        .{ 0xe2, 0x96, 0x88 }, // █
    };

    var max: f64 = 0;
    for (values) |v| max = @max(max, v);
    if (max <= 0) return;

    var col = x;
    for (values) |v| {
        if (col >= self.width) break;
        const idx: usize = @intFromFloat(@min(v / max, 0.999) * 8.0);
        const cell = self.get(col, y);
        cell.setUtf8(&ticks[idx]);
        cell.style = style;
        col += 1;
    }
}

/// Draw a box border using Unicode box-drawing characters.
pub fn drawBox(self: *Buffer, rect: Rect, title: ?[]const u8, style: Style) void {
    if (rect.w < 2 or rect.h < 2) return;
    const x = rect.x;
    const y = rect.y;
    const w = rect.w;
    const h = rect.h;

    // Corners
    self.putUtf8(x, y, "\xe2\x95\xad", style); // ╭
    self.putUtf8(x + w - 1, y, "\xe2\x95\xae", style); // ╮
    self.putUtf8(x, y + h - 1, "\xe2\x95\xb0", style); // ╰
    self.putUtf8(x + w - 1, y + h - 1, "\xe2\x95\xaf", style); // ╯

    // Horizontal lines
    var col: u16 = x + 1;
    while (col < x + w - 1) : (col += 1) {
        self.putUtf8(col, y, "\xe2\x94\x80", style); // ─
        self.putUtf8(col, y + h - 1, "\xe2\x94\x80", style); // ─
    }

    // Vertical lines
    var row: u16 = y + 1;
    while (row < y + h - 1) : (row += 1) {
        self.putUtf8(x, row, "\xe2\x94\x82", style); // │
        self.putUtf8(x + w - 1, row, "\xe2\x94\x82", style); // │
    }

    // Title
    if (title) |t| {
        if (t.len + 4 <= w) {
            self.putUtf8(x + 1, y, "\xe2\x94\x80", style); // ─
            self.putStr(x + 2, y, " ", style);
            self.putStr(x + 3, y, t, style);
            self.putStr(x + 3 + @as(u16, @intCast(t.len)), y, " ", style);
        }
    }
}

fn putUtf8(self: *Buffer, x: u16, y: u16, bytes: []const u8, style: Style) void {
    if (x >= self.width or y >= self.height) return;
    const cell = self.get(x, y);
    cell.setUtf8(bytes);
    cell.style = style;
}

/// Flush: diff `self` against `prev`, emit ANSI escape sequences for changed cells.
pub fn flush(self: *const Buffer, prev: *const Buffer) void {
    const stdout = std.fs.File.stdout();
    // Use a large static buffer to batch writes
    var out_buf: [65536]u8 = undefined;
    var pos: usize = 0;

    var last_style = Style{};
    var last_x: u16 = 0xFFFF;
    var last_y: u16 = 0xFFFF;

    var y: u16 = 0;
    while (y < self.height) : (y += 1) {
        var x: u16 = 0;
        while (x < self.width) : (x += 1) {
            const cur = self.getConst(x, y);
            const prv = if (prev.width == self.width and prev.height == self.height)
                prev.getConst(x, y)
            else
                Cell{};

            if (cur.eql(prv)) continue;

            // Move cursor if needed
            if (x != last_x +% 1 or y != last_y) {
                const move_seq = std.fmt.bufPrint(out_buf[pos..], "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch break;
                pos += move_seq.len;
            }

            // Style changes
            if (cur.style.fg != last_style.fg or cur.style.bg != last_style.bg or
                cur.style.bold != last_style.bold or cur.style.dim != last_style.dim)
            {
                // Reset then set
                const reset = "\x1b[0m";
                if (pos + reset.len <= out_buf.len) {
                    @memcpy(out_buf[pos..][0..reset.len], reset);
                    pos += reset.len;
                }
                if (cur.style.bold) {
                    const bold = "\x1b[1m";
                    if (pos + bold.len <= out_buf.len) { @memcpy(out_buf[pos..][0..bold.len], bold); pos += bold.len; }
                }
                if (cur.style.dim) {
                    const dim = "\x1b[2m";
                    if (pos + dim.len <= out_buf.len) { @memcpy(out_buf[pos..][0..dim.len], dim); pos += dim.len; }
                }
                if (cur.style.fg != .default) {
                    const fg_seq = std.fmt.bufPrint(out_buf[pos..], "\x1b[{d}m", .{@intFromEnum(cur.style.fg)}) catch break;
                    pos += fg_seq.len;
                }
                if (cur.style.bg != .default) {
                    const bg_seq = std.fmt.bufPrint(out_buf[pos..], "\x1b[{d}m", .{@intFromEnum(cur.style.bg) + 10}) catch break;
                    pos += bg_seq.len;
                }
                last_style = cur.style;
            }

            // Character
            const ch_slice = cur.char[0..cur.char_len];
            if (pos + ch_slice.len <= out_buf.len) {
                @memcpy(out_buf[pos..][0..ch_slice.len], ch_slice);
                pos += ch_slice.len;
            }

            last_x = x;
            last_y = y;

            // Flush if buffer is getting full
            if (pos > out_buf.len - 256) {
                stdout.writeAll(out_buf[0..pos]) catch {};
                pos = 0;
            }
        }
    }

    // Reset style at end
    const final_reset = "\x1b[0m";
    if (pos + final_reset.len <= out_buf.len) {
        @memcpy(out_buf[pos..][0..final_reset.len], final_reset);
        pos += final_reset.len;
    }

    if (pos > 0) stdout.writeAll(out_buf[0..pos]) catch {};
}
