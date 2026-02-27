# Types

Core types for orders, actions, and responses.

## Order Types

### `OrderRequest`

```zig
const OrderRequest = struct {
    asset: u32,              // Market index (0=BTC, 1=ETH, ...)
    is_buy: bool,
    limit_px: Decimal,       // Price as 38-digit decimal
    sz: Decimal,             // Size
    reduce_only: bool,
    order_type: OrderType,   // Limit, trigger, or market
    cloid: Cloid,            // Client order ID (optional)
};
```

### `OrderType`

```zig
const OrderType = union(enum) {
    limit: struct { tif: TimeInForce },
    trigger: struct {
        trigger_px: Decimal,
        is_market: bool,
        tpsl: TpSl,
    },
};
```

### `TimeInForce`

| Value | Meaning |
|-------|---------|
| `Gtc` | Good-til-cancelled |
| `Ioc` | Immediate-or-cancel |
| `Alo` | Add-liquidity-only (post-only) |
| `FrontendMarket` | Market order (used internally) |

### `BatchOrder`

```zig
const BatchOrder = struct {
    orders: []const OrderRequest,
    grouping: OrderGrouping,  // .na, .normalTpSl, .positionTpSl
};
```

## Response Types

All 62 response types live in `response.zig`. Key ones:

### `ClearinghouseState`

```zig
const ClearinghouseState = struct {
    marginSummary: MarginSummary,
    crossMarginSummary: MarginSummary,
    assetPositions: []AssetPosition,
    // ... 
};
```

### `OpenOrder`

```zig
const OpenOrder = struct {
    coin: []const u8,
    side: []const u8,
    limitPx: []const u8,
    sz: []const u8,
    oid: u64,
    // ...
};
```

### Response Conventions

- All fields use `camelCase` matching JSON keys exactly
- All fields have defaults for forward compatibility: `= ""`, `= 0`, `= Decimal.ZERO`
- Parse options: `{ .ignore_unknown_fields = true, .allocate = .alloc_always }`
- Returned as `Parsed(T)` — call `.deinit()` to free

## Decimal Type

`Decimal` is a 38-digit decimal type used for all prices and sizes:

```zig
const Decimal = hlz.math.decimal.Decimal;

const price = try Decimal.fromString("50000.5");
const size = try Decimal.fromString("0.001");

// Arithmetic
const total = price.mul(size);

// Format to string (stack buffer, no allocation)
var buf: [32]u8 = undefined;
const str = total.toString(&buf);
```

## Asset Index Resolution

The SDK resolves human-readable asset names to numeric indices at runtime:

```
"BTC"        → asset index 0
"ETH"        → asset index 1
"PURR/USDC"  → spot market index
"xyz:BTC"    → HIP-3 DEX market index
```

This resolution uses the metadata from `getMetaAndAssetCtxs()`.
