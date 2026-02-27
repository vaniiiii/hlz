const std = @import("std");
const hlz = @import("hlz");

pub const Config = struct {
    chain: hlz.hypercore.signing.Chain = .mainnet,
    key_hex: ?[]const u8 = null,
    address: ?[]const u8 = null,
};

pub fn run(_: std.mem.Allocator, _: Config, _: []const u8) !void {
    std.fs.File.stdout().writeAll("Trading terminal not available. Use `hl-trade` instead.\n") catch {};
    return error.NotAvailable;
}
