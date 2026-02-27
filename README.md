# HyperZig

High-performance Zig SDK for [Hyperliquid](https://hyperliquid.xyz).

## Performance

| Metric | Rust SDK | HyperZig |
|--------|---------|----------|
| Sign order | 34.6 µs | **34.5 µs** |
| Sign cancel | 35.0 µs | **34.1 µs** |
| EIP-712 hash | 1.2 µs | **250 ns** (4.8×) |
| Binary size | 2.2 MB | **2.5 KB** (880×) |
| Build time | 35.7s | **3.1s** (11×) |
| Dependencies | 13 crates | 1 |
| Heap allocs on sign | Multiple | **Zero** |

## Features

- **Byte-exact MessagePack** matching `rmp-serde::to_vec_named`
- **Comptime EIP-712** — all 7 type hashes pre-computed at compile time
- **5×52-bit field arithmetic** — ported from libsecp256k1/k256 with GLV endomorphism
- **HTTP client** — 18 info + 12 exchange endpoints
- **WebSocket types** — all 13 subscription types
- **120 tests**, cross-validated against the Rust SDK byte-for-byte

## Quick Start

```zig
const hyperzig = @import("hyperzig");
const Signer = hyperzig.crypto.signer.Signer;
const Decimal = hyperzig.math.decimal.Decimal;
const types = hyperzig.hypercore.types;
const signing = hyperzig.hypercore.signing;

const signer = try Signer.fromHex("your_64_char_hex_key");

const order = types.OrderRequest{
    .asset = 0,
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

// Sign (~34µs, zero heap allocations)
const sig = try signing.signOrder(signer, batch, nonce, .mainnet, null, null);

// Submit
var client = hyperzig.hypercore.client.Client.mainnet(allocator);
defer client.deinit();
var result = try client.place(signer, batch, nonce, null, null);
defer result.deinit();
```

## Building

Requires **Zig 0.15.2**.

```bash
zig build test          # 120 tests
zig build bench         # benchmarks
zig build               # static library → zig-out/lib/libhyperzig.a
PRIVATE_KEY=0x... zig build example
```

## Architecture

```
src/
├── encoding/msgpack.zig     # MessagePack encoder
├── math/decimal.zig         # 38-digit decimal arithmetic
├── crypto/
│   ├── field.zig            # 5×52-bit Solinas field arithmetic
│   ├── point.zig            # Projective point operations
│   ├── endo.zig             # GLV endomorphism scalar mul
│   ├── signer.zig           # secp256k1 ECDSA + RFC 6979
│   └── eip712.zig           # EIP-712 typed data hashing
└── hypercore/
    ├── types.zig            # Order types + msgpack serialization
    ├── signing.zig          # RMP + typed-data signing flows
    ├── client.zig           # HTTP client
    ├── ws.zig               # WebSocket subscription types
    ├── response.zig         # Response parsing
    ├── tick.zig             # Price tick rounding
    └── json.zig             # JSON helpers
```

## Signing Paths

**RMP path** (orders, cancels): Action → msgpack → nonce/vault → keccak256 → Agent EIP-712 (chainId 1337)

**Typed data path** (transfers, approvals): Fields → EIP-712 struct hash → Arbitrum domain (42161/421614)

## License

MIT
