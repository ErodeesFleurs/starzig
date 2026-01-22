const std = @import("std");
const vlq = @import("vlq.zig");
const types = @import("types.zig");

pub const Variant = union(enum(u8)) {
    nil = 1,
    double: f64 = 2,
    boolean: bool = 3,
    vlq: i64 = 4,
    string: []u8 = 5,
    list: []Variant = 6,
    map: std.StringArrayHashMap(Variant) = 7,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) anyerror!Variant {
        var byte_buf: [1]u8 = undefined;
        _ = try reader.readAll(&byte_buf);
        const tag = byte_buf[0];
        return switch (tag) {
            1 => .nil,
            2 => .{ .double = @bitCast(try reader.readInt(u64, .big)) },
            3 => .{ .boolean = (try reader.readByte()) != 0 },
            4 => .{ .vlq = try vlq.SignedVlq.decode(reader) },
            5 => .{ .string = try types.StarString.decode(allocator, reader) },
            6 => {
                const len = try vlq.Vlq.decode(reader);
                var items = try allocator.alloc(Variant, len);
                errdefer {
                    for (items) |item| item.deinit(allocator);
                    allocator.free(items);
                }
                for (0..len) |i| {
                    items[i] = try Variant.decode(allocator, reader);
                }
                return .{ .list = items };
            },
            7 => {
                const len = try vlq.Vlq.decode(reader);
                var map = std.StringArrayHashMap(Variant).init(allocator);
                errdefer {
                    var it = map.iterator();
                    while (it.next()) |entry| {
                        allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(allocator);
                    }
                    map.deinit();
                }
                for (0..len) |_| {
                    const key = try types.StarString.decode(allocator, reader);
                    const val = try Variant.decode(allocator, reader);
                    try map.put(key, val);
                }
                return .{ .map = map };
            },
            else => error.InvalidVariantTag,
        };
    }

    pub fn deinit(self: Variant, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .list => |l| {
                for (l) |item| item.deinit(allocator);
                allocator.free(l);
            },
            .map => |m| {
                var mutable_map = m;
                var it = mutable_map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                mutable_map.deinit();
            },
            else => {},
        }
    }

    pub fn encode(self: Variant, writer: anytype) !void {
        try writer.writeByte(@intFromEnum(self));
        switch (self) {
            .nil => {},
            .double => |d| try writer.writeInt(u64, @bitCast(d), .big),
            .boolean => |b| try writer.writeByte(if (b) 1 else 0),
            .vlq => |v| try vlq.SignedVlq.encode(writer, v),
            .string => |s| try types.StarString.encode(writer, s),
            .list => |l| {
                try vlq.Vlq.encode(writer, l.len);
                for (l) |item| try item.encode(writer);
            },
            .map => |m| {
                try vlq.Vlq.encode(writer, m.count());
                var it = m.iterator();
                while (it.next()) |entry| {
                    try types.StarString.encode(writer, entry.key_ptr.*);
                    try entry.value_ptr.encode(writer);
                }
            },
        }
    }

    pub fn toString(self: Variant, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        errdefer list.deinit(allocator);

        switch (self) {
            .nil => try list.appendSlice(allocator, "nil"),
            .double => |d| try std.fmt.format(list.writer(allocator), "{d}", .{d}),
            .boolean => |b| try list.appendSlice(allocator, if (b) "true" else "false"),
            .vlq => |v| try std.fmt.format(list.writer(allocator), "{d}", .{v}),
            .string => |s| try list.appendSlice(allocator, s),
            .list => |l| {
                try list.append(allocator, '[');
                for (l, 0..) |item, i| {
                    if (i > 0) try list.appendSlice(allocator, ", ");
                    const s = try item.toString(allocator);
                    defer allocator.free(s);
                    try list.appendSlice(allocator, s);
                }
                try list.append(allocator, ']');
            },
            .map => |m| {
                try list.append(allocator, '{');
                var it = m.iterator();
                var i: usize = 0;
                while (it.next()) |entry| {
                    if (i > 0) try list.appendSlice(allocator, ", ");
                    try list.appendSlice(allocator, entry.key_ptr.*);
                    try list.appendSlice(allocator, ": ");
                    const s = try entry.value_ptr.toString(allocator);
                    defer allocator.free(s);
                    try list.appendSlice(allocator, s);
                    i += 1;
                }
                try list.append(allocator, '}');
            },
        }

        return try list.toOwnedSlice(allocator);
    }
};

test "variant encoding/decoding" {
    const testing = std.testing;
    var list = std.ArrayList(u8){};
    defer list.deinit(testing.allocator);

    const v1 = Variant{ .vlq = 12345 };
    try v1.encode(list.writer(testing.allocator));

    var fbs = std.io.fixedBufferStream(list.items);
    const decoded = try Variant.decode(testing.allocator, fbs.reader());
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(@as(i64, 12345), decoded.vlq);
}

test "variant map encoding/decoding" {
    const testing = std.testing;
    var list = std.ArrayList(u8){};
    defer list.deinit(testing.allocator);

    var map = std.StringArrayHashMap(Variant).init(testing.allocator);
    // Key must be allocated because StarString.decode returns allocated bytes
    const key = try testing.allocator.dupe(u8, "test_key");
    try map.put(key, .{ .boolean = true });

    const v = Variant{ .map = map };
    try v.encode(list.writer(testing.allocator));

    var fbs = std.io.fixedBufferStream(list.items);
    const decoded = try Variant.decode(testing.allocator, fbs.reader());
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded.map.get("test_key").?.boolean);

    // We must deinit the original variant as well to avoid leaks
    v.deinit(testing.allocator);
}
