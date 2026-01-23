const std = @import("std");

pub const zstd = @cImport({
    @cInclude("zstd.h");
});

pub const zlib = @cImport({
    @cInclude("zlib.h");
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

/// Zlib decompression for individual packets using system zlib
pub fn decompressZlib(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var stream: zlib.z_stream = undefined;
    @memset(std.mem.asBytes(&stream), 0);
    stream.next_in = @constCast(data.ptr);
    stream.avail_in = @intCast(data.len);

    if (zlib.inflateInit(&stream) != zlib.Z_OK) return error.ZlibInitFailed;

    defer _ = zlib.inflateEnd(&stream);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;

        const ret = zlib.inflate(&stream, zlib.Z_NO_FLUSH);
        if (ret != zlib.Z_OK and ret != zlib.Z_STREAM_END) return error.ZlibDecompressionFailed;

        try out.appendSlice(allocator, buf[0 .. buf.len - stream.avail_out]);
        if (ret == zlib.Z_STREAM_END) break;
    }

    return out.toOwnedSlice(allocator);
}

/// Zlib compression for individual packets using system zlib
pub fn compressZlib(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var stream: zlib.z_stream = undefined;
    @memset(std.mem.asBytes(&stream), 0);
    stream.next_in = @constCast(data.ptr);
    stream.avail_in = @intCast(data.len);

    if (zlib.deflateInit(&stream, zlib.Z_DEFAULT_COMPRESSION) != zlib.Z_OK) return error.ZlibInitFailed;
    defer _ = zlib.deflateEnd(&stream);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;

        const ret = zlib.deflate(&stream, zlib.Z_FINISH);
        if (ret != zlib.Z_OK and ret != zlib.Z_STREAM_END) return error.ZlibCompressionFailed;

        try out.appendSlice(allocator, buf[0 .. buf.len - stream.avail_out]);
        if (ret == zlib.Z_STREAM_END) break;
    }

    return out.toOwnedSlice(allocator);
}

pub const ZstdStreamDecompressor = struct {
    dctx: *zstd.ZSTD_DCtx,
    allocator: std.mem.Allocator,
    input_buf: []u8,
    output_buf: []u8,
    output_pos: usize = 0,
    output_end: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*ZstdStreamDecompressor {
        const self = try allocator.create(ZstdStreamDecompressor);
        const dctx = zstd.ZSTD_createDCtx() orelse return error.ZstdContextCreationFailed;
        self.* = .{
            .dctx = dctx,
            .allocator = allocator,
            .input_buf = try allocator.alloc(u8, zstd.ZSTD_DStreamInSize()),
            .output_buf = try allocator.alloc(u8, zstd.ZSTD_DStreamOutSize()),
        };
        return self;
    }

    pub fn deinit(self: *ZstdStreamDecompressor) void {
        _ = zstd.ZSTD_freeDCtx(self.dctx);
        self.allocator.free(self.input_buf);
        self.allocator.free(self.output_buf);
        self.allocator.destroy(self);
    }

    pub fn read(self: *ZstdStreamDecompressor, inner_reader: anytype, dest: []u8) !usize {
        var bytes_read: usize = 0;
        while (bytes_read < dest.len) {
            if (self.output_pos < self.output_end) {
                const to_copy = @min(dest.len - bytes_read, self.output_end - self.output_pos);
                @memcpy(dest[bytes_read .. bytes_read + to_copy], self.output_buf[self.output_pos .. self.output_pos + to_copy]);
                self.output_pos += to_copy;
                bytes_read += to_copy;
                continue;
            }

            // Decompress more data
            var fw = std.io.Writer.fixed(self.input_buf);
            const raw_bytes = try inner_reader.vtable.stream(@constCast(inner_reader), &fw, .limited(self.input_buf.len));
            if (raw_bytes == 0) return bytes_read;

            var input = zstd.ZSTD_inBuffer{ .src = self.input_buf.ptr, .size = raw_bytes, .pos = 0 };
            while (input.pos < input.size) {
                var output = zstd.ZSTD_outBuffer{ .dst = self.output_buf.ptr, .size = self.output_buf.len, .pos = 0 };
                const ret = zstd.ZSTD_decompressStream(self.dctx, &output, &input);
                if (zstd.ZSTD_isError(ret) != 0) return error.ZstdDecompressionFailed;

                if (output.pos > 0) {
                    self.output_pos = 0;
                    self.output_end = output.pos;
                    break;
                }
            }
        }
        return bytes_read;
    }
};

pub const ZstdStreamCompressor = struct {
    cctx: *zstd.ZSTD_CCtx,
    allocator: std.mem.Allocator,
    output_buf: []u8,

    pub fn init(allocator: std.mem.Allocator) !*ZstdStreamCompressor {
        const self = try allocator.create(ZstdStreamCompressor);
        const cctx = zstd.ZSTD_createCCtx() orelse return error.ZstdContextCreationFailed;
        _ = zstd.ZSTD_CCtx_setParameter(cctx, zstd.ZSTD_c_compressionLevel, 3);
        self.* = .{
            .cctx = cctx,
            .allocator = allocator,
            .output_buf = try allocator.alloc(u8, zstd.ZSTD_CStreamOutSize()),
        };
        return self;
    }

    pub fn deinit(self: *ZstdStreamCompressor) void {
        _ = zstd.ZSTD_freeCCtx(self.cctx);
        self.allocator.free(self.output_buf);
        self.allocator.destroy(self);
    }

    pub fn write(self: *ZstdStreamCompressor, inner_writer: anytype, data: []const u8) !usize {
        var input = zstd.ZSTD_inBuffer{ .src = data.ptr, .size = data.len, .pos = 0 };
        while (input.pos < input.size) {
            var output = zstd.ZSTD_outBuffer{ .dst = self.output_buf.ptr, .size = self.output_buf.len, .pos = 0 };
            const ret = zstd.ZSTD_compressStream2(self.cctx, &output, &input, zstd.ZSTD_e_flush);
            if (zstd.ZSTD_isError(ret) != 0) return error.ZstdCompressionFailed;
            if (output.pos > 0) {
                try inner_writer.writeAll(self.output_buf[0..output.pos]);
            }
        }
        return data.len;
    }
};
