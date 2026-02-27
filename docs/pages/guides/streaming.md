# Streaming Market Data

Real-time data from Hyperliquid via WebSocket.

## Basic Streaming

```bash
# Trades (each line is a JSON trade)
hlz stream trades BTC

# Best bid/offer
hlz stream bbo ETH

# Full order book
hlz stream book BTC

# Candlesticks
hlz stream candles BTC

# All mid prices
hlz stream mids
```

## Piping to Files

```bash
# Log to JSONL file
hlz stream trades BTC >> btc_trades.jsonl

# Rotate daily
hlz stream trades BTC >> trades_$(date +%Y%m%d).jsonl
```

## Filtering with jq

```bash
# Only large trades (> 1 BTC)
hlz stream trades BTC | jq 'select(.sz > 1)'

# Only sells
hlz stream trades BTC | jq 'select(.side == "S")'

# Extract just price and size
hlz stream trades BTC | jq '{px: .px, sz: .sz}'
```

## Feeding to Other Programs

```bash
# Python consumer
hlz stream trades BTC | python3 my_analyzer.py

# Custom Zig program
hlz stream bbo ETH | ./my_strategy
```

## Multi-Stream

Run multiple streams in parallel:

```bash
# Background streams
hlz stream trades BTC > btc.jsonl &
hlz stream trades ETH > eth.jsonl &
hlz stream trades SOL > sol.jsonl &
wait
```

## User Event Streams

Monitor your own activity (requires auth):

```bash
# Your fills
hlz stream fills 0xYourAddress

# Your order updates
hlz stream orders 0xYourAddress
```
