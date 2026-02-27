# CLAUDE.md — hyperzig

## What is this?

A Zig monorepo for Hyperliquid: SDK, CLI, TUI framework, and trading terminal.
Single external dependency (websocket.zig). Targets HFT-grade performance.

## Architecture

```
lib/           core primitives (zero Hyperliquid knowledge)
 ├── crypto/    secp256k1, EIP-712, signer (field.zig, point.zig, endo.zig, eip712.zig, signer.zig)
 ├── encoding/  msgpack encoder (msgpack.zig)
 └── math/      decimal type (decimal.zig)

sdk/           Hyperliquid SDK (imports lib/)
 ├── types.zig    order/action types, BatchOrder, TimeInForce
 ├── signing.zig  RMP→agent hash, EIP-712 orchestration, Chain enum
 ├── client.zig   HTTP client (18 info + 12 exchange endpoints)
 ├── ws.zig       WebSocket connection, subscriptions, message parsing
 ├── response.zig response type definitions
 ├── json.zig     JSON helpers (getString, getArray)
 └── tick.zig     tick size rounding

tui/           TUI framework (standalone, no SDK dependency)
 ├── Buffer.zig    double-buffered cell grid, RGB color, diff flush
 ├── Terminal.zig  raw mode, input ring buffer, key parsing
 ├── Layout.zig    two-pass constraint layout engine
 ├── List.zig      scrollable list widget with search/sort
 ├── Chart.zig     candlestick chart renderer
 └── App.zig       frame lifecycle (beginFrame/endFrame/pollKey)

cli/           CLI tool (imports sdk/ + tui/)
 ├── main.zig      entry point, command dispatch
 ├── args.zig      argument parser (30 commands)
 ├── commands.zig  command implementations
 ├── config.zig    config file (~/.hl.json)
 └── output.zig    pipe-aware output (JSON when piped, tables on TTY)

terminal/      trading terminal (imports sdk/ + tui/)
 └── trade.zig     full trading TUI (WS streaming, chart, book, orders)
```

**Dependency rule: arrows point down only.**

```
terminal/  cli/
    ↓       ↓
   tui/    sdk/
    ↓       ↓
          lib/
```

tui/ depends on nothing. lib/ depends on nothing.
sdk/ depends on lib/. cli/ and terminal/ depend on sdk/ + tui/.

## Directory layout

```
src/
├── lib/                    core primitives (2,464 lines)
│   ├── crypto/             secp256k1, EIP-712, signer
│   ├── encoding/           msgpack encoder
│   └── math/               decimal type
├── sdk/                    Hyperliquid SDK (3,188 lines)
│   ├── client.zig          HTTP client
│   ├── ws.zig              WebSocket
│   ├── signing.zig         signing orchestration
│   ├── types.zig           order/action types
│   ├── response.zig        response types
│   ├── json.zig            JSON helpers
│   └── tick.zig            tick rounding
├── tui/                    TUI framework (1,682 lines)
│   ├── Buffer.zig          double-buffered cell grid
│   ├── Terminal.zig         raw mode, input
│   ├── Chart.zig           candlestick renderer
│   ├── Layout.zig          constraint layout
│   ├── List.zig            scrollable list
│   └── App.zig             frame lifecycle
├── cli/                    CLI tool (3,244 lines)
│   ├── main.zig            entry point
│   ├── args.zig            argument parser
│   ├── commands.zig         30 command implementations
│   ├── config.zig          config loader
│   └── output.zig          pipe-aware output
├── terminal/               trading terminal (1,225 lines)
│   └── trade.zig           full TUI trading interface
└── root.zig                public API (re-exports lib/ + sdk/)
```

Public API surface: `src/root.zig` re-exports lib/ + sdk/.

## Build targets

```bash
zig build                    # debug build → zig-out/bin/hl
zig build -Doptimize=ReleaseSmall   # ~650KB stripped
zig build -Doptimize=ReleaseFast    # ~1.4MB, fastest
zig build test               # all unit + integration tests
zig build bench              # signing benchmarks
zig build e2e                # live API end-to-end tests (needs network)
```

## Coding conventions

### Single-file structure (for files >500 lines)

Organize into numbered sections with const-namespace "mini modules":

```zig
// ╔═══════════════════════════╗
// ║  1. TYPES & STATE         ║
// ╚═══════════════════════════╝
const UiState = struct { ... };
const Shared = struct { ... };
const Snapshot = struct { ... };

// ╔═══════════════════════════╗
// ║  2. WORKERS               ║
// ╚═══════════════════════════╝
const WsWorker = struct {
    fn run(...) void { ... }
    fn decodeAndApplyBook(...) void { ... }
};

// ╔═══════════════════════════╗
// ║  3. INPUT                 ║
// ╚═══════════════════════════╝
const Input = struct { ... };

// ╔═══════════════════════════╗
// ║  4. RENDER                ║
// ╚═══════════════════════════╝
const Render = struct { ... };
```

### State ownership

- **UiState** — only UI thread reads/writes. Never locked.
- **Shared** — workers write, UI snapshots. Always locked via `mu`.
- **Snapshot** — immutable copy taken under lock. Render reads this freely.

Shared state updates use `apply*()` helpers (one lock, one gen bump):
```zig
fn applyBook(self: *Shared, bids: ..., asks: ...) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.bids = bids;
    self.gen += 1;
}
```

### Thread architecture

```
UI thread (4ms loop)     — pollKey → snapshot → render
WS thread (blocking)     — l2Book, trades, candle, activeAssetCtx
REST thread (500ms loop) — user positions, orders, fills
```

- UI thread NEVER does network I/O
- Workers NEVER touch Buffer/Terminal
- WS uses blocking reads + `shutdown(fd)` to break out (no SO_RCVTIMEO — corrupts macOS TLS)
- Coin/interval changes: UI writes to Shared, then `shutdown()` WS socket → reconnect

### Parse outside lock, apply under lock

```zig
fn decodeAndApplyBook(data: []const u8, shared: *Shared) void {
    // 1. Parse JSON (no lock held)
    const parsed = std.json.parseFromSlice(...) catch return;
    defer parsed.deinit();
    // 2. Build result on stack
    var bids: [64]BookLevel = undefined;
    // ... fill bids ...
    // 3. Apply under lock
    shared.applyBook(bids, asks, n, max_cum);
}
```

### Style rules

- **No heap allocations in hot paths.** Stack buffers, comptime, fixed arrays.
- **Owned string buffers.** BookLevel/InfoData use `[16]u8` buffers, not slices into freed JSON.
- **Pipe-aware output.** `isatty()` → tables. Piped → JSON. `--json` forces JSON.
- **UTF-8 escape sequences as hex literals.** `"\xe2\x94\x80"` not `"─"` in programmatic code.
- **Minimal comments.** Code should be self-documenting. Section headers only.
- **Static limits.** `MAX_ROWS=32`, `MAX_COLS=8`, `MAX_ITEMS=512`. No dynamic arrays in TUI.

### Zig 0.15.2 specifics

- `std.fs.File.stdout()` not `std.io.getStdOut()`
- `std.crypto.tls.Client.init()` needs `*Io.Reader`, `*Writer` with `read_buffer`/`write_buffer`
- Union fields and methods can't share names → use free functions for constructors
- `std.posix.Sigaction.mask` is `sigset_t` (zero-init)
- VTIME=0 VMIN=0 for truly non-blocking terminal reads

### TUI rendering

- **Synchronized updates**: frames wrapped in `\x1b[?2026h` ... `\x1b[?2026l`
- **Incremental SGR**: track fg/bg/bold/dim state, emit only diffs
- **Double-buffered**: write to `buf`, diff against `prev`, emit only changes
- **Buffer.Stats**: `cells_changed`, `cursor_moves`, `style_emits`, `write_bytes`, `flush_ns`
- **Color**: `union(enum)` with `.default`, `.basic(u8)`, `.rgb([3]u8)`. `Color.hex(0xRRGGBB)` comptime.

### Hyperliquid API

- MessagePack must be byte-exact with Rust `rmp-serde::to_vec_named`
- Action serde tag: `#[serde(tag = "type")]` — type field inside msgpack map
- Signature JSON: `{"r":"0x...","s":"0x...","v":27}` (structured, not flat hex)
- Body must include `"vaultAddress":null,"expiresAfter":null`
- Market orders use `FrontendMarket` TIF (not IOC with extreme price)
- WS requires app-level ping/pong: server sends `Ping`, client sends `{"method":"pong"}`

## SDK typing strategy

All API responses use typed structs via `std.json.parseFromSlice`. Every endpoint
has a `get*` method returning `Parsed(T)`. Raw methods exist only for `--json` passthrough.

### Command pattern

```zig
if (w.format == .json) {
    var raw = try client.clearinghouseState(addr, null);
    defer raw.deinit();
    try w.jsonRaw(raw.body);
    return;
}
var typed = try client.getClearinghouseState(addr, null);
defer typed.deinit();
// use typed.value...
```

Never fetch twice (once raw, once typed). Branch early on `--json`.

### Where raw JSON is correct

- **Exchange responses** (place, cancel, send): Variable structure, checked via `isOk()`.
- **allMids**: Returns `{"BTC": "65000.5", ...}` — dynamic-key dict. No auto-parse for this.
- **metaAndAssetCtxs**: Heterogeneous `[meta, [ctx, ...]]` tuple. Custom parse in `getMetaAndAssetCtxs()`.

### WS message data

`ws_types.extractData()` strips the outer `{"channel":"...","data":VALUE}` wrapper.
Decode functions receive VALUE directly — parse as the type, not wrapped in a `data` field.

### Adding a new typed endpoint

1. Add response struct to `response.zig` (camelCase fields, defaults for forward compat)
2. Add `get*` method to `client.zig` calling `self.infoTyped(T, body)`
3. Use in CLI/terminal directly — no intermediate parseTyped helper

## Post-work checklist

Run through after every change before committing:

### Code quality
- [ ] No `catch {}` on non-trivial operations (network, file I/O) — at minimum log or set status
- [ ] No stale comments referencing old patterns ("compat", "migrate", "to be removed", "fall back")
- [ ] No personal conversation artifacts in code ("as we discussed", "TODO: ask about")
- [ ] No chatty comments explaining obvious code — section headers only
- [ ] Dead code removed (unused functions, imports, variables)

### Zig patterns
- [ ] `errdefer` paired with every allocation that could fail before ownership transfer
- [ ] No `page_allocator` in hot paths — use arena with `reset(.retain_capacity)` for repeated allocs
- [ ] `@tagName` instead of manual `toString()` when tag names match desired strings
- [ ] `std.meta.stringToEnum` instead of if/else string comparison chains for enums
- [ ] `anytype` only for writer patterns — use `comptime T: type` or tagged unions for data

### SDK consistency
- [ ] One fetch per command — branch on `--json` early, don't fetch raw AND typed
- [ ] No `parseTyped` indirection — call typed client methods (`get*`) directly
- [ ] Response types have defaults on all fields (`= Decimal.ZERO`, `= ""`, `= 0`)
- [ ] `ParseOpts = .{ .ignore_unknown_fields = true, .allocate = .alloc_always }`
- [ ] camelCase field names matching JSON keys exactly

### File structure
- [ ] lib/ has zero Hyperliquid knowledge — pure primitives
- [ ] sdk/ never imports cli/ or tui/ or terminal/
- [ ] tui/ never imports sdk/ — standalone framework
- [ ] Arrows point down only: terminal/cli → tui/sdk → lib
- [ ] Single-file modules use numbered section headers, not scattered helpers

### Output & UX
- [ ] Pipe-aware: JSON when piped, tables on TTY
- [ ] `--json` passthrough uses raw body, not re-serialized typed data
- [ ] No interactive prompts — power tool, immediate execution
- [ ] Exit codes: 0=OK, 1=error, 2=usage, 3=auth, 4=network

## Key metrics

| Metric | Value |
|--------|-------|
| `hl` (ReleaseSmall, stripped) | **636KB** |
| `hl-trade` (ReleaseSmall, stripped) | **768KB** |
| SDK only (no HTTP/TLS) | **116KB** |
| Total source | **~14,645 lines** |
| External dependencies | **1** (websocket.zig) |
| Commands | **38** |
| Typed client methods | **21** |
| Response types | **62** |
| sign_order | **34.5µs** |
| eip712_struct_hash | **250ns** |
| UI frame rate | **250fps** |
| E2E tests | **17/17** |

## What NOT to do

- Don't use `SO_RCVTIMEO` with TLS on macOS (segfaults)
- Don't share `std.http.Client` across threads (not thread-safe)
- Don't allocate in render loops
- Don't use `std.io.getStdOut()` (removed in Zig 0.15)
- Don't emit `\n` without `\r` in raw terminal mode
- Don't use cassowary/constraint solvers for layout (overkill)
