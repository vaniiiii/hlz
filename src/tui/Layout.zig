//! Constraint-based layout engine.
//!
//! Splits a Rect into sub-rects using constraints, inspired by ratatui.
//! Uses a simple two-pass algorithm instead of a full cassowary solver.
//!
//! Usage:
//!   const areas = Layout.horizontal(&.{ .length(20), .fill(1), .length(30) }).split(rect);
//!   // areas[0] = 20px left panel, areas[1] = flexible middle, areas[2] = 30px right panel

const std = @import("std");
const Buffer = @import("Buffer.zig");

pub const Rect = Buffer.Rect;

const Layout = @This();

pub const Direction = enum { horizontal, vertical };

pub const Constraint = union(enum) {
    /// Fixed size in cells.
    length: u16,
    /// Minimum size (at least N cells, may grow).
    min: u16,
    /// Maximum size (at most N cells, may shrink).
    max: u16,
    /// Percentage of total available space (0-100).
    percent: u16,
    /// Proportional fill — shares remaining space with other fills.
    /// fill(2) gets twice the space of fill(1).
    fill: u16,
};

/// Constraint constructors (separate from union to avoid Zig name collision).
pub fn len(n: u16) Constraint {
    return .{ .length = n };
}
pub fn mn(n: u16) Constraint {
    return .{ .min = n };
}
pub fn mx(n: u16) Constraint {
    return .{ .max = n };
}
pub fn pct(n: u16) Constraint {
    return .{ .percent = n };
}
pub fn fill(n: u16) Constraint {
    return .{ .fill = n };
}

direction: Direction,
constraints: []const Constraint,

pub fn horizontal(constraints: []const Constraint) Layout {
    return .{ .direction = .horizontal, .constraints = constraints };
}

pub fn vertical(constraints: []const Constraint) Layout {
    return .{ .direction = .vertical, .constraints = constraints };
}

/// Split the given rect according to constraints. Returns up to 16 sub-rects.
pub fn split(self: Layout, area: Rect) [16]Rect {
    var result: [16]Rect = undefined;
    const n = @min(self.constraints.len, 16);
    if (n == 0) return result;

    const total: u16 = switch (self.direction) {
        .horizontal => area.w,
        .vertical => area.h,
    };

    // Pass 1: compute sizes for fixed constraints, track fill total
    var sizes: [16]u16 = undefined;
    var fill_total: u32 = 0;
    var fixed_used: u32 = 0;

    for (0..n) |i| {
        const c = self.constraints[i];
        switch (c) {
            .length => |v| {
                sizes[i] = @min(v, total);
                fixed_used += sizes[i];
            },
            .min => |v| {
                sizes[i] = v;
                fixed_used += v;
            },
            .max => |v| {
                sizes[i] = @min(v, total);
                fixed_used += sizes[i];
            },
            .percent => |v| {
                const pct_size: u16 = @intCast(@min(
                    @as(u32, total) * @as(u32, @min(v, 100)) / 100,
                    total,
                ));
                sizes[i] = pct_size;
                fixed_used += pct_size;
            },
            .fill => |v| {
                fill_total += @max(v, 1);
                sizes[i] = 0; // placeholder
            },
        }
    }

    // Pass 2: distribute remaining space to fill constraints
    const remaining: u32 = if (fixed_used < total) total - @as(u16, @intCast(fixed_used)) else 0;
    if (fill_total > 0 and remaining > 0) {
        var fill_distributed: u32 = 0;
        var last_fill: usize = 0;
        for (0..n) |i| {
            switch (self.constraints[i]) {
                .fill => |v| {
                    const weight: u32 = @max(v, 1);
                    sizes[i] = @intCast(remaining * weight / fill_total);
                    fill_distributed += sizes[i];
                    last_fill = i;
                },
                else => {},
            }
        }
        // Give rounding remainder to the last fill
        if (fill_distributed < remaining) {
            sizes[last_fill] += @intCast(remaining - fill_distributed);
        }
    }

    // Clamp total to not exceed available space
    var used: u32 = 0;
    for (0..n) |i| used += sizes[i];
    if (used > total) {
        // Proportionally shrink all elements
        for (0..n) |i| {
            sizes[i] = @intCast(@as(u32, sizes[i]) * total / used);
        }
    }

    // Convert sizes to rects
    var pos: u16 = switch (self.direction) {
        .horizontal => area.x,
        .vertical => area.y,
    };

    for (0..n) |i| {
        result[i] = switch (self.direction) {
            .horizontal => .{ .x = pos, .y = area.y, .w = sizes[i], .h = area.h },
            .vertical => .{ .x = area.x, .y = pos, .w = area.w, .h = sizes[i] },
        };
        pos += sizes[i];
    }

    return result;
}


test "horizontal split with fill" {
    const area = Rect{ .x = 0, .y = 0, .w = 100, .h = 10 };
    const constraints = [_]Constraint{ len(20), fill(1), len(30) };
    const result = Layout.horizontal(&constraints).split(area);
    try std.testing.expectEqual(@as(u16, 0), result[0].x);
    try std.testing.expectEqual(@as(u16, 20), result[0].w);
    try std.testing.expectEqual(@as(u16, 20), result[1].x);
    try std.testing.expectEqual(@as(u16, 50), result[1].w);
    try std.testing.expectEqual(@as(u16, 70), result[2].x);
    try std.testing.expectEqual(@as(u16, 30), result[2].w);
}

test "vertical split with percent" {
    const area = Rect{ .x = 0, .y = 0, .w = 80, .h = 40 };
    const constraints = [_]Constraint{ pct(25), fill(1), len(3) };
    const result = Layout.vertical(&constraints).split(area);
    try std.testing.expectEqual(@as(u16, 10), result[0].h);
    try std.testing.expectEqual(@as(u16, 27), result[1].h);
    try std.testing.expectEqual(@as(u16, 3), result[2].h);
}

test "multiple fills with weights" {
    const area = Rect{ .x = 0, .y = 0, .w = 90, .h = 10 };
    const constraints = [_]Constraint{ fill(1), fill(2), fill(3) };
    const result = Layout.horizontal(&constraints).split(area);
    try std.testing.expectEqual(@as(u16, 15), result[0].w);
    try std.testing.expectEqual(@as(u16, 30), result[1].w);
    try std.testing.expectEqual(@as(u16, 45), result[2].w);
}

test "min constraint" {
    const area = Rect{ .x = 0, .y = 0, .w = 100, .h = 10 };
    const constraints = [_]Constraint{ mn(30), fill(1) };
    const result = Layout.horizontal(&constraints).split(area);
    try std.testing.expectEqual(@as(u16, 30), result[0].w);
    try std.testing.expectEqual(@as(u16, 70), result[1].w);
}
