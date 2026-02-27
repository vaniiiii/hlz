# hyperzig — Execution Plan

## Vision

The best trading CLI ever made. Two binaries:
- **`hl`** (583KB) — fast, composable, agent-friendly CLI
- **`hl-trade`** (665KB) — full trading terminal

Not just a Hyperliquid tool — a universal trading kernel.

---

## What's Done

### Phase 0: Correctness ✅
- [x] Send routing (USDC/token/asset, perp↔spot↔DEX, subaccounts)
- [x] Market orders with FrontendMarket TIF + BBO slippage
- [x] Unified asset syntax (BTC, PURR/USDC, xyz:BTC)
- [x] Cancel by CLOID + modify orders
- [x] Asset index resolution from API metadata
- [x] Smart decimal formatting (auto-scales by magnitude)

### Phase 1: SDK + Streaming ✅
- [x] WebSocket streaming (7 types: trades, bbo, book, candles, mids, fills, orders)
- [x] SIGINT handling, ping/pong, reconnect on coin switch
- [x] 18 info + 14 exchange endpoints
- [x] Signing: order, cancel, cancelByCloid, modify, scheduleCancel,
      updateIsolatedMargin, updateLeverage, setReferrer, usdSend, spotSend,
      sendAsset, approveAgent, convertToMultiSig, evmUserModify, noop

### Phase 2: Interactive TUI ✅
- [x] TUI framework: Buffer, Terminal, Layout, List, Chart, App (1,682 lines)
- [x] All list commands interactive (markets, perps, spot, funding, mids)
- [x] vim-like navigation, search, sort, pagination
- [x] Enhanced live orderbook (trade tape, depth sparkline, hotkeys)
- [x] Full trading terminal (candlestick chart, order book, trade tape, order entry)
- [x] 3-thread architecture (UI + WS + REST)
- [x] Hyperliquid color palette, panel focus, coin switching

### Phase 2.5: Feature Parity ✅
- [x] 34 commands (exceeds both hypecli and hyperliquid-cli)
- [x] leverage query/set, portfolio, price (spot-aware), referral
- [x] Cancel by coin (batch), cancel all
- [x] long/short aliases
- [x] Two binaries: hl (CLI) and hl-trade (terminal)
- [x] Monorepo structure (lib/ sdk/ tui/ cli/ terminal/)

---

## What's Next

### Phase 3: Full HIP-3 Support ✅

- [x] **HIP-3 DEX balances** — `hl balance --all-dexes` shows per-DEX account value/margin
- [x] **HIP-3 positions across DEXes** — `hl positions --all-dexes` lists per-DEX positions
- [x] **DEX-aware portfolio** — `hl portfolio --all-dexes` includes all DEX positions and balances
- [x] **DEX-aware streaming** — `hl stream trades xyz:BTC` resolves through DEX metadata
- [x] Iterates all deployed DEXes via `perpDexs` endpoint, queries `clearinghouseState` per DEX

### Phase 4: Advanced Trading ✅

- [x] **TWAP** — `hl twap BTC buy 10.0 --duration 1h --slices 12`
  - Time-weighted execution: splits size into N slices over duration
  - Each slice: market order with configurable slippage bound (--slippage)
  - Progress as NDJSON stream (agent-friendly JSON output)
  - Summary with total filled and average price
- [x] **Trigger orders** — `hl buy BTC 1.0 --trigger-above 100000` (TP) / `--trigger-below 60000` (SL)
- [x] **Bracket orders** — `hl buy BTC 1.0 @98000 --tp 105000 --sl 95000`
  - Main order + TP + SL sent as NormalTpsl group
  - TP/SL are reduce-only market triggers on opposite side
- [x] **Batch orders** — `hl batch "buy BTC 0.1 @98000" "sell ETH 1.0 @3400"`
  - Up to 16 orders in one atomic batch
  - Each order string parsed independently (side coin size [@price])
  - Market orders auto-fetch BBO for slippage pricing

### Phase 5: Agent-First Protocol 🤖

Make `hl` the best CLI for AI agents to call. Every command becomes a reliable API.

#### 5.1 — Structured Output Envelope
Every command returns this in `--json` mode:
```json
{
  "v": 1,
  "cmd": "buy",
  "status": "ok",
  "data": { "oid": 12345, "filled": "0.5" },
  "errors": [],
  "warnings": [],
  "timing_ms": 45
}
```
- [ ] Define envelope struct in output.zig
- [ ] All commands emit this shape in JSON mode
- [ ] Errors include `code`, `retryable`, `hint`
- [ ] Stream commands emit NDJSON (one envelope per line)

#### 5.2 — Semantic Exit Codes
| Code | Meaning | Agent action |
|------|---------|-------------|
| 0 | Success | Proceed |
| 1 | User error (bad args, missing config) | Read stderr, fix invocation |
| 2 | Network error (timeout, connection) | Retry |
| 3 | Exchange rejected (insufficient margin, etc) | Read error, adjust |
| 4 | Authentication error | Fix key/config |

- [ ] Documented in `--help`
- [ ] Consistent across all commands
- [ ] Structured error JSON on stderr

#### 5.3 — Dry-Run Mode
```bash
hl buy BTC 1.0 @98000 --dry-run
```
- [ ] `--dry-run` on all mutating commands (buy, sell, cancel, send, leverage)
- [ ] Resolves asset, normalizes price to tick, validates size
- [ ] Shows margin impact and book depth analysis
- [ ] Zero network calls to exchange endpoint (info queries only)
- [ ] Returns structured JSON with `"dry_run": true`

#### 5.4 — Token Efficiency
- [ ] `--quiet` flag — minimal output (just the essential result)
- [ ] `--fields id,status,price` — select specific fields
- [ ] Concise defaults — don't dump 500 lines when 5 will do
- [ ] NDJSON for streaming (`--output jsonl`)

#### 5.5 — Non-Interactive Guarantees
- [ ] Never prompt in non-TTY mode (already mostly true)
- [ ] Respect `NO_COLOR` env var
- [ ] `HL_OUTPUT=json` env var to set JSON globally
- [ ] All errors to stderr, all data to stdout (already true)
- [ ] Consistent: no ANSI codes in JSON output

#### 5.6 — Idempotency + Verification
- [ ] Auto-generate CLOID for every order (already done) — log it in response
- [ ] `hl status <OID>` for agents to verify their work (already done)
- [ ] Safe retry: duplicate CLOID returns existing order, not error

#### 5.7 — Help as API Documentation
Rewrite `--help` to include:
- [ ] Exit codes section
- [ ] Environment variables section
- [ ] Concrete examples for every command
- [ ] Flag types and defaults

### Phase 6: Remaining Features 📊

- [ ] **Stdin batch** — `echo '{"orders":[...]}' | hl batch --stdin`
- [ ] **Config profiles** — `hl config set default.leverage 5`
- [ ] **TWAP crash recovery** — persistent state file for resume after crash
- [ ] **TWAP Ctrl-C** — graceful stop with partial fill report

### Phase 7: Portability 🌐

#### 7.1 — Binary Size Optimization
Current: 583KB (hl), 665KB (hl-trade). Target: <400KB for hl.
- [ ] Audit largest functions (size profiling)
- [ ] Strip unused JSON parsing paths
- [ ] Comptime string dedup
- [ ] Dead code elimination audit

#### 7.2 — C FFI (`libhyperzig.a`)
- [ ] `@export` key functions: sign, encode, HTTP
- [ ] Generate `hyperzig.h` header
- [ ] Python ctypes example
- [ ] Node.js ffi example

#### 7.3 — WASM Target
- [ ] Compile SDK core to WASM (signing + encoding only, no I/O)
- [ ] JavaScript wrapper for browser
- [ ] Benchmark: browser signing vs native

---

## Execution Order

```
NOW        Phase 5: Agent-first protocol
             5.1 Structured envelope
             5.2 Exit codes
             5.3 Dry-run
             5.4 Token efficiency
             5.5 Non-interactive
             5.6 Idempotency
             5.7 Help rewrite

THEN       Phase 6: Remaining features
           Phase 7: Portability (size, C FFI, WASM)
```

---

## Tracking

| Phase | Item | Status |
|-------|------|--------|
| 0 | Correctness (send, market orders, assets, cancel) | ✅ |
| 1 | SDK + WebSocket streaming | ✅ |
| 2 | Interactive TUI + trading terminal | ✅ |
| 2.5 | Feature parity (leverage, price, portfolio, referral) | ✅ |
| 3 | Full HIP-3 support | ✅ |
| 4 | Advanced trading (triggers, brackets, TWAP, batch) | ✅ |
| 5.1 | Structured JSON envelope | ⬜ |
| 5.2 | Semantic exit codes | ⬜ |
| 5.3 | Dry-run mode | ⬜ |
| 5.4 | Token efficiency (--quiet, --fields) | ⬜ |
| 5.5 | Non-interactive guarantees | ⬜ |
| 5.6 | Idempotency + verification | ⬜ |
| 5.7 | Help as API docs | ⬜ |
| 6 | Remaining features (config profiles, stdin batch) | ⬜ |
| 7.1 | Binary size optimization (<400KB) | ⬜ |
| 7.2 | C FFI | ⬜ |
| 7.3 | WASM | ⬜ |

---

## Design Principles

1. **Correct first** — signing and execution must be bulletproof
2. **One binary, one dep** — keep the static binary advantage
3. **Pipe-aware** — TTY gets TUI, pipe gets JSON
4. **Agent-native** — structured output, exit codes, dry-run, no prompts
5. **Zero alloc hot paths** — stack buffers, comptime, arena for responses
6. **Keyboard-first TUI** — every action has a keybinding
7. **Smart defaults** — works out of the box, power users customize
8. **Treat output as API** — don't break JSON shape between versions
