//! Configuration loader for the `hl` CLI.
//!
//! Loads settings from (in priority order):
//! 1. Command-line flags (--key, --address, --chain)
//! 2. Environment variables (HL_KEY, HL_ADDRESS, HL_CHAIN)
//! 3. .env file in current directory
//! 4. ~/.hl/config file

const std = @import("std");
const hlz = @import("hlz");
const signer_mod = hlz.crypto.signer;
const signing = hlz.hypercore.signing;
const args_mod = @import("args.zig");
const keystore = @import("keystore.zig");

const Signer = signer_mod.Signer;
const Chain = signing.Chain;

pub const Config = struct {
    key_hex: ?[]const u8 = null,
    address: ?[]const u8 = null,
    chain: Chain = .mainnet,
    output_override: ?args_mod.OutputFormat = null,
    allocator: std.mem.Allocator,
    env_buf: ?[]u8 = null,
    key_alloc: ?[]u8 = null,
    derived_addr: [42]u8 = undefined,

    pub fn deinit(self: *Config) void {
        if (self.key_alloc) |k| {
            @memset(k, 0); // zero before free
            self.allocator.free(k);
        }
        if (self.env_buf) |buf| self.allocator.free(buf);
    }

    pub fn getSigner(self: Config) !Signer {
        const hex = self.key_hex orelse return error.MissingKey;
        return Signer.fromHex(hex);
    }

    pub fn getAddress(self: *const Config) ?[]const u8 {
        if (self.address) |a| return a;
        // Derive from key if available
        if (self.key_hex) |hex| {
            const signer = Signer.fromHex(hex) catch return null;
            const addr = signer.address;
            const self_mut = @constCast(self);
            self_mut.derived_addr[0] = '0';
            self_mut.derived_addr[1] = 'x';
            const chars = "0123456789abcdef";
            for (addr, 0..) |b, i| {
                self_mut.derived_addr[2 + i * 2] = chars[b >> 4];
                self_mut.derived_addr[2 + i * 2 + 1] = chars[b & 0xf];
            }
            self_mut.address = &self_mut.derived_addr;
            return &self_mut.derived_addr;
        }
        return null;
    }

    pub fn requireAddress(self: Config) ![]const u8 {
        return self.getAddress() orelse return error.MissingAddress;
    }
};

pub const ConfigError = error{
    MissingKey,
    MissingAddress,
    InvalidLength,
    InvalidCharacter,
};

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
    if (getEnv("HL_OUTPUT")) |v| {
        if (args_mod.OutputFormat.fromStr(v)) |fmt| {
            if (flags.output == .pretty and !flags.output_explicit) {
                config.output_override = fmt;
            }
        }
    }
    // Compatibility with e2e tests
    if (config.key_hex == null) {
        if (getEnv("TRADING_KEY")) |v| config.key_hex = v;
    }

    // Command-line flags override everything
    if (flags.key) |k| config.key_hex = k;
    if (flags.address) |a| config.address = a;
    if (std.mem.eql(u8, flags.chain, "testnet")) config.chain = .testnet;

    // --key-name: decrypt keystore to get key
    if (config.key_hex == null) {
        const key_name = flags.key_name orelse blk: {
            // Check for default key
            var dbuf: [64]u8 = undefined;
            break :blk keystore.getDefaultNameBuf(&dbuf);
        };
        if (key_name) |name| {
            const pw = getEnv("HL_PASSWORD");
            if (pw) |password| {
                const data = keystore.load(allocator, name) catch null;
                if (data) |ks_data| {
                    const priv = keystore.decrypt(allocator, ks_data, password) catch null;
                    allocator.free(ks_data);
                    if (priv) |pk| {
                        // Convert to hex string
                        const hex = allocator.alloc(u8, 64) catch null;
                        if (hex) |h| {
                            const chars = "0123456789abcdef";
                            for (pk, 0..) |b, i| {
                                h[i * 2] = chars[b >> 4];
                                h[i * 2 + 1] = chars[b & 0xf];
                            }
                            config.key_hex = h;
                            config.key_alloc = h;
                        }
                    }
                }
            }
        }
    }

    return config;
}

fn getEnv(name: []const u8) ?[]const u8 {
    const v = std.posix.getenv(name) orelse return null;
    return if (v.len == 0) null else v;
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
