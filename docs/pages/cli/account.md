# Account

Account commands show positions, orders, fills, and balances. They require an address — either via `--address`, `HL_ADDRESS`, config file, or derived from your key.

## `hlz portfolio [ADDR]`

Combined view of positions and spot balances.

```bash
hlz portfolio
hlz portfolio 0x1234...     # View another address
```

## `hlz positions [ADDR]`

Open perpetual positions.

```bash
hlz positions
hlz positions --json | jq '.[] | {coin, size, pnl}'
```

## `hlz orders [ADDR]`

Open orders.

```bash
hlz orders
hlz orders --json
```

## `hlz fills [ADDR]`

Recent trade fills.

```bash
hlz fills
hlz fills --json | jq '.[] | select(.coin == "BTC")'
```

## `hlz balance [ADDR]`

Account balance and margin health.

```bash
hlz balance
```

## `hlz status <OID>`

Check the status of a specific order by OID.

```bash
hlz status 12345
hlz status 12345 --json
```

## `hlz referral [set <CODE>]`

View referral status or set a referral code.

```bash
hlz referral                # View current status
hlz referral set MYCODE     # Set referral code
```

## HIP-3 DEX Queries

Account commands support HIP-3 DEX filtering:

```bash
hlz positions --dex xyz         # Positions on a specific DEX
hlz orders --all-dexes          # Orders across all DEXes
```
