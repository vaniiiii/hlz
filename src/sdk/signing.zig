//! Signing orchestration for Hyperliquid actions.
//! RMP path: msgpack → nonce/vault → keccak256 → Agent EIP-712.
//! Typed data path: EIP-712 struct hash → sign directly.

const std = @import("std");
const msgpack = @import("../lib/encoding/msgpack.zig");
const signer = @import("../lib/crypto/signer.zig");
const eip712 = @import("../lib/crypto/eip712.zig");
const types = @import("types.zig");

const Hash = signer.Hash;
const Address = signer.Address;
const Signature = signer.Signature;
const Signer = signer.Signer;

pub const Chain = enum {
    mainnet,
    testnet,

    pub fn isMainnet(self: Chain) bool { return self == .mainnet; }
    pub fn name(self: Chain) []const u8 { return if (self == .mainnet) "Mainnet" else "Testnet"; }
    pub fn sigChainId(self: Chain) []const u8 { return if (self == .mainnet) "0xa4b1" else "0x66eee"; }
};

pub const SignError = signer.SignError || msgpack.PackError || error{BufferOverflow};

/// Compute the RMP hash of a BatchOrder for signing.
pub fn rmpHashOrder(
    batch: types.BatchOrder,
    nonce: u64,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Hash {
    var buf: [4096]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionOrder(&p, batch);
    return rmpHashGeneric(p.written(), nonce, vault_address, expires_after);
}

/// Sign a batch order (RMP path).
pub fn signOrder(
    s: Signer,
    batch: types.BatchOrder,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    const connection_id = try rmpHashOrder(batch, nonce, vault_address, expires_after);
    return eip712.signAgent(s, chain.isMainnet(), connection_id);
}

/// Compute the RMP hash of a BatchCancel for signing.
pub fn rmpHashCancel(
    batch: types.BatchCancel,
    nonce: u64,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Hash {
    var buf: [4096]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionCancel(&p, batch);
    return rmpHashGeneric(p.written(), nonce, vault_address, expires_after);
}

/// Sign a batch cancel (RMP path).
pub fn signCancel(
    s: Signer,
    batch: types.BatchCancel,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    const connection_id = try rmpHashCancel(batch, nonce, vault_address, expires_after);
    return eip712.signAgent(s, chain.isMainnet(), connection_id);
}


/// Generic RMP hash: serialize action to msgpack, append nonce/vault/expires, keccak256.
fn rmpHashGeneric(packed_data: []const u8, nonce: u64, vault_address: ?Address, expires_after: ?u64) Hash {
    var hash_buf: [4096 + 64]u8 = undefined;
    var pos: usize = 0;

    @memcpy(hash_buf[pos..][0..packed_data.len], packed_data);
    pos += packed_data.len;

    const nonce_bytes = std.mem.toBytes(std.mem.nativeTo(u64, nonce, .big));
    @memcpy(hash_buf[pos..][0..8], &nonce_bytes);
    pos += 8;

    if (vault_address) |va| {
        hash_buf[pos] = 0x01;
        pos += 1;
        @memcpy(hash_buf[pos..][0..20], &va);
        pos += 20;
    } else {
        hash_buf[pos] = 0x00;
        pos += 1;
    }

    if (expires_after) |ea| {
        hash_buf[pos] = 0x00;
        pos += 1;
        const ea_bytes = std.mem.toBytes(std.mem.nativeTo(u64, ea, .big));
        @memcpy(hash_buf[pos..][0..8], &ea_bytes);
        pos += 8;
    }

    return signer.keccak256(hash_buf[0..pos]);
}

/// Sign any RMP-path action: serialize → hash → Agent → EIP-712.
fn signRmpAction(s: Signer, packed_data: []const u8, nonce: u64, chain: Chain, vault_address: ?Address, expires_after: ?u64) signer.SignError!Signature {
    const connection_id = rmpHashGeneric(packed_data, nonce, vault_address, expires_after);
    return eip712.signAgent(s, chain.isMainnet(), connection_id);
}


/// Sign a batch cancel by cloid (RMP path).
pub fn signCancelByCloid(
    s: Signer,
    batch: types.BatchCancelCloid,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [4096]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionCancelByCloid(&p, batch);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a batch modify (RMP path).
pub fn signModify(
    s: Signer,
    batch: types.BatchModify,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [8192]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionBatchModify(&p, batch);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a schedule cancel (RMP path).
pub fn signScheduleCancel(
    s: Signer,
    sc: types.ScheduleCancel,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionScheduleCancel(&p, sc);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign an update isolated margin (RMP path).
pub fn signUpdateIsolatedMargin(
    s: Signer,
    uim: types.UpdateIsolatedMargin,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionUpdateIsolatedMargin(&p, uim);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign an updateLeverage action (RMP path).
pub fn signUpdateLeverage(
    s: Signer,
    ul: types.UpdateLeverage,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionUpdateLeverage(&p, ul);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a setReferrer action (RMP path).
pub fn signSetReferrer(
    s: Signer,
    sr: types.SetReferrer,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionSetReferrer(&p, sr);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign an EVM user modify (RMP path).
pub fn signEvmUserModify(
    s: Signer,
    using_big_blocks: bool,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionEvmUserModify(&p, using_big_blocks);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a noop (RMP path).
pub fn signNoop(
    s: Signer,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionNoop(&p);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}


/// Sign a UsdSend action (typed data path).
pub fn signUsdSend(
    s: Signer,
    chain: Chain,
    destination: Address,
    amount: []const u8,
    time: u64,
) signer.SignError!Signature {
    return eip712.signUsdSend(s, chain.isMainnet(), destination, amount, time);
}

/// Sign a SpotSend action (typed data path).
pub fn signSpotSend(
    s: Signer,
    chain: Chain,
    destination: Address,
    token: []const u8,
    amount: []const u8,
    time: u64,
) signer.SignError!Signature {
    return eip712.signSpotSend(s, chain.isMainnet(), destination, token, amount, time);
}

/// Sign a SendAsset action (typed data path).
pub fn signSendAsset(
    s: Signer,
    chain: Chain,
    destination: Address,
    source_dex: []const u8,
    destination_dex: []const u8,
    token: []const u8,
    amount: []const u8,
    from_sub_account: []const u8,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signSendAsset(s, chain.isMainnet(), destination, source_dex, destination_dex, token, amount, from_sub_account, nonce);
}

/// Sign an ApproveAgent action (typed data path).
pub fn signApproveAgent(
    s: Signer,
    chain: Chain,
    agent_address: Address,
    agent_name: []const u8,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signApproveAgent(s, chain.isMainnet(), agent_address, agent_name, nonce);
}

/// Sign a Withdraw action (bridge withdrawal, typed data path).
pub fn signWithdraw(
    s: Signer,
    chain: Chain,
    destination: Address,
    amount: []const u8,
    time: u64,
) signer.SignError!Signature {
    return eip712.signWithdraw(s, chain.isMainnet(), destination, amount, time);
}

/// Sign a UsdClassTransfer action (spot ↔ perp, typed data path).
pub fn signUsdClassTransfer(
    s: Signer,
    chain: Chain,
    amount: []const u8,
    to_perp: bool,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signUsdClassTransfer(s, chain.isMainnet(), amount, to_perp, nonce);
}

/// Sign a TokenDelegate action (staking, typed data path).
pub fn signTokenDelegate(
    s: Signer,
    chain: Chain,
    validator: Address,
    wei: u64,
    is_undelegate: bool,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signTokenDelegate(s, chain.isMainnet(), validator, wei, is_undelegate, nonce);
}

/// Sign an ApproveBuilderFee action (typed data path).
pub fn signApproveBuilderFee(
    s: Signer,
    chain: Chain,
    max_fee_rate: []const u8,
    builder: Address,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signApproveBuilderFee(s, chain.isMainnet(), max_fee_rate, builder, nonce);
}

/// Sign a ConvertToMultiSigUser action (typed data path).
pub fn signConvertToMultiSig(
    s: Signer,
    chain: Chain,
    signers_json: []const u8,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signConvertToMultiSigUser(s, chain.isMainnet(), signers_json, nonce);
}


/// Sign a UserDexAbstraction action (typed data path).
pub fn signUserDexAbstraction(
    s: Signer,
    chain: Chain,
    user: Address,
    enabled: bool,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signUserDexAbstraction(s, chain.isMainnet(), user, enabled, nonce);
}

/// Sign a UserSetAbstraction action (typed data path).
pub fn signUserSetAbstraction(
    s: Signer,
    chain: Chain,
    user: Address,
    abstraction: []const u8,
    nonce: u64,
) signer.SignError!Signature {
    return eip712.signUserSetAbstraction(s, chain.isMainnet(), user, abstraction, nonce);
}

/// Sign a VaultTransfer action (RMP path).
pub fn signVaultTransfer(
    s: Signer,
    vt: types.VaultTransfer,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [512]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionVaultTransfer(&p, vt);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a CreateSubAccount action (RMP path).
pub fn signCreateSubAccount(
    s: Signer,
    csa: types.CreateSubAccount,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionCreateSubAccount(&p, csa);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a SubAccountTransfer action (RMP path).
pub fn signSubAccountTransfer(
    s: Signer,
    sat: types.SubAccountTransfer,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [512]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionSubAccountTransfer(&p, sat);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a SubAccountSpotTransfer action (RMP path).
pub fn signSubAccountSpotTransfer(
    s: Signer,
    sst: types.SubAccountSpotTransfer,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [512]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionSubAccountSpotTransfer(&p, sst);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a TwapOrder action (RMP path).
pub fn signTwapOrder(
    s: Signer,
    tw: types.TwapOrder,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [512]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionTwapOrder(&p, tw);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a TwapCancel action (RMP path).
pub fn signTwapCancel(
    s: Signer,
    tc: types.TwapCancel,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try types.packActionTwapCancel(&p, tc);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign a SpotDeploy action (RMP path). Generic — takes pre-packed msgpack.
pub fn signSpotDeploy(
    s: Signer,
    packed_data: []const u8,
    nonce: u64,
    chain: Chain,
    expires_after: ?u64,
) signer.SignError!Signature {
    return signRmpAction(s, packed_data, nonce, chain, null, expires_after);
}

/// Sign a PerpDeploy action (RMP path). Generic — takes pre-packed msgpack.
pub fn signPerpDeploy(
    s: Signer,
    packed_data: []const u8,
    nonce: u64,
    chain: Chain,
    expires_after: ?u64,
) signer.SignError!Signature {
    return signRmpAction(s, packed_data, nonce, chain, null, expires_after);
}

/// Sign a CSignerAction (RMP path). Generic — takes pre-packed msgpack.
pub fn signCSignerAction(
    s: Signer,
    packed_data: []const u8,
    nonce: u64,
    chain: Chain,
    expires_after: ?u64,
) signer.SignError!Signature {
    return signRmpAction(s, packed_data, nonce, chain, null, expires_after);
}

/// Sign a CValidatorAction (RMP path). Generic — takes pre-packed msgpack.
pub fn signCValidatorAction(
    s: Signer,
    packed_data: []const u8,
    nonce: u64,
    chain: Chain,
    expires_after: ?u64,
) signer.SignError!Signature {
    return signRmpAction(s, packed_data, nonce, chain, null, expires_after);
}

/// Sign an AgentEnableDexAbstraction action (RMP path).
pub fn signAgentEnableDexAbstraction(
    s: Signer,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [256]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try p.packMapHeader(1);
    try p.packStr("type");
    try p.packStr("agentEnableDexAbstraction");
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

/// Sign an AgentSetAbstraction action (RMP path).
pub fn signAgentSetAbstraction(
    s: Signer,
    abstraction_json: []const u8,
    nonce: u64,
    chain: Chain,
    vault_address: ?Address,
    expires_after: ?u64,
) SignError!Signature {
    var buf: [1024]u8 = undefined;
    var p = msgpack.Packer.init(&buf);
    try p.packMapHeader(2);
    try p.packStr("type");
    try p.packStr("agentSetAbstraction");
    try p.packStr("abstraction");
    try p.packStr(abstraction_json);
    return signRmpAction(s, p.written(), nonce, chain, vault_address, expires_after);
}

const Decimal = @import("../lib/math/decimal.zig").Decimal;

test "rmpHashOrder: matches Rust Action::Order rmp_hash" {
    // From rust_vectors.json: action_order_rmp_hash (hash of Action with serde tag)
    const expected_hex = "4672e469ee19cfaf5914abfba4415d4d31eb1823ff61e88ffb7f1ce050bdb7fa";
    var expected: Hash = undefined;
    for (0..32) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const order = types.OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    const hash = try rmpHashOrder(batch, 1234567890, null, null);
    try std.testing.expectEqualSlices(u8, &expected, &hash);
}

test "signOrder: produces recoverable signature" {
    const s = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");

    const order = types.OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    const sig = try signOrder(s, batch, 1234567890, .mainnet, null, null);

    // Verify we can recover the signer
    const connection_id = try rmpHashOrder(batch, 1234567890, null, null);
    const struct_hash = eip712.hashAgent("a", connection_id);
    const signing_hash = eip712.signingHash(eip712.CORE_DOMAIN_SEPARATOR, struct_hash);
    const recovered = try Signer.recoverAddress(sig, signing_hash);
    try std.testing.expectEqualSlices(u8, &s.address, &recovered);
}

test "signOrder: matches Rust SDK signature" {
    // From rust_vectors.json: order_signature
    const expected_hex = "c74b8cbd4796e0f673c1133a892ba45707cf44b2389064e61b4ad7ffb55c17c95e3585f523c4684c30322f516be65b668c67426fcd84b8aefa0244ca4345b4e61b";
    var expected: [65]u8 = undefined;
    for (0..65) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const s = try Signer.fromHex("e908f86dbb4d55ac876378565aafeabc187f6690f046459397b17d9b9a19688e");

    const order = types.OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    const batch = types.BatchOrder{
        .orders = &[_]types.OrderRequest{order},
        .grouping = .na,
    };

    const sig = try signOrder(s, batch, 1234567890, .mainnet, null, null);
    const sig_bytes = sig.toEthBytes();

    try std.testing.expectEqualSlices(u8, &expected, &sig_bytes);
}
