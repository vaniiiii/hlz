# Signing

hlz implements two signing paths, matching the Hyperliquid protocol. The secp256k1 and EIP-712 implementation is adapted from [zabi](https://github.com/Raiden1411/zabi).

## Signing Paths

### RMP Path (Orders, Cancels)

Used for: `place`, `cancel`, `cancelByCloid`, `modify`, `batchModify`, `scheduleCancel`

```
Action → MessagePack → prepend nonce + vault → keccak256 → Agent EIP-712 (chainId 1337)
```

```zig
const signing = hlz.hypercore.signing;

const sig = try signing.signOrder(signer, batch, nonce, .mainnet, null, null);
// sig.r, sig.s, sig.v ready for JSON: {"r":"0x...","s":"0x...","v":27}
```

### Typed Data Path (Transfers, Approvals)

Used for: `usdSend`, `spotSend`, `sendAsset`, `updateLeverage`, `updateIsolatedMargin`, `approveAgent`, `setReferrer`

```
Fields → EIP-712 struct hash → Arbitrum domain (chainId 42161 mainnet / 421614 testnet)
```

```zig
const sig = try signing.signUsdSend(signer, destination, amount, nonce, .mainnet);
```

## The Signer

```zig
const Signer = hlz.crypto.signer.Signer;

// From hex string (64 chars, no 0x prefix)
const signer = try Signer.fromHex("abcdef1234...");

// The signer holds the private key and can produce ECDSA signatures
// It uses RFC 6979 deterministic nonces (no randomness needed)
```

## Chain Enum

```zig
const Chain = signing.Chain;

Chain.mainnet   // Arbitrum One (42161) for typed data, 1337 for agent
Chain.testnet   // Arbitrum Sepolia (421614) for typed data, 1337 for agent
```

## MessagePack Compatibility

The msgpack encoding must be **byte-exact** with Rust's `rmp-serde::to_vec_named`. This means:
- Named fields (not positional)
- Specific integer encoding widths
- Map ordering matches Rust struct field order
- The `type` field is embedded inside the map (serde `#[serde(tag = "type")]`)

## EIP-712 Details

All 7 EIP-712 type hashes are computed at **compile time**:

```zig
// Comptime: typeHash("Agent", "Agent(address source,address connectionId,...)")
// No runtime string hashing or allocation
```

The domain separator uses:
- `name = "Exchange"`
- `version = "1"`
- `chainId` = 42161 (mainnet) or 421614 (testnet) for typed data
- `chainId` = 1337 for agent-signed actions (orders, cancels)
- `verifyingContract = 0x0000000000000000000000000000000000000000`
