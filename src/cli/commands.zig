
const std = @import("std");
const posix = std.posix;
const hlz = @import("hlz");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const output_mod = @import("output.zig");
const keystore = @import("keystore.zig");
const client_mod = hlz.hypercore.client;
const response = hlz.hypercore.response;
const types = hlz.hypercore.types;
const signing = hlz.hypercore.signing;
const json_mod = hlz.hypercore.json;
const ws_types = hlz.hypercore.ws;
const WsConnection = ws_types.Connection;
const Decimal = hlz.math.decimal.Decimal;

const Client = client_mod.Client;
const Signer = hlz.crypto.signer.Signer;
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

pub fn keys(allocator: std.mem.Allocator, w: *Writer, a: args_mod.KeysArgs) !void {
    const password = a.password orelse std.posix.getenv("HL_PASSWORD") orelse {
        // For ls, no password needed
        if (a.action == .ls) return keysLs(allocator, w);
        if (a.action == .rm) return keysRm(w, a.name orelse {
            try w.err("usage: hl keys rm <name>");
            return;
        });
        if (a.action == .default) return keysDefault(w, a.name orelse {
            try w.err("usage: hl keys default <name>");
            return;
        });
        try w.err("password required: --password <PASS> or HL_PASSWORD env");
        return;
    };

    switch (a.action) {
        .ls => return keysLs(allocator, w),
        .new => {
            const name = a.name orelse {
                try w.err("usage: hl keys new <name> --password <PASS>");
                return;
            };
            // Generate random 32-byte private key
            var priv: [32]u8 = undefined;
            std.crypto.random.bytes(&priv);
            const json = keystore.encrypt(allocator, priv, password) catch |e| {
                try w.errFmt("encrypt: {s}", .{@errorName(e)});
                return;
            };
            defer allocator.free(json);
            keystore.save(name, json) catch |e| {
                try w.errFmt("save: {s}", .{@errorName(e)});
                return;
            };
            const signer = Signer.init(priv) catch return;
            var addr_buf: [42]u8 = undefined;
            addr_buf[0] = '0';
            addr_buf[1] = 'x';
            const hex_chars = "0123456789abcdef";
            for (signer.address, 0..) |b, i| {
                addr_buf[2 + i * 2] = hex_chars[b >> 4];
                addr_buf[2 + i * 2 + 1] = hex_chars[b & 0xf];
            }
            // Zero out key
            @memset(&priv, 0);
            if (w.format == .json) {
                try w.jsonFmt("{{\"status\":\"created\",\"name\":\"{s}\",\"address\":\"{s}\"}}", .{ name, addr_buf });
            } else {
                try w.success(name);
                try w.print("  address: {s}\n  path:    ~/.hl/keys/{s}.json\n", .{ addr_buf, name });
                try w.nl();
                try w.styled(Style.muted, "  To use as API wallet, approve on your main account:\n");
                try w.print("    hl approve-agent {s}\n", .{addr_buf});
                try w.styled(Style.muted, "  Or approve via web UI:\n");
                try w.print("    https://app.hyperliquid.xyz/API\n", .{});
            }
        },
        .import_ => {
            const name = a.name orelse {
                try w.err("usage: hl keys import <name> --private-key <HEX> --password <PASS>");
                return;
            };
            const hex = a.key_hex orelse std.posix.getenv("HL_KEY") orelse {
                try w.err("provide key: --private-key <HEX> or HL_KEY env");
                return;
            };
            const signer = Signer.fromHex(hex) catch {
                try w.err("invalid private key hex");
                return;
            };
            var priv: [32]u8 = signer.private_key;
            const json = keystore.encrypt(allocator, priv, password) catch |e| {
                try w.errFmt("encrypt: {s}", .{@errorName(e)});
                return;
            };
            defer allocator.free(json);
            keystore.save(name, json) catch |e| {
                try w.errFmt("save: {s}", .{@errorName(e)});
                return;
            };
            @memset(&priv, 0);
            var addr_buf: [42]u8 = undefined;
            addr_buf[0] = '0';
            addr_buf[1] = 'x';
            const hex_chars = "0123456789abcdef";
            for (signer.address, 0..) |b, i| {
                addr_buf[2 + i * 2] = hex_chars[b >> 4];
                addr_buf[2 + i * 2 + 1] = hex_chars[b & 0xf];
            }
            if (w.format == .json) {
                try w.jsonFmt("{{\"status\":\"imported\",\"name\":\"{s}\",\"address\":\"{s}\"}}", .{ name, addr_buf });
            } else {
                try w.success(name);
                try w.print("  address: {s}\n  path: ~/.hl/keys/{s}.json\n", .{ addr_buf, name });
            }
        },
        .export_ => {
            const name = a.name orelse {
                try w.err("usage: hl keys export <name> --password <PASS>");
                return;
            };
            const data = keystore.load(allocator, name) catch {
                try w.errFmt("key \"{s}\" not found", .{name});
                return;
            };
            defer allocator.free(data);
            var priv = keystore.decrypt(allocator, data, password) catch |e| {
                if (e == error.BadPassword) {
                    try w.err("wrong password");
                } else {
                    try w.errFmt("decrypt: {s}", .{@errorName(e)});
                }
                return;
            };
            // Print hex (stderr for safety, stdout only if piped/json)
            var hex_buf: [66]u8 = undefined;
            hex_buf[0] = '0';
            hex_buf[1] = 'x';
            const hc = "0123456789abcdef";
            for (priv, 0..) |b, i| {
                hex_buf[2 + i * 2] = hc[b >> 4];
                hex_buf[2 + i * 2 + 1] = hc[b & 0xf];
            }
            @memset(&priv, 0);
            if (w.format == .json) {
                try w.jsonFmt("{{\"name\":\"{s}\",\"key\":\"{s}\"}}", .{ name, hex_buf });
            } else {
                try w.print("{s}\n", .{hex_buf});
            }
            @memset(&hex_buf, 0);
        },
        .rm => {
            const name = a.name orelse {
                try w.err("usage: hl keys rm <name>");
                return;
            };
            return keysRm(w, name);
        },
        .default => {
            const name = a.name orelse {
                try w.err("usage: hl keys default <name>");
                return;
            };
            return keysDefault(w, name);
        },
    }
}

fn keysLs(allocator: std.mem.Allocator, w: *Writer) !void {
    const entries = keystore.list(allocator) catch {
        try w.err("failed to list keys");
        return;
    };
    defer allocator.free(entries);

    if (entries.len == 0) {
        if (w.format == .json) {
            try w.jsonRaw("[]");
        } else {
            try w.styled(Style.muted, "  no keys. Run: hl keys new <name> --password <PASS>\n");
        }
        return;
    }

    if (w.format == .json) {
        var jbuf: [4096]u8 = undefined;
        var jlen: usize = 0;
        jbuf[0] = '[';
        jlen = 1;
        for (entries, 0..) |e, i| {
            if (i > 0) { jbuf[jlen] = ','; jlen += 1; }
            jlen += (std.fmt.bufPrint(jbuf[jlen..], "{{\"name\":\"{s}\",\"address\":\"{s}\",\"default\":{s}}}", .{
                e.getName(), e.address, if (e.is_default) "true" else "false",
            }) catch break).len;
        }
        jbuf[jlen] = ']';
        jlen += 1;
        try w.jsonRaw(jbuf[0..jlen]);
        return;
    }

    try w.heading("KEYS");
    for (entries) |e| {
        const default_mark: []const u8 = if (e.is_default) " *" else "";
        try w.print("  ", .{});
        try w.styled(Style.bold_cyan, e.getName());
        try w.styled(Style.muted, "  ");
        try w.styled(Style.white, &e.address);
        try w.styled(Style.yellow, default_mark);
        try w.nl();
    }
    try w.footer();
}

fn keysRm(w: *Writer, name: []const u8) !void {
    keystore.remove(name) catch {
        try w.errFmt("key \"{s}\" not found", .{name});
        return;
    };
    if (w.format == .json) {
        try w.jsonFmt("{{\"status\":\"removed\",\"name\":\"{s}\"}}", .{name});
    } else {
        try w.success("removed");
        try w.print("  {s}\n", .{name});
    }
}

fn keysDefault(w: *Writer, name: []const u8) !void {
    // Verify key exists
    const home = std.posix.getenv("HOME") orelse "";
    var pbuf: [576]u8 = undefined;
    const kpath = std.fmt.bufPrint(&pbuf, "{s}/.hl/keys/{s}.json", .{ home, name }) catch {
        try w.errFmt("key \"{s}\" not found", .{name});
        return;
    };
    std.fs.cwd().access(kpath, .{}) catch {
        try w.errFmt("key \"{s}\" not found", .{name});
        return;
    };
    keystore.setDefault(name) catch {
        try w.err("failed to set default");
        return;
    };
    if (w.format == .json) {
        try w.jsonFmt("{{\"status\":\"default\",\"name\":\"{s}\"}}", .{name});
    } else {
        try w.success("default set");
        try w.print("  {s}\n", .{name});
    }
}

pub fn approveAgent(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ApproveAgentArgs) !void {
    const agent_addr = a.agent_address orelse {
        try w.err("usage: hl approve-agent <ADDRESS> [--name <NAME>]");
        try w.nl();
        try w.styled(Style.muted, "  Or approve via web UI:\n");
        const url: []const u8 = if (config.chain == .mainnet) "https://app.hyperliquid.xyz/API" else "https://app.hyperliquid-testnet.xyz/API";
        try w.print("  {s}\n", .{url});
        return;
    };
    const key = config.key_hex orelse { try w.err("private key required"); return; };
    const signer = Signer.fromHex(key) catch { try w.err("invalid key"); return; };
    var client = switch (config.chain) { .mainnet => Client.mainnet(allocator), .testnet => Client.testnet(allocator) };
    defer client.deinit();
    const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
    var result = client.approveAgent(signer, agent_addr, a.agent_name, nonce) catch |e| {
        try w.errFmt("approve failed: {s}", .{@errorName(e)});
        return;
    };
    defer result.deinit();
    if (result.isOk() catch false) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"status\":\"approved\",\"agent\":\"{s}\"}}", .{agent_addr});
        } else {
            try w.success("Agent approved");
            try w.print("  {s}\n", .{agent_addr});
        }
    } else {
        const val = result.json() catch { try w.err("Agent approval rejected"); return; };
        const resp = json_mod.getString(val, "response") orelse "rejected";
        try w.errFmt("Approval failed: {s}", .{resp});
    }
}

pub fn showConfig(w: *Writer, config: Config) !void {
    if (w.format == .json) {
        try w.jsonFmt("{{\"chain\":\"{s}\",\"address\":{s},\"key_set\":{s}}}", .{
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

    if (w.format == .json and !a.all_dexes) {
        var raw = try client.clearinghouseState(addr, a.dex);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getClearinghouseState(addr, a.dex);
    defer typed.deinit();
    const state = typed.value;

    try w.heading("POSITIONS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 6 },
        .{ .text = "SIDE", .width = 9 },
        .{ .text = "SIZE", .width = 10, .align_right = true },
        .{ .text = "ENTRY", .width = 10, .align_right = true },
        .{ .text = "VALUE", .width = 10, .align_right = true },
        .{ .text = "PNL", .width = 10, .align_right = true },
        .{ .text = "ROE", .width = 8 },
    };
    try w.tableHeader(&hdr);

    for (state.assetPositions) |ap| {
        const pos = ap.position;
        var szi_buf: [32]u8 = undefined;
        var entry_buf: [32]u8 = undefined;
        var pnl_buf: [32]u8 = undefined;

        const szi = pos.szi;
        const szi_str = szi.normalize().toString(&szi_buf) catch continue;
        if (szi.mantissa == 0) continue;

        const is_short = szi.isNegative();
        var side_buf: [16]u8 = undefined;
        const side_str: []const u8 = if (is_short)
            std.fmt.bufPrint(&side_buf, "\xe2\x96\xbc SHORT", .{}) catch "SHORT"
        else
            std.fmt.bufPrint(&side_buf, "\xe2\x96\xb2 LONG", .{}) catch "LONG";
        const side_color: []const u8 = if (is_short) Style.red else Style.green;
        const entry_str = decStr(pos.entryPx, &entry_buf);
        var val_buf: [32]u8 = undefined;
        const val_str = decStr(pos.positionValue, &val_buf);
        const pnl_str = decStr(pos.unrealizedPnl, &pnl_buf);

        var roe_buf: [16]u8 = undefined;
        const roe_f = blk: {
            const pnl_f = if (pos.unrealizedPnl) |p| decToF64(p) else break :blk @as(f64, 0);
            const margin_f = if (pos.marginUsed) |m| decToF64(m) else break :blk @as(f64, 0);
            if (margin_f == 0) break :blk @as(f64, 0);
            break :blk pnl_f / margin_f * 100.0;
        };
        const roe_str = std.fmt.bufPrint(&roe_buf, "{d:.1}%", .{roe_f}) catch "-";

        var abs_buf: [32]u8 = undefined;
        const abs_str = if (szi.isNegative()) blk: {
            const abs = szi.negate();
            break :blk abs.normalize().toString(&abs_buf) catch szi_str;
        } else szi_str;

        // Format ROE as badge string (will be rendered inline)
        const roe_color: []const u8 = if (roe_f < 0) Style.bold_red else Style.bold_green;

        const cols = [_]Column{
            .{ .text = pos.coin, .width = 6, .color = Style.bold_cyan },
            .{ .text = side_str, .width = 9, .color = side_color },
            .{ .text = abs_str, .width = 10, .align_right = true },
            .{ .text = entry_str, .width = 10, .align_right = true, .color = Style.muted },
            .{ .text = val_str, .width = 10, .align_right = true },
            .{ .text = pnl_str, .width = 10, .align_right = true, .color = Writer.pnlColor(pos.unrealizedPnl) },
            .{ .text = roe_str, .width = 8, .align_right = true, .color = roe_color },
        };
        try w.tableRow(&cols);
    }
    try w.footer();

    // HIP-3 DEX positions
    if (a.all_dexes) {
        var dex_typed = client.getPerpDexs() catch null;
        if (dex_typed) |*dt| {
            defer dt.deinit();
            for (dt.value) |dex| {
                var dex_state = client.getClearinghouseState(addr, dex.name) catch continue;
                defer dex_state.deinit();
                var has_dex_pos = false;
                for (dex_state.value.assetPositions) |ap| {
                    const p = ap.position;
                    const szi_f = decToF64(p.szi);
                    if (szi_f == 0) continue;
                    if (!has_dex_pos) {
                        try w.print("\n", .{});
                        try w.styled(Style.bold, "DEX: ");
                        try w.styled(Style.cyan, dex.name);
                        try w.print("\n", .{});
                        has_dex_pos = true;
                    }
                    var szi_buf: [32]u8 = undefined;
                    var entry_buf: [32]u8 = undefined;
                    var pnl_buf: [32]u8 = undefined;
                    const side_s: []const u8 = if (szi_f > 0) "LONG" else "SHORT";
                    try w.print("  {s: <8} {s: <6} {s: >12} entry {s: >10} pnl {s}\n", .{
                        p.coin,
                        side_s,
                        decFmt(p.szi, &szi_buf),
                        if (p.entryPx) |ep| decFmt(ep, &entry_buf) else "-",
                        if (p.unrealizedPnl) |up| decFmt(up, &pnl_buf) else "-",
                    });
                }
            }
        }
    }
}

pub fn orders(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var raw = try client.openOrders(addr, a.dex);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getOpenOrders(addr, a.dex);
    defer typed.deinit();
    const open_orders = typed.value;

    try w.heading("OPEN ORDERS");
    const hdr = [_]Column{
        .{ .text = "COIN", .width = 8 },
        .{ .text = "SIDE", .width = 6 },
        .{ .text = "SIZE", .width = 12, .align_right = true },
        .{ .text = "PRICE", .width = 12, .align_right = true },
        .{ .text = "OID", .width = 12, .align_right = true },
    };
    try w.tableHeader(&hdr);

    for (open_orders) |ord| {
        var sz_buf: [32]u8 = undefined;
        var px_buf: [32]u8 = undefined;
        var oid_buf: [20]u8 = undefined;

        const side_color: []const u8 = if (std.mem.eql(u8, ord.side, "B")) Style.green else Style.red;
        const side_str: []const u8 = if (std.mem.eql(u8, ord.side, "B")) "BUY" else "SELL";

        const cols = [_]Column{
            .{ .text = ord.coin, .width = 8, .color = Style.cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = decFmt(ord.sz, &sz_buf), .width = 12, .align_right = true },
            .{ .text = decFmt(ord.limitPx, &px_buf), .width = 12, .align_right = true },
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

    if (w.format == .json) {
        var raw = try client.userFills(addr);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getUserFills(addr);
    defer typed.deinit();

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

    const limit = @min(typed.value.len, 20);
    for (typed.value[0..limit]) |fill| {
        var sz_buf: [32]u8 = undefined;
        var px_buf: [32]u8 = undefined;
        var fee_buf: [32]u8 = undefined;
        var pnl_buf: [32]u8 = undefined;

        const side_color: []const u8 = if (std.mem.eql(u8, fill.side, "B")) Style.green else Style.red;
        const side_str: []const u8 = if (std.mem.eql(u8, fill.side, "B")) "BUY" else "SELL";

        const cols = [_]Column{
            .{ .text = fill.coin, .width = 8, .color = Style.cyan },
            .{ .text = side_str, .width = 6, .color = side_color },
            .{ .text = decFmt(fill.sz, &sz_buf), .width = 12, .align_right = true },
            .{ .text = decFmt(fill.px, &px_buf), .width = 12, .align_right = true },
            .{ .text = decFmt(fill.fee, &fee_buf), .width = 10, .align_right = true, .color = Style.dim },
            .{ .text = decStr(fill.closedPnl, &pnl_buf), .width = 12, .align_right = true, .color = Writer.pnlColor(fill.closedPnl) },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn balance(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var spot_raw = try client.spotBalances(addr);
        defer spot_raw.deinit();
        var perp_raw = try client.clearinghouseState(addr, a.dex);
        defer perp_raw.deinit();
        var combo_buf: [16384]u8 = undefined;
        const combo = std.fmt.bufPrint(&combo_buf, "{{\"spot\":{s},\"perp\":{s}}}", .{ spot_raw.body, perp_raw.body }) catch return;
        try w.jsonRaw(combo);
        return;
    }

    var perp_typed = try client.getClearinghouseState(addr, a.dex);
    defer perp_typed.deinit();
    const state = perp_typed.value;
    const m = state.marginSummary;

    // Hero-style account header
    try w.nl();
    try w.styled(Style.muted, "  ACCOUNT\n\n");

    {
        var av_buf: [32]u8 = undefined;
        try w.print("  ", .{});
        try w.styled(Style.bold_white, "$");
        try w.styled(Style.bold_white, decFmt(m.accountValue, &av_buf));
        try w.nl();
        try w.nl();

        try w.style(Style.subtle);
        try w.print("  ", .{});
        var si: usize = 0;
        while (si < 52) : (si += 1) try w.print("\xe2\x94\x80", .{});
        try w.style(Style.reset);
        try w.nl();

        var mu_buf: [32]u8 = undefined;
        var wd_buf: [32]u8 = undefined;

        try w.style(Style.muted);
        try w.print("  margin ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(m.totalMarginUsed, &mu_buf));
        try w.style(Style.muted);
        try w.print("  free ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(state.withdrawable, &wd_buf));

        const av_f = decToF64(m.accountValue);
        const mu_f = decToF64(m.totalMarginUsed);
        const health_pct: f64 = if (mu_f > 0 and av_f > 0)
            @max(0, @min(100, 100.0 - (mu_f / av_f * 100.0)))
        else
            100.0;
        const health_color: []const u8 = if (health_pct > 50) Style.bold_green else if (health_pct > 25) Style.bold_yellow else Style.bold_red;
        try w.style(Style.muted);
        try w.print("  health ", .{});
        try w.style(Style.reset);
        try w.bar(health_pct, 100.0, 8, health_color);
        var pct_buf: [8]u8 = undefined;
        const pct_str = std.fmt.bufPrint(&pct_buf, " {d:.0}%", .{health_pct}) catch "?";
        try w.styled(health_color, pct_str);
        try w.nl();
    }
    try w.nl();

    var spot_typed = client.getSpotBalances(addr) catch {
        try w.nl();
        return;
    };
    defer spot_typed.deinit();
    const balances = spot_typed.value.balances;

    {
        var nz: usize = 0;
        for (balances) |b| {
            if (decToF64(b.total) != 0) nz += 1;
        }
        if (nz > 0) {
            try w.heading("SPOT");
            const hdr = [_]Column{
                .{ .text = "TOKEN", .width = 10 },
                .{ .text = "BALANCE", .width = 18, .align_right = true },
                .{ .text = "HOLD", .width = 14, .align_right = true },
            };
            try w.tableHeader(&hdr);

            for (balances) |b| {
                var total_buf: [32]u8 = undefined;
                var hold_buf: [32]u8 = undefined;
                const total_f = decToF64(b.total);
                if (total_f == 0) continue;
                const hold_f = decToF64(b.hold);
                const hold_str: []const u8 = if (hold_f != 0) decFmt(b.hold, &hold_buf) else "";
                const cols = [_]Column{
                    .{ .text = b.coin, .width = 10, .color = Style.cyan },
                    .{ .text = decFmt(b.total, &total_buf), .width = 18, .align_right = true },
                    .{ .text = hold_str, .width = 14, .align_right = true, .color = Style.muted },
                };
                try w.tableRow(&cols);
            }
        }
    }

    // HIP-3 DEX balances (--all-dexes)
    if (a.all_dexes) {
        var dex_typed = client.getPerpDexs() catch null;
        if (dex_typed) |*dt| {
            defer dt.deinit();
            for (dt.value) |dex| {
                var dex_state = client.getClearinghouseState(addr, dex.name) catch continue;
                defer dex_state.deinit();
                const dm = dex_state.value.marginSummary;
                const av_f = decToF64(dm.accountValue);
                if (av_f == 0) continue;
                var title_buf: [32]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "DEX \xc2\xb7 {s}", .{dex.name}) catch "DEX";
                try w.heading(title);
                var dav_buf: [32]u8 = undefined;
                var dmu_buf: [32]u8 = undefined;
                try w.kv("Account Value", decFmt(dm.accountValue, &dav_buf));
                try w.kv("Margin Used", decFmt(dm.totalMarginUsed, &dmu_buf));
            }
        }
    }

    try w.footer();
}

pub fn perps(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var raw = try client.perps(a.dex);
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getPerps(a.dex);
    defer typed.deinit();
    const universe = typed.value.universe;

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

    for (universe) |pm| {
        if (a.filter) |f| { if (!containsInsensitive(pm.name, f)) continue; }
        total += 1;
    }

    for (universe) |pm| {
        if (shown >= limit) break;
        const m = pm;
        if (a.filter) |f| { if (!containsInsensitive(m.name, f)) continue; }
        if (skipped < start) { skipped += 1; continue; }
        var lev_buf: [16]u8 = undefined;
        var dec_buf: [8]u8 = undefined;
        const cols = [_]Column{
            .{ .text = m.name, .width = 12, .color = Style.cyan },
            .{ .text = std.fmt.bufPrint(&lev_buf, "{d}x", .{m.maxLeverage}) catch "?", .width = 8, .align_right = true, .color = Style.yellow },
            .{ .text = std.fmt.bufPrint(&dec_buf, "{d}", .{m.szDecimals}) catch "?", .width = 7, .align_right = true },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

fn perpsTui(allocator: std.mem.Allocator, config: Config, universe: []const response.PerpMeta) !void {
    const n = @min(universe.len, ListW.MAX_ITEMS);

    const CellBuf = struct { lev: [16]u8 = undefined, lev_len: usize = 0, dec: [8]u8 = undefined, dec_len: usize = 0 };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };
    const yellow = BufMod.Style{ .fg = .yellow };

    for (0..n) |i| {
        const m = universe[i];
        const lev_s = std.fmt.bufPrint(&cell_bufs[i].lev, "{d}x", .{m.maxLeverage}) catch "?";
        cell_bufs[i].lev_len = lev_s.len;
        const dec_s = std.fmt.bufPrint(&cell_bufs[i].dec, "{d}", .{m.szDecimals}) catch "?";
        cell_bufs[i].dec_len = dec_s.len;

        items[i] = .{
            .cells = cellsInit(&.{ m.name, cell_bufs[i].lev[0..cell_bufs[i].lev_len], cell_bufs[i].dec[0..cell_bufs[i].dec_len] }),
            .styles = stylesInit(&.{ cyan, yellow }),
            .sort_key = @as(f64, @floatFromInt(m.maxLeverage)),
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

    if (w.format == .json) {
        var raw = try client.perpDexs();
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getDexInfos();
    defer typed.deinit();

    try w.heading("HIP-3 DEXES");
    const hdr = [_]Column{
        .{ .text = "NAME", .width = 10 },
        .{ .text = "FULL NAME", .width = 16 },
        .{ .text = "MARKETS", .width = 8, .align_right = true },
        .{ .text = "DEPLOYER", .width = 14 },
    };
    try w.tableHeader(&hdr);

    for (typed.value) |d| {
        const name = d.name;
        const full_name = d.fullName orelse name;
        const deployer_full = d.deployer orelse "-";
        const markets_count: usize = if (d.assetToStreamingOiCap) |oi| oi.len else 0;
        var cnt_buf: [8]u8 = undefined;
        const cnt_str = std.fmt.bufPrint(&cnt_buf, "{d}", .{markets_count}) catch "?";
        // Truncate deployer to 0x1234...5678
        var dep_buf: [14]u8 = undefined;
        const dep_str = if (deployer_full.len >= 42) blk: {
            @memcpy(dep_buf[0..6], deployer_full[0..6]);
            @memcpy(dep_buf[6..9], "...");
            @memcpy(dep_buf[9..13], deployer_full[38..42]);
            dep_buf[13] = 0;
            break :blk dep_buf[0..13];
        } else deployer_full;

        const cols = [_]Column{
            .{ .text = name, .width = 10, .color = Style.bold_cyan },
            .{ .text = full_name, .width = 16 },
            .{ .text = cnt_str, .width = 8, .align_right = true, .color = Style.yellow },
            .{ .text = dep_str, .width = 14, .color = Style.muted },
        };
        try w.tableRow(&cols);
    }
    try w.footer();
}

pub fn spotMarkets(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.MarketArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    if (w.format == .json) {
        var raw = try client.spot();
        defer raw.deinit();
        try w.jsonRaw(raw.body);
        return;
    }

    var typed = try client.getSpotMeta();
    defer typed.deinit();
    const tokens = typed.value.tokens;

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
    for (tokens) |t| {
        if (a.filter) |f| { if (!containsInsensitive(t.name, f)) continue; }
        total += 1;
    }

    var shown: usize = 0;
    var skipped: usize = 0;
    for (tokens) |t| {
        if (shown >= limit) break;
        if (a.filter) |f| { if (!containsInsensitive(t.name, f)) continue; }
        if (skipped < start) { skipped += 1; continue; }
        var idx_buf: [8]u8 = undefined;
        var sz_buf: [8]u8 = undefined;
        var wei_buf: [8]u8 = undefined;
        const cols = [_]Column{
            .{ .text = t.name, .width = 12, .color = Style.cyan },
            .{ .text = std.fmt.bufPrint(&idx_buf, "{d}", .{t.index}) catch "?", .width = 6, .align_right = true },
            .{ .text = std.fmt.bufPrint(&sz_buf, "{d}", .{t.szDecimals}) catch "?", .width = 7, .align_right = true },
            .{ .text = std.fmt.bufPrint(&wei_buf, "{d}", .{t.weiDecimals}) catch "?", .width = 8, .align_right = true },
        };
        try w.tableRow(&cols);
        shown += 1;
    }
    const pages = (total + per_page - 1) / per_page;
    if (!a.all and start + shown < total) try w.paginatePage(shown, total, a.page, pages);
    try w.footer();
}

fn spotTui(allocator: std.mem.Allocator, tokens_arr: []const response.SpotToken) !void {
    const n = @min(tokens_arr.len, ListW.MAX_ITEMS);

    const CellBuf = struct { idx: [8]u8 = undefined, idx_len: usize = 0, sz: [8]u8 = undefined, sz_len: usize = 0, wei: [8]u8 = undefined, wei_len: usize = 0 };
    var cell_bufs: [ListW.MAX_ITEMS]CellBuf = undefined;
    var items: [ListW.MAX_ITEMS]ListW.Item = undefined;
    var count: usize = 0;

    const cyan = BufMod.Style{ .fg = .cyan, .bold = true };

    for (0..n) |i| {
        const t = tokens_arr[i];
        const idx_s = std.fmt.bufPrint(&cell_bufs[count].idx, "{d}", .{t.index}) catch "?";
        cell_bufs[count].idx_len = idx_s.len;
        const sz_s = std.fmt.bufPrint(&cell_bufs[count].sz, "{d}", .{t.szDecimals}) catch "?";
        cell_bufs[count].sz_len = sz_s.len;
        const wei_s = std.fmt.bufPrint(&cell_bufs[count].wei, "{d}", .{t.weiDecimals}) catch "?";
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

    // Trigger order: --trigger-above or --trigger-below
    const is_trigger = a.trigger_px != null;
    const is_market = a.price == null and !is_trigger;

    const order_type: types.OrderTypePlacement = if (is_trigger) blk: {
        const tpx = Decimal.fromString(a.trigger_px.?) catch return error.Overflow;
        break :blk .{ .trigger = .{
            .is_market = a.price == null,
            .trigger_px = tpx,
            .tpsl = if (a.trigger_is_tp) .tp else .sl,
        } };
    } else if (!is_market) blk: {
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
        var book_typed = client.getL2Book(a.coin) catch
            break :blk if (is_buy) Decimal.fromString("999999") catch unreachable else Decimal.fromString("0.01") catch unreachable;
        defer book_typed.deinit();
        const bl = book_typed.value.levels;
        if (is_buy) {
            if (bl[1].len > 0) {
                const ask_px = decToF64(bl[1][0].px);
                const slippage_px = ask_px * 1.005;
                var sl_buf: [32]u8 = undefined;
                break :blk Decimal.fromString(slippageFmt(&sl_buf, slippage_px)) catch Decimal.fromString("999999") catch unreachable;
            }
            break :blk Decimal.fromString("999999") catch unreachable;
        } else {
            if (bl[0].len > 0) {
                const bid_px = decToF64(bl[0][0].px);
                const slippage_px = bid_px * 0.995;
                var sl_buf: [32]u8 = undefined;
                break :blk Decimal.fromString(slippageFmt(&sl_buf, slippage_px)) catch Decimal.fromString("0.01") catch unreachable;
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

    // Bracket: attach TP and/or SL orders
    var bracket_orders: [3]types.OrderRequest = undefined;
    var bracket_count: usize = 1;
    bracket_orders[0] = order;

    if (a.tp) |tp_str| {
        const tp_px = Decimal.fromString(tp_str) catch return error.Overflow;
        bracket_orders[bracket_count] = .{
            .asset = asset,
            .is_buy = !is_buy, // TP closes the position (opposite side)
            .limit_px = tp_px,
            .sz = sz,
            .reduce_only = true,
            .order_type = .{ .trigger = .{ .is_market = true, .trigger_px = tp_px, .tpsl = .tp } },
            .cloid = types.ZERO_CLOID,
        };
        bracket_count += 1;
    }
    if (a.sl) |sl_str| {
        const sl_px = Decimal.fromString(sl_str) catch return error.Overflow;
        bracket_orders[bracket_count] = .{
            .asset = asset,
            .is_buy = !is_buy, // SL closes the position (opposite side)
            .limit_px = sl_px,
            .sz = sz,
            .reduce_only = true,
            .order_type = .{ .trigger = .{ .is_market = true, .trigger_px = sl_px, .tpsl = .sl } },
            .cloid = types.ZERO_CLOID,
        };
        bracket_count += 1;
    }

    const grouping: types.OrderGrouping = if (bracket_count > 1) .normalTpsl else .na;
    const batch = types.BatchOrder{
        .orders = bracket_orders[0..bracket_count],
        .grouping = grouping,
    };

    // --dry-run: preview without sending
    if (a.dry_run) {
        if (w.format == .json) {
            var db: [512]u8 = undefined;
            var lp_buf: [32]u8 = undefined;
            var sz_dbuf: [32]u8 = undefined;
            const lp_s = limit_px.normalize().toString(&lp_buf) catch "?";
            const sz_s = sz.normalize().toString(&sz_dbuf) catch "?";
            const dr = std.fmt.bufPrint(&db,
                \\{{"status":"dry_run","side":"{s}","coin":"{s}","size":"{s}","price":"{s}","reduce_only":{s},"bracket":{d}}}
            , .{
                if (is_buy) "buy" else "sell",
                a.coin,
                sz_s,
                lp_s,
                if (a.reduce_only) "true" else "false",
                bracket_count - 1,
            }) catch "{}";
            try w.jsonRaw(dr);
        } else {
            try w.styled(Style.bold_yellow, "⊘ dry-run");
            try w.print(" {s} {s}", .{ if (is_buy) "buy" else "sell", a.coin });
            var sz_dbuf: [32]u8 = undefined;
            var lp_buf: [32]u8 = undefined;
            try w.print(" {s} @ {s}", .{ sz.normalize().toString(&sz_dbuf) catch "?", limit_px.normalize().toString(&lp_buf) catch "?" });
            if (a.reduce_only) try w.print(" reduce-only", .{});
            if (bracket_count > 1) try w.print(" +{d} bracket", .{bracket_count - 1});
            try w.nl();
        }
        return;
    }

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
                try w.styled(Style.bold_green, "\xe2\x9c\x93 resting");
                var oid_buf: [20]u8 = undefined;
                try w.print(" oid={s}\n", .{std.fmt.bufPrint(&oid_buf, "{d}", .{r.oid}) catch "?"});
            },
            .filled => |f| {
                try w.styled(Style.bold_green, "\xe2\x9c\x93 filled");
                var avg_buf: [32]u8 = undefined;
                try w.print(" avg={s}\n", .{decStr(f.avgPx, &avg_buf)});
            },
            .success => try w.success("accepted"),
            .@"error" => |msg| try w.errFmt("rejected: {s}", .{msg}),
            .unknown => try w.err("unknown response"),
        }
    } else {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("submitted"),
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

    // cancel ETH (no OID, no CLOID) → cancel all orders for this coin
    if (a.oid == null and a.cloid == null) {
        const addr = config.getAddress() orelse config.requireAddress() catch return error.MissingAddress;
        var orders_typed = try client.getOpenOrders(addr, null);
        defer orders_typed.deinit();

        // Collect OIDs matching this coin
        var cancels: [64]types.Cancel = undefined;
        var cancel_count: usize = 0;
        for (orders_typed.value) |order| {
            if (!std.ascii.eqlIgnoreCase(order.coin, coin)) continue;
            const oid = order.oid;
            if (cancel_count >= 64) break;
            cancels[cancel_count] = .{ .asset = asset, .oid = oid };
            cancel_count += 1;
        }

        if (cancel_count == 0) {
            if (w.format == .json) {
                try w.jsonFmt("{{\"status\":\"ok\",\"cancelled\":0}}", .{});
            } else {
                try w.print("no open orders for {s}\n", .{coin});
            }
            return;
        }

        const batch = types.BatchCancel{ .cancels = cancels[0..cancel_count] };
        var result = try client.cancel(signer, batch, nonce, null, null);
        defer result.deinit();

        if (w.format == .json) {
            try w.jsonRaw(result.body);
            return;
        }
        const ok = try result.isOk();
        if (ok) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d} {s} orders cancelled", .{ cancel_count, coin }) catch "orders cancelled";
            try w.success(msg);
        } else {
            try w.err("cancel failed");
            try w.print("{s}\n", .{result.body});
        }
        return;
    }

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

    if (w.format == .json) {
        var result = try client.metaAndAssetCtxs();
        defer result.deinit();
        try w.jsonRaw(result.body);
        return;
    }

    var mac = try client.getMetaAndAssetCtxs(null);
    defer mac.deinit();

    var sorted = try parseFundingData(allocator, mac.entries);
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
        if (is_tty) p = emit(&buf, p, Style.muted);
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
        const bg_color: []const u8 = if (is_neg) Style.bg_red else Style.bg_green;
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
        var mark_buf2: [32]u8 = undefined;
        p = lpad(&buf, p, decFmt(e.mark, &mark_buf2), 12);
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
        mark: [32]u8 = undefined,
        mark_len: usize = 0,
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

        const mark_s = e.mark.normalize().toString(&cell_bufs[i].mark) catch "0";
        cell_bufs[i].mark_len = mark_s.len;

        const color: BufMod.Style = if (e.funding < 0) .{ .fg = .red } else if (e.funding > 0) .{ .fg = .green } else .{ .fg = .grey };

        items[i] = .{
            .cells = cellsInit(&.{ e.name, cell_bufs[i].rate[0..cell_bufs[i].rate_len], cell_bufs[i].ann[0..cell_bufs[i].ann_len], "", cell_bufs[i].mark[0..cell_bufs[i].mark_len] }),
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
    oi: Decimal,
    mark: Decimal,
};

const FundingData = struct {
    entries: []FundingEntry,
    count: usize,
    alloc_len: usize,
};

fn parseFundingData(allocator: std.mem.Allocator, mac_entries: []const response.MetaAndAssetCtx) !FundingData {
    var entries = try allocator.alloc(FundingEntry, mac_entries.len);
    var count: usize = 0;

    for (mac_entries) |e| {
        entries[count] = .{
            .name = e.meta.name,
            .funding = decToF64(e.ctx.funding),
            .oi = e.ctx.openInterest,
            .mark = if (e.ctx.markPx) |mp| mp else Decimal.ZERO,
        };
        count += 1;
    }

    std.mem.sort(FundingEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, lhs: FundingEntry, rhs: FundingEntry) bool {
            return @abs(lhs.funding) > @abs(rhs.funding);
        }
    }.lessThan);

    return .{ .entries = entries[0..count], .count = count, .alloc_len = mac_entries.len };
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

    if (w.format == .json) {
        var result = try client.l2Book(coin);
        defer result.deinit();
        try w.jsonRaw(result.body);
        return;
    }

    var typed = client.getL2Book(coin) catch {
        try w.err("no book data");
        return;
    };
    defer typed.deinit();
    const book_data = typed.value;

    const bids_raw = book_data.levels[0];
    const asks_raw = book_data.levels[1];
    const depth = @min(a.depth, @min(bids_raw.len, asks_raw.len));

    const Level = struct { px: Decimal, sz: f64, cum: f64 };
    var bids = try allocator.alloc(Level, depth);
    defer allocator.free(bids);
    var asks = try allocator.alloc(Level, depth);
    defer allocator.free(asks);

    var bid_cum: f64 = 0;
    var ask_cum: f64 = 0;
    for (0..depth) |i| {
        const bid_sz = decToF64(bids_raw[i].sz);
        bid_cum += bid_sz;
        bids[i] = .{ .px = bids_raw[i].px, .sz = bid_sz, .cum = bid_cum };

        const ask_sz = decToF64(asks_raw[i].sz);
        ask_cum += ask_sz;
        asks[i] = .{ .px = asks_raw[i].px, .sz = ask_sz, .cum = ask_cum };
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
        if (is_tty) p = emit(&buf, p, Style.muted);
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
        var ak_px_buf: [32]u8 = undefined;
        var ak_sz_buf: [32]u8 = undefined;
        if (is_tty) p = emit(&buf, p, Style.red);
        p = rpad(&buf, p, decFmt(ak.px, &ak_px_buf), px_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, floatFmt(&ak_sz_buf, ak.sz), sz_w);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, cum_str, cum_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, Style.bg_red);
        p = spaces(&buf, p, fill);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "\r\n");
        stdout.writeAll(buf[0..p]) catch {};
    }

    if (depth > 0) {
        const bid_f = decToF64(bids[0].px);
        const ask_f = decToF64(asks[0].px);
        const spread = ask_f - bid_f;
        const spread_pct = if (bid_f > 0) spread / bid_f * 100 else 0;
        var sbuf: [64]u8 = undefined;
        var sp_buf: [24]u8 = undefined;
        const sp_str = smartFmt(&sp_buf, spread);
        const ss = std.fmt.bufPrint(&sbuf, "spread: {s} ({d:.4}%)", .{ sp_str, spread_pct }) catch "";

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
        var b_px_buf: [32]u8 = undefined;
        var b_sz_buf: [32]u8 = undefined;
        if (is_tty) p = emit(&buf, p, Style.green);
        p = rpad(&buf, p, decFmt(b.px, &b_px_buf), px_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = lpad(&buf, p, floatFmt(&b_sz_buf, b.sz), sz_w);
        if (is_tty) p = emit(&buf, p, Style.dim);
        p = lpad(&buf, p, cum_str, cum_w);
        if (is_tty) p = emit(&buf, p, Style.reset);
        p = emit(&buf, p, "  ");
        if (is_tty) p = emit(&buf, p, Style.bg_green);
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
    return smartFmt(buf, value);
}

/// Adaptive decimal formatting: shows enough precision to be meaningful.
///   >= 1000    → 2 decimals  (67340.50)
///   >= 1       → 4 decimals  (85.8905)
///   >= 0.01    → 6 decimals  (0.003142)
///   < 0.01     → 8 decimals  (0.00003192)
fn emitSpotRow(w: *Writer, token: []const u8, bal_str: []const u8, val: f64, max_val: f64) !void {
    if (w.is_tty) {
        try w.print("  {s}{s}", .{ Style.rail_dim, Style.reset });
    } else {
        try w.print("  ", .{});
    }
    try w.print(" ", .{});
    try w.styled(Style.cyan, token);
    var i: usize = output_mod.displayWidth(token);
    while (i < 9) : (i += 1) try w.print(" ", .{});
    i = bal_str.len;
    while (i < 18) : (i += 1) try w.print(" ", .{});
    try w.styled(Style.bold_white, bal_str);
    try w.print(" ", .{});
    const ratio = if (max_val > 0) @sqrt(val / max_val) else 0.0;
    const fill = @max(if (val > 0) @as(usize, 1) else 0, @as(usize, @intFromFloat(ratio * 20.0)));
    try w.style(Style.bg_green);
    i = 0;
    while (i < fill) : (i += 1) try w.print(" ", .{});
    try w.style(Style.reset);
    try w.nl();
}

fn smartFmt(buf: []u8, value: f64) []const u8 {
    const abs = @abs(value);
    if (abs >= 1000) return std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?";
    if (abs >= 1) return std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch "?";
    if (abs >= 0.01) return std.fmt.bufPrint(buf, "{d:.6}", .{value}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.8}", .{value}) catch "?";
}

/// Format a slippage price preserving the precision of the original.
fn slippageFmt(buf: []u8, value: f64) []const u8 {
    const abs = @abs(value);
    if (abs >= 100) return std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "?";
    if (abs >= 1) return std.fmt.bufPrint(buf, "{d:.4}", .{value}) catch "?";
    if (abs >= 0.001) return std.fmt.bufPrint(buf, "{d:.6}", .{value}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.10}", .{value}) catch "?";
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

        var typed = std.json.parseFromSlice(response.L2Book, allocator, result.body, response.ParseOpts) catch continue;
        defer typed.deinit();
        const book_data = typed.value;

        const bids_bl = book_data.levels[0];
        const asks_bl = book_data.levels[1];
        const eff_depth = @min(depth, @min(bids_bl.len, asks_bl.len));

        const CumLevel = struct { px: Decimal, sz: f64, cum: f64 };
        var bid_levels: [64]CumLevel = undefined;
        var ask_levels: [64]CumLevel = undefined;
        var bid_cum: f64 = 0;
        var ask_cum: f64 = 0;

        for (0..eff_depth) |i| {
            const bid_sz = decToF64(bids_bl[i].sz);
            bid_cum += bid_sz;
            bid_levels[i] = .{ .px = bids_bl[i].px, .sz = bid_sz, .cum = bid_cum };

            const ask_sz = decToF64(asks_bl[i].sz);
            ask_cum += ask_sz;
            ask_levels[i] = .{ .px = asks_bl[i].px, .sz = ask_sz, .cum = ask_cum };
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
            var apx_buf: [32]u8 = undefined;
            var asz_buf: [32]u8 = undefined;
            buf.putStr(col_p, y, decFmt(lv.px, &apx_buf), bold_red);
            buf.putStrRight(col_s, y, 10, floatFmt(&asz_buf, lv.sz), white);
            var cb: [16]u8 = undefined;
            buf.putStrRight(col_c, y, 10, floatFmt(&cb, lv.cum), dim);
            if (bar_w > 0 and max_cum > 0) {
                const fw: u16 = @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bar_w)))));
                buf.putBgBar(col_b, y, fw, .{ .bg = .red });
            }
        }

        if (show_depth > 0 and y < h -| 2) {
            const bp = decToF64(bid_levels[0].px);
            const ap = decToF64(ask_levels[0].px);
            const sp = ap - bp;
            const pct = if (bp > 0) sp / bp * 100 else 0;
            var sb: [48]u8 = undefined;
            var spf: [24]u8 = undefined;
            const sp_s = smartFmt(&spf, sp);
            const ss = std.fmt.bufPrint(&sb, "\xe2\x94\x80\xe2\x94\x80 {s} ({d:.3}%) \xe2\x94\x80\xe2\x94\x80", .{ sp_s, pct }) catch "";
            buf.putStr((w -| @as(u16, @intCast(ss.len))) / 2, y, ss, .{ .fg = .yellow, .bold = true });
            y += 1;
        }

        for (0..show_depth) |i| {
            if (y >= h -| 2) break;
            const lv = bid_levels[i];
            var bpx_buf: [32]u8 = undefined;
            var bsz_buf: [32]u8 = undefined;
            buf.putStr(col_p, y, decFmt(lv.px, &bpx_buf), bold_green);
            buf.putStrRight(col_s, y, 10, floatFmt(&bsz_buf, lv.sz), white);
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
        var typed = try client.getSpotMeta();
        defer typed.deinit();
        for (typed.value.universe) |pair| {
            if (std.mem.indexOf(u8, pair.name, "/")) |ns| {
                const n_base = pair.name[0..ns];
                const n_quote = pair.name[ns + 1 ..];
                if (std.ascii.eqlIgnoreCase(n_base, base) and std.ascii.eqlIgnoreCase(n_quote, quote)) {
                    return @intCast(pair.index);
                }
            }
        }
        return error.AssetNotFound;
    }

    if (std.mem.indexOf(u8, coin, ":")) |colon| {
        const dex_name = coin[0..colon];
        const symbol = coin[colon + 1 ..];
        var typed = try client.getPerps(dex_name);
        defer typed.deinit();
        for (typed.value.universe, 0..) |pm, i| {
            if (std.ascii.eqlIgnoreCase(pm.name, symbol)) return i;
            if (std.mem.indexOf(u8, pm.name, ":")) |nc| {
                if (std.ascii.eqlIgnoreCase(pm.name[nc + 1 ..], symbol)) return i;
            }
        }
        return error.AssetNotFound;
    }

    var typed = try client.getPerps(null);
    defer typed.deinit();

    for (typed.value.universe, 0..) |pm, i| {
        if (std.ascii.eqlIgnoreCase(pm.name, coin)) return i;
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
        .mask = std.mem.zeroes(posix.sigset_t),
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

fn decFmt(d: Decimal, buf: []u8) []const u8 {
    return d.normalize().toString(buf) catch "-";
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

    var perps_typed = try client.getPerps(null);
    defer perps_typed.deinit();
    const universe = perps_typed.value.universe;

    // allMids returns {coin: "price"} dict — use raw JSON (dynamic keys)
    var mids_result = try client.allMids(null);
    defer mids_result.deinit();
    const mids_val = try mids_result.json();

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

    for (universe) |pm| {
        if (count >= MAX) break;
        const name = pm.name;
        if (pm.isDelisted) continue; // skip delisted

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

        const p = smartFmt(&row.price_buf, price_f);
        row.price_len = p.len;

        const l = std.fmt.bufPrint(&row.lev_buf, "{d}x", .{pm.maxLeverage}) catch "?";
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

// ── Price ─────────────────────────────────────────────────────

pub fn price(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.PriceArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    // Grab mid price (allMids returns a JSON object {coin: "price", ...})
    var mids_result = try client.allMids(null);
    defer mids_result.deinit();
    const mids_val = try mids_result.json();
    const mid_str = json_mod.getString(mids_val, a.coin);

    // Grab book for bid/ask
    var book_typed = client.getL2Book(a.coin) catch null;
    defer if (book_typed) |*bt| bt.deinit();
    const bl: ?[2][]response.BookLevel = if (book_typed) |bt| bt.value.levels else null;

    if (w.format == .json) {
        var jbuf: [256]u8 = undefined;
        var jlen: usize = 0;
        const jsl = jbuf[0..];
        jlen += (std.fmt.bufPrint(jsl[jlen..], "{{\"coin\":\"{s}\"", .{a.coin}) catch return).len;
        if (mid_str) |m_s| jlen += (std.fmt.bufPrint(jsl[jlen..], ",\"mid\":{s}", .{m_s}) catch return).len;
        if (bl) |levels| {
            if (levels[0].len > 0) { var bb: [32]u8 = undefined; jlen += (std.fmt.bufPrint(jsl[jlen..], ",\"bid\":{s}", .{decFmt(levels[0][0].px, &bb)}) catch return).len; }
            if (levels[1].len > 0) { var ab: [32]u8 = undefined; jlen += (std.fmt.bufPrint(jsl[jlen..], ",\"ask\":{s}", .{decFmt(levels[1][0].px, &ab)}) catch return).len; }
        }
        jlen += (std.fmt.bufPrint(jsl[jlen..], "}}", .{}) catch return).len;
        try w.jsonRaw(jbuf[0..jlen]);
        return;
    }

    if (w.quiet) {
        if (mid_str) |m_s| try w.print("{s}\n", .{m_s});
        return;
    }

    try w.nl();
    if (mid_str) |m_s| {
        try w.style(Style.muted);
        try w.print("  {s: <6}", .{a.coin});
        try w.style(Style.reset);
        try w.styled(Style.bold_white, m_s);
        try w.nl();
    } else {
        try w.err("coin not found");
        return;
    }

    if (bl) |levels| {
        var bid_px_buf: [32]u8 = undefined;
        var bid_sz_buf: [32]u8 = undefined;
        var ask_px_buf: [32]u8 = undefined;
        var ask_sz_buf: [32]u8 = undefined;
        const has_bid = levels[0].len > 0;
        const has_ask = levels[1].len > 0;
        const bid_px: []const u8 = if (has_bid) decFmt(levels[0][0].px, &bid_px_buf) else "-";
        const bid_sz: []const u8 = if (has_bid) decFmt(levels[0][0].sz, &bid_sz_buf) else "-";
        const ask_px: []const u8 = if (has_ask) decFmt(levels[1][0].px, &ask_px_buf) else "-";
        const ask_sz: []const u8 = if (has_ask) decFmt(levels[1][0].sz, &ask_sz_buf) else "-";

        try w.style(Style.muted);
        try w.print("  bid   ", .{});
        try w.styled(Style.bold_green, bid_px);
        try w.style(Style.muted);
        try w.print("  {s: >10}", .{bid_sz});
        try w.style(Style.reset);

        const bid_f = if (has_bid) decToF64(levels[0][0].px) else 0;
        const ask_f = if (has_ask) decToF64(levels[1][0].px) else 0;
        if (bid_f > 0 and ask_f > 0) {
            const spread = ask_f - bid_f;
            const spread_bps = spread / bid_f * 10000.0;
            var sp_buf: [16]u8 = undefined;
            const sp_str = std.fmt.bufPrint(&sp_buf, "  {d:.1}bps", .{spread_bps}) catch "";
            try w.style(Style.muted);
            try w.print("{s}", .{sp_str});
            try w.style(Style.reset);
        }
        try w.nl();

        try w.style(Style.muted);
        try w.print("  ask   ", .{});
        try w.styled(Style.bold_red, ask_px);
        try w.style(Style.muted);
        try w.print("  {s: >10}", .{ask_sz});
        try w.style(Style.reset);
        try w.nl();
        try w.nl();
    }
}

// ── Leverage ──────────────────────────────────────────────────

pub fn setLeverage(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.LeverageArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const asset = try resolveAsset(allocator, &client, a.coin);

    // If no leverage value, just show current leverage info
    if (a.leverage == null) {
        const addr = config.getAddress() orelse {
            try w.err("address required (--address or config)");
            return;
        };
        if (w.format == .json) {
            var result = try client.activeAssetData(addr, a.coin);
            defer result.deinit();
            try w.jsonRaw(result.body);
            return;
        }

        var typed = try client.getActiveAssetData(addr, a.coin);
        defer typed.deinit();
        const aad = typed.value;

        try w.styled(output_mod.Style.bold, a.coin);
        try w.print(" leverage\n", .{});

        {
            if (aad.leverage) |lev| {
                try w.print("  current   {d}x", .{lev.value});
                try w.print(" {s}", .{lev.type});
                try w.print("\n", .{});
                if (lev.rawVal) |r|
                    try w.print("  raw USD   {s}\n", .{r});
            }
            if (aad.markPx) |px| {
                var px_buf: [32]u8 = undefined;
                try w.print("  mark      {s}\n", .{decFmt(px, &px_buf)});
            }
            if (aad.maxTradeSzs) |mts| {
                var lb: [32]u8 = undefined;
                var sb: [32]u8 = undefined;
                try w.print("  max sz    {s} / {s}\n", .{ decFmt(mts[0], &lb), decFmt(mts[1], &sb) });
            }
            if (aad.availableToTrade) |avail| {
                var alb: [32]u8 = undefined;
                var asb: [32]u8 = undefined;
                try w.print("  avail     {s} / {s}\n", .{ decFmt(avail[0], &alb), decFmt(avail[1], &asb) });
            }
        }
        return;
    }

    // Set leverage
    const signer = try config.getSigner();
    const lev = std.fmt.parseInt(u32, a.leverage.?, 10) catch return error.InvalidFlag;
    const nonce: u64 = @intCast(std.time.milliTimestamp());

    const ul = types.UpdateLeverage{
        .asset = asset,
        .is_cross = a.cross,
        .leverage = lev,
    };
    var result = try client.updateLeverage(signer, ul, nonce, null, null);
    defer result.deinit();

    if (try result.isOk()) {
        if (w.format == .json) {
            try w.jsonFmt("{{\"coin\":\"{s}\",\"leverage\":{d},\"mode\":\"{s}\"}}", .{
                a.coin, lev, if (a.cross) "cross" else "isolated",
            });
        } else {
            try w.print("{s} leverage set to {d}x ({s})\n", .{
                a.coin, lev, if (a.cross) "cross" else "isolated",
            });
        }
    } else {
        try w.errFmt("failed: {s}", .{result.body});
    }
}

// ── Portfolio ─────────────────────────────────────────────────

pub fn portfolio(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.UserQuery) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const addr = a.address orelse config.getAddress() orelse return error.MissingAddress;

    if (w.format == .json) {
        var perp_result = try client.clearinghouseState(addr, a.dex);
        defer perp_result.deinit();
        var spot_result = try client.spotClearinghouseState(addr);
        defer spot_result.deinit();
        var combo_buf: [16384]u8 = undefined;
        const combo = std.fmt.bufPrint(&combo_buf, "{{\"perp\":{s},\"spot\":{s}}}", .{ perp_result.body, spot_result.body }) catch return;
        try w.jsonRaw(combo);
        return;
    }

    var perp_typed = try client.getClearinghouseState(addr, a.dex);
    defer perp_typed.deinit();
    const state = perp_typed.value;
    const ms = state.marginSummary;

    {
        try w.nl();
        try w.styled(Style.muted, "  PORTFOLIO\n\n");
        var av_buf: [32]u8 = undefined;
        try w.print("  ", .{});
        try w.styled(Style.bold_white, "$");
        try w.styled(Style.bold_white, decFmt(ms.accountValue, &av_buf));
        try w.nl();
        try w.nl();

        try w.style(Style.subtle);
        try w.print("  ", .{});
        var i: usize = 0;
        while (i < 52) : (i += 1) try w.print("\xe2\x94\x80", .{});
        try w.style(Style.reset);
        try w.nl();
        var mu_buf: [32]u8 = undefined;
        var wd_buf: [32]u8 = undefined;
        try w.style(Style.muted);
        try w.print("  margin ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(ms.totalMarginUsed, &mu_buf));
        try w.style(Style.muted);
        try w.print("  free ", .{});
        try w.style(Style.reset);
        try w.styled(Style.white, decFmt(state.withdrawable, &wd_buf));

        const av_f2 = decToF64(ms.accountValue);
        const mu_f2 = decToF64(ms.totalMarginUsed);
        const health = if (mu_f2 > 0 and av_f2 > 0) @max(0.0, @min(100.0, 100.0 - (mu_f2 / av_f2 * 100.0))) else 100.0;
        const hc: []const u8 = if (health > 50) Style.bold_green else if (health > 25) Style.bold_yellow else Style.bold_red;
        try w.style(Style.muted);
        try w.print("  health ", .{});
        try w.style(Style.reset);
        try w.bar(health, 100.0, 8, hc);
        var hbuf: [8]u8 = undefined;
        const hstr = std.fmt.bufPrint(&hbuf, " {d:.0}%", .{health}) catch "?";
        try w.styled(hc, hstr);
        try w.nl();
        try w.nl();
    }

    try printPositions(w, state.assetPositions, null);

    // HIP-3 DEX positions (--all-dexes)
    if (a.all_dexes) {
        var dex_typed = client.getPerpDexs() catch null;
        if (dex_typed) |*dt| {
            defer dt.deinit();
            for (dt.value) |dex| {
                var dex_state = client.getClearinghouseState(addr, dex.name) catch continue;
                defer dex_state.deinit();
                try printPositions(w, dex_state.value.assetPositions, dex.name);
            }
        }
    }

    // Spot balances with proportion bars
    var spot_typed = client.getSpotBalances(addr) catch null;
    defer if (spot_typed) |*st| st.deinit();
    if (spot_typed) |st| {
        var max_bal: f64 = 0;
        var nz_count: usize = 0;
        for (st.value.balances) |b| {
            const tf = decToF64(b.total);
            if (tf == 0) continue;
            max_bal = @max(max_bal, tf);
            nz_count += 1;
        }
        if (nz_count > 0) {
            try w.heading("SPOT");
            const hdr = [_]Column{
                .{ .text = "TOKEN", .width = 8 },
                .{ .text = "BALANCE", .width = 16, .align_right = true },
                .{ .text = "", .width = 20 },
            };
            try w.tableHeader(&hdr);
            try w.panelSep();

            for (st.value.balances) |b| {
                const total_f = decToF64(b.total);
                if (total_f == 0) continue;
                var fmt_buf: [32]u8 = undefined;
                const formatted = smartFmt(&fmt_buf, total_f);
                try emitSpotRow(w, b.coin, formatted, total_f, max_bal);
            }
            try w.footer();
        }
    }
}

fn printPositions(w: *Writer, asset_positions: []const response.AssetPosition, dex_name: ?[]const u8) !void {
    {
        var title_buf: [64]u8 = undefined;
        const title = if (dex_name) |dn|
            std.fmt.bufPrint(&title_buf, "POSITIONS \xc2\xb7 {s}", .{dn}) catch "POSITIONS"
        else
            "POSITIONS";
        try w.heading(title);

        const hdr = [_]Column{
            .{ .text = "COIN", .width = 8 },
            .{ .text = "SIDE", .width = 6 },
            .{ .text = "SIZE", .width = 12, .align_right = true },
            .{ .text = "ENTRY", .width = 10, .align_right = true },
            .{ .text = "PNL", .width = 14, .align_right = true },
        };
        try w.tableHeader(&hdr);

        var has_any = false;
        for (asset_positions) |ap| {
            const p = ap.position;
            const szi_f = decToF64(p.szi);
            if (szi_f == 0) continue;
            has_any = true;
            var szi_buf: [32]u8 = undefined;
            var entry_buf: [32]u8 = undefined;
            var pnl_buf: [32]u8 = undefined;
            const side_s: []const u8 = if (szi_f > 0) "LONG" else "SHORT";
            const side_c: []const u8 = if (szi_f > 0) Style.green else Style.red;
            var abs_buf: [32]u8 = undefined;
            const abs_s = std.fmt.bufPrint(&abs_buf, "{d}", .{@abs(szi_f)}) catch decFmt(p.szi, &szi_buf);
            const entry_s = if (p.entryPx) |ep| decFmt(ep, &entry_buf) else "-";
            const pnl_s = if (p.unrealizedPnl) |up| decFmt(up, &pnl_buf) else "-";
            const pnl_f = if (p.unrealizedPnl) |up| decToF64(up) else 0;
            const pnl_c: []const u8 = if (pnl_f > 0) Style.bold_green else if (pnl_f < 0) Style.bold_red else Style.muted;

            const cols = [_]Column{
                .{ .text = p.coin, .width = 8, .color = Style.bold_cyan },
                .{ .text = side_s, .width = 6, .color = side_c },
                .{ .text = abs_s, .width = 12, .align_right = true },
                .{ .text = entry_s, .width = 10, .align_right = true, .color = Style.muted },
                .{ .text = pnl_s, .width = 14, .align_right = true, .color = pnl_c },
            };
            try w.tableRow(&cols);
        }
        if (!has_any) {
            try w.style(Style.muted);
            try w.print("  (none)\n", .{});
            try w.style(Style.reset);
        }
        try w.nl();
    }
}

// ── Referral ──────────────────────────────────────────────────

pub fn referralCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.ReferralArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    switch (a.action) {
        .status => {
            const addr = config.getAddress() orelse return error.MissingAddress;
            if (w.format == .json) {
                var result = try client.referral(addr);
                defer result.deinit();
                try w.jsonRaw(result.body);
                return;
            }

            var typed = try client.getReferral(addr);
            defer typed.deinit();
            const ref = typed.value;
            if (ref.referredBy) |r|
                try w.print("referred by   {s}\n", .{r})
            else
                try w.print("referred by   (none)\n", .{});
            if (ref.cumVlm) |v| { var b: [32]u8 = undefined; try w.print("referral vol  ${s}\n", .{decFmt(v, &b)}); }
            if (ref.unclaimedRewards) |v| { var b: [32]u8 = undefined; try w.print("unclaimed     ${s}\n", .{decFmt(v, &b)}); }
            if (ref.claimedRewards) |v| { var b: [32]u8 = undefined; try w.print("claimed       ${s}\n", .{decFmt(v, &b)}); }
        },
        .set => {
            const code = a.code orelse {
                try w.err("usage: hl referral set <CODE>");
                return;
            };
            const signer = try config.getSigner();
            const nonce: u64 = @intCast(std.time.milliTimestamp());
            var result = try client.setReferrer(signer, .{ .code = code }, nonce, null, null);
            defer result.deinit();

            if (try result.isOk()) {
                if (w.format == .json) {
                    try w.jsonFmt("{{\"status\":\"ok\",\"code\":\"{s}\"}}", .{code});
                } else {
                    try w.print("referral code set: {s}\n", .{code});
                }
            } else {
                try w.errFmt("failed: {s}", .{result.body});
            }
        },
    }
}

// ── TWAP ──────────────────────────────────────────────────

pub fn twap(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.TwapArgs) !void {
    var client = makeClient(allocator, config);
    defer client.deinit();

    const signer = try config.getSigner();
    const asset = try resolveAsset(allocator, &client, a.coin);
    const total_sz = std.fmt.parseFloat(f64, a.size) catch return error.Overflow;
    const is_buy = std.mem.eql(u8, a.side, "buy") or std.mem.eql(u8, a.side, "long");
    const duration_ms = parseDuration(a.duration) orelse return error.InvalidFlag;
    const slices = @max(a.slices, 1);
    const slice_sz = total_sz / @as(f64, @floatFromInt(slices));
    const interval_ms: u64 = duration_ms / @as(u64, @intCast(slices));

    if (w.format != .json) {
        try w.print("TWAP: {s} {s} {s} over {s} in {d} slices\n", .{
            a.side, a.size, a.coin, a.duration, slices,
        });
        try w.print("  slice size: ", .{});
        var sb: [24]u8 = undefined;
        try w.print("{s}  interval: {d}s\n\n", .{ smartFmt(&sb, slice_sz), interval_ms / 1000 });
    }

    var filled: f64 = 0;
    var total_cost: f64 = 0;

    for (0..slices) |i| {
        // Fetch BBO for slippage price
        var book_result = client.l2Book(a.coin) catch {
            if (w.format == .json) {
                try w.jsonFmt("{{\"event\":\"error\",\"slice\":{d},\"error\":\"book_fetch_failed\"}}", .{i + 1});
            } else {
                try w.errFmt("slice {d}: failed to fetch book", .{i + 1});
            }
            continue;
        };
        defer book_result.deinit();
        var book_typed = std.json.parseFromSlice(response.L2Book, allocator, book_result.body, response.ParseOpts) catch continue;
        defer book_typed.deinit();

        // Get best price + apply slippage
        const slippage_mult: f64 = if (is_buy) 1.0 + a.slippage_pct / 100.0 else 1.0 - a.slippage_pct / 100.0;
        const best_px = getBestPrice(book_typed.value.levels, is_buy) orelse continue;
        const slip_px = best_px * slippage_mult;

        var px_buf: [32]u8 = undefined;
        const px_str = slippageFmt(&px_buf, slip_px);
        const limit_px = Decimal.fromString(px_str) catch continue;

        var sz_buf: [32]u8 = undefined;
        const sz_str = smartFmt(&sz_buf, slice_sz);
        const sz_dec = Decimal.fromString(sz_str) catch continue;

        const order = types.OrderRequest{
            .asset = asset,
            .is_buy = is_buy,
            .limit_px = limit_px,
            .sz = sz_dec,
            .reduce_only = false,
            .order_type = .{ .limit = .{ .tif = .FrontendMarket } },
            .cloid = makeCloid(),
        };
        const batch_order = types.BatchOrder{
            .orders = &[_]types.OrderRequest{order},
            .grouping = .na,
        };

        var nonce_handler = response.NonceHandler.init();
        const nonce = nonce_handler.next();

        var result = client.place(signer, batch_order, nonce, null, null) catch |e| {
            if (w.format == .json) {
                try w.jsonFmt("{{\"event\":\"error\",\"slice\":{d},\"error\":\"{s}\"}}", .{ i + 1, @errorName(e) });
            } else {
                try w.errFmt("slice {d}: {s}", .{ i + 1, @errorName(e) });
            }
            continue;
        };
        defer result.deinit();

        const val = result.json() catch continue;
        const statuses = response.parseOrderStatuses(allocator, val) catch continue;
        defer allocator.free(statuses);

        var slice_px: f64 = 0;
        var slice_filled: f64 = 0;
        if (statuses.len > 0) {
            switch (statuses[0]) {
                .filled => |f| {
                    slice_filled = slice_sz;
                    slice_px = std.fmt.parseFloat(f64, decStr(f.avgPx, &px_buf)) catch best_px;
                },
                .resting => {
                    slice_filled = slice_sz;
                    slice_px = best_px;
                },
                else => {},
            }
        }

        filled += slice_filled;
        total_cost += slice_filled * slice_px;

        if (w.format == .json) {
            var avg_buf: [24]u8 = undefined;
            try w.jsonFmt("{{\"event\":\"slice\",\"n\":{d},\"filled\":\"{s}\",\"price\":\"{s}\",\"total_filled\":\"{s}\"}}", .{
                i + 1, smartFmt(&sz_buf, slice_filled), smartFmt(&px_buf, slice_px), smartFmt(&avg_buf, filled),
            });
        } else {
            try w.print("  [{d}/{d}] filled {s} @ {s}  (total: {s})\n", .{
                i + 1, slices, smartFmt(&sz_buf, slice_filled), smartFmt(&px_buf, slice_px),
                smartFmt(&px_buf, filled),
            });
        }

        // Sleep between slices (except after last)
        if (i + 1 < slices) {
            std.Thread.sleep(interval_ms * std.time.ns_per_ms);
        }
    }

    // Summary
    const avg_px = if (filled > 0) total_cost / filled else 0;
    if (w.format == .json) {
        var fb: [24]u8 = undefined;
        var ab: [24]u8 = undefined;
        try w.jsonFmt("{{\"event\":\"done\",\"total_filled\":\"{s}\",\"avg_price\":\"{s}\",\"slices\":{d}}}", .{
            smartFmt(&fb, filled), smartFmt(&ab, avg_px), slices,
        });
    } else {
        var fb: [24]u8 = undefined;
        var ab: [24]u8 = undefined;
        try w.print("\ndone: filled {s} @ avg {s}\n", .{ smartFmt(&fb, filled), smartFmt(&ab, avg_px) });
    }
}

fn getBestPrice(book_levels: [2][]response.BookLevel, is_buy: bool) ?f64 {
    const side_idx: usize = if (is_buy) 1 else 0; // asks for buy, bids for sell
    const side = book_levels[side_idx];
    if (side.len == 0) return null;
    return decToF64(side[0].px);
}

fn parseDuration(s: []const u8) ?u64 {
    if (s.len < 2) return null;
    const unit = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return switch (unit) {
        's' => num * 1000,
        'm' => num * 60 * 1000,
        'h' => num * 3600 * 1000,
        'd' => num * 86400 * 1000,
        else => null,
    };
}

fn makeCloid() types.Cloid {
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
    return cloid;
}

// ── Batch ─────────────────────────────────────────────────

pub fn batchCmd(allocator: std.mem.Allocator, w: *Writer, config: Config, a: args_mod.BatchArgs) !void {
    // --stdin: read order strings from stdin (one per line or JSON array)
    var stdin_storage: [4096]u8 = undefined;
    var stdin_len: usize = 0;
    var effective = a;

    if (a.stdin) {
        stdin_len = std.fs.File.stdin().readAll(&stdin_storage) catch 0;
        if (stdin_len > 0) {
            const input = std.mem.trim(u8, stdin_storage[0..stdin_len], " \t\r\n");
            if (input.len > 0 and input[0] == '[') {
                // JSON array — parse, then copy strings into stdin_storage tail
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
                    try w.err("invalid JSON on stdin");
                    return;
                };
                // Copy strings into rest of stdin_storage so they outlive parsed
                var pos: usize = stdin_len;
                if (parsed.value == .array) {
                    for (parsed.value.array.items) |item| {
                        if (item == .string and effective.count < 16) {
                            const s = item.string;
                            if (pos + s.len <= stdin_storage.len) {
                                @memcpy(stdin_storage[pos..][0..s.len], s);
                                effective.orders[effective.count] = stdin_storage[pos..][0..s.len];
                                effective.count += 1;
                                pos += s.len;
                            }
                        }
                    }
                }
                parsed.deinit();
            } else {
                // Plain text: one order per line (slices into stdin_storage, stable)
                var it = std.mem.splitScalar(u8, input, '\n');
                while (it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len > 0 and effective.count < 16) {
                        effective.orders[effective.count] = trimmed;
                        effective.count += 1;
                    }
                }
            }
        }
    }

    if (effective.count == 0) {
        try w.err("no orders. Usage: hl batch \"buy BTC 0.1 @98000\" or echo orders | hl batch --stdin");
        return;
    }
    const ba = effective;

    var client = makeClient(allocator, config);
    defer client.deinit();
    const signer = try config.getSigner();

    // Parse each order string into OrderRequest
    var batch_items: [16]types.OrderRequest = undefined;
    var order_count: usize = 0;

    for (0..ba.count) |i| {
        const order_str = ba.orders[i] orelse continue;
        // Tokenize the order string (space-separated)
        var tokens: [8][]const u8 = undefined;
        var token_count: usize = 0;
        var it = std.mem.splitScalar(u8, order_str, ' ');
        while (it.next()) |tok| {
            if (tok.len > 0 and token_count < 8) {
                tokens[token_count] = tok;
                token_count += 1;
            }
        }
        if (token_count < 3) {
            try w.errFmt("order {d}: need at least 'side coin size' (got {d} tokens)", .{ i + 1, token_count });
            continue;
        }

        const side_str = tokens[0];
        const coin = tokens[1];
        const size_str = tokens[2];
        const is_buy = std.mem.eql(u8, side_str, "buy") or std.mem.eql(u8, side_str, "long");

        const asset_idx = resolveAsset(allocator, &client, coin) catch {
            try w.errFmt("order {d}: unknown asset {s}", .{ i + 1, coin });
            continue;
        };

        const sz = Decimal.fromString(size_str) catch {
            try w.errFmt("order {d}: invalid size {s}", .{ i + 1, size_str });
            continue;
        };

        // Check for price (@PX or 4th positional)
        var limit_px: Decimal = undefined;
        var order_type: types.OrderTypePlacement = .{ .limit = .{ .tif = .FrontendMarket } };
        var found_price = false;

        for (tokens[3..token_count]) |tok| {
            if (tok.len > 0 and tok[0] == '@') {
                limit_px = Decimal.fromString(tok[1..]) catch continue;
                order_type = .{ .limit = .{ .tif = .Gtc } };
                found_price = true;
                break;
            }
        }

        if (!found_price) {
            // Market order — get BBO
            var book_typed = client.getL2Book(coin) catch continue;
            defer book_typed.deinit();
            const best = getBestPrice(book_typed.value.levels, is_buy) orelse continue;
            const slip = if (is_buy) best * 1.01 else best * 0.99;
            var sb: [32]u8 = undefined;
            limit_px = Decimal.fromString(slippageFmt(&sb, slip)) catch continue;
        }

        batch_items[order_count] = .{
            .asset = asset_idx,
            .is_buy = is_buy,
            .limit_px = limit_px,
            .sz = sz,
            .reduce_only = false,
            .order_type = order_type,
            .cloid = makeCloid(),
        };
        order_count += 1;
    }

    if (order_count == 0) {
        try w.err("no valid orders to submit");
        return;
    }

    const batch_order = types.BatchOrder{
        .orders = batch_items[0..order_count],
        .grouping = .na,
    };

    var nonce_handler = response.NonceHandler.init();
    const nonce = nonce_handler.next();

    var result = try client.place(signer, batch_order, nonce, null, null);
    defer result.deinit();

    if (w.format == .json) {
        try w.jsonRaw(result.body);
        return;
    }

    const val = try result.json();
    const statuses = try response.parseOrderStatuses(allocator, val);
    defer allocator.free(statuses);

    for (statuses, 0..) |s, idx| {
        switch (s) {
            .resting => |r| {
                var ob: [20]u8 = undefined;
                try w.print("  [{d}] resting (oid: {s})\n", .{ idx + 1, std.fmt.bufPrint(&ob, "{d}", .{r.oid}) catch "?" });
            },
            .filled => |f| {
                var ab: [32]u8 = undefined;
                try w.print("  [{d}] filled @ {s}\n", .{ idx + 1, decStr(f.avgPx, &ab) });
            },
            .success => try w.print("  [{d}] accepted\n", .{idx + 1}),
            .@"error" => |msg| try w.print("  [{d}] error: {s}\n", .{ idx + 1, msg }),
            .unknown => try w.print("  [{d}] unknown\n", .{idx + 1}),
        }
    }

    if (statuses.len == 0) {
        const status = response.parseResponseStatus(val);
        switch (status) {
            .ok => try w.success("Batch submitted"),
            .err => {
                const err_msg = json_mod.getString(val, "response") orelse "unknown error";
                try w.errFmt("rejected: {s}", .{err_msg});
            },
            .unknown => try w.err("unknown response"),
        }
    }
}
