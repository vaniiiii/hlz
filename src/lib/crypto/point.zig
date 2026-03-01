//! secp256k1 point operations using 5×52-bit field arithmetic.
//!
//! Homogeneous projective coordinates: (X, Y, Z) represents affine (X/Z, Y/Z).
//! Used by endo.zig when `-Dfast-crypto=true`.
//!
//! Formulas from Renes, Costello, Batina. "Complete addition formulas for prime
//! order elliptic curves" (https://eprint.iacr.org/2015/1060.pdf), Algorithms 7, 8, 9.

const std = @import("std");
const Fe = @import("field.zig").Fe;

pub const Point = struct {
    x: Fe,
    y: Fe,
    z: Fe,

    pub const identity = Point{ .x = Fe.zero, .y = Fe.one, .z = Fe.zero };

    pub const G = blk: {
        break :blk Point{
            .x = Fe.fromBytes(.{
                0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
                0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
            }),
            .y = Fe.fromBytes(.{
                0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65, 0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
                0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19, 0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8,
            }),
            .z = Fe.one,
        };
    };

    pub fn neg(p: Point) Point {
        return .{ .x = p.x, .y = p.y.normalizeWeak().neg(1).normalizeWeak(), .z = p.z };
    }

    /// Algorithm 9: point doubling for b=7 (3b = 21 = 16 + 4 + 1).
    pub fn dbl(p: Point) Point {
        var t0 = p.y.sq();
        var Z3 = t0.dbl().dbl().dbl();
        var t1 = p.y.mul(p.z);
        var t2 = p.z.sq();
        const t2_4 = t2.dbl().dbl();
        t2 = t2_4.dbl().dbl().add(t2_4).add(t2);
        var X3 = t2.mul(Z3);
        var Y3 = t0.add(t2);
        Z3 = t1.mul(Z3);
        t1 = t2.dbl();
        t2 = t1.add(t2);
        t0 = t0.sub(t2);
        Y3 = t0.mul(Y3);
        Y3 = X3.add(Y3);
        t1 = p.x.mul(p.y);
        X3 = t0.mul(t1);
        X3 = X3.dbl();
        return .{ .x = X3, .y = Y3, .z = Z3 };
    }

    /// Algorithm 8: mixed addition with affine point (z=1), ~11 field muls.
    pub fn addAffine(p: Point, qx: Fe, qy: Fe) Point {
        var t0 = p.x.mul(qx);
        var t1 = p.y.mul(qy);
        var t3 = qx.add(qy);
        var t4 = p.x.add(p.y);
        t3 = t3.mul(t4);
        t4 = t0.add(t1);
        t3 = t3.sub(t4);
        t4 = qy.mul(p.z);
        t4 = t4.add(p.y);
        var Y3 = qx.mul(p.z);
        Y3 = Y3.add(p.x);
        var X3 = t0.dbl();
        t0 = X3.add(t0);
        const t2_4 = p.z.dbl().dbl();
        var t2 = t2_4.dbl().dbl().add(t2_4).add(p.z);
        var Z3 = t1.add(t2);
        t1 = t1.sub(t2);
        const Y3_4 = Y3.dbl().dbl();
        Y3 = Y3_4.dbl().dbl().add(Y3_4).add(Y3);
        X3 = t4.mul(Y3);
        t2 = t3.mul(t1);
        X3 = t2.sub(X3);
        Y3 = Y3.mul(t0);
        t1 = t1.mul(Z3);
        Y3 = t1.add(Y3);
        t0 = t0.mul(t3);
        Z3 = Z3.mul(t4);
        Z3 = Z3.add(t0);

        var ret = Point{ .x = X3, .y = Y3, .z = Z3 };
        ret.cMov(p, @intFromBool(qx.normalizeWeak().isZero()));
        return ret;
    }

    /// Algorithm 7: full point addition, ~15 field muls.
    pub fn add(p: Point, q: Point) Point {
        var t0 = p.x.mul(q.x);
        var t1 = p.y.mul(q.y);
        var t2 = p.z.mul(q.z);
        var t3 = p.x.add(p.y);
        var t4 = q.x.add(q.y);
        t3 = t3.mul(t4);
        t4 = t0.add(t1);
        t3 = t3.sub(t4);
        t4 = p.y.add(p.z);
        var X3 = q.y.add(q.z);
        t4 = t4.mul(X3);
        X3 = t1.add(t2);
        t4 = t4.sub(X3);
        X3 = p.x.add(p.z);
        var Y3 = q.x.add(q.z);
        X3 = X3.mul(Y3);
        Y3 = t0.add(t2);
        Y3 = X3.sub(Y3);
        X3 = t0.dbl();
        t0 = X3.add(t0);
        const t2_4 = t2.dbl().dbl();
        t2 = t2_4.dbl().dbl().add(t2_4).add(t2);
        var Z3 = t1.add(t2);
        t1 = t1.sub(t2);
        const Y3_4 = Y3.dbl().dbl();
        Y3 = Y3_4.dbl().dbl().add(Y3_4).add(Y3);
        X3 = t4.mul(Y3);
        t2 = t3.mul(t1);
        X3 = t2.sub(X3);
        Y3 = Y3.mul(t0);
        t1 = t1.mul(Z3);
        Y3 = t1.add(Y3);
        t0 = t0.mul(t3);
        Z3 = Z3.mul(t4);
        Z3 = Z3.add(t0);
        return .{ .x = X3, .y = Y3, .z = Z3 };
    }

    pub fn toAffine(p: Point) struct { x: Fe, y: Fe } {
        const zinv = p.z.invert();
        return .{
            .x = p.x.mul(zinv).normalize(),
            .y = p.y.mul(zinv).normalize(),
        };
    }

    pub fn isIdentity(p: Point) bool {
        return p.z.normalize().isZero();
    }

    pub fn cMov(p: *Point, other: Point, flag: u1) void {
        p.x.cMov(other.x, flag);
        p.y.cMov(other.y, flag);
        p.z.cMov(other.z, flag);
    }
};

pub const AffinePoint = struct {
    x: Fe,
    y: Fe,

    pub const identity = AffinePoint{ .x = Fe.zero, .y = Fe.zero };

    pub fn cMov(p: *AffinePoint, other: AffinePoint, flag: u1) void {
        p.x.cMov(other.x, flag);
        p.y.cMov(other.y, flag);
    }
};


const B7 = Fe{ .d = .{ 7, 0, 0, 0, 0 } };

test "G is on curve" {
    const y2 = Point.G.y.sq().normalize();
    const x3_7 = Point.G.x.sq().mul(Point.G.x).normalize().add(B7).normalize();
    try std.testing.expect(y2.equivalent(x3_7));
}

test "2G on curve" {
    const aff = Point.G.dbl().toAffine();
    const y2 = aff.y.sq().normalize();
    const x3_7 = aff.x.sq().mul(aff.x).add(B7).normalize();
    try std.testing.expect(y2.equivalent(x3_7));
}

test "G + G = 2G" {
    const a1 = Point.G.dbl().toAffine();
    const a2 = Point.G.add(Point.G).toAffine();
    try std.testing.expect(a1.x.equivalent(a2.x));
}

test "addAffine matches add" {
    const g2 = Point.G.dbl();
    const a1 = g2.add(Point.G).toAffine();
    const a2 = g2.addAffine(Point.G.x, Point.G.y).toAffine();
    try std.testing.expect(a1.x.equivalent(a2.x));
}

test "dbl matches stdlib" {
    const StdSecp = std.crypto.ecc.Secp256k1;
    const our = Point.G.dbl().toAffine().x.toBytes();
    const expected = StdSecp.basePoint.dbl().affineCoordinates().x.toBytes(.big);
    try std.testing.expectEqualSlices(u8, &expected, &our);
}

test "G toAffine roundtrip" {
    const expected = [_]u8{
        0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
        0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
    };
    try std.testing.expectEqualSlices(u8, &expected, &Point.G.toAffine().x.toBytes());
}

test "toAffine with z=2" {
    const z = Fe{ .d = .{ 2, 0, 0, 0, 0 } };
    const p = Point{ .x = Point.G.x.mul(z), .y = Point.G.y.mul(z), .z = z };
    const expected = Point.G.toAffine().x.toBytes();
    try std.testing.expectEqualSlices(u8, &expected, &p.toAffine().x.toBytes());
}
