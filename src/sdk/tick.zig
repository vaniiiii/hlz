//! Tick size calculation and price rounding for Hyperliquid.
//! 5 significant figures, clamped by market-specific max_decimals.

const std = @import("std");
const Decimal = @import("../lib/math/decimal.zig").Decimal;

pub const Side = enum { Bid, Ask };

/// Price tick configuration for a market.
/// Controls tick sizes and rounding behavior.
pub const PriceTick = struct {
    /// Maximum decimal places allowed (market-specific).
    /// - Spot: 8 - sz_decimals
    /// - Perp: 6 - sz_decimals
    max_decimals: i32,

    /// Create a PriceTick for a spot market.
    pub fn forSpot(sz_decimals: i32) PriceTick {
        return .{ .max_decimals = 8 - sz_decimals };
    }

    /// Create a PriceTick for a perpetual market.
    pub fn forPerp(sz_decimals: i32) PriceTick {
        return .{ .max_decimals = 6 - sz_decimals };
    }

    /// Returns the tick size for a given price.
    /// Maintains 5 significant figures, clamped to max_decimals.
    pub fn tickFor(self: PriceTick, price: Decimal) ?Decimal {
        if (price.isZero() or price.isNegative()) return null;

        const log = price.log10Floor() orelse return null;
        const sig_figs_n: i32 = log + 1;
        const decimals: i32 = 5 - sig_figs_n;

        // Clamp to [0, max_decimals]
        const clamped = @min(@max(decimals, 0), self.max_decimals);

        if (clamped <= 0) {
            return Decimal{ .mantissa = 1, .scale = 0 };
        }
        return Decimal{ .mantissa = 1, .scale = @intCast(clamped) };
    }

    /// Round a price to the nearest valid tick (MidpointTowardZero).
    pub fn round(self: PriceTick, price: Decimal) ?Decimal {
        const tick = self.tickFor(price) orelse return null;
        return price.roundDp(tick.scale);
    }

    /// Round a price based on order side and aggressiveness.
    ///
    /// | Side | Conservative | Direction |
    /// |------|-------------|-----------|
    /// | Ask  | true        | UP        |
    /// | Ask  | false       | DOWN      |
    /// | Bid  | true        | DOWN      |
    /// | Bid  | false       | UP        |
    pub fn roundBySide(self: PriceTick, side: Side, price: Decimal, conservative: bool) ?Decimal {
        const tick = self.tickFor(price) orelse return null;
        const scale = tick.scale;

        // Compute power = 10^scale
        var power: i128 = 1;
        for (0..scale) |_| power *= 10;

        // Scale up the price to integer at the target precision
        const scaled = price.mantissa * std.math.pow(i128, 10, @intCast(if (scale > price.scale) scale - price.scale else 0));
        const divisor = std.math.pow(i128, 10, @intCast(if (price.scale > scale) price.scale - scale else 0));

        const round_up = (side == .Ask and conservative) or (side == .Bid and !conservative);

        if (divisor == 1) {
            // Already at target scale or less precision needed
            return Decimal{ .mantissa = scaled, .scale = scale };
        }

        const quotient = @divTrunc(scaled, divisor);
        const remainder = @rem(scaled, divisor);

        if (remainder == 0) {
            return Decimal{ .mantissa = quotient, .scale = scale };
        }

        if (round_up) {
            // Round toward positive infinity (ceiling for positive numbers)
            if (price.isNegative()) {
                return Decimal{ .mantissa = quotient, .scale = scale };
            } else {
                return Decimal{ .mantissa = quotient + 1, .scale = scale };
            }
        } else {
            // Round toward negative infinity (floor for positive numbers)
            if (price.isNegative()) {
                return Decimal{ .mantissa = quotient - 1, .scale = scale };
            } else {
                return Decimal{ .mantissa = quotient, .scale = scale };
            }
        }
    }
};

/// Convenience: compute tick size with default 5-sig-fig perp config (max_decimals=6).
pub fn tickSize(price: Decimal) ?Decimal {
    const default_tick = PriceTick{ .max_decimals = 6 };
    return default_tick.tickFor(price);
}

/// Convenience: round a price with default perp config.
pub fn roundPrice(price: Decimal) ?Decimal {
    const default_tick = PriceTick{ .max_decimals = 6 };
    return default_tick.round(price);
}

// ── Tests ─────────────────────────────────────────────────────────

test "PriceTick.forPerp: BTC sz_decimals=5" {
    var buf: [64]u8 = undefined;
    const tick = PriceTick.forPerp(5); // max_decimals = 1

    // BTC at 50000: 5 sig figs → decimals=0, clamp(0,0,1) → 0 → tick=1
    const t1 = tick.tickFor(try Decimal.fromString("50000")).?;
    try std.testing.expectEqualStrings("1", try t1.toString(&buf));

    // BTC at 5: 5 sig figs → decimals=4, clamp(4,0,1) → 1 → tick=0.1
    const t2 = tick.tickFor(try Decimal.fromString("5")).?;
    try std.testing.expectEqualStrings("0.1", try t2.toString(&buf));
}

test "PriceTick.forSpot: token with sz_decimals=2" {
    var buf: [64]u8 = undefined;
    const tick = PriceTick.forSpot(2); // max_decimals = 6

    const t1 = tick.tickFor(try Decimal.fromString("1.5")).?;
    try std.testing.expectEqualStrings("0.0001", try t1.toString(&buf));
}

test "tickSize: high price" {
    var buf: [64]u8 = undefined;
    const t1 = tickSize(try Decimal.fromString("50000")).?;
    try std.testing.expectEqualStrings("1", try t1.toString(&buf));

    // 100000 → 6 sig figs → decimals=-1, clamp(-1,0,6) → 0 → tick=1
    const t2 = tickSize(try Decimal.fromString("100000")).?;
    try std.testing.expectEqualStrings("1", try t2.toString(&buf));
}

test "tickSize: low price" {
    var buf: [64]u8 = undefined;
    const t1 = tickSize(try Decimal.fromString("1.5")).?;
    try std.testing.expectEqualStrings("0.0001", try t1.toString(&buf));
}

test "tickSize: edge cases" {
    try std.testing.expectEqual(@as(?Decimal, null), tickSize(Decimal.ZERO));
}

test "roundPrice" {
    var buf: [64]u8 = undefined;
    const r1 = roundPrice(try Decimal.fromString("50000.123")).?;
    try std.testing.expectEqualStrings("50000", try r1.toString(&buf));

    const r2 = roundPrice(try Decimal.fromString("1.23456")).?;
    try std.testing.expectEqualStrings("1.2346", try r2.toString(&buf));
}

test "roundBySide: ask conservative rounds up" {
    var buf: [64]u8 = undefined;
    const tick = PriceTick.forPerp(0); // max_decimals = 6
    // 1.23451 → ask conservative → round UP to 1.2346
    const r = tick.roundBySide(.Ask, try Decimal.fromString("1.23451"), true).?;
    try std.testing.expectEqualStrings("1.2346", try r.toString(&buf));
}

test "roundBySide: bid conservative rounds down" {
    var buf: [64]u8 = undefined;
    const tick = PriceTick.forPerp(0);
    // 1.23459 → bid conservative → round DOWN to 1.2345
    const r = tick.roundBySide(.Bid, try Decimal.fromString("1.23459"), true).?;
    try std.testing.expectEqualStrings("1.2345", try r.toString(&buf));
}
