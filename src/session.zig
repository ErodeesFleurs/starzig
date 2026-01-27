const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");

pub const Session = struct {
    allocator: std.mem.Allocator,
    client_fd: posix.socket_t,
    server_fd: posix.socket_t,
    client_buf: std.ArrayList(u8),
    server_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, c_fd: posix.socket_t, s_fd: posix.socket_t) !*Session {
        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .client_fd = c_fd,
            .server_fd = s_fd,
            .client_buf = std.ArrayList(u8).empty,
            .server_buf = std.ArrayList(u8).empty,
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.client_buf.deinit(self.allocator);
        self.server_buf.deinit(self.allocator);
        posix.close(self.client_fd);
        posix.close(self.server_fd);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn handleData(self: *Session, src_fd: posix.socket_t) !void {
        const is_client = (src_fd == self.client_fd);
        const dest_fd = if (is_client) self.server_fd else self.client_fd;
        const buffer = if (is_client) &self.client_buf else &self.server_buf;

        var temp_buf: [16384]u8 = undefined;
        const n = posix.read(src_fd, &temp_buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        if (n == 0) return error.Closed;
        try buffer.appendSlice(self.allocator, temp_buf[0..n]);

        while (buffer.items.len >= 2) {
            const data = buffer.items;
            const packet_id = @as(i8, @bitCast(data[0]));

            const varint = protocol.vlq.decodeSigned(data[1..]) catch |err| {
                if (err == error.Incomplete) break;
                return err;
            };

            const packet_compressed = varint.value < 0;
            const header_size = 1 + varint.bytes_read;
            const payload_size = @as(usize, @intCast(if (packet_compressed) -varint.value else varint.value));
            const packet_size = payload_size + header_size;

            if (data.len < packet_size) break;

            const full_packet = data[0..packet_size];
            const payload = full_packet[header_size..];

            if (packet_compressed) {
                const decompressed = try protocol.compressor.decompressPayload(self.allocator, payload);
                defer self.allocator.free(decompressed);
                // TODO: 钩子处理
            } else {
                // TODO: 钩子处理
            }

            const direction = if (is_client) "C -> S" else "S -> C";
            std.debug.print("[{s}] Packet ID: {d}, Len: {d}\n", .{ direction, packet_id, packet_size });

            _ = try posix.write(dest_fd, full_packet);
            try buffer.replaceRange(self.allocator, 0, packet_size, &[_]u8{});
        }
    }
};
