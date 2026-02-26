const std = @import("std");
const hyperzig = @import("hyperzig");

pub const Config = struct {
    chain: hyperzig.hypercore.signing.Chain = .mainnet,
    key_hex: ?[]const u8 = null,
    address: ?[]const u8 = null,
};

pub fn run(_: std.mem.Allocator, _: Config, _: []const u8) !void {
    std.fs.File.stdout().writeAll("Trading terminal not available. Use `hl-trade` instead.\n") catch {};
    return error.NotAvailable;
}
