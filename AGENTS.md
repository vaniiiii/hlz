# AGENTS.md — hlz

> AI coding agent instructions for working on this codebase.
> For human documentation, see [README.md](README.md) and [docs/](docs/).

## Project Overview

Zig SDK, CLI, and trading terminal for Hyperliquid.

- **Language**: Zig 0.15.2
- **Binaries**: `hlz` (636KB CLI), `hlz-terminal` (768KB terminal)
- **API**: Hyperliquid L1 — https://api.hyperliquid.xyz

## Build & Run

```bash
zig build                              # Debug build → zig-out/bin/hl
zig build -Doptimize=ReleaseSmall      # Production (636KB)
zig build test                         # Unit tests (108)
zig build bench                        # Signing benchmarks
zig build e2e                          # Live API tests (needs network + HL_KEY)
```

## Architecture

```
src/
├── lib/          Primitives (crypto, encoding, math) — no Hyperliquid knowledge
├── sdk/          Hyperliquid SDK (client, ws, signing, types) — imports lib/
├── tui/          TUI framework (Buffer, Terminal, Layout, List, Chart) — standalone
├── cli/          CLI tool (38 commands, args, config, output) — imports sdk/ + tui/
└── terminal/     Trading terminal (trade.zig) — imports sdk/ + tui/
```

**Dependency rule: arrows point down only.**
- `lib/` depends on nothing
- `tui/` depends on nothing
- `sdk/` depends on `lib/`
- `cli/` and `terminal/` depend on `sdk/` + `tui/`

Never import upward.

## Code Style

### Zig Conventions
- `std.fs.File.stdout()` not `std.io.getStdOut()` (removed in 0.15)
- Explicit allocators everywhere, no global state
- `const` by default, `var` only when mutation needed
- No `catch {}` on non-trivial operations
- `@tagName` instead of manual `toString()`
- `std.meta.stringToEnum` instead of if/else string comparison chains

### Hot Paths
- Minimize allocations in signing, rendering, message parsing
- Stack buffers, comptime, fixed arrays (`MAX_ROWS=32`, `MAX_ITEMS=512`)
- Owned string buffers (`[16]u8`) not slices into freed JSON
- Arena with `reset(.retain_capacity)` for repeated allocs

### Thread Architecture (Terminal)
```
UI thread (4ms loop)     — pollKey → snapshot → render
WS thread (blocking)     — l2Book, trades, candle, activeAssetCtx
REST thread (500ms loop) — user positions, orders, fills
```
- UI thread never does network I/O
- Workers never touch Buffer/Terminal
- Parse outside lock, apply under lock

### Output & UX
- Pipe-aware: JSON when piped, tables on TTY
- **Read commands** (price, mids, funding, book, perps, spot, positions, orders, fills, balance, portfolio): normalize output — resolve `@index` to pair names, compute derived fields. The CLI is a UX layer.
- **Write commands** (buy, sell, cancel, modify, send, leverage, twap, batch): raw API passthrough — users need to verify exactly what the exchange returned.
- No interactive prompts
- Exit codes: 0=OK, 1=error, 2=usage, 3=auth, 4=network

### SDK Patterns
- One fetch per command — branch on `--json` early
- Response types have defaults on all fields
- `ParseOpts = .{ .ignore_unknown_fields = true, .allocate = .alloc_always }`
- camelCase field names matching JSON keys exactly
- MessagePack must be byte-exact with Rust `rmp-serde::to_vec_named`

## Hyperliquid API Gotchas

- Signature JSON: `{"r":"0x...","s":"0x...","v":27}` (structured, not flat hex)
- Body must include `"vaultAddress":null,"expiresAfter":null`
- Market orders use `FrontendMarket` TIF (not IOC with extreme price)
- WS ping/pong: server sends `Ping`, client responds `{"method":"pong"}`
- Don't use `SO_RCVTIMEO` with TLS on macOS (segfaults)
- Don't share `std.http.Client` across threads
- Prices in API are strings, not numbers

## Key Files

| File | Purpose |
|------|---------|
| `src/sdk/client.zig` | HTTP client (30 endpoints) |
| `src/sdk/signing.zig` | Signing orchestration |
| `src/sdk/types.zig` | Order types + msgpack |
| `src/sdk/ws.zig` | WebSocket subscriptions |
| `src/cli/main.zig` | Entry point, command dispatch |
| `src/cli/args.zig` | Argument parser (38 commands) |
| `src/terminal/trade.zig` | Trading TUI |
| `src/tui/Buffer.zig` | Double-buffered cell grid |
| `src/lib/crypto/signer.zig` | secp256k1 ECDSA |

## Testing

```bash
zig build test          # Unit tests — must pass before every commit
zig build e2e           # Live API tests — needs network + HL_KEY env
```

Tests use `std.testing.allocator` for leak detection.

## Common Mistakes

- Don't emit `\n` without `\r` in raw terminal mode
- Don't allocate in render loops
- Don't use `std.io.getStdOut()` (removed in Zig 0.15)
- Don't break JSON output shape between versions
