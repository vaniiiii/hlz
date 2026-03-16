# AGENTS.md — hlz

> AI coding agent instructions for working on this codebase.
> For human documentation, see [README.md](README.md) and [docs/](docs/).

## Project Overview

Zig SDK, CLI, and trading terminal for Hyperliquid.

- **Language**: Zig 0.15.2
- **Binaries**: `hlz` (895KB CLI), `hlz-terminal` (1121KB terminal)
- **API**: Hyperliquid L1 — https://api.hyperliquid.xyz

## Build & Run

```bash
zig build                              # Debug build → zig-out/bin/hl
zig build -Doptimize=ReleaseSmall      # Production (895KB)
zig build -Dfast-crypto=true           # Custom GLV (~3.4x faster signing, not audited for servers)
zig build test                         # Unit tests (183)
zig build bench                        # Signing benchmarks
zig build e2e                          # Live API tests (needs network + HL_KEY)
```

## Architecture

```
src/
├── lib/          Primitives (crypto, encoding, math) — no Hyperliquid knowledge
├── sdk/          Hyperliquid SDK (client, ws, signing, types) — imports lib/
├── tui/          TUI framework (Buffer, Terminal, Layout, List, Chart) — standalone
├── cli/          CLI tool (41 commands, args, config, output) — imports sdk/ + tui/
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

## Deeper Documentation

- `docs/pages/` — Vocs documentation source (CLI reference, SDK guide, TUI framework, guides)
- `README.md` — User-facing install, quick start, full command reference
- `WORKFLOW.md` — Symphony Pi orchestration config (do not edit unless changing workflow)

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
| `src/cli/args.zig` | Argument parser (41 commands) |
| `src/terminal/trade.zig` | Trading TUI |
| `src/tui/Buffer.zig` | Double-buffered cell grid |
| `src/lib/crypto/signer.zig` | secp256k1 ECDSA (stdlib default, custom GLV opt-in) |
| `src/lib/crypto/endo.zig` | GLV endomorphism (opt-in via `-Dfast-crypto`) |
| `src/lib/crypto/field.zig` | 5×52-bit field arithmetic for custom path |
| `src/lib/crypto/point.zig` | Projective point ops for custom path |

## Validation

```bash
zig build test          # MUST pass before every commit (unit + integration + crypto vectors)
zig build hlz           # Confirm CLI builds
zig build hlz-terminal  # Confirm terminal builds
```

CI runs all three on every PR (`.github/workflows/ci.yml`).

`zig build e2e` requires network + `HL_KEY` — skip in CI, run manually for API changes.

Tests use `std.testing.allocator` for leak detection.

## Dangerous / Special Paths

| Path | Rule |
|------|------|
| `src/lib/crypto/` | **Security-critical.** secp256k1, EIP-712, signing. Changes require running full test suite including `tests/ecdsa_wycheproof.zig`, `tests/ecdsa_differential.zig`, `tests/ecdsa_fuzz.zig`. Do not simplify or refactor without understanding the math. |
| `src/sdk/signing.zig` | **Must produce byte-exact MessagePack** matching Rust `rmp-serde::to_vec_named`. Test with `zig build e2e` against live API. |
| `src/sdk/types.zig` | **MessagePack wire format.** Field order and encoding matter. Changing field names/order breaks signing. |
| `docs/` | Vocs documentation site. Has its own `node_modules/`, `dist/`, `package.json`. Don't edit generated files in `docs/dist/` or `docs/node_modules/`. |
| `tests/vectors/`, `tests/fixtures/` | Test vectors from external sources (Wycheproof, etc.). Don't modify. |
| `hyperliquid-docs/` | Reference copy of upstream Hyperliquid docs. Don't modify. |

## Generated / Non-Editable

- `zig-out/`, `.zig-cache/` — build artifacts, gitignored
- `docs/node_modules/`, `docs/dist/` — docs build artifacts, gitignored
- `tests/vectors/` — external test vectors, treat as read-only

## PR Conventions

- Branch from `main`
- One logical change per PR
- All `zig build test` must pass before push
- PRs get the `symphony` label when created by Symphony Pi
- Squash merge preferred

## Skills

Repo-specific skills in `.pi/skills/`:

| Skill | When to use |
|-------|-------------|
| `add-cli-command` | Adding a new CLI subcommand to hlz |

## Common Mistakes

- Don't emit `\n` without `\r` in raw terminal mode
- Don't allocate in render loops
- Don't use `std.io.getStdOut()` (removed in Zig 0.15)
- Don't break JSON output shape between versions
- Don't modify crypto code without running the full crypto test suite
- Don't change field names/order in `types.zig` without verifying MessagePack output
