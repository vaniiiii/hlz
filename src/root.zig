//! HyperZig — High-performance Zig SDK for Hyperliquid.

// ── lib/ — core primitives ───────────────────────────────────────
pub const encoding = struct {
    pub const msgpack = @import("lib/encoding/msgpack.zig");
};
pub const math = struct {
    pub const decimal = @import("lib/math/decimal.zig");
};
pub const crypto = struct {
    pub const signer = @import("lib/crypto/signer.zig");
    pub const eip712 = @import("lib/crypto/eip712.zig");
    pub const endo = @import("lib/crypto/endo.zig");
    pub const field = @import("lib/crypto/field.zig");
    pub const point = @import("lib/crypto/point.zig");
};

// ── sdk/ — Hyperliquid client layer ──────────────────────────────
pub const hypercore = struct {
    pub const types = @import("sdk/types.zig");
    pub const signing = @import("sdk/signing.zig");
    pub const tick = @import("sdk/tick.zig");
    pub const json = @import("sdk/json.zig");
    pub const client = @import("sdk/client.zig");
    pub const ws = @import("sdk/ws.zig");
    pub const response = @import("sdk/response.zig");
};

test {
    _ = encoding.msgpack;
    _ = math.decimal;
    _ = crypto.signer;
    _ = crypto.eip712;
    _ = crypto.endo;
    _ = crypto.field;
    _ = crypto.point;
    _ = hypercore.types;
    _ = hypercore.signing;
    _ = hypercore.tick;
    _ = hypercore.json;
    _ = hypercore.client;
    _ = hypercore.ws;
    _ = hypercore.response;
}
