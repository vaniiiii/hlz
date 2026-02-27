# hyperzig — Execution Plan

## Vision

The best trading CLI ever made. Two binaries:
- **`hl`** (636KB) — fast, composable, agent-friendly CLI
- **`hl-trade`** (768KB) — full trading terminal

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
- [x] 21 typed client methods (get* prefix) + 62 response types
- [x] Signing: order, cancel, cancelByCloid, modify, scheduleCancel,
      updateIsolatedMargin, updateLeverage, setReferrer, usdSend, spotSend,
      sendAsset, approveAgent, convertToMultiSig, evmUserModify, noop

### Phase 2: Interactive TUI ✅
- [x] TUI framework: Buffer, Terminal, Layout, List, Chart, App (1,768 lines)
- [x] All list commands interactive (markets, perps, spot, funding, mids)
- [x] vim-like navigation, search, sort, pagination
- [x] Enhanced live orderbook (trade tape, depth sparkline, hotkeys)
- [x] Full trading terminal (candlestick chart, order book, trade tape, order entry)
- [x] 3-thread architecture (UI + WS + REST)
- [x] Hyperliquid color palette, panel focus, coin switching

### Phase 2.5: Feature Parity ✅
- [x] 38 commands (exceeds both hypecli and hyperliquid-cli)
- [x] leverage query/set, portfolio, price (spot-aware), referral
- [x] Cancel by coin (batch), cancel all
- [x] long/short aliases
- [x] Two binaries: hl (CLI) and hl-trade (terminal)
- [x] Monorepo structure (lib/ sdk/ tui/ cli/ terminal/)

### Phase 3: Full HIP-3 Support ✅
- [x] HIP-3 DEX balances — `hl balance --all-dexes`
- [x] HIP-3 positions across DEXes — `hl positions --all-dexes`
- [x] DEX-aware portfolio — `hl portfolio --all-dexes`
- [x] DEX-aware streaming — `hl stream trades xyz:BTC`
- [x] Iterates all deployed DEXes via `perpDexs` endpoint

### Phase 4: Advanced Trading ✅
- [x] TWAP — `hl twap BTC buy 10.0 --duration 1h --slices 12`
- [x] Trigger orders — `--trigger-above` (TP) / `--trigger-below` (SL)
- [x] Bracket orders — `--tp 105000 --sl 95000`
- [x] Batch orders — `hl batch "buy BTC 0.1 @98000" "sell ETH 1.0 @3400"`

### Phase 5: Agent-First Protocol (Partial) ✅
- [x] 5.2 — Semantic exit codes (0=OK, 1=error, 2=usage, 3=auth, 4=network)
- [x] 5.3 — Dry-run mode (`--dry-run` on buy/sell)
- [x] 5.4 — Token efficiency (`--quiet`, auto-JSON on pipe)
- [x] 5.5 — Non-interactive (NO_COLOR, HL_OUTPUT env, no prompts, pipe-aware)
- [x] 5.6 — Stdin batch (`hl batch --stdin`)

### Phase 5.5: Key Management ✅
- [x] Encrypted keystore (`~/.hl/keys/<name>.json`, Ethereum V3 format)
- [x] `hl key-gen`, `hl key-list`, `hl key-import`
- [x] Config precedence: `--key` > `--key-name` > `HL_KEY` > default key
- [x] Agent API wallet approval (`hl approve-agent`)
- [x] Address auto-derived from key (no separate HL_ADDRESS needed)

### Phase 5.6: SDK Typization ✅
- [x] 21 typed client methods via std.json.parseFromSlice
- [x] 62 response types with camelCase auto-parse
- [x] All CLI commands migrated to typed (15 raw JSON remaining, all justified)
- [x] All terminal workers migrated to typed
- [x] fromJsonCompat bridges eliminated
- [x] Arena allocator for WS message parsing

### Phase 5.7: Code Quality ✅
- [x] @tagName replaces manual toString() on all enums
- [x] std.meta.stringToEnum for WS channel parsing
- [x] Chain.name()/sigChainId() helpers
- [x] errdefer on all allocation paths
- [x] Error propagation (no silent catch {} on non-trivial ops)
- [x] Binary size optimization (strip, unwind_tables=none, gc-sections)
- [x] Post-work checklist + coding standards in CLAUDE.md

---

## What's Next

### Phase 5 Remaining ⬜

- [ ] **5.1 — Structured JSON envelope**
  ```json
  {"v":1,"cmd":"buy","status":"ok","data":{...},"errors":[],"timing_ms":45}
  ```
  All commands emit this shape in `--json` mode.

- [ ] **5.7 — Help as API docs**
  Rewrite `--help` to include exit codes, env vars, examples for every command.

### Phase 6: Terminal Actions ⬜

Action launcher modal for the trading terminal:
- [ ] Action registry (static ActionId enum + ActionSpec)
- [ ] 2 form types: confirm (yes/no), number (int/f64 + min/max/step)
- [ ] `v` key opens action launcher
- [ ] Migrate leverage flow to action system
- [ ] Cancel-all and close-selected as confirm actions
- [ ] Bottom table scrolling in terminal
- [ ] Book-price click (select price from orderbook)

### Phase 7: Polish ⬜

- [ ] Config profiles (`hl config set`, `--profile`)
- [ ] Shell completion (`hl completion bash/zsh/fish`)
- [ ] TWAP crash recovery (persistent state file)
- [ ] TWAP Ctrl-C (graceful stop with partial fill report)
- [ ] Chart.zig adaptive time axis labels (change ready, uncommitted)

### Phase 8: Portability 🌐

- [ ] C FFI (`libhyperzig.a`) — @export key functions, generate hyperzig.h
- [ ] WASM target — signing + encoding only, no I/O
- [ ] Linux cross-compile fix (sigset_t type mismatch in hl-trade)

---

## Tracking

| Phase | Item | Status |
|-------|------|--------|
| 0 | Correctness | ✅ |
| 1 | SDK + streaming | ✅ |
| 2 | Interactive TUI + terminal | ✅ |
| 2.5 | Feature parity (38 commands) | ✅ |
| 3 | Full HIP-3 support | ✅ |
| 4 | Advanced trading (TWAP, triggers, brackets, batch) | ✅ |
| 5.2 | Semantic exit codes | ✅ |
| 5.3 | Dry-run mode | ✅ |
| 5.4 | Quiet + auto-JSON | ✅ |
| 5.5 | Non-interactive guarantees | ✅ |
| 5.6 | Stdin batch | ✅ |
| 5.5+ | Key management + approve-agent | ✅ |
| 5.6+ | SDK typization (21 methods, 62 types) | ✅ |
| 5.7+ | Code quality + binary optimization | ✅ |
| 5.1 | Structured JSON envelope | ⬜ |
| 5.7 | Help as API docs | ⬜ |
| 6 | Terminal actions (modal, leverage, cancel-all) | ⬜ |
| 7 | Polish (config, completion, TWAP recovery) | ⬜ |
| 8.1 | C FFI | ⬜ |
| 8.2 | WASM | ⬜ |

---

## Key Metrics

| Metric | Value |
|--------|-------|
| `hl` (ReleaseSmall, stripped) | **636 KB** |
| `hl-trade` (ReleaseSmall, stripped) | **768 KB** |
| SDK only (no HTTP/TLS) | **116 KB** |
| Total source | **~14,645 lines** |
| External dependencies | **1** (websocket.zig) |
| Commands | **38** |
| Typed client methods | **21** |
| Response types | **62** |
| sign_order | **34.5µs** |
| eip712_struct_hash | **250ns** (4.5× faster than Rust) |
| E2E tests | **17/17** |
| Unit tests | **108** |

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
