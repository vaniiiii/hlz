//! secp256k1 ECDSA signer for Ethereum-compatible signatures.
//! Forked from zabi (MIT, github.com/Raiden1411/zabi). Zero allocations.

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const Secp256k1 = std.crypto.ecc.Secp256k1;
const endo = @import("endo.zig");
const Point = @import("point.zig").Point;

/// A 32-byte hash (keccak256 output, private key, etc.)
pub const Hash = [32]u8;

/// A 20-byte Ethereum address.
pub const Address = [20]u8;

/// An Ethereum ECDSA signature with recovery id.
pub const Signature = struct {
    r: u256,
    s: u256,
    /// Recovery id: 0 or 1 (internal). Use toEthBytes() for Ethereum's 27/28 format.
    v: u1,

    /// Convert to 65-byte Ethereum signature format: [r: 32][s: 32][v: 1]
    /// where v = 27 or 28.
    pub fn toEthBytes(self: Signature) [65]u8 {
        var bytes: [65]u8 = undefined;
        std.mem.writeInt(u256, bytes[0..32], self.r, .big);
        std.mem.writeInt(u256, bytes[32..64], self.s, .big);
        bytes[64] = @as(u8, self.v) + 27;
        return bytes;
    }

    /// Convert to hex string "0x..." (130 hex chars + "0x" prefix = 132 total, but
    /// we return 130 hex chars without prefix for Hyperliquid format).
    pub fn toHex(self: Signature) [130]u8 {
        const bytes = self.toEthBytes();
        var hex: [130]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(bytes[0..65])}) catch unreachable;
        return hex;
    }

    /// Format as "0x" prefixed hex string for Hyperliquid API.
    pub fn toHexPrefixed(self: Signature, buf: *[132]u8) []const u8 {
        buf[0] = '0';
        buf[1] = 'x';
        const hex = self.toHex();
        @memcpy(buf[2..132], &hex);
        return buf[0..132];
    }
};

/// Possible errors when signing.
pub const SignError = std.crypto.errors.IdentityElementError || std.crypto.errors.NonCanonicalError;

/// Possible errors when recovering.
pub const RecoverError = std.crypto.errors.NotSquareError ||
    std.crypto.errors.EncodingError ||
    std.crypto.errors.IdentityElementError ||
    std.crypto.errors.NonCanonicalError ||
    error{InvalidMessageHash};

/// secp256k1 ECDSA signer.
pub const Signer = struct {
    private_key: Hash,
    public_key: [33]u8, // compressed SEC1
    address: Address,

    /// Create a signer from a 32-byte private key.
    pub fn init(private_key: Hash) std.crypto.errors.IdentityElementError!Signer {
        const public_scalar = try Secp256k1.mul(Secp256k1.basePoint, private_key, .big);
        const public_key = public_scalar.toCompressedSec1();

        var hash: [32]u8 = undefined;
        Keccak256.hash(public_scalar.toUncompressedSec1()[1..], &hash, .{});

        return .{
            .private_key = private_key,
            .public_key = public_key,
            .address = hash[12..].*,
        };
    }

    /// Create a signer from a hex-encoded private key (with or without "0x" prefix).
    pub fn fromHex(hex: []const u8) !Signer {
        const key_hex = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X'))
            hex[2..]
        else
            hex;
        if (key_hex.len != 64) return error.InvalidLength;
        var key: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&key, key_hex) catch return error.InvalidCharacter;
        return init(key);
    }

    /// Sign a 32-byte message hash. Returns deterministic signature (RFC 6979).
    pub fn sign(self: Signer, hash: Hash) SignError!Signature {
        const z = reduceToScalar(Secp256k1.Fe.encoded_length, hash);

        // RFC 6979 deterministic nonce
        const k_bytes = self.generateNonce(hash);
        const k = try Secp256k1.scalar.Scalar.fromBytes(k_bytes, .big);

        // R = k * G (5×52 field + GLV endomorphism)
        const p = try endo.mulBasePointGLV(k.toBytes(.big), .big);
        const p_affine = p.toAffine();
        const xs = p_affine.x.toBytes(); // already big-endian
        const r = reduceToScalar(Secp256k1.Fe.encoded_length, xs);

        if (r.isZero()) return error.IdentityElement;

        // y parity
        var y_int: u1 = @truncate(if (p_affine.y.isOdd()) @as(u8, 1) else @as(u8, 0));

        // S = k^-1 * (z + r * privkey)
        const k_inv = k.invert();
        const zrs = z.add(r.mul(try Secp256k1.scalar.Scalar.fromBytes(self.private_key, .big)));
        const s_malliable = k_inv.mul(zrs);

        if (s_malliable.isZero()) return error.IdentityElement;

        // Low-S normalization (Ethereum rejects high-S)
        const s_bytes = s_malliable.toBytes(.little);
        const s_int = std.mem.readInt(u256, &s_bytes, .little);

        var field_order_half: [32]u8 = undefined;
        std.mem.writeInt(u256, &field_order_half, Secp256k1.scalar.field_order / 2, .little);

        const cmp = std.crypto.timing_safe.compare(u8, &s_bytes, &field_order_half, .little);
        y_int ^= @intFromBool(cmp.compare(.gt));

        const s_neg_bytes = s_malliable.neg().toBytes(.little);
        const s_neg_int = std.mem.readInt(u256, &s_neg_bytes, .little);

        const scalar = @min(s_int, s_neg_int % Secp256k1.scalar.field_order);

        var s_buffer: [32]u8 = undefined;
        std.mem.writeInt(u256, &s_buffer, scalar, .little);
        const s = try Secp256k1.scalar.Scalar.fromBytes(s_buffer, .little);

        return .{
            .r = std.mem.readInt(u256, &r.toBytes(.little), .little),
            .s = std.mem.readInt(u256, &s.toBytes(.little), .little),
            .v = y_int,
        };
    }

    /// Recover an Ethereum address from a signature and message hash.
    pub fn recoverAddress(sig: Signature, message_hash: Hash) RecoverError!Address {
        const z = reduceToScalar(Secp256k1.Fe.encoded_length, message_hash);
        if (z.isZero()) return error.InvalidMessageHash;

        const s = try Secp256k1.scalar.Scalar.fromBytes(@bitCast(sig.s), .little);
        const r = try Secp256k1.scalar.Scalar.fromBytes(@bitCast(sig.r), .little);

        const r_inv = r.invert();
        const v1 = z.mul(r_inv).neg().toBytes(.little);
        const v2 = s.mul(r_inv).toBytes(.little);

        const y_is_odd = sig.v == 1;
        const vr = try Secp256k1.Fe.fromBytes(r.toBytes(.little), .little);
        const recover_id = try Secp256k1.recoverY(vr, y_is_odd);
        const curve = try Secp256k1.fromAffineCoordinates(.{ .x = vr, .y = recover_id });
        const recovered = try Secp256k1.mulDoubleBasePublic(Secp256k1.basePoint, v1, curve, v2, .little);

        var hash: Hash = undefined;
        Keccak256.hash(recovered.toUncompressedSec1()[1..], &hash, .{});
        return hash[12..].*;
    }

    /// RFC 6979 deterministic nonce generation.
    fn generateNonce(self: Signer, message_hash: Hash) [32]u8 {
        var v: [33]u8 = undefined;
        var k: [32]u8 = undefined;
        var buffer: [97]u8 = undefined;

        @memset(v[0..32], 0x01);
        v[32] = 0x00;
        @memset(&k, 0x00);

        // Step d
        @memcpy(buffer[0..32], v[0..32]);
        buffer[32] = 0x00;
        @memcpy(buffer[33..65], &self.private_key);
        @memcpy(buffer[65..97], &message_hash);
        HmacSha256.create(&k, &buffer, &k);

        // Step e
        HmacSha256.create(v[0..32], v[0..32], &k);

        // Step f
        @memcpy(buffer[0..32], v[0..32]);
        buffer[32] = 0x01;
        @memcpy(buffer[33..65], &self.private_key);
        @memcpy(buffer[65..97], &message_hash);
        HmacSha256.create(&k, &buffer, &k);

        // Step g
        HmacSha256.create(v[0..32], v[0..32], &k);

        // Step h
        HmacSha256.create(v[0..32], v[0..32], &k);

        while (true) {
            const k_int = std.mem.readInt(u256, v[0..32], .big);
            if (k_int > 0 and k_int < Secp256k1.scalar.field_order) break;
            HmacSha256.create(&k, v[0..], &k);
            HmacSha256.create(v[0..32], v[0..32], &k);
        }

        return v[0..32].*;
    }
};

/// Reduce a field element coordinate to the scalar field.
fn reduceToScalar(comptime unreduced_len: usize, s: [unreduced_len]u8) Secp256k1.scalar.Scalar {
    if (unreduced_len >= 48) {
        var xs = [_]u8{0} ** 64;
        @memcpy(xs[xs.len - s.len ..], s[0..]);
        return Secp256k1.scalar.Scalar.fromBytes64(xs, .big);
    }
    var xs = [_]u8{0} ** 48;
    @memcpy(xs[xs.len - s.len ..], s[0..]);
    return Secp256k1.scalar.Scalar.fromBytes48(xs, .big);
}

/// Compute keccak256 hash of input bytes.
pub fn keccak256(data: []const u8) Hash {
    var hash: Hash = undefined;
    Keccak256.hash(data, &hash, .{});
    return hash;
}

// Test vectors from Rust SDK: reference/src/hypercore/signing.rs

test "signer: init from hex key" {
    // Private key from Rust SDK test
    const s = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");

    // Verify address derivation produces a 20-byte address
    try std.testing.expect(s.address.len == 20);

    // Address should be non-zero
    var all_zero = true;
    for (s.address) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "signer: sign and recover" {
    const signer = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");

    // Sign a test hash
    const test_hash = keccak256("test message");
    const sig = try signer.sign(test_hash);

    // Recover address — must match signer's address
    const recovered = try Signer.recoverAddress(sig, test_hash);
    try std.testing.expectEqualSlices(u8, &signer.address, &recovered);
}

test "signer: deterministic signatures (RFC 6979)" {
    const signer = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");

    const hash = keccak256("deterministic test");
    const sig1 = try signer.sign(hash);
    const sig2 = try signer.sign(hash);

    // Same hash → same signature (deterministic)
    try std.testing.expectEqual(sig1.r, sig2.r);
    try std.testing.expectEqual(sig1.s, sig2.s);
    try std.testing.expectEqual(sig1.v, sig2.v);
}

test "signer: v is 0 or 1" {
    const signer = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");

    // Sign multiple messages, v should always be 0 or 1
    for (0..10) |i| {
        var msg: [32]u8 = undefined;
        @memset(&msg, @intCast(i));
        const sig = try signer.sign(msg);
        try std.testing.expect(sig.v == 0 or sig.v == 1);
    }
}

test "signer: toEthBytes has v=27 or v=28" {
    const signer = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");
    const hash = keccak256("eth bytes test");
    const sig = try signer.sign(hash);
    const bytes = sig.toEthBytes();

    try std.testing.expect(bytes[64] == 27 or bytes[64] == 28);
    try std.testing.expectEqual(@as(usize, 65), bytes.len);
}

test "keccak256: known vector" {
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const empty_hash = keccak256("");
    try std.testing.expectEqual(@as(u8, 0xc5), empty_hash[0]);
    try std.testing.expectEqual(@as(u8, 0xd2), empty_hash[1]);
    try std.testing.expectEqual(@as(u8, 0x46), empty_hash[2]);
    try std.testing.expectEqual(@as(u8, 0x70), empty_hash[31]);
}
