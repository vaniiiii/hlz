//! 5×52-bit field arithmetic for secp256k1.
//!
//! Field elements mod p = 2^256 - 2^32 - 977. Five 64-bit limbs, each holding
//! at most 52 significant bits (last limb: 48 bits), with headroom for lazy carries.
//!
//! This is the same representation used by libsecp256k1 (C) and RustCrypto/k256 (Rust).
//! The 52-bit limbs leave 12 bits of headroom per limb, allowing multiple additions
//! before a carry pass is needed. Used by endo.zig when `-Dfast-crypto=true`.
//!
//! Reference: libsecp256k1 src/field_5x52_impl.h

const std = @import("std");
const mem = std.mem;

pub const Fe = struct {
    d: [5]u64,

    pub const zero = Fe{ .d = .{ 0, 0, 0, 0, 0 } };
    pub const one = Fe{ .d = .{ 1, 0, 0, 0, 0 } };

    const MASK: u64 = 0xFFFFFFFFFFFFF; // 52 bits
    const R: u128 = 0x1000003D10; // (2^256 mod p) << 4

    pub fn fromBytes(bytes: [32]u8) Fe {
        const w3 = mem.readInt(u64, bytes[0..8], .big);
        const w2 = mem.readInt(u64, bytes[8..16], .big);
        const w1 = mem.readInt(u64, bytes[16..24], .big);
        const w0 = mem.readInt(u64, bytes[24..32], .big);
        return Fe{ .d = .{
            w0 & MASK,
            ((w0 >> 52) | (w1 << 12)) & MASK,
            ((w1 >> 40) | (w2 << 24)) & MASK,
            ((w2 >> 28) | (w3 << 36)) & MASK,
            w3 >> 16,
        } };
    }

    pub fn toBytes(self: Fe) [32]u8 {
        const d = self.d;
        var out: [32]u8 = undefined;
        mem.writeInt(u64, out[0..8], (d[3] >> 36) | (d[4] << 16), .big);
        mem.writeInt(u64, out[8..16], (d[2] >> 24) | (d[3] << 28), .big);
        mem.writeInt(u64, out[16..24], (d[1] >> 12) | (d[2] << 40), .big);
        mem.writeInt(u64, out[24..32], d[0] | (d[1] << 52), .big);
        return out;
    }

    /// Fully normalize: propagate carries and reduce mod p.
    pub fn normalize(self: Fe) Fe {
        const r = self.normalizeWeak();
        const m = r.d[1] & r.d[2] & r.d[3];
        const overflow: u64 = @intFromBool(
            (r.d[4] >> 48 != 0) or
                ((r.d[4] == 0x0FFFFFFFFFFFF) and (m == MASK) and (r.d[0] >= 0xFFFFEFFFFFC2F)),
        );
        var t0 = r.d[0] +% (overflow *% 0x1000003D1);
        const t1 = r.d[1] +% (t0 >> 52);
        t0 &= MASK;
        const t2 = r.d[2] +% (t1 >> 52);
        const t3 = r.d[3] +% (t2 >> 52);
        var t4 = r.d[4] +% (t3 >> 52);
        t4 &= 0x0FFFFFFFFFFFF;
        return Fe{ .d = .{ t0, t1 & MASK, t2 & MASK, t3 & MASK, t4 } };
    }

    /// Propagate carries without full reduction.
    pub fn normalizeWeak(self: Fe) Fe {
        var t = self.d;
        const x = t[4] >> 48;
        t[4] &= 0x0FFFFFFFFFFFF;
        t[0] = t[0] +% (x *% 0x1000003D1);
        t[1] = t[1] +% (t[0] >> 52);
        t[0] &= MASK;
        t[2] = t[2] +% (t[1] >> 52);
        t[1] &= MASK;
        t[3] = t[3] +% (t[2] >> 52);
        t[2] &= MASK;
        t[4] = t[4] +% (t[3] >> 52);
        t[3] &= MASK;
        return Fe{ .d = t };
    }

    pub inline fn add(a: Fe, b: Fe) Fe {
        return Fe{ .d = .{
            a.d[0] +% b.d[0], a.d[1] +% b.d[1], a.d[2] +% b.d[2],
            a.d[3] +% b.d[3], a.d[4] +% b.d[4],
        } };
    }

    pub fn sub(a: Fe, b: Fe) Fe {
        return a.add(b.normalizeWeak().neg(1)).normalizeWeak();
    }

    pub fn neg(self: Fe, magnitude: u32) Fe {
        const m: u64 = @as(u64, magnitude + 1);
        return Fe{ .d = .{
            0xFFFFEFFFFFC2F *% 2 *% m -% self.d[0],
            MASK *% 2 *% m -% self.d[1],
            MASK *% 2 *% m -% self.d[2],
            MASK *% 2 *% m -% self.d[3],
            0x0FFFFFFFFFFFF *% 2 *% m -% self.d[4],
        } };
    }

    /// Schoolbook multiplication with integrated Solinas reduction.
    pub fn mul(a: Fe, b: Fe) Fe {
        const a0: u128 = a.d[0];
        const a1: u128 = a.d[1];
        const a2: u128 = a.d[2];
        const a3: u128 = a.d[3];
        const a4: u128 = a.d[4];
        const b0: u128 = b.d[0];
        const b1: u128 = b.d[1];
        const b2: u128 = b.d[2];
        const b3: u128 = b.d[3];
        const b4: u128 = b.d[4];
        const m: u128 = MASK;
        const r = R;

        var d: u128 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0;
        var c: u128 = a4 * b4;
        d += (c & m) * r;
        c >>= 52;
        const t3: u64 = @truncate(d & m);
        d >>= 52;

        d += a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0;
        d += @as(u128, @as(u64, @truncate(c))) * r;
        var t4: u64 = @truncate(d & m);
        d >>= 52;
        const tx: u64 = t4 >> 48;
        t4 &= @as(u64, @truncate(m >> 4));

        c = a0 * b0;
        d += a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1;
        var limb0: u64 = @truncate(d & m);
        d >>= 52;
        limb0 = (limb0 << 4) | tx;
        c += @as(u128, limb0) * @as(u128, @as(u64, @truncate(r >> 4)));
        const r0: u64 = @truncate(c & m);
        c >>= 52;

        c += a0 * b1 + a1 * b0;
        d += a2 * b4 + a3 * b3 + a4 * b2;
        c += (d & m) * r;
        d >>= 52;
        const r1: u64 = @truncate(c & m);
        c >>= 52;

        c += a0 * b2 + a1 * b1 + a2 * b0;
        d += a3 * b4 + a4 * b3;
        c += (d & m) * r;
        d >>= 52;
        const r2: u64 = @truncate(c & m);
        c >>= 52;

        c += @as(u128, @as(u64, @truncate(d))) * r + @as(u128, t3);
        const r3: u64 = @truncate(c & m);
        c >>= 52;
        const r4: u64 = @as(u64, @truncate(c)) + t4;

        return Fe{ .d = .{ r0, r1, r2, r3, r4 } };
    }

    pub inline fn sq(self: Fe) Fe {
        return mul(self, self);
    }

    pub inline fn dbl(self: Fe) Fe {
        return Fe{ .d = .{
            self.d[0] *% 2, self.d[1] *% 2, self.d[2] *% 2,
            self.d[3] *% 2, self.d[4] *% 2,
        } };
    }

    pub inline fn mulInt(self: Fe, n: u64) Fe {
        return Fe{ .d = .{
            self.d[0] *% n, self.d[1] *% n, self.d[2] *% n,
            self.d[3] *% n, self.d[4] *% n,
        } };
    }

    pub fn isZero(self: Fe) bool {
        return (self.d[0] | self.d[1] | self.d[2] | self.d[3] | self.d[4]) == 0;
    }

    pub fn isOdd(self: Fe) bool {
        return (self.d[0] & 1) != 0;
    }

    pub fn equivalent(a: Fe, b: Fe) bool {
        const an = a.normalize();
        const bn = b.normalize();
        return (an.d[0] == bn.d[0]) and (an.d[1] == bn.d[1]) and
            (an.d[2] == bn.d[2]) and (an.d[3] == bn.d[3]) and (an.d[4] == bn.d[4]);
    }

    pub fn cMov(self: *Fe, other: Fe, flag: u1) void {
        const mask: u64 = @as(u64, 0) -% @as(u64, flag);
        inline for (0..5) |i| {
            self.d[i] = (self.d[i] & ~mask) | (other.d[i] & mask);
        }
    }

    /// Invert via Fermat's little theorem with optimized addition chain from libsecp256k1.
    pub fn invert(self: Fe) Fe {
        const x = self;
        const x2 = x.sq().mul(x);
        const x3 = x2.sq().mul(x);
        const x6 = sqn(x3, 3).mul(x3);
        const x9 = sqn(x6, 3).mul(x3);
        const x11 = sqn(x9, 2).mul(x2);
        const x22 = sqn(x11, 11).mul(x11);
        const x44 = sqn(x22, 22).mul(x22);
        const x88 = sqn(x44, 44).mul(x44);
        const x176 = sqn(x88, 88).mul(x88);
        const x220 = sqn(x176, 44).mul(x44);
        const x223 = sqn(x220, 3).mul(x3);
        const t1 = sqn(x223, 23);
        const t2 = t1.mul(x22);
        const t3 = sqn(t2, 5);
        const t4 = t3.mul(x);
        const t5 = sqn(t4, 3);
        const t6 = t5.mul(x2);
        const t7 = sqn(t6, 2);
        return t7.mul(x);
    }

    /// Square root for p ≡ 3 (mod 4): a^((p+1)/4).
    pub fn sqrt(self: Fe) ?Fe {
        const x = self;
        const x2 = x.sq().mul(x);
        const x3 = x2.sq().mul(x);
        const x6 = sqn(x3, 3).mul(x3);
        const x9 = sqn(x6, 3).mul(x3);
        const x11 = sqn(x9, 2).mul(x2);
        const x22 = sqn(x11, 11).mul(x11);
        const x44 = sqn(x22, 22).mul(x22);
        const x88 = sqn(x44, 44).mul(x44);
        const x176 = sqn(x88, 88).mul(x88);
        const x220 = sqn(x176, 44).mul(x44);
        const x223 = sqn(x220, 3).mul(x3);
        const t1 = sqn(x223, 23);
        const t2 = t1.mul(x22);
        const t3 = sqn(t2, 6);
        const t4 = t3.mul(x2);
        const result = sqn(t4, 2);
        const check = result.sq().normalize();
        const orig = self.normalize();
        if (check.d[0] != orig.d[0] or check.d[1] != orig.d[1] or
            check.d[2] != orig.d[2] or check.d[3] != orig.d[3] or check.d[4] != orig.d[4])
            return null;
        return result;
    }

    fn sqn(a: Fe, comptime n: usize) Fe {
        var r = a;
        inline for (0..n) |_| r = r.sq();
        return r;
    }
};


test "roundtrip bytes" {
    const bytes = [_]u8{
        0x7f, 0xf0, 0xff, 0xff, 0xff, 0xf1, 0xff, 0xff, 0xff, 0xf2, 0xff, 0xff, 0xff, 0xf3, 0xff, 0xf3,
        0xff, 0xff, 0xff, 0xf4, 0xff, 0xff, 0xff, 0xf5, 0xff, 0xff, 0xff, 0xf6, 0x7f, 0xff, 0xfe, 0x18,
    };
    const fe = Fe.fromBytes(bytes);
    try std.testing.expectEqualSlices(u8, &bytes, &fe.normalize().toBytes());
}

test "mul" {
    const a = Fe{ .d = .{ 3, 0, 0, 0, 0 } };
    const b = Fe{ .d = .{ 7, 0, 0, 0, 0 } };
    const c = a.mul(b).normalize();
    try std.testing.expectEqual(@as(u64, 21), c.d[0]);
}

test "mul large" {
    const a = Fe.fromBytes(.{0} ** 31 ++ .{0xFF});
    const b = a.mul(a).normalize();
    try std.testing.expectEqual(@as(u64, 65025), b.d[0]);
}

test "invert" {
    const a = Fe{ .d = .{ 42, 0, 0, 0, 0 } };
    const product = a.mul(a.invert()).normalize();
    try std.testing.expectEqual(@as(u64, 1), product.d[0]);
    try std.testing.expectEqual(@as(u64, 0), product.d[1]);
}

test "invert large" {
    const a = Fe.fromBytes(.{
        0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
        0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98,
    });
    const product = a.mul(a.invert()).normalize();
    try std.testing.expect(product.equivalent(Fe.one));
}

test "neg" {
    const a = Fe{ .d = .{ 42, 7, 3, 1, 0 } };
    try std.testing.expect(a.add(a.neg(1)).normalize().isZero());
}

test "add" {
    const c = (Fe{ .d = .{ 1, 0, 0, 0, 0 } }).add(Fe{ .d = .{ 2, 0, 0, 0, 0 } }).normalize();
    try std.testing.expectEqual(@as(u64, 3), c.d[0]);
}

test "cMov" {
    var a = Fe{ .d = .{ 1, 0, 0, 0, 0 } };
    const b = Fe{ .d = .{ 99, 0, 0, 0, 0 } };
    a.cMov(b, 0);
    try std.testing.expectEqual(@as(u64, 1), a.d[0]);
    a.cMov(b, 1);
    try std.testing.expectEqual(@as(u64, 99), a.d[0]);
}
