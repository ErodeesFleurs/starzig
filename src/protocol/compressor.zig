const std = @import("std");

pub fn decompressPayload(gpa: std.mem.Allocator, compressed_data: []const u8) ![]u8 {
    var fbs = std.io.Reader.fixed(compressed_data);
    var decompressor: std.compress.flate.Decompress = .init(&fbs, .zlib, &.{});
    return try decompressor.reader.allocRemaining(gpa, .unlimited);
}
