//! Scrollable list widget with vim navigation, fuzzy search, and column sorting.

const std = @import("std");
const Buffer = @import("Buffer.zig");
const Terminal = @import("Terminal.zig");

const Rect = Buffer.Rect;
const Style = Buffer.Style;

const List = @This();

/// Maximum items the list can hold.
pub const MAX_ITEMS = 512;
/// Maximum columns per list.
pub const MAX_COLS = 12;
/// Maximum filter length.
pub const MAX_FILTER = 64;

pub const Column = struct {
    label: []const u8,
    width: u16, // 0 = auto-fill remaining space
    right_align: bool = false,
};

pub const Item = struct {
    /// Column values as strings. Up to MAX_COLS.
    cells: [MAX_COLS][]const u8 = .{""} ** MAX_COLS,
    /// Style per cell (default = white).
    styles: [MAX_COLS]Style = .{Style{}} ** MAX_COLS,
    /// Optional sort key for the current sort column (used for numeric sorting).
    sort_key: f64 = 0,
};

/// Callback for custom cell rendering. Return true if handled (widget skips default).
pub const RenderCellFn = *const fn (buf: *Buffer, x: u16, y: u16, width: u16, item: *const Item, col: usize, selected: bool) bool;

columns: []const Column,
items: []const Item,
total: usize,

/// Currently selected index (in filtered list).
selected: usize = 0,
/// Scroll offset (first visible row).
offset: usize = 0,

/// Search filter state.
filter: [MAX_FILTER]u8 = .{0} ** MAX_FILTER,
filter_len: usize = 0,
searching: bool = false,

/// Filtered indices into `items`.
filtered: [MAX_ITEMS]u16 = undefined,
filtered_count: usize = 0,

/// Sort state.
sort_col: usize = 0,
sort_desc: bool = true,

/// Title shown in the box border.
title: []const u8 = "",

/// Help text shown at bottom (e.g. "j/k:nav  /:search  s:sort  q:quit").
help: []const u8 = "j/k:nav  /:search  s:sort  q:quit",

/// Optional custom cell renderer.
on_render_cell: ?RenderCellFn = null,

pub fn init(columns: []const Column, items: []const Item, total: usize) List {
    var self = List{
        .columns = columns,
        .items = items,
        .total = total,
    };
    self.refilter();
    return self;
}

pub fn setItems(self: *List, items: []const Item, total: usize) void {
    self.items = items;
    self.total = total;
    self.refilter();
    if (self.filtered_count > 0) {
        if (self.selected >= self.filtered_count) self.selected = self.filtered_count - 1;
    } else {
        self.selected = 0;
    }
}

pub const Action = enum {
    none,
    select, // Enter pressed — selected item index available via selectedIndex()
    quit, // q or Esc (when not searching)
    sort, // s pressed — sort_col updated
    refresh, // r pressed
};

pub fn handleKey(self: *List, key: Terminal.Key) Action {
    if (self.searching) {
        switch (key) {
            .esc => {
                self.searching = false;
                self.filter_len = 0;
                self.refilter();
                // Keep selection in bounds but don't reset to 0
                if (self.filtered_count > 0) {
                    if (self.selected >= self.filtered_count) self.selected = self.filtered_count - 1;
                } else {
                    self.selected = 0;
                }
            },
            .enter => {
                self.searching = false;
            },
            .backspace => {
                if (self.filter_len > 0) {
                    self.filter_len -= 1;
                    self.refilter();
                    self.selected = 0;
                    self.offset = 0;
                }
            },
            .char => |c| {
                if (self.filter_len < MAX_FILTER) {
                    self.filter[self.filter_len] = c;
                    self.filter_len += 1;
                    self.refilter();
                    self.selected = 0;
                    self.offset = 0;
                }
            },
            else => {},
        }
        return .none;
    }

    switch (key) {
        .char => |c| switch (c) {
            'j' => self.moveDown(1),
            'k' => self.moveUp(1),
            'J' => self.moveDown(10),
            'K' => self.moveUp(10),
            'g' => {
                self.selected = 0;
                self.offset = 0;
            },
            'G' => {
                if (self.filtered_count > 0) {
                    self.selected = self.filtered_count - 1;
                }
            },
            '/' => {
                self.searching = true;
                self.filter_len = 0;
            },
            'q' => return .quit,
            's' => {
                self.sort_col = (self.sort_col + 1) % self.columns.len;
                self.sort_desc = !self.sort_desc;
                return .sort;
            },
            'r' => return .refresh,
            else => {},
        },
        .up => self.moveUp(1),
        .down => self.moveDown(1),
        .enter => return .select,
        .esc => return .quit,
        .tab => {
            self.sort_col = (self.sort_col + 1) % self.columns.len;
            return .sort;
        },
        else => {},
    }
    return .none;
}

fn moveDown(self: *List, n: usize) void {
    if (self.filtered_count == 0) return;
    self.selected = @min(self.selected + n, self.filtered_count - 1);
}

fn moveUp(self: *List, n: usize) void {
    self.selected -|= n;
}

/// Get the original item index of the currently selected row.
pub fn selectedIndex(self: *const List) ?usize {
    if (self.filtered_count == 0) return null;
    return self.filtered[self.selected];
}

pub fn render(self: *List, buf: *Buffer, area: Rect) void {
    if (area.w < 4 or area.h < 4) return;

    const dim = Style{ .fg = .grey, .dim = true };
    const header_style = Style{ .fg = .cyan, .bold = true };
    const sel_style = Style{ .fg = .bright_white, .bg = .blue, .bold = true };

    // Box border
    buf.drawBox(area, self.title, Style{ .fg = .cyan });

    // Content area (inside the box)
    const inner = Rect{
        .x = area.x + 1,
        .y = area.y + 1,
        .w = area.w -| 2,
        .h = area.h -| 2,
    };
    if (inner.w < 2 or inner.h < 2) return;

    // Layout: header (1 row) + data rows + help line (1 row) at bottom
    const help_y = inner.y + inner.h - 1;
    const header_y = inner.y;
    const data_start_y = inner.y + 1;
    const data_h = inner.h -| 2; // -1 header, -1 help
    if (data_h == 0) return;

    // ── Column headers ──
    var cx: u16 = inner.x;
    for (self.columns, 0..) |col, ci| {
        const cw = colWidth(col, cx, inner);
        if (cw == 0) break;

        if (ci == self.sort_col) {
            const arrow: []const u8 = if (self.sort_desc) "\xe2\x96\xbc" else "\xe2\x96\xb2"; // ▼ ▲
            buf.putStr(cx, header_y, arrow, header_style);
            buf.putStr(cx + 1, header_y, col.label, header_style);
        } else {
            buf.putStr(cx, header_y, col.label, dim);
        }
        cx += cw + 1;
    }

    // ── Data rows ──
    // Ensure selected is visible
    if (self.selected < self.offset) self.offset = self.selected;
    if (self.selected >= self.offset + data_h) self.offset = self.selected - data_h + 1;

    var row: u16 = 0;
    while (row < data_h) : (row += 1) {
        const idx = self.offset + row;
        if (idx >= self.filtered_count) break;

        const item_idx = self.filtered[idx];
        const item = &self.items[item_idx];
        const y = data_start_y + row;
        const is_selected = (idx == self.selected);

        // Selection highlight — fill entire row
        if (is_selected) {
            var fill_x: u16 = inner.x;
            while (fill_x < inner.x + inner.w) : (fill_x += 1) {
                const cell = buf.get(fill_x, y);
                cell.setChar(' ');
                cell.style = sel_style;
            }
        }

        // Render columns
        cx = inner.x;
        for (self.columns, 0..) |col, ci| {
            const cw = colWidth(col, cx, inner);
            if (cw == 0) break;

            // Custom renderer gets first shot
            if (self.on_render_cell) |render_fn| {
                if (render_fn(buf, cx, y, cw, item, ci, is_selected)) {
                    cx += cw + 1;
                    continue;
                }
            }

            const text = item.cells[ci];
            const base_style = if (is_selected) sel_style else item.styles[ci];

            if (col.right_align) {
                buf.putStrRight(cx, y, cw, text, base_style);
            } else {
                buf.putStr(cx, y, text, base_style);
            }
            cx += cw + 1;
        }
    }

    // ── Bottom bar: search or help ──
    if (self.searching) {
        // Search input: "> query█   3 of 229"
        const search_style = Style{ .fg = .yellow, .bold = true };
        const count_style = Style{ .fg = .grey };

        buf.putStr(inner.x, help_y, "> ", search_style);
        buf.putStr(inner.x + 2, help_y, self.filter[0..self.filter_len], search_style);
        // Cursor block
        const cursor_x = inner.x + 2 + @as(u16, @intCast(self.filter_len));
        if (cursor_x < inner.x + inner.w) {
            const cursor_cell = buf.get(cursor_x, help_y);
            cursor_cell.setChar(' ');
            cursor_cell.style = Style{ .fg = .black, .bg = .yellow };
        }

        // Match count on the right
        var count_buf: [24]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} of {d}", .{ self.filtered_count, self.total }) catch "";
        if (count_str.len + 1 < inner.w) {
            buf.putStrRight(inner.x, help_y, inner.w, count_str, count_style);
        }
    } else {
        // Help line + position indicator
        buf.putStr(inner.x, help_y, self.help, dim);

        // Position on the right: "5/229"
        var pos_buf: [24]u8 = undefined;
        const pos_str = if (self.filtered_count > 0)
            std.fmt.bufPrint(&pos_buf, "{d}/{d}", .{ self.selected + 1, self.filtered_count }) catch ""
        else
            std.fmt.bufPrint(&pos_buf, "0/{d}", .{self.total}) catch "";
        if (pos_str.len + 1 < inner.w) {
            buf.putStrRight(inner.x, help_y, inner.w, pos_str, dim);
        }
    }
}

fn colWidth(col: Column, cx: u16, inner: Rect) u16 {
    return if (col.width == 0) inner.w -| (cx - inner.x) else @min(col.width, inner.w -| (cx - inner.x));
}

fn refilter(self: *List) void {
    self.filtered_count = 0;
    const n = @min(self.total, MAX_ITEMS);

    if (self.filter_len == 0) {
        for (0..n) |i| {
            self.filtered[self.filtered_count] = @intCast(i);
            self.filtered_count += 1;
        }
        return;
    }

    const needle = self.filter[0..self.filter_len];
    for (0..n) |i| {
        var match_found = false;
        for (0..self.columns.len) |ci| {
            if (containsIgnoreCase(self.items[i].cells[ci], needle)) {
                match_found = true;
                break;
            }
        }
        if (match_found) {
            self.filtered[self.filtered_count] = @intCast(i);
            self.filtered_count += 1;
        }
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var ok = true;
        for (0..needle.len) |j| {
            if (toLower(haystack[i + j]) != toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

test "filter case insensitive" {
    try std.testing.expect(containsIgnoreCase("Bitcoin BTC", "btc"));
    try std.testing.expect(containsIgnoreCase("ETH", "eth"));
    try std.testing.expect(!containsIgnoreCase("SOL", "btc"));
}
