# Buffer

`Buffer.zig` is a double-buffered cell grid for flicker-free terminal rendering.

## How It Works

1. **Write** to the current buffer (`buf`)
2. **Diff** against the previous buffer (`prev`)
3. **Emit** only changed cells to the terminal
4. **Swap** buffers

This minimizes terminal I/O and eliminates flicker.

## Color System

```zig
const Color = union(enum) {
    default,           // Terminal default
    basic: u8,         // 16-color (0-15)
    rgb: [3]u8,        // 24-bit RGB
};

// Comptime hex constructor
const green = Color.hex(0x4ade80);
const red = Color.hex(0xf87171);
```

## Cell Style

```zig
const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
};
```

## Performance Stats

Every flush produces `Buffer.Stats`:

| Field | Description |
|-------|-------------|
| `cells_changed` | Number of cells that differ from previous frame |
| `cursor_moves` | Number of cursor repositioning sequences emitted |
| `style_emits` | Number of SGR (color/style) sequences emitted |
| `write_bytes` | Total bytes written to terminal |
| `flush_ns` | Time taken for the flush operation |

## Synchronized Updates

Frames are wrapped in terminal synchronized update sequences:

```
\x1b[?2026h    ← begin synchronized update
... cell data ...
\x1b[?2026l    ← end synchronized update
```

This tells the terminal to batch all changes and display them atomically, preventing partial-frame artifacts.
