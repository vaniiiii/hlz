//! `hlz` — Hyperliquid CLI.

const std = @import("std");

const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const output_mod = @import("output.zig");
const commands = @import("commands.zig");
const trade_mod = @import("trade");

const Style = output_mod.Style;
const VERSION = "0.4.6";

// Exit codes (documented in --help, stable contract)
const EXIT_OK: u8 = 0;
const EXIT_ERROR: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_AUTH: u8 = 3;
const EXIT_NETWORK: u8 = 4;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = args_mod.parse(allocator) catch |e| {
        var w = output_mod.Writer.init(.pretty);
        switch (e) {
            error.MissingArgument => try w.err("missing required argument. Run `hlz help` for usage."),
            error.UnknownCommand => try w.err("unknown command. Run `hlz help` for usage."),
            error.InvalidFlag => try w.err("invalid flag value. Run `hlz help` for usage."),
        }
        std.process.exit(EXIT_USAGE);
    };

    const flags = result.flags;

    // Apply HL_OUTPUT env var override
    var effective_output = flags.output;
    var effective_explicit = flags.output_explicit;

    var config = config_mod.load(allocator, flags);
    defer config.deinit();

    if (config.output_override) |ov| {
        effective_output = ov;
        effective_explicit = true;
    }

    var w = output_mod.Writer.initAuto(effective_output, effective_explicit);
    w.quiet = flags.quiet;

    const cmd = result.command orelse {
        try printHelp(&w);
        return;
    };

    const cmd_name: []const u8 = switch (cmd) {
        .approve_agent => "approve-agent",
        else => @tagName(cmd),
    };
    if (w.format == .json) {
        w.cmd = cmd_name;
        w.start_ns = std.time.nanoTimestamp();
    }

    switch (cmd) {
        .help => try printHelp(&w),
        .version => try printVersion(&w),
        .config => try commands.showConfig(&w, config),
        .keys => |a| commands.keys(allocator, &w, a) catch |e| return exit(&w, "keys", e),
        .approve_agent => |a| commands.approveAgent(allocator, &w, config, a) catch |e| return exit(&w, "approve-agent", e),
        .mids => |a| commands.mids(allocator, &w, config, a) catch |e| return exit(&w, "mids", e),
        .positions => |a| commands.positions(allocator, &w, config, a) catch |e| return exit(&w, "positions", e),
        .orders => |a| commands.orders(allocator, &w, config, a) catch |e| return exit(&w, "orders", e),
        .fills => |a| commands.fills(allocator, &w, config, a) catch |e| return exit(&w, "fills", e),
        .balance => |a| commands.balance(allocator, &w, config, a) catch |e| return exit(&w, "balance", e),
        .perps => |a| commands.perps(allocator, &w, config, a) catch |e| return exit(&w, "perps", e),
        .spot => |a| commands.spotMarkets(allocator, &w, config, a) catch |e| return exit(&w, "spot", e),
        .dexes => commands.dexes(allocator, &w, config) catch |e| return exit(&w, "dexes", e),
        .buy => |a| commands.placeOrder(allocator, &w, config, a, true) catch |e| return exit(&w, "buy", e),
        .sell => |a| commands.placeOrder(allocator, &w, config, a, false) catch |e| return exit(&w, "sell", e),
        .cancel => |a| commands.cancelOrder(allocator, &w, config, a) catch |e| return exit(&w, "cancel", e),
        .modify => |a| commands.modifyOrder(allocator, &w, config, a) catch |e| return exit(&w, "modify", e),
        .send => |a| commands.sendAsset(allocator, &w, config, a) catch |e| return exit(&w, "send", e),
        .stream => |a| commands.stream(allocator, &w, config, a) catch |e| return exit(&w, "stream", e),
        .status => |a| commands.orderStatus(allocator, &w, config, a) catch |e| return exit(&w, "status", e),
        .funding => |a| commands.funding(allocator, &w, config, a) catch |e| return exit(&w, "funding", e),
        .book => |a| commands.book(allocator, &w, config, a) catch |e| return exit(&w, "book", e),
        .markets => commands.markets(allocator, config) catch |e| return exit(&w, "markets", e),
        .leverage => |a| commands.setLeverage(allocator, &w, config, a) catch |e| return exit(&w, "leverage", e),
        .price => |a| commands.price(allocator, &w, config, a) catch |e| return exit(&w, "price", e),
        .portfolio => |a| commands.portfolio(allocator, &w, config, a) catch |e| return exit(&w, "portfolio", e),
        .referral => |a| commands.referralCmd(allocator, &w, config, a) catch |e| return exit(&w, "referral", e),
        .twap => |a| commands.twap(allocator, &w, config, a) catch |e| return exit(&w, "twap", e),
        .batch => |a| commands.batchCmd(allocator, &w, config, a) catch |e| return exit(&w, "batch", e),
        .trade => |a| trade_mod.run(allocator, .{
            .chain = config.chain,
            .key_hex = config.key_hex,
            .address = config.getAddress(),
        }, a.coin) catch |e| return exit(&w, "trade", e),
    }
}

fn exit(w: *output_mod.Writer, cmd: []const u8, e: anyerror) void {
    const code: u8 = switch (e) {
        error.MissingKey, error.MissingAddress => EXIT_AUTH,
        error.MissingArgument, error.InvalidFlag => EXIT_USAGE,
        error.ConnectionRefused, error.ConnectionResetByPeer, error.BrokenPipe, error.NetworkUnreachable => EXIT_NETWORK,
        else => EXIT_ERROR,
    };

    if (w.format == .json) {
        var buf: [2048]u8 = undefined;
        const name = @errorName(e);
        const retryable = switch (e) {
            error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable => true,
            else => false,
        };
        const hint = switch (e) {
            error.MissingKey => "set HL_KEY env var or pass --key",
            error.MissingAddress => "set HL_ADDRESS env var or pass --address",
            error.MissingArgument => "run `hlz help` for usage",
            error.AssetNotFound => "check coin name: BTC (perp), PURR/USDC (spot), xyz:BTC (dex)",
            error.CommandFailed => "",
            error.InvalidFlag => "check flag values",
            else => "",
        };
        var msg_buf: [1536]u8 = undefined;
        const msg = jsonEscape(w.exitMessage() orelse "", &msg_buf);
        const ms = w.elapsedMs();
        const s = std.fmt.bufPrint(&buf,
            \\{{"v":1,"status":"error","cmd":"{s}","error":"{s}","message":"{s}","retryable":{s},"hint":"{s}","timing_ms":{d}}}
        , .{ cmd, name, msg, if (retryable) "true" else "false", hint, ms }) catch return;
        w.rawJson(s) catch {};
    } else if (e != error.CommandFailed) {
        w.errFmt("{s}: {s}", .{ cmd, @errorName(e) }) catch {};
    }

    std.process.exit(code);
}

fn jsonEscape(input: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            0x08 => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'b';
                i += 2;
            },
            0x09 => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            '"' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            0x0c => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'f';
                i += 2;
            },
            '\r' => {
                if (i + 2 > buf.len) break;
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    if (i + 6 > buf.len) break;
                    _ = std.fmt.bufPrint(buf[i .. i + 6], "\\u00{x:0>2}", .{c}) catch break;
                    i += 6;
                } else {
                    if (i >= buf.len) break;
                    buf[i] = c;
                    i += 1;
                }
            },
        }
    }
    return buf[0..i];
}

fn printVersion(w: *output_mod.Writer) !void {
    if (w.format == .json) {
        try w.jsonRaw("{\"version\":\"" ++ VERSION ++ "\"}");
    } else {
        try w.print("hlz {s}\n", .{VERSION});
    }
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
    try w.styled(Style.bold_white, "USAGE\n");
    try w.print("  hlz <command> [args] [flags]\n\n", .{});

    try w.styled(Style.bold_white, "MARKET DATA\n");
    try w.print(
        \\  price <COIN>             Mid price + bid/ask spread
        \\  mids [COIN]              All mid prices (--all, --page N)
        \\  funding [--top N]        Funding rates with heat bars
        \\  book <COIN> [--live]     L2 order book
        \\  perps [--dex xyz]        Perpetual markets
        \\  spot [--all]             Spot markets
        \\  dexes                    HIP-3 DEXes
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "ACCOUNT\n");
    try w.print(
        \\  portfolio [ADDR]         Positions + spot balances
        \\  positions [ADDR]         Open positions
        \\  orders [ADDR]            Open orders
        \\  fills [ADDR]             Recent fills
        \\  balance [ADDR]           Account balance + health
        \\  status <OID>             Order status by OID
        \\  referral [set <CODE>]    Referral status or set code
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TRADING\n");
    try w.print(
        \\  buy <COIN> <SZ> [@PX]    Limit or market buy
        \\  sell <COIN> <SZ> [@PX]   Limit or market sell
        \\  cancel <COIN> [OID]      Cancel order(s)
        \\  cancel --all             Cancel all open orders
        \\  modify <COIN> <OID> <SZ> <PX>
        \\  leverage <COIN> [N]      Query or set leverage
        \\  twap <COIN> buy|sell <SZ> --duration 1h --slices 10
        \\  batch "buy BTC 0.1 @98000" "sell ETH 1.0" [--stdin]
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TRADING FLAGS\n");
    try w.print(
        \\  --reduce-only            Reduce-only order
        \\  --tp <PX>                Take-profit (bracket)
        \\  --sl <PX>                Stop-loss (bracket)
        \\  --trigger-above <PX>     Trigger order (take-profit)
        \\  --trigger-below <PX>     Trigger order (stop-loss)
        \\  --slippage <PX>          Max slippage for market orders
        \\  --tif <gtc|ioc|alo>      Time-in-force
        \\  --dry-run, -n            Preview order without sending
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TRANSFERS\n");
    try w.print(
        \\  send <AMT> [TOKEN] <DEST>      Send to address
        \\  send <AMT> USDC --to spot      Perp → spot transfer
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "STREAMING\n");
    try w.print(
        \\  stream trades|bbo|book|candles|mids|fills|orders <COIN|ADDR>
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "AGENT\n");
    try w.print(
        \\  approve-agent <ADDR>     Approve API wallet for your account
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "KEYS\n");
    try w.print(
        \\  keys ls                  List stored keys
        \\  keys new <NAME>          Generate new key (encrypted)
        \\  keys import <NAME>       Import existing key (--private-key)
        \\  keys export <NAME>       Export key (decrypted hex)
        \\  keys default <NAME>      Set default key
        \\  keys rm <NAME>           Remove key
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "TUI\n");
    try w.print(
        \\  trade [COIN]             Trading terminal (candlestick, orderbook)
        \\  markets                  Interactive market browser
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "GLOBAL FLAGS\n");
    try w.print(
        \\  --output json|pretty|csv Output format (auto-json when piped)
        \\  --json                   Shorthand for --output json
        \\  --quiet, -q              Minimal output (just result value)
        \\  --chain mainnet|testnet  Target chain
        \\  --key <HEX>             Private key (prefer keystore)
        \\  --key-name <NAME>       Use named keystore key
        \\  --address <ADDR>        User address
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "ENVIRONMENT\n");
    try w.print(
        \\  HL_KEY                   Trading private key (raw hex)
        \\  HL_PASSWORD              Keystore password (for --key-name)
        \\  HL_ADDRESS               Default wallet address
        \\  HL_CHAIN                 Default chain (mainnet|testnet)
        \\  HL_OUTPUT                Default output format (json|pretty|csv)
        \\  NO_COLOR                 Disable colored output
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "EXIT CODES\n");
    try w.print(
        \\  0   Success
        \\  1   Error (check stderr or JSON error envelope)
        \\  2   Usage error (bad arguments, unknown command)
        \\  3   Auth error (missing key or address)
        \\  4   Network error (connection failed, retryable)
        \\
        \\
    , .{});

    try w.styled(Style.bold_white, "EXAMPLES\n");
    try w.print(
        \\  hlz price BTC                           Current BTC price
        \\  hlz positions --json                     Positions as JSON
        \\  hlz buy BTC 0.1 @95000 --dry-run         Preview order
        \\  hlz buy ETH 1.0 @3400 --tp 3600 --sl 3200  Bracket order
        \\  hlz cancel ETH                           Cancel all ETH orders
        \\  hlz stream trades BTC                    Real-time BTC trades
        \\  hlz mids --json | jq .BTC                Pipe mid price
        \\  HL_OUTPUT=json hlz positions              Agent-friendly default
        \\  echo '["buy BTC 0.1 @95000"]' | hlz batch --stdin  Pipe orders
        \\
        \\
    , .{});

    try w.styled(Style.muted, "  Asset syntax: BTC (perp) · PURR/USDC (spot) · xyz:BTC (HIP-3 DEX)\n");
    try w.styled(Style.muted, "  Aliases: long=buy short=sell pos=positions bal=balance ord=orders\n\n");
}
