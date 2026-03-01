#!/usr/bin/env python3
"""Generate ECDSA test vectors using coincurve (libsecp256k1 wrapper).

These vectors serve as the ground truth for differential testing against
our custom Zig secp256k1 implementation. coincurve uses Bitcoin Core's
libsecp256k1 under the hood — the industry-standard reference.

Output: libsecp256k1_vectors.json
"""
import coincurve
import hashlib
import json
import os
import struct

CURVE_ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

def generate_vectors():
    vectors = []

    for i in range(1000):
        # Generate random valid private key
        while True:
            privkey_bytes = os.urandom(32)
            privkey_int = int.from_bytes(privkey_bytes, 'big')
            if 0 < privkey_int < CURVE_ORDER:
                break

        # Generate random message hash
        msghash = os.urandom(32)

        pk = coincurve.PrivateKey(privkey_bytes)

        # Sign with RFC 6979 deterministic nonce (hasher=None means prehashed)
        sig_recoverable = pk.sign_recoverable(msghash, hasher=None)

        # Extract r, s, v
        r = sig_recoverable[0:32]
        s = sig_recoverable[32:64]
        v = sig_recoverable[64]

        # Get public key (compressed)
        pubkey_compressed = pk.public_key.format(compressed=True)

        # Get public key (uncompressed)
        pubkey_uncompressed = pk.public_key.format(compressed=False)

        vectors.append({
            "privkey": privkey_bytes.hex(),
            "msghash": msghash.hex(),
            "r": r.hex(),
            "s": s.hex(),
            "v": v,
            "pubkey_compressed": pubkey_compressed.hex(),
            "pubkey_uncompressed": pubkey_uncompressed.hex(),
        })

    # Also add specific edge-case keys
    edge_cases = [
        # k = 1
        bytes([0] * 31 + [1]),
        # k = 2
        bytes([0] * 31 + [2]),
        # Small key
        bytes([0] * 31 + [0x42]),
        # Key with high byte
        bytes([0x7f] + [0xff] * 31),
        # Key near curve order (order - 1)
        (CURVE_ORDER - 1).to_bytes(32, 'big'),
        # Key near curve order (order - 2)
        (CURVE_ORDER - 2).to_bytes(32, 'big'),
    ]

    for privkey_bytes in edge_cases:
        privkey_int = int.from_bytes(privkey_bytes, 'big')
        if not (0 < privkey_int < CURVE_ORDER):
            continue

        pk = coincurve.PrivateKey(privkey_bytes)

        # Test with multiple message hashes
        test_messages = [
            bytes(32),  # all zeros hash
            bytes([0xff] * 32),  # all ones hash (exceeds curve order — tests bits2octets)
            bytes([i % 256 for i in range(32)]),  # sequential
            hashlib.sha256(b"test").digest(),
            hashlib.sha256(b"sample").digest(),
        ]

        for msghash in test_messages:
            sig_recoverable = pk.sign_recoverable(msghash, hasher=None)
            r = sig_recoverable[0:32]
            s = sig_recoverable[32:64]
            v = sig_recoverable[64]
            pubkey_compressed = pk.public_key.format(compressed=True)
            pubkey_uncompressed = pk.public_key.format(compressed=False)

            vectors.append({
                "privkey": privkey_bytes.hex(),
                "msghash": msghash.hex(),
                "r": r.hex(),
                "s": s.hex(),
                "v": v,
                "pubkey_compressed": pubkey_compressed.hex(),
                "pubkey_uncompressed": pubkey_uncompressed.hex(),
            })

    return vectors


if __name__ == "__main__":
    vectors = generate_vectors()
    outpath = os.path.join(os.path.dirname(__file__), "libsecp256k1_vectors.json")
    with open(outpath, "w") as f:
        json.dump(vectors, f, indent=2)
    print(f"Generated {len(vectors)} vectors -> {outpath}")
