//! Candlestick chart renderer with sub-cell resolution.
//! Uses Unicode box-drawing characters for wicks and bodies:
//!   ┃ body, │ wick, ╽╿ transitions, ╻╹ half body, ╷╵ half wick

const std = @import("std");
const Buffer = @import("Buffer.zig");

pub const VOID = " ";
pub const BODY = "┃";
pub const WICK = "│";
pub const UP = "╽"; // wick on top, body below
pub const DOWN = "╿"; // body on top, wick below
pub const HALF_BODY_BOT = "╻";
pub const HALF_WICK_BOT = "╷";
pub const HALF_BODY_TOP = "╹";
pub const HALF_WICK_TOP = "╵";

pub const Candle = struct {
    t: i64 = 0, // timestamp ms
    o: f64 = 0, // open
    h: f64 = 0, // high
    l: f64 = 0, // low
    c: f64 = 0, // close
    v: f64 = 0, // volume
};

pub const MAX_CANDLES = 512;

const C = Buffer.Color;
const hl_buy = C.hex(0x1fa67d);
const hl_sell = C.hex(0xed7088);
const hl_muted = C.hex(0x949e9c);
const hl_border = C.hex(0x273035);
const hl_text2 = C.hex(0xd2dad7);

const bullish_style = Buffer.Style{ .fg = hl_buy };
const bearish_style = Buffer.Style{ .fg = hl_sell };
const wick_bullish = Buffer.Style{ .fg = hl_buy };
const wick_bearish = Buffer.Style{ .fg = hl_sell };
const vol_bull = Buffer.Style{ .fg = hl_buy, .dim = true };
const vol_bear = Buffer.Style{ .fg = hl_sell, .dim = true };
const axis_style = Buffer.Style{ .fg = hl_border };
const label_style = Buffer.Style{ .fg = hl_muted };
const grid_style = Buffer.Style{ .fg = hl_border };

pub fn render(
    buf: *Buffer,
    candles: []const Candle,
    rect: Buffer.Rect,
    live_price: f64,
) void {
    if (candles.len == 0 or rect.w < 15 or rect.h < 8) return;

    // Reserve space: y-axis on right (12 chars), volume at bottom (1/4 of height), x-axis (2 rows)
    const y_axis_w: u16 = 11;
    const x_axis_h: u16 = 1;
    const chart_w: u16 = if (rect.w > y_axis_w + 2) rect.w - y_axis_w else 2;
    const total_h: u16 = if (rect.h > x_axis_h + 4) rect.h - x_axis_h else 4;
    const vol_h: u16 = @max(2, total_h / 5);
    const candle_h: u16 = if (total_h > vol_h + 1) total_h - vol_h - 1 else 2; // -1 for separator

    // How many candles fit (1 col each, no gap for density)
    const visible = @min(candles.len, @as(usize, chart_w));
    const start_idx = if (candles.len > visible) candles.len - visible else 0;
    const slice = candles[start_idx..];

    // Find price range from visible candles
    var price_min: f64 = std.math.floatMax(f64);
    var price_max: f64 = -std.math.floatMax(f64);
    var vol_max: f64 = 0;
    for (slice) |c| {
        if (c.h == 0 and c.l == 0) continue;
        price_min = @min(price_min, c.l);
        price_max = @max(price_max, c.h);
        vol_max = @max(vol_max, c.v);
    }
    if (price_min >= price_max) {
        price_max = price_min + 1;
    }

    // Add 2% padding to price range
    const range = price_max - price_min;
    price_min -= range * 0.02;
    price_max += range * 0.02;

    // Render each candle
    for (slice, 0..) |candle, i| {
        if (candle.h == 0 and candle.l == 0) continue;
        const x: u16 = rect.x + @as(u16, @intCast(i));
        const is_bull = candle.c >= candle.o;
        const style = if (is_bull) bullish_style else bearish_style;

        renderCandle(buf, candle, x, rect.y, candle_h, price_min, price_max, style);

        // Volume bar
        if (vol_max > 0 and vol_h > 0) {
            const vol_y = rect.y + candle_h + 1; // +1 for separator
            const vr = candle.v / vol_max;
            const bar_h: u16 = @max(1, @as(u16, @intFromFloat(vr * @as(f64, @floatFromInt(vol_h)))));
            const bar_start = vol_y + vol_h - bar_h;
            const vs = if (is_bull) vol_bull else vol_bear;
            var vy = bar_start;
            while (vy < vol_y + vol_h) : (vy += 1) {
                const cell = buf.get(x, vy);
                cell.setUtf8("█");
                cell.style = vs;
            }
        }
    }

    // Y-axis labels (right side)
    const axis_x = rect.x + chart_w + 1;
    const n_labels: u16 = @max(2, candle_h / 4);
    for (0..n_labels) |li| {
        const frac = @as(f64, @floatFromInt(li)) / @as(f64, @floatFromInt(n_labels - 1));
        const price = price_max - frac * (price_max - price_min);
        const y: u16 = rect.y + @as(u16, @intFromFloat(frac * @as(f64, @floatFromInt(candle_h -| 1))));
        var lbl: [12]u8 = undefined;
        const s = formatPrice(&lbl, price);
        buf.putStr(axis_x, y, s, label_style);

        // Grid line
        if (li > 0 and li < n_labels - 1) {
            var gx: u16 = rect.x;
            while (gx < rect.x + chart_w) : (gx += 2) {
                const gc = buf.get(gx, y);
                if (gc.char[0] == ' ' or gc.char[0] == 0) {
                    gc.setUtf8("·");
                    gc.style = grid_style;
                }
            }
        }

        buf.putStr(axis_x -| 1, y, "─", axis_style);
    }

    // Separator line between candles and volume
    const sep_y = rect.y + candle_h;
    var sx: u16 = rect.x;
    while (sx < rect.x + chart_w) : (sx += 1) {
        buf.putStr(sx, sep_y, "─", axis_style);
    }

    // X-axis time labels (adaptive by visible span)
    const time_y = rect.y + total_h;
    const first_ts = slice[0].t;
    const last_ts = slice[slice.len - 1].t;
    const span_ms: i64 = if (last_ts >= first_ts) last_ts - first_ts else first_ts - last_ts;
    const mode = axisLabelMode(span_ms);
    const label_w: usize = switch (mode) {
        .intraday => 5,   // HH:mm
        .day => 6,        // Sep 7
        .month_year => 8, // Sep 2026
    };
    const label_spacing: usize = @max(label_w + 2, @as(usize, chart_w) / 6);
    var last_label_end: i32 = -100;
    var prev_lbl: [12]u8 = undefined;
    var prev_lbl_len: usize = 0;

    for (0..visible) |i| {
        const candle = slice[i];
        const periodic = i % label_spacing == 0;
        const last = i == visible - 1;
        const boundary = isBoundaryLabel(candle.t, mode);
        if (!periodic and !last and !boundary) continue;

        const x: u16 = rect.x + @as(u16, @intCast(i));
        var tlbl: [12]u8 = undefined;
        const ts = formatAxisLabel(&tlbl, candle.t, mode);
        if (ts.len == 0) continue;

        // Suppress repeated labels unless this is an emphasized boundary.
        if (!boundary and ts.len == prev_lbl_len and std.mem.eql(u8, ts, prev_lbl[0..prev_lbl_len])) continue;

        const end_x: i32 = @as(i32, x) + @as(i32, @intCast(ts.len)) - 1;
        if (@as(i32, x) <= last_label_end + 1) continue;
        if (end_x >= @as(i32, rect.x + rect.w)) continue;

        buf.putStr(x, time_y, ts, label_style);
        last_label_end = end_x;
        prev_lbl_len = ts.len;
        @memcpy(prev_lbl[0..ts.len], ts);
    }

    // Live price line — dashed line across chart + highlighted label
    const show_price = if (live_price > 0) live_price else if (slice.len > 0) slice[slice.len - 1].c else 0;
    if (show_price > 0 and show_price >= price_min and show_price <= price_max) {
        const py = priceToY(show_price, rect.y, candle_h, price_min, price_max);
        // Determine color from last candle direction
        const is_bull = if (slice.len > 0) slice[slice.len - 1].c >= slice[slice.len - 1].o else true;
        const line_style = Buffer.Style{ .fg = if (is_bull) hl_buy else hl_sell, .dim = true };
        // Dashed line across chart area (only on empty cells)
        var lx: u16 = rect.x;
        while (lx < rect.x + chart_w) : (lx += 1) {
            const gc = buf.get(lx, py);
            if (gc.char[0] == ' ' or gc.char[0] == 0) {
                if (lx % 3 == 0) {
                    gc.setUtf8("╌");
                    gc.style = line_style;
                }
            }
        }
        // Price badge on y-axis
        var plbl: [12]u8 = undefined;
        const ps = formatPrice(&plbl, show_price);
        const price_style = Buffer.Style{
            .fg = C.hex(0xffffff),
            .bg = if (is_bull) hl_buy else hl_sell,
            .bold = true,
        };
        buf.putStr(axis_x -| 1, py, " ", price_style);
        buf.putStr(axis_x, py, ps, price_style);
        const pad_x = axis_x + @as(u16, @intCast(ps.len));
        if (pad_x < rect.x + rect.w) {
            buf.putStr(pad_x, py, " ", price_style);
        }
    }
}

fn renderCandle(
    buf: *Buffer,
    candle: Candle,
    x: u16,
    top_y: u16,
    height: u16,
    price_min: f64,
    price_max: f64,
    style: Buffer.Style,
) void {
    // Map prices to sub-pixel coordinates (2 sub-pixels per row)
    const h_f = @as(f64, @floatFromInt(height));
    const range = price_max - price_min;
    if (range <= 0) return;

    const high_sp = (price_max - candle.h) / range * h_f;
    const low_sp = (price_max - candle.l) / range * h_f;
    const body_top_sp = (price_max - @max(candle.o, candle.c)) / range * h_f;
    const body_bot_sp = (price_max - @min(candle.o, candle.c)) / range * h_f;

    // Render each row
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        const y = top_y + row;
        const row_f = @as(f64, @floatFromInt(row));
        const row_top = row_f;
        const row_mid = row_f + 0.5;
        const row_bot = row_f + 1.0;

        // Classify this row
        const has_wick_top = high_sp < row_mid and low_sp > row_top;
        const has_wick_bot = low_sp > row_mid and high_sp < row_bot;
        const has_body_top = body_top_sp < row_mid and body_bot_sp > row_top;
        const has_body_bot = body_bot_sp > row_mid and body_top_sp < row_bot;

        const in_body = body_top_sp <= row_top + 0.1 and body_bot_sp >= row_bot - 0.1;
        const in_wick_only_top = high_sp <= row_top + 0.1 and body_top_sp >= row_mid;
        const in_wick_only_bot = low_sp >= row_bot - 0.1 and body_bot_sp <= row_mid;
        _ = has_wick_top;
        _ = has_wick_bot;
        _ = has_body_top;
        _ = has_body_bot;

        const sym: []const u8 = if (in_body)
            BODY
        else if (body_top_sp >= row_top and body_top_sp < row_mid and body_bot_sp > row_mid and body_bot_sp <= row_bot)
            // Body fits in one row but doesn't fill it
            if (body_bot_sp - body_top_sp < 0.3)
                HALF_BODY_BOT // tiny body, show as dot
            else
                BODY
        else if (body_top_sp >= row_top and body_top_sp < row_mid and body_bot_sp >= row_bot - 0.1)
            // Body starts in top half, extends past bottom
            if (high_sp < body_top_sp - 0.3) UP else BODY
        else if (body_top_sp <= row_top + 0.1 and body_bot_sp > row_mid and body_bot_sp < row_bot)
            // Body from top, ends in bottom half
            if (low_sp > body_bot_sp + 0.3) DOWN else BODY
        else if (body_top_sp >= row_mid and body_top_sp < row_bot and body_bot_sp >= row_bot - 0.1)
            HALF_BODY_TOP
        else if (body_top_sp <= row_top + 0.1 and body_bot_sp > row_top and body_bot_sp <= row_mid)
            HALF_BODY_BOT
        else if (in_wick_only_top and in_wick_only_bot)
            WICK
        else if (high_sp >= row_top and high_sp < row_mid and low_sp > row_mid)
            HALF_WICK_BOT
        else if (low_sp > row_mid and low_sp <= row_bot and high_sp < row_top + 0.1)
            HALF_WICK_TOP
        else if (high_sp <= row_top + 0.1 and low_sp >= row_bot - 0.1)
            WICK
        else if (high_sp >= row_top and high_sp < row_bot and low_sp > row_top)
            HALF_WICK_BOT
        else if (low_sp > row_top and low_sp <= row_bot and high_sp <= row_top + 0.1)
            if (low_sp < row_mid) WICK else HALF_WICK_TOP
        else
            continue; // nothing to draw

        const cell = buf.get(x, y);
        cell.setUtf8(sym);
        cell.style = style;
    }
}

fn priceToY(price: f64, top_y: u16, height: u16, price_min: f64, price_max: f64) u16 {
    const range = price_max - price_min;
    if (range <= 0) return top_y;
    const frac = (price_max - price) / range;
    const row = @as(u16, @intFromFloat(@max(0, @min(frac * @as(f64, @floatFromInt(height -| 1)), @as(f64, @floatFromInt(height -| 1))))));
    return top_y + row;
}

fn formatPrice(buf: *[12]u8, price: f64) []const u8 {
    if (price >= 10000) {
        return std.fmt.bufPrint(buf, "{d:.0}", .{price}) catch "?";
    } else if (price >= 100) {
        return std.fmt.bufPrint(buf, "{d:.1}", .{price}) catch "?";
    } else if (price >= 1) {
        return std.fmt.bufPrint(buf, "{d:.2}", .{price}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.4}", .{price}) catch "?";
    }
}

const AxisLabelMode = enum { intraday, day, month_year };

fn axisLabelMode(span_ms: i64) AxisLabelMode {
    const day_ms: i64 = 86_400_000;
    if (span_ms <= 36 * 3_600_000) return .intraday;
    if (span_ms <= 365 * day_ms) return .day;
    return .month_year;
}

fn isBoundaryLabel(ts_ms: i64, mode: AxisLabelMode) bool {
    const p = datePartsUtc(ts_ms);
    return switch (mode) {
        .intraday => p.hour == 0 and p.minute == 0,
        .day => p.day == 1 and p.hour == 0,
        .month_year => p.month == 1 and p.day == 1 and p.hour == 0,
    };
}

fn formatAxisLabel(buf: *[12]u8, ts_ms: i64, mode: AxisLabelMode) []const u8 {
    const p = datePartsUtc(ts_ms);
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const m = months[@as(usize, p.month - 1)];
    return switch (mode) {
        .intraday => std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ p.hour, p.minute }) catch "??:??",
        .day => std.fmt.bufPrint(buf, "{s} {d}", .{ m, p.day }) catch "",
        .month_year => std.fmt.bufPrint(buf, "{s} {d}", .{ m, p.year }) catch "",
    };
}

const DateParts = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

/// UTC date decomposition from Unix milliseconds.
fn datePartsUtc(ts_ms: i64) DateParts {
    const sec = @divFloor(ts_ms, 1000);
    const day = @divFloor(sec, 86_400);
    const day_s = @mod(sec, 86_400);
    const hour: u8 = @intCast(@divFloor(day_s, 3600));
    const minute: u8 = @intCast(@divFloor(@mod(day_s, 3600), 60));

    // Howard Hinnant civil_from_days algorithm (days since 1970-01-01 UTC).
    const z = day + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9)); // [1, 12]
    const year: i32 = @intCast(y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)));

    return .{
        .year = year,
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = hour,
        .minute = minute,
    };
}

fn formatTime(buf: *[6]u8, ts_ms: i64) []const u8 {
    const p = datePartsUtc(ts_ms);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ p.hour, p.minute }) catch "??:??";
}

// ── Tests ─────────────────────────────────────────────────────────

test "formatPrice" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("67530", formatPrice(&buf, 67530.0));
    var buf2: [12]u8 = undefined;
    try std.testing.expectEqualStrings("0.0034", formatPrice(&buf2, 0.0034));
}

test "formatTime" {
    var buf: [6]u8 = undefined;
    // 1772132400000 ms = some time
    const s = formatTime(&buf, 1772132400000);
    try std.testing.expect(s.len == 5);
    try std.testing.expect(s[2] == ':');
}
