const std = @import("std");
const hlz = @import("hlz");

const Signer = hlz.crypto.signer.Signer;
const HlSignature = hlz.crypto.signer.Signature;
const StdEcdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
const Secp256k1 = std.crypto.ecc.Secp256k1;

fn toStdSignature(sig: HlSignature) StdEcdsa.Signature {
    var bytes: [64]u8 = undefined;
    std.mem.writeInt(u256, bytes[0..32], sig.r, .big);
    std.mem.writeInt(u256, bytes[32..64], sig.s, .big);
    return StdEcdsa.Signature.fromBytes(bytes);
}

fn randomValidPrivateKey(random: std.Random) ![32]u8 {
    while (true) {
        var key: [32]u8 = undefined;
        random.bytes(&key);
        if (Signer.init(key)) |_| return key else |_| {}
    }
}

test "ecdsa differential hlz sign verifies with stdlib" {
    var prng = std.Random.DefaultPrng.init(0xdecafbad);
    const random = prng.random();

    for (0..64) |_| {
        const key = try randomValidPrivateKey(random);
        const signer = try Signer.init(key);
        const pub_key = try StdEcdsa.PublicKey.fromSec1(&signer.public_key);

        for (0..8) |_| {
            var msg_hash: [32]u8 = undefined;
            random.bytes(&msg_hash);

            const sig = try signer.sign(msg_hash);
            const std_sig = toStdSignature(sig);

            try StdEcdsa.Signature.verifyPrehashed(std_sig, msg_hash, pub_key);

            const recovered = try Signer.recoverAddress(sig, msg_hash);
            try std.testing.expectEqualSlices(u8, &signer.address, &recovered);

            try std.testing.expect(sig.s <= Secp256k1.scalar.field_order / 2);
        }
    }
}

test "ecdsa differential mutated signatures fail stdlib verify" {
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    for (0..64) |_| {
        const key = try randomValidPrivateKey(random);
        const signer = try Signer.init(key);
        const pub_key = try StdEcdsa.PublicKey.fromSec1(&signer.public_key);

        var msg_hash: [32]u8 = undefined;
        random.bytes(&msg_hash);

        const sig = try signer.sign(msg_hash);
        var sig_bytes = toStdSignature(sig).toBytes();
        sig_bytes[0] ^= 0x01;

        const mutated = StdEcdsa.Signature.fromBytes(sig_bytes);
        const res = StdEcdsa.Signature.verifyPrehashed(mutated, msg_hash, pub_key);
        try std.testing.expectError(error.SignatureVerificationFailed, res);
    }
}
