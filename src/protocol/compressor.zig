const std = @import("std");

pub fn decompressToArrayList(compressed_data: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var fbs = std.io.Reader.fixed(compressed_data);
    var decompressor: std.compress.flate.Decompress = .init(&fbs, .zlib, &.{});

    out.clearRetainingCapacity();
    const buf = try decompressor.reader.allocRemaining(gpa, .unlimited);
    try out.appendSlice(gpa, buf);
}
