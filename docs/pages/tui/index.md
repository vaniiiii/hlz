# TUI Framework

hlz includes a standalone TUI framework for building terminal applications. It has no SDK dependency — you can use it for anything.

## Why

We needed a small TUI layer for the trading terminal and interactive list views. ~1,800 lines, just enough to get the job done.

## Modules

| Module | Lines | What it does |
|--------|-------|-------------|
| [App.zig](/tui/app) | 108 | Frame lifecycle — `beginFrame`, `endFrame`, `pollKey` |
| [Buffer.zig](/tui/buffer) | 482 | Double-buffered cell grid, RGB color, diff-based flush |
| [Terminal.zig](/tui/terminal) | 197 | Raw mode, terminal size, non-blocking input |
| [Layout.zig](/tui/layout) | 193 | Two-pass constraint layout (fixed, min, ratio, fill) |
| [List.zig](/tui/widgets) | 380 | Scrollable list with search, sort, pagination |
| [Chart.zig](/tui/widgets) | 408 | Candlestick chart with Unicode half-blocks |

## How It Fits Together

```
App.init()
  ├── Terminal.init()    enters raw mode
  └── Buffer.init()      allocates cell grids

loop:
  app.beginFrame()
    ├── Layout.horizontal/vertical()   divide space
    ├── List.render(buf, region)       draw widgets
    ├── Chart.render(buf, region)
    └── buf.putStr(...)                direct cell writes
  app.endFrame()
    └── buf.flush()   diff against prev, emit only changes

app.deinit()
  └── Terminal.deinit()   restores cooked mode
```

## Design Choices

- **No allocations in render** — all stack buffers and fixed arrays
- **Static limits** — `MAX_ROWS=32`, `MAX_COLS=8`, `MAX_ITEMS=512`, `MAX_CANDLES=512`
- **Double buffered** — write to `buf`, diff against `prev`, emit only changed cells
- **Synchronized updates** — `\x1b[?2026h` ... `\x1b[?2026l` wrapping for atomic frame display
- **Double buffered diff flush** — only changed cells get written to the terminal
- **No dependencies** — pure Zig stdlib. Doesn't import the SDK or anything else.

## Quick Example

```zig
const tui = @import("tui");

var app = try tui.App.init();
defer app.deinit();

while (true) {
    app.beginFrame();

    const size = app.size();
    app.buf.putStr(0, 0, "Hello from hlz TUI!", .{
        .fg = .{ .rgb = .{ 0xf7, 0xa4, 0x1d } },
    });

    if (app.pollKey()) |key| {
        if (key == 'q') break;
    }

    app.endFrame();
}
```
