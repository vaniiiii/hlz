//! Minimal argument parser for the `hl` CLI.
//!
//! No external dependencies — just iterates std.process.args().
//! Supports subcommands, flags (--flag value), and positional args.

const std = @import("std");

pub const Command = union(enum) {
    keys: KeysArgs,
    mids: MidsArgs,
    positions: UserQuery,
    orders: UserQuery,
    fills: UserQuery,
    balance: UserQuery,
    perps: MarketArgs,
    spot: MarketArgs,
    dexes: void,
    buy: OrderArgs,
    sell: OrderArgs,
    cancel: CancelArgs,
    modify: ModifyArgs,
    send: SendArgs,
    stream: StreamArgs,
    status: StatusArgs,
    funding: FundingArgs,
    book: BookArgs,
    markets: void,
    trade: TradeArgs,
    leverage: LeverageArgs,
    price: PriceArgs,
    portfolio: UserQuery,
    referral: ReferralArgs,
    twap: TwapArgs,
    batch: BatchArgs,
    approve_agent: ApproveAgentArgs,
    config: void,
    help: void,
    version: void,
};

pub const MidsArgs = struct {
    coin: ?[]const u8 = null,
    dex: ?[]const u8 = null,
    all: bool = false,
    page: usize = 1,
};

pub const UserQuery = struct {
    address: ?[]const u8 = null,
    dex: ?[]const u8 = null,
    all_dexes: bool = false,
};

pub const MarketArgs = struct {
    dex: ?[]const u8 = null,
    all: bool = false,
    page: usize = 1,
    filter: ?[]const u8 = null,
};

pub const OrderArgs = struct {
    coin: []const u8,
    size: []const u8,
    price: ?[]const u8 = null,
    slippage: ?[]const u8 = null,
    reduce_only: bool = false,
    tif: []const u8 = "gtc",
    trigger_px: ?[]const u8 = null,
    trigger_is_tp: bool = true,
    tp: ?[]const u8 = null,
    sl: ?[]const u8 = null,
    dry_run: bool = false,
};

pub const CancelArgs = struct {
    coin: ?[]const u8 = null,
    oid: ?[]const u8 = null,
    cloid: ?[]const u8 = null,
    all: bool = false,
};

pub const SendArgs = struct {
    amount: []const u8,
    token: []const u8 = "USDC",
    destination: ?[]const u8 = null, // null = self (internal transfer)
    from: []const u8 = "perp",
    to: []const u8 = "perp",
    subaccount: ?[]const u8 = null,
};

pub const ModifyArgs = struct {
    coin: []const u8,
    oid: []const u8,
    size: []const u8,
    price: []const u8,
};

pub const StreamArgs = struct {
    kind: StreamKind = .trades,
    coin: ?[]const u8 = null,
    address: ?[]const u8 = null,
    interval: []const u8 = "1m",
    filter: ?[]const u8 = null,
};

pub const StreamKind = enum {
    trades,
    bbo,
    book,
    candles,
    mids,
    fills,
    orders,
};

pub const StatusArgs = struct {
    oid: []const u8,
};

pub const FundingArgs = struct {
    top: usize = 20,
    all: bool = false,
    page: usize = 1,
    filter: ?[]const u8 = null,
};

pub const TradeArgs = struct {
    coin: []const u8 = "BTC",
};

pub const BookArgs = struct {
    coin: []const u8,
    depth: usize = 15,
    live: bool = false,
};

pub const LeverageArgs = struct {
    coin: []const u8,
    leverage: ?[]const u8 = null, // null = query only
    cross: bool = true, // --isolated flips to false
};

pub const PriceArgs = struct {
    coin: []const u8,
    dex: ?[]const u8 = null,
    quote: ?[]const u8 = null,
    all: bool = false,
};

pub const ReferralArgs = struct {
    action: ReferralAction = .status,
    code: ?[]const u8 = null,
};

pub const ReferralAction = enum { status, set };

pub const TwapArgs = struct {
    coin: []const u8,
    side: []const u8, // "buy" or "sell"
    size: []const u8,
    duration: []const u8 = "1h", // 5m, 15m, 1h, 4h, etc.
    slices: usize = 10,
    slippage_pct: f64 = 1.0, // max slippage per slice (%)
};

pub const BatchArgs = struct {
    orders: [16]?[]const u8 = .{null} ** 16,
    count: usize = 0,
    stdin: bool = false,
};

pub const KeysArgs = struct {
    action: KeysAction = .ls,
    name: ?[]const u8 = null,
    key_hex: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const KeysAction = enum { ls, new, import_, rm, export_, default };

pub const ApproveAgentArgs = struct {
    agent_address: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
};

pub const GlobalFlags = struct {
    chain: []const u8 = "mainnet",
    output: OutputFormat = .pretty,
    output_explicit: bool = false,
    quiet: bool = false,
    key: ?[]const u8 = null,
    key_name: ?[]const u8 = null,
    address: ?[]const u8 = null,
};

pub const OutputFormat = enum {
    pretty,
    json,
    csv,

    pub fn fromStr(s: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "csv")) return .csv;
        if (std.mem.eql(u8, s, "pretty") or std.mem.eql(u8, s, "table")) return .pretty;
        return null;
    }
};

pub const ParseResult = struct {
    command: ?Command,
    flags: GlobalFlags,
};

pub const ParseError = error{
    MissingArgument,
    UnknownCommand,
    InvalidFlag,
};

pub fn parse(allocator: std.mem.Allocator) ParseError!ParseResult {
    var args_iter = std.process.argsWithAllocator(allocator) catch return .{ .command = .{ .help = {} }, .flags = .{} };
    defer args_iter.deinit();

    _ = args_iter.next(); // skip binary name

    var flags = GlobalFlags{};
    var positionals: [8][]const u8 = undefined;
    var pos_count: usize = 0;

    // First pass: extract global flags and collect positionals
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--chain")) {
            flags.chain = args_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            const val = args_iter.next() orelse return error.MissingArgument;
            flags.output = OutputFormat.fromStr(val) orelse return error.InvalidFlag;
            flags.output_explicit = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            flags.output = .json;
            flags.output_explicit = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            flags.quiet = true;
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            flags.key = args_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--key-name")) {
            flags.key_name = args_iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--address") or std.mem.eql(u8, arg, "-a")) {
            flags.address = args_iter.next() orelse return error.MissingArgument;
        } else {
            if (pos_count < positionals.len) {
                positionals[pos_count] = arg;
                pos_count += 1;
            }
        }
    }

    if (pos_count == 0) return .{ .command = .{ .help = {} }, .flags = flags };

    const cmd_str = positionals[0];
    const rest = positionals[1..pos_count];

    const command: Command = if (std.mem.eql(u8, cmd_str, "keys") or std.mem.eql(u8, cmd_str, "key"))
        .{ .keys = parseKeys(rest) }
    else if (std.mem.eql(u8, cmd_str, "mids") or std.mem.eql(u8, cmd_str, "mid"))
        .{ .mids = parseMids(rest) }
    else if (std.mem.eql(u8, cmd_str, "positions") or std.mem.eql(u8, cmd_str, "pos"))
        .{ .positions = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "orders") or std.mem.eql(u8, cmd_str, "ord"))
        .{ .orders = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "fills"))
        .{ .fills = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "balance") or std.mem.eql(u8, cmd_str, "bal"))
        .{ .balance = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "perps"))
        .{ .perps = parseMarket(rest) }
    else if (std.mem.eql(u8, cmd_str, "spot"))
        .{ .spot = parseMarket(rest) }
    else if (std.mem.eql(u8, cmd_str, "dexes") or std.mem.eql(u8, cmd_str, "dex"))
        .{ .dexes = {} }
    else if (std.mem.eql(u8, cmd_str, "buy") or std.mem.eql(u8, cmd_str, "long"))
        .{ .buy = parseOrder(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "sell") or std.mem.eql(u8, cmd_str, "short"))
        .{ .sell = parseOrder(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "cancel"))
        .{ .cancel = parseCancel(rest) }
    else if (std.mem.eql(u8, cmd_str, "modify") or std.mem.eql(u8, cmd_str, "mod"))
        .{ .modify = parseModify(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "send"))
        .{ .send = parseSend(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "stream") or std.mem.eql(u8, cmd_str, "sub"))
        if (hasHelpFlag(rest)) .{ .help = {} } else .{ .stream = parseStream(rest) }
    else if (std.mem.eql(u8, cmd_str, "status"))
        .{ .status = .{ .oid = if (rest.len > 0) rest[0] else return error.MissingArgument } }
    else if (std.mem.eql(u8, cmd_str, "funding") or std.mem.eql(u8, cmd_str, "fund"))
        .{ .funding = parseFunding(rest) }
    else if (std.mem.eql(u8, cmd_str, "markets") or std.mem.eql(u8, cmd_str, "m"))
        if (hasHelpFlag(rest)) .{ .help = {} } else .{ .markets = {} }
    else if (std.mem.eql(u8, cmd_str, "book") or std.mem.eql(u8, cmd_str, "ob"))
        if (hasHelpFlag(rest)) .{ .help = {} } else .{ .book = parseBook(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "trade") or std.mem.eql(u8, cmd_str, "t"))
        if (hasHelpFlag(rest)) .{ .help = {} } else .{ .trade = parseTrade(rest) }
    else if (std.mem.eql(u8, cmd_str, "leverage") or std.mem.eql(u8, cmd_str, "lev"))
        .{ .leverage = parseLeverage(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "price"))
        .{ .price = parsePrice(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "portfolio") or std.mem.eql(u8, cmd_str, "folio"))
        .{ .portfolio = parseUserQuery(rest) }
    else if (std.mem.eql(u8, cmd_str, "referral"))
        .{ .referral = parseReferral(rest) }
    else if (std.mem.eql(u8, cmd_str, "twap"))
        .{ .twap = parseTwap(rest) orelse return error.MissingArgument }
    else if (std.mem.eql(u8, cmd_str, "batch"))
        .{ .batch = parseBatch(rest) }
    else if (std.mem.eql(u8, cmd_str, "approve-agent") or std.mem.eql(u8, cmd_str, "approve"))
        .{ .approve_agent = parseApproveAgent(rest) }
    else if (std.mem.eql(u8, cmd_str, "config"))
        .{ .config = {} }
    else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h"))
        .{ .help = {} }
    else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-V"))
        .{ .version = {} }
    else
        return error.UnknownCommand;

    return .{ .command = command, .flags = flags };
}

fn parseMids(args: []const []const u8) MidsArgs {
    var result = MidsArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
            i += 1;
            result.page = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else {
            result.coin = args[i];
        }
    }
    return result;
}

fn parseMarket(args: []const []const u8) MarketArgs {
    var result = MarketArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
            i += 1;
            result.page = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            result.filter = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            result.filter = args[i]; // positional = filter
        }
    }
    return result;
}

fn parseUserQuery(args: []const []const u8) UserQuery {
    var result = UserQuery{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--all-dexes")) {
            result.all_dexes = true;
        } else {
            result.address = args[i];
        }
    }
    return result;
}

// buy ETH 0.1 @1950   or   buy ETH 0.1  (market)
fn parseOrder(args: []const []const u8) ?OrderArgs {
    if (args.len < 2) return null;
    var result = OrderArgs{
        .coin = args[0],
        .size = args[1],
    };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 0 and a[0] == '@') {
            result.price = a[1..];
        } else if (std.mem.eql(u8, a, "--reduce-only")) {
            result.reduce_only = true;
        } else if (std.mem.eql(u8, a, "--tif") and i + 1 < args.len) {
            i += 1;
            result.tif = args[i];
        } else if (std.mem.eql(u8, a, "--slippage") and i + 1 < args.len) {
            i += 1;
            result.slippage = args[i];
        } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            result.dry_run = true;
        } else if (std.mem.eql(u8, a, "--trigger-above") and i + 1 < args.len) {
            i += 1;
            result.trigger_px = args[i];
            result.trigger_is_tp = true;
        } else if (std.mem.eql(u8, a, "--trigger-below") and i + 1 < args.len) {
            i += 1;
            result.trigger_px = args[i];
            result.trigger_is_tp = false;
        } else if (std.mem.eql(u8, a, "--tp") and i + 1 < args.len) {
            i += 1;
            result.tp = args[i];
        } else if (std.mem.eql(u8, a, "--sl") and i + 1 < args.len) {
            i += 1;
            result.sl = args[i];
        } else {
            // Might be price without @
            result.price = a;
        }
    }
    return result;
}

// cancel ETH 12345  or  cancel --all  or  cancel ETH --cloid 0x...
fn parseCancel(args: []const []const u8) CancelArgs {
    var result = CancelArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, a, "--cloid") and i + 1 < args.len) {
            i += 1;
            result.cloid = args[i];
        } else if (result.coin == null and result.oid == null and std.fmt.parseInt(u64, a, 10) catch null != null) {
            result.oid = a;
        } else if (result.coin == null) {
            result.coin = a;
        } else {
            result.oid = a;
        }
    }
    return result;
}

// modify ETH 12345 1.5 @3400
fn parseModify(args: []const []const u8) ?ModifyArgs {
    if (args.len < 4) return null;
    var price = args[3];
    if (price.len > 0 and price[0] == '@') price = price[1..];
    return ModifyArgs{
        .coin = args[0],
        .oid = args[1],
        .size = args[2],
        .price = price,
    };
}

fn parseFunding(args: []const []const u8) FundingArgs {
    var result = FundingArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--top") and i + 1 < args.len) {
            i += 1;
            result.top = std.fmt.parseInt(usize, args[i], 10) catch 20;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        } else if (std.mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
            i += 1;
            result.page = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
            i += 1;
            result.filter = args[i];
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            result.filter = args[i]; // positional = filter
        }
    }
    return result;
}

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

fn parsePrice(args: []const []const u8) ?PriceArgs {
    if (args.len < 1) return null;
    var result = PriceArgs{ .coin = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dex") and i + 1 < args.len) {
            i += 1;
            result.dex = args[i];
        } else if (std.mem.eql(u8, args[i], "--quote") and i + 1 < args.len) {
            i += 1;
            result.quote = args[i];
        } else if (std.mem.eql(u8, args[i], "--all")) {
            result.all = true;
        }
    }
    return result;
}

fn parseTrade(args: []const []const u8) TradeArgs {
    var result = TradeArgs{};
    if (args.len >= 1 and args[0].len > 0 and args[0][0] != '-') {
        result.coin = args[0];
    }
    return result;
}

fn parseBook(args: []const []const u8) ?BookArgs {
    if (args.len < 1) return null;
    var result = BookArgs{ .coin = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--depth") and i + 1 < args.len) {
            i += 1;
            result.depth = std.fmt.parseInt(usize, args[i], 10) catch 15;
        } else if (std.mem.eql(u8, args[i], "--live")) {
            result.live = true;
        }
    }
    return result;
}

// send 100 USDC 0xabc...       → send USDC to another user
// send 100 USDC --to spot      → self transfer perp→spot
// send 100 HYPE --from spot --to 0xabc...   → send from spot
// send 100 USDC --from perp --to xyz        → perp → DEX
// send 100 USDC --subaccount alice --to 0x...
fn parseSend(args: []const []const u8) ?SendArgs {
    if (args.len < 2) return null;
    var result = SendArgs{ .amount = args[0] };
    var i: usize = 1;
    // Second arg: token name or destination (if starts with 0x)
    if (i < args.len) {
        const a = args[i];
        if (a.len >= 2 and a[0] == '0' and a[1] == 'x') {
            result.destination = a;
        } else if (std.mem.eql(u8, a, "--from") or std.mem.eql(u8, a, "--to") or std.mem.eql(u8, a, "--subaccount")) {
            // flags start here, token defaults to USDC
        } else {
            result.token = a;
            i += 1;
        }
    }
    // Remaining: destination or flags
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--from") and i + 1 < args.len) {
            i += 1;
            result.from = args[i];
        } else if (std.mem.eql(u8, a, "--to") and i + 1 < args.len) {
            i += 1;
            result.to = args[i];
        } else if (std.mem.eql(u8, a, "--subaccount") and i + 1 < args.len) {
            i += 1;
            result.subaccount = args[i];
        } else if (result.destination == null) {
            result.destination = a;
        }
    }
    return result;
}

// leverage BTC 10 --isolated  or  leverage BTC (query)
fn parseLeverage(args: []const []const u8) ?LeverageArgs {
    if (args.len < 1) return null;
    var result = LeverageArgs{ .coin = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--isolated")) {
            result.cross = false;
        } else if (std.mem.eql(u8, a, "--cross")) {
            result.cross = true;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            result.leverage = a;
        }
    }
    return result;
}

fn parseReferral(args: []const []const u8) ReferralArgs {
    var result = ReferralArgs{};
    if (args.len >= 2 and std.mem.eql(u8, args[0], "set")) {
        result.action = .set;
        result.code = args[1];
    } else if (args.len >= 1 and std.mem.eql(u8, args[0], "status")) {
        result.action = .status;
    } else if (args.len >= 1 and !std.mem.startsWith(u8, args[0], "--")) {
        // `hlz referral MYCODE` = shorthand for set
        result.action = .set;
        result.code = args[0];
    }
    return result;
}

// twap BTC buy 10.0 --duration 1h --slices 12
fn parseTwap(args: []const []const u8) ?TwapArgs {
    if (args.len < 3) return null;
    var result = TwapArgs{
        .coin = args[0],
        .side = args[1],
        .size = args[2],
    };
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--duration") and i + 1 < args.len) {
            i += 1;
            result.duration = args[i];
        } else if (std.mem.eql(u8, a, "--slices") and i + 1 < args.len) {
            i += 1;
            result.slices = std.fmt.parseInt(usize, args[i], 10) catch 10;
        } else if (std.mem.eql(u8, a, "--slippage") and i + 1 < args.len) {
            i += 1;
            result.slippage_pct = std.fmt.parseFloat(f64, args[i]) catch 1.0;
        }
    }
    return result;
}

// batch "buy BTC 0.1 @98000" "sell ETH 1.0 @3400"
fn parseBatch(args: []const []const u8) BatchArgs {
    var result = BatchArgs{};
    for (args) |a| {
        if (std.mem.eql(u8, a, "--stdin")) {
            result.stdin = true;
        } else if (result.count < 16) {
            result.orders[result.count] = a;
            result.count += 1;
        }
    }
    return result;
}

fn parseApproveAgent(args: []const []const u8) ApproveAgentArgs {
    var result = ApproveAgentArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--name") and i + 1 < args.len) {
            i += 1;
            result.agent_name = args[i];
        } else if (!std.mem.startsWith(u8, a, "--")) {
            if (result.agent_address == null) result.agent_address = a;
        }
    }
    return result;
}

fn parseKeys(args: []const []const u8) KeysArgs {
    var result = KeysArgs{};
    if (args.len == 0) return result;

    const action = args[0];
    if (std.mem.eql(u8, action, "new")) {
        result.action = .new;
    } else if (std.mem.eql(u8, action, "import")) {
        result.action = .import_;
    } else if (std.mem.eql(u8, action, "rm") or std.mem.eql(u8, action, "remove")) {
        result.action = .rm;
    } else if (std.mem.eql(u8, action, "export")) {
        result.action = .export_;
    } else if (std.mem.eql(u8, action, "default") or std.mem.eql(u8, action, "use")) {
        result.action = .default;
    } else if (std.mem.eql(u8, action, "ls") or std.mem.eql(u8, action, "list")) {
        result.action = .ls;
    } else {
        // Bare name = ls or maybe the name for another action
        result.name = action;
        return result;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--password") and i + 1 < args.len) {
            i += 1;
            result.password = args[i];
        } else if ((std.mem.eql(u8, a, "--private-key") or std.mem.eql(u8, a, "--pk")) and i + 1 < args.len) {
            i += 1;
            result.key_hex = args[i];
        } else if (!std.mem.startsWith(u8, a, "--")) {
            result.name = a;
        }
    }
    return result;
}

// stream trades ETH  or  stream bbo BTC  or  stream fills 0x...
fn parseStream(args: []const []const u8) StreamArgs {
    var result = StreamArgs{};
    var i: usize = 0;
    if (i < args.len) {
        const kind_str = args[i];
        if (std.mem.eql(u8, kind_str, "trades") or std.mem.eql(u8, kind_str, "trade")) {
            result.kind = .trades;
        } else if (std.mem.eql(u8, kind_str, "bbo")) {
            result.kind = .bbo;
        } else if (std.mem.eql(u8, kind_str, "book") or std.mem.eql(u8, kind_str, "orderbook")) {
            result.kind = .book;
        } else if (std.mem.eql(u8, kind_str, "candles") or std.mem.eql(u8, kind_str, "candle")) {
            result.kind = .candles;
        } else if (std.mem.eql(u8, kind_str, "mids") or std.mem.eql(u8, kind_str, "mid")) {
            result.kind = .mids;
        } else if (std.mem.eql(u8, kind_str, "fills") or std.mem.eql(u8, kind_str, "fill")) {
            result.kind = .fills;
        } else if (std.mem.eql(u8, kind_str, "orders") or std.mem.eql(u8, kind_str, "order")) {
            result.kind = .orders;
        } else {
            // If first arg doesn't match a kind, treat as coin for default (trades)
            result.coin = kind_str;
            i += 1;
        }
        if (result.coin == null) i += 1;
    }
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--interval") and i + 1 < args.len) {
            i += 1;
            result.interval = args[i];
        } else if (std.mem.eql(u8, a, "--filter") and i + 1 < args.len) {
            i += 1;
            result.filter = a;
        } else if (result.coin == null and result.address == null) {
            // If starts with 0x, it's an address, otherwise coin
            if (a.len >= 2 and a[0] == '0' and a[1] == 'x') {
                result.address = a;
            } else {
                result.coin = a;
            }
        }
    }
    return result;
}
