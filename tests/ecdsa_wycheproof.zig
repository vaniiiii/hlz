const std = @import("std");

const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Secp256k1 = std.crypto.ecc.Secp256k1;

const ParseOpts = std.json.ParseOptions{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

const TestResult = enum {
    valid,
    invalid,
    acceptable,
};

const TestCase = struct {
    msg: []const u8,
    sig: []const u8,
    result: TestResult,
};

const PublicKey = struct {
    uncompressed: []const u8,
};

const TestGroup = struct {
    publicKey: PublicKey,
    sha: []const u8,
    tests: []TestCase,
};

const VectorFile = struct {
    testGroups: []TestGroup,
};

fn hexToAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn isLowS(sig: Ecdsa.Signature) bool {
    const s = std.mem.readInt(u256, &sig.s, .big);
    return s <= Secp256k1.scalar.field_order / 2;
}

fn verifyCase(msg: []const u8, sig_der: []const u8, pubkey_sec1: []const u8, enforce_low_s: bool) bool {
    const pk = Ecdsa.PublicKey.fromSec1(pubkey_sec1) catch return false;
    const sig = Ecdsa.Signature.fromDer(sig_der) catch return false;
    if (enforce_low_s and !isLowS(sig)) return false;
    Ecdsa.Signature.verify(sig, msg, pk) catch return false;
    return true;
}

fn runVectors(data: []const u8, enforce_low_s: bool) !void {
    var parsed = try std.json.parseFromSlice(VectorFile, std.testing.allocator, data, ParseOpts);
    defer parsed.deinit();

    for (parsed.value.testGroups) |group| {
        if (!std.mem.eql(u8, group.sha, "SHA-256")) continue;

        const pubkey = try hexToAlloc(std.testing.allocator, group.publicKey.uncompressed);
        defer std.testing.allocator.free(pubkey);

        for (group.tests) |tc| {
            const msg = try hexToAlloc(std.testing.allocator, tc.msg);
            defer std.testing.allocator.free(msg);

            const sig = try hexToAlloc(std.testing.allocator, tc.sig);
            defer std.testing.allocator.free(sig);

            const ok = verifyCase(msg, sig, pubkey, enforce_low_s);
            switch (tc.result) {
                .valid => try std.testing.expect(ok),
                .invalid => try std.testing.expect(!ok),
                .acceptable => {},
            }
        }
    }
}

test "ecdsa wycheproof secp256k1 sha256" {
    try runVectors(@embedFile("vectors/ecdsa_secp256k1_sha256_test.json"), false);
}

test "ecdsa wycheproof secp256k1 sha256 low-s" {
    try runVectors(@embedFile("vectors/ecdsa_secp256k1_sha256_bitcoin_test.json"), true);
}
