const std = @import("std");

/// Variable Length Quantity (VLQ) encoding/decoding.
/// Starbound uses a big-endian-like VLQ where the most significant bit (MSB)
/// of each byte indicates if there are more bytes to follow.
pub const Vlq = struct {
    pub fn decode(reader: anytype) !u64 {
        var value: u64 = 0;
        while (true) {
            var buf: [1]u8 = undefined;
            try reader.readNoEof(&buf);
            const byte = buf[0];
            value = (value << 7) | (byte & 0x7F);
            if (byte & 0x80 == 0) break;
        }
        return value;
    }

    pub fn encode(writer: anytype, value: u64) !void {
        if (value == 0) {
            const buf = [_]u8{0};
            try writer.writeAll(&buf);
            return;
        }

        var buf: [10]u8 = undefined;
        var bytes_needed: usize = 0;
        var v = value;
        while (v > 0) : (v >>= 7) bytes_needed += 1;

        var i: usize = bytes_needed;
        v = value;
        while (i > 0) {
            i -= 1;
            var b = @as(u8, @intCast(v & 0x7F));
            if (i < bytes_needed - 1) b |= 0x80;
            buf[i] = b;
            v >>= 7;
        }
        try writer.writeAll(buf[0..bytes_needed]);
    }
};

pub const SignedVlq = struct {
    pub fn decode(reader: anytype) !i64 {
        const v = try Vlq.decode(reader);
        if (v & 1 == 0) {
            return @intCast(v >> 1);
        } else {
            return -@as(i64, @intCast((v >> 1) + 1));
        }
    }

    pub fn encode(writer: anytype, value: i64) !void {
        var u_val: u64 = undefined;
        if (value >= 0) {
            u_val = @as(u64, @intCast(value)) << 1;
        } else {
            u_val = (@as(u64, @intCast(@abs(value + 1))) << 1) | 1;
        }
        try Vlq.encode(writer, u_val);
    }
};

test "vlq encoding/decoding" {
    const testing = std.testing;
    var list = std.ArrayList(u8){};
    defer list.deinit(testing.allocator);

    try Vlq.encode(list.writer(testing.allocator), 127);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(@as(u8, 127), list.items[0]);

    list.clearRetainingCapacity();
    try Vlq.encode(list.writer(testing.allocator), 128);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    // 128 = 1000 0000 -> 1 0000000 -> 0x81 0x00
    try testing.expectEqual(@as(u8, 0x81), list.items[0]);
    try testing.expectEqual(@as(u8, 0x00), list.items[1]);

    var fbs = std.io.fixedBufferStream(list.items);
    const decoded = try Vlq.decode(fbs.reader());
    try testing.expectEqual(@as(u64, 128), decoded);
}

test "signed vlq encoding/decoding" {
    const testing = std.testing;
    var list = std.ArrayList(u8){};
    defer list.deinit(testing.allocator);

    try SignedVlq.encode(list.writer(testing.allocator), -1);
    var fbs = std.io.fixedBufferStream(list.items);
    try testing.expectEqual(@as(i64, -1), try SignedVlq.decode(fbs.reader()));

    list.clearRetainingCapacity();
    try SignedVlq.encode(list.writer(testing.allocator), 64);
    fbs = std.io.fixedBufferStream(list.items);
    try testing.expectEqual(@as(i64, 64), try SignedVlq.decode(fbs.reader()));

    list.clearRetainingCapacity();
    try SignedVlq.encode(list.writer(testing.allocator), -64);
    fbs = std.io.fixedBufferStream(list.items);
    try testing.expectEqual(@as(i64, -64), try SignedVlq.decode(fbs.reader()));
}
