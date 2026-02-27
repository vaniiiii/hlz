//! HTTP client for Hyperliquid API (info + exchange endpoints).

const std = @import("std");
const json_mod = @import("json.zig");
const signing = @import("signing.zig");
const types = @import("types.zig");
const resp_types = @import("response.zig");
const signer_mod = @import("../lib/crypto/signer.zig");
const eip712 = @import("../lib/crypto/eip712.zig");
const Decimal = @import("../lib/math/decimal.zig").Decimal;

const Signer = signer_mod.Signer;
const Address = signer_mod.Address;
const Signature = signer_mod.Signature;
const Chain = signing.Chain;

pub const MAINNET_URL = "https://api.hyperliquid.xyz";
pub const TESTNET_URL = "https://api.hyperliquid-testnet.xyz";

pub const ClientError = error{
    HttpRequestFailed,
    JsonParseFailed,
    ApiError,
    BufferOverflow,
    InvalidResponse,
} || std.http.Client.RequestError || std.http.Client.Request.ReadError || std.mem.Allocator.Error || signing.SignError;

/// HTTP client for the Hyperliquid API.
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    base_url: []const u8,
    chain: Chain,

    /// Create a mainnet client.
    pub fn mainnet(allocator: std.mem.Allocator) Client {
        return init(allocator, .mainnet, MAINNET_URL);
    }

    /// Create a testnet client.
    pub fn testnet(allocator: std.mem.Allocator) Client {
        return init(allocator, .testnet, TESTNET_URL);
    }

    /// Create a client with a custom URL.
    pub fn withUrl(allocator: std.mem.Allocator, chain: Chain, base_url: []const u8) Client {
        return init(allocator, chain, base_url);
    }

    fn init(allocator: std.mem.Allocator, chain: Chain, base_url: []const u8) Client {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .base_url = base_url,
            .chain = chain,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    // ── Info Endpoints ────────────────────────────────────────────

    /// Fetch mid prices for all markets.
    /// Returns parsed JSON. Caller must deinit.
    pub fn allMids(self: *Client, dex_name: ?[]const u8) !InfoResult {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf,
                \\{{"type":"allMids","dex":"{s}"}}
            , .{d}) catch return error.Overflow;
            return self.infoRequestDyn(body);
        }
        return self.infoRequest(
            \\{"type":"allMids"}
        );
    }

    /// Fetch open orders for a user.
    pub fn openOrders(self: *Client, user: []const u8, dex_name: ?[]const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "frontendOpenOrders", user, dex_name);
        return self.infoRequestDyn(body);
    }

    /// Fetch user fills.
    pub fn userFills(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userFills", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch clearinghouse state.
    pub fn clearinghouseState(self: *Client, user: []const u8, dex_name: ?[]const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "clearinghouseState", user, dex_name);
        return self.infoRequestDyn(body);
    }

    /// Fetch spot balances.
    pub fn spotBalances(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "spotClearinghouseState", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch candle snapshot.
    pub fn candleSnapshot(
        self: *Client,
        coin: []const u8,
        interval: []const u8,
        start_time: u64,
        end_time: u64,
    ) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"candleSnapshot","req":{{"coin":"{s}","interval":"{s}","startTime":{d},"endTime":{d}}}}}
        , .{ coin, interval, start_time, end_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch historical orders.
    /// Fetch user funding payments.
    pub fn userFunding(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    pub fn historicalOrders(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "historicalOrders", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch funding history.
    pub fn fundingHistory(
        self: *Client,
        coin: []const u8,
        start_time: u64,
        end_time: ?u64,
    ) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d},"endTime":{d}}}
            , .{ coin, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d}}}
            , .{ coin, start_time }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch order status.
    pub fn orderStatus(self: *Client, user: []const u8, oid: u64) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"orderStatus","user":"{s}","oid":{d}}}
        , .{ user, oid }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user role.
    pub fn userRole(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userRole", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch subaccounts.
    pub fn subaccounts(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "subAccounts", user);
        return self.infoRequestDyn(body);
    }

    // ── Exchange Endpoints ────────────────────────────────────────

    /// Place a batch of orders.
    pub fn place(
        self: *Client,
        s: Signer,
        batch: types.BatchOrder,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signOrder(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchange("order", batch, sig, nonce, vault_address, expires_after);
    }

    /// Cancel a batch of orders.
    pub fn cancel(
        self: *Client,
        s: Signer,
        batch: types.BatchCancel,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signCancel(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchange("cancel", batch, sig, nonce, vault_address, expires_after);
    }

    /// Cancel a batch of orders by cloid.
    pub fn cancelByCloid(
        self: *Client,
        s: Signer,
        batch: types.BatchCancelCloid,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signCancelByCloid(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRaw(sig, nonce, batch, .cancelByCloid);
    }

    /// Modify a batch of orders.
    pub fn modify(
        self: *Client,
        s: Signer,
        batch: types.BatchModify,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signModify(s, batch, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRaw(sig, nonce, batch, .batchModify);
    }

    /// Schedule cancellation of all orders.
    pub fn scheduleCancel(
        self: *Client,
        s: Signer,
        sc: types.ScheduleCancel,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signScheduleCancel(s, sc, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRaw(sig, nonce, sc, .scheduleCancel);
    }

    /// Update isolated margin.
    pub fn updateIsolatedMargin(
        self: *Client,
        s: Signer,
        uim: types.UpdateIsolatedMargin,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signUpdateIsolatedMargin(s, uim, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRaw(sig, nonce, uim, .updateIsolatedMargin);
    }

    /// Update leverage for an asset.
    pub fn updateLeverage(
        self: *Client,
        s: Signer,
        ul: types.UpdateLeverage,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signUpdateLeverage(s, ul, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRaw(sig, nonce, ul, .updateLeverage);
    }

    /// Set referrer code.
    pub fn setReferrer(
        self: *Client,
        s: Signer,
        sr: types.SetReferrer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signSetReferrer(s, sr, nonce, self.chain, vault_address, expires_after);
        return self.sendExchangeRaw(sig, nonce, sr, .setReferrer);
    }

    /// Toggle big blocks.
    pub fn evmUserModify(
        self: *Client,
        s: Signer,
        using_big_blocks: bool,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signEvmUserModify(s, using_big_blocks, nonce, self.chain, vault_address, expires_after);
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"evmUserModify","usingBigBlocks":{s}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            if (using_big_blocks) "true" else "false",
            nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Invalidate a nonce (noop).
    pub fn noop(
        self: *Client,
        s: Signer,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        const sig = try signing.signNoop(s, nonce, self.chain, vault_address, expires_after);
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"noop"}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            nonce,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Send USDC to another address.
    pub fn sendUsdc(
        self: *Client,
        s: Signer,
        destination: []const u8,
        amount: []const u8,
        time: u64,
    ) !ExchangeResult {
        const sig = try eip712.signUsdSend(s, self.chain.isMainnet(), destination, amount, time);
        const chain_str = self.chain.name();

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"usdSend","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","amount":"{s}","time":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{
            self.chain.sigChainId(),
            chain_str,
            destination,
            amount,
            time,
            time,
            sigJsonSlice(&sigJsonStr(sig)),
        }) catch return error.BufferOverflow;

        return self.exchangeRequestDyn(body);
    }

    /// Spot send (spot → spot transfer).
    pub fn spotSend(
        self: *Client,
        s: Signer,
        destination: []const u8,
        token: []const u8,
        amount: []const u8,
        time: u64,
    ) !ExchangeResult {
        const sig = try signing.signSpotSend(s, self.chain, destination, token, amount, time);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();

        var body_buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"spotSend","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","token":"{s}","amount":"{s}","time":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ sig_chain_id, chain_str, destination, token, amount, time, time, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Send asset (perp ↔ spot, or cross-dex).
    pub fn sendAsset(
        self: *Client,
        s: Signer,
        destination: []const u8,
        source_dex: []const u8,
        destination_dex: []const u8,
        token: []const u8,
        amount: []const u8,
        from_sub_account: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signSendAsset(s, self.chain, destination, source_dex, destination_dex, token, amount, from_sub_account, nonce);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();

        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"sendAsset","signatureChainId":"{s}","hyperliquidChain":"{s}","destination":"{s}","sourceDex":"{s}","destinationDex":"{s}","token":"{s}","amount":"{s}","fromSubAccount":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ sig_chain_id, chain_str, destination, source_dex, destination_dex, token, amount, from_sub_account, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Approve an agent wallet.
    pub fn approveAgent(
        self: *Client,
        s: Signer,
        agent_address: []const u8,
        agent_name: ?[]const u8,
        nonce: u64,
    ) !ExchangeResult {
        const name = agent_name orelse "";
        const sig = try signing.signApproveAgent(s, self.chain, agent_address, name, nonce);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();

        var body_buf: [1024]u8 = undefined;
        const body = if (agent_name != null)
            std.fmt.bufPrint(&body_buf,
                \\{{"action":{{"type":"approveAgent","signatureChainId":"{s}","hyperliquidChain":"{s}","agentAddress":"{s}","agentName":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
            , .{ sig_chain_id, chain_str, agent_address, name, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&body_buf,
                \\{{"action":{{"type":"approveAgent","signatureChainId":"{s}","hyperliquidChain":"{s}","agentAddress":"{s}","agentName":null,"nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
            , .{ sig_chain_id, chain_str, agent_address, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    /// Convert account to multi-sig.
    pub fn convertToMultisig(
        self: *Client,
        s: Signer,
        signers_json: []const u8,
        nonce: u64,
    ) !ExchangeResult {
        const sig = try signing.signConvertToMultiSig(s, self.chain, signers_json, nonce);
        const chain_str = self.chain.name();
        const sig_chain_id = self.chain.sigChainId();

        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"action":{{"type":"convertToMultiSigUser","signatureChainId":"{s}","hyperliquidChain":"{s}","signers":"{s}","nonce":{d}}},"nonce":{d},"signature":{s},"vaultAddress":null,"expiresAfter":null}}
        , .{ sig_chain_id, chain_str, signers_json, nonce, nonce, sigJsonSlice(&sigJsonStr(sig)) }) catch return error.BufferOverflow;
        return self.exchangeRequestDyn(body);
    }

    // ── Additional Info Endpoints ─────────────────────────────────

    /// Fetch perpetual markets metadata.
    pub fn perps(self: *Client, dex_name: ?[]const u8) !InfoResult {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf,
                \\{{"type":"meta","dex":"{s}"}}
            , .{d}) catch return error.BufferOverflow;
            return self.infoRequestDyn(body);
        }
        return self.infoRequest(
            \\{"type":"meta"}
        );
    }

    /// Fetch spot markets metadata.
    pub fn spot(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"spotMeta"}
        );
    }

    /// Fetch available perpetual DEXes.
    pub fn perpDexs(self: *Client) !InfoResult {
        return self.infoRequest(
            \\{"type":"perpDexs"}
        );
    }

    /// Fetch multi-sig config for a user.
    pub fn multiSigConfig(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userToMultiSigSigners", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch API agents for a user.
    pub fn apiAgents(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "extraAgents", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch vault details.
    pub fn vaultDetails(self: *Client, vault_address: []const u8, user: ?[]const u8) !InfoResult {
        var buf: [512]u8 = undefined;
        const body = if (user) |u|
            std.fmt.bufPrint(&buf,
                \\{{"type":"vaultDetails","vaultAddress":"{s}","user":"{s}"}}
            , .{ vault_address, u }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"vaultDetails","vaultAddress":"{s}"}}
            , .{vault_address}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user vault equities.
    pub fn userVaultEquities(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userVaultEquities", user);
        return self.infoRequestDyn(body);
    }

    /// Fetch L2 order book snapshot for a coin.
    pub fn l2Book(self: *Client, coin: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"l2Book\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch recent trades for a coin.
    pub fn recentTrades(self: *Client, coin: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"recentTrades\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch user's active asset data (leverage, available-to-trade).
    pub fn activeAssetData(self: *Client, user: []const u8, coin: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"activeAssetData","user":"{s}","coin":"{s}"}}
        , .{ user, coin }) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch referral status for a user.
    pub fn referral(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"referral","user":"{s}"}}
        , .{user}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch spot clearinghouse state for a user.
    pub fn spotClearinghouseState(self: *Client, user: []const u8) !InfoResult {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"spotClearinghouseState","user":"{s}"}}
        , .{user}) catch return error.BufferOverflow;
        return self.infoRequestDyn(body);
    }

    /// Fetch perp meta + asset contexts (funding, OI, mark prices).
    pub fn metaAndAssetCtxs(self: *Client) !InfoResult {
        return self.infoRequestDyn("{\"type\":\"metaAndAssetCtxs\"}");
    }

    /// Send a pre-built ActionRequest (for advanced use / multi-sig).
    pub fn sendRaw(self: *Client, body: []const u8) !ExchangeResult {
        return self.exchangeRequestDyn(body);
    }

    // ── Typed Info Endpoints ──────────────────────────────────────

    const R = resp_types;
    const Parsed = std.json.Parsed;

    pub fn getClearinghouseState(self: *Client, user: []const u8, dex_name: ?[]const u8) !Parsed(R.ClearinghouseState) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "clearinghouseState", user, dex_name);
        return self.infoTyped(R.ClearinghouseState, body);
    }

    pub fn getSpotBalances(self: *Client, user: []const u8) !Parsed(R.SpotClearinghouseState) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "spotClearinghouseState", user);
        return self.infoTyped(R.SpotClearinghouseState, body);
    }

    pub fn getOpenOrders(self: *Client, user: []const u8, dex_name: ?[]const u8) !Parsed([]R.BasicOrder) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBody(&buf, "frontendOpenOrders", user, dex_name);
        return self.infoTyped([]R.BasicOrder, body);
    }

    pub fn getUserFills(self: *Client, user: []const u8) !Parsed([]R.Fill) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userFills", user);
        return self.infoTyped([]R.Fill, body);
    }

    pub fn getHistoricalOrders(self: *Client, user: []const u8) !Parsed([]R.HistoricalOrder) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "historicalOrders", user);
        return self.infoTyped([]R.HistoricalOrder, body);
    }

    pub fn getUserFunding(self: *Client, user: []const u8, start_time: u64, end_time: ?u64) !Parsed([]R.UserFunding) {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d},"endTime":{d}}}
            , .{ user, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"userFunding","user":"{s}","startTime":{d}}}
            , .{ user, start_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.UserFunding, body);
    }

    pub fn getFundingHistory(self: *Client, coin: []const u8, start_time: u64, end_time: ?u64) !Parsed([]R.FundingRate) {
        var buf: [512]u8 = undefined;
        const body = if (end_time) |et|
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d},"endTime":{d}}}
            , .{ coin, start_time, et }) catch return error.BufferOverflow
        else
            std.fmt.bufPrint(&buf,
                \\{{"type":"fundingHistory","coin":"{s}","startTime":{d}}}
            , .{ coin, start_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.FundingRate, body);
    }

    pub fn getCandleSnapshot(self: *Client, coin: []const u8, interval: []const u8, start_time: u64, end_time: u64) !Parsed([]R.Candle) {
        var buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"candleSnapshot","req":{{"coin":"{s}","interval":"{s}","startTime":{d},"endTime":{d}}}}}
        , .{ coin, interval, start_time, end_time }) catch return error.BufferOverflow;
        return self.infoTyped([]R.Candle, body);
    }

    pub fn getUserRole(self: *Client, user: []const u8) !Parsed(R.UserRole) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "userRole", user);
        return self.infoTyped(R.UserRole, body);
    }

    pub fn getApiAgents(self: *Client, user: []const u8) !Parsed([]R.ApiAgent) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "extraAgents", user);
        return self.infoTyped([]R.ApiAgent, body);
    }

    pub fn getSubaccounts(self: *Client, user: []const u8) !Parsed([]R.SubAccount) {
        var buf: [256]u8 = undefined;
        const body = try formatInfoBodySimple(&buf, "subAccounts", user);
        return self.infoTyped([]R.SubAccount, body);
    }

    pub fn getDexInfos(self: *Client) !Parsed([]R.DexInfo) {
        return self.infoTyped([]R.DexInfo, "{\"type\":\"perpDexs\"}");
    }

    pub fn getPerpDexs(self: *Client) !Parsed([]R.Dex) {
        return self.infoTyped([]R.Dex,
            \\{"type":"perpDexs"}
        );
    }

    pub fn getPerps(self: *Client, dex_name: ?[]const u8) !Parsed(R.PerpUniverse) {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf,
                \\{{"type":"meta","dex":"{s}"}}
            , .{d}) catch return error.BufferOverflow;
            return self.infoTyped(R.PerpUniverse, body);
        }
        return self.infoTyped(R.PerpUniverse,
            \\{"type":"meta"}
        );
    }

    pub fn getSpotMeta(self: *Client) !Parsed(R.SpotMeta) {
        return self.infoTyped(R.SpotMeta,
            \\{"type":"spotMeta"}
        );
    }

    pub fn getTokenDetails(self: *Client, token_id: []const u8) !Parsed(R.TokenDetails) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"tokenDetails\",\"tokenId\":\"{s}\"}}", .{token_id}) catch return error.Overflow;
        return self.infoTyped(R.TokenDetails, body);
    }

    pub fn getRecentTrades(self: *Client, coin: []const u8) !Parsed([]R.Trade) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"recentTrades\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoTyped([]R.Trade, body);
    }

    /// Parse metaAndAssetCtxs — heterogeneous [meta, [ctx, ...]] tuple.
    /// Returns a slice of MetaAndAssetCtx pairing each PerpMeta with its AssetContext.
    pub fn getMetaAndAssetCtxs(self: *Client, dex_name: ?[]const u8) !MetaAndAssetCtxsResult {
        var raw = if (dex_name) |d| blk: {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"type\":\"metaAndAssetCtxs\",\"dexName\":\"{s}\"}}", .{d}) catch return error.Overflow;
            break :blk try self.infoRequest(body);
        } else try self.metaAndAssetCtxs();
        defer raw.deinit();
        const val = try raw.json();
        if (val != .array or val.array.items.len < 2) return error.Overflow;
        const meta_val = val.array.items[0];
        const ctxs_val = val.array.items[1];
        const universe_arr = if (meta_val == .object)
            if (meta_val.object.get("universe")) |u| (if (u == .array) u.array.items else null) else null
        else
            null;
        const ctx_arr = if (ctxs_val == .array) ctxs_val.array.items else null;
        const u_arr = universe_arr orelse return error.Overflow;
        const c_arr = ctx_arr orelse return error.Overflow;
        const n = @min(u_arr.len, c_arr.len);
        var entries = try self.allocator.alloc(R.MetaAndAssetCtx, n);
        var count: usize = 0;
        for (0..n) |i| {
            const meta = std.json.parseFromValue(R.PerpMeta, self.allocator, u_arr[i], R.ParseOpts) catch continue;
            const ctx = std.json.parseFromValue(R.AssetContext, self.allocator, c_arr[i], R.ParseOpts) catch {
                meta.deinit();
                continue;
            };
            entries[count] = .{ .meta = meta.value, .ctx = ctx.value };
            count += 1;
        }
        return .{ .entries = entries[0..count], .alloc_len = n, .allocator = self.allocator };
    }

    pub const MetaAndAssetCtxsResult = struct {
        entries: []R.MetaAndAssetCtx,
        alloc_len: usize,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *MetaAndAssetCtxsResult) void {
            self.allocator.free(self.entries.ptr[0..self.alloc_len]);
        }
    };

    pub fn getL2Book(self: *Client, coin: []const u8) !Parsed(R.L2Book) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"l2Book\",\"coin\":\"{s}\"}}", .{coin}) catch return error.Overflow;
        return self.infoTyped(R.L2Book, body);
    }

    pub fn getAllMids(self: *Client, dex_name: ?[]const u8) !Parsed(std.json.Value) {
        if (dex_name) |d| {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"type\":\"allMids\",\"dexName\":\"{s}\"}}", .{d}) catch return error.Overflow;
            return self.infoTyped(std.json.Value, body);
        }
        return self.infoTyped(std.json.Value, "{\"type\":\"allMids\"}");
    }

    pub fn getReferral(self: *Client, user: []const u8) !Parsed(R.Referral) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"type\":\"referral\",\"user\":\"{s}\"}}", .{user}) catch return error.Overflow;
        return self.infoTyped(R.Referral, body);
    }

    pub fn getActiveAssetData(self: *Client, user: []const u8, coin: []const u8) !Parsed(R.ActiveAssetData) {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"type":"activeAssetData","user":"{s}","coin":"{s}"}}
        , .{ user, coin }) catch return error.BufferOverflow;
        return self.infoTyped(R.ActiveAssetData, body);
    }

    // ── Internal HTTP helpers ─────────────────────────────────────

    pub const InfoResult = struct {
        allocator: std.mem.Allocator,
        body: []u8,
        parsed: ?std.json.Parsed(std.json.Value),
        status: std.http.Status,

        pub fn json(self: *InfoResult) !std.json.Value {
            if (self.parsed == null) {
                self.parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    self.body,
                    .{ .allocate = .alloc_always },
                );
            }
            return self.parsed.?.value;
        }

        pub fn deinit(self: *InfoResult) void {
            if (self.parsed) |*p| p.deinit();
            self.allocator.free(self.body);
        }
    };

    pub const ExchangeResult = struct {
        allocator: std.mem.Allocator,
        body: []u8,
        parsed: ?std.json.Parsed(std.json.Value),
        status: std.http.Status,

        pub fn json(self: *ExchangeResult) !std.json.Value {
            if (self.parsed == null) {
                self.parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    self.body,
                    .{ .allocate = .alloc_always },
                );
            }
            return self.parsed.?.value;
        }

        pub fn isOk(self: *ExchangeResult) !bool {
            const val = try self.json();
            const status_str = json_mod.getString(val, "status") orelse return false;
            return std.mem.eql(u8, status_str, "ok");
        }



        pub fn deinit(self: *ExchangeResult) void {
            if (self.parsed) |*p| p.deinit();
            self.allocator.free(self.body);
        }
    };

    /// Typed info request: HTTP POST → parse JSON → typed struct.
    /// Uses std.json.parseFromSlice with ignore_unknown_fields.
    fn infoTyped(self: *Client, comptime T: type, body: []const u8) !std.json.Parsed(T) {
        var raw = try self.infoRequestDyn(body);
        defer raw.deinit();
        return std.json.parseFromSlice(T, self.allocator, raw.body, resp_types.ParseOpts) catch
            return error.JsonParseFailed;
    }

    fn infoRequest(self: *Client, body: []const u8) !InfoResult {
        return self.infoRequestDyn(body);
    }

    fn infoRequestDyn(self: *Client, body: []const u8) !InfoResult {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/info", .{self.base_url}) catch return error.BufferOverflow;

        const response_body = try self.doPost(url, body);
        errdefer self.allocator.free(response_body.body);
        return InfoResult{
            .allocator = self.allocator,
            .body = response_body.body,
            .parsed = null,
            .status = response_body.status,
        };
    }

    fn exchangeRequestDyn(self: *Client, body: []const u8) !ExchangeResult {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/exchange", .{self.base_url}) catch return error.BufferOverflow;

        const response_body = try self.doPost(url, body);
        errdefer self.allocator.free(response_body.body);
        return ExchangeResult{
            .allocator = self.allocator,
            .body = response_body.body,
            .parsed = null,
            .status = response_body.status,
        };
    }

    fn sendExchange(
        self: *Client,
        action_type: []const u8,
        action_data: anytype,
        sig: Signature,
        nonce: u64,
        vault_address: ?Address,
        expires_after: ?u64,
    ) !ExchangeResult {
        _ = action_type;
        _ = vault_address;
        _ = expires_after;

        var body_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"action\":");
        try writeActionJson(writer, action_data);
        const sig_json_1 = sigJsonStr(sig);
        try std.fmt.format(writer, ",\"nonce\":{d},\"signature\":{s},\"vaultAddress\":null,\"expiresAfter\":null", .{
            nonce,
            sigJsonSlice(&sig_json_1),
        });
        try writer.writeAll("}");
        return self.exchangeRequestDyn(fbs.getWritten());
    }

    /// Generic exchange endpoint for RMP-path actions that need JSON serialization.
    fn sendExchangeRaw(
        self: *Client,
        sig: Signature,
        nonce: u64,
        action_data: anytype,
        tag: types.ActionTag,
    ) !ExchangeResult {
        var body_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"action\":");
        try writeActionJsonTagged(writer, action_data, tag);
        const sig_json = sigJsonStr(sig);
        try std.fmt.format(writer, ",\"nonce\":{d},\"signature\":{s},\"vaultAddress\":null,\"expiresAfter\":null", .{
            nonce,
            sigJsonSlice(&sig_json),
        });
        try writer.writeAll("}");
        return self.exchangeRequestDyn(fbs.getWritten());
    }

    const HttpResponse = struct {
        status: std.http.Status,
        body: []u8,
    };

    fn doPost(self: *Client, url: []const u8, payload: []const u8) !HttpResponse {
        const uri = std.Uri.parse(url) catch return error.HttpRequestFailed;

        var req = try std.http.Client.request(&self.http_client, .POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = try req.sendBody(&.{});
        try body_writer.writer.writeAll(payload);
        try body_writer.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        var reader = response.reader(&.{});
        const body = reader.allocRemaining(self.allocator, @enumFromInt(1024 * 1024)) catch
            return error.HttpRequestFailed;

        return .{
            .status = response.head.status,
            .body = body,
        };
    }
};

fn writeActionJson(writer: anytype, action_data: anytype) !void {
    const T = @TypeOf(action_data);
    if (T == types.BatchOrder) {
        try writer.writeAll("{\"type\":\"order\",\"orders\":[");
        for (action_data.orders, 0..) |order, i| {
            if (i > 0) try writer.writeAll(",");
            try writeOrderJson(writer, order);
        }
        try std.fmt.format(writer, "],\"grouping\":\"{s}\"}}", .{@tagName(action_data.grouping)});
    } else if (T == types.BatchCancel) {
        try writer.writeAll("{\"type\":\"cancel\",\"cancels\":[");
        for (action_data.cancels, 0..) |c, i| {
            if (i > 0) try writer.writeAll(",");
            try std.fmt.format(writer, "{{\"a\":{d},\"o\":{d}}}", .{ c.asset, c.oid });
        }
        try writer.writeAll("]}");
    } else {
        @compileError("unsupported action type for writeActionJson");
    }
}

fn writeActionJsonTagged(writer: anytype, action_data: anytype, tag: types.ActionTag) !void {
    try std.fmt.format(writer, "{{\"type\":\"{s}\"", .{@tagName(tag)});
    const T = @TypeOf(action_data);
    if (T == types.BatchCancelCloid) {
        try writer.writeAll(",\"cancels\":[");
        for (action_data.cancels, 0..) |c, i| {
            if (i > 0) try writer.writeAll(",");
            const hex = types.cloidToHex(c.cloid);
            try std.fmt.format(writer, "{{\"asset\":{d},\"cloid\":\"{s}\"}}", .{ c.asset, @as([]const u8, &hex) });
        }
        try writer.writeAll("]}");
    } else if (T == types.BatchModify) {
        try writer.writeAll(",\"modifies\":[");
        for (action_data.modifies, 0..) |m, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"oid\":");
            switch (m.oid) {
                .oid => |oid| try std.fmt.format(writer, "{d}", .{oid}),
                .cloid => |cloid| {
                    const hex = types.cloidToHex(cloid);
                    try std.fmt.format(writer, "\"{s}\"", .{@as([]const u8, &hex)});
                },
            }
            try writer.writeAll(",\"order\":");
            try writeOrderJson(writer, m.order);
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
    } else if (T == types.ScheduleCancel) {
        if (action_data.time) |t| {
            try std.fmt.format(writer, ",\"time\":{d}}}", .{t});
        } else {
            try writer.writeAll(",\"time\":null}");
        }
    } else if (T == types.UpdateIsolatedMargin) {
        try std.fmt.format(writer, ",\"asset\":{d},\"isBuy\":{s},\"ntli\":{d}}}", .{
            action_data.asset,
            if (action_data.is_buy) "true" else "false",
            action_data.ntli,
        });
    } else if (T == types.UpdateLeverage) {
        try std.fmt.format(writer, ",\"asset\":{d},\"isCross\":{s},\"leverage\":{d}}}", .{
            action_data.asset,
            if (action_data.is_cross) "true" else "false",
            action_data.leverage,
        });
    } else if (T == types.SetReferrer) {
        try std.fmt.format(writer, ",\"code\":\"{s}\"}}", .{action_data.code});
    } else {
        try writer.writeAll("}");
    }
}

fn writeOrderJson(writer: anytype, order: types.OrderRequest) !void {
    var px_buf: [64]u8 = undefined;
    const px_str = order.limit_px.normalize().toString(&px_buf) catch return error.BufferOverflow;
    var sz_buf: [64]u8 = undefined;
    const sz_str = order.sz.normalize().toString(&sz_buf) catch return error.BufferOverflow;
    const cloid_hex = types.cloidToHex(order.cloid);

    try std.fmt.format(writer, "{{\"a\":{d},\"b\":{},\"p\":\"{s}\",\"s\":\"{s}\",\"r\":{}", .{
        order.asset,
        order.is_buy,
        px_str,
        sz_str,
        order.reduce_only,
    });

    // Order type
    switch (order.order_type) {
        .limit => |lim| {
            try std.fmt.format(writer, ",\"t\":{{\"limit\":{{\"tif\":\"{s}\"}}}}", .{@tagName(lim.tif)});
        },
        .trigger => |trig| {
            var tpx_buf: [64]u8 = undefined;
            const tpx_str = trig.trigger_px.normalize().toString(&tpx_buf) catch return error.BufferOverflow;
            try std.fmt.format(writer, ",\"t\":{{\"trigger\":{{\"isMarket\":{},\"triggerPx\":\"{s}\",\"tpsl\":\"{s}\"}}}}", .{
                trig.is_market,
                tpx_str,
                @tagName(trig.tpsl),
            });
        },
    }

    try std.fmt.format(writer, ",\"c\":\"{s}\"}}", .{@as([]const u8, &cloid_hex)});
}

fn hexByte(buf: *[2]u8, byte: u8) void {
    const charset = "0123456789abcdef";
    buf[0] = charset[byte >> 4];
    buf[1] = charset[byte & 0x0f];
}

fn sigToHex(sig_bytes: [65]u8) [132]u8 {
    var hex: [132]u8 = undefined;
    hex[0] = '0';
    hex[1] = 'x';
    for (sig_bytes, 0..) |byte, i| hexByte(hex[2 + i * 2 ..][0..2], byte);
    return hex;
}

/// Format signature as JSON: {"r":"0x...64hex...","s":"0x...64hex...","v":27}
fn sigJsonStr(sig: Signature) [163]u8 {
    const bytes = sig.toEthBytes();
    var buf: [163]u8 = undefined;
    var pos: usize = 0;

    // r field
    const r_prefix = "{\"r\":\"0x";
    @memcpy(buf[pos..][0..r_prefix.len], r_prefix);
    pos += r_prefix.len;
    for (bytes[0..32]) |b| {
        hexByte(buf[pos..][0..2], b);
        pos += 2;
    }

    // s field
    const s_prefix = "\",\"s\":\"0x";
    @memcpy(buf[pos..][0..s_prefix.len], s_prefix);
    pos += s_prefix.len;
    for (bytes[32..64]) |b| {
        hexByte(buf[pos..][0..2], b);
        pos += 2;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "\",\"v\":{d}}}", .{bytes[64]}) catch unreachable;
    pos += suffix.len;
    @memset(buf[pos..], 0);
    return buf;
}

fn sigJsonSlice(buf: *const [163]u8) []const u8 {
    // Find the end (after the closing brace)
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return buf;
}

fn formatInfoBody(buf: []u8, req_type: []const u8, user: []const u8, dex_name: ?[]const u8) ![]const u8 {
    if (dex_name) |d| {
        return std.fmt.bufPrint(buf,
            \\{{"type":"{s}","user":"{s}","dex":"{s}"}}
        , .{ req_type, user, d }) catch return error.BufferOverflow;
    }
    return formatInfoBodySimple(buf, req_type, user);
}

fn formatInfoBodySimple(buf: []u8, req_type: []const u8, user: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"type":"{s}","user":"{s}"}}
    , .{ req_type, user }) catch return error.BufferOverflow;
}

test "sigToHex" {
    var sig_bytes: [65]u8 = [_]u8{0} ** 65;
    sig_bytes[0] = 0xab;
    sig_bytes[64] = 0x1c;
    const hex = sigToHex(sig_bytes);
    try std.testing.expect(std.mem.startsWith(u8, &hex, "0xab"));
    try std.testing.expect(std.mem.endsWith(u8, &hex, "1c"));
}

test "formatInfoBody: simple" {
    var buf: [256]u8 = undefined;
    const body = try formatInfoBodySimple(&buf, "userFills", "0xabc123");
    try std.testing.expectEqualStrings(
        \\{"type":"userFills","user":"0xabc123"}
    , body);
}

test "formatInfoBody: with dex" {
    var buf: [256]u8 = undefined;
    const body = try formatInfoBody(&buf, "clearinghouseState", "0xabc123", "myDex");
    try std.testing.expectEqualStrings(
        \\{"type":"clearinghouseState","user":"0xabc123","dex":"myDex"}
    , body);
}

test "writeOrderJson" {
    const order = types.OrderRequest{
        .asset = 0,
        .is_buy = true,
        .limit_px = Decimal.fromString("50000") catch unreachable,
        .sz = Decimal.fromString("0.1") catch unreachable,
        .reduce_only = false,
        .order_type = .{ .limit = .{ .tif = .Gtc } },
        .cloid = types.ZERO_CLOID,
    };

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeOrderJson(fbs.writer(), order);
    const json = fbs.getWritten();

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"b\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"p\":\"50000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"s\":\"0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tif\":\"Gtc\"") != null);
}
