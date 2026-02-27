# Guides

Step-by-step guides for common tasks.

## Getting Started

- [Building a Trading Bot](/guides/trading-bot) — Automated order placement and monitoring
- [Streaming Market Data](/guides/streaming) — Real-time data pipelines
- [Agent Payments](/guides/agent-payments) — Using `hlz` for AI agent payments

## Common Patterns

### Quick Price Check → Trade

```bash
PRICE=$(hlz price BTC -q)
hlz buy BTC 0.1 @${PRICE}
```

### Monitor → React

```bash
hlz stream trades BTC | while read -r line; do
  echo "$line" | jq -r '.sz' | xargs -I {} sh -c '
    if [ $(echo "{} > 10" | bc) -eq 1 ]; then
      echo "Whale alert: {} BTC"
    fi
  '
done
```

### Portfolio Snapshot

```bash
hlz portfolio --json > portfolio_$(date +%Y%m%d).json
```

### Batch Execution

```bash
cat <<EOF | hlz batch --stdin
buy BTC 0.1 @98000
buy ETH 1.0 @3400
sell SOL 100 @180
EOF
```
