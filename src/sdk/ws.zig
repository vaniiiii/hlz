const std = @import("std");
const signing = @import("signing.zig");
const Chain = signing.Chain;
const ws = @import("websocket");

pub const MAINNET_WS_URL = "wss://api.hyperliquid.xyz/ws";
pub const TESTNET_WS_URL = "wss://api.hyperliquid-testnet.xyz/ws";

pub const Subscription = union(enum) {
    allMids: struct { dex: ?[]const u8 = null },
    l2Book: struct { coin: []const u8 },
    trades: struct { coin: []const u8 },
    candle: struct { coin: []const u8, interval: []const u8 },
    bbo: struct { coin: []const u8 },
    orderUpdates: struct { user: []const u8 },
    userFills: struct { user: []const u8 },
    userEvents: struct { user: []const u8 },
    userTwapSliceFills: struct { user: []const u8 },
    userTwapHistory: struct { user: []const u8 },
    activeAssetCtx: struct { coin: []const u8 },
    activeAssetData: struct { user: []const u8, coin: []const u8 },
    webData2: struct { user: []const u8 },

    fn formatMsg(self: Subscription, buf: []u8, method: []const u8) ![]const u8 {
        return switch (self) {
            .allMids => |s| if (s.dex) |d|
                std.fmt.bufPrint(buf,
                    \\{{"method":"{s}","subscription":{{"type":"allMids","dex":"{s}"}}}}
                , .{ method, d })
            else
                std.fmt.bufPrint(buf,
                    \\{{"method":"{s}","subscription":{{"type":"allMids"}}}}
                , .{method}),
            .l2Book => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"l2Book","coin":"{s}"}}}}
            , .{ method, s.coin }),
            .trades => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"trades","coin":"{s}"}}}}
            , .{ method, s.coin }),
            .candle => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"candle","coin":"{s}","interval":"{s}"}}}}
            , .{ method, s.coin, s.interval }),
            .bbo => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"bbo","coin":"{s}"}}}}
            , .{ method, s.coin }),
            .orderUpdates => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"orderUpdates","user":"{s}"}}}}
            , .{ method, s.user }),
            .userFills => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"userFills","user":"{s}"}}}}
            , .{ method, s.user }),
            .userEvents => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"userEvents","user":"{s}"}}}}
            , .{ method, s.user }),
            .userTwapSliceFills => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"userTwapSliceFills","user":"{s}"}}}}
            , .{ method, s.user }),
            .userTwapHistory => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"userTwapHistory","user":"{s}"}}}}
            , .{ method, s.user }),
            .activeAssetCtx => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"activeAssetCtx","coin":"{s}"}}}}
            , .{ method, s.coin }),
            .activeAssetData => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"activeAssetData","user":"{s}","coin":"{s}"}}}}
            , .{ method, s.user, s.coin }),
            .webData2 => |s| std.fmt.bufPrint(buf,
                \\{{"method":"{s}","subscription":{{"type":"webData2","user":"{s}"}}}}
            , .{ method, s.user }),
        };
    }

    pub fn toJson(self: Subscription, buf: []u8) ![]const u8 {
        return self.formatMsg(buf, "subscribe");
    }

    pub fn toUnsubJson(self: Subscription, buf: []u8) ![]const u8 {
        return self.formatMsg(buf, "unsubscribe");
    }
};

pub const MessageChannel = enum {
    subscriptionResponse,
    bbo,
    l2Book,
    candle,
    allMids,
    trades,
    orderUpdates,
    userFills,
    userEvents,
    userTwapSliceFills,
    userTwapHistory,
    activeAssetCtx,
    activeAssetData,
    webData2,
    ping,
    pong,
    unknown,
};

pub const Message = struct {
    channel: MessageChannel,
    raw_json: []const u8, // valid until next read
};

pub fn parseChannel(text: []const u8) MessageChannel {
    if (std.mem.indexOf(u8, text, "\"Pong\"") != null or
        std.mem.indexOf(u8, text, "\"pong\"") != null)
        return .pong;
    if (std.mem.indexOf(u8, text, "\"Ping\"") != null or
        std.mem.indexOf(u8, text, "\"ping\"") != null)
        return .ping;

    const marker = "\"channel\":\"";
    const idx = std.mem.indexOf(u8, text, marker) orelse return .unknown;
    const start = idx + marker.len;
    const end = std.mem.indexOfPos(u8, text, start, "\"") orelse return .unknown;
    const channel = text[start..end];

    return std.meta.stringToEnum(MessageChannel, channel) orelse .unknown;
}

pub fn extractData(text: []const u8) ?[]const u8 {
    const marker = "\"data\":";
    const idx = std.mem.indexOf(u8, text, marker) orelse return null;
    const start = idx + marker.len;
    if (start >= text.len) return null;

    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (escape) { escape = false; continue; }
        if (c == '\\' and in_string) { escape = true; continue; }
        if (c == '"') { in_string = !in_string; continue; }
        if (in_string) continue;
        if (c == '{' or c == '[') {
            depth += 1;
        } else if (c == '}' or c == ']') {
            if (depth == 0) return text[start..i];
            depth -= 1;
            if (depth == 0) return text[start .. i + 1];
        } else if (depth == 0 and (c == ',' or c == '}')) {
            return text[start..i];
        }
    }
    return text[start..];
}

pub const Connection = struct {
    client: ws.Client,
    allocator: std.mem.Allocator,
    chain: Chain,
    subs: [MAX_SUBS]SubEntry = undefined,
    sub_count: usize = 0,
    ticks_since_ping: u8 = 0,
    missed_pongs: u8 = 0,
    debug: bool = false,
    socket_fd: std.posix.fd_t = -1, // for shutdown() from signal handler

    const MAX_SUBS = 16;
    const SubEntry = struct { buf: [256]u8 = undefined, len: usize = 0 };

    pub const NextResult = union(enum) {
        message: Message,
        timeout,
        closed,
    };

    pub fn connect(allocator: std.mem.Allocator, chain: Chain) !*Connection {
        const url = if (chain.isMainnet()) MAINNET_WS_URL else TESTNET_WS_URL;
        return connectUrl(allocator, chain, url);
    }

    pub fn connectUrl(allocator: std.mem.Allocator, chain: Chain, url: []const u8) !*Connection {
        const stripped = if (std.mem.startsWith(u8, url, "wss://"))
            url[6..]
        else if (std.mem.startsWith(u8, url, "ws://"))
            url[5..]
        else
            return error.InvalidArgument;

        const is_tls = std.mem.startsWith(u8, url, "wss://");
        const slash_pos = std.mem.indexOf(u8, stripped, "/") orelse stripped.len;
        const host = stripped[0..slash_pos];
        const path = if (slash_pos < stripped.len) stripped[slash_pos..] else "/";
        const port: u16 = if (is_tls) 443 else 80;

        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);

        self.* = .{
            .client = undefined,
            .allocator = allocator,
            .chain = chain,
        };

        self.client = try ws.Client.init(allocator, .{
            .host = host,
            .port = port,
            .tls = is_tls,
            .max_size = 1 << 20,
            .buffer_size = 16384,
        });

        var hdr_buf: [256]u8 = undefined;
        const host_header = std.fmt.bufPrint(&hdr_buf, "Host: {s}\r\n", .{host}) catch "";

        self.client.handshake(path, .{
            .timeout_ms = 10000,
            .headers = host_header,
        }) catch |e| {
            self.client.deinit();
            allocator.destroy(self);
            return e;
        };

        self.socket_fd = self.client.stream.stream.handle;
        return self;
    }

    pub fn subscribe(self: *Connection, sub: Subscription) !void {
        var buf: [512]u8 = undefined;
        const msg = try sub.toJson(&buf);
        self.sendRaw(msg) catch return error.Overflow;
        if (self.sub_count < MAX_SUBS) {
            var entry = &self.subs[self.sub_count];
            if (msg.len <= entry.buf.len) {
                @memcpy(entry.buf[0..msg.len], msg);
                entry.len = msg.len;
                self.sub_count += 1;
            }
        }
    }

    pub fn unsubscribe(self: *Connection, sub: Subscription) !void {
        var buf: [512]u8 = undefined;
        const msg = try sub.toUnsubJson(&buf);
        self.sendRaw(msg) catch return error.Overflow;
    }

    /// Read next event. Auto-handles ping/pong keepalive.
    pub fn next(self: *Connection) !NextResult {
        while (true) {
            const raw = self.client.read() catch |e| switch (e) {
                error.Closed => return .closed,
                // TLS wraps EAGAIN as ReadFailed on macOS when SO_RCVTIMEO fires
                error.WouldBlock, error.ReadFailed => {
                    self.tickKeepalive();
                    return .timeout;
                },
                else => return e,
            };

            const frame = raw orelse {
                self.tickKeepalive();
                return .timeout;
            };

            switch (frame.type) {
                .text, .binary => {
                    const text = frame.data;
                    const channel = parseChannel(text);
                    if (channel == .ping) {
                        self.sendRaw("{\"method\":\"pong\"}") catch {};
                        continue;
                    }
                    if (channel == .pong) {
                        self.missed_pongs = 0;
                        continue;
                    }
                    return .{ .message = .{ .channel = channel, .raw_json = text } };
                },
                .ping => {
                    self.client.writeFrame(.pong, @constCast(frame.data)) catch {};
                    self.client.done(frame);
                    continue;
                },
                .pong => {
                    self.client.done(frame);
                    continue;
                },
                .close => return .closed,
            }
        }
    }

    fn tickKeepalive(self: *Connection) void {
        self.ticks_since_ping += 1;
        if (self.ticks_since_ping >= 5) {
            self.ticks_since_ping = 0;
            if (self.missed_pongs >= 3) return;
            self.sendRaw("{\"method\":\"ping\"}") catch return;
            self.missed_pongs += 1;
        }
    }

    pub fn setReadTimeout(self: *Connection, ms: u32) void {
        self.client.readTimeout(ms) catch {};
    }

    pub fn sendRaw(self: *Connection, text: []const u8) !void {
        var buf: [8192]u8 = undefined;
        if (text.len > buf.len) return error.Overflow;
        @memcpy(buf[0..text.len], text);
        try self.client.writeText(buf[0..text.len]);
    }

    pub fn close(self: *Connection) void {
        self.client.close(.{}) catch {};
        self.client.deinit();
        self.allocator.destroy(self);
    }
};

test "Subscription.toJson: trades" {
    var buf: [256]u8 = undefined;
    const json = try (Subscription{ .trades = .{ .coin = "BTC" } }).toJson(&buf);
    try std.testing.expectEqualStrings(
        \\{"method":"subscribe","subscription":{"type":"trades","coin":"BTC"}}
    , json);
}

test "Subscription.toJson: allMids without dex" {
    var buf: [256]u8 = undefined;
    const json = try (Subscription{ .allMids = .{} }).toJson(&buf);
    try std.testing.expectEqualStrings(
        \\{"method":"subscribe","subscription":{"type":"allMids"}}
    , json);
}

test "Subscription.toJson: candle" {
    var buf: [256]u8 = undefined;
    const json = try (Subscription{ .candle = .{ .coin = "ETH", .interval = "15m" } }).toJson(&buf);
    try std.testing.expectEqualStrings(
        \\{"method":"subscribe","subscription":{"type":"candle","coin":"ETH","interval":"15m"}}
    , json);
}

test "Subscription.toUnsubJson: trades" {
    var buf: [256]u8 = undefined;
    const json = try (Subscription{ .trades = .{ .coin = "BTC" } }).toUnsubJson(&buf);
    try std.testing.expectEqualStrings(
        \\{"method":"unsubscribe","subscription":{"type":"trades","coin":"BTC"}}
    , json);
}

test "parseChannel" {
    const msg =
        \\{"channel":"trades","data":[{"coin":"BTC","side":"B","px":"50000","sz":"0.1"}]}
    ;
    try std.testing.expectEqual(MessageChannel.trades, parseChannel(msg));
    try std.testing.expectEqual(MessageChannel.pong, parseChannel("\"Pong\""));
}

test "extractData" {
    const msg =
        \\{"channel":"l2Book","data":{"coin":"BTC","levels":[[],[]]}}
    ;
    try std.testing.expectEqualStrings(
        \\{"coin":"BTC","levels":[[],[]]}
    , extractData(msg).?);
}
