//! MessagePack encoder producing byte-exact output matching rmp-serde::to_vec_named.
//! Fixed buffer, no allocations. Compact integer encoding per msgpack spec.

const std = @import("std");

/// Errors that can occur during packing.
pub const PackError = error{
    BufferOverflow,
};

/// A MessagePack packer that writes to a fixed buffer.
pub const Packer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) Packer {
        return .{ .buf = buf };
    }

    /// Returns the packed bytes written so far.
    pub fn written(self: *const Packer) []const u8 {
        return self.buf[0..self.pos];
    }

    // ── Low-level write ──────────────────────────────────────────

    fn put(self: *Packer, byte: u8) PackError!void {
        if (self.pos >= self.buf.len) return error.BufferOverflow;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn putSlice(self: *Packer, data: []const u8) PackError!void {
        if (self.pos + data.len > self.buf.len) return error.BufferOverflow;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn putU16(self: *Packer, val: u16) PackError!void {
        const bytes = std.mem.toBytes(std.mem.nativeTo(u16, val, .big));
        try self.putSlice(&bytes);
    }

    fn putU32(self: *Packer, val: u32) PackError!void {
        const bytes = std.mem.toBytes(std.mem.nativeTo(u32, val, .big));
        try self.putSlice(&bytes);
    }

    fn putU64(self: *Packer, val: u64) PackError!void {
        const bytes = std.mem.toBytes(std.mem.nativeTo(u64, val, .big));
        try self.putSlice(&bytes);
    }

    fn putI8(self: *Packer, val: i8) PackError!void {
        try self.put(@bitCast(val));
    }

    fn putI16(self: *Packer, val: i16) PackError!void {
        const bytes = std.mem.toBytes(std.mem.nativeTo(i16, val, .big));
        try self.putSlice(&bytes);
    }

    fn putI32(self: *Packer, val: i32) PackError!void {
        const bytes = std.mem.toBytes(std.mem.nativeTo(i32, val, .big));
        try self.putSlice(&bytes);
    }

    fn putI64(self: *Packer, val: i64) PackError!void {
        const bytes = std.mem.toBytes(std.mem.nativeTo(i64, val, .big));
        try self.putSlice(&bytes);
    }

    // ── Nil ──────────────────────────────────────────────────────

    pub fn packNil(self: *Packer) PackError!void {
        try self.put(0xc0);
    }

    // ── Bool ─────────────────────────────────────────────────────

    pub fn packBool(self: *Packer, val: bool) PackError!void {
        try self.put(if (val) 0xc3 else 0xc2);
    }

    // ── Unsigned integers ────────────────────────────────────────
    // Matches rmp::encode::write_uint — smallest representation.

    pub fn packUint(self: *Packer, val: u64) PackError!void {
        if (val < 128) {
            // positive fixint: 0x00..0x7f
            try self.put(@intCast(val));
        } else if (val < 256) {
            // uint 8: 0xcc + u8
            try self.put(0xcc);
            try self.put(@intCast(val));
        } else if (val < 65536) {
            // uint 16: 0xcd + u16
            try self.put(0xcd);
            try self.putU16(@intCast(val));
        } else if (val < 4294967296) {
            // uint 32: 0xce + u32
            try self.put(0xce);
            try self.putU32(@intCast(val));
        } else {
            // uint 64: 0xcf + u64
            try self.put(0xcf);
            try self.putU64(val);
        }
    }

    // ── Signed integers ──────────────────────────────────────────
    // Matches rmp::encode::write_sint — uses unsigned encoding for
    // non-negative values, signed for negative.

    pub fn packInt(self: *Packer, val: i64) PackError!void {
        if (val >= 0) {
            // Non-negative: use unsigned encoding (matches rmp-serde behavior)
            return self.packUint(@intCast(val));
        }
        if (val >= -32) {
            // negative fixint: 0xe0..0xff (val as i8 cast to u8)
            try self.putI8(@intCast(val));
        } else if (val >= -128) {
            // int 8: 0xd0 + i8
            try self.put(0xd0);
            try self.putI8(@intCast(val));
        } else if (val >= -32768) {
            // int 16: 0xd1 + i16
            try self.put(0xd1);
            try self.putI16(@intCast(val));
        } else if (val >= -2147483648) {
            // int 32: 0xd2 + i32
            try self.put(0xd2);
            try self.putI32(@intCast(val));
        } else {
            // int 64: 0xd3 + i64
            try self.put(0xd3);
            try self.putI64(val);
        }
    }

    // ── Floats ───────────────────────────────────────────────────

    pub fn packF32(self: *Packer, val: f32) PackError!void {
        try self.put(0xca);
        const bytes = std.mem.toBytes(std.mem.nativeTo(f32, val, .big));
        try self.putSlice(&bytes);
    }

    pub fn packF64(self: *Packer, val: f64) PackError!void {
        try self.put(0xcb);
        const bytes = std.mem.toBytes(std.mem.nativeTo(f64, val, .big));
        try self.putSlice(&bytes);
    }

    // ── Strings ──────────────────────────────────────────────────
    // Matches rmp::encode::write_str — fixstr / str8 / str16 / str32

    pub fn packStr(self: *Packer, val: []const u8) PackError!void {
        const len = val.len;
        if (len < 32) {
            // fixstr: 0xa0..0xbf
            try self.put(0xa0 | @as(u8, @intCast(len)));
        } else if (len < 256) {
            // str 8: 0xd9 + u8 length
            try self.put(0xd9);
            try self.put(@intCast(len));
        } else if (len < 65536) {
            // str 16: 0xda + u16 length
            try self.put(0xda);
            try self.putU16(@intCast(len));
        } else {
            // str 32: 0xdb + u32 length
            try self.put(0xdb);
            try self.putU32(@intCast(len));
        }
        try self.putSlice(val);
    }

    // ── Binary ───────────────────────────────────────────────────

    pub fn packBin(self: *Packer, val: []const u8) PackError!void {
        const len = val.len;
        if (len < 256) {
            try self.put(0xc4);
            try self.put(@intCast(len));
        } else if (len < 65536) {
            try self.put(0xc5);
            try self.putU16(@intCast(len));
        } else {
            try self.put(0xc6);
            try self.putU32(@intCast(len));
        }
        try self.putSlice(val);
    }

    // ── Array header ─────────────────────────────────────────────

    pub fn packArrayHeader(self: *Packer, len: u32) PackError!void {
        if (len < 16) {
            // fixarray: 0x90..0x9f
            try self.put(0x90 | @as(u8, @intCast(len)));
        } else if (len < 65536) {
            try self.put(0xdc);
            try self.putU16(@intCast(len));
        } else {
            try self.put(0xdd);
            try self.putU32(len);
        }
    }

    // ── Map header ───────────────────────────────────────────────

    pub fn packMapHeader(self: *Packer, len: u32) PackError!void {
        if (len < 16) {
            // fixmap: 0x80..0x8f
            try self.put(0x80 | @as(u8, @intCast(len)));
        } else if (len < 65536) {
            try self.put(0xde);
            try self.putU16(@intCast(len));
        } else {
            try self.put(0xdf);
            try self.putU32(len);
        }
    }

    // ── High-level: pack any value ───────────────────────────────
    // Recursively packs Zig values using msgpack format.
    // Structs → named maps (matching rmp-serde::to_vec_named).

    pub fn pack(self: *Packer, value: anytype) PackError!void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        switch (info) {
            .bool => try self.packBool(value),
            .int => |int_info| {
                if (int_info.signedness == .signed) {
                    try self.packInt(@intCast(value));
                } else {
                    try self.packUint(@intCast(value));
                }
            },
            .float => |float_info| {
                if (float_info.bits <= 32) {
                    try self.packF32(@floatCast(value));
                } else {
                    try self.packF64(@floatCast(value));
                }
            },
            .optional => {
                if (value) |v| {
                    try self.pack(v);
                } else {
                    try self.packNil();
                }
            },
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        if (ptr_info.child == u8) {
                            // []const u8 → string
                            try self.packStr(value);
                        } else {
                            // Other slices → array
                            try self.packArrayHeader(@intCast(value.len));
                            for (value) |item| {
                                try self.pack(item);
                            }
                        }
                    },
                    .one => try self.pack(value.*),
                    else => @compileError("unsupported pointer type"),
                }
            },
            .array => |arr_info| {
                if (arr_info.child == u8) {
                    // [N]u8 → string
                    try self.packStr(&value);
                } else {
                    try self.packArrayHeader(@intCast(arr_info.len));
                    for (value) |item| {
                        try self.pack(item);
                    }
                }
            },
            .@"struct" => |struct_info| {
                // Count non-null optional fields for accurate map header
                comptime var field_count: u32 = 0;
                inline for (struct_info.fields) |_| {
                    field_count += 1;
                }
                // For named map: emit all fields (nulls as nil)
                try self.packMapHeader(field_count);
                inline for (struct_info.fields) |field| {
                    try self.packStr(field.name);
                    try self.pack(@field(value, field.name));
                }
            },
            .@"enum" => {
                // Enums serialized as their string name (matching serde default)
                try self.packStr(@tagName(value));
            },
            .@"union" => |union_info| {
                if (union_info.tag_type) |_| {
                    // Tagged union: {"VariantName": value} (matches serde)
                    try self.packMapHeader(1);
                    try self.packStr(@tagName(value));
                    inline for (union_info.fields) |field| {
                        if (std.mem.eql(u8, @tagName(value), field.name)) {
                            if (field.type == void) {
                                try self.packNil();
                            } else {
                                try self.pack(@field(value, field.name));
                            }
                        }
                    }
                } else {
                    @compileError("untagged unions not supported");
                }
            },
            .void, .null => try self.packNil(),
            else => @compileError("unsupported type: " ++ @typeName(T)),
        }
    }
};

/// Convenience: pack a value into a fixed buffer, return the written slice.
pub fn packToSlice(buf: []u8, value: anytype) PackError![]const u8 {
    var packer = Packer.init(buf);
    try packer.pack(value);
    return packer.written();
}

// Test vectors from rmp-serde/tests/encode_derive.rs and rmp/tests/

test "uint: positive fixint" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packUint(0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, p.written());

    p = Packer.init(&buf);
    try p.packUint(127);
    try std.testing.expectEqualSlices(u8, &.{0x7f}, p.written());
}

test "uint: u8" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packUint(128);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0x80 }, p.written());

    p = Packer.init(&buf);
    try p.packUint(255);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xff }, p.written());
}

test "uint: u16" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packUint(256);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0x01, 0x00 }, p.written());
}

test "uint: u32" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packUint(65536);
    try std.testing.expectEqualSlices(u8, &.{ 0xce, 0x00, 0x01, 0x00, 0x00 }, p.written());
}

test "uint: u64" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packUint(4294967296);
    try std.testing.expectEqualSlices(u8, &.{ 0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 }, p.written());
}

test "int: negative fixint" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packInt(-1);
    try std.testing.expectEqualSlices(u8, &.{0xff}, p.written());

    p = Packer.init(&buf);
    try p.packInt(-32);
    try std.testing.expectEqualSlices(u8, &.{0xe0}, p.written());
}

test "int: i8" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packInt(-33);
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0xdf }, p.written());

    p = Packer.init(&buf);
    try p.packInt(-128);
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x80 }, p.written());
}

test "int: i16" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packInt(-129);
    try std.testing.expectEqualSlices(u8, &.{ 0xd1, 0xff, 0x7f }, p.written());
}

test "int: positive via signed uses unsigned encoding" {
    // rmp-serde: serialize_i64 calls write_sint, which for positive
    // values uses unsigned encoding
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packInt(42);
    try std.testing.expectEqualSlices(u8, &.{0x2a}, p.written());

    p = Packer.init(&buf);
    try p.packInt(200);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xc8 }, p.written());
}

test "string: fixstr" {
    var buf: [64]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packStr("a");
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 'a' }, p.written());
}

test "string: str8" {
    var buf: [300]u8 = undefined;
    var p = Packer.init(&buf);
    // 32-byte string → str8
    const s = "a" ** 32;
    try p.packStr(s);
    try std.testing.expectEqual(@as(u8, 0xd9), p.written()[0]);
    try std.testing.expectEqual(@as(u8, 32), p.written()[1]);
    try std.testing.expectEqual(@as(usize, 34), p.written().len);
}

test "bool" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packBool(true);
    try std.testing.expectEqualSlices(u8, &.{0xc3}, p.written());

    p = Packer.init(&buf);
    try p.packBool(false);
    try std.testing.expectEqualSlices(u8, &.{0xc2}, p.written());
}

test "nil" {
    var buf: [16]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packNil();
    try std.testing.expectEqualSlices(u8, &.{0xc0}, p.written());
}

test "struct as named map — matches rmp-serde with_struct_map" {
    // From rmp-serde test: pass_struct_as_map_using_ext
    // Dog { name: "Bobby", age: 8 } → {"name": "Bobby", "age": 8}
    // Expected: 0x82, 0xa4, "name", 0xa5, "Bobby", 0xa3, "age", 0x08
    const Dog = struct {
        name: []const u8,
        age: u16,
    };

    var buf: [64]u8 = undefined;
    const result = try packToSlice(&buf, Dog{ .name = "Bobby", .age = 8 });

    try std.testing.expectEqualSlices(u8, &.{
        0x82, // fixmap, 2 entries
        0xa4, 'n', 'a', 'm', 'e', // "name"
        0xa5, 'B', 'o', 'b', 'b', 'y', // "Bobby"
        0xa3, 'a', 'g', 'e', // "age"
        0x08, // 8
    }, result);
}

test "struct with u32 fields — matches rmp-serde" {
    // From rmp-serde test: pass_struct (but with_struct_map)
    // Struct { f1: 42, f2: 100500 }
    // As named map: {"f1": 42, "f2": 100500}
    const Msg = struct {
        f1: u32,
        f2: u32,
    };

    var buf: [64]u8 = undefined;
    const result = try packToSlice(&buf, Msg{ .f1 = 42, .f2 = 100500 });

    try std.testing.expectEqualSlices(u8, &.{
        0x82, // fixmap, 2 entries
        0xa2, 'f', '1', // "f1"
        0x2a, // 42 (fixint)
        0xa2, 'f', '2', // "f2"
        0xce, 0x00, 0x01, 0x88, 0x94, // 100500 (uint32)
    }, result);
}

test "optional field — Some and None" {
    const Msg = struct {
        a: u32,
        b: ?u32,
    };

    // With value
    var buf: [64]u8 = undefined;
    var result = try packToSlice(&buf, Msg{ .a = 1, .b = 2 });
    try std.testing.expectEqualSlices(u8, &.{
        0x82, 0xa1, 'a', 0x01, 0xa1, 'b', 0x02,
    }, result);

    // With null → nil
    result = try packToSlice(&buf, Msg{ .a = 1, .b = null });
    try std.testing.expectEqualSlices(u8, &.{
        0x82, 0xa1, 'a', 0x01, 0xa1, 'b', 0xc0,
    }, result);
}

test "nested struct" {
    const Inner = struct {
        x: u8,
    };
    const Outer = struct {
        name: []const u8,
        inner: Inner,
    };

    var buf: [64]u8 = undefined;
    const result = try packToSlice(&buf, Outer{
        .name = "hi",
        .inner = .{ .x = 42 },
    });

    try std.testing.expectEqualSlices(u8, &.{
        0x82, // outer map, 2 entries
        0xa4, 'n', 'a', 'm', 'e', // "name"
        0xa2, 'h', 'i', // "hi"
        0xa5, 'i', 'n', 'n', 'e', 'r', // "inner"
        0x81, // inner map, 1 entry
        0xa1, 'x', // "x"
        0x2a, // 42
    }, result);
}

test "array of integers" {
    var buf: [64]u8 = undefined;
    var p = Packer.init(&buf);
    try p.packArrayHeader(3);
    try p.packUint(1);
    try p.packUint(2);
    try p.packUint(3);
    try std.testing.expectEqualSlices(u8, &.{
        0x93, 0x01, 0x02, 0x03,
    }, p.written());
}

test "enum as string" {
    const Side = enum { Buy, Sell };
    var buf: [64]u8 = undefined;
    var p = Packer.init(&buf);
    try p.pack(Side.Buy);
    try std.testing.expectEqualSlices(u8, &.{
        0xa3, 'B', 'u', 'y',
    }, p.written());
}

test "pack via generic — integer types" {
    var buf: [64]u8 = undefined;
    var p = Packer.init(&buf);

    // u8
    try p.pack(@as(u8, 42));
    try std.testing.expectEqualSlices(u8, &.{0x2a}, p.written());

    // i32 negative
    p = Packer.init(&buf);
    try p.pack(@as(i32, -1));
    try std.testing.expectEqualSlices(u8, &.{0xff}, p.written());
}
