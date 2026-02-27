# Installation

## Pre-built Binaries

```bash
curl -fsSL https://hlz.dev/install.sh | sh
```

This downloads the latest release for your platform and installs:
- `hlz` — CLI tool (636KB)
- `hlz-terminal` — Trading terminal (768KB)

Supported platforms:
- macOS (Apple Silicon, Intel)
- Linux (x86_64, aarch64)

## Build from Source

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
git clone https://github.com/hlz/hlz
cd hlz

# Debug build (fast compile, larger binary)
zig build

# Production build (636KB stripped binary)
zig build -Doptimize=ReleaseSmall

# Fastest execution (1.4MB)
zig build -Doptimize=ReleaseFast
```

Binaries are output to `zig-out/bin/`.

## As a Zig Dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .hlz = .{
        .url = "git+https://github.com/hlz/hlz#main",
    },
},
```

Then in `build.zig`:

```zig
const hlz_dep = b.dependency("hlz", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("hlz", hlz_dep.module("hlz"));
```

## Verify Installation

```bash
hlz version
hlz price BTC     # Should show current BTC price
```

## Updating

```bash
# Pre-built binary
curl -fsSL https://hlz.dev/install.sh | sh

# From source
git pull && zig build -Doptimize=ReleaseSmall
```
