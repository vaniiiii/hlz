//! JSON parsing utilities for Hyperliquid API responses.
//!
//! Uses Zig's stdlib JSON parser with helpers for common patterns:
//! - Decimal fields (parsed from string)
//! - Optional fields
//! - Enum variants (camelCase)

const std = @import("std");
const Decimal = @import("../math/decimal.zig").Decimal;

pub const ParseError = error{
    JsonParseFailed,
    MissingField,
    InvalidType,
    InvalidDecimal,
    BufferOverflow,
};

/// Parse a JSON string into a std.json.Value tree.
/// Caller owns the returned Parsed and must call deinit().
pub fn parse(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_str, .{
        .allocate = .alloc_always,
    });
}

/// Get a string field from a JSON object.
pub fn getString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// Get an integer field from a JSON object.
pub fn getInt(comptime T: type, obj: std.json.Value, key: []const u8) ?T {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .integer => |i| std.math.cast(T, i),
        .number_string => |s| std.fmt.parseInt(T, s, 10) catch null,
        else => null,
    };
}

/// Get a float field from a JSON object (for API responses that return numbers).
pub fn getFloat(obj: std.json.Value, key: []const u8) ?f64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Get a boolean field from a JSON object.
pub fn getBool(obj: std.json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

/// Get a Decimal field from a JSON object (expects string value).
pub fn getDecimal(obj: std.json.Value, key: []const u8) ?Decimal {
    const str = getString(obj, key) orelse return null;
    return Decimal.fromString(str) catch null;
}

/// Get an array field from a JSON object.
pub fn getArray(obj: std.json.Value, key: []const u8) ?[]const std.json.Value {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .array) return null;
    return val.array.items;
}

/// Get an object field from a JSON object.
pub fn getObject(obj: std.json.Value, key: []const u8) ?std.json.Value {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .object) return null;
    return val;
}

// ── Tests ─────────────────────────────────────────────────────────

test "parse and extract fields" {
    const json_str =
        \\{"coin":"BTC","px":"50000.5","sz":"0.1","oid":12345,"crossed":true}
    ;

    var parsed = try parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const obj = parsed.value;

    try std.testing.expectEqualStrings("BTC", getString(obj, "coin").?);
    try std.testing.expectEqual(@as(u64, 12345), getInt(u64, obj, "oid").?);
    try std.testing.expectEqual(true, getBool(obj, "crossed").?);

    const px = getDecimal(obj, "px").?;
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("50000.5", try px.toString(&buf));
}

test "missing fields return null" {
    const json_str =
        \\{"coin":"BTC"}
    ;

    var parsed = try parse(std.testing.allocator, json_str);
    defer parsed.deinit();
    const obj = parsed.value;

    try std.testing.expectEqual(@as(?u64, null), getInt(u64, obj, "oid"));
    try std.testing.expectEqual(@as(?bool, null), getBool(obj, "crossed"));
}
