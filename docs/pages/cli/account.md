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

## `hlz withdraw <AMOUNT> [DESTINATION]`

Bridge withdrawal to Arbitrum.

```bash
hlz withdraw 100                # Withdraw to own address
hlz withdraw 100 0xDest...      # Withdraw to specific address
```

## `hlz transfer <AMOUNT> --to-spot|--to-perp`

Move USDC between spot and perp balances.

```bash
hlz transfer 100 --to-spot
hlz transfer 50 --to-perp
```

## `hlz stake <delegate|undelegate|status> [ARGS]`

Staking operations.

```bash
hlz stake status                                        # View staking summary
hlz stake delegate 0xValidator... 1000000000000000000    # Delegate (wei)
hlz stake undelegate 0xValidator... 1000000000000000000  # Undelegate (wei)
```

## `hlz vault [info|deposit|withdraw] [ARGS]`

Vault operations.

```bash
hlz vault 0xVault...            # View vault details (shorthand)
hlz vault info 0xVault...       # View vault details (explicit)
hlz vault deposit 0xVault... 100
hlz vault withdraw 0xVault... 50
```

## `hlz subaccount <ls|create|transfer> [ARGS]`

Sub-account management. Also accepts `hlz sub` as shorthand.

```bash
hlz subaccount ls                                        # List sub-accounts
hlz subaccount create myaccount                          # Create sub-account
hlz subaccount transfer 0xSub... 100                     # USDC transfer (deposit)
hlz subaccount transfer 0xSub... 100 --withdraw          # USDC transfer (withdraw)
hlz subaccount transfer 0xSub... 10 --token PURR         # Spot token transfer
```

## `hlz approve-agent <ADDRESS> [--name NAME]`

Approve an API agent wallet.

```bash
hlz approve-agent 0xAgent...
hlz approve-agent 0xAgent... --name my-bot
```

## `hlz account [standard|unified|portfolio]`

View or change account abstraction mode. Controls how spot and perp balances interact.

- **standard** — Separate spot and perp wallets. You must `hlz transfer --to-perp` before trading perps. Required for builder code addresses. No daily action limit.
- **unified** — Single balance per asset, shared across all perps and spot. Default on app.hyperliquid.xyz. 50k actions/day limit.
- **portfolio** — Portfolio margin (pre-alpha). Most capital efficient, unifies HYPE/BTC/USDH/USDC as collateral. 50k actions/day limit.

```bash
hlz account                 # Show current mode
hlz account standard        # Switch to standard (separate wallets)
hlz account unified         # Switch to unified (single balance)
hlz account portfolio       # Switch to portfolio margin
```

See [Account Abstraction Modes](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/account-abstraction-modes) for full details.

## `hlz approve-builder <BUILDER> <MAX_FEE_RATE>`

Approve a builder fee rate. The rate is a percent string (e.g. `"0.001%"` = 0.001%).

```bash
hlz approve-builder 0xBuilder... "0.001%"
```

## HIP-3 DEX Queries

Account commands support HIP-3 DEX filtering:

```bash
hlz positions --dex xyz         # Positions on a specific DEX
hlz orders --all-dexes          # Orders across all DEXes
```
