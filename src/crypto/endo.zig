//! GLV endomorphism-accelerated base point multiplication for secp256k1.
//! Splits scalar k into two ~128-bit halves via k = k1 + k2·λ (mod n),
//! then computes k·G = k1·G + k2·φ(G) with 4-bit windowed double-base mul.

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const Fe = @import("field.zig").Fe;
const point_mod = @import("point.zig");
const Point = point_mod.Point;
const AffinePoint = point_mod.AffinePoint;
const StdSecp = crypto.ecc.Secp256k1;
const scalar = StdSecp.scalar;
const Endo = StdSecp.Endormorphism;
const IdentityElementError = crypto.errors.IdentityElementError;

fn affineSelect(comptime n: usize, pc: *const [n]AffinePoint, idx: u8) AffinePoint {
    var t = AffinePoint.identity;
    comptime var i: u8 = 1;
    inline while (i < n) : (i += 1) {
        t.cMov(pc[i], @as(u1, @truncate((@as(usize, idx ^ i) -% 1) >> 8)));
    }
    return t;
}

fn precomputeAffine16(p: Point) [16]AffinePoint {
    var proj: [16]Point = undefined;
    proj[0] = Point.identity;
    proj[1] = p;
    for (2..16) |i| {
        proj[i] = if (i % 2 == 0) proj[i / 2].dbl() else proj[i - 1].add(p);
    }
    var affine: [16]AffinePoint = undefined;
    for (0..16) |i| {
        const a = proj[i].toAffine();
        affine[i] = .{ .x = a.x, .y = a.y };
    }
    affine[0] = AffinePoint.identity;
    return affine;
}

const base_pc = blk: {
    @setEvalBranchQuota(200_000_000);
    break :blk precomputeAffine16(Point.G);
};

const lambda_g = blk: {
    const beta: u256 = 55594575648329892869085402983802832744385952214688224221778511981742606582254;
    var buf: [32]u8 = undefined;
    mem.writeInt(u256, &buf, beta, .big);
    break :blk Point{ .x = Point.G.x.mul(Fe.fromBytes(buf)), .y = Point.G.y, .z = Fe.one };
};

const lambda_g_pc = blk: {
    @setEvalBranchQuota(200_000_000);
    break :blk precomputeAffine16(lambda_g);
};

/// Constant-time base point multiplication using GLV endomorphism + 5×52 field.
pub fn mulBasePointGLV(s_: [32]u8, endian: std.builtin.Endian) IdentityElementError!Point {
    const s = if (endian == .little) s_ else StdSecp.Fe.orderSwap(s_);
    const zero_bytes = comptime scalar.Scalar.zero.toBytes(.little);

    var split = Endo.splitScalar(s, .little) catch return error.IdentityElement;
    const r1_sign: u1 = @intFromBool(split.r1[16] != 0);
    const r2_sign: u1 = @intFromBool(split.r2[16] != 0);
    const r1_neg = scalar.neg(split.r1, .little) catch zero_bytes;
    const r2_neg = scalar.neg(split.r2, .little) catch zero_bytes;
    cmovBytes(&split.r1, r1_neg, r1_sign);
    cmovBytes(&split.r2, r2_neg, r2_sign);

    var q = Point.identity;
    var pos: usize = 124;

    while (true) {
        const byte_idx = pos >> 3;
        const bit_shift: u3 = @truncate(pos);
        const slot1: u8 = @as(u4, @truncate(split.r1[byte_idx] >> bit_shift));
        const slot2: u8 = @as(u4, @truncate(split.r2[byte_idx] >> bit_shift));

        var p1 = affineSelect(16, &base_pc, slot1);
        var p2 = affineSelect(16, &lambda_g_pc, slot2);
        p1.y.cMov(p1.y.neg(1).normalizeWeak(), r1_sign);
        p2.y.cMov(p2.y.neg(1).normalizeWeak(), r2_sign);

        q = q.addAffine(p1.x, p1.y);
        q = q.addAffine(p2.x, p2.y);

        if (pos == 0) break;
        pos -= 4;
        q = q.dbl().dbl().dbl().dbl();
    }

    if (q.isIdentity()) return error.IdentityElement;
    return q;
}

inline fn cmovBytes(dst: *[32]u8, src: [32]u8, flag: u1) void {
    const mask: u8 = @as(u8, 0) -% @as(u8, flag);
    for (dst, src) |*d, s_byte| d.* = (d.* & ~mask) | (s_byte & mask);
}


test "matches stdlib for known key" {
    var s: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&s, "e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e") catch unreachable;
    const glv = (try mulBasePointGLV(s, .big)).toAffine().x.toBytes();
    const expected = (try StdSecp.basePoint.mul(s, .big)).affineCoordinates().x.toBytes(.big);
    try std.testing.expectEqualSlices(u8, &expected, &glv);
}

test "matches stdlib for small scalar" {
    var s = [_]u8{0} ** 32;
    s[31] = 7;
    const glv = (try mulBasePointGLV(s, .big)).toAffine().x.toBytes();
    const expected = (try StdSecp.basePoint.mul(s, .big)).affineCoordinates().x.toBytes(.big);
    try std.testing.expectEqualSlices(u8, &expected, &glv);
}

test "matches stdlib for scalar near order" {
    const s = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x40,
    };
    const glv = (try mulBasePointGLV(s, .big)).toAffine().x.toBytes();
    const expected = (try StdSecp.basePoint.mul(s, .big)).affineCoordinates().x.toBytes(.big);
    try std.testing.expectEqualSlices(u8, &expected, &glv);
}

test "matches stdlib for 50 random scalars" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..50) |_| {
        var s: [32]u8 = undefined;
        random.bytes(&s);
        s[0] &= 0x7f;
        const glv = (mulBasePointGLV(s, .big) catch continue).toAffine();
        const expected = (StdSecp.basePoint.mul(s, .big) catch continue).affineCoordinates();
        try std.testing.expectEqualSlices(u8, &expected.x.toBytes(.big), &glv.x.toBytes());
        try std.testing.expectEqualSlices(u8, &expected.y.toBytes(.big), &glv.y.toBytes());
    }
}
