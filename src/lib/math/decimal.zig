//! Fixed-point Decimal type for Hyperliquid price/size calculations.
//! i128 mantissa + u8 scale. normalize() matches rust_decimal output.

const std = @import("std");

/// Maximum scale (decimal places). rust_decimal supports 28.
const MAX_SCALE: u8 = 28;

/// A fixed-point decimal number: value = mantissa × 10^(-scale)
pub const Decimal = struct {
    /// The unscaled integer value. E.g., for 123.45, mantissa = 12345
    mantissa: i128,
    /// Number of decimal places. E.g., for 123.45, scale = 2
    scale: u8,

    pub const ZERO = Decimal{ .mantissa = 0, .scale = 0 };
    pub const ONE = Decimal{ .mantissa = 1, .scale = 0 };
    pub const TWO = Decimal{ .mantissa = 2, .scale = 0 };

    /// Parse a decimal from a string like "123.456", "-0.1", "10".
    pub fn fromString(s: []const u8) !Decimal {
        if (s.len == 0) return error.InvalidDecimal;

        var i: usize = 0;
        var negative = false;

        if (s[i] == '-') {
            negative = true;
            i += 1;
        } else if (s[i] == '+') {
            i += 1;
        }

        if (i >= s.len) return error.InvalidDecimal;

        var mantissa: i128 = 0;
        var scale: u8 = 0;
        var seen_dot = false;
        var has_digits = false;

        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '.') {
                if (seen_dot) return error.InvalidDecimal;
                seen_dot = true;
                continue;
            }
            if (c < '0' or c > '9') return error.InvalidDecimal;
            has_digits = true;

            // Check overflow before multiply
            if (mantissa > std.math.maxInt(i128) / 10) return error.Overflow;
            mantissa = mantissa * 10 + (c - '0');

            if (seen_dot) {
                scale += 1;
                if (scale > MAX_SCALE) return error.Overflow;
            }
        }

        if (!has_digits) return error.InvalidDecimal;
        if (negative) mantissa = -mantissa;

        return .{ .mantissa = mantissa, .scale = scale };
    }

    /// Hook for std.json.parseFromSlice (streaming token parser).
    pub fn jsonParse(
        _: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Decimal {
        const token = try source.nextAllocMax(
            std.heap.page_allocator,
            .alloc_if_needed,
            options.max_value_len orelse 256,
        );
        const slice = switch (token) {
            .number, .allocated_number, .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return Decimal.fromString(slice) catch return error.Overflow;
    }

    /// Hook for std.json.parseFromValue (pre-parsed Value tree).
    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Decimal {
        const s = switch (source) {
            .string => |v| v,
            .number_string => |v| v,
            else => return error.UnexpectedToken,
        };
        return Decimal.fromString(s) catch return error.InvalidNumber;
    }

    /// Format decimal to string in caller-provided buffer.
    /// Returns the written slice.
    pub fn toString(self: Decimal, buf: []u8) ![]const u8 {
        var m = self.mantissa;
        const negative = m < 0;
        if (negative) m = -m;

        // Convert mantissa to digit string (reversed)
        var digits: [64]u8 = undefined;
        var dlen: usize = 0;

        if (m == 0) {
            digits[0] = '0';
            dlen = 1;
        } else {
            while (m > 0) {
                digits[dlen] = @intCast(@as(u8, @intCast(@rem(m, 10))) + '0');
                dlen += 1;
                m = @divTrunc(m, 10);
            }
        }

        // Pad with leading zeros if scale > digit count
        while (dlen <= self.scale) {
            digits[dlen] = '0';
            dlen += 1;
        }

        // Build output: [sign] integer_part [. fractional_part]
        var pos: usize = 0;

        if (negative) {
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = '-';
            pos += 1;
        }

        // Integer part (digits from dlen-1 down to scale)
        var di: usize = dlen;
        while (di > self.scale) {
            di -= 1;
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = digits[di];
            pos += 1;
        }

        // Fractional part
        if (self.scale > 0) {
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = '.';
            pos += 1;

            while (di > 0) {
                di -= 1;
                if (pos >= buf.len) return error.BufferTooSmall;
                buf[pos] = digits[di];
                pos += 1;
            }
        }

        return buf[0..pos];
    }

    /// Strip trailing zeros from fractional part.
    /// "10.0" → "10", "1.200" → "1.2", "100" → "100"
    /// This MUST match rust_decimal's normalize() for msgpack hash compatibility.
    pub fn normalize(self: Decimal) Decimal {
        if (self.mantissa == 0) return .{ .mantissa = 0, .scale = 0 };

        var m = self.mantissa;
        var s = self.scale;

        while (s > 0 and @rem(m, 10) == 0) {
            m = @divTrunc(m, 10);
            s -= 1;
        }

        return .{ .mantissa = m, .scale = s };
    }

    /// Rescale: adjust to target scale (may truncate or extend).
    fn rescale(self: Decimal, target_scale: u8) Decimal {
        if (self.scale == target_scale) return self;

        var m = self.mantissa;
        var s = self.scale;

        if (s < target_scale) {
            // Need more decimal places
            while (s < target_scale) {
                m *= 10;
                s += 1;
            }
        } else {
            // Need fewer decimal places (truncation)
            while (s > target_scale) {
                m = @divTrunc(m, 10);
                s -= 1;
            }
        }

        return .{ .mantissa = m, .scale = target_scale };
    }

    /// Add two decimals.
    pub fn add(self: Decimal, other: Decimal) Decimal {
        const target = @max(self.scale, other.scale);
        const a = self.rescale(target);
        const b = other.rescale(target);
        return .{ .mantissa = a.mantissa + b.mantissa, .scale = target };
    }

    /// Subtract.
    pub fn sub(self: Decimal, other: Decimal) Decimal {
        const target = @max(self.scale, other.scale);
        const a = self.rescale(target);
        const b = other.rescale(target);
        return .{ .mantissa = a.mantissa - b.mantissa, .scale = target };
    }

    /// Multiply.
    pub fn mul(self: Decimal, other: Decimal) Decimal {
        return .{
            .mantissa = self.mantissa * other.mantissa,
            .scale = self.scale + other.scale,
        };
    }

    /// Divide with specified result scale.
    pub fn divWithScale(self: Decimal, other: Decimal, result_scale: u8) Decimal {
        // Scale numerator up to get desired precision
        const total_scale = result_scale + other.scale;
        const a = self.rescale(total_scale);
        return .{
            .mantissa = @divTrunc(a.mantissa, other.mantissa),
            .scale = result_scale,
        };
    }

    /// Divide with automatic scale (max of inputs + 6 for extra precision).
    pub fn div(self: Decimal, other: Decimal) Decimal {
        const result_scale = @min(@as(u8, @max(self.scale, other.scale)) + 6, MAX_SCALE);
        return self.divWithScale(other, result_scale);
    }

    /// Round to n decimal places.
    /// Matches rust_decimal's round_dp (banker's rounding / half-even by default,
    /// but Hyperliquid uses MidpointAwayFromZero for price rounding).
    /// This implements MidpointAwayFromZero to match.
    pub fn roundDp(self: Decimal, dp: u8) Decimal {
        if (self.scale <= dp) return self.rescale(dp);

        // Compute the power of 10 to divide by (in one step, no cascading)
        const steps = self.scale - dp;
        var divisor: i128 = 1;
        for (0..steps) |_| {
            divisor *= 10;
        }

        const half = @divTrunc(divisor, 2);
        var m = self.mantissa;
        const remainder = @rem(m, divisor);
        m = @divTrunc(m, divisor);

        // MidpointAwayFromZero: round away from zero when exactly at midpoint
        if (remainder >= half) {
            m += 1;
        } else if (remainder <= -half) {
            m -= 1;
        }

        return .{ .mantissa = m, .scale = dp };
    }

    /// Integer floor(log10(abs(value))). Used for tick size calculation.
    /// Returns null for zero.
    pub fn log10Floor(self: Decimal) ?i32 {
        if (self.mantissa == 0) return null;

        const m = if (self.mantissa < 0) -self.mantissa else self.mantissa;

        // Count digits in mantissa
        var digits: i32 = 0;
        var tmp = m;
        while (tmp > 0) {
            tmp = @divTrunc(tmp, 10);
            digits += 1;
        }

        // log10(value) = digits_in_mantissa - 1 - scale
        return digits - 1 - @as(i32, self.scale);
    }

    /// Compare: returns .lt, .eq, or .gt
    pub fn cmp(self: Decimal, other: Decimal) std.math.Order {
        const target = @max(self.scale, other.scale);
        const a = self.rescale(target);
        const b = other.rescale(target);
        return std.math.order(a.mantissa, b.mantissa);
    }

    pub fn eql(self: Decimal, other: Decimal) bool {
        return self.cmp(other) == .eq;
    }

    pub fn isZero(self: Decimal) bool {
        return self.mantissa == 0;
    }

    pub fn isNegative(self: Decimal) bool {
        return self.mantissa < 0;
    }

    pub fn negate(self: Decimal) Decimal {
        return .{ .mantissa = -self.mantissa, .scale = self.scale };
    }

    pub fn abs(self: Decimal) Decimal {
        return .{
            .mantissa = if (self.mantissa < 0) -self.mantissa else self.mantissa,
            .scale = self.scale,
        };
    }
};

test "fromString: basic" {
    const d = try Decimal.fromString("123.456");
    try std.testing.expectEqual(@as(i128, 123456), d.mantissa);
    try std.testing.expectEqual(@as(u8, 3), d.scale);
}

test "fromString: integer" {
    const d = try Decimal.fromString("42");
    try std.testing.expectEqual(@as(i128, 42), d.mantissa);
    try std.testing.expectEqual(@as(u8, 0), d.scale);
}

test "fromString: negative" {
    const d = try Decimal.fromString("-0.5");
    try std.testing.expectEqual(@as(i128, -5), d.mantissa);
    try std.testing.expectEqual(@as(u8, 1), d.scale);
}

test "fromString: trailing zeros preserved" {
    const d = try Decimal.fromString("10.00");
    try std.testing.expectEqual(@as(i128, 1000), d.mantissa);
    try std.testing.expectEqual(@as(u8, 2), d.scale);
}

test "toString: basic" {
    var buf: [64]u8 = undefined;
    const d = Decimal{ .mantissa = 12345, .scale = 2 };
    const s = try d.toString(&buf);
    try std.testing.expectEqualStrings("123.45", s);
}

test "toString: integer" {
    var buf: [64]u8 = undefined;
    const d = Decimal{ .mantissa = 42, .scale = 0 };
    const s = try d.toString(&buf);
    try std.testing.expectEqualStrings("42", s);
}

test "toString: leading zero" {
    var buf: [64]u8 = undefined;
    const d = Decimal{ .mantissa = 5, .scale = 1 };
    const s = try d.toString(&buf);
    try std.testing.expectEqualStrings("0.5", s);
}

test "toString: negative" {
    var buf: [64]u8 = undefined;
    const d = Decimal{ .mantissa = -123, .scale = 1 };
    const s = try d.toString(&buf);
    try std.testing.expectEqualStrings("-12.3", s);
}

test "normalize: strip trailing zeros" {
    // "10.0" → "10"
    var buf: [64]u8 = undefined;
    const d = (Decimal{ .mantissa = 100, .scale = 1 }).normalize();
    try std.testing.expectEqual(@as(i128, 10), d.mantissa);
    try std.testing.expectEqual(@as(u8, 0), d.scale);
    const s = try d.toString(&buf);
    try std.testing.expectEqualStrings("10", s);
}

test "normalize: partial strip" {
    // "1.200" → "1.2"
    var buf: [64]u8 = undefined;
    const d = (Decimal{ .mantissa = 1200, .scale = 3 }).normalize();
    try std.testing.expectEqual(@as(i128, 12), d.mantissa);
    try std.testing.expectEqual(@as(u8, 1), d.scale);
    const s = try d.toString(&buf);
    try std.testing.expectEqualStrings("1.2", s);
}

test "normalize: zero" {
    const d = (Decimal{ .mantissa = 0, .scale = 5 }).normalize();
    try std.testing.expectEqual(@as(i128, 0), d.mantissa);
    try std.testing.expectEqual(@as(u8, 0), d.scale);
}

test "normalize: no trailing zeros" {
    const d = (Decimal{ .mantissa = 123, .scale = 2 }).normalize();
    try std.testing.expectEqual(@as(i128, 123), d.mantissa);
    try std.testing.expectEqual(@as(u8, 2), d.scale);
}

test "arithmetic: add" {
    const a = try Decimal.fromString("1.5");
    const b = try Decimal.fromString("2.3");
    var buf: [64]u8 = undefined;
    const s = try a.add(b).toString(&buf);
    try std.testing.expectEqualStrings("3.8", s);
}

test "arithmetic: sub" {
    const a = try Decimal.fromString("10.0");
    const b = try Decimal.fromString("3.5");
    var buf: [64]u8 = undefined;
    const s = try a.sub(b).toString(&buf);
    try std.testing.expectEqualStrings("6.5", s);
}

test "arithmetic: mul" {
    const a = try Decimal.fromString("2.5");
    const b = try Decimal.fromString("4.0");
    var buf: [64]u8 = undefined;
    const s = try a.mul(b).normalize().toString(&buf);
    try std.testing.expectEqualStrings("10", s);
}

test "roundDp: round to 2 places" {
    const d = try Decimal.fromString("1.2345");
    var buf: [64]u8 = undefined;
    const s = try d.roundDp(2).toString(&buf);
    try std.testing.expectEqualStrings("1.23", s);
}

test "roundDp: round up" {
    const d = try Decimal.fromString("1.235");
    var buf: [64]u8 = undefined;
    const s = try d.roundDp(2).toString(&buf);
    try std.testing.expectEqualStrings("1.24", s);
}

test "log10Floor" {
    // 100 → 2
    try std.testing.expectEqual(@as(?i32, 2), (try Decimal.fromString("100")).log10Floor());
    // 99 → 1
    try std.testing.expectEqual(@as(?i32, 1), (try Decimal.fromString("99")).log10Floor());
    // 1 → 0
    try std.testing.expectEqual(@as(?i32, 0), (try Decimal.fromString("1")).log10Floor());
    // 0.1 → -1
    try std.testing.expectEqual(@as(?i32, -1), (try Decimal.fromString("0.1")).log10Floor());
    // 0.01 → -2
    try std.testing.expectEqual(@as(?i32, -2), (try Decimal.fromString("0.01")).log10Floor());
    // 0 → null
    try std.testing.expectEqual(@as(?i32, null), Decimal.ZERO.log10Floor());
}

test "compare" {
    const a = try Decimal.fromString("1.5");
    const b = try Decimal.fromString("2.0");
    try std.testing.expect(a.cmp(b) == .lt);
    try std.testing.expect(b.cmp(a) == .gt);
    try std.testing.expect(a.cmp(a) == .eq);
}

test "roundtrip: fromString → normalize → toString" {
    // Key test: this is exactly what Hyperliquid signing does
    var buf: [64]u8 = undefined;
    const cases = .{
        .{ "10.0", "10" },
        .{ "0.100", "0.1" },
        .{ "123.456", "123.456" },
        .{ "100", "100" },
        .{ "0.0", "0" },
        .{ "-5.00", "-5" },
    };
    inline for (cases) |case| {
        const input = case[0];
        const expected = case[1];
        const d = try Decimal.fromString(input);
        const n = d.normalize();
        const s = try n.toString(&buf);
        try std.testing.expectEqualStrings(expected, s);
    }
}
