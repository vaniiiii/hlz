# Agent Payments

Transfers on Hyperliquid are free and settle in under a second. No gas, no approval transactions. That makes it practical for agent-to-agent payments, even tiny ones.

## Setup

```bash
# Generate a wallet for your agent
hlz keys new agent

# Export for non-interactive use
export HL_KEY_NAME=agent
export HL_PASSWORD=your_password
```

The printed address is where your agent receives funds.

## Funding the Wallet

**Bridge from another chain** — [app.hyperliquid.xyz](https://app.hyperliquid.xyz) or [cctp.to](https://cctp.to) both work. Connect your wallet, pick a source chain (Ethereum, Arbitrum, Base, etc.), enter the amount, and send to your agent's address. Takes a few minutes.

**Transfer from another Hyperliquid account** — if someone already has funds on Hyperliquid, they can send directly:

```bash
hlz send 100 USDC 0xYourAgentAddress
```

## Sending Payments

```bash
# Send USDC to another address
hlz send 10 USDC 0xRecipientAddress --json

# Send HYPE tokens
hlz send 5 HYPE 0xRecipientAddress --json

# Exit code tells you what happened: 0 = ok, 4 = network error
echo $?
```

## Checking Balance

```bash
hlz balance --json | jq '.accountValue'

# Or just the number
hlz balance -q
```

## Spot vs Perps Balance

USDC exists in two places on Hyperliquid: your perps balance (for trading) and your spot balance (for token transfers). Bridged funds arrive in spot.

```bash
# Move bridged funds to perps for trading
hlz send 100 USDC --to perp

# Move back to spot for sending tokens
hlz send 50 USDC --to spot
```

## In a Script

```bash
#!/bin/bash
RESULT=$(hlz send "$1" "${3:-USDC}" "$2" --json 2>&1)
if [ $? -eq 0 ]; then
  echo "Sent $1 ${3:-USDC} to $2"
else
  echo "Failed: $RESULT" >&2
  exit 1
fi
```

## Supported Tokens

USDC, HYPE, and any listed spot token:

```bash
hlz spot --json | jq '.[].symbol'
```
