const std = @import("std");
const hlz = @import("hlz");

const client_mod = hlz.hypercore.client;
const response_mod = hlz.hypercore.response;
const signing = hlz.hypercore.signing;
const types = hlz.hypercore.types;
const msgpack = hlz.encoding.msgpack;
const Signer = hlz.crypto.signer.Signer;
const Decimal = hlz.math.decimal.Decimal;

const READ_ONLY_USER = "0xe0e8c1d735698060477e79a8e4c20276fc2ec7a7";
const ETH_ASSET_INDEX: usize = 1;
const VECTOR_NONCE: u64 = 1700000000123;

// Fill these by running the Rust reference test (reference/tests/e2e_vectors.rs).
const EXPECTED_ETH_ORDER_ACTION_MSGPACK_HEX: ?[]const u8 = "0x83a474797065a56f72646572a66f72646572739187a16101a162c3a170a131a173a5302e303031a172c2a17481a56c696d697481a3746966a3477463a163d92230783030303030303030303030303030303030303030303030303030303030303030a867726f7570696e67a26e61";
const EXPECTED_ETH_ORDER_RMP_HASH_HEX: ?[]const u8 = "0xdefa6e8e4a1b596b8936279962f05cf5a58ee69921047e573d36d101c0e6bb7e";
const EXPECTED_ETH_ORDER_SIGNATURE_HEX: ?[]const u8 = "0xb4ae7acb2dc7a30cd3a80887adddf73a719193f54f3b59e1627e197e19282eb515189d2dfeeb875265e0978da0e695a72ed29fe6d3cd099beafed3727a1c9c991b";

const CheckKind = enum { pass, fail, skip };

const Counts = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn total(self: Counts) usize {
        return self.passed + self.failed + self.skipped;
    }
};

fn record(kind: CheckKind, counts: *Counts, endpoint: []const u8, status_code: ?u16, body: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    switch (kind) {
        .pass => counts.passed += 1,
        .fail => counts.failed += 1,
        .skip => counts.skipped += 1,
    }

    const tag = switch (kind) {
        .pass => "PASS",
        .fail => "FAIL",
        .skip => "SKIP",
    };

    var preview_buf: [200]u8 = undefined;
    const preview = if (body) |b| sanitizePreview(&preview_buf, b) else "";

    if (status_code) |code| {
        std.debug.print("[{s}] {s}: {d}", .{ tag, endpoint, code });
    } else {
        std.debug.print("[{s}] {s}", .{ tag, endpoint });
    }

    if (body) |b| {
        std.debug.print(", {d} bytes", .{b.len});
    }

    std.debug.print(", ", .{});
    std.debug.print(fmt, args);

    if (body != null) {
        std.debug.print(", preview=\"{s}\"", .{preview});
    }
    std.debug.print("\n", .{});
}

fn sanitizePreview(buf: []u8, body: []const u8) []const u8 {
    const n = @min(buf.len, body.len);
    for (body[0..n], 0..) |c, i| {
        buf[i] = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
    }
    return buf[0..n];
}

fn statusCode(status: std.http.Status) u16 {
    return @intCast(@intFromEnum(status));
}

fn nowMillis() u64 {
    return @intCast(std.time.milliTimestamp());
}

fn hasKey(obj: std.json.Value, key: []const u8) bool {
    return obj == .object and obj.object.get(key) != null;
}

fn mustParseJsonInfo(result: *client_mod.Client.InfoResult) !std.json.Value {
    if (result.status != .ok) return error.UnexpectedHttpStatus;
    return result.json();
}

fn assertAllMidsShape(v: std.json.Value) !void {
    if (v != .object) return error.ExpectedObject;
    if (v.object.count() == 0) return error.EmptyObject;

    var it = v.object.iterator();
    var checked_any = false;
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        if (val != .string) return error.ExpectedStringValue;
        _ = Decimal.fromString(val.string) catch return error.InvalidDecimal;
        checked_any = true;
        if (checked_any) break;
    }
    if (!checked_any) return error.EmptyObject;

    const btc = v.object.get("BTC") orelse return error.MissingBTC;
    const eth = v.object.get("ETH") orelse return error.MissingETH;
    if (btc != .string or eth != .string) return error.ExpectedStringValue;
    _ = Decimal.fromString(btc.string) catch return error.InvalidDecimal;
    _ = Decimal.fromString(eth.string) catch return error.InvalidDecimal;
}

fn assertPerpsShape(v: std.json.Value) !void {
    if (v == .array and v.array.items.len > 0) {
        const first = v.array.items[0];
        if (!hasKey(first, "universe")) return error.MissingUniverse;
        return;
    }
    if (v == .object and hasKey(v, "universe")) return;
    return error.ExpectedMetaShape;
}

fn assertSpotShape(v: std.json.Value) !void {
    if (v != .object) return error.ExpectedObject;
    if (!hasKey(v, "tokens")) return error.MissingTokens;
    if (!hasKey(v, "universe")) return error.MissingUniverse;
}

fn assertArray(v: std.json.Value) ![]const std.json.Value {
    if (v != .array) return error.ExpectedArray;
    return v.array.items;
}

fn verifyClearinghouseState(v: std.json.Value) !void {
    const state = response_mod.ClearinghouseState.fromJson(v) orelse return error.ParseFailed;
    const ms = state.margin_summary orelse return error.MissingMarginSummary;
    if (ms.account_value == null) return error.MissingAccountValue;
}

fn verifyOpenOrders(v: std.json.Value) !void {
    const arr = try assertArray(v);
    if (arr.len == 0) return;
    const order = response_mod.BasicOrder.fromJson(arr[0]) orelse return error.ParseFailed;
    if (order.limit_px == null or order.sz == null) return error.MissingOrderFields;
}

fn verifyUserFills(v: std.json.Value) !void {
    const arr = try assertArray(v);
    if (arr.len == 0) return;
    const fill = response_mod.Fill.fromJson(arr[0]) orelse return error.ParseFailed;
    if (fill.coin.len == 0 or fill.px == null or fill.sz == null) return error.MissingFillFields;
}

fn verifyCandleSnapshot(v: std.json.Value) !void {
    const arr = try assertArray(v);
    if (arr.len == 0) return;
    const candle = response_mod.Candle.fromJson(arr[0]) orelse return error.ParseFailed;
    if (candle.open == null or candle.high == null or candle.low == null or candle.close == null or candle.volume == null) {
        return error.MissingCandleFields;
    }
}

fn verifyUserRole(v: std.json.Value) !void {
    _ = response_mod.UserRole.fromJson(v) orelse return error.ParseFailed;
}

fn verifySpotBalances(v: std.json.Value) !void {
    // API returns {"balances": [...]}
    if (v == .object) {
        if (v.object.get("balances")) |balances| {
            const arr = try assertArray(balances);
            if (arr.len == 0) return;
            _ = response_mod.UserBalance.fromJson(arr[0]) orelse return error.ParseFailed;
            return;
        }
    }
    // Fallback: direct array
    const arr = try assertArray(v);
    if (arr.len == 0) return;
    _ = response_mod.UserBalance.fromJson(arr[0]) orelse return error.ParseFailed;
}

fn verifyHistoricalOrders(v: std.json.Value) !void {
    const arr = try assertArray(v);
    if (arr.len == 0) return;
    _ = response_mod.OrderUpdate.fromJson(arr[0]) orelse return error.ParseFailed;
}

fn verifyFundingHistory(v: std.json.Value) !void {
    const arr = try assertArray(v);
    if (arr.len == 0) return;
    _ = response_mod.FundingRate.fromJson(arr[0]) orelse return error.ParseFailed;
}

fn runInfoChecks(allocator: std.mem.Allocator, counts: *Counts) !void {
    var client = client_mod.Client.mainnet(allocator);
    defer client.deinit();

    const now_ms = nowMillis();
    const day_ms: u64 = 24 * 60 * 60 * 1000;
    const start_ms = now_ms - day_ms;

    // allMids
    all_mids_blk: {
        var res = client.allMids(null) catch |err| {
            record(.fail, counts, "mainnet/info/allMids", null, null, "request error={s}", .{@errorName(err)});
            break :all_mids_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/allMids", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :all_mids_blk;
        };
        if (assertAllMidsShape(v)) |_| {
            record(.pass, counts, "mainnet/info/allMids", statusCode(res.status), res.body, "shape ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/allMids", statusCode(res.status), res.body, "shape error={s}", .{@errorName(err)});
        }
    }

    // perps
    perps_blk: {
        var res = client.perps(null) catch |err| {
            record(.fail, counts, "mainnet/info/perps", null, null, "request error={s}", .{@errorName(err)});
            break :perps_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/perps", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :perps_blk;
        };
        if (assertPerpsShape(v)) |_| {
            record(.pass, counts, "mainnet/info/perps", statusCode(res.status), res.body, "shape ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/perps", statusCode(res.status), res.body, "shape error={s}", .{@errorName(err)});
        }
    }

    // perpDexs
    perp_dexs_blk: {
        var res = client.perpDexs() catch |err| {
            record(.fail, counts, "mainnet/info/perpDexs", null, null, "request error={s}", .{@errorName(err)});
            break :perp_dexs_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/perpDexs", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :perp_dexs_blk;
        };
        if (assertArray(v)) |arr| {
            _ = arr;
            record(.pass, counts, "mainnet/info/perpDexs", statusCode(res.status), res.body, "array ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/perpDexs", statusCode(res.status), res.body, "shape error={s}", .{@errorName(err)});
        }
    }

    // spot
    spot_blk: {
        var res = client.spot() catch |err| {
            record(.fail, counts, "mainnet/info/spot", null, null, "request error={s}", .{@errorName(err)});
            break :spot_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/spot", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :spot_blk;
        };
        if (assertSpotShape(v)) |_| {
            record(.pass, counts, "mainnet/info/spot", statusCode(res.status), res.body, "shape ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/spot", statusCode(res.status), res.body, "shape error={s}", .{@errorName(err)});
        }
    }

    clearinghouse_blk: {
        var res = client.clearinghouseState(READ_ONLY_USER, null) catch |err| {
            record(.fail, counts, "mainnet/info/clearinghouseState", null, null, "request error={s}", .{@errorName(err)});
            break :clearinghouse_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/clearinghouseState", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :clearinghouse_blk;
        };
        if (verifyClearinghouseState(v)) |_| {
            record(.pass, counts, "mainnet/info/clearinghouseState", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/clearinghouseState", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    spot_balances_blk: {
        var res = client.spotBalances(READ_ONLY_USER) catch |err| {
            record(.fail, counts, "mainnet/info/spotBalances", null, null, "request error={s}", .{@errorName(err)});
            break :spot_balances_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/spotBalances", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :spot_balances_blk;
        };
        if (verifySpotBalances(v)) |_| {
            record(.pass, counts, "mainnet/info/spotBalances", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/spotBalances", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    open_orders_blk: {
        var res = client.openOrders(READ_ONLY_USER, null) catch |err| {
            record(.fail, counts, "mainnet/info/openOrders", null, null, "request error={s}", .{@errorName(err)});
            break :open_orders_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/openOrders", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :open_orders_blk;
        };
        if (verifyOpenOrders(v)) |_| {
            record(.pass, counts, "mainnet/info/openOrders", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/openOrders", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    user_fills_blk: {
        var res = client.userFills(READ_ONLY_USER) catch |err| {
            record(.fail, counts, "mainnet/info/userFills", null, null, "request error={s}", .{@errorName(err)});
            break :user_fills_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/userFills", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :user_fills_blk;
        };
        if (verifyUserFills(v)) |_| {
            record(.pass, counts, "mainnet/info/userFills", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/userFills", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    historical_orders_blk: {
        var res = client.historicalOrders(READ_ONLY_USER) catch |err| {
            record(.fail, counts, "mainnet/info/historicalOrders", null, null, "request error={s}", .{@errorName(err)});
            break :historical_orders_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/historicalOrders", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :historical_orders_blk;
        };
        if (verifyHistoricalOrders(v)) |_| {
            record(.pass, counts, "mainnet/info/historicalOrders", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/historicalOrders", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    user_role_blk: {
        var res = client.userRole(READ_ONLY_USER) catch |err| {
            record(.fail, counts, "mainnet/info/userRole", null, null, "request error={s}", .{@errorName(err)});
            break :user_role_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/userRole", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :user_role_blk;
        };
        if (verifyUserRole(v)) |_| {
            record(.pass, counts, "mainnet/info/userRole", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/userRole", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    // fundingHistory
    funding_history_blk: {
        var res = client.fundingHistory("ETH", start_ms, null) catch |err| {
            record(.fail, counts, "mainnet/info/fundingHistory", null, null, "request error={s}", .{@errorName(err)});
            break :funding_history_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/fundingHistory", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :funding_history_blk;
        };
        if (verifyFundingHistory(v)) |_| {
            record(.pass, counts, "mainnet/info/fundingHistory", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/fundingHistory", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }

    // candleSnapshot
    candle_snapshot_blk: {
        var res = client.candleSnapshot("ETH", "1h", start_ms, now_ms) catch |err| {
            record(.fail, counts, "mainnet/info/candleSnapshot", null, null, "request error={s}", .{@errorName(err)});
            break :candle_snapshot_blk;
        };
        defer res.deinit();
        const v = mustParseJsonInfo(&res) catch |err| {
            record(.fail, counts, "mainnet/info/candleSnapshot", statusCode(res.status), res.body, "json/parse error={s}", .{@errorName(err)});
            break :candle_snapshot_blk;
        };
        if (verifyCandleSnapshot(v)) |_| {
            record(.pass, counts, "mainnet/info/candleSnapshot", statusCode(res.status), res.body, "parse ok", .{});
        } else |err| {
            record(.fail, counts, "mainnet/info/candleSnapshot", statusCode(res.status), res.body, "parse error={s}", .{@errorName(err)});
        }
    }
}

fn formatHexPrefixed(buf: []u8, bytes: []const u8) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[2 + i * 2] = charset[b >> 4];
        buf[2 + i * 2 + 1] = charset[b & 0x0f];
    }
    return buf[0 .. 2 + bytes.len * 2];
}

fn runSigningVectorCheck(counts: *Counts) !void {
    const endpoint = "mainnet/signing/order_eth_vector";

    if (EXPECTED_ETH_ORDER_ACTION_MSGPACK_HEX == null or EXPECTED_ETH_ORDER_RMP_HASH_HEX == null or EXPECTED_ETH_ORDER_SIGNATURE_HEX == null) {
        record(.skip, counts, endpoint, null, null, "Rust ETH vector constants not filled yet", .{});
        return;
    }

    const key = try maybeLoadTradingKey(std.heap.page_allocator);
    defer if (key) |k| std.heap.page_allocator.free(k);

    if (key == null) {
        record(.skip, counts, endpoint, null, null, "TRADING_KEY missing in .env", .{});
        return;
    }

    const signer = Signer.fromHex(key.?) catch |err| {
        record(.fail, counts, endpoint, null, null, "invalid TRADING_KEY ({s})", .{@errorName(err)});
        return;
    };

    var orders = [_]types.OrderRequest{types.OrderRequest{
        .asset = ETH_ASSET_INDEX,
        .is_buy = true,
        .limit_px = try Decimal.fromString("1"),
        .sz = try Decimal.fromString("0.001"),
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    }};
    const batch = types.BatchOrder{ .orders = orders[0..], .grouping = .na };

    var pack_buf: [512]u8 = undefined;
    var packer = msgpack.Packer.init(&pack_buf);
    try types.packActionOrder(&packer, batch);
    const action_msgpack = packer.written();

    const rmp_hash = try signing.rmpHashOrder(batch, VECTOR_NONCE, null, null);
    const sig = try signing.signOrder(signer, batch, VECTOR_NONCE, .mainnet, null, null);
    const sig_bytes = sig.toEthBytes();

    var msgpack_hex_buf: [2 + 512 * 2]u8 = undefined;
    var hash_hex_buf: [66]u8 = undefined;
    var sig_hex_buf: [132]u8 = undefined;
    const msgpack_hex = formatHexPrefixed(&msgpack_hex_buf, action_msgpack);
    const hash_hex = formatHexPrefixed(&hash_hex_buf, &rmp_hash);
    const sig_hex = formatHexPrefixed(&sig_hex_buf, &sig_bytes);

    std.debug.print("[INFO] {s}: nonce={d}\n", .{ endpoint, VECTOR_NONCE });
    std.debug.print("[INFO] {s}: action_msgpack_hex={s}\n", .{ endpoint, msgpack_hex });
    std.debug.print("[INFO] {s}: rmp_hash_hex={s}\n", .{ endpoint, hash_hex });
    std.debug.print("[INFO] {s}: signature_hex={s}\n", .{ endpoint, sig_hex });

    const msgpack_ok = std.mem.eql(u8, msgpack_hex, EXPECTED_ETH_ORDER_ACTION_MSGPACK_HEX.?);
    const hash_ok = std.mem.eql(u8, hash_hex, EXPECTED_ETH_ORDER_RMP_HASH_HEX.?);
    const sig_ok = std.mem.eql(u8, sig_hex, EXPECTED_ETH_ORDER_SIGNATURE_HEX.?);

    if (msgpack_ok and hash_ok and sig_ok) {
        record(.pass, counts, endpoint, null, null, "msgpack/rmpHash/signature match Rust", .{});
    } else {
        record(.fail, counts, endpoint, null, null, "msgpack={any} hash={any} sig={any}", .{ msgpack_ok, hash_ok, sig_ok });
    }
}

fn maybeLoadTradingKey(allocator: std.mem.Allocator) !?[]u8 {
    const file = std.fs.cwd().readFileAlloc(allocator, ".env", 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(file);

    var it = std.mem.tokenizeAny(u8, file, "\r\n");
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "TRADING_KEY=")) continue;
        var value = std.mem.trim(u8, line["TRADING_KEY=".len..], " \t\"");
        if (value.len == 0) return null;
        if (std.mem.indexOfScalar(u8, value, '#')) |idx| {
            value = std.mem.trimRight(u8, value[0..idx], " \t");
        }
        if (value.len == 0) return null;
        return try allocator.dupe(u8, value);
    }

    return null;
}

fn extractOidFromPlace(result: *client_mod.Client.ExchangeResult) !?u64 {
    const v = try result.json();
    const statuses = try response_mod.parseOrderStatuses(result.allocator, v);
    defer if (statuses.len > 0) result.allocator.free(statuses);
    for (statuses) |st| switch (st) {
        .resting => |r| return r.oid,
        .filled => |f| return f.oid,
        else => {},
    };
    return null;
}

fn exchangeStatusIsMeaningful(result: *client_mod.Client.ExchangeResult) !bool {
    const v = try result.json();
    return switch (response_mod.parseResponseStatus(v)) {
        .ok, .err => true,
        else => false,
    };
}

fn runExchangeChecks(allocator: std.mem.Allocator, counts: *Counts) !void {
    const key = try maybeLoadTradingKey(allocator);
    defer if (key) |k| allocator.free(k);

    if (key == null) {
        record(.skip, counts, "mainnet/exchange", null, null, "No .env TRADING_KEY found; skipping exchange endpoints", .{});
        return;
    }

    const signer = Signer.fromHex(key.?) catch |err| {
        record(.fail, counts, "mainnet/exchange", null, null, "invalid TRADING_KEY ({s})", .{@errorName(err)});
        return;
    };

    var client = client_mod.Client.mainnet(allocator);
    defer client.deinit();

    var nonce_handler = response_mod.NonceHandler.init();

    const cloid = blk: {
        var c: [16]u8 = [_]u8{0} ** 16;
        const ts: u64 = @intCast(std.time.milliTimestamp());
        std.mem.writeInt(u64, c[8..16], ts, .big);
        c[0] = 0x01;
        break :blk c;
    };
    var orders = [_]types.OrderRequest{types.OrderRequest{
        .asset = ETH_ASSET_INDEX,
        .is_buy = true,
        .limit_px = try Decimal.fromString("1500"),
        .sz = try Decimal.fromString("0.01"),
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = cloid,
    }};
    const batch = types.BatchOrder{ .orders = orders[0..], .grouping = .na };

    var placed_oid: ?u64 = null;

    // place
    place_blk: {
        const nonce = nonce_handler.next();
        var res = client.place(signer, batch, nonce, null, null) catch |err| {
            record(.fail, counts, "mainnet/exchange/place", null, null, "request error={s}", .{@errorName(err)});
            break :place_blk;
        };
        defer res.deinit();

        const meaningful = exchangeStatusIsMeaningful(&res) catch |err| {
            record(.fail, counts, "mainnet/exchange/place", statusCode(res.status), res.body, "json error={s}", .{@errorName(err)});
            break :place_blk;
        };
        placed_oid = extractOidFromPlace(&res) catch null;

        if (meaningful) {
            if (placed_oid) |oid| {
                record(.pass, counts, "mainnet/exchange/place", statusCode(res.status), res.body, "parsed response, oid={d}", .{oid});
            } else {
                record(.pass, counts, "mainnet/exchange/place", statusCode(res.status), res.body, "meaningful response (no oid)", .{});
            }
        } else {
            record(.fail, counts, "mainnet/exchange/place", statusCode(res.status), res.body, "unexpected exchange status", .{});
        }
    }

    // cancel (only if we got an oid)
    if (placed_oid) |oid| {
        var cancels = [_]types.Cancel{.{ .asset = ETH_ASSET_INDEX, .oid = oid }};
        const cancel_batch = types.BatchCancel{ .cancels = cancels[0..] };
        const nonce = nonce_handler.next();

        cancel_blk: {
            var res = client.cancel(signer, cancel_batch, nonce, null, null) catch |err| {
                record(.fail, counts, "mainnet/exchange/cancel", null, null, "request error={s}", .{@errorName(err)});
                break :cancel_blk;
            };
            defer res.deinit();

            const meaningful = exchangeStatusIsMeaningful(&res) catch |err| {
                record(.fail, counts, "mainnet/exchange/cancel", statusCode(res.status), res.body, "json error={s}", .{@errorName(err)});
                break :cancel_blk;
            };
            if (meaningful) {
                record(.pass, counts, "mainnet/exchange/cancel", statusCode(res.status), res.body, "meaningful response", .{});
            } else {
                record(.fail, counts, "mainnet/exchange/cancel", statusCode(res.status), res.body, "unexpected exchange status", .{});
            }
        }
    } else {
        record(.skip, counts, "mainnet/exchange/cancel", null, null, "place() did not return oid", .{});
    }

    // noop
    noop_blk: {
        const nonce = nonce_handler.next();
        var res = client.noop(signer, nonce, null, null) catch |err| {
            record(.fail, counts, "mainnet/exchange/noop", null, null, "request error={s}", .{@errorName(err)});
            break :noop_blk;
        };
        defer res.deinit();

        const meaningful = exchangeStatusIsMeaningful(&res) catch |err| {
            record(.fail, counts, "mainnet/exchange/noop", statusCode(res.status), res.body, "json error={s}", .{@errorName(err)});
            break :noop_blk;
        };
        if (meaningful) {
            record(.pass, counts, "mainnet/exchange/noop", statusCode(res.status), res.body, "meaningful response", .{});
        } else {
            record(.fail, counts, "mainnet/exchange/noop", statusCode(res.status), res.body, "unexpected exchange status", .{});
        }
    }

    // scheduleCancel(time=null)
    schedule_cancel_blk: {
        const nonce = nonce_handler.next();
        var res = client.scheduleCancel(signer, .{ .time = null }, nonce, null, null) catch |err| {
            record(.fail, counts, "mainnet/exchange/scheduleCancel", null, null, "request error={s}", .{@errorName(err)});
            break :schedule_cancel_blk;
        };
        defer res.deinit();

        const meaningful = exchangeStatusIsMeaningful(&res) catch |err| {
            record(.fail, counts, "mainnet/exchange/scheduleCancel", statusCode(res.status), res.body, "json error={s}", .{@errorName(err)});
            break :schedule_cancel_blk;
        };
        if (meaningful) {
            record(.pass, counts, "mainnet/exchange/scheduleCancel", statusCode(res.status), res.body, "meaningful response", .{});
        } else {
            record(.fail, counts, "mainnet/exchange/scheduleCancel", statusCode(res.status), res.body, "unexpected exchange status", .{});
        }
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_state.deinit();
        if (leaked == .leak) std.debug.print("[WARN] allocator reported leaks\n", .{});
    }
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var offline = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--offline")) offline = true;
    }

    var counts = Counts{};

    try runSigningVectorCheck(&counts);

    if (offline) {
        record(.skip, &counts, "mainnet/info", null, null, "offline mode", .{});
        record(.skip, &counts, "mainnet/exchange", null, null, "offline mode", .{});
    } else {
        runInfoChecks(allocator, &counts) catch |err| {
            record(.fail, &counts, "mainnet/info", null, null, "fatal error={s}", .{@errorName(err)});
        };
        runExchangeChecks(allocator, &counts) catch |err| {
            record(.fail, &counts, "mainnet/exchange", null, null, "fatal error={s}", .{@errorName(err)});
        };
    }

    std.debug.print(
        "Summary: {d}/{d} passed ({d} failed, {d} skipped)\n",
        .{ counts.passed, counts.total(), counts.failed, counts.skipped },
    );

    if (counts.failed != 0) return error.EndToEndChecksFailed;
}
