//! Comptime EIP-712 typed data hashing for all 7 Hyperliquid struct types.
//! Type hashes and domain separators pre-computed at compile time.

const std = @import("std");
const signer = @import("signer.zig");

const Keccak256 = std.crypto.hash.sha3.Keccak256;
const Hash = signer.Hash;


/// Compute keccak256 at comptime.
fn comptimeKeccak256(data: []const u8) Hash {
    @setEvalBranchQuota(100_000);
    var hash: Hash = undefined;
    Keccak256.hash(data, &hash, .{});
    return hash;
}

/// ABI-encode a uint64 as uint256 (32 bytes, big-endian, left-padded).
fn encodeUint64(value: u64) [32]u8 {
    var buf: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, buf[24..32], value, .big);
    return buf;
}

/// ABI-encode an address (20 bytes, left-padded to 32).
fn encodeAddress(addr: [20]u8) [32]u8 {
    var buf: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buf[12..32], &addr);
    return buf;
}

/// Hash a string value for EIP-712 (keccak256 of the raw bytes).
fn hashString(s: []const u8) Hash {
    return signer.keccak256(s);
}

// Pre-computed at comptime from the Rust SDK domain definitions.

const EIP712_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
const EIP712_DOMAIN_TYPEHASH = comptimeKeccak256(EIP712_DOMAIN_TYPE);

/// EIP-712 domain parameters.
pub const Domain = struct {
    name: []const u8,
    version: []const u8,
    chain_id: u256,
    verifying_contract: [20]u8,
};

/// Compute the domain separator hash.
pub fn domainSeparator(domain: Domain) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&EIP712_DOMAIN_TYPEHASH);
    hasher.update(&hashString(domain.name));
    hasher.update(&hashString(domain.version));
    var chain_id_buf: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u256, &chain_id_buf, domain.chain_id, .big);
    hasher.update(&chain_id_buf);
    hasher.update(&encodeAddress(domain.verifying_contract));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}


/// Core domain — used for Agent signing (orders, cancels via RMP path).
/// chainId: 1337, name: "Exchange"
pub const CORE_DOMAIN = Domain{
    .name = "Exchange",
    .version = "1",
    .chain_id = 1337,
    .verifying_contract = [_]u8{0} ** 20,
};

/// Arbitrum mainnet — used for typed data signing (transfers, approvals).
/// chainId: 42161, name: "HyperliquidSignTransaction"
pub const MAINNET_DOMAIN = Domain{
    .name = "HyperliquidSignTransaction",
    .version = "1",
    .chain_id = 42161,
    .verifying_contract = [_]u8{0} ** 20,
};

/// Arbitrum testnet — chainId: 421614
pub const TESTNET_DOMAIN = Domain{
    .name = "HyperliquidSignTransaction",
    .version = "1",
    .chain_id = 421614,
    .verifying_contract = [_]u8{0} ** 20,
};

// Pre-computed domain separators
pub const CORE_DOMAIN_SEPARATOR = comptimeDomainSeparator(CORE_DOMAIN);
pub const MAINNET_DOMAIN_SEPARATOR = comptimeDomainSeparator(MAINNET_DOMAIN);
pub const TESTNET_DOMAIN_SEPARATOR = comptimeDomainSeparator(TESTNET_DOMAIN);

fn comptimeDomainSeparator(domain: Domain) Hash {
    @setEvalBranchQuota(100_000);
    return domainSeparator(domain);
}

// Hyperliquid wraps types with "HyperliquidTransaction:" prefix for typed data path.

const HL_PREFIX = "HyperliquidTransaction:";

// Agent (used in RMP signing path — no prefix)
pub const AGENT_TYPE = "Agent(string source,bytes32 connectionId)";
pub const AGENT_TYPEHASH = comptimeKeccak256(AGENT_TYPE);

// UsdSend
pub const USD_SEND_TYPE = HL_PREFIX ++ "UsdSend(string hyperliquidChain,string destination,string amount,uint64 time)";
pub const USD_SEND_TYPEHASH = comptimeKeccak256(USD_SEND_TYPE);

// SpotSend
pub const SPOT_SEND_TYPE = HL_PREFIX ++ "SpotSend(string hyperliquidChain,string destination,string token,string amount,uint64 time)";
pub const SPOT_SEND_TYPEHASH = comptimeKeccak256(SPOT_SEND_TYPE);

// SendAsset
pub const SEND_ASSET_TYPE = HL_PREFIX ++ "SendAsset(string hyperliquidChain,string destination,string sourceDex,string destinationDex,string token,string amount,string fromSubAccount,uint64 nonce)";
pub const SEND_ASSET_TYPEHASH = comptimeKeccak256(SEND_ASSET_TYPE);

// ApproveAgent
pub const APPROVE_AGENT_TYPE = HL_PREFIX ++ "ApproveAgent(string hyperliquidChain,address agentAddress,string agentName,uint64 nonce)";
pub const APPROVE_AGENT_TYPEHASH = comptimeKeccak256(APPROVE_AGENT_TYPE);

// ConvertToMultiSigUser
pub const CONVERT_MULTISIG_TYPE = HL_PREFIX ++ "ConvertToMultiSigUser(string hyperliquidChain,string signers,uint64 nonce)";
pub const CONVERT_MULTISIG_TYPEHASH = comptimeKeccak256(CONVERT_MULTISIG_TYPE);

// SendMultiSig
pub const SEND_MULTISIG_TYPE = HL_PREFIX ++ "SendMultiSig(string hyperliquidChain,bytes32 multiSigActionHash,uint64 nonce)";
pub const SEND_MULTISIG_TYPEHASH = comptimeKeccak256(SEND_MULTISIG_TYPE);


/// Hash the Agent struct (RMP signing path).
/// Agent { source: string, connectionId: bytes32 }
pub fn hashAgent(source: []const u8, connection_id: Hash) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&AGENT_TYPEHASH);
    hasher.update(&hashString(source));
    hasher.update(&connection_id); // bytes32 passed as-is
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Hash UsdSend struct.
pub fn hashUsdSend(chain: []const u8, destination: []const u8, amount: []const u8, time: u64) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&USD_SEND_TYPEHASH);
    hasher.update(&hashString(chain));
    hasher.update(&hashString(destination));
    hasher.update(&hashString(amount));
    hasher.update(&encodeUint64(time));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Hash SpotSend struct.
pub fn hashSpotSend(chain: []const u8, destination: []const u8, token: []const u8, amount: []const u8, time: u64) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&SPOT_SEND_TYPEHASH);
    hasher.update(&hashString(chain));
    hasher.update(&hashString(destination));
    hasher.update(&hashString(token));
    hasher.update(&hashString(amount));
    hasher.update(&encodeUint64(time));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Hash SendAsset struct.
pub fn hashSendAsset(
    chain: []const u8,
    destination: []const u8,
    source_dex: []const u8,
    destination_dex: []const u8,
    token: []const u8,
    amount: []const u8,
    from_sub_account: []const u8,
    nonce: u64,
) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&SEND_ASSET_TYPEHASH);
    hasher.update(&hashString(chain));
    hasher.update(&hashString(destination));
    hasher.update(&hashString(source_dex));
    hasher.update(&hashString(destination_dex));
    hasher.update(&hashString(token));
    hasher.update(&hashString(amount));
    hasher.update(&hashString(from_sub_account));
    hasher.update(&encodeUint64(nonce));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Hash ApproveAgent struct.
pub fn hashApproveAgent(chain: []const u8, agent_address: [20]u8, agent_name: []const u8, nonce: u64) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&APPROVE_AGENT_TYPEHASH);
    hasher.update(&hashString(chain));
    hasher.update(&encodeAddress(agent_address));
    hasher.update(&hashString(agent_name));
    hasher.update(&encodeUint64(nonce));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Hash ConvertToMultiSigUser struct.
pub fn hashConvertToMultiSigUser(chain: []const u8, signers_json: []const u8, nonce: u64) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&CONVERT_MULTISIG_TYPEHASH);
    hasher.update(&hashString(chain));
    hasher.update(&hashString(signers_json));
    hasher.update(&encodeUint64(nonce));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Hash SendMultiSig struct.
pub fn hashSendMultiSig(chain: []const u8, multi_sig_action_hash: Hash, nonce: u64) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&SEND_MULTISIG_TYPEHASH);
    hasher.update(&hashString(chain));
    hasher.update(&multi_sig_action_hash);
    hasher.update(&encodeUint64(nonce));
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}


/// Compute the EIP-712 signing hash: keccak256(0x19 ++ 0x01 ++ domainSeparator ++ structHash)
pub fn signingHash(domain_sep: Hash, struct_hash: Hash) Hash {
    var hasher = Keccak256.init(.{});
    hasher.update(&[_]u8{ 0x19, 0x01 });
    hasher.update(&domain_sep);
    hasher.update(&struct_hash);
    var hash: Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Sign an Agent struct (RMP path). This is the hot path for orders/cancels.
/// Zero allocations.
pub fn signAgent(s: signer.Signer, chain_is_mainnet: bool, connection_id: Hash) signer.SignError!signer.Signature {
    const source: []const u8 = if (chain_is_mainnet) "a" else "b";
    const struct_hash = hashAgent(source, connection_id);
    const hash = signingHash(CORE_DOMAIN_SEPARATOR, struct_hash);
    return s.sign(hash);
}

/// Sign a UsdSend (typed data path).
pub fn signUsdSend(
    s: signer.Signer,
    is_mainnet: bool,
    destination: []const u8,
    amount: []const u8,
    time: u64,
) signer.SignError!signer.Signature {
    const chain_str: []const u8 = if (is_mainnet) "Mainnet" else "Testnet";
    const struct_hash = hashUsdSend(chain_str, destination, amount, time);
    const domain_sep = if (is_mainnet) MAINNET_DOMAIN_SEPARATOR else TESTNET_DOMAIN_SEPARATOR;
    const hash = signingHash(domain_sep, struct_hash);
    return s.sign(hash);
}

/// Sign a SpotSend (typed data path).
pub fn signSpotSend(
    s: signer.Signer,
    is_mainnet: bool,
    destination: []const u8,
    token: []const u8,
    amount: []const u8,
    time: u64,
) signer.SignError!signer.Signature {
    const chain_str: []const u8 = if (is_mainnet) "Mainnet" else "Testnet";
    const struct_hash = hashSpotSend(chain_str, destination, token, amount, time);
    const domain_sep = if (is_mainnet) MAINNET_DOMAIN_SEPARATOR else TESTNET_DOMAIN_SEPARATOR;
    return s.sign(signingHash(domain_sep, struct_hash));
}

/// Sign a SendAsset (typed data path).
pub fn signSendAsset(
    s: signer.Signer,
    is_mainnet: bool,
    destination: []const u8,
    source_dex: []const u8,
    destination_dex: []const u8,
    token: []const u8,
    amount: []const u8,
    from_sub_account: []const u8,
    nonce: u64,
) signer.SignError!signer.Signature {
    const chain_str: []const u8 = if (is_mainnet) "Mainnet" else "Testnet";
    const struct_hash = hashSendAsset(chain_str, destination, source_dex, destination_dex, token, amount, from_sub_account, nonce);
    const domain_sep = if (is_mainnet) MAINNET_DOMAIN_SEPARATOR else TESTNET_DOMAIN_SEPARATOR;
    return s.sign(signingHash(domain_sep, struct_hash));
}

/// Parse a hex address string (0x-prefixed, 42 chars) into a [20]u8.
fn parseAddress(hex: []const u8) ?[20]u8 {
    const start: usize = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X')) 2 else 0;
    const clean = hex[start..];
    if (clean.len != 40) return null;
    var addr: [20]u8 = undefined;
    for (0..20) |i| {
        addr[i] = std.fmt.parseInt(u8, clean[i * 2 ..][0..2], 16) catch return null;
    }
    return addr;
}

/// Sign an ApproveAgent (typed data path).
pub fn signApproveAgent(
    s: signer.Signer,
    is_mainnet: bool,
    agent_address: []const u8,
    agent_name: []const u8,
    nonce: u64,
) signer.SignError!signer.Signature {
    const chain_str: []const u8 = if (is_mainnet) "Mainnet" else "Testnet";
    const addr = parseAddress(agent_address) orelse return error.IdentityElementError;
    const struct_hash = hashApproveAgent(chain_str, addr, agent_name, nonce);
    const domain_sep = if (is_mainnet) MAINNET_DOMAIN_SEPARATOR else TESTNET_DOMAIN_SEPARATOR;
    return s.sign(signingHash(domain_sep, struct_hash));
}

/// Sign a ConvertToMultiSigUser (typed data path).
/// `signers_json` should be the JSON representation of the signers config.
pub fn signConvertToMultiSigUser(
    s: signer.Signer,
    is_mainnet: bool,
    signers_json: []const u8,
    nonce: u64,
) signer.SignError!signer.Signature {
    const chain_str: []const u8 = if (is_mainnet) "Mainnet" else "Testnet";
    const struct_hash = hashConvertToMultiSigUser(chain_str, signers_json, nonce);
    const domain_sep = if (is_mainnet) MAINNET_DOMAIN_SEPARATOR else TESTNET_DOMAIN_SEPARATOR;
    return s.sign(signingHash(domain_sep, struct_hash));
}

/// Sign a SendMultiSig (typed data path).
pub fn signSendMultiSig(
    s: signer.Signer,
    is_mainnet: bool,
    multi_sig_action_hash: Hash,
    nonce: u64,
) signer.SignError!signer.Signature {
    const chain_str: []const u8 = if (is_mainnet) "Mainnet" else "Testnet";
    const struct_hash = hashSendMultiSig(chain_str, multi_sig_action_hash, nonce);
    const domain_sep = if (is_mainnet) MAINNET_DOMAIN_SEPARATOR else TESTNET_DOMAIN_SEPARATOR;
    return s.sign(signingHash(domain_sep, struct_hash));
}


test "eip712: domain separator is deterministic" {
    const sep1 = domainSeparator(CORE_DOMAIN);
    const sep2 = domainSeparator(CORE_DOMAIN);
    try std.testing.expectEqualSlices(u8, &sep1, &sep2);
}

test "eip712: comptime domain separators are valid" {
    // Verify comptime and runtime produce same result
    const runtime_core = domainSeparator(CORE_DOMAIN);
    try std.testing.expectEqualSlices(u8, &CORE_DOMAIN_SEPARATOR, &runtime_core);

    const runtime_mainnet = domainSeparator(MAINNET_DOMAIN);
    try std.testing.expectEqualSlices(u8, &MAINNET_DOMAIN_SEPARATOR, &runtime_mainnet);

    const runtime_testnet = domainSeparator(TESTNET_DOMAIN);
    try std.testing.expectEqualSlices(u8, &TESTNET_DOMAIN_SEPARATOR, &runtime_testnet);
}

test "eip712: different domains produce different separators" {
    try std.testing.expect(!std.mem.eql(u8, &CORE_DOMAIN_SEPARATOR, &MAINNET_DOMAIN_SEPARATOR));
    try std.testing.expect(!std.mem.eql(u8, &MAINNET_DOMAIN_SEPARATOR, &TESTNET_DOMAIN_SEPARATOR));
}

test "eip712: agent struct hash" {
    const connection_id = signer.keccak256("test");
    const hash1 = hashAgent("a", connection_id);
    const hash2 = hashAgent("a", connection_id);
    try std.testing.expectEqualSlices(u8, &hash1, &hash2);

    // Different source → different hash
    const hash3 = hashAgent("b", connection_id);
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

test "eip712: signing hash format" {
    // Verify the 0x19 0x01 prefix is applied correctly
    const struct_hash = [_]u8{0xaa} ** 32;
    const domain_sep = [_]u8{0xbb} ** 32;
    const hash = signingHash(domain_sep, struct_hash);

    // Result should be keccak256(0x19 || 0x01 || domain || struct)
    var expected_input: [66]u8 = undefined;
    expected_input[0] = 0x19;
    expected_input[1] = 0x01;
    @memcpy(expected_input[2..34], &domain_sep);
    @memcpy(expected_input[34..66], &struct_hash);

    const expected = signer.keccak256(&expected_input);
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "eip712: signAgent produces recoverable signature" {
    const s = try signer.Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");
    const connection_id = signer.keccak256("test order hash");

    const sig = try signAgent(s, true, connection_id);

    // Recover — must match signer address
    const struct_hash = hashAgent("a", connection_id);
    const hash = signingHash(CORE_DOMAIN_SEPARATOR, struct_hash);
    const recovered = try signer.Signer.recoverAddress(sig, hash);
    try std.testing.expectEqualSlices(u8, &s.address, &recovered);
}

test "eip712: type hashes are non-zero" {
    const zero = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &AGENT_TYPEHASH, &zero));
    try std.testing.expect(!std.mem.eql(u8, &USD_SEND_TYPEHASH, &zero));
    try std.testing.expect(!std.mem.eql(u8, &SPOT_SEND_TYPEHASH, &zero));
    try std.testing.expect(!std.mem.eql(u8, &SEND_ASSET_TYPEHASH, &zero));
    try std.testing.expect(!std.mem.eql(u8, &APPROVE_AGENT_TYPEHASH, &zero));
    try std.testing.expect(!std.mem.eql(u8, &CONVERT_MULTISIG_TYPEHASH, &zero));
    try std.testing.expect(!std.mem.eql(u8, &SEND_MULTISIG_TYPEHASH, &zero));
}

test "eip712: all type hashes are unique" {
    const hashes = [_]*const Hash{
        &AGENT_TYPEHASH,
        &USD_SEND_TYPEHASH,
        &SPOT_SEND_TYPEHASH,
        &SEND_ASSET_TYPEHASH,
        &APPROVE_AGENT_TYPEHASH,
        &CONVERT_MULTISIG_TYPEHASH,
        &SEND_MULTISIG_TYPEHASH,
    };
    for (hashes, 0..) |a, i| {
        for (hashes[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}
