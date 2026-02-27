# Installation

## Pre-built Binaries

Download from [GitHub Releases](https://github.com/vaniiiii/hlz/releases/latest):

```bash
# macOS (Apple Silicon)
curl -fsSL -o hlz https://github.com/vaniiiii/hlz/releases/latest/download/hlz-darwin-arm64
chmod +x hlz && sudo mv hlz /usr/local/bin/

# macOS (Intel)
curl -fsSL -o hlz https://github.com/vaniiiii/hlz/releases/latest/download/hlz-darwin-x64
chmod +x hlz && sudo mv hlz /usr/local/bin/

# Linux (x86_64, static)
curl -fsSL -o hlz https://github.com/vaniiiii/hlz/releases/latest/download/hlz-linux-x64
chmod +x hlz && sudo mv hlz /usr/local/bin/

# Linux (aarch64, static)
curl -fsSL -o hlz https://github.com/vaniiiii/hlz/releases/latest/download/hlz-linux-arm64
chmod +x hlz && sudo mv hlz /usr/local/bin/
```

## Build from Source

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
git clone https://github.com/vaniiiii/hlz
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
        .url = "git+https://github.com/vaniiiii/hlz#main",
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
# Download latest release
curl -fsSL -o hlz https://github.com/vaniiiii/hlz/releases/latest/download/hlz-darwin-arm64
chmod +x hlz && sudo mv hlz /usr/local/bin/

# Or from source
git pull && zig build -Doptimize=ReleaseSmall
```
