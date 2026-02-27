# Transfers

Send tokens between addresses and between balance contexts (perp ↔ spot).

## `hlz send <AMOUNT> [TOKEN] <DESTINATION>`

### Send to Another Address

```bash
# Send USDC (default token)
hlz send 100 0xRecipientAddress

# Send a specific token
hlz send 5 HYPE 0xRecipientAddress

# Send spot token
hlz send 10 PURR/USDC 0xRecipientAddress
```

### Internal Transfers

Move funds between your own perp and spot balances:

```bash
# Perp → Spot
hlz send 100 USDC --to spot

# Spot → Perp
hlz send 100 USDC --to perp
```

Transfers on Hyperliquid are **free and instant** — no gas fees.
