//! Example: Place a limit order on Hyperliquid.
//!
//! Usage:
//!   PRIVATE_KEY=0x... zig build run-example
//!
//! This example demonstrates:
//! - Creating a signer from a private key
//! - Building an order request
//! - Signing and submitting via HTTP
//!
//! ⚠️  This will place a REAL order on mainnet if you provide a real key.
//!      Use testnet or a very low price for safety.

const std = @import("std");
const hlz = @import("hlz");

const Signer = hlz.crypto.signer.Signer;
const Decimal = hlz.math.decimal.Decimal;
const types = hlz.hypercore.types;
const Client = hlz.hypercore.client.Client;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get private key from environment
    const key_hex = std.process.getEnvVarOwned(allocator, "PRIVATE_KEY") catch {
        std.debug.print("Set PRIVATE_KEY env var (hex, with or without 0x prefix)\n", .{});
        return;
    };
    defer allocator.free(key_hex);

    // Strip 0x prefix if present
    const key = if (std.mem.startsWith(u8, key_hex, "0x")) key_hex[2..] else key_hex;
    if (key.len != 64) {
        std.debug.print("Private key must be 32 bytes (64 hex chars)\n", .{});
        return;
    }

    // Create signer
    const signer = Signer.fromHex(key) catch {
        std.debug.print("Invalid private key\n", .{});
        return;
    };

    // Print address
    const hex = "0123456789abcdef";
    var addr_hex: [42]u8 = undefined;
    addr_hex[0] = '0';
    addr_hex[1] = 'x';
    for (signer.address, 0..) |byte, i| {
        addr_hex[2 + i * 2] = hex[byte >> 4];
        addr_hex[2 + i * 2 + 1] = hex[byte & 0x0f];
    }
    std.debug.print("Signer address: {s}\n", .{&addr_hex});

    // Build a limit buy order: 0.001 BTC at $1 (will not fill, safe for testing)
    const order = types.OrderRequest{
        .asset = 0, // BTC
        .is_buy = true,
        .limit_px = Decimal.fromString("1") catch unreachable, // $1 — will never fill
        .sz = Decimal.fromString("0.001") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    // Use current timestamp as nonce
    const nonce: u64 = @intCast(std.time.milliTimestamp());

    // Sign the order (zero-alloc, ~50μs)
    const sig = hlz.hypercore.signing.signOrder(
        signer,
        batch,
        nonce,
        .mainnet,
        null,
        null,
    ) catch |err| {
        std.debug.print("Signing failed: {}\n", .{err});
        return;
    };

    const sig_bytes = sig.toEthBytes();
    var sig_hex: [132]u8 = undefined;
    sig_hex[0] = '0';
    sig_hex[1] = 'x';
    for (sig_bytes, 0..) |byte, i| {
        sig_hex[2 + i * 2] = hex[byte >> 4];
        sig_hex[2 + i * 2 + 1] = hex[byte & 0x0f];
    }
    std.debug.print("Signature: {s}\n", .{&sig_hex});
    std.debug.print("Nonce: {d}\n", .{nonce});

    // Submit via HTTP (uncomment to actually send)
    // var client = Client.mainnet(allocator);
    // defer client.deinit();
    // var result = try client.place(signer, batch, nonce, null, null);
    // defer result.deinit();
    // std.debug.print("Response: {s}\n", .{result.body});

    std.debug.print("\nOrder signed successfully! Uncomment HTTP section to submit.\n", .{});
}
