# SDK Overview

Zig library for Hyperliquid with typed API responses. Signing adapted from [zabi](https://github.com/Raiden1411/zabi)'s EIP-712 and ECDSA implementation.

## What's Included

| Component | Details |
|-----------|---------|
| **Signing** | secp256k1 + EIP-712 (based on zabi) |
| **HTTP Client** | 18 info + 12 exchange endpoints, typed responses |
| **WebSocket** | 13 subscription types |
| **Decimal Math** | 38-digit precision |
| **MessagePack** | Byte-exact with Rust `rmp-serde::to_vec_named` |

## Module Structure

```zig
const hlz = @import("hlz");

// Core primitives (lib/)
hlz.crypto.signer      // secp256k1 ECDSA + RFC 6979
hlz.crypto.eip712      // EIP-712 typed data hashing
hlz.math.decimal        // 38-digit decimal type
hlz.encoding.msgpack    // MessagePack encoder

// Hyperliquid SDK (sdk/)
hlz.hypercore.client    // HTTP client
hlz.hypercore.signing   // Signing orchestration
hlz.hypercore.types     // Order types, BatchOrder, TimeInForce
hlz.hypercore.ws        // WebSocket subscriptions
hlz.hypercore.response  // 62 response types
hlz.hypercore.tick      // Price tick rounding
```

## Quick Example

```zig
const hlz = @import("hlz");
const Signer = hlz.crypto.signer.Signer;
const Decimal = hlz.math.decimal.Decimal;
const types = hlz.hypercore.types;
const signing = hlz.hypercore.signing;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const signer = try Signer.fromHex("your_64_char_hex_key");

    // Build an order
    const order = types.OrderRequest{
        .asset = 0,  // BTC
        .is_buy = true,
        .limit_px = try Decimal.fromString("50000"),
        .sz = try Decimal.fromString("0.1"),
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    // Sign (34.5µs, zero allocs)
    const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
    const sig = try signing.signOrder(signer, batch, nonce, .mainnet, null, null);

    // Submit
    var client = hlz.hypercore.client.Client.mainnet(allocator);
    defer client.deinit();
    var result = try client.place(signer, batch, nonce, null, null);
    defer result.deinit();
}
```

## Design Principles

- **Explicit allocators** — Every function that allocates takes an `Allocator` parameter
- **Type-safe responses** — All endpoints return `Parsed(T)` with proper Zig types
- **Comptime where possible** — EIP-712 type hashes computed at compile time
