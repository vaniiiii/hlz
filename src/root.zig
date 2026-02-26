//! HyperZig — High-performance Zig SDK for Hyperliquid.

pub const encoding = struct {
    pub const msgpack = @import("encoding/msgpack.zig");
};

pub const math = struct {
    pub const decimal = @import("math/decimal.zig");
};

pub const crypto = struct {
    pub const signer = @import("crypto/signer.zig");
    pub const eip712 = @import("crypto/eip712.zig");
    pub const endo = @import("crypto/endo.zig");
};

pub const hypercore = struct {
    pub const types = @import("hypercore/types.zig");
    pub const signing = @import("hypercore/signing.zig");
    pub const tick = @import("hypercore/tick.zig");
    pub const json = @import("hypercore/json.zig");
    pub const client = @import("hypercore/client.zig");
    pub const ws = @import("hypercore/ws.zig");
    pub const response = @import("hypercore/response.zig");
};

test {
    _ = encoding.msgpack;
    _ = math.decimal;
    _ = crypto.signer;
    _ = crypto.eip712;
    _ = crypto.endo;
    _ = @import("crypto/field.zig");
    _ = @import("crypto/point.zig");
    _ = hypercore.types;
    _ = hypercore.signing;
    _ = hypercore.tick;
    _ = hypercore.json;
    _ = hypercore.client;
    _ = hypercore.ws;
    _ = hypercore.response;
}
