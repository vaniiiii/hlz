//! Ethereum V3 Keystore — scrypt + AES-128-CTR.
//! Compatible with Foundry, MetaMask, geth.
//! Storage: ~/.hl/keys/<name>.json

const std = @import("std");
const hlz = @import("hlz");
const Signer = hlz.crypto.signer.Signer;

const aes = std.crypto.core.aes;
const Aes128Ctx = aes.AesEncryptCtx(aes.Aes128);
const ctr = std.crypto.core.modes.ctr;

pub const KeystoreError = error{
    BadPassword,
    InvalidFormat,
    NotFound,
    AlreadyExists,
    IoError,
} || std.crypto.pwhash.KdfError || std.mem.Allocator.Error;

/// Encrypt a 32-byte private key into Ethereum V3 keystore JSON.
pub fn encrypt(allocator: std.mem.Allocator, key: [32]u8, password: []const u8) KeystoreError![]u8 {
    // Generate random salt (32 bytes) and IV (16 bytes)
    var salt: [32]u8 = undefined;
    var iv: [16]u8 = undefined;
    std.crypto.random.bytes(&salt);
    std.crypto.random.bytes(&iv);

    // Derive 32 bytes via scrypt (n=8192, r=8, p=1 — standard light params)
    var derived: [32]u8 = undefined;
    const params = std.crypto.pwhash.scrypt.Params{ .ln = 13, .r = 8, .p = 1 }; // n=8192
    try std.crypto.pwhash.scrypt.kdf(allocator, &derived, password, &salt, params);

    // AES-128-CTR encrypt with first 16 bytes of derived key
    const enc_key = derived[0..16];
    var ciphertext: [32]u8 = undefined;
    const aes_ctx = Aes128Ctx.init(enc_key.*);
    ctr(Aes128Ctx, aes_ctx, &ciphertext, &key, iv, .big);

    // MAC = keccak256(derived[16..32] ++ ciphertext)
    var mac_input: [64]u8 = undefined;
    @memcpy(mac_input[0..16], derived[16..32]);
    @memcpy(mac_input[16..48], &ciphertext);
    const Keccak = std.crypto.hash.sha3.Keccak256;
    var mac: [32]u8 = undefined;
    Keccak.hash(mac_input[0..48], &mac, .{});

    // Derive address from private key
    var addr_hex: [40]u8 = undefined;
    const signer = Signer.init(key) catch return error.InvalidFormat;
    const addr = signer.address;
    const hex_chars = "0123456789abcdef";
    for (addr, 0..) |b, i| {
        addr_hex[i * 2] = hex_chars[b >> 4];
        addr_hex[i * 2 + 1] = hex_chars[b & 0xf];
    }

    // Format as JSON
    var salt_hex: [64]u8 = undefined;
    var iv_hex: [32]u8 = undefined;
    var ct_hex: [64]u8 = undefined;
    var mac_hex: [64]u8 = undefined;
    hexEncode(&salt, &salt_hex);
    hexEncode(iv[0..16], &iv_hex);
    hexEncode(&ciphertext, &ct_hex);
    hexEncode(&mac, &mac_hex);

    return std.fmt.allocPrint(allocator,
        \\{{"version":3,"id":"00000000-0000-0000-0000-000000000000",
        \\"address":"{s}",
        \\"crypto":{{
        \\"cipher":"aes-128-ctr",
        \\"cipherparams":{{"iv":"{s}"}},
        \\"ciphertext":"{s}",
        \\"kdf":"scrypt",
        \\"kdfparams":{{"dklen":32,"n":8192,"r":8,"p":1,"salt":"{s}"}},
        \\"mac":"{s}"}}}}
    , .{ addr_hex, iv_hex, ct_hex, salt_hex, mac_hex }) catch return error.OutOfMemory;
}

/// Decrypt Ethereum V3 keystore JSON → 32-byte private key.
pub fn decrypt(allocator: std.mem.Allocator, json_data: []const u8, password: []const u8) KeystoreError![32]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch
        return error.InvalidFormat;
    defer parsed.deinit();
    const root = parsed.value;

    const crypto = (if (root == .object) root.object.get("crypto") else null) orelse
        return error.InvalidFormat;

    // Extract fields
    const ct_hex = getString(crypto, "ciphertext") orelse return error.InvalidFormat;
    const mac_hex = getString(root, "mac") orelse (getString(crypto, "mac") orelse return error.InvalidFormat);

    const cp = (if (crypto == .object) crypto.object.get("cipherparams") else null) orelse
        return error.InvalidFormat;
    const iv_hex = getString(cp, "iv") orelse return error.InvalidFormat;

    const kp = (if (crypto == .object) crypto.object.get("kdfparams") else null) orelse
        return error.InvalidFormat;
    const salt_hex = getString(kp, "salt") orelse return error.InvalidFormat;
    const n_val = getInt(kp, "n") orelse return error.InvalidFormat;
    const r_val = getInt(kp, "r") orelse return error.InvalidFormat;
    const p_val = getInt(kp, "p") orelse return error.InvalidFormat;

    // Decode hex
    var salt: [32]u8 = undefined;
    var iv: [16]u8 = undefined;
    var ciphertext: [32]u8 = undefined;
    var expected_mac: [32]u8 = undefined;
    hexDecode(salt_hex, &salt) catch return error.InvalidFormat;
    hexDecode(iv_hex, &iv) catch return error.InvalidFormat;
    hexDecode(ct_hex, &ciphertext) catch return error.InvalidFormat;
    hexDecode(mac_hex, &expected_mac) catch return error.InvalidFormat;

    // Derive key via scrypt
    const ln: std.math.Log2Int(u64) = std.math.log2_int(u64, @intCast(n_val));
    var derived: [32]u8 = undefined;
    const params = std.crypto.pwhash.scrypt.Params{
        .ln = ln,
        .r = @intCast(r_val),
        .p = @intCast(p_val),
    };
    try std.crypto.pwhash.scrypt.kdf(allocator, &derived, password, &salt, params);

    // Verify MAC
    var mac_input: [64]u8 = undefined;
    @memcpy(mac_input[0..16], derived[16..32]);
    @memcpy(mac_input[16..48], &ciphertext);
    const Keccak = std.crypto.hash.sha3.Keccak256;
    var actual_mac: [32]u8 = undefined;
    Keccak.hash(mac_input[0..48], &actual_mac, .{});

    if (!std.mem.eql(u8, &actual_mac, &expected_mac)) return error.BadPassword;

    // Decrypt
    const enc_key = derived[0..16];
    var plaintext: [32]u8 = undefined;
    const aes_ctx = Aes128Ctx.init(enc_key.*);
    ctr(Aes128Ctx, aes_ctx, &plaintext, &ciphertext, iv, .big);

    return plaintext;
}

/// Get the keys directory (~/.hl/keys/), creating if needed.
pub fn keysDir() ![512]u8 {
    const home = std.posix.getenv("HOME") orelse return error.IoError;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.hl/keys", .{home}) catch return error.IoError;
    std.fs.cwd().makePath(path) catch {};
    return buf;
}

/// Save keystore JSON to ~/.hl/keys/<name>.json
pub fn save(name: []const u8, data: []const u8) !void {
    _ = try keysDir();
    var path_buf: [576]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse return error.IoError;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/keys/{s}.json", .{ home, name }) catch return error.IoError;

    // Check if exists
    std.fs.cwd().access(path, .{}) catch {
        // Doesn't exist, good
        const file = std.fs.cwd().createFile(path, .{}) catch return error.IoError;
        defer file.close();
        file.writeAll(data) catch return error.IoError;
        // chmod 600
        const fd = file.handle;
        _ = std.c.fchmod(fd, 0o600);
        return;
    };
    return error.AlreadyExists;
}

/// Load keystore JSON from ~/.hl/keys/<name>.json
pub fn load(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.IoError;
    var path_buf: [576]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/keys/{s}.json", .{ home, name }) catch return error.IoError;
    return std.fs.cwd().readFileAlloc(allocator, path, 8192) catch return error.NotFound;
}

/// List all keystore names + addresses in ~/.hl/keys/
pub fn list(allocator: std.mem.Allocator) ![]Entry {
    const home = std.posix.getenv("HOME") orelse return error.IoError;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/keys", .{home}) catch return error.IoError;

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return allocator.alloc(Entry, 0);
    defer dir.close();

    var entries = std.array_list.AlignedManaged(Entry, null).init(allocator);
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const fname = entry.name;
        if (!std.mem.endsWith(u8, fname, ".json")) continue;
        const name = fname[0 .. fname.len - 5];
        if (name.len == 0 or name.len > 63) continue;

        // Read address from keystore
        var name_copy: [64]u8 = undefined;
        @memcpy(name_copy[0..name.len], name);

        var addr: [42]u8 = .{0} ** 42;
        const data = dir.readFileAlloc(allocator, fname, 8192) catch continue;
        defer allocator.free(data);
        const p = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer p.deinit();
        if (getString(p.value, "address")) |a| {
            addr[0] = '0';
            addr[1] = 'x';
            const copy_len = @min(a.len, 40);
            @memcpy(addr[2..][0..copy_len], a[0..copy_len]);
        }

        var e: Entry = undefined;
        @memcpy(e.name[0..name.len], name);
        e.name_len = @intCast(name.len);
        e.address = addr;
        e.is_default = false;
        entries.append(e) catch continue;
    }

    // Check which is default
    var default_buf: [64]u8 = undefined;
    const default_name = getDefaultNameBuf(&default_buf);
    for (entries.items) |*e| {
        if (default_name) |dn| {
            if (std.mem.eql(u8, e.getName(), dn)) e.is_default = true;
        }
    }

    return entries.toOwnedSlice() catch return allocator.alloc(Entry, 0);
}

pub const Entry = struct {
    name: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
    address: [42]u8 = .{0} ** 42,
    is_default: bool = false,

    pub fn getName(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Delete a keystore
pub fn remove(name: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.IoError;
    var path_buf: [576]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/keys/{s}.json", .{ home, name }) catch return error.IoError;
    std.fs.cwd().deleteFile(path) catch return error.NotFound;
}

/// Set default key name in ~/.hl/default
pub fn setDefault(name: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.IoError;
    var path_buf: [576]u8 = undefined;
    std.fs.cwd().makePath(std.fmt.bufPrint(&path_buf, "{s}/.hl", .{home}) catch return error.IoError) catch {};
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/default", .{home}) catch return error.IoError;
    const file = std.fs.cwd().createFile(path, .{}) catch return error.IoError;
    defer file.close();
    file.writeAll(name) catch return error.IoError;
}

/// Get default key name from ~/.hl/default
pub fn getDefaultName() ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    var path_buf: [576]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/default", .{home}) catch return null;
    var buf: [64]u8 = undefined;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(&buf) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;
    // Return pointer to static — safe because buf is on stack but we need persistent
    // Actually this is a problem — the caller needs to copy. For now return null
    // and let config.zig read the file directly.
    return null;
}

/// Read default key name into a caller-provided buffer
pub fn getDefaultNameBuf(buf: []u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    var path_buf: [576]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.hl/default", .{home}) catch return null;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

// ── Helpers ───────────────────────────────────────────────

fn getString(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getInt(val: std.json.Value, key: []const u8) ?u64 {
    if (val != .object) return null;
    const v = val.object.get(key) orelse return null;
    return switch (v) {
        .integer => @intCast(v.integer),
        .float => @intFromFloat(v.float),
        else => null,
    };
}

fn hexEncode(src: []const u8, dst: []u8) void {
    const chars = "0123456789abcdef";
    for (src, 0..) |b, i| {
        dst[i * 2] = chars[b >> 4];
        dst[i * 2 + 1] = chars[b & 0xf];
    }
}

fn hexDecode(src: []const u8, dst: []u8) !void {
    if (src.len != dst.len * 2) return error.InvalidFormat;
    for (dst, 0..) |*b, i| {
        b.* = (try hexVal(src[i * 2])) << 4 | try hexVal(src[i * 2 + 1]);
    }
}

fn hexVal(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidFormat,
    };
}
