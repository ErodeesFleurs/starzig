const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol.zig");
const RingBuffer = @import("ring_buffer.zig").RingBuffer;

pub const SessionState = enum {
    Handshaking,
    Forwarding,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    client_fd: posix.socket_t,
    server_fd: posix.socket_t,
    client_buf: RingBuffer,
    server_buf: RingBuffer,
    decompress_buf: std.ArrayList(u8),

    client_out_queue: std.ArrayList(u8),
    server_out_queue: std.ArrayList(u8),

    last_active_ms: i64,
    state: SessionState = .Handshaking,

    pub fn init(gpa: std.mem.Allocator, c_fd: posix.socket_t, s_fd: posix.socket_t) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.* = .{
            .allocator = gpa,
            .client_fd = c_fd,
            .server_fd = s_fd,
            .client_buf = try RingBuffer.init(gpa, 1024 * 1024),
            .server_buf = try RingBuffer.init(gpa, 1024 * 1024),
            .decompress_buf = std.ArrayList(u8).empty,
            .client_out_queue = std.ArrayList(u8).empty,
            .server_out_queue = std.ArrayList(u8).empty,
            .last_active_ms = std.time.milliTimestamp(),
            .state = .Handshaking,
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.client_buf.deinit(self.allocator);
        self.server_buf.deinit(self.allocator);
        self.decompress_buf.deinit(self.allocator);
        self.client_out_queue.deinit(self.allocator);
        self.server_out_queue.deinit(self.allocator);
        posix.close(self.client_fd);
        posix.close(self.server_fd);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn markActive(self: *Session) void {
        self.last_active_ms = std.time.milliTimestamp();
    }

    pub fn send(self: *Session, dest_fd: posix.socket_t, data: []const u8) !void {
        self.markActive();
        const queue = if (dest_fd == self.client_fd) &self.client_out_queue else &self.server_out_queue;
        if (queue.items.len > 0) {
            try queue.appendSlice(self.allocator, data);
            return;
        }

        const n = posix.write(dest_fd, data) catch |err| {
            if (err == error.WouldBlock) {
                try queue.appendSlice(self.allocator, data);
                return;
            }
            return err;
        };

        if (n < data.len) {
            try queue.appendSlice(self.allocator, data[n..]);
        }
    }

    pub fn flush(self: *Session, fd: posix.socket_t) !void {
        self.markActive();
        const queue = if (fd == self.client_fd) &self.client_out_queue else &self.server_out_queue;
        if (queue.items.len == 0) return;

        const n = posix.write(fd, queue.items) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (n > 0) {
            try queue.replaceRange(self.allocator, 0, n, &[_]u8{});
        }
    }

    pub fn hasPendingData(self: *Session, fd: posix.socket_t) bool {
        const queue = if (fd == self.client_fd) &self.client_out_queue else &self.server_out_queue;
        return queue.items.len > 0;
    }

    fn processHandshakePacket(self: *Session, is_client: bool, packet_id: i8, full_packet: []const u8) !void {
        const dest_fd = if (is_client) self.server_fd else self.client_fd;
        const direction = if (is_client) "C -> S" else "S -> C";

        std.debug.print("[Handshake][{s}] Packet ID: {d}, Len: {d}\n", .{ direction, packet_id, full_packet.len });

        if (!is_client and packet_id == 3) {
            std.debug.print("Handshake completed successfully.\n", .{});
            self.state = .Forwarding;
        }

        try self.send(dest_fd, full_packet);
    }

    pub fn handleData(self: *Session, src_fd: posix.socket_t) !void {
        const is_client = (src_fd == self.client_fd);
        const buffer = if (is_client) &self.client_buf else &self.server_buf;

        const w_slice = buffer.writeSlice();
        if (w_slice.len == 0) return error.BufferFull;

        const n = posix.read(src_fd, w_slice) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };
        if (n == 0) return error.Closed;
        self.markActive();
        buffer.advanceWrite(n);

        while (true) {
            const avail = buffer.readableLen();
            if (avail < 2) break;

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

            const full_packet = try buffer.linearize(packet_size);

            if (self.state == .Handshaking) {
                try self.processHandshakePacket(is_client, packet_id, full_packet);
                buffer.advanceRead(packet_size);
                return;
            } else {
                // 通用高效转发模式
                const dest_fd = if (is_client) self.server_fd else self.client_fd;
                const direction = if (is_client) "C -> S" else "S -> C";

                if (packet_compressed) {
                    const payload = full_packet[header_size..];
                    try protocol.compressor.decompressToArrayList(payload, &self.decompress_buf, self.allocator);
                }

                std.debug.print("[{s}] Packet ID: {d}, Len: {d}\n", .{ direction, packet_id, packet_size });
                try self.send(dest_fd, full_packet);
                buffer.advanceRead(packet_size);
            }
        }
    }
};
