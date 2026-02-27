const std = @import("std");
const builtin = @import("builtin");
const hyperzig = @import("hyperzig");
const client_mod = hyperzig.hypercore.client;
const ws_types = hyperzig.hypercore.ws;
const signing = hyperzig.hypercore.signing;
const response = hyperzig.hypercore.response;
const resp_types = response;
const Decimal = hyperzig.math.decimal.Decimal;
const signer_mod = hyperzig.crypto.signer;
const App = @import("App");
const BufMod = @import("Buffer");
const Chart = @import("Chart");

const Client = client_mod.Client;
const Signer = signer_mod.Signer;
const Chain = signing.Chain;

/// Minimal config interface — avoids importing cli/config.zig
pub const Config = struct {
    chain: Chain = .mainnet,
    key_hex: ?[]const u8 = null,
    address: ?[]const u8 = null,
    derived_addr_buf: [42]u8 = undefined,

    pub fn getSigner(self: Config) !Signer { return Signer.fromHex(self.key_hex orelse return error.MissingKey); }
    pub fn getAddress(self: *Config) ?[]const u8 {
        if (self.address) |a| return a;
        if (self.key_hex) |hex| {
            const signer = Signer.fromHex(hex) catch return null;
            const addr = signer.address;
            self.derived_addr_buf[0] = '0';
            self.derived_addr_buf[1] = 'x';
            const chars = "0123456789abcdef";
            for (addr, 0..) |b, i| {
                self.derived_addr_buf[2 + i * 2] = chars[b >> 4];
                self.derived_addr_buf[2 + i * 2 + 1] = chars[b & 0xf];
            }
            self.address = &self.derived_addr_buf;
            return &self.derived_addr_buf;
        }
        return null;
    }
};
const Buffer = BufMod;
const Style = Buffer.Style;
const Rect = Buffer.Rect;

// ╔══════════════════════════════════════════════════════════════════╗
// ║  1. PALETTE & STYLES                                            ║
// ╚══════════════════════════════════════════════════════════════════╝

const C = Buffer.Color;
const hl_bg = C.hex(0x0f1a1f);
const hl_panel = C.hex(0x1b2429);
const hl_border = C.hex(0x273035);
const hl_buy = C.hex(0x1fa67d);
const hl_accent = C.hex(0x50d2c1);
const hl_sell = C.hex(0xed7088);
const hl_text = C.hex(0xffffff);
const hl_text2 = C.hex(0xd2dad7);
const hl_muted = C.hex(0x949e9c);
const hl_buy_bg = C.hex(0x1e5d52);
const hl_sell_bg = C.hex(0x732a36);

const s_green = Style{ .fg = hl_buy };
const s_red = Style{ .fg = hl_sell };
const s_bold_green = Style{ .fg = hl_buy, .bold = true };
const s_bold_red = Style{ .fg = hl_sell, .bold = true };
const s_cyan = Style{ .fg = hl_accent, .bold = true };
const s_white = Style{ .fg = hl_text2 };
const s_bold = Style{ .fg = hl_text, .bold = true };
const s_dim = Style{ .fg = hl_muted };

// ╔══════════════════════════════════════════════════════════════════╗
// ║  2. TYPES & STATE                                               ║
// ╚══════════════════════════════════════════════════════════════════╝

const ActiveTab = enum(u3) { positions, open_orders, trade_history, funding_history, order_history };
const FocusPanel = enum(u3) { chart, book, tape, order_entry, bottom };
const OrderSide = enum { buy, sell };
const OrderType = enum { market, limit };
const OrderField = enum { size, price };
const ActionId = enum(u8) { set_leverage, cancel_all, close_selected };
const ActionMode = enum(u2) { list, confirm, number };
const LEVERAGE_MIN: u32 = 1;
const LEVERAGE_MAX: u32 = 125;

const MAX_ROWS = 32;
const MAX_COLS = 8;
const CELL_SZ = 24;
const STATUS_TTL_MS: i64 = 6000;
const PERF_SAMPLE_MS: i64 = 1000;

const TableData = struct {
    cells: [MAX_ROWS][MAX_COLS][CELL_SZ]u8 = undefined,
    lens: [MAX_ROWS][MAX_COLS]u8 = undefined,
    row_colors: [MAX_ROWS]RowColor = .{.neutral} ** MAX_ROWS,
    n_rows: usize = 0,
    n_cols: usize = 0,
    headers: [MAX_COLS][CELL_SZ]u8 = undefined,
    header_lens: [MAX_COLS]u8 = undefined,

    const RowColor = enum { neutral, positive, negative };

    fn set(self: *TableData, row: usize, col: usize, val: []const u8) void {
        if (row >= MAX_ROWS or col >= MAX_COLS) return;
        const n = @min(val.len, CELL_SZ);
        @memcpy(self.cells[row][col][0..n], val[0..n]);
        self.lens[row][col] = @intCast(n);
    }
    fn setHeader(self: *TableData, col: usize, val: []const u8) void {
        if (col >= MAX_COLS) return;
        const n = @min(val.len, CELL_SZ);
        @memcpy(self.headers[col][0..n], val[0..n]);
        self.header_lens[col] = @intCast(n);
    }
    fn get(self: *const TableData, row: usize, col: usize) []const u8 {
        if (row >= MAX_ROWS or col >= MAX_COLS) return "";
        return self.cells[row][col][0..self.lens[row][col]];
    }
    fn getHeader(self: *const TableData, col: usize) []const u8 {
        if (col >= MAX_COLS) return "";
        return self.headers[col][0..self.header_lens[col]];
    }
    fn clear(self: *TableData) void {
        self.n_rows = 0;
        self.n_cols = 0;
        self.row_colors = .{.neutral} ** MAX_ROWS;
    }
};

fn copyTo(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

const InfoData = struct {
    mark_buf: [20]u8 = undefined, mark_len: usize = 0,
    oracle_buf: [20]u8 = undefined, oracle_len: usize = 0,
    change_buf: [32]u8 = undefined, change_len: usize = 0,
    volume_buf: [20]u8 = undefined, volume_len: usize = 0,
    oi_buf: [20]u8 = undefined, oi_len: usize = 0,
    funding_buf: [20]u8 = undefined, funding_len: usize = 0,
    is_negative_change: bool = false,

    fn mark(self: *const InfoData) []const u8 { return if (self.mark_len > 0) self.mark_buf[0..self.mark_len] else "—"; }
    fn oracle(self: *const InfoData) []const u8 { return if (self.oracle_len > 0) self.oracle_buf[0..self.oracle_len] else "—"; }
    fn change_24h(self: *const InfoData) []const u8 { return if (self.change_len > 0) self.change_buf[0..self.change_len] else "—"; }
    fn volume_24h(self: *const InfoData) []const u8 { return if (self.volume_len > 0) self.volume_buf[0..self.volume_len] else "—"; }
    fn open_interest(self: *const InfoData) []const u8 { return if (self.oi_len > 0) self.oi_buf[0..self.oi_len] else "—"; }
    fn funding(self: *const InfoData) []const u8 { return if (self.funding_len > 0) self.funding_buf[0..self.funding_len] else "—"; }
};

const BookLevel = struct {
    px_buf: [16]u8 = undefined, px_len: usize = 0,
    sz: f64 = 0,
    sz_buf: [16]u8 = undefined, sz_len: usize = 0,
    cum: f64 = 0,

    fn px(self: *const BookLevel) []const u8 { return if (self.px_len > 0) self.px_buf[0..self.px_len] else "0"; }
    fn szStr(self: *const BookLevel) []const u8 { return if (self.sz_len > 0) self.sz_buf[0..self.sz_len] else "0"; }
};

const OrderState = struct {
    side: OrderSide = .buy,
    order_type: OrderType = .market,
    field: OrderField = .size,
    size_buf: [16]u8 = .{0} ** 16, size_len: usize = 0,
    price_buf: [16]u8 = .{0} ** 16, price_len: usize = 0,
    status_buf: [48]u8 = undefined, status_len: usize = 0,
    status_is_error: bool = false,
    status_set_ms: i64 = 0,

    fn sizeStr(self: *const OrderState) []const u8 { return self.size_buf[0..self.size_len]; }
    fn priceStr(self: *const OrderState) []const u8 { return self.price_buf[0..self.price_len]; }
    fn statusStr(self: *const OrderState) []const u8 { return self.status_buf[0..self.status_len]; }
    fn setStatus(self: *OrderState, msg: []const u8, err: bool) void {
        const n = @min(msg.len, 48);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_len = n;
        self.status_is_error = err;
        self.status_set_ms = std.time.milliTimestamp();
    }
    fn clearStatus(self: *OrderState) void {
        self.status_len = 0;
        self.status_is_error = false;
        self.status_set_ms = 0;
    }
    fn expireStatus(self: *OrderState, now_ms: i64, ttl_ms: i64) bool {
        if (self.status_len == 0 or self.status_set_ms == 0) return false;
        if (now_ms - self.status_set_ms < ttl_ms) return false;
        self.clearStatus();
        return true;
    }
    fn appendToActive(self: *OrderState, c: u8) void {
        switch (self.field) {
            .size => if (self.size_len < 15) { self.size_buf[self.size_len] = c; self.size_len += 1; },
            .price => if (self.price_len < 15) { self.price_buf[self.price_len] = c; self.price_len += 1; },
        }
    }
    fn backspaceActive(self: *OrderState) void {
        switch (self.field) {
            .size => if (self.size_len > 0) { self.size_len -= 1; },
            .price => if (self.price_len > 0) { self.price_len -= 1; },
        }
    }
};

const LeverageState = struct {
    open: bool = false,
    value: u32 = 20,
    is_cross: bool = true,
    return_to_actions: bool = false,
    max: u32 = LEVERAGE_MAX,

    fn clamp(v: u32, max: u32) u32 {
        return @max(LEVERAGE_MIN, @min(v, @max(LEVERAGE_MIN, max)));
    }

    fn step(self: *LeverageState, delta: i32) void {
        const now: i32 = @intCast(self.value);
        const next: i32 = now + delta;
        if (next <= 0) self.value = LEVERAGE_MIN
        else self.value = clamp(@intCast(next), self.max);
    }
};

const ActionUiState = struct {
    open: bool = false,
    mode: ActionMode = .list,
    selected: usize = 0,
    current: ActionId = .set_leverage,
    number_value: i32 = 20,
    number_min: i32 = 1,
    number_max: i32 = 125,
    number_step: i32 = 1,
    number_step_large: i32 = 5,
    number_is_cross: bool = true,
};

/// UI-only state (never touched by worker threads)
const UiState = struct {
    tab: ActiveTab = .positions,
    focus: FocusPanel = .chart,
    order: OrderState = .{},
    interval: []const u8 = "1m",
    chart_scroll: usize = 0,
    book_depth: usize = 20,
    coin_input: [16]u8 = undefined,
    coin_input_len: usize = 0,
    coin_picking: bool = false,
    coin: [16]u8 = undefined,
    coin_len: usize = 0,
    selected_row: usize = 0,
    scroll_offset: usize = 0,
    leverage: LeverageState = .{},
    actions: ActionUiState = .{},
    show_perf: bool = false,
    rss_kb: u64 = 0,
    peak_rss_kb: u64 = 0,
    perf_last_ms: i64 = 0,
};

/// Shared state (workers write, UI snapshots under lock)
const Shared = struct {
    mu: std.Thread.Mutex = .{},
    gen: u64 = 0,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    ws_fd: std.atomic.Value(std.posix.fd_t) = std.atomic.Value(std.posix.fd_t).init(-1),
    // Market data
    candles: [Chart.MAX_CANDLES]Chart.Candle = undefined,
    candle_count: usize = 0,
    info: InfoData = .{},
    bids: [64]BookLevel = undefined,
    asks: [64]BookLevel = undefined,
    n_bids: usize = 0,
    n_asks: usize = 0,
    max_cum: f64 = 0,
    trades: TableData = .{},
    // User data
    positions: TableData = .{},
    open_orders: TableData = .{},
    trade_history: TableData = .{},
    funding_history: TableData = .{},
    order_history: TableData = .{},
    acct_buf: [24]u8 = undefined,
    acct_len: usize = 0,
    margin_buf: [24]u8 = undefined,
    margin_len: usize = 0,
    avail_buf: [24]u8 = undefined,
    avail_len: usize = 0,
    leverage_buf: [8]u8 = undefined,
    leverage_len: usize = 0,
    leverage_is_cross: bool = true,
    max_leverage: u32 = LEVERAGE_MAX,
    // Asset resolution
    asset_index: ?usize = null,
    // Config (UI writes, workers read)
    iv_buf: [4]u8 = .{ '1', 'm', 0, 0 },
    iv_len: u8 = 2,
    depth: usize = 20,
    coin_buf: [16]u8 = undefined,
    coin_len: u8 = 0,
    coin_gen: u64 = 0,

    fn setInterval(self: *Shared, iv: []const u8) void {
        const n: u8 = @intCast(@min(iv.len, 4));
        @memcpy(self.iv_buf[0..n], iv[0..n]);
        self.iv_len = n;
    }
    fn setCoin(self: *Shared, c: []const u8) void {
        const n: u8 = @intCast(@min(c.len, 16));
        @memcpy(self.coin_buf[0..n], c[0..n]);
        self.coin_len = n;
        self.coin_gen += 1;
        self.max_leverage = LEVERAGE_MAX;
        self.candle_count = 0;
        self.n_bids = 0;
        self.n_asks = 0;
        self.trades.clear();
        self.info = .{};
        self.gen += 1;
    }

    // Apply helpers — single lock, single gen bump
    fn applyBook(self: *Shared, bids: [64]BookLevel, asks: [64]BookLevel, n: usize, mc: f64) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.bids = bids;
        self.asks = asks;
        self.n_bids = n;
        self.n_asks = n;
        self.max_cum = mc;
        self.gen += 1;
    }
    fn applyInfo(self: *Shared, info: InfoData) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.info = info;
        self.gen += 1;
    }
    fn applyCandle(self: *Shared, candle: Chart.Candle) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.candle_count > 0 and self.candles[self.candle_count - 1].t == candle.t) {
            self.candles[self.candle_count - 1] = candle;
        } else if (self.candle_count < Chart.MAX_CANDLES) {
            self.candles[self.candle_count] = candle;
            self.candle_count += 1;
        } else {
            std.mem.copyForwards(Chart.Candle, self.candles[0 .. Chart.MAX_CANDLES - 1], self.candles[1..Chart.MAX_CANDLES]);
            self.candles[Chart.MAX_CANDLES - 1] = candle;
        }
        self.gen += 1;
    }
    fn applyCandleSnapshot(self: *Shared, candles: [Chart.MAX_CANDLES]Chart.Candle, count: usize) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.candles = candles;
        self.candle_count = count;
        self.gen += 1;
    }
};

/// Snapshot taken under lock for rendering (no pointers into shared)
const Snapshot = struct {
    gen: u64,
    candles: [Chart.MAX_CANDLES]Chart.Candle,
    candle_count: usize,
    info: InfoData,
    bids: [64]BookLevel,
    asks: [64]BookLevel,
    n_bids: usize,
    n_asks: usize,
    max_cum: f64,
    trades: TableData,
    positions: TableData,
    open_orders: TableData,
    trade_history: TableData,
    funding_history: TableData,
    order_history: TableData,
    acct_buf: [24]u8,
    acct_len: usize,
    margin_buf: [24]u8,
    margin_len: usize,
    avail_buf: [24]u8,
    avail_len: usize,
    leverage_buf: [8]u8,
    leverage_len: usize,
    leverage_is_cross: bool,
    max_leverage: u32,
    asset_index: ?usize,

    fn take(s: *Shared) Snapshot {
        s.mu.lock();
        defer s.mu.unlock();
        return .{
            .gen = s.gen,
            .candles = s.candles, .candle_count = s.candle_count,
            .info = s.info,
            .bids = s.bids, .asks = s.asks, .n_bids = s.n_bids, .n_asks = s.n_asks, .max_cum = s.max_cum,
            .trades = s.trades,
            .positions = s.positions, .open_orders = s.open_orders,
            .trade_history = s.trade_history, .funding_history = s.funding_history,
            .order_history = s.order_history,
            .acct_buf = s.acct_buf, .acct_len = s.acct_len,
            .margin_buf = s.margin_buf, .margin_len = s.margin_len,
            .avail_buf = s.avail_buf, .avail_len = s.avail_len,
            .leverage_buf = s.leverage_buf, .leverage_len = s.leverage_len,
            .leverage_is_cross = s.leverage_is_cross,
            .max_leverage = s.max_leverage,
            .asset_index = s.asset_index,
        };
    }

    fn accountValue(self: *const Snapshot) ?[]const u8 {
        return if (self.acct_len > 0) self.acct_buf[0..self.acct_len] else null;
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  3. WORKERS (WS + REST)                                         ║
// ╚══════════════════════════════════════════════════════════════════╝

const WsWorker = struct {
    fn run(shared: *Shared, allocator: std.mem.Allocator, chain: signing.Chain) void {
        runInner(shared, allocator, chain) catch {};
    }

    fn runInner(shared: *Shared, allocator: std.mem.Allocator, chain: signing.Chain) !void {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        var prev_coin_gen: u64 = 0;
        var prev_iv: [4]u8 = .{ 0, 0, 0, 0 };
        var prev_iv_len: u8 = 0;

        while (shared.running.load(.acquire)) {
            var coin_buf: [16]u8 = undefined;
            var coin_len: u8 = undefined;
            var coin_gen: u64 = undefined;
            var iv_buf: [4]u8 = undefined;
            var iv_len: u8 = undefined;
            var depth: usize = undefined;
            {
                shared.mu.lock();
                defer shared.mu.unlock();
                coin_buf = shared.coin_buf;
                coin_len = shared.coin_len;
                coin_gen = shared.coin_gen;
                iv_buf = shared.iv_buf;
                iv_len = shared.iv_len;
                depth = shared.depth;
            }
            const coin = coin_buf[0..coin_len];
            const interval = iv_buf[0..iv_len];
            const changed = coin_gen != prev_coin_gen or iv_len != prev_iv_len or
                !std.mem.eql(u8, iv_buf[0..iv_len], prev_iv[0..prev_iv_len]);

            // REST candle snapshot on change
            if (changed) {
                var rc = switch (chain) { .mainnet => Client.mainnet(allocator), .testnet => Client.testnet(allocator) };
                defer rc.deinit();
                var candles: [Chart.MAX_CANDLES]Chart.Candle = undefined;
                var count: usize = 0;
                Rest.fetchCandles(&rc, coin, interval, &candles, &count);
                shared.applyCandleSnapshot(candles, count);
            }

            // Connect WS (blocking reads, broken by shutdown())
            const conn = ws_types.Connection.connect(allocator, chain) catch {
                std.Thread.sleep(1_000_000_000);
                continue;
            };
            defer conn.close();
            shared.ws_fd.store(conn.socket_fd, .release);

            conn.subscribe(.{ .l2Book = .{ .coin = coin } }) catch {};
            conn.subscribe(.{ .trades = .{ .coin = coin } }) catch {};
            conn.subscribe(.{ .candle = .{ .coin = coin, .interval = interval } }) catch {};
            conn.subscribe(.{ .activeAssetCtx = .{ .coin = coin } }) catch {};

            prev_coin_gen = coin_gen;
            prev_iv = iv_buf;
            prev_iv_len = iv_len;

            while (shared.running.load(.acquire)) {
                // Detect settings change → reconnect
                {
                    shared.mu.lock();
                    defer shared.mu.unlock();
                    if (shared.coin_gen != coin_gen or shared.iv_len != iv_len or
                        !std.mem.eql(u8, shared.iv_buf[0..shared.iv_len], iv_buf[0..iv_len]))
                        break;
                }
                const result = conn.next() catch break;
                switch (result) {
                    .timeout => continue,
                    .closed => break,
                    .message => |msg| {
                        const data = ws_types.extractData(msg.raw_json) orelse continue;
                        const arena = arena_state.allocator();
                        switch (msg.channel) {
                            .l2Book => decodeAndApplyBook(data, shared, depth, arena),
                            .trades => decodeAndApplyTrades(data, shared, arena),
                            .candle => decodeAndApplyCandle(data, shared, arena),
                            .activeAssetCtx => decodeAndApplyInfo(data, shared, arena),
                            else => {},
                        }
                        _ = arena_state.reset(.retain_capacity);
                    },
                }
            }
            shared.ws_fd.store(-1, .release);
            std.Thread.sleep(100_000_000);
        }
    }

    // ── Decode + Apply (parse outside lock, apply under lock) ──

    fn decodeAndApplyBook(data: []const u8, shared: *Shared, depth: usize, arena: std.mem.Allocator) void {
        const parsed = std.json.parseFromSlice(resp_types.L2Book, arena, data, resp_types.ParseOpts) catch return;
        const bl = parsed.value.levels;

        var bids: [64]BookLevel = undefined;
        var asks: [64]BookLevel = undefined;
        const eff = @min(depth, @min(bl[0].len, @min(bl[1].len, 64)));
        var bid_cum: f64 = 0;
        var ask_cum: f64 = 0;
        for (0..eff) |i| {
            var bpx_buf: [24]u8 = undefined;
            var bsz_buf: [24]u8 = undefined;
            const bsz = decToF64(bl[0][i].sz);
            bid_cum += bsz;
            bids[i] = .{ .sz = bsz, .cum = bid_cum };
            bids[i].px_len = copyTo(&bids[i].px_buf, bl[0][i].px.normalize().toString(&bpx_buf) catch "0");
            bids[i].sz_len = copyTo(&bids[i].sz_buf, bl[0][i].sz.normalize().toString(&bsz_buf) catch "0");

            var apx_buf: [24]u8 = undefined;
            var asz_buf: [24]u8 = undefined;
            const asz = decToF64(bl[1][i].sz);
            ask_cum += asz;
            asks[i] = .{ .sz = asz, .cum = ask_cum };
            asks[i].px_len = copyTo(&asks[i].px_buf, bl[1][i].px.normalize().toString(&apx_buf) catch "0");
            asks[i].sz_len = copyTo(&asks[i].sz_buf, bl[1][i].sz.normalize().toString(&asz_buf) catch "0");
        }
        shared.applyBook(bids, asks, eff, @max(bid_cum, ask_cum));
    }

    fn decodeAndApplyTrades(data: []const u8, shared: *Shared, arena: std.mem.Allocator) void {
        const parsed = std.json.parseFromSlice([]resp_types.Trade, arena, data, resp_types.ParseOpts) catch return;
        const trade_list = parsed.value;
        const new_count = @min(trade_list.len, MAX_ROWS);

        shared.mu.lock();
        defer shared.mu.unlock();

        // Shift existing rows down, prepend new trades
        const existing = shared.trades.n_rows;
        const total = @min(new_count + existing, MAX_ROWS);
        if (existing > 0 and new_count > 0) {
            var i: usize = total;
            while (i > new_count) {
                i -= 1;
                const src = i - new_count;
                if (src < existing) {
                    for (0..shared.trades.n_cols) |c| shared.trades.cells[i][c] = shared.trades.cells[src][c];
                    shared.trades.row_colors[i] = shared.trades.row_colors[src];
                }
            }
        }
        if (shared.trades.n_cols == 0) {
            shared.trades.n_cols = 4;
            shared.trades.setHeader(0, "Time");
            shared.trades.setHeader(1, "Price");
            shared.trades.setHeader(2, "Size");
            shared.trades.setHeader(3, "Side");
        }
        for (0..new_count) |idx| {
            const tr = trade_list[idx];
            if (tr.time > 0) {
                const s = @as(u64, @intCast(tr.time)) / 1000 % 86400;
                var tb: [10]u8 = undefined;
                shared.trades.set(idx, 0, std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, (s % 3600) / 60, s % 60 }) catch "?");
            }
            var px_b: [20]u8 = undefined;
            shared.trades.set(idx, 1, tr.px.normalize().toString(&px_b) catch "?");
            var sz_b: [20]u8 = undefined;
            shared.trades.set(idx, 2, tr.sz.normalize().toString(&sz_b) catch "?");
            const is_buy = std.mem.eql(u8, tr.side, "B");
            shared.trades.set(idx, 3, if (is_buy) "BUY" else "SELL");
            shared.trades.row_colors[idx] = if (is_buy) .positive else .negative;
        }
        shared.trades.n_rows = total;
        shared.gen += 1;
    }

    fn decodeAndApplyCandle(data: []const u8, shared: *Shared, arena: std.mem.Allocator) void {
        const parsed = std.json.parseFromSlice(resp_types.Candle, arena, data, resp_types.ParseOpts) catch return;
        const c = parsed.value;
        if (c.t == 0) return;
        shared.applyCandle(.{
            .t = @as(i64, @intCast(c.t)),
            .o = decToF64(c.o), .h = decToF64(c.h),
            .l = decToF64(c.l), .c = decToF64(c.c),
            .v = decToF64(c.v),
        });
    }

    fn decodeAndApplyInfo(data: []const u8, shared: *Shared, arena: std.mem.Allocator) void {
        const CtxWrapper = struct { ctx: resp_types.AssetContext = .{} };
        const parsed = std.json.parseFromSlice(CtxWrapper, arena, data, resp_types.ParseOpts) catch return;
        shared.applyInfo(buildInfoFromCtx(parsed.value.ctx));
    }
};

const RestWorker = struct {
    fn run(shared: *Shared, client: *Client, user_addr: ?[]const u8) void {
        var last_ms: i64 = 0;
        var prev_gen: u64 = 0;
        var resolved_coin_gen: u64 = 0;

        while (shared.running.load(.acquire)) {
            var coin_buf: [16]u8 = undefined;
            var coin_len: u8 = undefined;
            var coin_gen: u64 = undefined;
            {
                shared.mu.lock();
                defer shared.mu.unlock();
                coin_buf = shared.coin_buf;
                coin_len = shared.coin_len;
                coin_gen = shared.coin_gen;
            }
            if (coin_gen != prev_gen) { last_ms = 0; prev_gen = coin_gen; }

            // Resolve asset index on coin change
            if (coin_gen != resolved_coin_gen) {
                resolved_coin_gen = coin_gen;
                Rest.resolveAssetIndex(client, coin_buf[0..coin_len], shared);
            }

            const now = std.time.milliTimestamp();
            if (user_addr != null and now - last_ms >= 3000) {
                Rest.fetchUserData(client, user_addr.?, coin_buf[0..coin_len], shared);
                last_ms = std.time.milliTimestamp();
            }
            std.Thread.sleep(500_000_000);
        }
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  4. INPUT                                                       ║
// ╚══════════════════════════════════════════════════════════════════╝

const Input = struct {
    const intervals = [_][]const u8{ "1m", "5m", "15m", "1h", "4h", "1d" };
    const action_items = [_]ActionId{.set_leverage};

    fn handleKey(key: @import("Terminal").Key, ui: *UiState, running: *bool, client: *Client, config: *const Config, shared: *Shared) void {
        if (ui.actions.open) return handleActionKey(key, ui, client, config, shared);
        if (ui.leverage.open) return handleLeverageKey(key, ui, client, config, shared);
        if (ui.focus == .order_entry) return handleOrderKey(key, ui, client, config, shared);
        switch (key) {
            .char => |c| switch (c) {
                'q' => { running.* = false; },
                'i', 'I' => {
                    for (intervals, 0..) |iv, idx| {
                        if (std.mem.eql(u8, ui.interval, iv)) {
                            ui.interval = intervals[(idx + 1) % intervals.len];
                            break;
                        }
                    }
                },
                '1' => { ui.tab = .positions; ui.selected_row = 0; ui.scroll_offset = 0; },
                '2' => { ui.tab = .open_orders; ui.selected_row = 0; ui.scroll_offset = 0; },
                '3' => { ui.tab = .trade_history; ui.selected_row = 0; ui.scroll_offset = 0; },
                '4' => { ui.tab = .funding_history; ui.selected_row = 0; ui.scroll_offset = 0; },
                '5' => { ui.tab = .order_history; ui.selected_row = 0; ui.scroll_offset = 0; },
                'j' => if (ui.focus == .bottom) { ui.selected_row += 1; },
                'k' => if (ui.focus == .bottom) { ui.selected_row = ui.selected_row -| 1; },
                'g' => if (ui.focus == .bottom) { ui.selected_row = 0; ui.scroll_offset = 0; },
                'G' => if (ui.focus == .bottom) { ui.selected_row = 999; }, // clamped later
                'h' => ui.chart_scroll += 10, 'l' => ui.chart_scroll = ui.chart_scroll -| 10,
                'H' => ui.chart_scroll += 50, 'L' => ui.chart_scroll = ui.chart_scroll -| 50,
                '0' => ui.chart_scroll = 0,
                '+', '=' => ui.book_depth = @min(ui.book_depth + 5, 40),
                '-', '_' => ui.book_depth = if (ui.book_depth > 5) ui.book_depth - 5 else 5,
                'x', 'X' => if (ui.focus == .bottom) {
                    if (ui.tab == .open_orders) Orders.cancelOrder(ui, client, config, shared)
                    else if (ui.tab == .positions) Orders.closePosition(ui, client, config, shared);
                },
                'v', 'V' => openActionModal(ui),
                'd', 'D' => ui.show_perf = !ui.show_perf,
                'r', 'R' => if (ui.focus == .order_entry) { ui.order = OrderState{}; ui.order.setStatus("Reset", false); },
                else => {},
            },
            .tab => ui.focus = @enumFromInt((@intFromEnum(ui.focus) + 1) % 5),
            .esc => { running.* = false; },
            .left => ui.chart_scroll += 5,
            .right => ui.chart_scroll = ui.chart_scroll -| 5,
            .up => if (ui.focus == .bottom) { ui.selected_row = ui.selected_row -| 1; },
            .down => if (ui.focus == .bottom) { ui.selected_row += 1; },

            else => {},
        }
    }

    fn handleOrderKey(key: @import("Terminal").Key, ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        const o = &ui.order;
        switch (key) {
            .char => |c| switch (c) {
                '0'...'9', '.' => o.appendToActive(c),
                'b', 'B' => o.side = .buy,
                's', 'S' => o.side = .sell,
                'm', 'M' => { o.order_type = if (o.order_type == .market) .limit else .market; if (o.order_type == .limit) o.field = .size; },
                'L' => openLeverageModal(ui, shared),
                'v', 'V' => openActionModal(ui),
                'd', 'D' => ui.show_perf = !ui.show_perf,
                'q' => { ui.focus = .chart; },
                'r', 'R' => { o.* = OrderState{}; o.setStatus("Reset", false); },
                else => {},
            },
            .backspace => o.backspaceActive(),
            .enter => {
                const ai = blk: { shared.mu.lock(); defer shared.mu.unlock(); break :blk shared.asset_index; };
                Orders.execute(o, client, ui.coin[0..ui.coin_len], config, ai);
            },
            .tab => {
                if (o.order_type == .limit and o.field == .size) o.field = .price
                else { o.field = .size; ui.focus = .bottom; }
            },
            .up, .down => if (o.order_type == .limit) { o.field = if (o.field == .size) .price else .size; },
            .esc => ui.focus = .chart,
            else => {},
        }
    }

    fn openActionModal(ui: *UiState) void {
        ui.actions.open = true;
        ui.actions.mode = .list;
        ui.actions.selected = 0;
    }

    fn handleActionKey(key: @import("Terminal").Key, ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        switch (ui.actions.mode) {
            .list => switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q', 'v', 'V' => ui.actions.open = false,
                    'j' => ui.actions.selected = @min(ui.actions.selected + 1, action_items.len - 1),
                    'k' => ui.actions.selected -|= 1,
                    else => {},
                },
                .up => ui.actions.selected -|= 1,
                .down => ui.actions.selected = @min(ui.actions.selected + 1, action_items.len - 1),
                .enter => openActionForm(ui, shared),
                .esc => ui.actions.open = false,
                else => {},
            },
            .confirm => switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q' => ui.actions.mode = .list,
                    else => {},
                },
                .enter => executeAction(ui, client, config, shared),
                .esc => ui.actions.mode = .list,
                else => {},
            },
            .number => switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q' => ui.actions.mode = .list,
                    'h' => actionStep(ui, -ui.actions.number_step),
                    'l' => actionStep(ui, ui.actions.number_step),
                    'H' => actionStep(ui, -ui.actions.number_step_large),
                    'L' => actionStep(ui, ui.actions.number_step_large),
                    'c', 'C', 'm', 'M' => ui.actions.number_is_cross = !ui.actions.number_is_cross,
                    else => {},
                },
                .left => actionStep(ui, -ui.actions.number_step),
                .right => actionStep(ui, ui.actions.number_step),
                .down => actionStep(ui, -ui.actions.number_step_large),
                .up => actionStep(ui, ui.actions.number_step_large),
                .enter => executeAction(ui, client, config, shared),
                .esc => ui.actions.mode = .list,
                else => {},
            },
        }
    }

    fn openActionForm(ui: *UiState, shared: *Shared) void {
        const id = action_items[ui.actions.selected];
        if (!actionEnabled(id, ui, shared)) {
            ui.order.setStatus(actionDisabledReason(id), true);
            ui.actions.open = false;
            return;
        }
        ui.actions.current = id;
        switch (id) {
            .set_leverage => {
                ui.actions.open = false;
                ui.actions.mode = .list;
                ui.leverage.return_to_actions = true;
                openLeverageModal(ui, shared);
                return;
            },
            .cancel_all, .close_selected => ui.actions.mode = .confirm,
        }
    }

    fn executeAction(ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        switch (ui.actions.current) {
            .set_leverage => {
                ui.leverage.value = LeverageState.clamp(@intCast(@max(1, ui.actions.number_value)), ui.leverage.max);
                ui.leverage.is_cross = ui.actions.number_is_cross;
                Orders.updateLeverage(ui, client, config, shared);
            },
            .cancel_all => Orders.cancelAll(ui, client, config, shared),
            .close_selected => Orders.closePosition(ui, client, config, shared),
        }
        ui.actions.open = false;
        ui.actions.mode = .list;
    }

    fn actionStep(ui: *UiState, delta: i32) void {
        const next = ui.actions.number_value + delta;
        ui.actions.number_value = @max(ui.actions.number_min, @min(ui.actions.number_max, next));
    }

    fn actionEnabled(id: ActionId, ui: *const UiState, shared: *Shared) bool {
        const snap = Snapshot.take(shared);
        return switch (id) {
            .set_leverage => snap.asset_index != null,
            .cancel_all => countCoinOpenOrders(&snap, ui.coin[0..ui.coin_len]) > 0,
            .close_selected => snap.positions.n_rows > 0,
        };
    }

    fn actionDisabledReason(id: ActionId) []const u8 {
        return switch (id) {
            .set_leverage => "Asset not resolved",
            .cancel_all => "No open orders for coin",
            .close_selected => "No open positions",
        };
    }

    fn actionTitle(id: ActionId) []const u8 {
        return switch (id) {
            .set_leverage => "Set Leverage / Mode",
            .cancel_all => "Cancel All (Coin)",
            .close_selected => "Close Selected Position",
        };
    }

    fn countCoinOpenOrders(snap: *const Snapshot, coin: []const u8) usize {
        var n: usize = 0;
        for (0..snap.open_orders.n_rows) |r| {
            if (std.ascii.eqlIgnoreCase(snap.open_orders.get(r, 0), coin)) n += 1;
        }
        return n;
    }

    fn handleLeverageKey(key: @import("Terminal").Key, ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        switch (key) {
            .char => |c| switch (c) {
                'q', 'Q' => {
                    ui.leverage.open = false;
                    if (ui.leverage.return_to_actions) {
                        ui.actions.open = true;
                        ui.actions.mode = .list;
                        ui.leverage.return_to_actions = false;
                    }
                },
                'h' => ui.leverage.step(-1),
                'l' => ui.leverage.step(1),
                'H' => ui.leverage.step(-5),
                'L' => ui.leverage.step(5),
                'j' => ui.leverage.step(-1),
                'k' => ui.leverage.step(1),
                'c', 'C', 'm', 'M' => ui.leverage.is_cross = !ui.leverage.is_cross,
                else => {},
            },
            .left => ui.leverage.step(-1),
            .right => ui.leverage.step(1),
            .down => ui.leverage.step(-5),
            .up => ui.leverage.step(5),
            .enter => {
                Orders.updateLeverage(ui, client, config, shared);
                ui.leverage.open = false;
                if (ui.leverage.return_to_actions) {
                    ui.actions.open = true;
                    ui.actions.mode = .list;
                    ui.leverage.return_to_actions = false;
                }
            },
            .esc => {
                ui.leverage.open = false;
                if (ui.leverage.return_to_actions) {
                    ui.actions.open = true;
                    ui.actions.mode = .list;
                    ui.leverage.return_to_actions = false;
                }
            },
            else => {},
        }
    }

    fn openLeverageModal(ui: *UiState, shared: *Shared) void {
        var lev_buf: [8]u8 = undefined;
        var lev_len: usize = 0;
        var lev_cross = true;
        var max_lev: u32 = LEVERAGE_MAX;
        shared.mu.lock();
        lev_buf = shared.leverage_buf;
        lev_len = shared.leverage_len;
        lev_cross = shared.leverage_is_cross;
        max_lev = shared.max_leverage;
        shared.mu.unlock();

        ui.leverage.max = @max(LEVERAGE_MIN, max_lev);
        if (lev_len > 0) {
            const parsed = std.fmt.parseInt(u32, lev_buf[0..lev_len], 10) catch ui.leverage.value;
            ui.leverage.value = LeverageState.clamp(parsed, ui.leverage.max);
        }
        ui.leverage.is_cross = lev_cross;
        ui.leverage.open = true;
    }

    fn handleCoinPicker(key: @import("Terminal").Key, ui: *UiState, shared: *Shared) void {
        switch (key) {
            .char => |c| {
                if (c == '/') { ui.coin_picking = false; }
                else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
                    if (ui.coin_input_len < 15) { ui.coin_input[ui.coin_input_len] = std.ascii.toUpper(c); ui.coin_input_len += 1; }
                }
            },
            .backspace => ui.coin_input_len = ui.coin_input_len -| 1,
            .enter => {
                if (ui.coin_input_len > 0) {
                    @memcpy(ui.coin[0..ui.coin_input_len], ui.coin_input[0..ui.coin_input_len]);
                    ui.coin_len = ui.coin_input_len;
                    shared.mu.lock();
                    shared.setCoin(ui.coin[0..ui.coin_len]);
                    shared.mu.unlock();
                    const fd = shared.ws_fd.load(.acquire);
                    if (fd != -1) _ = std.c.shutdown(fd, 2);
                    ui.chart_scroll = 0;
                }
                ui.coin_picking = false;
                ui.coin_input_len = 0;
            },
            .esc => { ui.coin_picking = false; ui.coin_input_len = 0; },
            else => {},
        }
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  5. RENDER                                                      ║
// ╚══════════════════════════════════════════════════════════════════╝

const Render = struct {
    fn frame(app: *App, ui: *const UiState, snap: *const Snapshot) void {
        app.beginFrame();
        const buf = &app.buf;
        const w = app.width();
        const h = app.height();

        if (w < 80 or h < 24) {
            buf.putStr(2, 2, "Terminal too small (need 80x24+)", s_dim);
            app.endFrame();
            return;
        }

        const top_h: u16 = 2;
        const bottom_h: u16 = @max(6, h / 5);
        const main_h: u16 = h -| top_h -| bottom_h;
        const right_w: u16 = @min(38, w / 3);
        const chart_w: u16 = w -| right_w;
        const book_h: u16 = main_h / 2;
        const tape_h: u16 = @max(4, main_h / 6);
        const order_h: u16 = main_h -| book_h -| tape_h;

        const chart_rect = Rect{ .x = 0, .y = top_h, .w = chart_w, .h = main_h };
        const book_rect = Rect{ .x = chart_w, .y = top_h, .w = right_w, .h = book_h };
        const tape_rect = Rect{ .x = chart_w, .y = top_h + book_h, .w = right_w, .h = tape_h };
        const order_rect = Rect{ .x = chart_w, .y = top_h + book_h + tape_h, .w = right_w, .h = order_h };
        const bottom_rect = Rect{ .x = 0, .y = top_h + main_h, .w = w, .h = bottom_h };

        infoBar(buf, ui.coin[0..ui.coin_len], &snap.info, ui.interval, .{ .x = 0, .y = 0, .w = w, .h = top_h });

        const end = if (ui.chart_scroll < snap.candle_count) snap.candle_count - ui.chart_scroll else 0;
        const live_px = std.fmt.parseFloat(f64, snap.info.mark()) catch 0;
        Chart.render(buf, snap.candles[0..end], chart_rect, live_px);

        book(buf, &snap.bids, &snap.asks, snap.n_bids, snap.n_asks, snap.max_cum, book_rect);
        tradeTape(buf, &snap.trades, tape_rect);
        orderPanel(buf, ui.coin[0..ui.coin_len], snap.accountValue(), &ui.order, ui.focus == .order_entry, order_rect, snap);
        bottomTabs(buf, ui.tab, snap, bottom_rect, ui.selected_row, ui.focus == .bottom, ui.scroll_offset, ui.order.statusStr(), ui.order.status_is_error);

        const focus_rect = switch (ui.focus) {
            .chart => chart_rect, .book => book_rect, .tape => tape_rect,
            .order_entry => order_rect, .bottom => bottom_rect,
        };
        focusIndicator(buf, focus_rect);

        const badge = switch (ui.focus) {
            .chart => " \xe2\x97\x86 CHART ", .book => " \xe2\x97\x86 BOOK ",
            .tape => " \xe2\x97\x86 TRADES ", .order_entry => " \xe2\x97\x86 ORDER ",
            .bottom => " \xe2\x97\x86 TABS ",
        };
        if (ui.show_perf) {
            var mb: [96]u8 = undefined;
            const rss_mib = @as(f64, @floatFromInt(ui.rss_kb)) / 1024.0;
            const peak_mib = @as(f64, @floatFromInt(ui.peak_rss_kb)) / 1024.0;
            const flush_ms = @as(f64, @floatFromInt(BufMod.stats.flush_ns)) / 1_000_000.0;
            const mtxt = std.fmt.bufPrint(&mb, " RSS {d:.2}M  Peak {d:.2}M  \xe2\x88\x86{d}  Flush {d:.2}ms ", .{
                rss_mib,
                peak_mib,
                BufMod.stats.cells_changed,
                flush_ms,
            }) catch "";
            const mx = w -| @as(u16, @intCast(mtxt.len)) -| @as(u16, @intCast(badge.len)) -| 2;
            if (mx > 1) buf.putStr(mx, 0, mtxt, s_dim);
        }
        buf.putStr(w -| @as(u16, @intCast(badge.len)) -| 1, 0, badge, .{ .fg = hl_text, .bg = hl_accent, .bold = true });
        if (ui.actions.open) actionModal(buf, ui, snap, .{ .x = 0, .y = 0, .w = w, .h = h });
        if (ui.leverage.open) leverageModal(buf, ui, snap, .{ .x = 0, .y = 0, .w = w, .h = h });

        app.endFrame();
    }

    fn coinPickerOverlay(app: *App, ui: *const UiState) void {
        const buf = &app.buf;
        const w = app.width();
        const bx = w / 2 -| 16;
        const bg = Style{ .fg = hl_text, .bg = hl_panel };
        var px: u16 = bx;
        while (px < bx + 32 and px < w) : (px += 1) buf.putStr(px, 0, " ", bg);
        buf.putStr(bx + 1, 0, "/ ", .{ .fg = hl_accent, .bg = hl_panel, .bold = true });
        buf.putStr(bx + 3, 0, ui.coin_input[0..ui.coin_input_len], .{ .fg = hl_text, .bg = hl_panel, .bold = true });
        buf.putStr(bx + 3 + @as(u16, @intCast(ui.coin_input_len)), 0, "\xe2\x96\x88", .{ .fg = hl_accent, .bg = hl_panel });
        buf.flush(&app.prev);
        @memcpy(app.prev.cells, app.buf.cells);
    }

    fn focusIndicator(buf: *Buffer, rect: Rect) void {
        const fs = Style{ .fg = hl_accent, .bold = true };
        var y: u16 = rect.y + 1;
        while (y < rect.y + rect.h -| 1) : (y += 1) buf.putStr(rect.x, y, "\xe2\x96\x8e", fs);
        buf.putStr(rect.x, rect.y, "\xe2\x96\x9b", fs);
        if (rect.w > 1) buf.putStr(rect.x + rect.w - 1, rect.y, "\xe2\x96\x9c", fs);
        if (rect.h > 1) buf.putStr(rect.x, rect.y + rect.h - 1, "\xe2\x96\x99", fs);
        if (rect.w > 1 and rect.h > 1) buf.putStr(rect.x + rect.w - 1, rect.y + rect.h - 1, "\xe2\x96\x9f", fs);
    }

    fn infoBar(buf: *Buffer, coin: []const u8, info: *const InfoData, interval: []const u8, rect: Rect) void {
        buf.putStr(rect.x + 1, rect.y, coin, s_cyan);
        var x: u16 = rect.x + @as(u16, @intCast(coin.len)) + 2;
        x = label(buf, x, rect.y, "Mark", info.mark(), s_bold);
        x = label(buf, x, rect.y, "Oracle", info.oracle(), s_white);
        x = label(buf, x, rect.y, "24H", info.change_24h(), if (info.is_negative_change) s_bold_red else s_bold_green);
        x = label(buf, x, rect.y, "Vol", info.volume_24h(), s_white);
        if (x + 15 < rect.x + rect.w) _ = label(buf, x, rect.y, "OI", info.open_interest(), s_white);
        // Separator row
        var sx: u16 = 0;
        while (sx < rect.w) : (sx += 1) buf.putStr(rect.x + sx, rect.y + 1, "\xe2\x94\x80", s_dim);
        buf.putStr(rect.x + 1, rect.y + 1, "Fund ", s_dim);
        buf.putStr(rect.x + 6, rect.y + 1, info.funding(), s_green);
        const hint = "i:interval  \xe2\x86\x90\xe2\x86\x92:scroll  Tab:panel  v:actions  D:perf";
        buf.putStr(rect.x + rect.w -| @as(u16, @intCast(hint.len)) -| 1, rect.y + 1, hint, s_dim);
        const bx = rect.x + 7 + @as(u16, @intCast(@min(info.funding().len, 16))) + 2;
        buf.putStr(bx, rect.y + 1, "[", s_dim);
        buf.putStr(bx + 1, rect.y + 1, interval, s_bold);
        buf.putStr(bx + 1 + @as(u16, @intCast(interval.len)), rect.y + 1, "]", s_dim);
    }

    fn book(buf: *Buffer, bids: []const BookLevel, asks: []const BookLevel, n_bids: usize, n_asks: usize, max_cum: f64, rect: Rect) void {
        buf.drawBox(rect, "Order Book", s_cyan);
        if (rect.h < 6) return;
        const ix = rect.x + 1;
        const iw = rect.w -| 2;
        const data_h = rect.h -| 3;
        const half = data_h / 2;

        buf.putStr(ix, rect.y + 1, "Price", s_dim);
        buf.putStr(ix + 11, rect.y + 1, "Size", s_dim);
        buf.putStr(ix + 22, rect.y + 1, "Total", s_dim);

        const show_asks = @min(n_asks, half);
        var y: u16 = rect.y + 2;
        var ai: usize = show_asks;
        while (ai > 0) : (y += 1) {
            ai -= 1;
            if (y >= rect.y + rect.h - 1) break;
            const lv = asks[ai];
            buf.putStr(ix, y, lv.px(), s_bold_red);
            buf.putStrRight(ix + 11, y, 10, lv.szStr(), s_white);
            var cb: [12]u8 = undefined;
            buf.putStrRight(ix + 22, y, 10, fmtF64(&cb, lv.cum), s_dim);
            if (max_cum > 0 and iw > 34) {
                const bw = iw -| 34;
                buf.putBgBar(ix + 33, y, @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bw))))), .{ .bg = hl_sell_bg });
            }
        }
        if (show_asks > 0 and n_bids > 0 and y < rect.y + rect.h - 1) {
            const bp = std.fmt.parseFloat(f64, bids[0].px()) catch 0;
            const ap = std.fmt.parseFloat(f64, asks[0].px()) catch 0;
            const sp = ap - bp;
            var sb: [32]u8 = undefined;
            const ss = std.fmt.bufPrint(&sb, "Spread {d:.0} ({d:.3}%)", .{ sp, if (bp > 0) sp / bp * 100 else @as(f64, 0) }) catch "";
            buf.putStr(ix + (iw -| @as(u16, @intCast(ss.len))) / 2, y, ss, s_dim);
            y += 1;
        }
        for (0..@min(n_bids, half)) |i| {
            if (y >= rect.y + rect.h - 1) break;
            const lv = bids[i];
            buf.putStr(ix, y, lv.px(), s_bold_green);
            buf.putStrRight(ix + 11, y, 10, lv.szStr(), s_white);
            var cb: [12]u8 = undefined;
            buf.putStrRight(ix + 22, y, 10, fmtF64(&cb, lv.cum), s_dim);
            if (max_cum > 0 and iw > 34) {
                const bw = iw -| 34;
                buf.putBgBar(ix + 33, y, @max(1, @as(u16, @intFromFloat(@sqrt(lv.cum / max_cum) * @as(f64, @floatFromInt(bw))))), .{ .bg = hl_buy_bg });
            }
            y += 1;
        }
    }

    fn tradeTape(buf: *Buffer, trades: *const TableData, rect: Rect) void {
        buf.drawBox(rect, "Trades", s_cyan);
        if (rect.h < 3 or trades.n_rows == 0) {
            if (rect.h >= 3) buf.putStr(rect.x + 2, rect.y + 1, "Waiting...", s_dim);
            return;
        }
        const ix = rect.x + 1;
        const iw = rect.w -| 2;
        buf.putStr(ix, rect.y + 1, "Price", s_dim);
        buf.putStr(ix + @min(12, iw -| 10), rect.y + 1, "Size", s_dim);
        buf.putStr(ix + @min(24, iw -| 3), rect.y + 1, "Time", s_dim);
        for (0..@min(trades.n_rows, rect.h -| 2)) |i| {
            const y = rect.y + 2 + @as(u16, @intCast(i));
            if (y >= rect.y + rect.h - 1) break;
            const s = if (std.mem.eql(u8, trades.get(i, 3), "BUY")) s_bold_green else s_bold_red;
            buf.putStr(ix, y, trades.get(i, 1), s);
            buf.putStr(ix + @min(12, iw -| 10), y, trades.get(i, 2), s_white);
            if (iw > 20) buf.putStr(ix + @min(24, iw -| 3), y, trades.get(i, 0), s_dim);
        }
    }

    fn orderPanel(buf: *Buffer, coin: []const u8, acct: ?[]const u8, o: *const OrderState, focused: bool, rect: Rect, snap: *const Snapshot) void {
        buf.drawBox(rect, "Order Entry", if (focused) s_cyan else Style{ .fg = hl_accent });
        if (rect.h < 5) return;
        const ix = rect.x + 2;
        const iw = rect.w -| 4;
        const content_bottom = rect.y + rect.h - 1;
        var y = rect.y + 1;
        // Type
        const mkt = o.order_type == .market;
        buf.putStr(ix, y, " Market ", if (mkt) Style{ .fg = hl_text, .bg = hl_accent, .bold = true } else s_dim);
        buf.putStr(ix + 9, y, " Limit ", if (!mkt) Style{ .fg = hl_text, .bg = hl_accent, .bold = true } else s_dim);
        if (focused) buf.putStr(ix + iw -| 5, y, "[m]", s_dim);
        y += 1;
        // Side
        buf.putStr(ix, y, " Buy/Long ", if (o.side == .buy) Style{ .fg = hl_text, .bg = hl_buy, .bold = true } else Style{ .fg = hl_buy });
        buf.putStr(ix + 11, y, " Sell/Short ", if (o.side == .sell) Style{ .fg = hl_text, .bg = hl_sell, .bold = true } else Style{ .fg = hl_sell });
        if (focused) buf.putStr(ix + iw -| 5, y, "[b/s]", s_dim);
        y += 1;
        // Coin
        buf.putStr(ix, y, "Coin", s_dim);
        buf.putStr(ix + 10, y, coin, s_cyan);
        y += 1;
        // Size
        const sz = o.sizeStr();
        const sf = focused and o.field == .size;
        buf.putStr(ix, y, if (sf) "\xe2\x96\xb8 " else "  ", .{ .fg = hl_accent });
        buf.putStr(ix + 2, y, "Size", if (sf) Style{ .fg = hl_accent, .bold = true } else s_dim);
        if (sf) { buf.putStr(ix + 10, y, sz, s_bold); buf.putStr(ix + 10 + @as(u16, @intCast(sz.len)), y, "\xe2\x96\x88", .{ .fg = hl_accent }); }
        else buf.putStr(ix + 10, y, if (sz.len > 0) sz else "\xe2\x80\x94", s_white);
        y += 1;
        // Price (limit)
        if (o.order_type == .limit) {
            const px = o.priceStr();
            const pf = focused and o.field == .price;
            buf.putStr(ix, y, if (pf) "\xe2\x96\xb8 " else "  ", .{ .fg = hl_accent });
            buf.putStr(ix + 2, y, "Price", if (pf) Style{ .fg = hl_accent, .bold = true } else s_dim);
            if (pf) { buf.putStr(ix + 10, y, px, s_bold); buf.putStr(ix + 10 + @as(u16, @intCast(px.len)), y, "\xe2\x96\x88", .{ .fg = hl_accent }); }
            else buf.putStr(ix + 10, y, if (px.len > 0) px else "\xe2\x80\x94", s_white);
            y += 1;
            if (focused) { buf.putStr(ix + 2, y, "\xe2\x86\x91\xe2\x86\x93 switch field", s_dim); y += 1; }
        }
        // ── Account ──
        if (y + 1 < content_bottom) {
            y += 1;
        }
        if (y < rect.y + rect.h -| 3) {
            // Separator
            var sx: u16 = 0;
            while (sx < iw) : (sx += 1) buf.putStr(ix + sx, y, "\xe2\x94\x80", .{ .fg = hl_border });
            y += 1;
        }
        if (acct) |av| if (y < content_bottom) {
            buf.putStr(ix, y, "Equity", s_dim);
            buf.putStr(ix + 12, y, av, s_bold);
            y += 1;
        };
        if (snap.avail_len > 0 and y < content_bottom) {
            buf.putStr(ix, y, "Available", s_dim);
            const avail_style: Style = if (std.fmt.parseFloat(f64, snap.avail_buf[0..snap.avail_len]) catch 0 > 0) s_green else Style{ .fg = hl_sell };
            buf.putStr(ix + 12, y, snap.avail_buf[0..snap.avail_len], avail_style);
            y += 1;
        }
        if (snap.margin_len > 0 and y < content_bottom) {
            buf.putStr(ix, y, "Margin Used", s_dim);
            buf.putStr(ix + 12, y, snap.margin_buf[0..snap.margin_len], s_white);
            y += 1;
        }
        const lev = if (snap.leverage_len > 0) snap.leverage_buf[0..snap.leverage_len] else null;
        if (lev) |l| if (y < content_bottom) {
            buf.putStr(ix, y, "Leverage", s_dim);
            buf.putStr(ix + 12, y, l, Style{ .fg = hl_accent, .bold = true });
            buf.putStr(ix + 12 + @as(u16, @intCast(@min(l.len, 8))), y, "x", s_dim);
            if (focused and iw > 20) buf.putStr(ix + iw -| 10, y, "[L] edit", s_dim);
            y += 1;
        };
        if (snap.asset_index == null and y < content_bottom) {
            buf.putStr(ix, y, "\xe2\x9a\xa0 resolving...", Style{ .fg = C.hex(0xf5c344) });
            y += 1;
        }
        if (y + 1 < content_bottom) y += 1;
        // Button
        if (y < content_bottom) {
            const bg = if (o.side == .buy) hl_buy else hl_sell;
            const bl = if (o.side == .buy) " \xe2\x8f\x8e Place Buy " else " \xe2\x8f\x8e Place Sell ";
            const bw: u16 = @min(rect.w -| 4, @as(u16, @intCast(bl.len)) + 2);
            const bx = ix + (rect.w -| 4 -| bw) / 2;
            var bi: u16 = 0;
            while (bi < bw) : (bi += 1) buf.putStr(bx + bi, y, " ", .{ .bg = bg });
            buf.putStr(bx + 1, y, bl, .{ .fg = hl_text, .bg = bg, .bold = true });
        }
    }

    fn bottomTabs(
        buf: *Buffer,
        active: ActiveTab,
        snap: *const Snapshot,
        rect: Rect,
        selected: usize,
        focused: bool,
        scroll: usize,
        status: []const u8,
        status_is_error: bool,
    ) void {
        const tabs = [_][]const u8{ " Positions ", " Open Orders ", " Trade History ", " Funding ", " Order History " };
        var tx: u16 = rect.x + 1;
        for (tabs, 0..) |lbl, i| {
            const act = @as(u3, @intCast(i)) == @intFromEnum(active);
            var nb: [2]u8 = .{ @intCast('1' + i), ' ' };
            buf.putStr(tx, rect.y, &nb, if (act) Style{ .fg = hl_accent, .bg = hl_panel, .bold = true } else s_dim);
            tx += 1;
            buf.putStr(tx, rect.y, lbl, if (act) Style{ .fg = hl_text, .bg = hl_panel, .bold = true } else s_dim);
            tx += @as(u16, @intCast(lbl.len));
            if (act) { var ux: u16 = tx -| @as(u16, @intCast(lbl.len)); while (ux < tx) : (ux += 1) buf.putStr(ux, rect.y + 1, "\xe2\x96\x94", .{ .fg = hl_accent }); }
            tx += 1;
        }
        var sx: u16 = 0;
        while (sx < rect.w) : (sx += 1) {
            const cell = buf.get(rect.x + sx, rect.y + 1);
            if (cell.char[0] == ' ' or cell.char[0] == 0) buf.putStr(rect.x + sx, rect.y + 1, "\xe2\x94\x80", .{ .fg = hl_border });
        }
        const cr = Rect{ .x = rect.x, .y = rect.y + 2, .w = rect.w, .h = rect.h -| 3 };
        if (cr.h < 1) return;
        const tbl: *const TableData = switch (active) {
            .positions => &snap.positions, .open_orders => &snap.open_orders,
            .trade_history => &snap.trade_history, .funding_history => &snap.funding_history,
            .order_history => &snap.order_history,
        };
        if (tbl.n_rows == 0) {
            buf.putStr(cr.x + 2, cr.y, switch (active) {
                .positions => "No open positions", .open_orders => "No open orders",
                .trade_history => "No trade history", .funding_history => "No funding history",
                .order_history => "No order history",
            }, s_dim);
        } else table(buf, tbl, cr, if (focused) selected else null, if (focused) scroll else null);
        const hint: []const u8 = switch (active) {
            .positions => if (focused) "x:close  \xe2\x86\x91\xe2\x86\x93:select  q:quit  /:coin  Tab:panel  i:interval" else "q:quit  /:coin  Tab:panel  i:interval  \xe2\x86\x90\xe2\x86\x92:scroll  0:snap  +/-:depth",
            .open_orders => if (focused) "x:cancel  \xe2\x86\x91\xe2\x86\x93:select  q:quit  /:coin  Tab:panel  i:interval" else "q:quit  /:coin  Tab:panel  i:interval  \xe2\x86\x90\xe2\x86\x92:scroll  0:snap  +/-:depth",
            else => "q:quit  /:coin  Tab:panel  i:interval  \xe2\x86\x90\xe2\x86\x92:scroll  0:snap  +/-:depth",
        };
        const footer_y = rect.y + rect.h - 1;
        const st_style: Style = if (status_is_error) s_bold_red else s_green;
        const st = if (status.len > 0) status else "Ready";
        var sb: [96]u8 = undefined;
        const st_prefix = std.fmt.bufPrint(&sb, "Status: {s}", .{st}) catch "Status";
        const max_status = rect.w / 2;
        const st_text = st_prefix[0..@min(st_prefix.len, max_status)];
        buf.putStr(rect.x + 1, footer_y, st_text, st_style);
        const hint_x = rect.x + rect.w -| @as(u16, @intCast(hint.len)) -| 1;
        buf.putStr(hint_x, footer_y, hint, s_dim);
    }

    fn table(buf: *Buffer, tbl: *const TableData, rect: Rect, selected: ?usize, scroll: ?usize) void {
        if (tbl.n_cols == 0) return;
        const n: u16 = @intCast(tbl.n_cols);
        const cw = @max(6, (rect.w -| 2) / n);
        for (0..tbl.n_cols) |c| {
            const hx = rect.x + @as(u16, @intCast(c)) * cw + 1;
            if (hx >= rect.x + rect.w) break;
            const hdr = tbl.getHeader(c);
            buf.putStr(hx, rect.y, hdr[0..@min(hdr.len, cw -| 1)], s_dim);
        }
        const visible = rect.h -| 1;
        const off = scroll orelse 0;
        const start = @min(off, if (tbl.n_rows > visible) tbl.n_rows - visible else 0);
        for (0..@min(tbl.n_rows -| start, visible)) |vi| {
            const r = start + vi;
            const ry = rect.y + 1 + @as(u16, @intCast(vi));
            if (ry >= rect.y + rect.h) break;
            const is_sel = if (selected) |s| r == s else false;
            const rs: Style = switch (tbl.row_colors[r]) { .positive => s_green, .negative => s_red, .neutral => s_white };
            // Highlight selected row background
            if (is_sel) {
                var sx: u16 = 0;
                while (sx < rect.w) : (sx += 1) buf.putStr(rect.x + sx, ry, " ", .{ .bg = hl_border });
                buf.putStr(rect.x, ry, "▸", .{ .fg = hl_accent, .bg = hl_border });
            }
            for (0..tbl.n_cols) |c| {
                const cx = rect.x + @as(u16, @intCast(c)) * cw + 1;
                if (cx >= rect.x + rect.w) break;
                const val = tbl.get(r, c);
                const mw = @min(val.len, @min(cw -| 1, rect.x + rect.w -| cx -| 1));
                const base: Style = if (c == 0 or c == tbl.n_cols - 1) rs else s_white;
                buf.putStr(cx, ry, val[0..mw], if (is_sel) Style{ .fg = base.fg, .bg = hl_border, .bold = true } else base);
            }
        }
        // Scroll indicator
        if (tbl.n_rows > visible) {
            var ib: [16]u8 = undefined;
            const ind = std.fmt.bufPrint(&ib, " {d}/{d} ", .{ (selected orelse 0) + 1, tbl.n_rows }) catch "";
            buf.putStr(rect.x + rect.w -| @as(u16, @intCast(ind.len)) -| 1, rect.y, ind, s_dim);
        }
    }

    fn label(buf: *Buffer, x: u16, y: u16, lbl: []const u8, val: []const u8, style: Style) u16 {
        buf.putStr(x, y, lbl, s_dim);
        const lx = x + @as(u16, @intCast(lbl.len)) + 1;
        buf.putStr(lx, y, val, style);
        return lx + @as(u16, @intCast(@min(val.len, 20))) + 2;
    }

    fn leverageModal(buf: *Buffer, ui: *const UiState, snap: *const Snapshot, rect: Rect) void {
        const scrim = Style{ .bg = C.hex(0x0b1519) };
        var sy: u16 = 0;
        while (sy < rect.h) : (sy += 1) {
            var sx: u16 = 0;
            while (sx < rect.w) : (sx += 1) buf.putStr(rect.x + sx, rect.y + sy, " ", scrim);
        }

        const mw: u16 = @min(72, rect.w -| 4);
        const mh: u16 = 12;
        const mx = rect.x + (rect.w -| mw) / 2;
        const my = rect.y + (rect.h -| mh) / 2;
        const mrect = Rect{ .x = mx, .y = my, .w = mw, .h = @min(mh, rect.h -| 2) };
        buf.drawBox(mrect, "Adjust Leverage", s_cyan);

        var fy: u16 = mrect.y + 1;
        while (fy < mrect.y + mrect.h - 1) : (fy += 1) {
            var fx: u16 = mrect.x + 1;
            while (fx < mrect.x + mrect.w - 1) : (fx += 1) buf.putStr(fx, fy, " ", .{ .bg = hl_panel });
        }

        const ix = mrect.x + 3;
        const mode = if (ui.leverage.is_cross) "cross" else "isolated";
        var cb: [32]u8 = undefined;
        const coin = if (ui.coin_len > 0) ui.coin[0..ui.coin_len] else "COIN";
        const header = std.fmt.bufPrint(&cb, "{s} mode: {s}", .{ coin, mode }) catch "";
        buf.putStr(ix, mrect.y + 2, header, s_white);

        const track_w: u16 = mrect.w -| 24;
        const tx = ix;
        const ty = mrect.y + 5;
        if (track_w > 2) {
            var i: u16 = 0;
            while (i < track_w) : (i += 1) buf.putStr(tx + i, ty, "\xe2\x94\x80", .{ .fg = hl_border, .bg = hl_panel });
            const range = LEVERAGE_MAX - LEVERAGE_MIN;
            const pos_num: u32 = (ui.leverage.value - LEVERAGE_MIN) * (track_w - 1);
            const kpos: u16 = if (range > 0) @intCast(pos_num / range) else 0;
            i = 0;
            while (i <= kpos and i < track_w) : (i += 1) buf.putStr(tx + i, ty, "\xe2\x94\x81", .{ .fg = hl_accent, .bg = hl_panel });
            buf.putStr(tx + kpos, ty, "\xe2\x97\x8f", .{ .fg = hl_accent, .bg = hl_panel, .bold = true });
        }

        var vb: [12]u8 = undefined;
        const vtxt = std.fmt.bufPrint(&vb, "{d}x", .{ui.leverage.value}) catch "?x";
        buf.putStr(mrect.x + mrect.w -| 12, ty, vtxt, s_bold);
        var xb: [14]u8 = undefined;
        const xmax = std.fmt.bufPrint(&xb, "Max: {d}x", .{ui.leverage.max}) catch "";
        buf.putStr(mrect.x + mrect.w -| @as(u16, @intCast(xmax.len)) -| 2, mrect.y + 2, xmax, s_dim);

        const can_set = snap.asset_index != null;
        if (!can_set) buf.putStr(ix, mrect.y + 7, "Asset not resolved yet", s_bold_red);
        buf.putStr(ix, mrect.y + mrect.h -| 3, "h/l: +/-1  H/L: +/-5  c:mode  Enter:apply  Esc:q", s_dim);
    }

    fn actionModal(buf: *Buffer, ui: *const UiState, snap: *const Snapshot, rect: Rect) void {
        const scrim = Style{ .bg = C.hex(0x0b1519) };
        var sy: u16 = 0;
        while (sy < rect.h) : (sy += 1) {
            var sx: u16 = 0;
            while (sx < rect.w) : (sx += 1) buf.putStr(rect.x + sx, rect.y + sy, " ", scrim);
        }

        const mw: u16 = @min(56, rect.w -| 4);
        const mh: u16 = @min(14, rect.h -| 4);
        const mx = rect.x + (rect.w -| mw) / 2;
        const my = rect.y + (rect.h -| mh) / 2;
        const mrect = Rect{ .x = mx, .y = my, .w = mw, .h = mh };
        buf.drawBox(mrect, "Actions", s_cyan);
        if (mrect.w < 40 or mrect.h < 8) {
            buf.putStr(mrect.x + 2, mrect.y + 2, "Terminal too small", s_dim);
            return;
        }

        const ix = mrect.x + 2;
        var y = mrect.y + 2;
        switch (ui.actions.mode) {
            .list => {
                const items = [_]ActionId{.set_leverage};
                for (items, 0..) |id, i| {
                    const sel = i == ui.actions.selected;
                    const enabled = actionEnabledSnap(id, ui, snap);
                    buf.putStr(ix, y, if (sel) "\xe2\x96\xb8" else " ", if (sel) s_cyan else s_dim);
                    buf.putStr(ix + 2, y, Input.actionTitle(id), if (!enabled) s_dim else if (sel) s_bold else s_white);
                    if (!enabled) {
                        const why = switch (id) {
                            .set_leverage => "asset unresolved",
                            .cancel_all => "no open orders",
                            .close_selected => "no positions",
                        };
                        buf.putStr(ix + 28, y, why, s_dim);
                    }
                    y += 1;
                }
                buf.putStr(ix, mrect.y + mrect.h -| 2, "j/k:select  Enter:open  Esc/v:close", s_dim);
            },
            .confirm => {
                buf.putStr(ix, y, Input.actionTitle(ui.actions.current), s_bold);
                y += 2;
                const msg = switch (ui.actions.current) {
                    .cancel_all => "Cancel all open orders for active coin?",
                    .close_selected => "Close currently selected position?",
                    .set_leverage => "Apply leverage?",
                };
                buf.putStr(ix, y, msg, s_white);
                buf.putStr(ix, mrect.y + mrect.h -| 2, "Enter:confirm  Esc:back", s_dim);
            },
            .number => {
                buf.putStr(ix, y, Input.actionTitle(ui.actions.current), s_bold);
                y += 2;
                var nb: [16]u8 = undefined;
                const v = std.fmt.bufPrint(&nb, "{d}x", .{ui.actions.number_value}) catch "?x";
                buf.putStr(ix, y, "Leverage", s_dim);
                buf.putStr(ix + 12, y, v, s_cyan);
                y += 1;
                buf.putStr(ix, y, "Mode", s_dim);
                buf.putStr(ix + 12, y, if (ui.actions.number_is_cross) "cross" else "isolated", s_white);
                if (snap.asset_index == null) buf.putStr(ix, y + 2, "Asset not resolved yet", s_bold_red);
                buf.putStr(ix, mrect.y + mrect.h -| 2, "h/l:+/-1 H/L:+/-5 c:mode Enter:apply Esc:back", s_dim);
            },
        }
    }

    fn actionEnabledSnap(id: ActionId, ui: *const UiState, snap: *const Snapshot) bool {
        return switch (id) {
            .set_leverage => snap.asset_index != null,
            .cancel_all => Input.countCoinOpenOrders(snap, ui.coin[0..ui.coin_len]) > 0,
            .close_selected => snap.positions.n_rows > 0,
        };
    }

};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  6. ORDERS                                                      ║
// ╚══════════════════════════════════════════════════════════════════╝

const Orders = struct {
    const zig = @import("hyperzig");
    const types = zig.hypercore.types;

    fn makeCloid(seed: u64) types.Cloid {
        var cloid = types.ZERO_CLOID;
        cloid[0] = @intCast((seed >> 56) & 0xff);
        cloid[1] = @intCast((seed >> 48) & 0xff);
        cloid[2] = @intCast((seed >> 40) & 0xff);
        cloid[3] = @intCast((seed >> 32) & 0xff);
        cloid[4] = @intCast((seed >> 24) & 0xff);
        cloid[5] = @intCast((seed >> 16) & 0xff);
        cloid[6] = @intCast((seed >> 8) & 0xff);
        cloid[7] = @intCast(seed & 0xff);
        if (seed == 0) cloid[15] = 1;
        return cloid;
    }

    fn execute(order: *OrderState, client: *Client, coin: []const u8, config: *const Config, asset_index: ?usize) void {
        _ = coin;
        const signer = config.getSigner() catch { order.setStatus("No key configured", true); return; };
        const asset: u32 = @intCast(asset_index orelse { order.setStatus("Asset not resolved", true); return; });
        const sz_str = order.sizeStr();
        if (sz_str.len == 0) { order.setStatus("Enter size first", true); return; }
        const sz = std.fmt.parseFloat(f64, sz_str) catch { order.setStatus("Invalid size", true); return; };
        if (sz <= 0) { order.setStatus("Size must be > 0", true); return; }

        const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
        const tif: types.TimeInForce = if (order.order_type == .market) .FrontendMarket else .Gtc;
        const sz_dec = Decimal.fromString(sz_str) catch { order.setStatus("Invalid size format", true); return; };
        const px_dec = if (order.order_type == .market)
            (if (order.side == .buy) Decimal.fromString("999999") catch unreachable else Decimal.fromString("1") catch unreachable)
        else blk: {
            const p = order.priceStr();
            if (p.len == 0) { order.setStatus("Enter price first", true); return; }
            break :blk Decimal.fromString(p) catch { order.setStatus("Invalid price format", true); return; };
        };
        const ord = types.OrderRequest{ .asset = asset, .is_buy = order.side == .buy, .limit_px = px_dec, .sz = sz_dec, .reduce_only = false, .order_type = .{ .limit = .{ .tif = tif } }, .cloid = makeCloid(nonce) };
        const arr = [1]types.OrderRequest{ord};
        var result = client.place(signer, .{ .orders = &arr, .grouping = .na }, nonce, null, null) catch {
            order.setStatus("Order failed (network)", true);
            return;
        };
        defer result.deinit();
        var sb: [48]u8 = undefined;
        const check = checkOrderResult(std.heap.page_allocator, &result, &sb);
        if (check.ok) {
            order.setStatus(check.msg, false);
            order.size_len = 0;
            if (order.order_type == .limit) order.price_len = 0;
        } else {
            order.setStatus(check.msg, true);
        }
    }

    /// Cancel selected order (from orders tab)
    fn cancelOrder(ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        const signer = config.getSigner() catch { ui.order.setStatus("No key configured", true); return; };
        const snap = Snapshot.take(shared);
        if (ui.selected_row >= snap.open_orders.n_rows) { ui.order.setStatus("No order selected", true); return; }
        const oid_str = snap.open_orders.get(ui.selected_row, 5); // OID column
        const coin = snap.open_orders.get(ui.selected_row, 0);
        if (oid_str.len == 0 or coin.len == 0) { ui.order.setStatus("Invalid order", true); return; }
        const oid = std.fmt.parseInt(u64, oid_str, 10) catch { ui.order.setStatus("Invalid OID", true); return; };

        // Resolve asset for cancel (we need the asset index for this coin)
        const asset: u32 = blk: { shared.mu.lock(); defer shared.mu.unlock(); break :blk @intCast(shared.asset_index orelse { ui.order.setStatus("Asset not resolved", true); return; }); };
        const cancel = types.Cancel{ .asset = asset, .oid = oid };
        const arr = [1]types.Cancel{cancel};
        const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
        var result = client.cancel(signer, .{ .cancels = &arr }, nonce, null, null) catch {
            ui.order.setStatus("Cancel failed (network)", true);
            return;
        };
        defer result.deinit();
        var sb: [48]u8 = undefined;
        const check = checkOrderResult(std.heap.page_allocator, &result, &sb);
        ui.order.setStatus(if (check.ok) "Order cancelled!" else check.msg, !check.ok);
    }

    fn cancelAll(ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        const signer = config.getSigner() catch { ui.order.setStatus("No key configured", true); return; };
        const snap = Snapshot.take(shared);
        const asset: u32 = blk: {
            shared.mu.lock();
            defer shared.mu.unlock();
            break :blk @intCast(shared.asset_index orelse {
                ui.order.setStatus("Asset not resolved", true);
                return;
            });
        };

        var cancels: [MAX_ROWS]types.Cancel = undefined;
        var n: usize = 0;
        const coin = ui.coin[0..ui.coin_len];
        for (0..snap.open_orders.n_rows) |r| {
            if (!std.ascii.eqlIgnoreCase(snap.open_orders.get(r, 0), coin)) continue;
            const oid_str = snap.open_orders.get(r, 5);
            const oid = std.fmt.parseInt(u64, oid_str, 10) catch continue;
            cancels[n] = .{ .asset = asset, .oid = oid };
            n += 1;
            if (n >= MAX_ROWS) break;
        }
        if (n == 0) { ui.order.setStatus("No open orders for coin", true); return; }

        const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
        var result = client.cancel(signer, .{ .cancels = cancels[0..n] }, nonce, null, null) catch {
            ui.order.setStatus("Cancel all failed (network)", true);
            return;
        };
        defer result.deinit();
        if (!(result.isOk() catch false)) {
            var sb: [48]u8 = undefined;
            const check = checkOrderResult(std.heap.page_allocator, &result, &sb);
            ui.order.setStatus(check.msg, true);
            return;
        }
        var mb: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&mb, "Cancelled {d} order(s)", .{n}) catch "Cancelled orders";
        ui.order.setStatus(msg, false);
    }

    fn closePosition(ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        const signer = config.getSigner() catch { ui.order.setStatus("No key configured", true); return; };
        const snap = Snapshot.take(shared);
        if (ui.selected_row >= snap.positions.n_rows) { ui.order.setStatus("No position selected", true); return; }
        const sz_str = snap.positions.get(ui.selected_row, 2); // Size column
        const side_str = snap.positions.get(ui.selected_row, 1); // Side column
        if (sz_str.len == 0) { ui.order.setStatus("Invalid position", true); return; }

        const asset: u32 = blk: { shared.mu.lock(); defer shared.mu.unlock(); break :blk @intCast(shared.asset_index orelse { ui.order.setStatus("Asset not resolved", true); return; }); };
        const sz_dec = Decimal.fromString(sz_str) catch { ui.order.setStatus("Invalid size", true); return; };
        // Close = opposite side, reduce_only, market
        const is_long = std.mem.eql(u8, side_str, "LONG");
        const px_dec = if (is_long) Decimal.fromString("1") catch unreachable else Decimal.fromString("999999") catch unreachable;
        const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
        const ord = types.OrderRequest{ .asset = asset, .is_buy = !is_long, .limit_px = px_dec, .sz = sz_dec, .reduce_only = true, .order_type = .{ .limit = .{ .tif = .FrontendMarket } }, .cloid = makeCloid(nonce) };
        const arr = [1]types.OrderRequest{ord};
        var result = client.place(signer, .{ .orders = &arr, .grouping = .na }, nonce, null, null) catch {
            ui.order.setStatus("Close failed (network)", true);
            return;
        };
        defer result.deinit();
        var sb: [48]u8 = undefined;
        const check = checkOrderResult(std.heap.page_allocator, &result, &sb);
        ui.order.setStatus(if (check.ok) "Position closed!" else check.msg, !check.ok);
    }

    fn updateLeverage(ui: *UiState, client: *Client, config: *const Config, shared: *Shared) void {
        const signer = config.getSigner() catch { ui.order.setStatus("No key configured", true); return; };
        const asset: usize = blk: {
            shared.mu.lock();
            defer shared.mu.unlock();
            break :blk shared.asset_index orelse {
                ui.order.setStatus("Asset not resolved", true);
                return;
            };
        };

        const lev = LeverageState.clamp(ui.leverage.value, ui.leverage.max);
        const nonce = @as(u64, @intCast(std.time.milliTimestamp()));
        const ul = types.UpdateLeverage{
            .asset = asset,
            .is_cross = ui.leverage.is_cross,
            .leverage = lev,
        };
        var result = client.updateLeverage(signer, ul, nonce, null, null) catch {
            ui.order.setStatus("Leverage update failed (network)", true);
            return;
        };
        defer result.deinit();

        if (!(result.isOk() catch false)) {
            ui.order.setStatus("Leverage update rejected", true);
            return;
        }

        var msg: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "Leverage set: {d}x ({s})", .{ lev, if (ui.leverage.is_cross) "cross" else "isolated" }) catch "Leverage updated";
        ui.order.setStatus(text, false);

        // Optimistic UI update; REST refresh will reconcile shortly.
        shared.mu.lock();
        defer shared.mu.unlock();
        var lb: [8]u8 = undefined;
        const ls = std.fmt.bufPrint(&lb, "{d}", .{lev}) catch "";
        shared.leverage_len = copyTo(&shared.leverage_buf, ls);
        shared.leverage_is_cross = ui.leverage.is_cross;
        shared.gen += 1;
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  7. REST HELPERS                                                ║
// ╚══════════════════════════════════════════════════════════════════╝

const Rest = struct {
    fn resolveAssetIndex(client: *Client, coin: []const u8, shared: *Shared) void {
        // Check if it's a spot pair (contains /)
        if (std.mem.indexOf(u8, coin, "/") != null) {
            var typed = client.getSpotMeta() catch return;
            defer typed.deinit();
            for (typed.value.universe) |pair| {
                if (std.ascii.eqlIgnoreCase(pair.name, coin)) {
                    shared.mu.lock();
                    defer shared.mu.unlock();
                    shared.asset_index = @intCast(pair.index);
                    shared.max_leverage = 1;
                    return;
                }
            }
        } else {
            // Perp
            var typed = client.getPerps(null) catch return;
            defer typed.deinit();
            for (typed.value.universe, 0..) |pm, idx| {
                if (std.ascii.eqlIgnoreCase(pm.name, coin)) {
                    shared.mu.lock();
                    defer shared.mu.unlock();
                    shared.asset_index = idx;
                    shared.max_leverage = @max(LEVERAGE_MIN, @min(pm.maxLeverage, LEVERAGE_MAX));
                    return;
                }
            }
        }
    }

    fn fetchCandles(client: *Client, coin: []const u8, interval: []const u8, out: *[Chart.MAX_CANDLES]Chart.Candle, count: *usize) void {
        const now: u64 = @intCast(std.time.milliTimestamp());
        const lookback: u64 = if (std.mem.eql(u8, interval, "1m")) 3600_000 * 8
            else if (std.mem.eql(u8, interval, "5m")) 3600_000 * 42
            else if (std.mem.eql(u8, interval, "15m")) 3600_000 * 120
            else if (std.mem.eql(u8, interval, "1h")) 3600_000 * 500
            else if (std.mem.eql(u8, interval, "4h")) 3600_000 * 2000
            else 3600_000 * 8760;
        var typed = client.getCandleSnapshot(coin, interval, now -| lookback, now) catch return;
        defer typed.deinit();
        var n: usize = 0;
        for (typed.value) |candle| {
            if (n >= Chart.MAX_CANDLES) break;
            out[n] = .{
                .t = @as(i64, @intCast(candle.t)),
                .o = decToF64(candle.o), .h = decToF64(candle.h),
                .l = decToF64(candle.l), .c = decToF64(candle.c),
                .v = decToF64(candle.v),
            };
            n += 1;
        }
        count.* = n;
    }

    fn fetchUserData(client: *Client, addr: []const u8, coin: []const u8, shared: *Shared) void {
        var pos = TableData{};
        var ords = TableData{};
        var trades = TableData{};
        var funding = TableData{};
        var ord_hist = TableData{};
        var ab: [24]u8 = undefined;
        var al: usize = 0;
        var mb: [24]u8 = undefined;
        var ml: usize = 0;
        var avb: [24]u8 = undefined;
        var avl: usize = 0;
        var lev_buf: [8]u8 = undefined;
        var lev_len: usize = 0;
        var lev_cross = true;

        // 1. Positions + account value (typed)
        blk_pos: {
            var typed = client.getClearinghouseState(addr, null) catch break :blk_pos;
            defer typed.deinit();
            const state = typed.value;
            var av_str: [24]u8 = undefined;
            var mu_str: [24]u8 = undefined;
            var wd_str: [24]u8 = undefined;
            al = copyTo(&ab, state.marginSummary.accountValue.normalize().toString(&av_str) catch "0");
            ml = copyTo(&mb, state.marginSummary.totalMarginUsed.normalize().toString(&mu_str) catch "0");
            avl = copyTo(&avb, state.withdrawable.normalize().toString(&wd_str) catch "0");
            pos.n_cols = 6;
            pos.setHeader(0, "Coin"); pos.setHeader(1, "Side"); pos.setHeader(2, "Size");
            pos.setHeader(3, "Entry"); pos.setHeader(4, "Lev"); pos.setHeader(5, "uPnL");
            for (state.assetPositions) |ap| {
                if (pos.n_rows >= MAX_ROWS) break;
                const p = ap.position;
                const sz_f = decToF64(p.szi);
                if (sz_f == 0) continue;
                if (std.ascii.eqlIgnoreCase(p.coin, coin)) {
                    if (p.leverage) |lev| {
                        lev_len = (std.fmt.bufPrint(&lev_buf, "{d}", .{lev.value}) catch "").len;
                        lev_cross = !std.ascii.eqlIgnoreCase(lev.type, "isolated");
                    }
                }
                const r = pos.n_rows;
                pos.set(r, 0, p.coin);
                if (sz_f > 0) { pos.set(r, 1, "LONG"); pos.row_colors[r] = .positive; } else { pos.set(r, 1, "SHORT"); pos.row_colors[r] = .negative; }
                var sb: [20]u8 = undefined;
                pos.set(r, 2, std.fmt.bufPrint(&sb, "{d:.4}", .{@abs(sz_f)}) catch "?");
                if (p.entryPx) |ep| { var eb: [20]u8 = undefined; pos.set(r, 3, ep.normalize().toString(&eb) catch "?"); }
                if (p.leverage) |lev| {
                    var lb: [16]u8 = undefined;
                    pos.set(r, 4, std.fmt.bufPrint(&lb, "{d}x {s}", .{ lev.value, lev.type }) catch "?");
                }
                if (p.unrealizedPnl) |pnl| {
                    var pnl_str: [20]u8 = undefined;
                    const pnl_s = pnl.normalize().toString(&pnl_str) catch "0";
                    const roe_f = if (p.returnOnEquity) |roe| decToF64(roe) else 0;
                    var pb: [24]u8 = undefined;
                    pos.set(r, 5, std.fmt.bufPrint(&pb, "{s} ({d:.1}%)", .{ pnl_s, roe_f * 100 }) catch pnl_s);
                    pos.row_colors[r] = if (decToF64(pnl) >= 0) .positive else .negative;
                }
                pos.n_rows += 1;
            }
        }

        // 2. Open orders (typed)
        blk_ords: {
            var typed = client.getOpenOrders(addr, null) catch break :blk_ords;
            defer typed.deinit();
            ords.n_cols = 6;
            ords.setHeader(0, "Coin"); ords.setHeader(1, "Side"); ords.setHeader(2, "Size");
            ords.setHeader(3, "Price"); ords.setHeader(4, "Type"); ords.setHeader(5, "OID");
            for (typed.value) |o| {
                if (ords.n_rows >= MAX_ROWS) break;
                const r = ords.n_rows;
                ords.set(r, 0, o.coin);
                const is_buy = std.mem.eql(u8, o.side, "B");
                ords.set(r, 1, if (is_buy) "Buy" else "Sell");
                ords.row_colors[r] = if (is_buy) .positive else .negative;
                var sz_b: [20]u8 = undefined;
                ords.set(r, 2, o.sz.normalize().toString(&sz_b) catch "?");
                var px_b: [20]u8 = undefined;
                ords.set(r, 3, o.limitPx.normalize().toString(&px_b) catch "?");
                ords.set(r, 4, o.orderType);
                var ob: [20]u8 = undefined;
                ords.set(r, 5, std.fmt.bufPrint(&ob, "{d}", .{o.oid}) catch "?");
                ords.n_rows += 1;
            }
        }

        // 3. Trade History (user fills) — matches Hyperliquid "Trade History" tab
        // 3. Trade History (typed)
        blk_trades: {
            var typed = client.getUserFills(addr) catch break :blk_trades;
            defer typed.deinit();
            trades.n_cols = 7;
            trades.setHeader(0, "Time"); trades.setHeader(1, "Coin"); trades.setHeader(2, "Direction");
            trades.setHeader(3, "Price"); trades.setHeader(4, "Size"); trades.setHeader(5, "Value");
            trades.setHeader(6, "Fee");
            for (typed.value) |f| {
                if (trades.n_rows >= MAX_ROWS) break;
                const r = trades.n_rows;
                if (f.time > 0) {
                    const sec: u64 = @intCast(@mod(@divFloor(@as(i64, @intCast(f.time)), 1000), 86400));
                    var tb: [10]u8 = undefined;
                    trades.set(r, 0, std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ sec / 3600, (sec % 3600) / 60, sec % 60 }) catch "?");
                }
                trades.set(r, 1, f.coin);
                const is_buy = std.mem.eql(u8, f.side, "B");
                trades.set(r, 2, if (f.dir.len > 0) f.dir else if (is_buy) "Open Long" else "Open Short");
                trades.row_colors[r] = if (is_buy) .positive else .negative;
                var px_b: [20]u8 = undefined;
                trades.set(r, 3, f.px.normalize().toString(&px_b) catch "?");
                var sz_b: [20]u8 = undefined;
                trades.set(r, 4, f.sz.normalize().toString(&sz_b) catch "?");
                const val_f = decToF64(f.px) * decToF64(f.sz);
                var vb: [20]u8 = undefined;
                trades.set(r, 5, std.fmt.bufPrint(&vb, "{d:.2}", .{val_f}) catch "?");
                var fee_b: [20]u8 = undefined;
                trades.set(r, 6, f.fee.normalize().toString(&fee_b) catch "?");
                trades.n_rows += 1;
            }
        }

        // 4. Funding History (typed)
        blk_fund: {
            const now: u64 = @intCast(std.time.milliTimestamp());
            var typed = client.getUserFunding(addr, now -| 86400_000 * 7, null) catch break :blk_fund;
            defer typed.deinit();
            funding.n_cols = 5;
            funding.setHeader(0, "Time"); funding.setHeader(1, "Coin"); funding.setHeader(2, "Size");
            funding.setHeader(3, "Payment"); funding.setHeader(4, "Rate");
            for (typed.value) |f| {
                if (funding.n_rows >= MAX_ROWS) break;
                const r = funding.n_rows;
                if (f.time > 0) {
                    const sec: u64 = @intCast(@mod(@divFloor(@as(i64, @intCast(f.time)), 1000), 86400));
                    var tb: [10]u8 = undefined;
                    funding.set(r, 0, std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ sec / 3600, (sec % 3600) / 60, sec % 60 }) catch "?");
                }
                funding.set(r, 1, f.delta.coin);
                var sz_b: [20]u8 = undefined;
                funding.set(r, 2, f.delta.szi.normalize().toString(&sz_b) catch "?");
                var usdc_b: [20]u8 = undefined;
                const usdc_s = f.delta.usdc.normalize().toString(&usdc_b) catch "0";
                funding.set(r, 3, usdc_s);
                funding.row_colors[r] = if (decToF64(f.delta.usdc) >= 0) .positive else .negative;
                var rate_b: [20]u8 = undefined;
                funding.set(r, 4, f.delta.fundingRate.normalize().toString(&rate_b) catch "?");
                funding.n_rows += 1;
            }
        }

        // 5. Order History (typed)
        blk_hist: {
            var typed = client.getHistoricalOrders(addr) catch break :blk_hist;
            defer typed.deinit();
            ord_hist.n_cols = 7;
            ord_hist.setHeader(0, "Time"); ord_hist.setHeader(1, "Coin"); ord_hist.setHeader(2, "Side");
            ord_hist.setHeader(3, "Size"); ord_hist.setHeader(4, "Price"); ord_hist.setHeader(5, "Status");
            ord_hist.setHeader(6, "OID");
            for (typed.value) |ho| {
                if (ord_hist.n_rows >= MAX_ROWS) break;
                const r = ord_hist.n_rows;
                const o = ho.order;
                ord_hist.set(r, 1, o.coin);
                const is_buy = std.mem.eql(u8, o.side, "B");
                ord_hist.set(r, 2, if (is_buy) "Buy" else "Sell");
                ord_hist.row_colors[r] = if (is_buy) .positive else .negative;
                var sz_b: [20]u8 = undefined;
                ord_hist.set(r, 3, o.sz.normalize().toString(&sz_b) catch "?");
                var px_b: [20]u8 = undefined;
                ord_hist.set(r, 4, o.limitPx.normalize().toString(&px_b) catch "?");
                ord_hist.set(r, 5, ho.status);
                if (std.mem.indexOf(u8, ho.status, "ejected") != null) ord_hist.row_colors[r] = .negative;
                var ob: [20]u8 = undefined;
                ord_hist.set(r, 6, std.fmt.bufPrint(&ob, "{d}", .{o.oid}) catch "?");
                if (ho.statusTimestamp > 0) {
                    const sec: u64 = @intCast(@mod(@divFloor(@as(i64, @intCast(ho.statusTimestamp)), 1000), 86400));
                    var tb: [10]u8 = undefined;
                    ord_hist.set(r, 0, std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ sec / 3600, (sec % 3600) / 60, sec % 60 }) catch "?");
                }
                ord_hist.n_rows += 1;
            }
        }
        shared.mu.lock();
        defer shared.mu.unlock();
        shared.positions = pos;
        shared.open_orders = ords;
        shared.trade_history = trades;
        shared.funding_history = funding;
        shared.order_history = ord_hist;
        shared.acct_buf = ab;
        shared.acct_len = al;
        shared.margin_buf = mb;
        shared.margin_len = ml;
        shared.avail_buf = avb;
        shared.avail_len = avl;
        shared.leverage_buf = lev_buf;
        shared.leverage_len = lev_len;
        shared.leverage_is_cross = lev_cross;
        shared.gen += 1;
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  8. UTILS                                                       ║
// ╚══════════════════════════════════════════════════════════════════╝

fn decToF64(d: Decimal) f64 {
    const m: f64 = @floatFromInt(d.mantissa);
    const s: f64 = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(d.scale)));
    return m / s;
}

fn fmtTimestamp(obj: std.json.Value, key: []const u8, buf: *[10]u8) []const u8 {
    const ts: i64 = if (obj == .object) blk: {
        const v = obj.object.get(key) orelse break :blk @as(i64, 0);
        break :blk switch (v) {
            .integer => v.integer,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
            else => 0,
        };
    } else 0;
    if (ts <= 0) return "";
    const sec: u64 = @intCast(@mod(@divFloor(ts, 1000), 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ sec / 3600, (sec % 3600) / 60, sec % 60 }) catch "?";
}

fn checkOrderResult(alloc: std.mem.Allocator, result: *Client.ExchangeResult, status_buf: *[48]u8) struct { ok: bool, msg: []const u8 } {
    const val = result.json() catch return .{ .ok = false, .msg = "Parse error" };
    const statuses = response.parseOrderStatuses(alloc, val) catch return .{ .ok = false, .msg = "Parse error" };
    defer alloc.free(statuses);
    if (statuses.len == 0) {
        // Fall back to top-level status
        return .{ .ok = result.isOk() catch false, .msg = "Unknown response" };
    }
    return switch (statuses[0]) {
        .resting => .{ .ok = true, .msg = "Order resting" },
        .filled => .{ .ok = true, .msg = "Order filled!" },
        .success => .{ .ok = true, .msg = "Order accepted" },
        .@"error" => |e| blk: {
            const n = @min(e.len, 48);
            @memcpy(status_buf[0..n], e[0..n]);
            break :blk .{ .ok = false, .msg = status_buf[0..n] };
        },
        .unknown => .{ .ok = false, .msg = "Unknown status" },
    };
}

fn fmtF64(buf: *[12]u8, v: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "?";
}

fn samplePerf(ui: *UiState) bool {
    const now = std.time.milliTimestamp();
    if (ui.perf_last_ms != 0 and now - ui.perf_last_ms < PERF_SAMPLE_MS) return false;
    ui.perf_last_ms = now;

    const rss_kb = currentRssKb();
    if (rss_kb == ui.rss_kb and !ui.show_perf) return false;
    ui.rss_kb = rss_kb;
    if (rss_kb > ui.peak_rss_kb) ui.peak_rss_kb = rss_kb;
    return true;
}

fn currentRssKb() u64 {
    return switch (builtin.os.tag) {
        .macos => currentRssKbMac(),
        .linux => currentRssKbLinux(),
        else => 0,
    };
}

const ProcTaskInfo = extern struct {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
};

extern fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn currentRssKbMac() u64 {
    const PROC_PIDTASKINFO: c_int = 4;
    var ti: ProcTaskInfo = undefined;
    const pid: c_int = std.c.getpid();
    const rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(ProcTaskInfo));
    if (rc <= 0) return 0;
    return ti.pti_resident_size / 1024;
}

fn currentRssKbLinux() u64 {
    var file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return 0;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return 0;
    if (n == 0) return 0;
    var it = std.mem.tokenizeAny(u8, buf[0..n], " \t\r\n");
    _ = it.next() orelse return 0; // total pages
    const rss_pages_s = it.next() orelse return 0;
    const rss_pages = std.fmt.parseInt(u64, rss_pages_s, 10) catch return 0;
    const page_kb: u64 = std.heap.page_size_min / 1024;
    return rss_pages * page_kb;
}

fn buildInfoFromCtx(ctx: resp_types.AssetContext) InfoData {
    var info = InfoData{};
    if (ctx.markPx) |mp| { var b: [24]u8 = undefined; info.mark_len = copyTo(&info.mark_buf, mp.normalize().toString(&b) catch "0"); }
    if (ctx.oraclePx) |op| { var b: [24]u8 = undefined; info.oracle_len = copyTo(&info.oracle_buf, op.normalize().toString(&b) catch "0"); }
    { var b: [24]u8 = undefined; info.oi_len = copyTo(&info.oi_buf, ctx.openInterest.normalize().toString(&b) catch "0"); }
    { var b: [24]u8 = undefined; info.funding_len = copyTo(&info.funding_buf, ctx.funding.normalize().toString(&b) catch "0"); }
    const prev_f = if (ctx.prevDayPx) |pp| decToF64(pp) else 0;
    const mark_f = if (ctx.markPx) |mp| decToF64(mp) else 0;
    if (prev_f > 0) {
        const chg = mark_f - prev_f;
        info.is_negative_change = chg < 0;
        info.change_len = (std.fmt.bufPrint(&info.change_buf, "{d:.0} / {d:.2}%", .{ chg, chg / prev_f * 100 }) catch "").len;
    }
    const vol_f = if (ctx.dayNtlVlm) |v| decToF64(v) else 0;
    const vs = if (vol_f > 1e9) std.fmt.bufPrint(&info.volume_buf, "${d:.2}B", .{vol_f / 1e9}) catch ""
        else if (vol_f > 1e6) std.fmt.bufPrint(&info.volume_buf, "${d:.1}M", .{vol_f / 1e6}) catch ""
        else std.fmt.bufPrint(&info.volume_buf, "${d:.0}", .{vol_f}) catch "";
    info.volume_len = vs.len;
    return info;
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  9. MAIN LOOP                                                   ║
// ╚══════════════════════════════════════════════════════════════════╝

pub fn run(allocator: std.mem.Allocator, config_in: Config, coin: []const u8) !void {
    var config = config_in;
    var ui = UiState{};
    ui.coin_len = @min(coin.len, 16);
    for (0..ui.coin_len) |i| ui.coin[i] = std.ascii.toUpper(coin[i]);

    var ui_client = switch (config.chain) { .mainnet => Client.mainnet(allocator), .testnet => Client.testnet(allocator) };
    defer ui_client.deinit();
    var worker_client = switch (config.chain) { .mainnet => Client.mainnet(allocator), .testnet => Client.testnet(allocator) };
    defer worker_client.deinit();

    var app = App.init(allocator) catch {
        std.fs.File.stderr().writeAll("error: requires an interactive terminal\n") catch {};
        return;
    };
    defer app.deinit();

    var shared = Shared{};
    shared.setInterval(ui.interval);
    { shared.mu.lock(); defer shared.mu.unlock(); shared.setCoin(ui.coin[0..ui.coin_len]); }

    const ws_w = std.Thread.spawn(.{}, WsWorker.run, .{ &shared, allocator, config.chain }) catch return;
    const rest_w = std.Thread.spawn(.{}, RestWorker.run, .{ &shared, &worker_client, config.getAddress() }) catch return;
    defer {
        shared.running.store(false, .release);
        const fd = shared.ws_fd.load(.acquire);
        if (fd != -1) _ = std.c.shutdown(fd, 2);
        ws_w.join();
        rest_w.join();
    }

    var last_gen: u64 = 0;

    while (app.running) {
        // 1. Input
        var dirty = false;
        while (app.pollKey()) |key| {
            if (ui.coin_picking) Input.handleCoinPicker(key, &ui, &shared)
            else if (key == .char and key.char == '/') { ui.coin_picking = true; ui.coin_input_len = 0; }
            else Input.handleKey(key, &ui, &app.running, &ui_client, &config, &shared);
            dirty = true;
        }
        if (ui.order.expireStatus(std.time.milliTimestamp(), STATUS_TTL_MS)) dirty = true;
        if (!app.running) break;

        // 2. Sync UI → shared
        var iv_changed = false;
        {
            shared.mu.lock();
            defer shared.mu.unlock();
            if (!std.mem.eql(u8, shared.iv_buf[0..shared.iv_len], ui.interval)) iv_changed = true;
            shared.setInterval(ui.interval);
            shared.depth = ui.book_depth;
        }
        if (iv_changed) { const fd = shared.ws_fd.load(.acquire); if (fd != -1) _ = std.c.shutdown(fd, 2); }

        // 3. Clamp selection + auto-scroll
        {
            const s = Snapshot.take(&shared);
            const tbl: *const TableData = switch (ui.tab) {
                .positions => &s.positions, .open_orders => &s.open_orders,
                .trade_history => &s.trade_history, .funding_history => &s.funding_history,
                .order_history => &s.order_history,
            };
            if (tbl.n_rows > 0) {
                ui.selected_row = @min(ui.selected_row, tbl.n_rows - 1);
            } else ui.selected_row = 0;

            // visible rows = bottom panel height - tabs(2) - header(1) - helpbar(1) = bottom_h - 4
            const h = app.height();
            const bottom_h = @max(6, h / 5);
            const vis = if (bottom_h > 4) bottom_h - 4 else 1;

            const max_scroll = if (tbl.n_rows > vis) tbl.n_rows - vis else 0;
            if (ui.scroll_offset > max_scroll) ui.scroll_offset = max_scroll;
            if (ui.selected_row >= ui.scroll_offset + vis) ui.scroll_offset = ui.selected_row + 1 -| vis;
            if (ui.selected_row < ui.scroll_offset) ui.scroll_offset = ui.selected_row;
        }

        // 4. Snapshot + render
        const snap = Snapshot.take(&shared);
        if (snap.gen != last_gen or dirty) {
            last_gen = snap.gen;
            Render.frame(&app, &ui, &snap);
            if (ui.coin_picking) Render.coinPickerOverlay(&app, &ui);
        }

        // 4. Sleep
        std.Thread.sleep(4_000_000);
    }
}
