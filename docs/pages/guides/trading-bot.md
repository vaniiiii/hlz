# Building a Trading Bot

This guide shows how to build a simple trading bot using the `hlz` CLI and shell scripting. For complex bots, use the Zig SDK directly.

## Prerequisites

```bash
# Install hlz
curl -fsSL https://hlz.dev/install.sh | sh

# Set up your key
hlz keys new bot
export HL_KEY_NAME=bot
export HL_PASSWORD=your_password
export HL_OUTPUT=json
```

## Simple Grid Bot

Places buy and sell orders at fixed intervals around the current price:

```bash
#!/bin/bash
set -euo pipefail

COIN="BTC"
SIZE="0.01"
LEVELS=5
SPREAD="50"  # dollars between levels

# Get current mid price
MID=$(hlz price $COIN -q)
echo "Mid price: $MID"

# Place grid orders
for i in $(seq 1 $LEVELS); do
  OFFSET=$(echo "$i * $SPREAD" | bc)
  BUY_PX=$(echo "$MID - $OFFSET" | bc)
  SELL_PX=$(echo "$MID + $OFFSET" | bc)
  
  hlz buy $COIN $SIZE @$BUY_PX --json
  hlz sell $COIN $SIZE @$SELL_PX --json
done

echo "Grid placed: $LEVELS levels, $SPREAD spread"
```

## Monitor and Rebalance

```bash
#!/bin/bash
# Check positions every 30 seconds, rebalance if needed

while true; do
  POS=$(hlz positions --json | jq -r '.[] | select(.coin == "BTC") | .szi')
  
  if [ -z "$POS" ]; then
    POS="0"
  fi
  
  # If position exceeds threshold, reduce
  if (( $(echo "$POS > 0.5" | bc -l) )); then
    echo "Position too large ($POS), reducing..."
    hlz sell BTC 0.1 --reduce-only --json
  elif (( $(echo "$POS < -0.5" | bc -l) )); then
    echo "Short too large ($POS), reducing..."
    hlz buy BTC 0.1 --reduce-only --json
  fi
  
  sleep 30
done
```

## Using the Zig SDK

For lower latency and more control, use the SDK directly:

```zig
const hlz = @import("hlz");
const Client = hlz.hypercore.client.Client;
const Signer = hlz.crypto.signer.Signer;
const Decimal = hlz.math.decimal.Decimal;
const types = hlz.hypercore.types;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const signer = try Signer.fromHex("your_key");
    var client = Client.mainnet(allocator);
    defer client.deinit();

    // Fetch current mid price
    var mids = try client.getAllMids(null);
    defer mids.deinit();

    // Build and sign order (34.5µs, zero allocs)
    const order = types.OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = try Decimal.fromString("50000"),
        .sz = try Decimal.fromString("0.01"),
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
    var result = try client.place(signer, batch, nonce, null, null);
    defer result.deinit();
}
```

## Best Practices

1. **Always use `--dry-run` first** — Test your bot logic without real orders
2. **Set position limits** — Use `--reduce-only` to prevent runaway positions
3. **Handle all exit codes** — `3` = auth error, `4` = network error
4. **Use keystores** — Don't put private keys in scripts
5. **Rate limit yourself** — Hyperliquid allows 1200 req/min per IP
