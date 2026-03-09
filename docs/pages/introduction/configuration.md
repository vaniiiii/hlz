# Configuration

## Authentication

hlz needs a private key for trading operations. Market data commands work without auth.

### Encrypted Keystore (Recommended)

```bash
# Generate a new key
hlz keys new trading

# Import an existing key
hlz keys import trading --private-key 0xYOUR_KEY

# Set as default
hlz keys default trading

# List all keys
hlz keys ls
```

Keys are stored encrypted at `~/.hlz/keys/`. Use `--key-name` to select a specific key per command.

### Environment Variables

| Variable | Description |
|----------|-------------|
| `HL_KEY` | Private key (raw hex, no 0x prefix) |
| `HL_PASSWORD` | Keystore password (for `--key-name`) |
| `HL_ADDRESS` | Default wallet address (for read-only queries) |
| `HL_CHAIN` | Default chain: `mainnet` (default) or `testnet` |
| `HL_OUTPUT` | Default output format: `json`, `pretty`, or `csv` |
| `NO_COLOR` | Disable colored output |

### Config Files

hlz loads config from key=value files (same format as `.env`):

**Project-level** — `.env` in the current directory:

```bash
HL_KEY=your_private_key_hex
HL_ADDRESS=0xYourAddress
HL_CHAIN=mainnet
```

**System-level** — `~/.hl/config` (used as fallback if no `.env` found):

```bash
HL_KEY=your_private_key_hex
HL_ADDRESS=0xYourAddress
HL_CHAIN=mainnet
```

Supported keys: `HL_KEY`, `TRADING_KEY`, `HL_ADDRESS`, `ADDRESS`, `HL_CHAIN`, `CHAIN`.

### Priority Order

1. Command-line flags (`--key`, `--key-name`, `--chain`)
2. Environment variables (`HL_KEY`, `HL_CHAIN`)
3. `.env` file in current directory
4. `~/.hl/config` file
5. Defaults (mainnet, no key)

## Testnet

Add `--chain testnet` to any command:

```bash
hlz buy BTC 0.1 @50000 --chain testnet
```

Or set globally:

```bash
export HL_CHAIN=testnet
```

## Output Formats

| Flag | When | Format |
|------|------|--------|
| (none, TTY) | Interactive terminal | Colored tables |
| (none, piped) | `hlz price BTC \| jq` | JSON (auto-detected) |
| `--json` | Explicit | JSON |
| `--output pretty` | Explicit | Formatted tables |
| `--output csv` | Explicit | CSV |
| `--quiet` / `-q` | Minimal | Just the value |
