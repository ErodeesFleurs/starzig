const std = @import("std");

pub const zstd = @cImport({
    @cInclude("zstd.h");
});

pub const Decompressor = struct {
    dctx: *zstd.ZSTD_DCtx,

    pub fn init() !Decompressor {
        const dctx = zstd.ZSTD_createDCtx() orelse return error.ZstdContextCreationFailed;
        return Decompressor{ .dctx = dctx };
    }

    pub fn deinit(self: *Decompressor) void {
        _ = zstd.ZSTD_freeDCtx(self.dctx);
    }

    pub fn decompress(self: *Decompressor, allocator: std.mem.Allocator, compressed_data: []const u8) ![]u8 {
        const decompressed_size = zstd.ZSTD_getFrameContentSize(compressed_data.ptr, compressed_data.len);
        if (decompressed_size == @as(u64, @bitCast(@as(i64, -2)))) return error.NotZstdCompressed;
        if (decompressed_size == @as(u64, @bitCast(@as(i64, -1)))) return error.UnknownDecompressedSize;

        const buf = try allocator.alloc(u8, decompressed_size);
        errdefer allocator.free(buf);

        const result = zstd.ZSTD_decompressDCtx(self.dctx, buf.ptr, decompressed_size, compressed_data.ptr, compressed_data.len);
        if (zstd.ZSTD_isError(result) != 0) return error.ZstdDecompressionFailed;

        return buf;
    }
};

pub const Compressor = struct {
    cctx: *zstd.ZSTD_CCtx,

    pub fn init() !Compressor {
        const cctx = zstd.ZSTD_createCCtx() orelse return error.ZstdContextCreationFailed;
        return Compressor{ .cctx = cctx };
    }

    pub fn deinit(self: *Compressor) void {
        _ = zstd.ZSTD_freeCCtx(self.cctx);
    }

    pub fn compress(self: *Compressor, allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const max_compressed_size = zstd.ZSTD_compressBound(data.len);
        const buf = try allocator.alloc(u8, max_compressed_size);
        errdefer allocator.free(buf);

        const result = zstd.ZSTD_compressCCtx(self.cctx, buf.ptr, max_compressed_size, data.ptr, data.len, 3);
        if (zstd.ZSTD_isError(result) != 0) return error.ZstdCompressionFailed;

        return allocator.realloc(buf, result);
    }
};

test "zstd compression/decompression" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var compressor = try Compressor.init();
    defer compressor.deinit();

    var decompressor = try Decompressor.init();
    defer decompressor.deinit();

    const original_data = "Starbound protocol compression test data. " ** 10;
    const compressed = try compressor.compress(allocator, original_data);
    defer allocator.free(compressed);

    const decompressed = try decompressor.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(original_data, decompressed);
}
