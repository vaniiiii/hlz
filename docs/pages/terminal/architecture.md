# Terminal Architecture

The trading terminal is a ~2,200 line single-file module (`src/terminal/trade.zig`) using the numbered-section pattern.

## Thread Model

| Thread | Rate | Reads | Writes |
|--------|------|-------|--------|
| **UI** (main) | 4ms loop | Shared State (snapshot) | Buffer, Terminal |
| **WS** | Blocking | WebSocket | Shared State (lock → write → unlock) |
| **REST** | 500ms poll | HTTP | Shared State (lock → write → unlock) |

**Shared State** holds: bids, asks, trades, candles, positions, orders, fills, asset context. Protected by a mutex with a generation counter for change detection.

- UI thread snapshots shared state (lock → memcpy → unlock), then renders from the snapshot
- Workers parse data outside the lock, then apply under the lock
- UI thread **never** does network I/O. Workers **never** touch Buffer/Terminal.

## State Ownership

### UiState (UI thread only)

```zig
const UiState = struct {
    focus: Panel,          // Which panel has focus
    cursor: usize,         // Cursor position in active list
    input_buf: [64]u8,     // Text input buffer
    input_len: usize,
    // ... never shared, never locked
};
```

### Shared (mutex-protected)

```zig
const Shared = struct {
    mu: std.Thread.Mutex,
    gen: u64,              // Bumped on every update
    bids: [64]BookLevel,
    asks: [64]BookLevel,
    trades: [128]Trade,
    candles: [512]Candle,
    // ... workers write, UI snapshots
};
```

### Snapshot (immutable copy)

```zig
fn takeSnapshot(shared: *Shared) Snapshot {
    shared.mu.lock();
    defer shared.mu.unlock();
    return .{
        .gen = shared.gen,
        .bids = shared.bids,
        .asks = shared.asks,
        // ... memcpy under lock, then render freely
    };
}
```

## Parse Outside Lock, Apply Under Lock

Workers follow this pattern for minimal lock contention:

```zig
fn decodeAndApplyBook(data: []const u8, shared: *Shared) void {
    // 1. Parse JSON (no lock held)
    const parsed = std.json.parseFromSlice(...) catch return;
    defer parsed.deinit();

    // 2. Build result on stack
    var bids: [64]BookLevel = undefined;
    // ... fill from parsed data

    // 3. Apply under lock (fast memcpy only)
    shared.applyBook(bids, asks, n, max_cum);
}
```

## Rendering

- **Double-buffered**: Write to `buf`, diff against `prev`, emit only changed cells
- **Synchronized updates**: Frames wrapped in `\x1b[?2026h` ... `\x1b[?2026l`
- **Incremental SGR**: Track fg/bg/bold/dim state, emit only diffs
- **No allocations**: All rendering uses stack buffers and the pre-allocated Buffer grid

## Coin Switching

When the user switches coins:
1. UI writes new coin to Shared
2. UI calls `shutdown()` on the WS socket file descriptor
3. WS thread detects the closed socket, reads new coin from Shared
4. WS thread reconnects with new subscriptions

This avoids `SO_RCVTIMEO` which corrupts macOS TLS state.
