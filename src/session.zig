const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const Session = struct {
    allocator: std.mem.Allocator,
    client_fd: posix.socket_t,
    server_fd: posix.socket_t,
    client_buf: RingBuffer,
    server_buf: RingBuffer,
    decompress_buf: std.ArrayList(u8),

    pub fn init(gpa: std.mem.Allocator, c_fd: posix.socket_t, s_fd: posix.socket_t) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.* = .{
            .allocator = gpa,
            .client_fd = c_fd,
            .server_fd = s_fd,
            // 增加缓冲区大小到 1MB 以支持大型数据包（如世界数据）
            .client_buf = try RingBuffer.init(gpa, 1024 * 1024),
            .server_buf = try RingBuffer.init(gpa, 1024 * 1024),
            .decompress_buf = std.ArrayList(u8).empty,
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.client_buf.deinit(self.allocator);
        self.server_buf.deinit(self.allocator);
        self.decompress_buf.deinit(self.allocator);
        posix.close(self.client_fd);
        posix.close(self.server_fd);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn writeAll(fd: posix.socket_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = posix.write(fd, data[written..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.yield() catch {};
                    continue;
                }
                return err;
            };
            if (n == 0) return error.Closed;
            written += n;
        }
    }

    pub fn handleData(self: *Session, src_fd: posix.socket_t) !void {
        const is_client = (src_fd == self.client_fd);
        const dest_fd = if (is_client) self.server_fd else self.client_fd;
        const buffer = if (is_client) &self.client_buf else &self.server_buf;

        const w_slice = buffer.writeSlice();
        if (w_slice.len == 0) return error.BufferFull;

        const n = posix.read(src_fd, w_slice) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        if (n == 0) return error.Closed;
        buffer.advanceWrite(n);

        while (true) {
            const avail = buffer.readableLen();
            if (avail < 2) break;

            // 线性化以读取 ID 和第一个 VarInt 字节
            const peek_data = try buffer.linearize(@min(avail, 16));
            const packet_id = @as(i8, @bitCast(peek_data[0]));

            const varint = protocol.vlq.decodeSigned(peek_data[1..]) catch |err| {
                if (err == error.Incomplete) break;
                return err;
            };

            const packet_compressed = varint.value < 0;
            const header_size = 1 + varint.bytes_read;
            const payload_size = @as(usize, @intCast(if (packet_compressed) -varint.value else varint.value));
            const packet_size = payload_size + header_size;

            if (avail < packet_size) break;

            // 线性化完整包以供后续处理
            const full_packet = try buffer.linearize(packet_size);
            const payload = full_packet[header_size..];

            if (packet_compressed) {
                try protocol.compressor.decompressToArrayList(payload, &self.decompress_buf, self.allocator);
            }

            const direction = if (is_client) "C -> S" else "S -> C";
            std.debug.print("[{s}] Packet ID: {d}, Len: {d}\n", .{ direction, packet_id, packet_size });

            // 使用 writeAll 确保数据不被截断，防止服务端报 TcpPacketSocket 错误
            try writeAll(dest_fd, full_packet);
            buffer.advanceRead(packet_size);
        }
    }
};
