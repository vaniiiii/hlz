# Decimal Math

hlz includes a 38-digit decimal type for precise financial arithmetic. No floating-point errors.

## Creating Decimals

```zig
const Decimal = hlz.math.decimal.Decimal;

// From string (most common)
const price = try Decimal.fromString("50000.5");
const size = try Decimal.fromString("0.001");

// Special values
const zero = Decimal.ZERO;
```

## Formatting

```zig
var buf: [32]u8 = undefined;
const str = price.toString(&buf);
// "50000.5"
```

Smart formatting auto-scales by magnitude — no trailing zeros, appropriate decimal places.

## Why Not `f64`?

Floating-point math produces rounding errors that are unacceptable for financial operations:

```
f64: 0.1 + 0.2 = 0.30000000000000004
Decimal: 0.1 + 0.2 = 0.3
```

The Hyperliquid API uses string-encoded decimals. hlz's `Decimal` type preserves exact precision through the entire pipeline: parse → compute → sign → serialize.
