//! `hl` — Hyperliquid CLI.

const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const output_mod = @import("output.zig");
const commands = @import("commands.zig");

const Style = output_mod.Style;
const VERSION = "0.2.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = args_mod.parse(allocator) catch |e| {
        var w = output_mod.Writer.init(.pretty);
        switch (e) {
            error.MissingArgument => try w.err("missing required argument. Run `hl help` for usage."),
            error.UnknownCommand => try w.err("unknown command. Run `hl help` for usage."),
            error.InvalidFlag => try w.err("invalid flag value. Run `hl help` for usage."),
        }
        std.process.exit(1);
    };

    const flags = result.flags;
    var w = output_mod.Writer.initAuto(flags.output, flags.output_explicit);
    var config = config_mod.load(allocator, flags);
    defer config.deinit();

    const cmd = result.command orelse {
        try printHelp(&w);
        return;
    };

    switch (cmd) {
        .help => try printHelp(&w),
        .version => try printVersion(&w),
        .config => try commands.showConfig(&w, config),
        .mids => |a| commands.mids(allocator, &w, config, a) catch |e| return fail(&w, "mids", e),
        .positions => |a| commands.positions(allocator, &w, config, a) catch |e| return fail(&w, "positions", e),
        .orders => |a| commands.orders(allocator, &w, config, a) catch |e| return fail(&w, "orders", e),
        .fills => |a| commands.fills(allocator, &w, config, a) catch |e| return fail(&w, "fills", e),
        .balance => |a| commands.balance(allocator, &w, config, a) catch |e| return fail(&w, "balance", e),
        .perps => |a| commands.perps(allocator, &w, config, a) catch |e| return fail(&w, "perps", e),
        .spot => |a| commands.spotMarkets(allocator, &w, config, a) catch |e| return fail(&w, "spot", e),
        .dexes => commands.dexes(allocator, &w, config) catch |e| return fail(&w, "dexes", e),
        .buy => |a| commands.placeOrder(allocator, &w, config, a, true) catch |e| return fail(&w, "buy", e),
        .sell => |a| commands.placeOrder(allocator, &w, config, a, false) catch |e| return fail(&w, "sell", e),
        .cancel => |a| commands.cancelOrder(allocator, &w, config, a) catch |e| return fail(&w, "cancel", e),
        .modify => |a| commands.modifyOrder(allocator, &w, config, a) catch |e| return fail(&w, "modify", e),
        .send => |a| commands.sendAsset(allocator, &w, config, a) catch |e| return fail(&w, "send", e),
        .stream => |a| commands.stream(allocator, &w, config, a) catch |e| return fail(&w, "stream", e),
        .status => |a| commands.orderStatus(allocator, &w, config, a) catch |e| return fail(&w, "status", e),
        .funding => |a| commands.funding(allocator, &w, config, a) catch |e| return fail(&w, "funding", e),
        .book => |a| commands.book(allocator, &w, config, a) catch |e| return fail(&w, "book", e),
        .markets => commands.markets(allocator, config) catch |e| return fail(&w, "markets", e),
    }
}

fn fail(w: *output_mod.Writer, cmd: []const u8, e: anyerror) void {
    w.errFmt("{s}: {s}", .{ cmd, @errorName(e) }) catch {};
    std.process.exit(1);
}

fn printVersion(w: *output_mod.Writer) !void {
    try w.print("hl {s}\n", .{VERSION});
}

fn printHelp(w: *output_mod.Writer) !void {
    try w.styled(Style.bold_cyan,
        \\
        \\  ╦ ╦╦  
        \\  ╠═╣║  
        \\  ╩ ╩╩═╝
        \\
    );
    try w.print("  Hyperliquid CLI v{s}\n\n", .{VERSION});
    try w.styled(Style.bold, "USAGE\n");
    try w.print("  hl <command> [args] [flags]\n\n", .{});

    try w.styled(Style.bold, "MARKET DATA\n");
    try w.print("  hl markets                  Interactive market browser (TUI)\n", .{});
    try w.print("  hl mids [COIN]              Mid prices (top 20, --all)\n", .{});
    try w.print("  hl funding [--top N] [--all] Funding rates with heat bars\n", .{});
    try w.print("  hl book <COIN> [--live]     Order book depth\n", .{});
    try w.print("  hl perps [--dex xyz] [--all] Perpetual markets\n", .{});
    try w.print("  hl spot [--all]             Spot markets\n", .{});
    try w.print("  hl dexes                    HIP-3 DEXes\n\n", .{});

    try w.styled(Style.bold, "STREAMING\n");
    try w.print("  hl stream trades <COIN>     Real-time trades\n", .{});
    try w.print("  hl stream bbo <COIN>        Best bid/offer\n", .{});
    try w.print("  hl stream book <COIN>       L2 orderbook updates\n", .{});
    try w.print("  hl stream candles <COIN>    OHLCV candles (--interval 1m)\n", .{});
    try w.print("  hl stream mids              All mid prices\n", .{});
    try w.print("  hl stream fills <ADDR>      User fills\n", .{});
    try w.print("  hl stream orders <ADDR>     Order status updates\n\n", .{});

    try w.styled(Style.bold, "ACCOUNT\n");
    try w.print("  hl positions [ADDR]         Open positions\n", .{});
    try w.print("  hl orders [ADDR]            Open orders\n", .{});
    try w.print("  hl fills [ADDR]             Recent fills\n", .{});
    try w.print("  hl balance [ADDR]           Spot + perp balances\n", .{});
    try w.print("  hl status <OID>             Order status\n\n", .{});

    try w.styled(Style.bold, "TRADING\n");
    try w.print("  hl buy <COIN> <SZ> [@PX]    Limit buy (@PX) or market\n", .{});
    try w.print("  hl sell <COIN> <SZ> [@PX]   Limit sell (@PX) or market\n", .{});
    try w.print("  hl modify <COIN> <OID> <SZ> <PX>  Modify existing order\n", .{});
    try w.print("  hl cancel <COIN> <OID>      Cancel by OID\n", .{});
    try w.print("  hl cancel <COIN> --cloid <HEX>  Cancel by CLOID\n", .{});
    try w.print("  hl cancel --all             Cancel all orders\n\n", .{});

    try w.styled(Style.bold, "TRANSFERS\n");
    try w.print("  hl send <AMT> [TOKEN] <DEST>      Send to address\n", .{});
    try w.print("  hl send <AMT> USDC --to spot      Perp → spot (self)\n", .{});
    try w.print("  hl send <AMT> USDC --from spot --to xyz  Spot → DEX\n", .{});
    try w.print("  hl send <AMT> HYPE --subaccount alice --to <DEST>\n\n", .{});

    try w.styled(Style.bold, "FLAGS\n");
    try w.print("  --chain <mainnet|testnet>   Target chain\n", .{});
    try w.print("  --output <pretty|json|csv>  Output format\n", .{});
    try w.print("  --json                      Shorthand for --output json\n", .{});
    try w.print("  --key <HEX>                 Private key\n", .{});
    try w.print("  --address <ADDR>            User address\n\n", .{});

    try w.styled(Style.dim, "  Config: .env, ~/.hl/config, or env vars (HL_KEY, HL_ADDRESS)\n");
    try w.styled(Style.dim, "  Pipe-aware: auto-outputs JSON when stdout is not a TTY\n");
    try w.styled(Style.dim, "  Asset formats: BTC (perp), PURR/USDC (spot), xyz:BTC (HIP-3)\n\n");
}
