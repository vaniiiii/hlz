# hyperzig — Project Context

## What is this?

A Zig monorepo for Hyperliquid: SDK, CLI, TUI framework, and trading terminal.
Single static binary. One external dependency. Targets HFT-grade performance.

Two products ship from this repo:
- **`hl`** — CLI for trading, market data, account management (600KB stripped)
- **`hl-trade`** — Full trading terminal with candlestick chart, live orderbook, order entry (681KB stripped)

## Why Zig?

Competing against the official Rust SDK (`hypersdk`) and two CLIs (`hypecli` Rust, `hyperliquid-cli` TypeScript).

| Metric | hyperzig | hypersdk (Rust) | hyperliquid-cli (TS) |
|--------|----------|-----------------|----------------------|
| Binary | **583KB** | ~15MB | Node.js + 195MB node_modules |
| Build | **3.1s** | 35.7s | npm install |
| Deps | **1** | 13 crates | 9 runtime + 215 transitive |
| sign_order | **34.5µs** | 34.6µs | viem (external) |
| eip712_hash | **250ns** | 1.2µs | viem (external) |
| Commands | **36** | ~15 | ~31 |
| Startup | ~1ms | ~5ms | ~200ms |

## Architecture

```
src/
├── lib/               core primitives (2,464 lines)
│   ├── crypto/        secp256k1, EIP-712, signer (5 files)
│   ├── encoding/      msgpack encoder
│   └── math/          decimal type
├── sdk/               Hyperliquid SDK (3,315 lines)
│   ├── client.zig     HTTP client (18 info + 14 exchange endpoints)
│   ├── signing.zig    signing orchestration
│   ├── types.zig      wire types + msgpack packing
│   ├── ws.zig         WebSocket subscriptions
│   ├── response.zig   response parsing
│   ├── json.zig       JSON helpers
│   └── tick.zig       tick rounding
├── tui/               TUI framework (1,682 lines)
│   ├── Buffer.zig     double-buffered cell grid, RGB color
│   ├── Terminal.zig   raw mode, input ring buffer
│   ├── Layout.zig     two-pass constraint layout
│   ├── List.zig       scrollable list with search/sort
│   ├── Chart.zig      candlestick renderer
│   └── App.zig        frame lifecycle
├── cli/               CLI tool (3,703 lines)
│   ├── main.zig       entry point, dispatch
│   ├── args.zig       argument parser (34 commands)
│   ├── commands.zig   command implementations
│   ├── config.zig     config loader
│   ├── output.zig     pipe-aware output
│   └── trade_stub.zig stub for hl (no terminal)
├── terminal/          trading terminal (1,225 lines)
│   └── trade.zig      full TUI: chart, book, tape, orders
└── root.zig           public API re-exports
```

**Dependency rule: arrows only point down.**
```
terminal/  cli/
    ↓       ↓
   tui/    sdk/
            ↓
          lib/
```

## CLI Commands (34)

### Market Data (9)
| Command | Description |
|---------|-------------|
| `hl markets` | Interactive market browser (TUI) |
| `hl price <COIN>` | Current price — mid + bid/ask (spot-aware) |
| `hl mids [COIN]` | Mid prices (top 20, --all) |
| `hl funding` | Funding rates with heat bars |
| `hl book <COIN> [--live]` | Orderbook depth (static or live TUI) |
| `hl perps [--dex xyz]` | Perpetual markets |
| `hl spot` | Spot markets |
| `hl dexes` | HIP-3 DEXes |

### Streaming (7)
| Command | Description |
|---------|-------------|
| `hl stream trades <COIN>` | Real-time trade feed |
| `hl stream bbo <COIN>` | Best bid/offer |
| `hl stream book <COIN>` | L2 orderbook updates |
| `hl stream candles <COIN>` | OHLCV candles |
| `hl stream mids` | All mid prices |
| `hl stream fills <ADDR>` | User fills |
| `hl stream orders <ADDR>` | Order status updates |

### Account (8)
| Command | Description |
|---------|-------------|
| `hl portfolio [ADDR] [--all-dexes]` | Full portfolio (positions + spot + HIP-3) |
| `hl positions [ADDR] [--all-dexes]` | Open positions (+ HIP-3 DEX positions) |
| `hl orders [ADDR]` | Open orders |
| `hl fills [ADDR]` | Recent fills |
| `hl balance [ADDR]` | Spot + perp balances |
| `hl status <OID>` | Order status |
| `hl leverage <COIN> [N]` | Query or set leverage |
| `hl referral [set CODE]` | Referral status or set code |

### Trading (10)
| Command | Aliases | Description |
|---------|---------|-------------|
| `hl buy <COIN> <SZ> [@PX]` | `long` | Limit or market buy |
| `hl sell <COIN> <SZ> [@PX]` | `short` | Limit or market sell |
| `hl buy BTC 1.0 --trigger-above 100000` | | Trigger order (TP) |
| `hl buy BTC 1.0 --trigger-below 60000` | | Trigger order (SL) |
| `hl buy BTC 1.0 @98000 --tp 105000 --sl 95000` | | Bracket order |
| `hl modify <COIN> <OID> <SZ> <PX>` | | Modify order |
| `hl cancel <COIN> [OID]` | | Cancel by OID or all for coin |
| `hl cancel --all` | | Cancel all orders |
| `hl twap <COIN> buy\|sell <SZ> --duration 1h` | | Time-weighted execution |
| `hl batch "buy BTC 0.1 @98000" "sell ETH 1.0"` | | Batch orders |

### Transfers (1)
| Command | Description |
|---------|-------------|
| `hl send <AMT> [TOKEN] <DEST>` | Transfers (perp↔spot, DEX, subaccount) |

### Terminal (1)
| Command | Description |
|---------|-------------|
| `hl trade [COIN]` | Full trading terminal (separate binary: hl-trade) |

### System (2)
| Command | Description |
|---------|-------------|
| `hl config` | Show loaded config |
| `hl help` | Usage guide |

## Trading Terminal (`hl-trade`)

Three-thread architecture:
- **UI thread** (4ms loop) — input, snapshot, render at 250fps
- **WS thread** (blocking reads) — l2Book, trades, candle, activeAssetCtx
- **REST thread** (500ms loop) — positions, orders, fills

Features: candlestick chart with interval cycling, live orderbook with depth bars,
trade tape, order entry (market + limit), positions/orders/fills tabs, coin switching,
Hyperliquid color palette, WebSocket streaming.

## Key Technical Decisions

- **5×52-bit Solinas field** — 2.4× faster than Montgomery
- **GLV endomorphism** — halves doublings in signing
- **Zero allocations on signing hot path** — all stack buffers, comptime
- **Byte-exact MessagePack** — matches Rust `rmp-serde::to_vec_named`
- **Smart decimal formatting** — auto-scales precision by magnitude
- **Pipe-aware output** — JSON when piped, tables on TTY
- **Blocking WS + shutdown()** — no SO_RCVTIMEO (crashes macOS TLS)
- **Parse outside lock, apply under lock** — minimizes lock hold time

## Config

```bash
# .env or ~/.hl/config or env vars
HL_KEY=0x...          # Private key
HL_ADDRESS=0x...      # Default address
HL_CHAIN=mainnet      # mainnet or testnet
```

Precedence: flags > env vars > .env > ~/.hl/config > defaults

## What's Verified Live

- ✅ Place/cancel/modify orders (all asset types)
- ✅ Market orders with FrontendMarket TIF
- ✅ Asset resolution (perp, spot, HIP-3 DEX)
- ✅ USDC/token/asset transfers
- ✅ WebSocket streaming (7 subscription types)
- ✅ Full trading terminal with real-time data
- ✅ Leverage query and set
- ✅ Cancel by coin (batch)
- ✅ All 18 info + 14 exchange endpoints
- ✅ E2E test suite: 17/17 passing
