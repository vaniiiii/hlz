//! Rigorous benchmarks for HyperZig critical paths.
//!
//! Run: zig build bench
//!
//! Methodology:
//! - Warmup: 1000 iterations discarded
//! - Measurement: 10,000 iterations (100,000 for sub-μs ops)
//! - Per-iteration timing with std.time.Timer
//! - Report: min, median, p95, p99, mean, stddev
//!
//! Operations benchmarked:
//! - sign_order:         msgpack → keccak256 → Agent → EIP-712 → ECDSA
//! - sign_cancel:        same path, cancel payload
//! - sign_usd_send:      typed data: EIP-712 → sign
//! - msgpack_encode:     BatchOrder → msgpack bytes
//! - keccak256_32b:      raw hash of 32 bytes
//! - decimal_parse:      parse "50000.12345"
//! - decimal_normalize:  strip trailing zeros
//! - decimal_multiply:   two decimal multiply
//! - eip712_struct_hash: hash Agent struct (no signing)

const std = @import("std");
const hlz = @import("hlz");

const Signer = hlz.crypto.signer.Signer;
const Decimal = hlz.math.decimal.Decimal;
const types = hlz.hypercore.types;
const signing = hlz.hypercore.signing;
const msgpack = hlz.encoding.msgpack;
const eip712 = hlz.crypto.eip712;
const keccak256 = hlz.crypto.signer.keccak256;

// ── Shared test fixtures ──────────────────────────────────────────

const PRIVATE_KEY_HEX = "e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e";
const NONCE: u64 = 1234567890;

fn makeOrder() !types.OrderRequest {
    return .{
        .asset = 0,
        .is_buy = true,
        .limit_px = try Decimal.fromString("50000"),
        .sz = try Decimal.fromString("0.1"),
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };
}

fn makeBatch() !types.BatchOrder {
    const order = try makeOrder();
    return .{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };
}

fn makeCancel() types.BatchCancel {
    return .{
        .cancels = &[_]types.Cancel{.{ .asset = 0, .oid = 123456789 }},
    };
}

// ── Statistics ────────────────────────────────────────────────────

const Stats = struct {
    min_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    mean_ns: f64,
    stddev_ns: f64,
};

fn computeStats(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const n = samples.len;
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));

    var var_sum: f64 = 0;
    for (samples) |s| {
        const diff = @as(f64, @floatFromInt(s)) - mean;
        var_sum += diff * diff;
    }
    const stddev = @sqrt(var_sum / @as(f64, @floatFromInt(n)));

    return .{
        .min_ns = samples[0],
        .median_ns = samples[n / 2],
        .p95_ns = samples[@min(n - 1, n * 95 / 100)],
        .p99_ns = samples[@min(n - 1, n * 99 / 100)],
        .mean_ns = mean,
        .stddev_ns = stddev,
    };
}

// ── Formatting ────────────────────────────────────────────────────

fn fmtNs(ns: u64, buf: *[16]u8) []const u8 {
    if (ns >= 1_000_000) {
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}ms", .{ms}) catch "???";
    } else if (ns >= 1_000) {
        const us = @as(f64, @floatFromInt(ns)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.1}\xc2\xb5s", .{us}) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "???";
    }
}

fn fmtF64Ns(ns: f64, buf: *[16]u8) []const u8 {
    const abs = if (ns < 0) -ns else ns;
    if (abs >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.1}ms", .{ns / 1_000_000.0}) catch "???";
    } else if (abs >= 1_000) {
        return std.fmt.bufPrint(buf, "{d:.1}\xc2\xb5s", .{ns / 1_000.0}) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0}ns", .{ns}) catch "???";
    }
}

fn printStats(name: []const u8, stats: Stats) void {
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [16]u8 = undefined;
    var b4: [16]u8 = undefined;
    var b5: [16]u8 = undefined;
    var b6: [16]u8 = undefined;
    std.debug.print("  {s:<22} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        name,
        fmtNs(stats.min_ns, &b1),
        fmtNs(stats.median_ns, &b2),
        fmtNs(stats.p95_ns, &b3),
        fmtNs(stats.p99_ns, &b4),
        fmtF64Ns(stats.mean_ns, &b5),
        fmtF64Ns(stats.stddev_ns, &b6),
    });
}

// ── Benchmark runner (heap-allocated samples) ─────────────────────

const allocator = std.heap.page_allocator;

fn runBenchIndexed(warmup: usize, iterations: usize, func: *const fn (u64) void) !Stats {
    // Warmup
    for (0..warmup) |i| func(@intCast(i));

    // Allocate samples on the heap
    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        func(@intCast(i));
        samples[i] = timer.read();
    }

    return computeStats(samples);
}

fn runBenchSimple(warmup: usize, iterations: usize, func: *const fn () void) !Stats {
    // Warmup
    for (0..warmup) |_| func();

    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        func();
        samples[i] = timer.read();
    }

    return computeStats(samples);
}

// ── Individual benchmark functions ────────────────────────────────

var g_signer: Signer = undefined;
var g_batch: types.BatchOrder = undefined;
var g_cancel: types.BatchCancel = undefined;

fn benchSignOrder(idx: u64) void {
    const nonce: u64 = NONCE + idx;
    const sig = signing.signOrder(g_signer, g_batch, nonce, .mainnet, null, null) catch unreachable;
    std.mem.doNotOptimizeAway(&sig);
}

fn benchSignCancel(idx: u64) void {
    const nonce: u64 = NONCE + idx;
    const sig = signing.signCancel(g_signer, g_cancel, nonce, .mainnet, null, null) catch unreachable;
    std.mem.doNotOptimizeAway(&sig);
}

fn benchSignUsdSend(idx: u64) void {
    const time: u64 = 1690393044548 + idx;
    const sig = signing.signUsdSend(
        g_signer,
        .mainnet,
        "0x0D1d9635D0640821d15e323ac8AdADfA9c111414",
        "1",
        time,
    ) catch unreachable;
    std.mem.doNotOptimizeAway(&sig);
}

fn benchMsgpackEncode() void {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    types.packActionOrder(&p, g_batch) catch unreachable;
    std.mem.doNotOptimizeAway(p.written());
}

fn benchKeccak32b() void {
    const input = [_]u8{0xab} ** 32;
    const hash = keccak256(&input);
    std.mem.doNotOptimizeAway(&hash);
}

fn benchDecimalParse() void {
    const d = Decimal.fromString("50000.12345") catch unreachable;
    std.mem.doNotOptimizeAway(&d);
}

fn benchDecimalNormalize() void {
    const d = Decimal{ .mantissa = 5000012345, .scale = 5 };
    const n = d.normalize();
    std.mem.doNotOptimizeAway(&n);
}

fn benchDecimalMultiply() void {
    const a = Decimal{ .mantissa = 5000012345, .scale = 5 };
    const b = Decimal{ .mantissa = 100001, .scale = 5 };
    const c = a.mul(b);
    std.mem.doNotOptimizeAway(&c);
}

fn benchEip712StructHash() void {
    const connection_id = [_]u8{0xab} ** 32;
    const hash = eip712.hashAgent("a", connection_id);
    std.mem.doNotOptimizeAway(&hash);
}

// ── Main ──────────────────────────────────────────────────────────

pub fn main() !void {
    // Initialize shared state
    g_signer = try Signer.fromHex(PRIVATE_KEY_HEX);
    g_batch = try makeBatch();
    g_cancel = makeCancel();

    const arch = @tagName(@import("builtin").target.cpu.arch);
    const os = @tagName(@import("builtin").target.os.tag);

    std.debug.print("\n=== HyperZig Benchmarks ({s}-{s}, ReleaseFast) ===\n\n", .{ arch, os });
    std.debug.print("  {s:<22} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "Operation", "Min", "Median", "P95", "P99", "Mean", "StdDev",
    });
    std.debug.print("  {s}\n", .{"-" ** 88});

    // sign_order: 1000 warmup, 10000 iterations
    printStats("sign_order", try runBenchIndexed(1_000, 10_000, &benchSignOrder));
    printStats("sign_cancel", try runBenchIndexed(1_000, 10_000, &benchSignCancel));
    printStats("sign_usd_send", try runBenchIndexed(1_000, 10_000, &benchSignUsdSend));
    printStats("msgpack_encode", try runBenchSimple(1_000, 100_000, &benchMsgpackEncode));
    printStats("keccak256_32b", try runBenchSimple(1_000, 100_000, &benchKeccak32b));
    printStats("decimal_parse", try runBenchSimple(1_000, 100_000, &benchDecimalParse));
    printStats("decimal_normalize", try runBenchSimple(1_000, 100_000, &benchDecimalNormalize));
    printStats("decimal_multiply", try runBenchSimple(1_000, 100_000, &benchDecimalMultiply));
    printStats("eip712_struct_hash", try runBenchSimple(1_000, 100_000, &benchEip712StructHash));

    std.debug.print("\n", .{});
}
