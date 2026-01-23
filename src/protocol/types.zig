const std = @import("std");
const vlq = @import("vlq.zig");

pub const StarString = struct {
    pub fn decode(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
        const length = try vlq.Vlq.decode(reader);
        const buf = try allocator.alloc(u8, length);
        errdefer allocator.free(buf);
        var total: usize = 0;
        while (total < length) {
            const n = try reader.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        if (total < length) return error.EndOfStream;
        return buf;
    }

    pub fn encode(writer: anytype, value: []const u8) !void {
        try vlq.Vlq.encode(writer, value.len);
        _ = try writer.write(value);
    }
};

pub const StarByteArray = struct {
    pub fn decode(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
        const length = try vlq.Vlq.decode(reader);
        const buf = try allocator.alloc(u8, length);
        errdefer allocator.free(buf);
        var total: usize = 0;
        while (total < length) {
            const n = try reader.read(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        if (total < length) return error.EndOfStream;
        return buf;
    }

    pub fn encode(writer: anytype, value: []const u8) !void {
        try vlq.Vlq.encode(writer, value.len);
        _ = try writer.write(value);
    }
};

pub const UUID = struct {
    data: [16]u8,

    pub fn decode(reader: anytype) !UUID {
        var uuid: UUID = undefined;
        var total: usize = 0;
        while (total < 16) {
            const n = try reader.read(uuid.data[total..]);
            if (n == 0) break;
            total += n;
        }
        if (total < 16) return error.EndOfStream;
        return uuid;
    }

    pub fn encode(self: UUID, writer: anytype) !void {
        _ = try writer.write(&self.data);
    }

    pub fn format(
        self: UUID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        for (self.data) |b| {
            try std.fmt.format(writer, "{x:0>2}", .{b});
        }
    }

    pub fn toString(self: UUID, allocator: std.mem.Allocator) ![]u8 {
        var buf: [32]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try self.format("", .{}, fbs.writer());
        return try allocator.dupe(u8, &buf);
    }
};

test "starstring encoding/decoding" {
    const testing = std.testing;
    var list = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer list.deinit(testing.allocator);

    const test_str = "Hello Starbound!";
    try StarString.encode(list.writer(testing.allocator), test_str);

    var fbs = std.io.fixedBufferStream(list.items);
    const decoded = try StarString.decode(testing.allocator, fbs.reader());
    defer testing.allocator.free(decoded);

    try testing.expectEqualStrings(test_str, decoded);
}
