const std = @import("std");

pub const Protocol = struct {
    pub fn decodeVLQ(data: []const u8) !struct { value: u64, bytes_read: usize } {
        if (data.len == 0) return error.Incomplete;

        var value: u64 = 0;
        const len = @min(data.len, 10);
        const bytes = data[0..len];

        comptime var i = 0;
        inline while (i < 10) : (i += 1) {
            if (i >= len) break;

            const byte = bytes[i];
            value = (value << 7) | @as(u64, byte & 0x7F);

            if (byte & 0x80 == 0) {
                return .{ .value = value, .bytes_read = i + 1 };
            }
        }

        if (len >= 10) return error.Overflow;

        return error.Incomplete;
    }

    pub fn decodeSignedVLQ(data: []const u8) !struct { value: i64, bytes_read: usize } {
        const res = try decodeVLQ(data);
        const sign: i64 = @as(i64, 1) - 2 * @as(i64, @intCast(res.value & 1));
        const abs_value = (res.value >> 1) + @as(u64, res.value & 1);

        return .{
            .value = sign * @as(i64, @intCast(abs_value)),
            .bytes_read = res.bytes_read,
        };
    }

    pub fn encodeVLQ(allocator: std.mem.Allocator, obj: u64) ![]u8 {
        if (obj == 0) {
            const res = try allocator.alloc(u8, 1);
            res[0] = 0;
            return res;
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit();
        var value = obj;

        while (value > 0) {
            var byte = @as(u8, @intCast(value & 0x7F));
            value >>= 7;
            if (result.items.len > 0) {
                byte |= 0x80;
            }
            try result.append(byte);
        }

        std.mem.reverse(u8, result.items);

        if (result.items.len > 1) {
            result.items[0] |= 0x80;
            result.items[result.items.len - 1] &= 0x7F;
        }

        return result.toOwnedSlice();
    }

    pub fn decompressPayload(gpa: std.mem.Allocator, compressed_data: []const u8) ![]u8 {
        var fbs = std.io.Reader.fixed(compressed_data);
        var decompressor: std.compress.flate.Decompress = .init(&fbs, .zlib, &.{});
        return try decompressor.reader.allocRemaining(gpa, .unlimited);
    }
};
