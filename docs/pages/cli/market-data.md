# Market Data

All market data commands work without authentication.

## `hlz price <COIN>`

Smart price lookup across all Hyperliquid venues. Resolves perps, spot pairs, and HIP-3 DEX markets automatically.

**Resolution rules:**
- `BTC` → perp on default dex (most liquid, USDC-settled)
- `HYPE/USDC` → explicit spot pair (oracle-adjusted USD price via `tokenDetails`)
- `xyz:AAPL` → perp on xyz dex
- `HYPE --quote USDH` → spot pair HYPE/USDH
- `HYPE --all` → every venue: perp + all spot quote pairs

When only a perp is shown, a hint suggests `--all` for additional markets.

**Flags:**
- `--dex <NAME>` — target a specific HIP-3 DEX (e.g. `xyz`, `flx`)
- `--quote <ASSET>` — filter to a specific spot quote asset (e.g. `USDC`, `USDH`, `USDT0`, `USDE`)
- `--all` — show all matching markets (perps + every spot pair)

```bash
# Perps (default)
hlz price BTC                     # → $65,000 (perp, default dex)
hlz price ETH -q                  # → 1925.0 (quiet, just the number)

# HIP-3 DEX perps
hlz price xyz:AAPL                # → $265 (stocks on xyz)
hlz price BTC --dex flx           # → BTC on flx (USDH collateral)

# Spot pairs
hlz price HYPE/USDC               # → $27 (oracle USD price)
hlz price UETH/USDC               # → $1,925 (not the raw book unit price)
hlz price HYPE --quote USDH       # → HYPE/USDH spot price

# All venues
hlz price HYPE --all
# Shows: HYPE perp, HYPE/USDC, HYPE/USDT0, HYPE/USDH, HYPE/USDE

hlz price HYPE --all --json
# [{"market":"HYPE","type":"perp","venue":"hl","price":27.08},
#  {"market":"HYPE/USDC","type":"spot","venue":"USDC","price":27.12}, ...]
```

**Spot price accuracy:** For spot pairs, `price` uses the `tokenDetails` API which returns oracle-adjusted USD prices (same as the Hyperliquid web frontend). The raw `allMids` endpoint returns per-sz-unit book midpoints which can differ significantly for non-canonical tokens — use `hlz mids` if you need raw book data.

**Perp collateral:** Different HIP-3 DEXes use different collateral tokens (USDC, USDH, USDE). Use `--dex` to target a specific venue. Use `hlz dexes` to see available DEXes.

## `hlz mids [COIN]`

Raw order book mid prices from the `allMids` API. Returns per-sz-unit midpoints — for human-friendly spot prices, use `hlz price` instead.

Spot pairs show as human-readable names (e.g. `PURR/USDC`), not raw `@index` keys.

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

List available HIP-3 DEXes with their collateral tokens.

```bash
hlz dexes
```
