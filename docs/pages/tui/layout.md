# Layout

`Layout.zig` is a two-pass constraint layout engine for dividing terminal space.

## Constraints

```zig
const Constraint = union(enum) {
    fixed: u16,        // Exact number of cells
    min: u16,          // Minimum cells
    ratio: f32,        // Proportion of remaining space
    fill,              // Take all remaining space
};
```

## Usage

```zig
const Layout = tui.Layout;

// Horizontal split: 30-cell sidebar + fill
const cols = Layout.horizontal(size.width, &[_]Constraint{
    .{ .fixed = 30 },
    .fill,
});
// cols[0] = { .x = 0, .width = 30 }
// cols[1] = { .x = 30, .width = remaining }

// Vertical split: header + fill + status bar
const rows = Layout.vertical(size.height, &[_]Constraint{
    .{ .fixed = 1 },
    .fill,
    .{ .fixed = 1 },
});
```

## Two-Pass Algorithm

1. **First pass**: Allocate fixed and min constraints
2. **Second pass**: Distribute remaining space to ratio and fill constraints

No cassowary solver or constraint propagation — just direct arithmetic. Fast and predictable.
