//! Quick TUI demo — run with: zig build tui-demo
//! Press 'q' to quit, arrows to scroll.

const std = @import("std");
const Terminal = @import("Terminal");
const Buffer = @import("Buffer");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var term = try Terminal.init();
    defer term.deinit();
    Terminal.clear();

    var current = try Buffer.init(alloc, term.width, term.height);
    defer current.deinit();
    var prev = try Buffer.init(alloc, term.width, term.height);
    defer prev.deinit();

    const green = Buffer.Style{ .fg = .green, .bold = true };
    const red = Buffer.Style{ .fg = .red, .bold = true };
    const cyan = Buffer.Style{ .fg = .cyan, .bold = true };
    const dim = Buffer.Style{ .fg = .grey, .dim = true };
    const white = Buffer.Style{ .fg = .bright_white };
    const yellow = Buffer.Style{ .fg = .yellow, .bold = true };

    var frame: u32 = 0;
    while (true) {
        current.clear();

        // Header box
        const header_rect = Buffer.Rect{ .x = 0, .y = 0, .w = term.width, .h = 3 };
        current.drawBox(header_rect, "HL TRADING TERMINAL", cyan);
        current.putStr(3, 1, "Press 'q' to quit", dim);

        // Funding rates panel
        const panel = Buffer.Rect{ .x = 1, .y = 4, .w = term.width - 2, .h = 12 };
        current.drawBox(panel, "FUNDING RATES", cyan);

        const coins = [_][]const u8{ "TRUMP", "WIF", "HYPE", "SOL", "BTC", "ETH", "DOGE" };
        const rates = [_]f64{ -0.082, -0.041, 0.034, 0.016, 0.010, 0.008, 0.005 };

        // Header row
        current.putStr(3, 5, "COIN", dim);
        current.putStr(12, 5, "RATE", dim);
        current.putStr(22, 5, "BAR", dim);

        for (coins, 0..) |coin, i| {
            const y: u16 = @intCast(6 + i);
            const rate = rates[i];

            current.putStr(3, y, coin, white);

            // Rate string
            var rate_buf: [16]u8 = undefined;
            const rate_str = std.fmt.bufPrint(&rate_buf, "{d:.4}%", .{rate * 100}) catch "?";
            const rate_style = if (rate < 0) red else green;
            current.putStr(11, y, rate_str, rate_style);

            // Bar chart
            const bar_color = if (rate < 0) red else green;
            current.putBar(22, y, @abs(rate), 0.1, 30, bar_color);
        }

        // Account panel
        const acct = Buffer.Rect{ .x = 1, .y = 17, .w = term.width - 2, .h = 5 };
        current.drawBox(acct, "ACCOUNT", cyan);
        current.putStr(3, 18, "Value  $5,581.97", white);
        current.putStr(3, 19, "Health ", dim);
        current.putBar(10, 19, 0.827, 1.0, 20, green);
        current.putStr(31, 19, " 82.7% SAFE", green);

        // Sparkline demo
        const spark_rect = Buffer.Rect{ .x = 1, .y = 23, .w = term.width - 2, .h = 4 };
        current.drawBox(spark_rect, "ETH 24h VOLUME", cyan);
        const vols = [_]f64{ 2, 3, 4, 5, 7, 9, 12, 15, 18, 14, 10, 8, 6, 5, 4, 3, 5, 8, 12, 16, 20, 18, 15, 12 };
        current.putSparkline(3, 24, &vols, yellow);

        // Frame counter
        var frame_buf: [32]u8 = undefined;
        const frame_str = std.fmt.bufPrint(&frame_buf, "frame {d}", .{frame}) catch "?";
        current.putStr(term.width - @as(u16, @intCast(frame_str.len)) - 1, term.height - 1, frame_str, dim);

        // Diff and flush
        current.flush(&prev);

        // Swap: copy current into prev
        @memcpy(prev.cells, current.cells);
        frame += 1;

        // Poll input
        std.Thread.sleep(50_000_000); // 50ms
        if (Terminal.pollKey()) |key| {
            switch (key) {
                .char => |c| if (c == 'q') break,
                .esc => break,
                else => {},
            }
        }
    }
}
