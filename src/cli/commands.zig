
const std = @import("std");
const posix = std.posix;
const hyperzig = @import("hyperzig");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const output_mod = @import("output.zig");
const client_mod = hyperzig.hypercore.client;
const response = hyperzig.hypercore.response;
const types = hyperzig.hypercore.types;
const signing = hyperzig.hypercore.signing;
const json_mod = hyperzig.hypercore.json;
const ws_types = hyperzig.hypercore.ws;
const WsConnection = ws_types.Connection;
const Decimal = hyperzig.math.decimal.Decimal;

const Client = client_mod.Client;
const Column = output_mod.Column;
const Style = output_mod.Style;
const Writer = output_mod.Writer;
const Config = config_mod.Config;

pub const CmdError = client_mod.ClientError || config_mod.ConfigError || error{
    Overflow,
    MissingAddress,
    MissingKey,
    AssetNotFound,
};

var stream_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var stream_socket_fd: std.atomic.Value(std.posix.fd_t) = std.atomic.Value(std.posix.fd_t).init(-1);

fn makeClient(allocator: std.mem.Allocator, config: Config) Client {
    return switch (config.chain) {
        .mainnet => Client.mainnet(allocator),
        .testnet => Client.testnet(allocator),
    };
}

const ListW = @import("List");
const App = @import("App");
const BufMod = @import("Buffer");

const ListViewOpts = struct {
    title: []const u8 = "",
    help: []const u8 = "j/k:nav  /:search  s:sort  q:quit",
    on_render_cell: ?ListW.RenderCellFn = null,
    on_select: ?*const fn (allocator: std.mem.Allocator, config: Config, items: []const ListW.Item, idx: usize) void = null,
    allocator: std.mem.Allocator = undefined,
    config: Config = undefined,
};

fn runListView(
    columns: []const ListW.Column,
    items: []const ListW.Item,
    count: usize,
    opts: ListViewOpts,
) !void {
    var list = ListW.init(columns, items, count);
    list.title = opts.title;
    list.help = opts.help;
    list.on_render_cell = opts.on_render_cell;

    var app = App.init(opts.allocator) catch {
        std.fs.File.stderr().writeAll("error: requires an interactive terminal\n") catch {};
        return;
    };
    defer app.deinit();
    app.setTickMs(100);

    while (app.running) {
        app.beginFrame();
        list.render(&app.buf, app.fullRect());
        app.endFrame();
        app.tick();

        if (app.pollKey()) |key| {
            switch (list.handleKey(key)) {
                .quit => app.running = false,
                .select => {
                    if (opts.on_select) |cb| {
                        if (list.selectedIndex()) |idx| {
                            app.deinit();
                            cb(opts.allocator, opts.config, items, idx);
                            app = App.init(opts.allocator) catch return;
                            app.setTickMs(100);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

pub fn showConfig(w: *Writer, config: Config) !void {
    if (w.format == .json) {
        try w.print("{{\"chain\":\"{s}\",\"address\":{s},\"key_set\":{s}}}\n", .{
            if (config.chain == .mainnet) "mainnet" else "testnet",
            if (config.address) |a| a else "null",
            if (config.key_hex != null) "true" else "false",
        });
        return;
    }
    try w.heading("CONFIG");
    try w.print("│ Chain:    {s}\n", .{if (config.chain == .mainnet) "mainnet" else "testnet"});
    try w.print("│ Address:  {s}\n", .{config.address orelse "(not set)"});
    try w.print("│ Key:      {s}\n", .{if (config.key_hex != null) "✓ loaded" else "✗ not set"});
    try w.footer();
}

pub fn mids(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MidsArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var result = try client.allMids(a.dex);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    if (val != .object) return;

    const MidEntry = struct { coin: []const u8, mid: []const u8 };
    var entries = try allocator.alloc(MidEntry, val.object.count());
    defer allocator.free(entries);
    var total: usize = 0;

    var iter = val.object.iterator();
    while (iter.next()) |entry| {
        entries[total] = .{
            .coin = entry.key_ptr.*,
            .mid = switch (entry.value_ptr.*) { .string => |s| s, else => "?" },
        };
        total += 1;
    }

    if (w.is_tty and !a.all and a.page == 1 and a.coin == null) {
        return midsTui(allocator, config, entries[0..total]);
    }

    try w.heading("MID PRICES");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 14 },
        .{ .text = "MID", .width = 16, .align_right = true },
    };
    try w.tableHeader(&hdr);

    var filtered: usize = 0;
    for (entries[0..total]) |e| {
        if (a.coin) |f| { if (!containsInsensitive(e.coin, f)) continue; }
        entries[filtered] = e;
        filtered += 1;
    }

    const per_page: usize = 20;
    const start = if (a.all or a.coin != null) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all or a.coin != null) filtered else per_page;
    const end = @min(start + limit, filtered);

    for (entries[start..end]) |e| {
        const cols = [_]Column{
            .{ .text = e.coin, .width = 14, .color = Style.cyan },
            .{ .text = e.mid, .width = 16, .align_right = true, .color = Style.white },
        };
        try w.tableRow(&cols);
    }
    const pages = (filtered + per_page - 1) / per_page;
    if (!a.all and a.coin == null and end < filtered) try w.paginatePage(end - start, filtered, a.page, pages);
    try w.footer();
}

fn midsTui(allocator: std.mem.Allocator, config: Config, entries: anytype) !void {
    _ = config;
    const n = @min(entries.len, ListW.MAX_ITEMS);

    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;
    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const white = BufMod.Style{ .fg = .bright_white };

    for (0..n) |i| {
        items[i] = .{
            .cells = cellsInit(&.{ entries[i].coin, entries[i].mid }),
            .styles = stylesInit(&.{ cyan, white }),
            .sort_key = std.fmt.parseFloat(f64, entries[i].mid) catch 0,
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "COIN", .width = 14 },
        .{ .label = "MID", .width = 16, .right_align = true },
    };

    try runListView(&columns, &items, n, .{
        .title = "MID PRICES",
        .allocator = allocator,
    });
}

fn cellsInit(vals: []const []const u8) [ListW.MAX_COLS][]const u8 {
    var c: [ListW.MAX_COLS][]const u8 = .{""} ** ListW.MAX_COLS;
    for (vals, 0..) |v, i| c[i] = v;
    return c;
}

fn stylesInit(vals: []const BufMod.Style) [ListW.MAX_COLS]BufMod.Style {
    var s: [ListW.MAX_COLS]BufMod.Style = .{BufMod.Style{}} ** ListW.MAX_COLS;
    for (vals, 0..) |v, i| s[i] = v;
    return s;
}

pub fn positions(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;
    var result = try client.clearinghouseState(addr, a.dex);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const pos_arr = json_mod.getArray(val, "assetPositions") orelse {
        try w.styled(Style.dim, "  No positions found\n");
        return;
    };

    try w.heading("POSITIONS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 8 },
        .{ .text = "SIDE", .width = 6 },
        .{ .text = "SIZE", .width = 12, .align_right = true },
        .{ .text = "ENTRY", .width = 12, .align_right = true },
        .{ .text = "MARK", .width = 12, .align_right = true },
        .{ .text = "PNL", .width = 14, .align_right = true },
        .{ .text = "LEV", .width = 5, .align_right = true },
    };
    try w.tableHeader(&hdr);

    for (pos_arr) |item| {
        const pos = response.PositionData.fromJson(item) orelse continue;
        var szi_buf: [32]u8 = undefined;
        var entry_buf: [32]u8 = undefined;
        var pnl_buf: [32]u8 = undefined;

        const szi = pos.szi orelse continue;
        const szi_str = szi.normalize().toString(&szi_buf) catch continue;
        if (szi.mantissa == 0) continue; // skip zero positions

        const side_str: []const u8 = if (szi.isNegative()) "SHORT" else "LONG";
        const side_color: []const u8 = if (szi.isNegative()) Style.red else Style.green;
        const entry_str = decStr(pos.entry_px, &entry_buf);
        var mark_buf: [32]u8 = undefined;
        const mark_str = decStr(pos.liquidation_px, &mark_buf);
        const pnl_str = decStr(pos.unrealized_pnl, &pnl_buf);
        var lev_buf: [16]u8 = undefined;
        const lev_str = if (pos.leverage_value) |lv|
            std.fmt.bufPrint(&lev_buf, "{d}x", .{lv}) catch "?"
        else
            "-";

        var abs_buf: [32]u8 = undefined;
        const abs_str = if (szi.isNegative()) blk: {
            const abs = szi.negate();
            break :blk abs.normalize().toString(&abs_buf) catch szi_str;
        } else szi_str;

        const cols = [_]Column{
            .{ .text = pos.coin, .width = 8, .color = Style.bold_cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = abs_str, .width = 12, .align_right = true },
            .{ .text = entry_str, .width = 12, .align_right = true },
            .{ .text = mark_str, .width = 12, .align_right = true, .color = Style.dim },
            .{ .text = pnl_str, .width = 14, .align_right = true, .color = Writer.pnlColor(pos.unrealized_pnl) },
            .{ .text = lev_str, .width = 5, .align_right = true },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn orders(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;
    var result = try client.openOrders(addr, a.dex);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const arr = if (val == .array) val.array.items else {
        try w.styled(Style.dim, "  No orders found\n");
        return;
    };

    try w.heading("OPEN ORDERS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 8 },
        .{ .text = "SIDE", .width = 6 },
        .{ .text = "SIZE", .width = 12, .align_right = true },
        .{ .text = "PRICE", .width = 12, .align_right = true },
        .{ .text = "OID", .width = 12, .align_right = true },
    };
    try w.tableHeader(&hdr);

    for (arr) |item| {
        const ord = response.BasicOrder.fromJson(item) orelse continue;
        var sz_buf: [32]u8 = undefined;
        var px_buf: [32]u8 = undefined;
        var oid_buf: [20]u8 = undefined;

        const side_color: []const u8 = if (std.mem.eql(u8, ord.side, "B")) Style.green else Style.red;
        const side_str: []const u8 = if (std.mem.eql(u8, ord.side, "B")) "BUY" else "SELL";

        const cols = [_]Column{
            .{ .text = ord.coin, .width = 8, .color = Style.cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = decStr(ord.sz, &sz_buf), .width = 12, .align_right = true },
            .{ .text = decStr(ord.limit_px, &px_buf), .width = 12, .align_right = true },
            .{ .text = std.fmt.bufPrint(&oid_buf, "{d}", .{ord.oid}) catch "?", .width = 12, .align_right = true, .color = Style.dim },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn fills(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;
    var result = try client.userFills(addr);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const arr = if (val == .array) val.array.items else {
        try w.styled(Style.dim, "  No fills found\n");
        return;
    };

    try w.heading("RECENT FILLS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 8 },
        .{ .text = "SIDE", .width = 6 },
        .{ .text = "SIZE", .width = 12, .align_right = true },
        .{ .text = "PRICE", .width = 12, .align_right = true },
        .{ .text = "FEE", .width = 10, .align_right = true },
        .{ .text = "PNL", .width = 12, .align_right = true },
    };
    try w.tableHeader(&hdr);

    const limit = @min(arr.len, 20); // show last 20
    for (arr[0..limit]) |item| {
        const fill = response.Fill.fromJson(item) orelse continue;
        var sz_buf: [32]u8 = undefined;
        var px_buf: [32]u8 = undefined;
        var fee_buf: [32]u8 = undefined;
        var pnl_buf: [32]u8 = undefined;

        const side_color: []const u8 = if (std.mem.eql(u8, fill.side, "B")) Style.green else Style.red;
        const side_str: []const u8 = if (std.mem.eql(u8, fill.side, "B")) "BUY" else "SELL";

        const cols = [_]Column{
            .{ .text = fill.coin, .width = 8, .color = Style.cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = decStr(fill.sz, &sz_buf), .width = 12, .align_right = true },
            .{ .text = decStr(fill.px, &px_buf), .width = 12, .align_right = true },
            .{ .text = decStr(fill.fee, &fee_buf), .width = 10, .align_right = true, .color = Style.dim },
            .{ .text = decStr(fill.closed_pnl, &pnl_buf), .width = 12, .align_right = true, .color = Writer.pnlColor(fill.closed_pnl) },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn balance(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    var spot_result = try client.spotBalances(addr);
    defer spot_result.deinit();
    var perp_result = try client.clearinghouseState(addr, a.dex);
    defer perp_result.deinit();

    if (w.format == .json) {
        try w.print("{{\"spot\":{s},\"perp\":{s}}}\n", .{ spot_result.body, perp_result.body });
        return;
    }

    const perp_val = try perp_result.json();
    const margin = if (json_mod.getObject(perp_val, "marginSummary")) |ms|
        response.MarginSummary.fromJson(ms)
    else
        null;

    try w.heading("ACCOUNT");

    if (margin) |m| {
        var av_buf: [32]u8 = undefined;
        var mu_buf: [32]u8 = undefined;
        var wd_buf: [32]u8 = undefined;
        const withdrawable = json_mod.getDecimal(perp_val, "withdrawable");
        try w.print("\xe2\x94\x82 Account Value:  {s}\n", .{decStr(m.account_value, &av_buf)});
        try w.print("\xe2\x94\x82 Margin Used:    {s}\n", .{decStr(m.total_margin_used, &mu_buf)});
        try w.print("\xe2\x94\x82 Withdrawable:   {s}\n", .{decStr(withdrawable, &wd_buf)});

        const av_f = if (m.account_value) |av| decToF64(av) else 0.0;
        const mu_f = if (m.total_margin_used) |mu| decToF64(mu) else 0.0;
        const health_pct: f64 = if (mu_f > 0 and av_f > 0)
            @max(0, @min(100, 100.0 - (mu_f / av_f * 100.0)))
        else
            100.0;

        const bar_w: usize = 20;
        const fill: usize = @intFromFloat(health_pct / 100.0 * @as(f64, @floatFromInt(bar_w)));
        const health_color: []const u8 = if (health_pct > 50) Style.bold_green else if (health_pct > 25) Style.bold_yellow else Style.bold_red;

        const stdout = std.fs.File.stdout();
        const is_tty = w.is_tty;
        {
            var buf: [256]u8 = undefined;
            var p: usize = 0;
            p = emit(&buf, p, "\xe2\x94\x82 Health:         ");
            if (is_tty) p = emit(&buf, p, health_color);
            var fi: usize = 0;
            while (fi < fill) : (fi += 1) {
                buf[p] = 0xe2; buf[p+1] = 0x96; buf[p+2] = 0x88; // █
                p += 3;
            }
            if (is_tty) p = emit(&buf, p, Style.reset);
            if (is_tty) p = emit(&buf, p, Style.dim);
            var ei: usize = fill;
            while (ei < bar_w) : (ei += 1) {
                buf[p] = 0xe2; buf[p+1] = 0x96; buf[p+2] = 0x91; // ░
                p += 3;
            }
            if (is_tty) p = emit(&buf, p, Style.reset);
            var pct_buf: [8]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, " {d:.0}%", .{health_pct}) catch "?";
            if (is_tty) p = emit(&buf, p, health_color);
            @memcpy(buf[p..][0..pct_str.len], pct_str);
            p += pct_str.len;
            if (is_tty) p = emit(&buf, p, Style.reset);
            p = emit(&buf, p, "\r\n");
            stdout.writeAll(buf[0..p]) catch {};
        }
    }

    const spot_val = try spot_result.json();
    const balances_arr = if (json_mod.getObject(spot_val, "balances")) |_| blk: {
        break :blk json_mod.getArray(spot_val, "balances");
    } else if (spot_val == .array) spot_val.array.items else null;

    if (balances_arr) |bal_arr| {
        if (bal_arr.len > 0) {
            try w.nl();
            try w.styled(Style.bold, "│ SPOT BALANCES\n");
            const hdr = [_]Column{
                .{ .text = "COIN", .width = 10 },
                .{ .text = "TOTAL", .width = 16, .align_right = true },
                .{ .text = "HOLD", .width = 16, .align_right = true },
            };
            try w.tableHeader(&hdr);

            for (bal_arr) |item| {
                const b = response.UserBalance.fromJson(item) orelse continue;
                var total_buf: [32]u8 = undefined;
                var hold_buf: [32]u8 = undefined;
                const cols = [_]Column{
                    .{ .text = b.coin, .width = 10, .color = Style.cyan },
                    .{ .text = decStr(b.total, &total_buf), .width = 16, .align_right = true },
                    .{ .text = decStr(b.hold, &hold_buf), .width = 16, .align_right = true, .color = Style.dim },
                };
                try w.tableRow(&cols);
            }
        }
    }

    try w.footer();
}

pub fn perps(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var result = try client.perps(a.dex);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const universe = json_mod.getArray(val, "universe") orelse {
        try w.styled(Style.dim, "  No perp markets found\n");
        return;
    };

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return perpsTui(allocator, config, universe);
    }

    try w.heading("PERP MARKETS");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 12 },
        .{ .text = "MAX LEV", .width = 8, .align_right = true },
        .{ .text = "SZ DEC", .width = 7, .align_right = true },
    };
    try w.tableHeader(&hdr);

    var total: usize = 0;
    var shown: usize = 0;
    var skipped: usize = 0;
    const per_page: usize = 20;
    const start = if (a.all) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all) universe.len else per_page;

    for (universe) |item| {
        const name = json_mod.getString(item, "name") orelse continue;
        if (a.filter) |f| { if (!containsInsensitive(name, f)) continue; }
        total += 1;
    }

    for (universe) |item| {
        if (shown >= limit) break;
        const m = response.PerpMeta.fromJson(item) orelse continue;
        if (a.filter) |f| { if (!containsInsensitive(m.name, f)) continue; }
        if (skipped < start) { skipped += 1; continue; }
        var lev_buf: [16]u8 = undefined;
        var dec_buf: [8]u8 = undefined;
        const cols = [_]Column{
            .{ .text = m.name, .width = 12, .color = Style.cyan },
            .{ .text = std.fmt.bufPrint(&lev_buf, "{d}x", .{m.max_leverage}) catch "?", .width = 8, .align_right = true, .color = Style.yellow },
            .{ .text = std.fmt.bufPrint(&dec_buf, "{d}", .{m.sz_decimals}) catch "?", .width = 7, .align_right = true },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

fn perpsTui(allocator: std.mem.Allocator, config: Config, universe: []const std.json.Value) !void {
    const n = @min(universe.len, ListW.MAX_ITEMS);

    const CellBuf = struct { lev: [16]u8 = undefined, lev_len: usize = 0, dec: [8]u8 = undefined, dec_len: usize = 0 };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const yellow = BufMod.Style{ .fg = .yellow };

    for (0..n) |i| {
        const m = response.PerpMeta.fromJson(universe[i]) orelse continue;
        const lev_s = std.fmt.bufPrint(&cell_bufs[i].lev, "{d}x", .{m.max_leverage}) catch "?";
        cell_bufs[i].lev_len = lev_s.len;
        const dec_s = std.fmt.bufPrint(&cell_bufs[i].dec, "{d}", .{m.sz_decimals}) catch "?";
        cell_bufs[i].dec_len = dec_s.len;

        items[i] = .{
            .cells = cellsInit(&.{ m.name, cell_bufs[i].lev[0..cell_bufs[i].lev_len], cell_bufs[i].dec[0..cell_bufs[i].dec_len] }),
            .styles = stylesInit(&.{ cyan, yellow }),
            .sort_key = @as(f64, @floatFromInt(m.max_leverage)),
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "NAME", .width = 12 },
        .{ .label = "MAX LEV", .width = 10, .right_align = true },
        .{ .label = "SZ DEC", .width = 8, .right_align = true },
    };

    try runListView(&columns, &items, n, .{
        .title = "PERP MARKETS",
        .help = "j/k:nav  /:search  s:sort  Enter:book  q:quit",
        .allocator = allocator,
        .config = config,
        .on_select = &perpsOnSelect,
    });
}

fn perpsOnSelect(allocator: std.mem.Allocator, config: Config, items: []const ListW.Item, idx: usize) void {
    const coin = items[idx].cells[0];
    const ba = args_mod.BookArgs{ .coin = coin, .depth = 15, .live = true };
    bookLive(allocator, config, ba) catch {};
}

pub fn dexes(allocator: std.mem.Allocator, w: *Writer, config: Config) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var result = try client.perpDexs();
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const arr = if (val == .array) val.array.items else {
        try w.styled(Style.dim, "  No DEXes found\n");
        return;
    };

    try w.heading("HIP-3 DEXES");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 20 },
    };
    try w.tableHeader(&hdr);

    for (arr) |item| {
        const name = json_mod.getString(item, "name") orelse continue;
        const cols = [_]Column{
            .{ .text = name, .width = 20, .color = Style.cyan },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn spotMarkets(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var result = try client.spot();
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const tokens = json_mod.getArray(val, "tokens") orelse {
        try w.styled(Style.dim, "  No spot markets found\n");
        return;
    };

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return spotTui(allocator, tokens);
    }

    try w.heading("SPOT TOKENS");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 12 },
        .{ .text = "INDEX", .width = 6, .align_right = true },
        .{ .text = "SZ DEC", .width = 7, .align_right = true },
        .{ .text = "WEI DEC", .width = 8, .align_right = true },
    };
    try w.tableHeader(&hdr);

    const per_page: usize = 20;
    const start = if (a.all) @as(usize, 0) else (a.page -| 1) * per_page;
    const limit = if (a.all) tokens.len else per_page;

    var total: usize = 0;
    for (tokens) |item| {
        const t = response.SpotToken.fromJson(item) orelse continue;
        if (a.filter) |f| { if (!containsInsensitive(t.name, f)) continue; }
        total += 1;
    }

    var shown: usize = 0;
    var skipped: usize = 0;
    for (tokens) |item| {
        if (shown >= limit) break;
        const t = response.SpotToken.fromJson(item) orelse continue;
        if (a.filter) |f| { if (!containsInsensitive(t.name, f)) continue; }
        if (skipped < start) { skipped += 1; continue; }
        var idx_buf: [8]u8 = undefined;
        var sz_buf: [8]u8 = undefined;
        var wei_buf: [8]u8 = undefined;
        const cols = [_]Column{
            .{ .text = t.name, .width = 12, .color = Style.cyan },
            .{ .text = std.fmt.bufPrint(&idx_buf, "{d}", .{t.index}) catch "?", .width = 6, .align_right = true },
            .{ .text = std.fmt.bufPrint(&sz_buf, "{d}", .{t.sz_decimals}) catch "?", .width = 7, .align_right = true },
            .{ .text = std.fmt.bufPrint(&wei_buf, "{d}", .{t.wei_decimals}) catch "?", .width = 8, .align_right = true },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

fn spotTui(allocator: std.mem.Allocator, tokens: []const std.json.Value) !void {
    const n = @min(tokens.len, ListW.MAX_ITEMS);

    const CellBuf = struct { idx: [8]u8 = undefined, idx_len: usize = 0, sz: [8]u8 = undefined, sz_len: usize = 0, wei: [8]u8 = undefined, wei_len: usize = 0 };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;
    var count: usize = 0;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };

    for (0..n) |i| {
        const t = response.SpotToken.fromJson(tokens[i]) orelse continue;
        const idx_s = std.fmt.bufPrint(&cell_bufs[count].idx, "{d}", .{t.index}) catch "?";
        cell_bufs[count].idx_len = idx_s.len;
        const sz_s = std.fmt.bufPrint(&cell_bufs[count].sz, "{d}", .{t.sz_decimals}) catch "?";
        cell_bufs[count].sz_len = sz_s.len;
        const wei_s = std.fmt.bufPrint(&cell_bufs[count].wei, "{d}", .{t.wei_decimals}) catch "?";
        cell_bufs[count].wei_len = wei_s.len;

        items[count] = .{
            .cells = cellsInit(&.{ t.name, cell_bufs[count].idx[0..cell_bufs[count].idx_len], cell_bufs[count].sz[0..cell_bufs[count].sz_len], cell_bufs[count].wei[0..cell_bufs[count].wei_len] }),
            .styles = stylesInit(&.{cyan}),
            .sort_key = @as(f64, @floatFromInt(t.index)),
        };
        count += 1;
    }

    const columns = [_]ListW.Column{
        .{ .label = "NAME", .width = 12 },
        .{ .label = "INDEX", .width = 8, .right_align = true },
        .{ .label = "SZ DEC", .width = 8, .right_align = true },
        .{ .label = "WEI DEC", .width = 8, .right_align = true },
    };

    try runListView(&columns, &items, count, .{
        .title = "SPOT TOKENS",
        .allocator = allocator,
    });
}

pub fn placeOrder(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.OrderArgs, is_buy: bool) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const signer = try config.getSigner();

    const asset = try resolveAsset(allocator, &client, a.coin);

    const sz = Decimal.fromString(a.size) catch return error.Overflow;

    const is_market = a.price == null;
    const order_type: types.OrderTypePlacement = if (!is_market) blk: {
        const tif: types.TimeInForce = if (std.mem.eql(u8, a.tif, "ioc"))
            .Ioc
        else if (std.mem.eql(u8, a.tif, "alo"))
            .Alo
        else
            .Gtc;
        break :blk .{ .limit = .{ .tif = tif } };
    } else .{ .limit = .{ .tif = .FrontendMarket } };

    const limit_px = if (a.price) |px_str|
        Decimal.fromString(px_str) catch return error.Overflow
    else if (a.slippage) |sl_str|
        Decimal.fromString(sl_str) catch return error.Overflow
    else blk: {
        var bbo_result = try client.l2Book(a.coin);
        defer bbo_result.deinit();
        const bbo_val = try bbo_result.json();
        const levels = json_mod.getArray(bbo_val, "levels") orelse
            break :blk if (is_buy) Decimal.fromString("999999") catch unreachable else Decimal.fromString("0.01") catch unreachable;
        if (is_buy) {
            if (levels.len > 1) {
                const asks = if (levels[1] == .array) levels[1].array.items else break :blk Decimal.fromString("999999") catch unreachable;
                if (asks.len > 0) {
                    const ask_px_str = json_mod.getString(asks[0], "px") orelse break :blk Decimal.fromString("999999") catch unreachable;
                    const ask_px = std.fmt.parseFloat(f64, ask_px_str) catch break :blk Decimal.fromString("999999") catch unreachable;
                    const slippage_px = ask_px * 1.01;
                    var sl_buf: [32]u8 = undefined;
                    const sl_str2 = std.fmt.bufPrint(&sl_buf, "{d:.2}", .{slippage_px}) catch break :blk Decimal.fromString("999999") catch unreachable;
                    break :blk Decimal.fromString(sl_str2) catch Decimal.fromString("999999") catch unreachable;
                }
            }
            break :blk Decimal.fromString("999999") catch unreachable;
        } else {
            if (levels.len > 0) {
                const bids = if (levels[0] == .array) levels[0].array.items else break :blk Decimal.fromString("0.01") catch unreachable;
                if (bids.len > 0) {
                    const bid_px_str = json_mod.getString(bids[0], "px") orelse break :blk Decimal.fromString("0.01") catch unreachable;
                    const bid_px = std.fmt.parseFloat(f64, bid_px_str) catch break :blk Decimal.fromString("0.01") catch unreachable;
                    const slippage_px = bid_px * 0.99;
                    var sl_buf: [32]u8 = undefined;
                    const sl_str2 = std.fmt.bufPrint(&sl_buf, "{d:.2}", .{slippage_px}) catch break :blk Decimal.fromString("0.01") catch unreachable;
                    break :blk Decimal.fromString(sl_str2) catch Decimal.fromString("0.01") catch unreachable;
                }
            }
            break :blk Decimal.fromString("0.01") catch unreachable;
        }
    };

    const now: u64 = @intCast(std.time.milliTimestamp());
    var cloid = types.ZERO_CLOID;
    cloid[0] = @intCast((now >> 56) & 0xff);
    cloid[1] = @intCast((now >> 48) & 0xff);
    cloid[2] = @intCast((now >> 40) & 0xff);
    cloid[3] = @intCast((now >> 32) & 0xff);
    cloid[4] = @intCast((now >> 24) & 0xff);
    cloid[5] = @intCast((now >> 16) & 0xff);
    cloid[6] = @intCast((now >> 8) & 0xff);
    cloid[7] = @intCast(now & 0xff);

    const order = types.OrderRequest{
        .asset = asset,
        .is_buy = is_buy,
        .limit_px = limit_px,
        .sz = sz,
        .reduce_only = a.reduce_only,
        .order_type = order_type,
        .cloid = cloid,
    };
    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    var result = try client.place(signer, batch, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    if (statuses.len > 0) {
        switch (statuses[0]) {
            .resting => |r| {
                try w.styled(Style.bold_green, "✓ Order resting");
                var oid_buf: [20]u8 = undefined;
                try w.print(" (oid: {s})\n", .{std.fmt.bufPrint(&oid_buf, "{d}", .{r.oid}) catch "?"});
            },
            .filled => |f| {
                try w.styled(Style.bold_green, "✓ Order filled");
                var avg_buf: [32]u8 = undefined;
                try w.print(" (avg: {s})\n", .{decStr(f.avg_px, &avg_buf)});
            },
            .success => try w.success("Order accepted"),
            .@"error" => |msg| try w.errFmt("order rejected: {s}", .{msg}),
            .unknown => try w.err("unknown response"),
        }
    } else {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("Order submitted"),
            .err => {
                const err_msg = json_mod.getString(val, "response") orelse "unknown error";
                try w.errFmt("rejected: {s}", .{err_msg});
            },
            .unknown => {
                try w.err("unexpected response");
                try w.print("{s}\n", .{result.body});
            },
        }
    }
}

pub fn cancelOrder(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.CancelArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const signer = try config.getSigner();
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    if (a.all) {
        const sc = types.ScheduleCancel{ .time = null };
        var result = try client.scheduleCancel(signer, sc, nonce, null, null);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("All orders cancelled");
        } else {
            try w.err("cancel-all failed");
            try w.print("{s}\n", .{result.body});
        }
        return;
    }

    const coin = a.coin orelse return error.MissingArgument;
    const asset = try resolveAsset(allocator, &client, coin);

    if (a.cloid) |cloid_hex| {
        var cloid: types.Cloid = types.ZERO_CLOID;
        const hex_str = if (cloid_hex.len >= 2 and cloid_hex[0] == '0' and cloid_hex[1] == 'x') cloid_hex[2..] else cloid_hex;
        if (hex_str.len != 32) return error.InvalidArgument;
        for (0..16) |bi| {
            cloid[bi] = std.fmt.parseInt(u8, hex_str[bi * 2 ..][0..2], 16) catch return error.InvalidArgument;
        }

        const cancel_cloid = types.CancelByCloid{ .asset = @intCast(asset), .cloid = cloid };
        const batch_cloid = types.BatchCancelCloid{
            .cancels = &[_]types.CancelByCloid{cancel_cloid},
        };

        var result = try client.cancelByCloid(signer, batch_cloid, nonce, null, null);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("Order cancelled (by CLOID)");
        } else {
            try w.err("cancel by CLOID failed");
            try w.print("{s}\n", .{result.body});
        }
        return;
    }

    const oid_str = a.oid orelse return error.MissingArgument;
    const oid = std.fmt.parseInt(u64, oid_str, 10) catch return error.Overflow;

    const cancel = types.Cancel{ .asset = asset, .oid = oid };
    const batch = types.BatchCancel{
        .cancels = &[_]types.Cancel{cancel},
    };

    var result = try client.cancel(signer, batch, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    if (statuses.len > 0) {
        switch (statuses[0]) {
            .success => try w.success("Order cancelled"),
            .@"error" => |msg| try w.errFmt("cancel failed: {s}", .{msg}),
            else => {
                const ok = try result.isOk();
                if (ok) try w.success("Cancel submitted") else try w.err("cancel failed");
            },
        }
    } else {
        const ok = try result.isOk();
        if (ok) {
            try w.success("Cancel submitted");
        } else {
            try w.err("cancel failed");
            try w.print("{s}\n", .{result.body});
        }
    }
}

pub fn sendAsset(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.SendArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const signer = try config.getSigner();
    const now: u64 = @intCast(std.time.milliTimestamp());

    const is_usdc = std.ascii.eqlIgnoreCase(a.token, "USDC");
    const is_simple = is_usdc and std.mem.eql(u8, a.from, "perp") and std.mem.eql(u8, a.to, "perp") and a.subaccount == null;

    const dest = a.destination orelse config.getAddress() orelse return error.MissingAddress;

    if (is_simple) {
        var result = try client.sendUsdc(signer, dest, a.amount, now);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("Sent ");
            try w.print("{s} USDC \xe2\x86\x92 {s}\n", .{ a.amount, dest });
        } else {
            try w.err("send failed");
            try w.print("{s}\n", .{result.body});
        }
    } else {
        const source_dex = if (std.mem.eql(u8, a.from, "perp")) "" else if (std.mem.eql(u8, a.from, "spot")) "spot" else a.from;
        const dest_dex = if (std.mem.eql(u8, a.to, "perp")) "" else if (std.mem.eql(u8, a.to, "spot")) "spot" else a.to;
        const sub = a.subaccount orelse "";

        var result = try client.sendAsset(signer, dest, source_dex, dest_dex, a.token, a.amount, sub, now);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }

        const ok = try result.isOk();
        if (ok) {
            try w.success("Sent ");
            const from_label = if (source_dex.len == 0) "perp" else source_dex;
            const to_label = if (dest_dex.len == 0) "perp" else dest_dex;
            try w.print("{s} {s} ({s} \xe2\x86\x92 {s}) \xe2\x86\x92 {s}\n", .{ a.amount, a.token, from_label, to_label, dest });
        } else {
            try w.err("send failed");
            try w.print("{s}\n", .{result.body});
        }
    }
}

pub fn modifyOrder(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ModifyArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const signer = try config.getSigner();
    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    const asset = try resolveAsset(allocator, &client, a.coin);
    const oid = std.fmt.parseInt(u64, a.oid, 10) catch return error.Overflow;
    const sz = Decimal.fromString(a.size) catch return error.Overflow;
    const px = Decimal.fromString(a.price) catch return error.Overflow;

    const modify_req = types.Modify{
        .oid = .{ .oid = oid },
        .order = .{
            .asset = asset,
            .is_buy = true, // TODO: detect from current order
            .limit_px = px,
            .sz = sz,
            .reduce_only = false,
            .order_type = .{ .limit = .{ .tif = .Gtc } },
            .cloid = types.ZERO_CLOID,
        },
    };
    const batch = types.BatchModify{
        .modifies = &[_]types.Modify{modify_req},
    };

    var result = try client.modify(signer, batch, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    if (statuses.len > 0) {
        switch (statuses[0]) {
            .resting => |r| {
                try w.styled(Style.bold_green, "\xe2\x9c\x93 Order modified");
                var oid_buf: [20]u8 = undefined;
                try w.print(" (oid: {s})\n", .{std.fmt.bufPrint(&oid_buf, "{d}", .{r.oid}) catch "?"});
            },
            .success => try w.success("Order modified"),
            .@"error" => |msg| try w.errFmt("modify rejected: {s}", .{msg}),
            else => {
                const ok = try result.isOk();
                if (ok) try w.success("Modify submitted") else try w.err("modify failed");
            },
        }
    } else {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("Modify submitted"),
            .err => {
                const err_msg = json_mod.getString(val, "response") orelse "unknown error";
                try w.errFmt("rejected: {s}", .{err_msg});
            },
            .unknown => {
                try w.err("unexpected response");
                try w.print("{s}\n", .{result.body});
            },
        }
    }
}

pub fn orderStatus(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.StatusArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = config.getAddress() orelse return error.MissingAddress;
    const oid = std.fmt.parseInt(u64, a.oid, 10) catch return error.Overflow;

    var result = try client.orderStatus(addr, oid);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    try w.heading("ORDER STATUS");
    try w.print("│ {s}\n", .{result.body});
    try w.footer();
}

pub fn funding(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.FundingArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var result = try client.metaAndAssetCtxs();
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    var sorted = try parseFundingData(allocator, &result);
    defer allocator.free(sorted.entries.ptr[0..sorted.alloc_len]);

    if (w.is_tty and !a.all and a.page == 1 and a.filter == null) {
        return fundingTui(allocator, sorted.entries[0..sorted.count]);
    }

    if (a.filter) |f| {
        var fc: usize = 0;
        for (sorted.entries) |e| {
            if (containsInsensitive(e.name, f)) {
                sorted.entries[fc] = e;
                fc += 1;
            }
        }
        sorted.entries = sorted.entries[0..fc];
    }

    const per_page: usize = a.top;
    const total_count = sorted.entries.len;
    const pages = (total_count + per_page - 1) / per_page;
    const page = @min(a.page, pages);
    const start: usize = if (a.all) 0 else (page -| 1) * per_page;
    const end: usize = if (a.all) total_count else @min(start + per_page, total_count);
    const show_slice = sorted.entries[start..end];

    try w.heading("FUNDING RATES (hourly)");

    const stdout = std.fs.File.stdout();
    const is_tty = w.is_tty;

    {
        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = rpad(&buf, p, "COIN", 8);
        p = lpad(&buf, p, "RATE", 14);
        p = lpad(&buf, p, "ANN%", 10);
        p = emit(&buf, p, "  ");
        p = rpad(&buf, p, "HEAT", 20);
        p = lpad(&buf, p, "MARK", 12);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }

    var max_rate: f64 = 0;
    for (show_slice) |e| max_rate = @max(max_rate, @abs(e.funding));
    if (max_rate == 0) max_rate = 1;

    for (show_slice) |e| {
        var rate_buf: [20]u8 = undefined;
        var ann_buf: [16]u8 = undefined;
        const rate_pct = e.funding * 100.0;
        const ann_pct = e.funding * 8760.0 * 100.0;
        const rate_str = std.fmt.bufPrint(&rate_buf, "{d:.6}%", .{rate_pct}) catch "?";
        const ann_str = std.fmt.bufPrint(&ann_buf, "{d:.1}%", .{ann_pct}) catch "?";
        const is_neg = e.funding < 0;
        const rate_color: []const u8 = if (is_neg) Style.red else if (e.funding > 0) Style.green else Style.dim;
        const bg_color: []const u8 = if (is_neg) "\x1b[41m" else "\x1b[42m";
        const bar_width: usize = 20;
        const fill_f = @sqrt(@abs(e.funding) / max_rate);
        const fill: usize = @max(1, @as(usize, @intFromFloat(fill_f * @as(f64, @floatFromInt(bar_width)))));

        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.bold_cyan);
        p = rpad(&buf, p, e.name, 8);
        if (is_tty) p = emit(&buf, p, Style.reset);
        if (is_tty) p = emit(&buf, p, rate_color);
        p = lpad(&buf, p, rate_str, 14);
        p = lpad(&buf, p, ann_str, 10);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, bg_color);
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = spaces(&buf, p, bar_width - fill);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, e.mark, 12);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }
    if (!a.all and end < total_count) try w.paginatePage(end - start, total_count, page, pages);
    try w.footer();
}

var funding_max_rate: f64 = 1;
var funding_entries_ptr: [*]const FundingEntry = undefined;
var funding_entries_len: usize = 0;

fn fundingTui(allocator: std.mem.Allocator, entries: []const FundingEntry) !void {
    const n = @min(entries.len, ListW.MAX_ITEMS);

    var max_rate: f64 = 0;
    for (entries[0..n]) |e| max_rate = @max(max_rate, @abs(e.funding));
    if (max_rate == 0) max_rate = 1;
    funding_max_rate = max_rate;
    funding_entries_ptr = entries.ptr;
    funding_entries_len = entries.len;

    const CellBuf = struct {
        rate: [20]u8 = undefined,
        rate_len: usize = 0,
        ann: [16]u8 = undefined,
        ann_len: usize = 0,
    };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;

    for (0..n) |i| {
        const e = entries[i];
        const rate_pct = e.funding * 100.0;
        const ann_pct = e.funding * 8760.0 * 100.0;

        const rate_s = std.fmt.bufPrint(&cell_bufs[i].rate, "{d:.6}%", .{rate_pct}) catch "?";
        cell_bufs[i].rate_len = rate_s.len;
        const ann_s = std.fmt.bufPrint(&cell_bufs[i].ann, "{d:.1}%", .{ann_pct}) catch "?";
        cell_bufs[i].ann_len = ann_s.len;

        const color: BufMod.Style = if (e.funding < 0) .{ .fg = .red } else if (e.funding > 0) .{ .fg = .green } else .{ .fg = .grey };

        items[i] = .{
            .cells = cellsInit(&.{ e.name, cell_bufs[i].rate[0..cell_bufs[i].rate_len], cell_bufs[i].ann[0..cell_bufs[i].ann_len], "", e.mark }),
            .styles = stylesInit(&.{ .{ .fg = .cyan, .bold = true }, color, color, .{}, .{ .fg = .grey, .dim = true } }),
            .sort_key = @abs(e.funding),
        };
    }

    const columns = [_]ListW.Column{
        .{ .label = "COIN", .width = 10 },
        .{ .label = "RATE", .width = 14, .right_align = true },
        .{ .label = "ANN%", .width = 10, .right_align = true },
        .{ .label = "HEAT", .width = 16 },
        .{ .label = "MARK", .width = 12, .right_align = true },
    };

    try runListView(&columns, &items, n, .{
        .title = "FUNDING RATES (hourly)",
        .on_render_cell = &fundingRenderCell,
        .allocator = allocator,
    });
}

fn fundingRenderCell(buf: *BufMod, x: u16, y: u16, width: u16, item: *const ListW.Item, col: usize, selected: bool) bool {
    if (col != 3) return false;
    if (width < 2) return true;

    const abs_rate = item.sort_key;
    const is_neg = std.mem.startsWith(u8, item.cells[1], "-"); // rate cell starts with '-'

    const fill_f = @sqrt(abs_rate / funding_max_rate);
    const fill: u16 = @max(1, @as(u16, @intFromFloat(fill_f * @as(f64, @floatFromInt(width)))));

    const bg_color: BufMod.Color = if (is_neg) .red else .green;
    const bar_style: BufMod.Style = if (selected)
        .{ .fg = .bright_white, .bg = .blue, .bold = true }
    else
        .{ .bg = bg_color };

    var bx: u16 = 0;
    while (bx < fill and x + bx < x + width) : (bx += 1) {
        const cell = buf.get(x + bx, y);
        cell.setChar(' ');
        cell.style = bar_style;
    }
    return true;
}

const FundingEntry = struct {
    name: []const u8,
    funding: f64,
    oi: []const u8,
    mark: []const u8,
};

const FundingData = struct {
    entries: []FundingEntry,
    count: usize,
    alloc_len: usize,
};

fn parseFundingData(allocator: std.mem.Allocator, result: anytype) !FundingData {
    const val = try result.json();
    if (val != .array or val.array.items.len < 2) return error.Overflow;

    const meta = val.array.items[0];
    const ctxs = val.array.items[1];
    const universe = json_mod.getArray(meta, "universe") orelse return error.Overflow;
    const ctx_arr = if (ctxs == .array) ctxs.array.items else return error.Overflow;

    const limit = @min(universe.len, ctx_arr.len);
    var entries = try allocator.alloc(FundingEntry, limit);
    var count: usize = 0;

    for (0..limit) |i| {
        const name = json_mod.getString(universe[i], "name") orelse continue;
        const funding_str = json_mod.getString(ctx_arr[i], "funding") orelse continue;
        const oi_str = json_mod.getString(ctx_arr[i], "openInterest") orelse "0";
        const mark_str = json_mod.getString(ctx_arr[i], "markPx") orelse "0";
        const f = std.fmt.parseFloat(f64, funding_str) catch continue;
        entries[count] = .{ .name = name, .funding = f, .oi = oi_str, .mark = mark_str };
        count += 1;
    }

    std.mem.sort(FundingEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, lhs: FundingEntry, rhs: FundingEntry) bool {
            return @abs(lhs.funding) > @abs(rhs.funding);
        }
    }.lessThan);

    return .{ .entries = entries[0..count], .count = count, .alloc_len = limit };
}

pub fn book(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.BookArgs) !void {
    if (a.live) {
        return bookLive(allocator, config, a);
    }
    return bookStatic(allocator, w, config, a);
}

fn bookStatic(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.BookArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    var coin_upper: [16]u8 = undefined;
    const coin = upperCoin(a.coin, &coin_upper);

    var result = try client.l2Book(coin);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const levels = json_mod.getArray(val, "levels") orelse {
        try w.err("no book data");
        return;
    };
    if (levels.len < 2) {
        try w.err("invalid book data");
        return;
    }

    const bids_raw = if (levels[0] == .array) levels[0].array.items else return;
    const asks_raw = if (levels[1] == .array) levels[1].array.items else return;
    const depth = @min(a.depth, @min(bids_raw.len, asks_raw.len));

    const Level = struct { px: []const u8, sz: f64, sz_str: []const u8, cum: f64 };
    var bids = try allocator.alloc(Level, depth);
    defer allocator.free(bids);
    var asks = try allocator.alloc(Level, depth);
    defer allocator.free(asks);

    var bid_cum: f64 = 0;
    var ask_cum: f64 = 0;
    for (0..depth) |i| {
        const bid_sz_str = json_mod.getString(bids_raw[i], "sz") orelse "0";
        const bid_sz = std.fmt.parseFloat(f64, bid_sz_str) catch 0;
        bid_cum += bid_sz;
        bids[i] = .{
            .px = json_mod.getString(bids_raw[i], "px") orelse "0",
            .sz = bid_sz, .sz_str = bid_sz_str, .cum = bid_cum,
        };

        const ask_sz_str = json_mod.getString(asks_raw[i], "sz") orelse "0";
        const ask_sz = std.fmt.parseFloat(f64, ask_sz_str) catch 0;
        ask_cum += ask_sz;
        asks[i] = .{
            .px = json_mod.getString(asks_raw[i], "px") orelse "0",
            .sz = ask_sz, .sz_str = ask_sz_str, .cum = ask_cum,
        };
    }
    const max_cum = @max(bid_cum, ask_cum);

    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} ORDER BOOK", .{coin}) catch "ORDER BOOK";
    try w.heading(title);

    const stdout = std.fs.File.stdout();
    const is_tty = w.is_tty;

    const px_w: usize = 10;
    const sz_w: usize = 10;
    const cum_w: usize = 10;
    const bar_w: usize = 20;

    {
        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = rpad(&buf, p, "PRICE", px_w);
        p = lpad(&buf, p, "SIZE", sz_w);
        p = lpad(&buf, p, "TOTAL", cum_w);
        p = emit(&buf, p, "  ");
        p = rpad(&buf, p, "DEPTH", bar_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }

    var ri: usize = depth;
    while (ri > 0) {
        ri -= 1;
        const ak = asks[ri];
        const fill = barFillSqrt(ak.cum, max_cum, bar_w);
        var cum_buf: [16]u8 = undefined;
        const cum_str = floatFmt(&cum_buf, ak.cum);

        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.red);
        p = rpad(&buf, p, ak.px, px_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, ak.sz_str, sz_w);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, cum_str, cum_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, "\x1b[41m"); // red bg
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }

    if (depth > 0) {
        const bid_f = std.fmt.parseFloat(f64, bids[0].px) catch 0;
        const ask_f = std.fmt.parseFloat(f64, asks[0].px) catch 0;
        const spread = ask_f - bid_f;
        const spread_pct = if (bid_f > 0) spread / bid_f * 100 else 0;
        var sbuf: [64]u8 = undefined;
        const ss = std.fmt.bufPrint(&sbuf, "spread: {d:.2} ({d:.4}%)", .{ spread, spread_pct }) catch "";

        const total_w = px_w + sz_w + cum_w + 2 + bar_w;
        const left_pad = if (total_w > ss.len) (total_w - ss.len) / 2 else 0;

        var buf: [256]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = spaces(&buf, p, left_pad);
        @memcpy(buf[p..][0..ss.len], ss);
        p += ss.len;
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }

    for (0..depth) |i| {
        const b = bids[i];
        const fill = barFillSqrt(b.cum, max_cum, bar_w);
        var cum_buf: [16]u8 = undefined;
        const cum_str = floatFmt(&cum_buf, b.cum);

        var buf: [512]u8 = undefined;
        var p: usize = 0;
        if (is_tty) p = emit(&buf, p, Style.green);
        p = rpad(&buf, p, b.px, px_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, b.sz_str, sz_w);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, cum_str, cum_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, "\x1b[42m"); // green bg
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }

    try w.footer();
}

/// sqrt-scaled bar fill for cumulative depth.
fn barFillSqrt(value: f64, max_value: f64, width: usize) usize {
    if (value <= 0 or max_value <= 0) return 0;
    const ratio = @min(@sqrt(value / max_value), 1.0);
    const raw: usize = @intFromFloat(ratio * @as(f64, @floatFromInt(width)));
    return @max(raw, 1);
}

fn floatFmt(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?";
}

fn emit(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn spaces(buf: []u8, pos: usize, n: usize) usize {
    @memset(buf[pos..][0..n], ' ');
    return pos + n;
}

fn rpad(buf: []u8, pos: usize, text: []const u8, width: usize) usize {
    var p = pos;
    const tlen = @min(text.len, width);
    @memcpy(buf[p..][0..tlen], text[0..tlen]);
    p += tlen;
    if (width > tlen) {
        @memset(buf[p..][0..width - tlen], ' ');
        p += width - tlen;
    }
    return p;
}

fn lpad(buf: []u8, pos: usize, text: []const u8, width: usize) usize {
    var p = pos;
    if (width > text.len) {
        const pad = width - text.len;
        @memset(buf[p..][0..pad], ' ');
        p += pad;
    }
    @memcpy(buf[p..][0..text.len], text);
    p += text.len;
    return p;
}

fn bookLive(allocator: std.mem.Allocator, config: Config, a: args_mod.BookArgs) !void {

    var coin_upper: [16]u8 = undefined;
    const coin = upperCoin(a.coin, &coin_upper);

    var client = makeClient(allocator, config);
    defer client.deinit();

    var app = App.init(allocator) catch return error.Overflow;
    defer app.deinit();
    app.setTickMs(150);

    var depth: usize = a.depth;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const white = BufMod.Style{ .fg = .bright_white };
    const dim = BufMod.Style{ .fg = .grey, .dim = true };
    const bold_green = BufMod.Style{ .fg = .green, .bold = true };
    const bold_red = BufMod.Style{ .fg = .red, .bold = true };

    while (app.running) {
        app.beginFrame();
        const buf = &app.buf;

        const w = app.width();
        const h = app.height();

        if (w < 50 or h < 10) {
            buf.putStr(1, 1, "too small", dim);
            app.endFrame();
            app.tick();
            if (app.pollKey()) |key| switch (key) {
                .char => |c| if (c == 'q') { app.running = false; },
                .esc => { app.running = false; },
                else => {},
            };
            continue;
        }

        var result = client.l2Book(coin) catch {
            buf.putStr(2, 4, "Fetching...", dim);
            app.endFrame();
            app.tick();
            continue;
        };
        defer result.deinit();

        const val = result.json() catch continue;
        const levels = json_mod.getArray(val, "levels") orelse continue;
        if (levels.len < 2) continue;

        const bids_raw = if (levels[0] == .array) levels[0].array.items else continue;
        const asks_raw = if (levels[1] == .array) levels[1].array.items else continue;

        const eff_depth = @min(depth, @min(bids_raw.len, asks_raw.len));

        const CumLevel = struct { px: []const u8, sz_str: []const u8, sz: f64, cum: f64 };
        var bid_levels: [64]CumLevel = undefined;
        var ask_levels: [64]CumLevel = undefined;
        var bid_cum: f64 = 0;
        var ask_cum: f64 = 0;

        for (0..eff_depth) |i| {
            const bid_sz_str = json_mod.getString(bids_raw[i], "sz") orelse "0";
            const bid_sz = std.fmt.parseFloat(f64, bid_sz_str) catch 0;
            bid_cum += bid_sz;
            bid_levels[i] = .{
                .px = json_mod.getString(bids_raw[i], "px") orelse "0",
                .sz_str = bid_sz_str, .sz = bid_sz, .cum = bid_cum,
            };

            const ask_sz_str = json_mod.getString(asks_raw[i], "sz") orelse "0";
            const ask_sz = std.fmt.parseFloat(f64, ask_sz_str) catch 0;
            ask_cum += ask_sz;
            ask_levels[i] = .{
                .px = json_mod.getString(asks_raw[i], "px") orelse "0",
                .sz_str = ask_sz_str, .sz = ask_sz, .cum = ask_cum,
            };
        }
        const max_cum = @max(bid_cum, ask_cum);

        var title_buf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} ORDER BOOK", .{coin}) catch "BOOK";
        buf.drawBox(.{ .x = 0, .y = 0, .w = w, .h = h }, title, cyan);

        const col_p: u16 = 2;
        const col_s: u16 = 14;
        const col_c: u16 = 26;
        const col_b: u16 = 38;
        const bar_w: u16 = if (w > 60) @min(w -| 42, 30) else 0;

        buf.putStr(col_p, 1, "PRICE", dim);
        buf.putStr(col_s, 1, "SIZE", dim);
        buf.putStr(col_c, 1, "TOTAL", dim);
        if (bar_w > 0) buf.putStr(col_b, 1, "DEPTH", dim);

        const data_rows = h -| 4; // -2 border, -1 header, -1 sparkline
        const half_h = (data_rows -| 1) / 2;
        const show_depth = @min(eff_depth, half_h);

        var ri: usize = show_depth;
        var y: u16 = 2;
        while (ri > 0) : (y += 1) {
            ri -= 1;
            if (y >= h -| 2) break;
            const lv = ask_levels[ri];
            buf.putStr(col_p, y, lv.px, bold_red);
            buf.putStrRight(col_s, y, 10, lv.sz_str, white);
            var cb: [16]u8 = undefined;
            buf.putStrRight(col_c, y, 10, floatFmt(&cb, lv.cum), dim);
            if (bar_w > 0 and max_cum > 0) {
                const fw: u16 = @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bar_w)))));
                buf.putBgBar(col_b, y, fw, .{ .bg = .red });
            }
        }

        if (show_depth > 0 and y < h -| 2) {
            const bp = std.fmt.parseFloat(f64, bid_levels[0].px) catch 0;
            const ap = std.fmt.parseFloat(f64, ask_levels[0].px) catch 0;
            const sp = ap - bp;
            const pct = if (bp > 0) sp / bp * 100 else 0;
            var sb: [48]u8 = undefined;
            const ss = std.fmt.bufPrint(&sb, "\xe2\x94\x80\xe2\x94\x80 {d:.2} ({d:.3}%) \xe2\x94\x80\xe2\x94\x80", .{ sp, pct }) catch "";
            buf.putStr((w -| @as(u16, @intCast(ss.len))) / 2, y, ss, .{ .fg = .yellow, .bold = true });
            y += 1;
        }

        for (0..show_depth) |i| {
            if (y >= h -| 2) break;
            const lv = bid_levels[i];
            buf.putStr(col_p, y, lv.px, bold_green);
            buf.putStrRight(col_s, y, 10, lv.sz_str, white);
            var cb: [16]u8 = undefined;
            buf.putStrRight(col_c, y, 10, floatFmt(&cb, lv.cum), dim);
            if (bar_w > 0 and max_cum > 0) {
                const fw: u16 = @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bar_w)))));
                buf.putBgBar(col_b, y, fw, .{ .bg = .green });
            }
            y += 1;
        }

        if (h > 8 and show_depth >= 2) {
            const spark_y = h -| 2;
            const spark_w: usize = @min(w -| 4, 60);
            const half_sp = spark_w / 2;
            var sv: [60]f64 = .{0} ** 60;
            for (0..@min(half_sp, show_depth)) |i| {
                sv[i] = ask_levels[@min(show_depth - 1, half_sp - 1 - i)].cum;
                if (i < show_depth) sv[half_sp + i] = bid_levels[i].cum;
            }
            buf.putSparkline(2, spark_y, sv[0..half_sp], .{ .fg = .red });
            buf.putSparkline(2 + @as(u16, @intCast(half_sp)), spark_y, sv[half_sp .. half_sp * 2], .{ .fg = .green });
        }

        buf.putStr(2, h -| 1, "q=quit +/-=depth 1-5=preset", dim);
        var db: [16]u8 = undefined;
        buf.putStr(30, h -| 1, std.fmt.bufPrint(&db, "depth={d}", .{show_depth}) catch "?", white);

        app.endFrame();
        app.tick();

        if (app.pollKey()) |key| {
            switch (key) {
                .char => |c| switch (c) {
                    'q' => app.running = false,
                    '+', '=' => depth = @min(depth + 5, 50),
                    '-', '_' => depth = if (depth > 5) depth - 5 else 5,
                    '1' => depth = 5,
                    '2' => depth = 10,
                    '3' => depth = 15,
                    '4' => depth = 20,
                    '5' => depth = 30,
                    else => {},
                },
                .esc => app.running = false,
                else => {},
            }
        }
    }
}

fn upperCoin(coin: []const u8, buf: *[16]u8) []const u8 {
    const len = @min(coin.len, 16);
    for (0..len) |i| buf[i] = std.ascii.toUpper(coin[i]);
    return buf[0..len];
}

/// Resolve asset name to index. Supports:
///   "BTC"        → perp on main DEX
///   "PURR/USDC"  → spot market (index = 10000 + spot_index)
///   "xyz:BTC"    → perp on HIP-3 DEX "xyz"
///   "42"         → raw index
fn resolveAsset(_: std.mem.Allocator, client: *Client, coin: []const u8) !usize {
    if (std.fmt.parseInt(usize, coin, 10) catch null) |idx| return idx;

    if (std.mem.indexOf(u8, coin, "/")) |slash| {
        const base = coin[0..slash];
        const quote = coin[slash + 1 ..];
        var result = try client.spot();
        defer result.deinit();
        const val = try result.json();
        const tokens = json_mod.getArray(val, "tokens") orelse return error.AssetNotFound;
        _ = tokens;
        const universe = json_mod.getArray(val, "universe") orelse return error.AssetNotFound;
        for (universe) |item| {
            const name = json_mod.getString(item, "name") orelse continue;
            const pair_tokens = json_mod.getArray(item, "tokens") orelse continue;
            if (pair_tokens.len >= 2) {
            }
            const idx = json_mod.getInt(u64, item, "index") orelse continue;
            if (name.len > 0 and std.mem.indexOf(u8, name, "/") != null) {
                // Check if base and quote match
                if (std.mem.indexOf(u8, name, "/")) |ns| {
                    const n_base = name[0..ns];
                    const n_quote = name[ns + 1 ..];
                    if (std.ascii.eqlIgnoreCase(n_base, base) and std.ascii.eqlIgnoreCase(n_quote, quote)) {
                        return @intCast(idx);
                    }
                }
            }
        }
        return error.AssetNotFound;
    }

    if (std.mem.indexOf(u8, coin, ":")) |colon| {
        const dex_name = coin[0..colon];
        const symbol = coin[colon + 1 ..];
        var result = try client.perps(dex_name);
        defer result.deinit();
        const val = try result.json();
        const universe = json_mod.getArray(val, "universe") orelse return error.AssetNotFound;
        for (universe, 0..) |item, i| {
            const name = json_mod.getString(item, "name") orelse continue;
            if (std.ascii.eqlIgnoreCase(name, symbol)) return i;
            if (std.mem.indexOf(u8, name, ":")) |nc| {
                if (std.ascii.eqlIgnoreCase(name[nc + 1 ..], symbol)) return i;
            }
        }
        return error.AssetNotFound;
    }

    var result = try client.perps(null);
    defer result.deinit();

    const val = try result.json();
    const universe = json_mod.getArray(val, "universe") orelse return error.AssetNotFound;

    for (universe, 0..) |item, i| {
        const name = json_mod.getString(item, "name") orelse continue;
        if (std.ascii.eqlIgnoreCase(name, coin)) return i;
    }

    return error.AssetNotFound;
}

pub fn stream(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.StreamArgs) !void {
    _ = allocator;

    const sub: ws_types.Subscription = switch (a.kind) {
        .trades => .{ .trades = .{ .coin = a.coin orelse return error.MissingArgument } },
        .bbo => .{ .bbo = .{ .coin = a.coin orelse return error.MissingArgument } },
        .book => .{ .l2Book = .{ .coin = a.coin orelse return error.MissingArgument } },
        .candles => .{ .candle = .{ .coin = a.coin orelse return error.MissingArgument, .interval = a.interval } },
        .mids => .{ .allMids = .{ .dex = null } },
        .fills => .{ .userFills = .{ .user = a.address orelse config.getAddress() orelse return error.MissingAddress } },
        .orders => .{ .orderUpdates = .{ .user = a.address orelse config.getAddress() orelse return error.MissingAddress } },
    };

    const is_json = w.format == .json or !w.is_tty;
    const stdout = std.fs.File.stdout();

    if (!is_json) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Connecting...\r\n") catch {};
    }

    var conn = WsConnection.connect(std.heap.page_allocator, config.chain) catch |e| {
        try w.errFmt("WebSocket connection failed: {s}", .{@errorName(e)});
        return;
    };
    defer conn.close();

    conn.subscribe(sub) catch {
        try w.err("Failed to subscribe");
        return;
    };

    if (!is_json) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("Subscribed \xe2\x9c\x93  (Ctrl+C to quit)\r\n") catch {};
    }

    stream_shutdown.store(false, .release);
    stream_socket_fd.store(conn.socket_fd, .release);
    const S = struct {
        fn handler(_: c_int) callconv(.c) void {
            stream_shutdown.store(true, .release);
            const fd = stream_socket_fd.load(.acquire);
            if (fd != -1) {
                _ = std.c.shutdown(fd, 2); // SHUT_RDWR = 2
            }
        }
    };
    const act = posix.Sigaction{
        .handler = .{ .handler = S.handler },
        .mask = @as(posix.sigset_t, 0),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);

    while (!stream_shutdown.load(.acquire)) {
        const event = conn.next() catch |e| {
            if (!is_json) {
                const stderr = std.fs.File.stderr();
                if (e == error.EndOfStream) {
                    stderr.writeAll("Server closed connection (bad subscription?)\r\n") catch {};
                } else {
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "Connection error: {s}\r\n", .{@errorName(e)}) catch "Connection error\r\n";
                    stderr.writeAll(err_msg) catch {};
                }
            }
            return;
        };

        switch (event) {
            .timeout => continue,
            .closed => {
                if (!is_json) {
                    const stderr = std.fs.File.stderr();
                    stderr.writeAll("Connection closed\r\n") catch {};
                }
                return;
            },
            .message => |msg| {
                if (msg.channel == .subscriptionResponse) continue;

                if (is_json) {
                    stdout.writeAll(msg.raw_json) catch return;
                    stdout.writeAll("\n") catch return;
                    continue;
                }

                streamPretty(stdout, a.kind, msg.raw_json);
            },
        }
    }

    if (!is_json) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("\r\n") catch {};
    }
}

fn streamPretty(stdout: std.fs.File, kind: args_mod.StreamKind, text: []const u8) void {
    const channel = ws_types.parseChannel(text);
    const data_slice = ws_types.extractData(text);

    switch (channel) {
        .subscriptionResponse => return,
        .pong => return,
        else => {},
    }

    _ = data_slice;

    switch (kind) {
        .trades => streamTradesPretty(stdout, text),
        .bbo => streamBboPretty(stdout, text),
        .candles => streamCandlePretty(stdout, text),
        else => {
            stdout.writeAll(text) catch {};
            stdout.writeAll("\r\n") catch {};
        },
    }
}

fn streamTradesPretty(stdout: std.fs.File, text: []const u8) void {
    const data_start = std.mem.indexOf(u8, text, "\"data\"") orelse return;
    const arr_start = std.mem.indexOfPos(u8, text, data_start, "[") orelse return;
    var pos = arr_start;
    while (std.mem.indexOfPos(u8, text, pos, "{")) |obj_start| {
        const obj_end = std.mem.indexOfPos(u8, text, obj_start, "}") orelse break;
        const obj = text[obj_start .. obj_end + 1];

        const coin = jsonFieldStr(obj, "coin") orelse "?";
        const side = jsonFieldStr(obj, "side") orelse "?";
        const px = jsonFieldStr(obj, "px") orelse "?";
        const sz = jsonFieldStr(obj, "sz") orelse "?";

        const is_buy = side.len > 0 and side[0] == 'B';
        const side_color: []const u8 = if (is_buy) Style.bold_green else Style.bold_red;
        const side_label: []const u8 = if (is_buy) "BUY " else "SELL";

        const px_f = std.fmt.parseFloat(f64, px) catch 0;
        const sz_f = std.fmt.parseFloat(f64, sz) catch 0;
        const notional = px_f * sz_f;
        const whale = notional > 100_000;

        var buf: [256]u8 = undefined;
        var p: usize = 0;
        p = emit(&buf, p, side_color);
        p = emit(&buf, p, side_label);
        p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, " ");
        p = emit(&buf, p, Style.bold);
        p = rpad(&buf, p, coin, 6);
        p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, sz, 12);
        p = emit(&buf, p, " @ ");
        p = emit(&buf, p, Style.cyan);
        p = lpad(&buf, p, px, 12);
        p = emit(&buf, p, Style.reset);
        if (whale) {
            p = emit(&buf, p, " \xe2\x9a\xa1"); // ⚡
            var not_buf: [16]u8 = undefined;
            const not_str = std.fmt.bufPrint(&not_buf, " ${d:.0}", .{notional}) catch "?";
            p = emit(&buf, p, Style.bold_yellow);
            p = emit(&buf, p, not_str);
            p = emit(&buf, p, Style.reset);
        }
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};

        pos = obj_end + 1;
    }
}

fn streamBboPretty(stdout: std.fs.File, text: []const u8) void {
    const coin = jsonFieldStr(text, "coin") orelse "?";

    const bbo_marker = std.mem.indexOf(u8, text, "\"bbo\":[") orelse return;
    const arr_start = bbo_marker + 7; // past "bbo":[

    const bid_start = std.mem.indexOfPos(u8, text, arr_start, "{") orelse return;
    const bid_end = std.mem.indexOfPos(u8, text, bid_start, "}") orelse return;
    const bid_obj = text[bid_start .. bid_end + 1];
    const bid_px = jsonFieldStr(bid_obj, "px") orelse "-";
    const bid_sz = jsonFieldStr(bid_obj, "sz") orelse "-";

    const ask_start = std.mem.indexOfPos(u8, text, bid_end + 1, "{") orelse return;
    const ask_end = std.mem.indexOfPos(u8, text, ask_start, "}") orelse return;
    const ask_obj = text[ask_start .. ask_end + 1];
    const ask_px = jsonFieldStr(ask_obj, "px") orelse "-";
    const ask_sz = jsonFieldStr(ask_obj, "sz") orelse "-";

    var buf: [256]u8 = undefined;
    var p: usize = 0;
    p = emit(&buf, p, Style.bold);
    p = rpad(&buf, p, coin, 6);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.green);
    p = emit(&buf, p, " bid ");
    p = lpad(&buf, p, bid_sz, 12);
    p = emit(&buf, p, " @ ");
    p = lpad(&buf, p, bid_px, 10);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.dim);
    p = emit(&buf, p, " | ");
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.red);
    p = emit(&buf, p, "ask ");
    p = lpad(&buf, p, ask_sz, 12);
    p = emit(&buf, p, " @ ");
    p = lpad(&buf, p, ask_px, 10);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, "\r\n");
    stdout.writeAll(buf[0..p]) catch {};
}

fn streamCandlePretty(stdout: std.fs.File, text: []const u8) void {
    const data_start = std.mem.indexOf(u8, text, "\"data\"") orelse return;
    const obj_start = std.mem.indexOfPos(u8, text, data_start, "{") orelse return;
    const obj_end = std.mem.lastIndexOf(u8, text, "}") orelse return;
    const obj = text[obj_start .. obj_end + 1];

    const coin = jsonFieldStr(obj, "s") orelse jsonFieldStr(obj, "coin") orelse "?";
    const open = jsonFieldStr(obj, "o") orelse "?";
    const high = jsonFieldStr(obj, "h") orelse "?";
    const low = jsonFieldStr(obj, "l") orelse "?";
    const close_px = jsonFieldStr(obj, "c") orelse "?";
    const vol = jsonFieldStr(obj, "v") orelse "?";

    var buf: [256]u8 = undefined;
    var p: usize = 0;
    p = emit(&buf, p, Style.bold);
    p = rpad(&buf, p, coin, 6);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, " O:");
    p = emit(&buf, p, open);
    p = emit(&buf, p, " H:");
    p = emit(&buf, p, Style.green);
    p = emit(&buf, p, high);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, " L:");
    p = emit(&buf, p, Style.red);
    p = emit(&buf, p, low);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, " C:");
    p = emit(&buf, p, Style.bold);
    p = emit(&buf, p, close_px);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, Style.dim);
    p = emit(&buf, p, " V:");
    p = emit(&buf, p, vol);
    p = emit(&buf, p, Style.reset);
    p = emit(&buf, p, "\r\n");
    stdout.writeAll(buf[0..p]) catch {};
}

/// Quick JSON string field extractor (no allocations, returns slice into input).
fn jsonFieldStr(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, json, search) orelse return null;
    const val_start = start + search.len;
    const val_end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    return json[val_start..val_end];
}

fn decToF64(d: Decimal) f64 {
    const m: f64 = @floatFromInt(d.mantissa);
    const s: f64 = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
    return m / s;
}

fn decStr(d: ?Decimal, buf: []u8) []const u8 {
    if (d) |val| return val.normalize().toString(buf) catch "-";
    return "-";
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn markets(allocator: std.mem.Allocator, config: Config) !void {

    var client = makeClient(allocator, config);
    defer client.deinit();

    var meta_result = try client.perps(null);
    defer meta_result.deinit();
    const meta_val = try meta_result.json();

    var mids_result = try client.allMids(null);
    defer mids_result.deinit();
    const mids_val = try mids_result.json();

    const universe = json_mod.getArray(meta_val, "universe") orelse return error.Overflow;

    const MarketRow = struct {
        name_buf: [16]u8 = undefined,
        name_len: usize = 0,
        price_buf: [16]u8 = undefined,
        price_len: usize = 0,
        lev_buf: [8]u8 = undefined,
        lev_len: usize = 0,
        price_f: f64 = 0,
        delisted: bool = false,
    };

    const MAX = ListW.MAX_ITEMS;
    var rows: [MAX]MarketRow = undefined;
    var items: [MAX]ListW.Item = undefined;
    var count: usize = 0;

    for (universe) |entry| {
        if (count >= MAX) break;
        const name = json_mod.getString(entry, "name") orelse continue;
        const is_delisted = if (entry == .object) blk: {
            const obj = entry.object;
            break :blk if (obj.get("isDelisted")) |v| switch (v) {
                .bool => |b| b,
                else => false,
            } else false;
        } else false;
        if (is_delisted) continue; // skip delisted

        const lev = if (entry == .object) blk: {
            if (entry.object.get("maxLeverage")) |v| {
                break :blk switch (v) {
                    .integer => |i| @as(u32, @intCast(i)),
                    else => @as(u32, 3),
                };
            }
            break :blk @as(u32, 3);
        } else @as(u32, 3);

        const mid_str = if (mids_val == .object) (mids_val.object.get(name) orelse null) else null;
        const price_str = if (mid_str) |ms| switch (ms) {
            .string => |s| s,
            else => "—",
        } else "—";
        const price_f = std.fmt.parseFloat(f64, price_str) catch 0;

        var row = &rows[count];
        row.delisted = false;
        row.price_f = price_f;

        row.name_len = @min(name.len, 16);
        @memcpy(row.name_buf[0..row.name_len], name[0..row.name_len]);

        const p = std.fmt.bufPrint(&row.price_buf, "{d:.4}", .{price_f}) catch "?";
        row.price_len = p.len;

        const l = std.fmt.bufPrint(&row.lev_buf, "{d}x", .{lev}) catch "?";
        row.lev_len = l.len;

        const white = BufMod.Style{ .fg = .bright_white };
        const dim = BufMod.Style{ .fg = .grey };
        const cyan = BufMod.Style{ .fg = .cyan };

        items[count] = .{
            .cells = blk: {
                var c: [ListW.MAX_COLS][]const u8 = .{""} ** ListW.MAX_COLS;
                c[0] = row.name_buf[0..row.name_len];
                c[1] = row.price_buf[0..row.price_len];
                c[2] = row.lev_buf[0..row.lev_len];
                break :blk c;
            },
            .styles = blk: {
                var s: [ListW.MAX_COLS]BufMod.Style = .{BufMod.Style{}} ** ListW.MAX_COLS;
                s[0] = cyan;
                s[1] = white;
                s[2] = dim;
                break :blk s;
            },
            .sort_key = price_f,
        };
        count += 1;
    }

    const items_slice = items[0..count];
    std.mem.sort(ListW.Item, items_slice, {}, struct {
        fn cmp(_: void, a: ListW.Item, b: ListW.Item) bool {
            return a.sort_key > b.sort_key;
        }
    }.cmp);

    const columns = [_]ListW.Column{
        .{ .label = "COIN", .width = 12 },
        .{ .label = "PRICE", .width = 14, .right_align = true },
        .{ .label = "LEV", .width = 6, .right_align = true },
    };

    try runListView(&columns, items_slice, count, .{
        .title = "PERP MARKETS",
        .help = "j/k:nav  /:search  s:sort  Enter:book  q:quit",
        .allocator = allocator,
        .config = config,
        .on_select = &marketsOnSelect,
    });
}

fn marketsOnSelect(allocator: std.mem.Allocator, config: Config, items: []const ListW.Item, idx: usize) void {
    const coin = items[idx].cells[0];
    const ba = args_mod.BookArgs{ .coin = coin, .depth = 15, .live = true };
    bookLive(allocator, config, ba) catch {};
}
