# Widgets

## List

`List.zig` — Scrollable list with search, sort, and pagination.

### Features

- **Vim-style navigation** — `j`/`k` or arrow keys
- **Search** — `/` to filter, `Esc` to clear
- **Sort** — `s` to cycle sort column
- **Pagination** — `n`/`p` for next/previous page
- **Static limits** — `MAX_ITEMS=512`, no dynamic allocation

### Used For

- Market browser (`hlz markets`)
- Perps list (`hlz perps`)
- Spot list (`hlz spot`)
- Funding rates (`hlz funding`)
- Mid prices (`hlz mids`)

## Chart

`Chart.zig` — Candlestick chart renderer using Unicode block characters.

### Features

- **OHLCV candles** with body and wick rendering
- **Auto-scaling** Y-axis based on visible data range
- **Multiple timeframes** — 1m, 5m, 15m, 1h, 4h, 1d
- **Color-coded** — Green for bullish, red for bearish candles
- **Zero allocations** — Fixed-size candle buffer on stack

### Rendering

Uses Unicode half-block characters (`▀`, `▄`, `█`) for sub-cell resolution, giving 2× vertical resolution compared to character-level rendering.
