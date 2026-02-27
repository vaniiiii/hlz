# Streaming

Real-time WebSocket streams. Data flows continuously until you Ctrl+C.

## `hlz stream <TYPE> <COIN|ADDR>`

### Market Data Streams (No Auth)

```bash
hlz stream trades BTC       # Real-time trades
hlz stream bbo BTC          # Best bid/offer updates
hlz stream book ETH         # L2 order book updates
hlz stream candles BTC      # Candlestick updates
hlz stream mids             # All mid price updates
```

### User Streams (Requires Auth)

```bash
hlz stream fills 0xAddr     # User's trade fills
hlz stream orders 0xAddr    # User's order updates
```

### Output

Each message is a JSON line, making it easy to pipe:

```bash
# Log trades to file
hlz stream trades BTC >> btc_trades.jsonl

# Filter large trades
hlz stream trades BTC --json | jq 'select(.sz > 1)'

# Feed to another program
hlz stream bbo ETH | my_trading_bot
```

### WebSocket Details

- Server sends `Ping`, client responds with `{"method":"pong"}`
- Reconnects automatically on connection loss
- Messages are JSON, one per line
- Supports all 13 Hyperliquid subscription types
