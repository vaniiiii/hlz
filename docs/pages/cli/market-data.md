# Market Data

All market data commands work without authentication.

## `hlz price <COIN>`

Get the current mid price with bid/ask spread.

```bash
hlz price BTC
# BTC: $97,432.50  bid $97,432.00 / ask $97,433.00  spread 0.001%

hlz price BTC --json
# {"coin":"BTC","mid":"97432.5","bid":"97432.0","ask":"97433.0","spread":"0.00103"}
```

## `hlz mids [COIN]`

All mid prices. Optionally filter by coin.

```bash
hlz mids                    # Top 20 by default
hlz mids --all              # All markets
hlz mids --page 2           # Page 2
hlz mids BTC                # Just BTC

# Pipe to jq for custom filtering
hlz mids --json | jq '.[] | select(.mid > 1000)'
```

## `hlz funding [--top N]`

Funding rates with visual heat bars.

```bash
hlz funding                 # All markets
hlz funding --top 10        # Top 10 by absolute rate
```

## `hlz book <COIN> [--live]`

L2 order book. Use `--live` for real-time WebSocket updates.

```bash
hlz book BTC                # Snapshot
hlz book ETH --live         # Live updating (Ctrl+C to exit)
```

## `hlz perps [--dex xyz]`

List perpetual markets.

```bash
hlz perps                   # Hyperliquid native markets
hlz perps --dex xyz         # HIP-3 DEX markets
hlz perps --all             # All DEXes combined
hlz perps --filter BTC      # Search markets
```

## `hlz spot [--all]`

List spot markets.

```bash
hlz spot                    # Top spot markets
hlz spot --all              # All spot markets
```

## `hlz dexes`

List available HIP-3 DEXes.

```bash
hlz dexes
```
