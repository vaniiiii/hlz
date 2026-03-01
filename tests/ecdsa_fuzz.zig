//! Fuzz and robustness tests for secp256k1 ECDSA and field arithmetic.
//!
//! These tests feed random and adversarial inputs through every layer of the
//! crypto stack, asserting invariants that must hold regardless of input.
//! Catches crashes, integer overflow, and logic errors that structured tests miss.

const std = @import("std");
const hlz = @import("hlz");
const Fe = hlz.crypto.field.Fe;
const Point = hlz.crypto.point.Point;

const Signer = hlz.crypto.signer.Signer;
const Secp256k1 = std.crypto.ecc.Secp256k1;
const endo = hlz.crypto.endo;

// ── Field arithmetic invariants ──────────────────────────────────

test "fuzz: field mul commutativity (a·b = b·a)" {
    var prng = std.Random.DefaultPrng.init(0xF1E1D);
    const random = prng.random();

    for (0..10000) |_| {
        var a_bytes: [32]u8 = undefined;
        var b_bytes: [32]u8 = undefined;
        random.bytes(&a_bytes);
        random.bytes(&b_bytes);

        const a = Fe.fromBytes(a_bytes);
        const b = Fe.fromBytes(b_bytes);
        const ab = a.mul(b).normalize();
        const ba = b.mul(a).normalize();

        try std.testing.expect(ab.equivalent(ba));
    }
}

test "fuzz: field mul associativity ((a·b)·c = a·(b·c))" {
    var prng = std.Random.DefaultPrng.init(0xA550C);
    const random = prng.random();

    for (0..5000) |_| {
        var a_bytes: [32]u8 = undefined;
        var b_bytes: [32]u8 = undefined;
        var c_bytes: [32]u8 = undefined;
        random.bytes(&a_bytes);
        random.bytes(&b_bytes);
        random.bytes(&c_bytes);

        const a = Fe.fromBytes(a_bytes);
        const b = Fe.fromBytes(b_bytes);
        const c = Fe.fromBytes(c_bytes);

        const ab_c = a.mul(b).mul(c).normalize();
        const a_bc = a.mul(b.mul(c)).normalize();

        try std.testing.expect(ab_c.equivalent(a_bc));
    }
}

test "fuzz: field a·a⁻¹ = 1 for random elements" {
    var prng = std.Random.DefaultPrng.init(0x10_E47);
    const random = prng.random();

    for (0..1000) |_| {
        var bytes: [32]u8 = undefined;
        random.bytes(&bytes);

        const a = Fe.fromBytes(bytes).normalize();
        if (a.isZero()) continue;

        const product = a.mul(a.invert()).normalize();
        try std.testing.expect(product.equivalent(Fe.one));
    }
}

test "fuzz: field a + (-a) = 0" {
    var prng = std.Random.DefaultPrng.init(0xADD_0E6);
    const random = prng.random();

    for (0..10000) |_| {
        var bytes: [32]u8 = undefined;
        random.bytes(&bytes);

        const a = Fe.fromBytes(bytes).normalizeWeak();
        const sum = a.add(a.neg(1)).normalize();
        try std.testing.expect(sum.isZero());
    }
}

test "fuzz: field sqrt roundtrip" {
    var prng = std.Random.DefaultPrng.init(0x5047);
    const random = prng.random();

    var found_some: usize = 0;
    for (0..5000) |_| {
        var bytes: [32]u8 = undefined;
        random.bytes(&bytes);

        const a = Fe.fromBytes(bytes).normalize();
        if (a.isZero()) continue;

        // Compute a², then sqrt(a²) should be either a or -a
        const a_sq = a.sq().normalize();
        if (a_sq.sqrt()) |root| {
            const root_norm = root.normalize();
            const root_sq = root_norm.sq().normalize();
            try std.testing.expect(root_sq.equivalent(a_sq));
            found_some += 1;
        }
    }
    try std.testing.expect(found_some > 0);
}

// ── Point arithmetic invariants ──────────────────────────────────

test "fuzz: point doubling is on curve" {
    var prng = std.Random.DefaultPrng.init(0xDB1C4F);
    const random = prng.random();

    const B7 = Fe{ .d = .{ 7, 0, 0, 0, 0 } };

    for (0..500) |_| {
        var s: [32]u8 = undefined;
        random.bytes(&s);
        s[0] &= 0x7f;

        const p = endo.mulBasePointGLV(s, .big) catch continue;
        const p2 = p.dbl();
        const aff = p2.toAffine();

        // Check y² = x³ + 7
        const y2 = aff.y.sq().normalize();
        const x3_7 = aff.x.sq().mul(aff.x).add(B7).normalize();
        try std.testing.expect(y2.equivalent(x3_7));
    }
}

test "fuzz: point add commutativity (P + Q = Q + P)" {
    var prng = std.Random.DefaultPrng.init(0xADDC00);
    const random = prng.random();

    for (0..200) |_| {
        var s1: [32]u8 = undefined;
        var s2: [32]u8 = undefined;
        random.bytes(&s1);
        random.bytes(&s2);
        s1[0] &= 0x7f;
        s2[0] &= 0x7f;

        const p1 = endo.mulBasePointGLV(s1, .big) catch continue;
        const p2 = endo.mulBasePointGLV(s2, .big) catch continue;

        const sum1 = p1.add(p2).toAffine();
        const sum2 = p2.add(p1).toAffine();

        try std.testing.expectEqualSlices(u8, &sum1.x.toBytes(), &sum2.x.toBytes());
        try std.testing.expectEqualSlices(u8, &sum1.y.toBytes(), &sum2.y.toBytes());
    }
}

test "fuzz: P + identity = P" {
    var prng = std.Random.DefaultPrng.init(0x1DE07);
    const random = prng.random();

    for (0..200) |_| {
        var s: [32]u8 = undefined;
        random.bytes(&s);
        s[0] &= 0x7f;

        const p = endo.mulBasePointGLV(s, .big) catch continue;
        const sum = p.add(Point.identity);
        const p_aff = p.toAffine();
        const sum_aff = sum.toAffine();

        try std.testing.expectEqualSlices(u8, &p_aff.x.toBytes(), &sum_aff.x.toBytes());
    }
}

test "fuzz: P + (-P) = identity" {
    var prng = std.Random.DefaultPrng.init(0x03E6_0001);
    const random = prng.random();

    for (0..200) |_| {
        var s: [32]u8 = undefined;
        random.bytes(&s);
        s[0] &= 0x7f;

        const p = endo.mulBasePointGLV(s, .big) catch continue;
        const sum = p.add(p.neg());

        try std.testing.expect(sum.isIdentity());
    }
}

// ── Signing invariants ──────────────────────────────────────────

test "fuzz: sign-then-recover roundtrip for 500 random keys" {
    var prng = std.Random.DefaultPrng.init(0x0051_600);
    const random = prng.random();
    const half_n = Secp256k1.scalar.field_order / 2;

    var tested: usize = 0;
    for (0..600) |_| {
        var key: [32]u8 = undefined;
        random.bytes(&key);

        const signer = Signer.init(key) catch continue;

        var msg: [32]u8 = undefined;
        random.bytes(&msg);

        const sig = signer.sign(msg) catch continue;

        // Low-S
        try std.testing.expect(sig.s <= half_n);

        // Recovery id valid
        try std.testing.expect(sig.v == 0 or sig.v == 1);

        // r, s non-zero
        try std.testing.expect(sig.r != 0);
        try std.testing.expect(sig.s != 0);

        // Recover address
        const recovered = try Signer.recoverAddress(sig, msg);
        try std.testing.expectEqualSlices(u8, &signer.address, &recovered);

        tested += 1;
        if (tested >= 500) break;
    }
    try std.testing.expect(tested >= 500);
}

test "fuzz: deterministic — same key+msg always produces same sig" {
    var prng = std.Random.DefaultPrng.init(0xD3_73E4);
    const random = prng.random();

    for (0..100) |_| {
        var key: [32]u8 = undefined;
        random.bytes(&key);

        const signer = Signer.init(key) catch continue;

        var msg: [32]u8 = undefined;
        random.bytes(&msg);

        const sig1 = signer.sign(msg) catch continue;
        const sig2 = signer.sign(msg) catch continue;

        try std.testing.expectEqual(sig1.r, sig2.r);
        try std.testing.expectEqual(sig1.s, sig2.s);
        try std.testing.expectEqual(sig1.v, sig2.v);
    }
}

test "fuzz: different messages produce different signatures" {
    const key = [_]u8{0} ** 31 ++ [_]u8{42};
    const signer = try Signer.init(key);

    var prng = std.Random.DefaultPrng.init(0xD1FF_0001);
    const random = prng.random();

    var prev_r: u256 = 0;
    for (0..200) |_| {
        var msg: [32]u8 = undefined;
        random.bytes(&msg);

        const sig = signer.sign(msg) catch continue;
        // It's astronomically unlikely for two random messages to produce same r
        if (prev_r != 0) {
            try std.testing.expect(sig.r != prev_r);
        }
        prev_r = sig.r;
    }
}

// ── Invalid input handling ──────────────────────────────────────

test "fuzz: Signer.init rejects zero key" {
    const zero_key = [_]u8{0} ** 32;
    try std.testing.expectError(error.IdentityElement, Signer.init(zero_key));
}

test "fuzz: Signer.init rejects key = n (curve order)" {
    // key = exact curve order → n·G = identity → should fail
    var order_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &order_bytes, Secp256k1.scalar.field_order, .big);
    try std.testing.expectError(error.IdentityElement, Signer.init(order_bytes));
}

test "fuzz: Signer.init rejects key >= n" {
    // key = n+1 is non-canonical — init must reject it, not silently wrap.
    // Without this check, the stored private_key bytes would differ from
    // the effective scalar, and sign() would fail with NonCanonical.
    var order_plus_1: [32]u8 = undefined;
    std.mem.writeInt(u256, &order_plus_1, Secp256k1.scalar.field_order + 1, .big);
    try std.testing.expectError(error.IdentityElement, Signer.init(order_plus_1));

    // n + 2
    var order_plus_2: [32]u8 = undefined;
    std.mem.writeInt(u256, &order_plus_2, Secp256k1.scalar.field_order + 2, .big);
    try std.testing.expectError(error.IdentityElement, Signer.init(order_plus_2));

    // max u256
    const max_key = [_]u8{0xff} ** 32;
    try std.testing.expectError(error.IdentityElement, Signer.init(max_key));
}

test "fuzz: recover rejects invalid signatures" {
    const msg = [_]u8{0xab} ** 32;

    // All-zero r and s
    const zero_sig = hlz.crypto.signer.Signature{ .r = 0, .s = 0, .v = 0 };
    try std.testing.expect(std.meta.isError(Signer.recoverAddress(zero_sig, msg)));

    // r=0, s=1
    const r0_sig = hlz.crypto.signer.Signature{ .r = 0, .s = 1, .v = 0 };
    try std.testing.expect(std.meta.isError(Signer.recoverAddress(r0_sig, msg)));

    // r=n (curve order), s=1
    const rn_sig = hlz.crypto.signer.Signature{ .r = Secp256k1.scalar.field_order, .s = 1, .v = 0 };
    try std.testing.expect(std.meta.isError(Signer.recoverAddress(rn_sig, msg)));
}

test "fuzz: mutated signatures fail recovery to original address" {
    var prng = std.Random.DefaultPrng.init(0x000A_7E8);
    const random = prng.random();

    for (0..100) |_| {
        var key: [32]u8 = undefined;
        random.bytes(&key);
        const signer = Signer.init(key) catch continue;

        var msg: [32]u8 = undefined;
        random.bytes(&msg);
        const sig = signer.sign(msg) catch continue;

        // Flip one bit in r
        var mutated = sig;
        mutated.r ^= 1;

        if (Signer.recoverAddress(mutated, msg)) |recovered| {
            // If recovery succeeds, it must NOT match original address
            try std.testing.expect(!std.mem.eql(u8, &recovered, &signer.address));
        } else |_| {
            // Recovery failure is also acceptable
        }
    }
}

// ── EIP-712 signing robustness ──────────────────────────────────

test "fuzz: EIP-712 signAgent roundtrip for random keys" {
    const eip712 = hlz.crypto.eip712;
    var prng = std.Random.DefaultPrng.init(0xE10_712);
    const random = prng.random();

    for (0..200) |_| {
        var key: [32]u8 = undefined;
        random.bytes(&key);
        const signer = Signer.init(key) catch continue;

        var connection_id: [32]u8 = undefined;
        random.bytes(&connection_id);

        // Sign for mainnet
        {
            const sig = eip712.signAgent(signer, true, connection_id) catch continue;
            const struct_hash = eip712.hashAgent("a", connection_id);
            const hash = eip712.signingHash(eip712.CORE_DOMAIN_SEPARATOR, struct_hash);
            const recovered = try Signer.recoverAddress(sig, hash);
            try std.testing.expectEqualSlices(u8, &signer.address, &recovered);
        }
        // Sign for testnet
        {
            const sig = eip712.signAgent(signer, false, connection_id) catch continue;
            const struct_hash = eip712.hashAgent("b", connection_id);
            const hash = eip712.signingHash(eip712.CORE_DOMAIN_SEPARATOR, struct_hash);
            const recovered = try Signer.recoverAddress(sig, hash);
            try std.testing.expectEqualSlices(u8, &signer.address, &recovered);
        }
    }
}
