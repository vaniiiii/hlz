# Agent Integration

hlz is designed for AI agents and automated workflows. Every command works non-interactively with structured output.

## Design Guarantees

| Property | Guarantee |
|----------|-----------|
| **No prompts** | Every command completes without user input |
| **Structured output** | JSON when piped, `--json` flag always available |
| **Semantic exit codes** | `0`=OK, `1`=error, `2`=usage, `3`=auth, `4`=network |
| **Dry-run mode** | `--dry-run` previews any trade without submitting |
| **Stdin batch** | Pipe order lists via `--stdin` |
| **Deterministic** | Same inputs → same outputs (except market data) |

## Detecting Output Mode

hlz auto-detects whether stdout is a TTY:

```bash
# TTY: colored tables
hlz positions

# Piped: JSON automatically
hlz positions | jq .

# Explicit JSON
hlz positions --json

# Minimal output
hlz price BTC -q    # Just: 97432.5
```

## Agent Workflow Examples

### Check-then-trade

```bash
PRICE=$(hlz price BTC -q)
if (( $(echo "$PRICE < 50000" | bc -l) )); then
  hlz buy BTC 0.1 @${PRICE} --json
fi
```

### Monitor and react

```bash
hlz stream trades BTC | while read -r line; do
  SIZE=$(echo "$line" | jq -r '.sz')
  if (( $(echo "$SIZE > 10" | bc -l) )); then
    echo "Large trade detected: $line"
    # React to whale trades
  fi
done
```

### Batch from file

```bash
# orders.txt:
# buy BTC 0.1 @98000
# buy ETH 1.0 @3400
# sell SOL 100 @180

cat orders.txt | hlz batch --stdin --json
```

### Portfolio snapshot

```bash
# Capture full state as JSON
hlz portfolio --json > snapshot_$(date +%s).json
hlz orders --json >> snapshot_$(date +%s).json
```

## Environment Variables

Configure everything via environment for CI/agents:

```bash
export HL_KEY="private_key_hex"       # Trading key
export HL_ADDRESS="0x..."             # Default address
export HL_CHAIN="mainnet"             # or testnet
export HL_OUTPUT="json"               # Always JSON
export HL_PASSWORD="keystore_pass"    # Keystore password
```

## Error Handling

Errors are written to stderr. JSON errors include a structured envelope:

```bash
hlz buy INVALID 0.1 2>/dev/null
echo $?  # 2 (usage error)

hlz buy BTC 0.1 @50000 --json 2>&1
# stderr: {"error":"missing key","code":3}
```

## Rate Limits

Hyperliquid API: 1200 requests/minute per IP. The CLI doesn't add any additional throttling — manage this in your agent logic.

## Agent-Approve Workflow

For security, use a dedicated API wallet:

```bash
# Generate a new API wallet
hlz keys new api-agent

# Approve it from your main wallet
hlz approve-agent 0xAPI_WALLET_ADDRESS

# Agent uses the API wallet (limited permissions)
export HL_KEY_NAME=api-agent
```
