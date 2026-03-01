//! GLV endomorphism mathematical invariant tests.
//!
//! Verifies the mathematical properties that the GLV scalar decomposition and
//! endomorphism-accelerated multiplication must satisfy for correctness,
//! independent of any external oracle.
//!
//! References:
//!   - Gallant, Lambert, Vanstone. "Faster Point Multiplication on Elliptic Curves
//!     with Efficient Endomorphisms" (CRYPTO 2001)
//!   - libsecp256k1 endomorphism constants and decomposition bounds

const std = @import("std");
const hlz = @import("hlz");
const Fe = hlz.crypto.field.Fe;
const Point = hlz.crypto.point.Point;

const StdSecp = std.crypto.ecc.Secp256k1;
const Endo = StdSecp.Endormorphism;
const scalar = StdSecp.scalar;
const endo = hlz.crypto.endo;

// ── Endomorphism constants ───────────────────────────────────────

/// β: cube root of unity in Fp (field). ψ(x,y) = (β·x, y)
const BETA: u256 = 0x7ae96a2b657c07106e64479eac3434e99cf0497512f58995c1396c28719501ee;

/// λ: cube root of unity in Fn (scalar field). λ·P = ψ(P) for all P on curve.
const LAMBDA: u256 = 0x5363ad4cc05c30e0a5261c028812645a122e22ea20816678df02967c1b23bd72;

/// Curve order n
const N: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

// ── Test 1: Endomorphism ψ(G) = λ·G ─────────────────────────────

test "GLV: endomorphism ψ(G) equals λ·G" {
    // Compute ψ(G) = (β·Gx, Gy)
    var beta_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &beta_bytes, BETA, .big);
    const beta_fe = Fe.fromBytes(beta_bytes);
    const psi_gx = Point.G.x.mul(beta_fe).normalize();
    const psi_gy = Point.G.y.normalize();

    // Compute λ·G using stdlib (trusted reference)
    var lambda_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &lambda_bytes, LAMBDA, .big);
    const lambda_g = try StdSecp.basePoint.mul(lambda_bytes, .big);
    const lambda_g_aff = lambda_g.affineCoordinates();

    // Compare
    try std.testing.expectEqualSlices(u8, &lambda_g_aff.x.toBytes(.big), &psi_gx.toBytes());
    try std.testing.expectEqualSlices(u8, &lambda_g_aff.y.toBytes(.big), &psi_gy.toBytes());
}

test "GLV: β³ ≡ 1 (mod p)" {
    // β is a cube root of unity in Fp
    var beta_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &beta_bytes, BETA, .big);
    const beta_fe = Fe.fromBytes(beta_bytes);
    const beta_cubed = beta_fe.mul(beta_fe).mul(beta_fe).normalize();
    try std.testing.expect(beta_cubed.equivalent(Fe.one));
}

test "GLV: λ³ ≡ 1 (mod n)" {
    // λ is a cube root of unity in the scalar field
    var lambda_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &lambda_bytes, LAMBDA, .big);
    const lambda_scalar = try scalar.Scalar.fromBytes(lambda_bytes, .big);
    const lambda_sq = lambda_scalar.mul(lambda_scalar);
    const lambda_cubed = lambda_sq.mul(lambda_scalar);

    // Should equal 1
    const one = try scalar.Scalar.fromBytes(([_]u8{0} ** 31) ++ [_]u8{1}, .big);
    try std.testing.expectEqualSlices(u8, &one.toBytes(.big), &lambda_cubed.toBytes(.big));
}

// ── Test 2: Scalar decomposition k = k1 + k2·λ (mod n) ─────────

test "GLV: scalar decomposition k = k1 + k2·λ (mod n) for 10000 random scalars" {
    // Directly verify the GLV decomposition: splitScalar(k) → (r1, r2)
    // such that k ≡ r1 + r2·λ (mod n).
    // Also check that |r1|, |r2| < 2^128 (the half-width bound).
    var prng = std.Random.DefaultPrng.init(0x61F_7E57);
    const random = prng.random();

    var lambda_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &lambda_bytes, LAMBDA, .big);
    const lambda_scalar = try scalar.Scalar.fromBytes(lambda_bytes, .big);

    var tested: usize = 0;
    for (0..11000) |_| {
        var k_bytes_be: [32]u8 = undefined;
        random.bytes(&k_bytes_be);
        k_bytes_be[0] &= 0x7f;

        const k_scalar = scalar.Scalar.fromBytes(k_bytes_be, .big) catch continue;
        if (k_scalar.isZero()) continue;

        // splitScalar expects little-endian input, returns little-endian r1, r2
        const k_bytes_le = k_scalar.toBytes(.little);
        const split = Endo.splitScalar(k_bytes_le, .little) catch continue;

        // r1 and r2 are full 32-byte little-endian scalars mod n
        const r1 = scalar.Scalar.fromBytes(split.r1, .little) catch continue;
        const r2 = scalar.Scalar.fromBytes(split.r2, .little) catch continue;

        // Verify: k ≡ r1 + r2·λ (mod n)
        const reconstructed = r1.add(r2.mul(lambda_scalar));
        try std.testing.expectEqualSlices(u8, &k_scalar.toBytes(.big), &reconstructed.toBytes(.big));

        // Verify half-width bound: |r1| and |r2| should fit in ~128 bits.
        // The split returns values mod n. If the mathematical value is negative,
        // it's stored as n - |val|, which is near n (large). We take the minimum
        // of val and n - val to get the absolute value.
        const r1_int = std.mem.readInt(u256, &r1.toBytes(.big), .big);
        const r2_int = std.mem.readInt(u256, &r2.toBytes(.big), .big);
        const r1_abs = @min(r1_int, N - r1_int);
        const r2_abs = @min(r2_int, N - r2_int);

        // Both halves must fit in 128 bits (the whole point of GLV)
        try std.testing.expect(r1_abs < (@as(u256, 1) << 128));
        try std.testing.expect(r2_abs < (@as(u256, 1) << 128));

        tested += 1;
        if (tested >= 10000) break;
    }
    try std.testing.expect(tested >= 10000);
}

// ── Test 3: GLV matches stdlib for generator point ──────────────

test "GLV: mulBasePointGLV matches stdlib for 1000 random scalars" {
    var prng = std.Random.DefaultPrng.init(0xBA5E_0001);
    const random = prng.random();

    var tested: usize = 0;
    for (0..1100) |_| {
        var s: [32]u8 = undefined;
        random.bytes(&s);
        s[0] &= 0x7f; // ensure < 2^255

        const glv_point = endo.mulBasePointGLV(s, .big) catch continue;
        const std_point = StdSecp.basePoint.mul(s, .big) catch continue;

        const glv_aff = glv_point.toAffine();
        const std_aff = std_point.affineCoordinates();

        try std.testing.expectEqualSlices(u8, &std_aff.x.toBytes(.big), &glv_aff.x.toBytes());
        try std.testing.expectEqualSlices(u8, &std_aff.y.toBytes(.big), &glv_aff.y.toBytes());

        tested += 1;
        if (tested >= 1000) break;
    }
    try std.testing.expect(tested >= 1000);
}

// ── Test 4: Edge-case scalars ───────────────────────────────────

test "GLV: k = 1 gives generator" {
    var s = [_]u8{0} ** 32;
    s[31] = 1;
    const result = try endo.mulBasePointGLV(s, .big);
    const aff = result.toAffine();
    const g_aff = Point.G.toAffine();
    try std.testing.expectEqualSlices(u8, &g_aff.x.toBytes(), &aff.x.toBytes());
    try std.testing.expectEqualSlices(u8, &g_aff.y.toBytes(), &aff.y.toBytes());
}

test "GLV: k = n-1 gives -G" {
    // (n-1)·G = -G, which has same x as G but negated y
    var s: [32]u8 = undefined;
    std.mem.writeInt(u256, &s, N - 1, .big);

    const result = try endo.mulBasePointGLV(s, .big);
    const aff = result.toAffine();

    // x should equal Gx
    const g_aff = Point.G.toAffine();
    try std.testing.expectEqualSlices(u8, &g_aff.x.toBytes(), &aff.x.toBytes());

    // y should be -Gy (mod p), i.e., y != Gy
    try std.testing.expect(!std.mem.eql(u8, &g_aff.y.toBytes(), &aff.y.toBytes()));

    // Verify: y + Gy = 0 (mod p) via addition
    const sum = result.add(Point.G);
    try std.testing.expect(sum.isIdentity());
}

test "GLV: k = 2 gives 2G" {
    var s = [_]u8{0} ** 32;
    s[31] = 2;
    const result = try endo.mulBasePointGLV(s, .big);
    const aff = result.toAffine();

    const expected = StdSecp.basePoint.dbl().affineCoordinates();
    try std.testing.expectEqualSlices(u8, &expected.x.toBytes(.big), &aff.x.toBytes());
}

test "GLV: k = λ gives ψ(G) = (β·Gx, Gy)" {
    var s: [32]u8 = undefined;
    std.mem.writeInt(u256, &s, LAMBDA, .big);
    const result = try endo.mulBasePointGLV(s, .big);
    const aff = result.toAffine();

    // Compute expected: ψ(G) = (β·Gx, Gy)
    var beta_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &beta_bytes, BETA, .big);
    const beta_fe = Fe.fromBytes(beta_bytes);
    const expected_x = Point.G.x.mul(beta_fe).normalize();
    const expected_y = Point.G.y.normalize();

    try std.testing.expectEqualSlices(u8, &expected_x.toBytes(), &aff.x.toBytes());
    try std.testing.expectEqualSlices(u8, &expected_y.toBytes(), &aff.y.toBytes());
}

test "GLV: k = λ + 1" {
    var s: [32]u8 = undefined;
    std.mem.writeInt(u256, &s, (LAMBDA + 1) % N, .big);
    const result = try endo.mulBasePointGLV(s, .big);
    const expected = StdSecp.basePoint.mul(s, .big) catch unreachable;

    const our = result.toAffine();
    const exp = expected.affineCoordinates();
    try std.testing.expectEqualSlices(u8, &exp.x.toBytes(.big), &our.x.toBytes());
}

test "GLV: k = 0 returns identity error" {
    const s = [_]u8{0} ** 32;
    try std.testing.expectError(error.IdentityElement, endo.mulBasePointGLV(s, .big));
}

// ── Test 5: Endomorphism on non-generator points ────────────────

test "GLV: endomorphism is consistent for multiples of G" {
    var beta_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &beta_bytes, BETA, .big);
    const beta_fe = Fe.fromBytes(beta_bytes);

    var lambda_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &lambda_bytes, LAMBDA, .big);

    // For several points P = k·G, verify ψ(P) = λ·P
    const test_scalars = [_]u8{
        3, 7, 13, 42, 100, 200, 255,
    };

    for (test_scalars) |k| {
        var s = [_]u8{0} ** 32;
        s[31] = k;

        // Compute P = k·G using stdlib
        const p = try StdSecp.basePoint.mul(s, .big);
        const p_aff = p.affineCoordinates();

        // ψ(P) = (β·Px, Py)
        const px_our = Fe.fromBytes(p_aff.x.toBytes(.big));
        const psi_x = px_our.mul(beta_fe).normalize();

        // λ·P using stdlib
        const lambda_p = try p.mul(lambda_bytes, .big);
        const lambda_p_aff = lambda_p.affineCoordinates();

        try std.testing.expectEqualSlices(u8, &lambda_p_aff.x.toBytes(.big), &psi_x.toBytes());
    }
}
