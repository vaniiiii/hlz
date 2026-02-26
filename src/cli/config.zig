//! Configuration loader for the `hl` CLI.
//!
//! Loads settings from (in priority order):
//! 1. Command-line flags (--key, --address, --chain)
//! 2. Environment variables (HL_KEY, HL_ADDRESS, HL_CHAIN)
//! 3. .env file in current directory
//! 4. ~/.hl/config file

const std = @import("std");
const hyperzig = @import("hyperzig");
const signer_mod = hyperzig.crypto.signer;
const signing = hyperzig.hypercore.signing;
const args_mod = @import("args.zig");

const Signer = signer_mod.Signer;
const Chain = signing.Chain;

pub const Config = struct {
    key_hex: ?[]const u8 = null,
    address: ?[]const u8 = null,
    chain: Chain = .mainnet,
    allocator: std.mem.Allocator,
    env_buf: ?[]u8 = null,

    pub fn deinit(self: *Config) void {
        if (self.env_buf) |buf| self.allocator.free(buf);
    }

    pub fn getSigner(self: Config) !Signer {
        const hex = self.key_hex orelse return error.MissingKey;
        return Signer.fromHex(hex);
    }

    pub fn getAddress(self: Config) ?[]const u8 {
        if (self.address) |a| return a;
        return null;
    }

    pub fn requireAddress(self: Config) ![]const u8 {
        return self.getAddress() orelse return error.MissingAddress;
    }
};

pub const ConfigError = error{
    MissingKey,
    MissingAddress,
} || signer_mod.Signer.FromHexError;

pub fn load(allocator: std.mem.Allocator, flags: args_mod.GlobalFlags) Config {
    var config = Config{ .allocator = allocator };

    // Load .env file first (lowest priority)
    loadEnvFile(allocator, &config);

    // Environment variables override .env
    if (getEnv("HL_KEY")) |v| config.key_hex = v;
    if (getEnv("HL_ADDRESS")) |v| config.address = v;
    if (getEnv("HL_CHAIN")) |v| {
        if (std.mem.eql(u8, v, "testnet")) config.chain = .testnet;
    }
    // Compatibility with e2e tests
    if (config.key_hex == null) {
        if (getEnv("TRADING_KEY")) |v| config.key_hex = v;
    }

    // Command-line flags override everything
    if (flags.key) |k| config.key_hex = k;
    if (flags.address) |a| config.address = a;
    if (std.mem.eql(u8, flags.chain, "testnet")) config.chain = .testnet;

    return config;
}

fn getEnv(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

fn loadEnvFile(allocator: std.mem.Allocator, config: *Config) void {
    const buf = std.fs.cwd().readFileAlloc(allocator, ".env", 64 * 1024) catch {
        const home = std.posix.getenv("HOME") orelse return;
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/config", .{home}) catch return;
        const buf2 = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return;
        config.env_buf = buf2;
        parseEnvBuf(buf2, config);
        return;
    };
    config.env_buf = buf;
    parseEnvBuf(buf, config);
}

fn parseEnvBuf(buf: []const u8, config: *Config) void {
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (parseEnvLine(trimmed, "TRADING_KEY=") orelse parseEnvLine(trimmed, "HL_KEY=")) |v| {
            if (config.key_hex == null) config.key_hex = v;
        } else if (parseEnvLine(trimmed, "HL_ADDRESS=") orelse parseEnvLine(trimmed, "ADDRESS=")) |v| {
            if (config.address == null) config.address = v;
        } else if (parseEnvLine(trimmed, "HL_CHAIN=") orelse parseEnvLine(trimmed, "CHAIN=")) |v| {
            if (std.mem.eql(u8, v, "testnet")) config.chain = .testnet;
        }
    }
}

fn parseEnvLine(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var value = line[prefix.len..];
    value = std.mem.trim(u8, value, " \t\"'");
    if (value.len == 0) return null;
    return value;
}
