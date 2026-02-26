//! Response types for Hyperliquid API.
//!
//! These structs parse JSON responses from the info and exchange endpoints.
//! All types use Zig's stdlib JSON parser via our json.zig helpers.
//!
//! Response types are designed for zero-copy parsing where possible — string
//! fields reference the original JSON buffer.

const std = @import("std");
const json = @import("json.zig");
const Decimal = @import("../lib/math/decimal.zig").Decimal;


pub const ResponseStatus = enum {
    ok,
    err,
    unknown,
};

pub const OrderResponseStatus = union(enum) {
    success: void,
    resting: struct { oid: u64, cloid: ?[]const u8 },
    filled: struct { total_sz: ?Decimal, avg_px: ?Decimal, oid: u64 },
    @"error": []const u8,
    unknown: void,
};

/// Parse the exchange response status.
pub fn parseResponseStatus(obj: std.json.Value) ResponseStatus {
    const status = json.getString(obj, "status") orelse return .unknown;
    if (std.mem.eql(u8, status, "ok")) return .ok;
    if (std.mem.eql(u8, status, "err")) return .err;
    return .unknown;
}

/// Parse order response statuses from a place/cancel/modify response.
pub fn parseOrderStatuses(allocator: std.mem.Allocator, obj: std.json.Value) ![]OrderResponseStatus {
    const response = json.getObject(obj, "response") orelse return &[_]OrderResponseStatus{};
    const data = json.getObject(response, "data") orelse return &[_]OrderResponseStatus{};
    const statuses_arr = json.getArray(data, "statuses") orelse return &[_]OrderResponseStatus{};

    var result = try allocator.alloc(OrderResponseStatus, statuses_arr.len);
    for (statuses_arr, 0..) |item, i| {
        result[i] = parseOneOrderStatus(item);
    }
    return result;
}

fn parseOneOrderStatus(item: std.json.Value) OrderResponseStatus {
    // Could be {"resting":{"oid":123}}, {"filled":{"totalSz":"0.1","avgPx":"50000","oid":123}},
    // "success", or {"error":"msg"}
    if (item == .string) {
        if (std.mem.eql(u8, item.string, "success")) return .{ .success = {} };
        return .{ .@"error" = item.string };
    }
    if (item != .object) return .{ .unknown = {} };

    if (json.getObject(item, "resting")) |r| {
        return .{ .resting = .{
            .oid = json.getInt(u64, r, "oid") orelse 0,
            .cloid = json.getString(r, "cloid"),
        } };
    }
    if (json.getObject(item, "filled")) |f| {
        return .{ .filled = .{
            .total_sz = json.getDecimal(f, "totalSz"),
            .avg_px = json.getDecimal(f, "avgPx"),
            .oid = json.getInt(u64, f, "oid") orelse 0,
        } };
    }
    if (json.getString(item, "error")) |e| {
        return .{ .@"error" = e };
    }
    return .{ .unknown = {} };
}


pub const Fill = struct {
    coin: []const u8,
    px: ?Decimal,
    sz: ?Decimal,
    side: []const u8,
    time: u64,
    start_position: ?Decimal,
    dir: []const u8,
    closed_pnl: ?Decimal,
    hash: []const u8,
    oid: u64,
    crossed: bool,
    fee: ?Decimal,
    tid: u64,
    fee_token: []const u8,

    pub fn fromJson(obj: std.json.Value) ?Fill {
        return Fill{
            .coin = json.getString(obj, "coin") orelse return null,
            .px = json.getDecimal(obj, "px"),
            .sz = json.getDecimal(obj, "sz"),
            .side = json.getString(obj, "side") orelse "?",
            .time = json.getInt(u64, obj, "time") orelse 0,
            .start_position = json.getDecimal(obj, "startPosition"),
            .dir = json.getString(obj, "dir") orelse "",
            .closed_pnl = json.getDecimal(obj, "closedPnl"),
            .hash = json.getString(obj, "hash") orelse "",
            .oid = json.getInt(u64, obj, "oid") orelse 0,
            .crossed = json.getBool(obj, "crossed") orelse false,
            .fee = json.getDecimal(obj, "fee"),
            .tid = json.getInt(u64, obj, "tid") orelse 0,
            .fee_token = json.getString(obj, "feeToken") orelse "",
        };
    }
};

pub const BasicOrder = struct {
    timestamp: u64,
    coin: []const u8,
    side: []const u8,
    limit_px: ?Decimal,
    sz: ?Decimal,
    oid: u64,
    orig_sz: ?Decimal,
    reduce_only: bool,

    pub fn fromJson(obj: std.json.Value) ?BasicOrder {
        return BasicOrder{
            .timestamp = json.getInt(u64, obj, "timestamp") orelse return null,
            .coin = json.getString(obj, "coin") orelse return null,
            .side = json.getString(obj, "side") orelse "?",
            .limit_px = json.getDecimal(obj, "limitPx"),
            .sz = json.getDecimal(obj, "sz"),
            .oid = json.getInt(u64, obj, "oid") orelse 0,
            .orig_sz = json.getDecimal(obj, "origSz"),
            .reduce_only = json.getBool(obj, "reduceOnly") orelse false,
        };
    }
};

pub const OrderUpdate = struct {
    coin: []const u8,
    oid: u64,
    side: []const u8,
    limit_px: ?Decimal,
    sz: ?Decimal,
    orig_sz: ?Decimal,
    timestamp: u64,
    status: []const u8,

    pub fn fromJson(obj: std.json.Value) ?OrderUpdate {
        // OrderUpdate wraps: { order: { ... }, status: "..." }
        const order_obj = json.getObject(obj, "order") orelse return null;
        return OrderUpdate{
            .coin = json.getString(order_obj, "coin") orelse return null,
            .oid = json.getInt(u64, order_obj, "oid") orelse 0,
            .side = json.getString(order_obj, "side") orelse "?",
            .limit_px = json.getDecimal(order_obj, "limitPx"),
            .sz = json.getDecimal(order_obj, "sz"),
            .orig_sz = json.getDecimal(order_obj, "origSz"),
            .timestamp = json.getInt(u64, order_obj, "timestamp") orelse 0,
            .status = json.getString(obj, "status") orelse "",
        };
    }
};

pub const Candle = struct {
    open_time: u64,
    close_time: u64,
    coin: []const u8,
    interval: []const u8,
    open: ?Decimal,
    high: ?Decimal,
    low: ?Decimal,
    close: ?Decimal,
    volume: ?Decimal,
    num_trades: u64,

    pub fn fromJson(obj: std.json.Value) ?Candle {
        return Candle{
            .open_time = json.getInt(u64, obj, "t") orelse return null,
            .close_time = json.getInt(u64, obj, "T") orelse 0,
            .coin = json.getString(obj, "s") orelse "",
            .interval = json.getString(obj, "i") orelse "",
            .open = json.getDecimal(obj, "o"),
            .high = json.getDecimal(obj, "h"),
            .low = json.getDecimal(obj, "l"),
            .close = json.getDecimal(obj, "c"),
            .volume = json.getDecimal(obj, "v"),
            .num_trades = json.getInt(u64, obj, "n") orelse 0,
        };
    }
};

pub const Trade = struct {
    coin: []const u8,
    side: []const u8,
    px: ?Decimal,
    sz: ?Decimal,
    time: u64,
    hash: []const u8,
    tid: u64,

    pub fn fromJson(obj: std.json.Value) ?Trade {
        return Trade{
            .coin = json.getString(obj, "coin") orelse return null,
            .side = json.getString(obj, "side") orelse "?",
            .px = json.getDecimal(obj, "px"),
            .sz = json.getDecimal(obj, "sz"),
            .time = json.getInt(u64, obj, "time") orelse 0,
            .hash = json.getString(obj, "hash") orelse "",
            .tid = json.getInt(u64, obj, "tid") orelse 0,
        };
    }
};

pub const BookLevel = struct {
    px: ?Decimal,
    sz: ?Decimal,
    n: u64, // number of orders

    pub fn fromJson(obj: std.json.Value) ?BookLevel {
        return BookLevel{
            .px = json.getDecimal(obj, "px"),
            .sz = json.getDecimal(obj, "sz"),
            .n = json.getInt(u64, obj, "n") orelse 0,
        };
    }
};

pub const Bbo = struct {
    coin: []const u8,
    bid_px: ?Decimal,
    bid_sz: ?Decimal,
    ask_px: ?Decimal,
    ask_sz: ?Decimal,
    time: u64,

    pub fn fromJson(obj: std.json.Value) ?Bbo {
        return Bbo{
            .coin = json.getString(obj, "coin") orelse return null,
            .bid_px = json.getDecimal(obj, "bidPx"),
            .bid_sz = json.getDecimal(obj, "bidSz"),
            .ask_px = json.getDecimal(obj, "askPx"),
            .ask_sz = json.getDecimal(obj, "askSz"),
            .time = json.getInt(u64, obj, "time") orelse 0,
        };
    }
};

pub const MarginSummary = struct {
    account_value: ?Decimal,
    total_ntl_pos: ?Decimal,
    total_raw_usd: ?Decimal,
    total_margin_used: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?MarginSummary {
        return MarginSummary{
            .account_value = json.getDecimal(obj, "accountValue"),
            .total_ntl_pos = json.getDecimal(obj, "totalNtlPos"),
            .total_raw_usd = json.getDecimal(obj, "totalRawUsd"),
            .total_margin_used = json.getDecimal(obj, "totalMarginUsed"),
        };
    }
};

pub const PositionData = struct {
    coin: []const u8,
    szi: ?Decimal,
    entry_px: ?Decimal,
    position_value: ?Decimal,
    unrealized_pnl: ?Decimal,
    leverage_type: []const u8,
    leverage_value: ?u64,
    liquidation_px: ?Decimal,
    margin_used: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?PositionData {
        const pos = json.getObject(obj, "position") orelse return null;
        var lev_val: ?u64 = null;
        var lev_type: []const u8 = "";
        if (json.getObject(pos, "leverage")) |lev| {
            lev_type = json.getString(lev, "type") orelse "";
            lev_val = json.getInt(u64, lev, "value");
        }
        return PositionData{
            .coin = json.getString(pos, "coin") orelse return null,
            .szi = json.getDecimal(pos, "szi"),
            .entry_px = json.getDecimal(pos, "entryPx"),
            .position_value = json.getDecimal(pos, "positionValue"),
            .unrealized_pnl = json.getDecimal(pos, "unrealizedPnl"),
            .leverage_type = lev_type,
            .leverage_value = lev_val,
            .liquidation_px = json.getDecimal(pos, "liquidationPx"),
            .margin_used = json.getDecimal(pos, "marginUsed"),
        };
    }
};

pub const ClearinghouseState = struct {
    margin_summary: ?MarginSummary,
    cross_margin_summary: ?MarginSummary,
    withdrawable: ?Decimal,
    cross_maintenance_margin_used: ?Decimal,
    time: u64,

    pub fn fromJson(obj: std.json.Value) ?ClearinghouseState {
        return ClearinghouseState{
            .margin_summary = if (json.getObject(obj, "marginSummary")) |ms| MarginSummary.fromJson(ms) else null,
            .cross_margin_summary = if (json.getObject(obj, "crossMarginSummary")) |cms| MarginSummary.fromJson(cms) else null,
            .withdrawable = json.getDecimal(obj, "withdrawable"),
            .cross_maintenance_margin_used = json.getDecimal(obj, "crossMaintenanceMarginUsed"),
            .time = json.getInt(u64, obj, "time") orelse 0,
        };
    }
};

pub const UserBalance = struct {
    coin: []const u8,
    token: usize,
    hold: ?Decimal,
    total: ?Decimal,
    entry_ntl: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?UserBalance {
        return UserBalance{
            .coin = json.getString(obj, "coin") orelse return null,
            .token = json.getInt(usize, obj, "token") orelse 0,
            .hold = json.getDecimal(obj, "hold"),
            .total = json.getDecimal(obj, "total"),
            .entry_ntl = json.getDecimal(obj, "entryNtl"),
        };
    }
};

pub const FundingRate = struct {
    coin: []const u8,
    funding_rate: ?Decimal,
    premium: ?Decimal,
    time: u64,

    pub fn fromJson(obj: std.json.Value) ?FundingRate {
        return FundingRate{
            .coin = json.getString(obj, "coin") orelse return null,
            .funding_rate = json.getDecimal(obj, "fundingRate"),
            .premium = json.getDecimal(obj, "premium"),
            .time = json.getInt(u64, obj, "time") orelse 0,
        };
    }
};

pub const L2Book = struct {
    coin: []const u8,
    time: u64,
    snapshot: bool,
    // Levels stored as raw JSON arrays — parse with BookLevel.fromJson
    bids_raw: ?[]const std.json.Value,
    asks_raw: ?[]const std.json.Value,

    pub fn fromJson(obj: std.json.Value) ?L2Book {
        const levels_arr = json.getArray(obj, "levels");
        var bids: ?[]const std.json.Value = null;
        var asks: ?[]const std.json.Value = null;
        if (levels_arr) |la| {
            if (la.len >= 2) {
                if (la[0] == .array) bids = la[0].array.items;
                if (la[1] == .array) asks = la[1].array.items;
            }
        }
        return L2Book{
            .coin = json.getString(obj, "coin") orelse return null,
            .time = json.getInt(u64, obj, "time") orelse 0,
            .snapshot = json.getBool(obj, "snapshot") orelse false,
            .bids_raw = bids,
            .asks_raw = asks,
        };
    }
};

pub const UserFunding = struct {
    time: u64,
    coin: []const u8,
    usdc: ?Decimal,
    szi: ?Decimal,
    funding_rate: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?UserFunding {
        return UserFunding{
            .time = json.getInt(u64, obj, "time") orelse return null,
            .coin = json.getString(obj, "coin") orelse return null,
            .usdc = json.getDecimal(obj, "usdc"),
            .szi = json.getDecimal(obj, "szi"),
            .funding_rate = json.getDecimal(obj, "fundingRate"),
        };
    }
};

pub const UserLiquidation = struct {
    lid: u64,
    liquidator: []const u8,
    liquidated_user: []const u8,
    liquidated_ntl_pos: ?Decimal,
    liquidated_account_value: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?UserLiquidation {
        return UserLiquidation{
            .lid = json.getInt(u64, obj, "lid") orelse return null,
            .liquidator = json.getString(obj, "liquidator") orelse "",
            .liquidated_user = json.getString(obj, "liquidated_user") orelse "",
            .liquidated_ntl_pos = json.getDecimal(obj, "liquidated_ntl_pos"),
            .liquidated_account_value = json.getDecimal(obj, "liquidated_account_value"),
        };
    }
};

pub const NonUserCancel = struct {
    coin: []const u8,
    oid: u64,

    pub fn fromJson(obj: std.json.Value) ?NonUserCancel {
        return NonUserCancel{
            .coin = json.getString(obj, "coin") orelse return null,
            .oid = json.getInt(u64, obj, "oid") orelse 0,
        };
    }
};

pub const Liquidation = struct {
    lid: u64,
    liquidator: []const u8,
    liquidated_user: []const u8,
    liquidated_ntl_pos: ?Decimal,
    liquidated_account_value: ?Decimal,
};

pub const UserLeverage = struct {
    leverage_type: []const u8,
    value: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?UserLeverage {
        return UserLeverage{
            .leverage_type = json.getString(obj, "type") orelse "",
            .value = json.getDecimal(obj, "value"),
        };
    }
};

pub const ActiveAssetData = struct {
    user: []const u8,
    coin: []const u8,
    leverage: ?UserLeverage,

    pub fn fromJson(obj: std.json.Value) ?ActiveAssetData {
        return ActiveAssetData{
            .user = json.getString(obj, "user") orelse return null,
            .coin = json.getString(obj, "coin") orelse return null,
            .leverage = if (json.getObject(obj, "leverage")) |l| UserLeverage.fromJson(l) else null,
        };
    }
};

pub const AssetContext = struct {
    funding: ?Decimal,
    open_interest: ?Decimal,
    mark_px: ?Decimal,
    oracle_px: ?Decimal,
    mid_px: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?AssetContext {
        return AssetContext{
            .funding = json.getDecimal(obj, "funding"),
            .open_interest = json.getDecimal(obj, "openInterest"),
            .mark_px = json.getDecimal(obj, "markPx"),
            .oracle_px = json.getDecimal(obj, "oraclePx"),
            .mid_px = json.getDecimal(obj, "midPx"),
        };
    }
};

pub const MultiSigConfig = struct {
    authorized_users: ?[]const std.json.Value,
    threshold: usize,

    pub fn fromJson(obj: std.json.Value) ?MultiSigConfig {
        return MultiSigConfig{
            .authorized_users = json.getArray(obj, "authorizedUsers"),
            .threshold = json.getInt(usize, obj, "threshold") orelse 0,
        };
    }
};

pub const ApiAgent = struct {
    name: []const u8,
    address: []const u8,
    valid_until: ?u64,

    pub fn fromJson(obj: std.json.Value) ?ApiAgent {
        return ApiAgent{
            .name = json.getString(obj, "name") orelse return null,
            .address = json.getString(obj, "address") orelse return null,
            .valid_until = json.getInt(u64, obj, "validUntil"),
        };
    }
};

pub const UserRole = struct {
    role: []const u8,
    data: ?std.json.Value,

    pub fn fromJson(obj: std.json.Value) ?UserRole {
        return UserRole{
            .role = json.getString(obj, "role") orelse return null,
            .data = if (obj == .object) obj.object.get("data") orelse null else null,
        };
    }

    pub fn isUser(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "user");
    }
    pub fn isVault(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "vault");
    }
    pub fn isAgent(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "agent");
    }
    pub fn isMissing(self: UserRole) bool {
        return std.mem.eql(u8, self.role, "missing");
    }
};

pub const UserVaultEquity = struct {
    vault_address: []const u8,
    equity: ?Decimal,
    locked_until_timestamp: ?u64,

    pub fn fromJson(obj: std.json.Value) ?UserVaultEquity {
        return UserVaultEquity{
            .vault_address = json.getString(obj, "vaultAddress") orelse return null,
            .equity = json.getDecimal(obj, "equity"),
            .locked_until_timestamp = json.getInt(u64, obj, "lockedUntilTimestamp"),
        };
    }
};

pub const SubAccount = struct {
    name: []const u8,
    sub_account_user: []const u8,
    master: []const u8,
    clearinghouse_state: ?ClearinghouseState,

    pub fn fromJson(obj: std.json.Value) ?SubAccount {
        return SubAccount{
            .name = json.getString(obj, "name") orelse return null,
            .sub_account_user = json.getString(obj, "subAccountUser") orelse "",
            .master = json.getString(obj, "master") orelse "",
            .clearinghouse_state = if (json.getObject(obj, "clearinghouseState")) |cs| ClearinghouseState.fromJson(cs) else null,
        };
    }
};

pub const VaultDetails = struct {
    name: []const u8,
    vault_address: []const u8,
    leader: []const u8,
    description: []const u8,
    apr: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?VaultDetails {
        return VaultDetails{
            .name = json.getString(obj, "name") orelse return null,
            .vault_address = json.getString(obj, "vaultAddress") orelse "",
            .leader = json.getString(obj, "leader") orelse "",
            .description = json.getString(obj, "description") orelse "",
            .apr = json.getDecimal(obj, "apr"),
        };
    }
};

pub const WsBasicOrder = struct {
    timestamp: u64,
    coin: []const u8,
    side: []const u8,
    limit_px: ?Decimal,
    sz: ?Decimal,
    oid: u64,
    orig_sz: ?Decimal,

    pub fn fromJson(obj: std.json.Value) ?WsBasicOrder {
        return WsBasicOrder{
            .timestamp = json.getInt(u64, obj, "timestamp") orelse return null,
            .coin = json.getString(obj, "coin") orelse return null,
            .side = json.getString(obj, "side") orelse "?",
            .limit_px = json.getDecimal(obj, "limitPx"),
            .sz = json.getDecimal(obj, "sz"),
            .oid = json.getInt(u64, obj, "oid") orelse 0,
            .orig_sz = json.getDecimal(obj, "origSz"),
        };
    }
};

/// Dex (exchange) identifier.
pub const Dex = struct {
    name: []const u8,
    index: usize,

    pub fn fromJson(obj: std.json.Value) ?Dex {
        return Dex{
            .name = json.getString(obj, "name") orelse return null,
            .index = json.getInt(usize, obj, "index") orelse 0,
        };
    }
};

/// Spot token info (from SpotMeta response).
pub const SpotToken = struct {
    name: []const u8,
    index: u32,
    sz_decimals: i32,
    wei_decimals: i32,

    pub fn fromJson(obj: std.json.Value) ?SpotToken {
        return SpotToken{
            .name = json.getString(obj, "name") orelse return null,
            .index = json.getInt(u32, obj, "index") orelse 0,
            .sz_decimals = json.getInt(i32, obj, "szDecimals") orelse 0,
            .wei_decimals = json.getInt(i32, obj, "weiDecimals") orelse 0,
        };
    }
};

/// Perp market info (from Meta response, post-processing needed).
pub const PerpMeta = struct {
    name: []const u8,
    sz_decimals: i32,
    max_leverage: u64,
    only_isolated: bool,

    pub fn fromJson(obj: std.json.Value) ?PerpMeta {
        return PerpMeta{
            .name = json.getString(obj, "name") orelse return null,
            .sz_decimals = json.getInt(i32, obj, "szDecimals") orelse 0,
            .max_leverage = json.getInt(u64, obj, "maxLeverage") orelse 1,
            .only_isolated = json.getBool(obj, "onlyIsolated") orelse false,
        };
    }
};


/// Atomic nonce handler. Generates monotonically increasing nonces
/// based on current timestamp in milliseconds.
pub const NonceHandler = struct {
    nonce: std.atomic.Value(u64),

    pub fn init() NonceHandler {
        const now: u64 = @intCast(std.time.milliTimestamp());
        return .{ .nonce = std.atomic.Value(u64).init(now) };
    }

    /// Get the next nonce. Guaranteed to be monotonically increasing.
    pub fn next(self: *NonceHandler) u64 {
        const now: u64 = @intCast(std.time.milliTimestamp());
        var current = self.nonce.load(.acquire);
        while (true) {
            const new_val = @max(current + 1, now);
            if (self.nonce.cmpxchgWeak(current, new_val, .release, .acquire)) |old| {
                current = old;
            } else {
                return new_val;
            }
        }
    }
};


test "Fill.fromJson" {
    const json_str =
        \\{"coin":"BTC","px":"50000.5","sz":"0.1","side":"B","time":1690000000000,"startPosition":"0","dir":"Open Long","closedPnl":"0","hash":"0xabc","oid":12345,"crossed":true,"fee":"0.5","tid":99,"feeToken":"USDC"}
    ;
    var parsed = try json.parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const fill = Fill.fromJson(parsed.value).?;
    try std.testing.expectEqualStrings("BTC", fill.coin);
    try std.testing.expectEqual(@as(u64, 12345), fill.oid);
    try std.testing.expectEqual(true, fill.crossed);
}

test "ClearinghouseState.fromJson" {
    const json_str =
        \\{"marginSummary":{"accountValue":"10000","totalNtlPos":"5000","totalRawUsd":"10000","totalMarginUsed":"500"},"crossMarginSummary":{"accountValue":"10000","totalNtlPos":"5000","totalRawUsd":"10000","totalMarginUsed":"500"},"withdrawable":"9500","crossMaintenanceMarginUsed":"250","assetPositions":[],"time":1690000000000}
    ;
    var parsed = try json.parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const state = ClearinghouseState.fromJson(parsed.value).?;
    try std.testing.expectEqual(@as(u64, 1690000000000), state.time);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("10000", try state.margin_summary.?.account_value.?.toString(&buf));
}

test "parseResponseStatus" {
    const ok_json =
        \\{"status":"ok","response":{"type":"default"}}
    ;
    var parsed = try json.parse(std.testing.allocator, ok_json);
    defer parsed.deinit();
    try std.testing.expectEqual(ResponseStatus.ok, parseResponseStatus(parsed.value));
}

test "NonceHandler: monotonic" {
    var handler = NonceHandler.init();
    const n1 = handler.next();
    const n2 = handler.next();
    const n3 = handler.next();
    try std.testing.expect(n2 > n1);
    try std.testing.expect(n3 > n2);
}

test "L2Book.fromJson" {
    const json_str =
        \\{"coin":"BTC","time":1690000000000,"snapshot":true,"levels":[[{"px":"50000","sz":"1","n":5}],[{"px":"50001","sz":"0.5","n":3}]]}
    ;
    var parsed = try json.parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const book = L2Book.fromJson(parsed.value).?;
    try std.testing.expectEqualStrings("BTC", book.coin);
    try std.testing.expectEqual(true, book.snapshot);
    try std.testing.expectEqual(@as(usize, 1), book.bids_raw.?.len);
    try std.testing.expectEqual(@as(usize, 1), book.asks_raw.?.len);
}

test "ApiAgent.fromJson" {
    const json_str =
        \\{"name":"my_agent","address":"0x1234","validUntil":1700000000000}
    ;
    var parsed = try json.parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const agent = ApiAgent.fromJson(parsed.value).?;
    try std.testing.expectEqualStrings("my_agent", agent.name);
    try std.testing.expectEqual(@as(u64, 1700000000000), agent.valid_until.?);
}

test "UserBalance.fromJson" {
    const json_str =
        \\{"coin":"USDC","token":0,"hold":"100","total":"1000","entryNtl":"900"}
    ;
    var parsed = try json.parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const bal = UserBalance.fromJson(parsed.value).?;
    try std.testing.expectEqualStrings("USDC", bal.coin);
}
