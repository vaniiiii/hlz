# Market Data

All market data commands work without authentication.

## `hlz price <COIN>`

Get the current mid price with bid/ask spread. Returns exit 1 if the coin doesn't exist.

```bash
hlz price BTC
# BTC: $97,432.50  bid $97,432.00 / ask $97,433.00  spread 0.001%

hlz price BTC --json
# {"coin":"BTC","mid":97432.5,"bid":97432.0,"ask":97433.0}

hlz price PURR/USDC --json
# {"coin":"PURR/USDC","mid":0.066454,"bid":0.066309,"ask":0.066599}
```

## `hlz mids [COIN]`

All mid prices. Optionally filter by coin. Spot pairs show as human-readable names (e.g. `PURR/USDC`), not raw `@index` keys.

```bash
hlz mids                    # Top 20 by default
hlz mids --all              # All markets
hlz mids --page 2           # Page 2
hlz mids BTC                # Filter to BTC-related

# JSON output is a {coin: price} object
hlz mids BTC --json
# {"BTC":"65000.5","UBTC/USDC":"65012.3"}

hlz mids --json | jq '.BTC'
```

## `hlz funding [--top N]`

Funding rates with visual heat bars. `--json` returns a clean filtered array.

```bash
hlz funding                 # Top 20 by absolute rate
hlz funding --top 5         # Top 5
hlz funding --filter ETH    # Search

hlz funding --top 3 --json
# [{"coin":"MAVIA","funding":0.00081,"annualized":718.04,"mark":"0.033"},...]
```

## `hlz book <COIN> [--live]`

L2 order book. Use `--live` for real-time WebSocket updates. Returns exit 1 if the coin doesn't exist.

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
