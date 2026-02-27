# Getting Started

hlz gives you three things:

1. **`hlz`** — A 38-command CLI for Hyperliquid (636KB)
2. **`hlz-terminal`** — A full trading terminal (768KB)
3. **hlz** — A Zig library for building your own tools

## Install the CLI

```bash
# See https://github.com/vaniiiii/hlz/releases/latest for binaries
curl -fsSL -o hlz https://github.com/vaniiiii/hlz/releases/latest/download/hlz-darwin-arm64
chmod +x hlz
```

Or build from source:

```bash
git clone https://github.com/vaniiiii/hlz
cd hlz
zig build -Doptimize=ReleaseSmall
# Binary at zig-out/bin/hlz
```

## Configure

Set your private key:

```bash
# Option 1: Environment variable
export HL_KEY="your_private_key_hex"

# Option 2: Encrypted keystore (recommended)
hlz keys new default
# Enter password when prompted

# Option 3: Config file (~/.hlz.json)
echo '{"key_name":"default","address":"0x..."}' > ~/.hlz.json
```

## Your First Commands

No authentication needed for market data:

```bash
hlz price BTC              # Current price + spread
hlz funding --top 5        # Top funding rates
hlz book ETH --live        # Live order book
```

Place a trade:

```bash
hlz buy BTC 0.1 @50000     # Limit buy 0.1 BTC at $50,000
hlz sell ETH 1.0            # Market sell 1 ETH
```

Check your account:

```bash
hlz portfolio               # Positions + balances
hlz orders                  # Open orders
```

Launch the trading terminal:

```bash
hlz trade BTC               # Full TUI with chart, book, tape
```

## Use as a Zig Library

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .hlz = .{
        .url = "git+https://github.com/vaniiiii/hlz#main",
    },
},
```

Then in your code:

```zig
const hlz = @import("hlz");
const client = hlz.hypercore.client.Client.mainnet(allocator);
defer client.deinit();

// Fetch all mid prices (no auth needed)
var result = try client.getAllMids(null);
defer result.deinit();
// result.value is a parsed response
```

## Next Steps

- [CLI commands](/cli) — Full command reference
- [SDK guide](/sdk) — Building with the Zig library
- [Trading terminal](/terminal) — Terminal keybindings and features
- [Agent integration](/cli/agent-integration) — Using `hlz` in automated workflows
