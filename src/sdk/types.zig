//! Hyperliquid API types and MessagePack serialization.
//! Byte-identical to Rust SDK's rmp-serde output.

const std = @import("std");
const msgpack = @import("../lib/encoding/msgpack.zig");
const Decimal = @import("../lib/math/decimal.zig").Decimal;


/// B128 client order ID, serialized as "0x" + 32 hex chars.
pub const Cloid = [16]u8;

pub const ZERO_CLOID: Cloid = [_]u8{0} ** 16;

/// Format a Cloid as "0x" + 32 lowercase hex chars.
pub fn cloidToHex(cloid: Cloid) [34]u8 {
    var buf: [34]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    for (cloid, 0..) |byte, i| {
        const hex = "0123456789abcdef";
        buf[2 + i * 2] = hex[byte >> 4];
        buf[2 + i * 2 + 1] = hex[byte & 0x0f];
    }
    return buf;
}


pub const Side = enum {
    Buy,
    Sell,

    pub fn isBuy(self: Side) bool {
        return self == .Buy;
    }
};

/// Time in force — PascalCase serialization (matching Rust's #[serde(rename = "PascalCase")])
pub const TimeInForce = enum { Alo, Ioc, Gtc, FrontendMarket };
pub const TpSl = enum { tp, sl };
pub const OrderGrouping = enum { na, normalTpsl, positionTpsl };


/// Order type placement — serialized as tagged union.
pub const OrderTypePlacement = union(enum) {
    limit: struct { tif: TimeInForce },
    trigger: struct {
        is_market: bool,
        trigger_px: Decimal,
        tpsl: TpSl,
    },
};

/// A single order request.
/// Fields use single-letter serde renames: a, b, p, s, r, t, c
pub const OrderRequest = struct {
    asset: usize,
    is_buy: bool,
    limit_px: Decimal,
    sz: Decimal,
    reduce_only: bool,
    order_type: OrderTypePlacement,
    cloid: Cloid,
};

/// Batch of orders to place.
pub const BatchOrder = struct {
    orders: []const OrderRequest,
    grouping: OrderGrouping,
};

/// Cancel a single order by exchange-assigned ID.
pub const Cancel = struct {
    asset: usize,
    oid: u64,
};

/// Cancel a single order by client ID.
pub const CancelByCloid = struct {
    asset: usize,
    cloid: Cloid,
};

pub const BatchCancel = struct {
    cancels: []const Cancel,
};

pub const BatchCancelCloid = struct {
    cancels: []const CancelByCloid,
};

pub const ScheduleCancel = struct {
    time: ?u64,
};

pub const UpdateIsolatedMargin = struct {
    asset: usize,
    is_buy: bool,
    ntli: u64,
};

pub const UpdateLeverage = struct {
    asset: usize,
    is_cross: bool,
    leverage: u32,
};

pub const SetReferrer = struct {
    code: []const u8,
};

/// Either a numeric OID or a Cloid.
pub const OidOrCloid = union(enum) {
    oid: u64,
    cloid: Cloid,
};

/// Modification of an existing order.
pub const Modify = struct {
    oid: OidOrCloid,
    order: OrderRequest,
};

pub const BatchModify = struct {
    modifies: []const Modify,
};

// These are NOT msgpack-serialized — they go through EIP-712 typed data signing.
// But they ARE JSON-serialized for the exchange endpoint.

pub const UsdSendParams = struct {
    destination: []const u8, // lowercase hex "0x..."
    amount: []const u8, // decimal string
    time: u64,
};

pub const SpotSendParams = struct {
    destination: []const u8,
    token: []const u8, // token name like "PURR" or index string
    amount: []const u8,
    time: u64,
};

pub const SendAssetParams = struct {
    destination: []const u8,
    source_dex: []const u8, // "Perp" or "Spot" or dex name
    destination_dex: []const u8,
    token: []const u8,
    amount: []const u8,
    from_sub_account: []const u8,
    nonce: u64,
};

pub const ApproveAgentParams = struct {
    agent_address: []const u8, // lowercase hex
    agent_name: ?[]const u8, // null for unnamed
    nonce: u64,
};

pub const ConvertToMultiSigParams = struct {
    authorized_users: []const []const u8, // list of address hex strings
    threshold: usize,
    nonce: u64,
};

// These functions produce byte-exact output matching rmp-serde::to_vec_named.
// The Rust SDK uses serde field renames, so we must match them exactly.

/// Pack an OrderRequest to msgpack with single-letter field names.
pub fn packOrderRequest(p: *msgpack.Packer, order: OrderRequest) msgpack.PackError!void {
    try p.packMapHeader(7); // 7 fields: a, b, p, s, r, t, c

    // a: asset
    try p.packStr("a");
    try p.packUint(@intCast(order.asset));

    // b: is_buy
    try p.packStr("b");
    try p.packBool(order.is_buy);

    // p: limit_px (normalized decimal string)
    try p.packStr("p");
    var px_buf: [64]u8 = undefined;
    const px_str = order.limit_px.normalize().toString(&px_buf) catch return error.BufferOverflow;
    try p.packStr(px_str);

    // s: sz (normalized decimal string)
    try p.packStr("s");
    var sz_buf: [64]u8 = undefined;
    const sz_str = order.sz.normalize().toString(&sz_buf) catch return error.BufferOverflow;
    try p.packStr(sz_str);

    // r: reduce_only
    try p.packStr("r");
    try p.packBool(order.reduce_only);

    // t: order_type (tagged union)
    try p.packStr("t");
    switch (order.order_type) {
        .limit => |lim| {
            try p.packMapHeader(1);
            try p.packStr("limit");
            try p.packMapHeader(1);
            try p.packStr("tif");
            try p.packStr(@tagName(lim.tif));
        },
        .trigger => |trig| {
            try p.packMapHeader(1);
            try p.packStr("trigger");
            try p.packMapHeader(3);
            try p.packStr("isMarket");
            try p.packBool(trig.is_market);
            try p.packStr("triggerPx");
            var tpx_buf: [64]u8 = undefined;
            const tpx_str = trig.trigger_px.normalize().toString(&tpx_buf) catch return error.BufferOverflow;
            try p.packStr(tpx_str);
            try p.packStr("tpsl");
            try p.packStr(@tagName(trig.tpsl));
        },
    }

    // c: cloid (hex string)
    try p.packStr("c");
    const cloid_hex = cloidToHex(order.cloid);
    try p.packStr(&cloid_hex);
}

/// Pack a BatchOrder to msgpack.
pub fn packBatchOrder(p: *msgpack.Packer, batch: BatchOrder) msgpack.PackError!void {
    try p.packMapHeader(2);

    // orders: array of OrderRequest
    try p.packStr("orders");
    try p.packArrayHeader(@intCast(batch.orders.len));
    for (batch.orders) |order| {
        try packOrderRequest(p, order);
    }

    // grouping: enum string
    try p.packStr("grouping");
    try p.packStr(@tagName(batch.grouping));
}

/// Pack a Cancel to msgpack.
pub fn packCancel(p: *msgpack.Packer, cancel: Cancel) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("a");
    try p.packUint(@intCast(cancel.asset));
    try p.packStr("o");
    try p.packUint(cancel.oid);
}

/// Pack a BatchCancel to msgpack.
pub fn packBatchCancel(p: *msgpack.Packer, batch: BatchCancel) msgpack.PackError!void {
    try p.packMapHeader(1);
    try p.packStr("cancels");
    try p.packArrayHeader(@intCast(batch.cancels.len));
    for (batch.cancels) |cancel| {
        try packCancel(p, cancel);
    }
}

// The Rust SDK uses #[serde(tag = "type")] on the Action enum.
// This means msgpack output includes a "type" field with the variant name.

/// Action tags matching Rust's serde tag names (camelCase).
pub const ActionTag = enum {
    order,
    batchModify,
    cancel,
    cancelByCloid,
    scheduleCancel,
    usdSend,
    sendAsset,
    spotSend,
    evmUserModify,
    approveAgent,
    convertToMultiSigUser,
    updateIsolatedMargin,
    updateLeverage,
    setReferrer,
    multiSig,
    noop,

};

/// Pack an Action::Order to msgpack (with serde tag = "type").
/// Output: {"type": "order", "orders": [...], "grouping": "na"}
pub fn packActionOrder(p: *msgpack.Packer, batch: BatchOrder) msgpack.PackError!void {
    try p.packMapHeader(3); // type + orders + grouping

    // type: "order"
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.order));

    // orders: array
    try p.packStr("orders");
    try p.packArrayHeader(@intCast(batch.orders.len));
    for (batch.orders) |order| {
        try packOrderRequest(p, order);
    }

    // grouping: enum string
    try p.packStr("grouping");
    try p.packStr(@tagName(batch.grouping));
}

/// Pack an Action::Cancel to msgpack (with serde tag).
pub fn packActionCancel(p: *msgpack.Packer, batch: BatchCancel) msgpack.PackError!void {
    try p.packMapHeader(2); // type + cancels

    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.cancel));

    try p.packStr("cancels");
    try p.packArrayHeader(@intCast(batch.cancels.len));
    for (batch.cancels) |cancel| {
        try packCancel(p, cancel);
    }
}

/// Pack a CancelByCloid to msgpack.
fn packCancelByCloid(p: *msgpack.Packer, cancel: CancelByCloid) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("asset");
    try p.packUint(@intCast(cancel.asset));
    try p.packStr("cloid");
    const hex = cloidToHex(cancel.cloid);
    try p.packStr(&hex);
}

/// Pack an Action::CancelByCloid to msgpack (with serde tag).
pub fn packActionCancelByCloid(p: *msgpack.Packer, batch: BatchCancelCloid) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.cancelByCloid));
    try p.packStr("cancels");
    try p.packArrayHeader(@intCast(batch.cancels.len));
    for (batch.cancels) |cancel| {
        try packCancelByCloid(p, cancel);
    }
}

/// Pack a Modify to msgpack.
fn packModify(p: *msgpack.Packer, modify: Modify) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("oid");
    switch (modify.oid) {
        .oid => |oid| try p.packUint(oid),
        .cloid => |cloid| {
            const hex = cloidToHex(cloid);
            try p.packStr(&hex);
        },
    }
    try p.packStr("order");
    try packOrderRequest(p, modify.order);
}

/// Pack an Action::BatchModify to msgpack (with serde tag).
pub fn packActionBatchModify(p: *msgpack.Packer, batch: BatchModify) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.batchModify));
    try p.packStr("modifies");
    try p.packArrayHeader(@intCast(batch.modifies.len));
    for (batch.modifies) |modify| {
        try packModify(p, modify);
    }
}

/// Pack an Action::ScheduleCancel to msgpack (with serde tag).
pub fn packActionScheduleCancel(p: *msgpack.Packer, sc: ScheduleCancel) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.scheduleCancel));
    try p.packStr("time");
    if (sc.time) |t| {
        try p.packUint(t);
    } else {
        try p.packNil();
    }
}

/// Pack an Action::UpdateIsolatedMargin to msgpack (with serde tag).
pub fn packActionUpdateIsolatedMargin(p: *msgpack.Packer, uim: UpdateIsolatedMargin) msgpack.PackError!void {
    try p.packMapHeader(4);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.updateIsolatedMargin));
    try p.packStr("asset");
    try p.packUint(@intCast(uim.asset));
    try p.packStr("isBuy");
    try p.packBool(uim.is_buy);
    try p.packStr("ntli");
    try p.packUint(uim.ntli);
}

/// Pack an Action::UpdateLeverage to msgpack (with serde tag).
pub fn packActionUpdateLeverage(p: *msgpack.Packer, ul: UpdateLeverage) msgpack.PackError!void {
    try p.packMapHeader(4);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.updateLeverage));
    try p.packStr("asset");
    try p.packUint(@intCast(ul.asset));
    try p.packStr("isCross");
    try p.packBool(ul.is_cross);
    try p.packStr("leverage");
    try p.packUint(@intCast(ul.leverage));
}

/// Pack an Action::SetReferrer to msgpack (with serde tag).
pub fn packActionSetReferrer(p: *msgpack.Packer, sr: SetReferrer) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.setReferrer));
    try p.packStr("code");
    try p.packStr(sr.code);
}

/// Pack an Action::EvmUserModify to msgpack (with serde tag).
pub fn packActionEvmUserModify(p: *msgpack.Packer, using_big_blocks: bool) msgpack.PackError!void {
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.evmUserModify));
    try p.packStr("usingBigBlocks");
    try p.packBool(using_big_blocks);
}

/// Pack an Action::Noop to msgpack (with serde tag).
pub fn packActionNoop(p: *msgpack.Packer) msgpack.PackError!void {
    try p.packMapHeader(1);
    try p.packStr("type");
    try p.packStr(@tagName(ActionTag.noop));
}


test "cloidToHex: zero cloid" {
    const hex = cloidToHex(ZERO_CLOID);
    try std.testing.expectEqualStrings("0x00000000000000000000000000000000", &hex);
}

test "packActionOrder: matches Rust Action::Order msgpack vector" {
    // From rust_vectors.json: action_order_msgpack_hex (112 bytes)
    // This is the Action with serde tag, which is what actually gets hashed for signing
    const expected_hex = "83a474797065a56f72646572a66f72646572739187a16100a162c3a170a53530303030a173a3302e31a172c2a17481a56c696d697481a3746966a3477463a163d92230783030303030303030303030303030303030303030303030303030303030303030a867726f7570696e67a26e61";

    var expected: [112]u8 = undefined;
    for (0..112) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const order = OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = ZERO_CLOID,
    };

    const batch = BatchOrder{
        .orders = &[_]OrderRequest{order},
        .grouping = .na,
    };

    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packActionOrder(&p, batch);

    try std.testing.expectEqualSlices(u8, &expected, p.written());
}

test "packBatchOrder: matches Rust msgpack vector" {
    // From rust_vectors.json: order_msgpack_hex
    const expected_hex = "82a66f72646572739187a16100a162c3a170a53530303030a173a3302e31a172c2a17481a56c696d697481a3746966a3477463a163d92230783030303030303030303030303030303030303030303030303030303030303030a867726f7570696e67a26e61";

    var expected: [101]u8 = undefined;
    for (0..101) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const order = OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = ZERO_CLOID,
    };

    const batch = BatchOrder{
        .orders = &[_]OrderRequest{order},
        .grouping = .na,
    };

    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try packBatchOrder(&p, batch);

    try std.testing.expectEqualSlices(u8, &expected, p.written());
}
