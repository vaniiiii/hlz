# App

`App.zig` manages the frame lifecycle — the entry point for any TUI application.

## Usage

```zig
const tui = @import("tui");

var app = try tui.App.init();
defer app.deinit();  // restores terminal to cooked mode

while (true) {
    app.beginFrame();

    // ... render to app.buf ...

    if (app.pollKey()) |key| {
        switch (key) {
            'q' => break,
            else => {},
        }
    }

    app.endFrame();  // flushes buffer diff to terminal
}
```

## API

### `App.init() -> !App`

Initializes the terminal in raw mode and allocates the double buffer.

### `app.deinit()`

Restores terminal to cooked mode. Always call this (use `defer`).

### `app.beginFrame()`

Starts a new frame. Clears dirty state from previous frame.

### `app.endFrame()`

Flushes the buffer diff to the terminal. Only changed cells are written.

### `app.pollKey() -> ?Key`

Non-blocking key read. Returns `null` if no key is pressed.

Uses `VTIME=0 VMIN=0` for truly non-blocking reads — no blocking, no busy-wait.

### `app.size() -> struct { rows: u16, cols: u16 }`

Returns current terminal dimensions.

### `app.buf`

The current frame buffer. Write to this during your render phase.
