# Trading Terminal

`hlz-terminal` (or `hlz trade`) is a full-featured trading terminal for Hyperliquid.

## Launch

```bash
hlz trade BTC              # Open with BTC
hlz trade ETH              # Open with ETH
hlz trade                  # Opens with default market
```

## Features

- **Candlestick chart** — Multiple timeframes (1m, 5m, 15m, 1h, 4h, 1d)
- **Live order book** — Depth visualization with bid/ask spread
- **Trade tape** — Real-time fills with size highlighting
- **Order entry** — Place, modify, cancel from the terminal
- **Position display** — Current positions with PnL
- **Double-buffered rendering** — only changed cells written to terminal

## Architecture

The terminal runs three threads:

| Thread | Loop | Data |
|--------|------|------|
| **UI** (main) | 4ms — `pollKey → snapshot → render` | Never blocks on I/O |
| **WS** | Blocking reads | l2Book, trades, candle, assetCtx |
| **REST** | 500ms poll | positions, orders, fills |

All three communicate through **Shared State** protected by a mutex. Workers write, UI snapshots.

**Key rule**: UI thread never does network I/O. Workers never touch the terminal buffer.

## State Model

- **UiState** — Owned by UI thread. Cursor position, panel focus, input buffer. Never locked.
- **Shared** — Written by workers, read by UI via snapshot. Locked with a mutex.
- **Snapshot** — Immutable copy taken under lock once per frame. Render reads freely.

## Colors

Uses the Hyperliquid color palette:
- Green (#4ade80) for buys / positive PnL
- Red (#f87171) for sells / negative PnL
- Cyan for headers and highlights
- Gray for secondary information
