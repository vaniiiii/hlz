# Terminal

`Terminal.zig` handles raw mode, terminal size detection, and input.

## Raw Mode

Entering raw mode disables:
- Line buffering (characters available immediately, not after Enter)
- Echo (typed characters aren't displayed)
- Signal handling for Ctrl+C (you handle it yourself)

```zig
var term = try tui.Terminal.init();  // enters raw mode
defer term.deinit();                  // restores cooked mode
```

Always pair `init` with `deinit` via `defer`. If your program crashes without restoring cooked mode, the terminal will be unusable (run `reset` to fix).

## Terminal Size

```zig
const size = term.getSize();
// size.rows, size.cols
```

## Input

The terminal uses a ring buffer for input and `VTIME=0 VMIN=0` for non-blocking reads. This means:
- `pollKey()` returns immediately with `null` if no input
- No busy-wait, no blocking
- Escape sequences (arrow keys, function keys) are parsed into single key events

## Raw Mode Details

On POSIX systems, raw mode sets:
- `ICANON` off — no line buffering
- `ECHO` off — no character echo
- `ISIG` off — no signal generation from Ctrl+C etc
- `VTIME=0, VMIN=0` — non-blocking reads

## Important

- Always emit `\r\n` not just `\n` in raw mode (the terminal won't do CR for you)
- Use hex literals for escape sequences: `"\x1b[2J"` not literal escape chars
- Don't use `SO_RCVTIMEO` with TLS on macOS — it corrupts state
