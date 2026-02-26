const std = @import("std");
const hyperzig = @import("hyperzig");
const client_mod = hyperzig.hypercore.client;
const json_mod = hyperzig.hypercore.json;
const ws_types = hyperzig.hypercore.ws;
const signing = hyperzig.hypercore.signing;
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

    pub fn getSigner(self: Config) !Signer { return Signer.fromHex(self.key_hex orelse return error.MissingKey); }
    pub fn getAddress(self: Config) ?[]const u8 { return self.address; }
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

const ActiveTab = enum(u3) { positions, orders, trades, funding, history };
const FocusPanel = enum(u3) { chart, book, tape, order_entry, bottom };
const OrderSide = enum { buy, sell };
const OrderType = enum { market, limit };
const OrderField = enum { size, price };

const MAX_ROWS = 32;
const MAX_COLS = 8;
const CELL_SZ = 24;

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

    fn sizeStr(self: *const OrderState) []const u8 { return self.size_buf[0..self.size_len]; }
    fn priceStr(self: *const OrderState) []const u8 { return self.price_buf[0..self.price_len]; }
    fn statusStr(self: *const OrderState) []const u8 { return self.status_buf[0..self.status_len]; }
    fn setStatus(self: *OrderState, msg: []const u8, err: bool) void {
        const n = @min(msg.len, 48);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_len = n;
        self.status_is_error = err;
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
    orders: TableData = .{},
    fills: TableData = .{},
    acct_buf: [24]u8 = undefined,
    acct_len: usize = 0,
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
    orders: TableData,
    fills: TableData,
    acct_buf: [24]u8,
    acct_len: usize,

    fn take(s: *Shared) Snapshot {
        s.mu.lock();
        defer s.mu.unlock();
        return .{
            .gen = s.gen,
            .candles = s.candles, .candle_count = s.candle_count,
            .info = s.info,
            .bids = s.bids, .asks = s.asks, .n_bids = s.n_bids, .n_asks = s.n_asks, .max_cum = s.max_cum,
            .trades = s.trades,
            .positions = s.positions, .orders = s.orders, .fills = s.fills,
            .acct_buf = s.acct_buf, .acct_len = s.acct_len,
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
                        switch (msg.channel) {
                            .l2Book => decodeAndApplyBook(data, shared, depth),
                            .trades => decodeAndApplyTrades(data, shared),
                            .candle => decodeAndApplyCandle(data, shared),
                            .activeAssetCtx => decodeAndApplyInfo(data, shared),
                            else => {},
                        }
                    },
                }
            }
            shared.ws_fd.store(-1, .release);
            std.Thread.sleep(100_000_000);
        }
    }

    // ── Decode + Apply (parse outside lock, apply under lock) ──

    fn decodeAndApplyBook(data: []const u8, shared: *Shared, depth: usize) void {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
        defer parsed.deinit();
        const levels = json_mod.getArray(parsed.value, "levels") orelse return;
        if (levels.len < 2) return;
        const bids_raw = if (levels[0] == .array) levels[0].array.items else return;
        const asks_raw = if (levels[1] == .array) levels[1].array.items else return;

        var bids: [64]BookLevel = undefined;
        var asks: [64]BookLevel = undefined;
        const eff = @min(depth, @min(bids_raw.len, @min(asks_raw.len, 64)));
        var bid_cum: f64 = 0;
        var ask_cum: f64 = 0;
        for (0..eff) |i| {
            const bpx = json_mod.getString(bids_raw[i], "px") orelse "0";
            const bsz_s = json_mod.getString(bids_raw[i], "sz") orelse "0";
            const bsz = std.fmt.parseFloat(f64, bsz_s) catch 0;
            bid_cum += bsz;
            bids[i] = .{ .sz = bsz, .cum = bid_cum };
            bids[i].px_len = copyTo(&bids[i].px_buf, bpx);
            bids[i].sz_len = copyTo(&bids[i].sz_buf, bsz_s);

            const apx = json_mod.getString(asks_raw[i], "px") orelse "0";
            const asz_s = json_mod.getString(asks_raw[i], "sz") orelse "0";
            const asz = std.fmt.parseFloat(f64, asz_s) catch 0;
            ask_cum += asz;
            asks[i] = .{ .sz = asz, .cum = ask_cum };
            asks[i].px_len = copyTo(&asks[i].px_buf, apx);
            asks[i].sz_len = copyTo(&asks[i].sz_buf, asz_s);
        }
        shared.applyBook(bids, asks, eff, @max(bid_cum, ask_cum));
    }

    fn decodeAndApplyTrades(data: []const u8, shared: *Shared) void {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
        defer parsed.deinit();
        const arr = if (parsed.value == .array) parsed.value.array.items else return;
        const new_count = @min(arr.len, MAX_ROWS);

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
            const trade = arr[idx];
            if (trade == .object) if (trade.object.get("time")) |tv| switch (tv) {
                .integer => |ts| {
                    const ds: u64 = @intCast(@divFloor(ts, 1000));
                    const s = ds % 86400;
                    var tb: [10]u8 = undefined;
                    const t = std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, (s % 3600) / 60, s % 60 }) catch "?";
                    shared.trades.set(idx, 0, t);
                },
                else => {},
            };
            if (json_mod.getString(trade, "px")) |p| shared.trades.set(idx, 1, p);
            if (json_mod.getString(trade, "sz")) |sz| shared.trades.set(idx, 2, sz);
            if (json_mod.getString(trade, "side")) |side| {
                const is_buy = std.mem.eql(u8, side, "B");
                shared.trades.set(idx, 3, if (is_buy) "BUY" else "SELL");
                shared.trades.row_colors[idx] = if (is_buy) .positive else .negative;
            }
        }
        shared.trades.n_rows = total;
        shared.gen += 1;
    }

    fn decodeAndApplyCandle(data: []const u8, shared: *Shared) void {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
        defer parsed.deinit();
        const val = parsed.value;
        const t: i64 = if (val == .object) if (val.object.get("t")) |tv| switch (tv) { .integer => |i| i, else => 0 } else 0 else 0;
        if (t == 0) return;
        shared.applyCandle(.{
            .t = t,
            .o = parseFloat(val, "o"), .h = parseFloat(val, "h"),
            .l = parseFloat(val, "l"), .c = parseFloat(val, "c"),
            .v = parseFloat(val, "v"),
        });
    }

    fn decodeAndApplyInfo(data: []const u8, shared: *Shared) void {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{}) catch return;
        defer parsed.deinit();
        const ctx = if (parsed.value == .object) parsed.value.object.get("ctx") orelse return else return;
        shared.applyInfo(buildInfoFromCtx(ctx));
    }
};

const RestWorker = struct {
    fn run(shared: *Shared, client: *Client, user_addr: ?[]const u8) void {
        var last_ms: i64 = 0;
        var prev_gen: u64 = 0;

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

    fn handleKey(key: @import("Terminal").Key, ui: *UiState, running: *bool, client: *Client, config: *const Config) void {
        if (ui.focus == .order_entry) return handleOrderKey(key, ui, client, config);
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
                '1' => ui.tab = .positions, '2' => ui.tab = .orders,
                '3' => ui.tab = .trades, '4' => ui.tab = .funding, '5' => ui.tab = .history,
                'h' => ui.chart_scroll += 10, 'l' => ui.chart_scroll = ui.chart_scroll -| 10,
                'H' => ui.chart_scroll += 50, 'L' => ui.chart_scroll = ui.chart_scroll -| 50,
                '0' => ui.chart_scroll = 0,
                '+', '=' => ui.book_depth = @min(ui.book_depth + 5, 40),
                '-', '_' => ui.book_depth = if (ui.book_depth > 5) ui.book_depth - 5 else 5,
                else => {},
            },
            .tab => ui.focus = @enumFromInt((@intFromEnum(ui.focus) + 1) % 5),
            .esc => { running.* = false; },
            .left => ui.chart_scroll += 5,
            .right => ui.chart_scroll = ui.chart_scroll -| 5,
            .up => if (ui.focus == .bottom) { const v = @intFromEnum(ui.tab); ui.tab = if (v > 0) @enumFromInt(v - 1) else .history; },
            .down => if (ui.focus == .bottom) { const v = @intFromEnum(ui.tab); ui.tab = if (v < 4) @enumFromInt(v + 1) else .positions; },
            else => {},
        }
    }

    fn handleOrderKey(key: @import("Terminal").Key, ui: *UiState, client: *Client, config: *const Config) void {
        const o = &ui.order;
        switch (key) {
            .char => |c| switch (c) {
                '0'...'9', '.' => o.appendToActive(c),
                'b', 'B' => o.side = .buy,
                's', 'S' => o.side = .sell,
                'm', 'M' => { o.order_type = if (o.order_type == .market) .limit else .market; if (o.order_type == .limit) o.field = .size; },
                'q' => { ui.focus = .chart; },
                else => {},
            },
            .backspace => o.backspaceActive(),
            .enter => Orders.execute(o, client, ui.coin[0..ui.coin_len], config),
            .tab => {
                if (o.order_type == .limit and o.field == .size) o.field = .price
                else { o.field = .size; ui.focus = .bottom; }
            },
            .up, .down => if (o.order_type == .limit) { o.field = if (o.field == .size) .price else .size; },
            .esc => ui.focus = .chart,
            else => {},
        }
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
        orderPanel(buf, ui.coin[0..ui.coin_len], snap.accountValue(), &ui.order, ui.focus == .order_entry, order_rect);
        bottomTabs(buf, ui.tab, &snap.positions, &snap.orders, &snap.trades, &snap.fills, bottom_rect);

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
        buf.putStr(w -| @as(u16, @intCast(badge.len)) -| 1, 0, badge, .{ .fg = hl_text, .bg = hl_accent, .bold = true });

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
        const hint = "i:interval  \xe2\x86\x90\xe2\x86\x92:scroll  Tab:panel";
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

    fn orderPanel(buf: *Buffer, coin: []const u8, acct: ?[]const u8, o: *const OrderState, focused: bool, rect: Rect) void {
        buf.drawBox(rect, "Order Entry", if (focused) s_cyan else Style{ .fg = hl_accent });
        if (rect.h < 5) return;
        const ix = rect.x + 2;
        const iw = rect.w -| 4;
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
        // Equity
        if (acct) |av| {
            buf.putStr(ix, y, "Equity", s_dim);
            buf.putStr(ix + 10, y, av, s_bold);
            buf.putStr(ix + 10 + @as(u16, @intCast(@min(av.len, 16))), y, " USDC", s_dim);
        }
        y += 1;
        // Status
        const st = o.statusStr();
        if (st.len > 0) { buf.putStr(ix, y, st, if (o.status_is_error) s_bold_red else s_bold_green); y += 1; }
        // Button
        if (y < rect.y + rect.h - 1) {
            const bg = if (o.side == .buy) hl_buy else hl_sell;
            const bl = if (o.side == .buy) " \xe2\x8f\x8e Place Buy " else " \xe2\x8f\x8e Place Sell ";
            const bw: u16 = @min(rect.w -| 4, @as(u16, @intCast(bl.len)) + 2);
            const bx = ix + (rect.w -| 4 -| bw) / 2;
            var bi: u16 = 0;
            while (bi < bw) : (bi += 1) buf.putStr(bx + bi, y, " ", .{ .bg = bg });
            buf.putStr(bx + 1, y, bl, .{ .fg = hl_text, .bg = bg, .bold = true });
        }
    }

    fn bottomTabs(buf: *Buffer, active: ActiveTab, positions: *const TableData, ord: *const TableData, trades: *const TableData, fills: *const TableData, rect: Rect) void {
        const tabs = [_][]const u8{ " Positions ", " Orders ", " Trades ", " Funding ", " History " };
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
        const tbl = switch (active) {
            .positions => positions, .orders => ord,
            .trades, .history => trades, .funding => fills,
        };
        if (tbl.n_rows == 0) {
            buf.putStr(cr.x + 2, cr.y, switch (active) {
                .positions => "No open positions", .orders => "No open orders",
                .trades => "No recent trades", .funding => "No recent fills", .history => "No recent trades",
            }, s_dim);
        } else table(buf, tbl, cr);
        buf.putStr(rect.x + 1, rect.y + rect.h - 1, "q:quit  /:coin  Tab:panel  i:interval  \xe2\x86\x90\xe2\x86\x92:scroll  0:snap  +/-:depth", s_dim);
    }

    fn table(buf: *Buffer, tbl: *const TableData, rect: Rect) void {
        if (tbl.n_cols == 0) return;
        const n: u16 = @intCast(tbl.n_cols);
        const cw = @max(6, (rect.w -| 2) / n);
        for (0..tbl.n_cols) |c| {
            const hx = rect.x + @as(u16, @intCast(c)) * cw + 1;
            if (hx >= rect.x + rect.w) break;
            const hdr = tbl.getHeader(c);
            buf.putStr(hx, rect.y, hdr[0..@min(hdr.len, cw -| 1)], s_dim);
        }
        for (0..@min(tbl.n_rows, rect.h -| 1)) |r| {
            const ry = rect.y + 1 + @as(u16, @intCast(r));
            if (ry >= rect.y + rect.h) break;
            const rs: Style = switch (tbl.row_colors[r]) { .positive => s_green, .negative => s_red, .neutral => s_white };
            for (0..tbl.n_cols) |c| {
                const cx = rect.x + @as(u16, @intCast(c)) * cw + 1;
                if (cx >= rect.x + rect.w) break;
                const val = tbl.get(r, c);
                const mw = @min(val.len, @min(cw -| 1, rect.x + rect.w -| cx -| 1));
                buf.putStr(cx, ry, val[0..mw], if (c == 0 or c == tbl.n_cols - 1) rs else s_white);
            }
        }
    }

    fn label(buf: *Buffer, x: u16, y: u16, lbl: []const u8, val: []const u8, style: Style) u16 {
        buf.putStr(x, y, lbl, s_dim);
        const lx = x + @as(u16, @intCast(lbl.len)) + 1;
        buf.putStr(lx, y, val, style);
        return lx + @as(u16, @intCast(@min(val.len, 20))) + 2;
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  6. ORDERS                                                      ║
// ╚══════════════════════════════════════════════════════════════════╝

const Orders = struct {
    fn execute(order: *OrderState, client: *Client, coin: []const u8, config: *const Config) void {
        _ = coin;
        const signer = config.getSigner() catch { order.setStatus("No key configured", true); return; };
        const sz_str = order.sizeStr();
        if (sz_str.len == 0) { order.setStatus("Enter size first", true); return; }
        const sz = std.fmt.parseFloat(f64, sz_str) catch { order.setStatus("Invalid size", true); return; };
        if (sz <= 0) { order.setStatus("Size must be > 0", true); return; }

        const zig = @import("hyperzig");
        const types = zig.hypercore.types;
        const Decimal = zig.math.decimal.Decimal;
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
        const ord = types.OrderRequest{ .asset = 0, .is_buy = order.side == .buy, .limit_px = px_dec, .sz = sz_dec, .reduce_only = false, .order_type = .{ .limit = .{ .tif = tif } }, .cloid = types.ZERO_CLOID };
        const arr = [1]types.OrderRequest{ord};
        var result = client.place(signer, .{ .orders = &arr, .grouping = .na }, nonce, null, null) catch {
            order.setStatus("Order failed (network)", true);
            return;
        };
        defer result.deinit();
        if (result.status == .ok) {
            order.setStatus(if (order.order_type == .market) "Market order sent!" else "Limit order sent!", false);
            order.size_len = 0;
            if (order.order_type == .limit) order.price_len = 0;
        } else order.setStatus("Order rejected", true);
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  7. REST HELPERS                                                ║
// ╚══════════════════════════════════════════════════════════════════╝

const Rest = struct {
    fn fetchCandles(client: *Client, coin: []const u8, interval: []const u8, out: *[Chart.MAX_CANDLES]Chart.Candle, count: *usize) void {
        const now: u64 = @intCast(std.time.milliTimestamp());
        const lookback: u64 = if (std.mem.eql(u8, interval, "1m")) 3600_000 * 8
            else if (std.mem.eql(u8, interval, "5m")) 3600_000 * 42
            else if (std.mem.eql(u8, interval, "15m")) 3600_000 * 120
            else if (std.mem.eql(u8, interval, "1h")) 3600_000 * 500
            else if (std.mem.eql(u8, interval, "4h")) 3600_000 * 2000
            else 3600_000 * 8760;
        var result = client.candleSnapshot(coin, interval, now -| lookback, now) catch return;
        defer result.deinit();
        const val = result.json() catch return;
        const arr = if (val == .array) val.array.items else return;
        var n: usize = 0;
        for (arr) |item| {
            if (n >= Chart.MAX_CANDLES) break;
            out[n] = .{
                .t = if (item == .object) if (item.object.get("t")) |v| switch (v) { .integer => |i| i, else => 0 } else 0 else 0,
                .o = parseFloat(item, "o"), .h = parseFloat(item, "h"),
                .l = parseFloat(item, "l"), .c = parseFloat(item, "c"),
                .v = parseFloat(item, "v"),
            };
            n += 1;
        }
        count.* = n;
    }

    fn fetchUserData(client: *Client, addr: []const u8, coin: []const u8, shared: *Shared) void {
        var pos = TableData{};
        var ords = TableData{};
        var fills = TableData{};
        var ab: [24]u8 = undefined;
        var al: usize = 0;

        // Positions + account value
        blk_pos: {
            var result = client.clearinghouseState(addr, null) catch break :blk_pos;
            defer result.deinit();
            const val = result.json() catch break :blk_pos;
            if (val == .object) if (val.object.get("marginSummary")) |ms| {
                if (json_mod.getString(ms, "accountValue")) |av| al = copyTo(&ab, av);
            };
            pos.n_cols = 6;
            pos.setHeader(0, "Coin"); pos.setHeader(1, "Side"); pos.setHeader(2, "Size");
            pos.setHeader(3, "Entry"); pos.setHeader(4, "Mark"); pos.setHeader(5, "uPnL");
            if (json_mod.getArray(val, "assetPositions")) |aps| for (aps) |ap| {
                if (pos.n_rows >= MAX_ROWS) break;
                const p = if (ap == .object) (ap.object.get("position") orelse continue) else continue;
                const szi = json_mod.getString(p, "szi") orelse "0";
                const sz_f = std.fmt.parseFloat(f64, szi) catch 0;
                if (sz_f == 0) continue;
                _ = coin;
                const r = pos.n_rows;
                if (json_mod.getString(p, "coin")) |c| pos.set(r, 0, c);
                if (sz_f > 0) { pos.set(r, 1, "LONG"); pos.row_colors[r] = .positive; } else { pos.set(r, 1, "SHORT"); pos.row_colors[r] = .negative; }
                var sb: [20]u8 = undefined;
                pos.set(r, 2, std.fmt.bufPrint(&sb, "{d:.4}", .{@abs(sz_f)}) catch "?");
                if (json_mod.getString(p, "entryPx")) |ep| pos.set(r, 3, ep);
                pos.set(r, 4, "\xe2\x80\x94");
                if (json_mod.getString(p, "unrealizedPnl")) |pnl| {
                    pos.set(r, 5, pnl);
                    pos.row_colors[r] = if ((std.fmt.parseFloat(f64, pnl) catch 0) >= 0) .positive else .negative;
                }
                pos.n_rows += 1;
            };
        }

        // Open orders
        blk_ords: {
            var result = client.openOrders(addr, null) catch break :blk_ords;
            defer result.deinit();
            const val = result.json() catch break :blk_ords;
            const arr = if (val == .array) val.array.items else break :blk_ords;
            ords.n_cols = 6;
            ords.setHeader(0, "Coin"); ords.setHeader(1, "Side"); ords.setHeader(2, "Size");
            ords.setHeader(3, "Price"); ords.setHeader(4, "Type"); ords.setHeader(5, "OID");
            for (arr) |o| {
                if (ords.n_rows >= MAX_ROWS) break;
                const r = ords.n_rows;
                if (json_mod.getString(o, "coin")) |c| ords.set(r, 0, c);
                if (json_mod.getString(o, "side")) |s| { ords.set(r, 1, s); ords.row_colors[r] = if (std.mem.eql(u8, s, "B")) .positive else .negative; }
                if (json_mod.getString(o, "sz")) |s| ords.set(r, 2, s);
                if (json_mod.getString(o, "limitPx")) |p| ords.set(r, 3, p);
                if (json_mod.getString(o, "orderType")) |t| ords.set(r, 4, t);
                if (o == .object) if (o.object.get("oid")) |oid| switch (oid) {
                    .integer => |i| { var ob: [20]u8 = undefined; ords.set(r, 5, std.fmt.bufPrint(&ob, "{d}", .{i}) catch "?"); },
                    else => {},
                };
                ords.n_rows += 1;
            }
        }

        // Fills
        blk_fills: {
            var result = client.userFills(addr) catch break :blk_fills;
            defer result.deinit();
            const val = result.json() catch break :blk_fills;
            const arr = if (val == .array) val.array.items else break :blk_fills;
            fills.n_cols = 6;
            fills.setHeader(0, "Coin"); fills.setHeader(1, "Side"); fills.setHeader(2, "Size");
            fills.setHeader(3, "Price"); fills.setHeader(4, "Fee"); fills.setHeader(5, "Time");
            for (arr) |f| {
                if (fills.n_rows >= MAX_ROWS) break;
                const r = fills.n_rows;
                if (json_mod.getString(f, "coin")) |c| fills.set(r, 0, c);
                if (json_mod.getString(f, "side")) |s| {
                    const ib = std.mem.eql(u8, s, "B");
                    fills.set(r, 1, if (ib) "BUY" else "SELL");
                    fills.row_colors[r] = if (ib) .positive else .negative;
                }
                if (json_mod.getString(f, "sz")) |s| fills.set(r, 2, s);
                if (json_mod.getString(f, "px")) |p| fills.set(r, 3, p);
                if (json_mod.getString(f, "fee")) |fe| fills.set(r, 4, fe);
                if (json_mod.getString(f, "time")) |t| {
                    const ts = std.fmt.parseInt(i64, t, 10) catch 0;
                    if (ts > 0) {
                        const ds: u64 = @intCast(@divFloor(ts, 1000));
                        const sec = ds % 86400;
                        var tb: [10]u8 = undefined;
                        fills.set(r, 5, std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ sec / 3600, (sec % 3600) / 60, sec % 60 }) catch "?");
                    }
                }
                fills.n_rows += 1;
            }
        }

        shared.mu.lock();
        defer shared.mu.unlock();
        shared.positions = pos;
        shared.orders = ords;
        shared.fills = fills;
        shared.acct_buf = ab;
        shared.acct_len = al;
        shared.gen += 1;
    }
};

// ╔══════════════════════════════════════════════════════════════════╗
// ║  8. UTILS                                                       ║
// ╚══════════════════════════════════════════════════════════════════╝

fn parseFloat(obj: std.json.Value, key: []const u8) f64 {
    return std.fmt.parseFloat(f64, json_mod.getString(obj, key) orelse return 0) catch 0;
}

fn fmtF64(buf: *[12]u8, v: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "?";
}

fn buildInfoFromCtx(ctx: std.json.Value) InfoData {
    var info = InfoData{};
    if (json_mod.getString(ctx, "markPx")) |s| info.mark_len = copyTo(&info.mark_buf, s);
    if (json_mod.getString(ctx, "oraclePx")) |s| info.oracle_len = copyTo(&info.oracle_buf, s);
    if (json_mod.getString(ctx, "openInterest")) |s| info.oi_len = copyTo(&info.oi_buf, s);
    if (json_mod.getString(ctx, "funding")) |s| info.funding_len = copyTo(&info.funding_buf, s);
    const prev_str = json_mod.getString(ctx, "prevDayPx") orelse "0";
    const mark_str = info.mark();
    const prev_f = std.fmt.parseFloat(f64, prev_str) catch 0;
    const mark_f = std.fmt.parseFloat(f64, mark_str) catch 0;
    if (prev_f > 0) {
        const chg = mark_f - prev_f;
        info.is_negative_change = chg < 0;
        info.change_len = (std.fmt.bufPrint(&info.change_buf, "{d:.0} / {d:.2}%", .{ chg, chg / prev_f * 100 }) catch "").len;
    }
    const vol_f = std.fmt.parseFloat(f64, json_mod.getString(ctx, "dayNtlVlm") orelse "0") catch 0;
    const vs = if (vol_f > 1e9) std.fmt.bufPrint(&info.volume_buf, "${d:.2}B", .{vol_f / 1e9}) catch ""
        else if (vol_f > 1e6) std.fmt.bufPrint(&info.volume_buf, "${d:.1}M", .{vol_f / 1e6}) catch ""
        else std.fmt.bufPrint(&info.volume_buf, "${d:.0}", .{vol_f}) catch "";
    info.volume_len = vs.len;
    return info;
}

// ╔══════════════════════════════════════════════════════════════════╗
// ║  9. MAIN LOOP                                                   ║
// ╚══════════════════════════════════════════════════════════════════╝

pub fn run(allocator: std.mem.Allocator, config: Config, coin: []const u8) !void {
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
            else Input.handleKey(key, &ui, &app.running, &ui_client, &config);
            dirty = true;
        }
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

        // 3. Snapshot + render
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
