const std = @import("std");
const net = std.net;
const posix = std.posix;

const Session = @import("session.zig").Session;
const Protocol = @import("protocol.zig").Protocol;

const SessionMap = std.AutoHashMap(posix.socket_t, *Session);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var sessions = SessionMap.init(allocator);
    defer sessions.deinit();

    const listen_addr = try net.Address.parseIp("127.0.0.1", 21025);
    const target_addr = try net.Address.parseIp("127.0.0.1", 21024);

    var listener = try listen_addr.listen(.{ .reuse_address = true, .force_nonblocking = true });
    defer listener.deinit();

    var poll_fds = std.ArrayList(posix.pollfd).empty;
    defer poll_fds.deinit(allocator);

    try poll_fds.append(allocator, .{
        .fd = listener.stream.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    std.debug.print("StarryPy-Zig 代理启动: 21024 -> 21025\n", .{});

    while (true) {
        const ready_count = try posix.poll(poll_fds.items, -1);
        if (ready_count == 0) continue;

        var i: usize = poll_fds.items.len;
        while (i > 0) {
            i -= 1;
            const pfd = &poll_fds.items[i];

            if (pfd.revents == 0) continue;

            if (pfd.fd == listener.stream.handle) {
                // 处理新连接
                if (pfd.revents & posix.POLL.IN != 0) {
                    acceptClient(allocator, &poll_fds, &listener, target_addr, &sessions) catch |err| {
                        std.debug.print("会话建立失败: {}\n", .{err});
                    };
                }
            } else {
                // 处理已连接的数据交换
                handleForwarding(allocator, &poll_fds, i, &sessions) catch {
                    cleanupSession(&poll_fds, i, &sessions);
                };
            }
        }
    }
}

fn setNonBlock(fd: posix.socket_t) !void {
    const flags = posix.O{ .NONBLOCK = true };
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(flags)))));
}

fn acceptClient(gpa: std.mem.Allocator, poll_fds: *std.ArrayList(posix.pollfd), listener: *net.Server, target: net.Address, sessions: *SessionMap) !void {
    const client_conn = try listener.accept();
    errdefer client_conn.stream.close();
    try setNonBlock(client_conn.stream.handle);

    const server_stream = net.tcpConnectToAddress(target) catch |err| {
        std.debug.print("无法连接到服务器 21025: {}\n", .{err});
        return err;
    };
    errdefer server_stream.close();
    try setNonBlock(client_conn.stream.handle);

    const session = try Session.init(gpa, client_conn.stream.handle, server_stream.handle);
    try sessions.put(client_conn.stream.handle, session);
    try sessions.put(server_stream.handle, session);

    try poll_fds.append(gpa, .{ .fd = client_conn.stream.handle, .events = posix.POLL.IN, .revents = 0 });
    try poll_fds.append(gpa, .{ .fd = server_stream.handle, .events = posix.POLL.IN, .revents = 0 });
    std.debug.print("会话激活: FD {} <-> FD {}\n", .{ session.client_fd, session.server_fd });
}

fn handleForwarding(gpa: std.mem.Allocator, poll_fds: *std.ArrayList(posix.pollfd), idx: usize, sessions: *SessionMap) !void {
    const src_fd = poll_fds.items[idx].fd;
    const session = sessions.get(src_fd) orelse return error.NoSession;

    const is_client = (src_fd == session.client_fd);
    const dest_fd = if (is_client) session.server_fd else session.client_fd;
    const buffer = if (is_client) &session.client_buf else &session.server_buf;

    var temp_buf: [16384]u8 = undefined;
    const n = posix.read(src_fd, &temp_buf) catch |err| {
        if (err == error.WouldBlock) return;
        return err;
    };
    if (n == 0) return error.Closed;
    try buffer.appendSlice(gpa, temp_buf[0..n]);

    while (buffer.items.len >= 2) { // 至少要有 ID(1b) + VarInt最小(1b)
        const data = buffer.items;
        const packet_id = @as(i8, @bitCast(data[0]));

        std.log.debug("包id: {}", .{packet_id});

        const varint = Protocol.decodeSignedVLQ(data[1..]) catch |err| {
            if (err == error.Incomplete) break; // VarInt 还没收全
            return err;
        };
        const packet_compressed = varint.value < 0;
        const header_size = 1 + varint.bytes_read;
        const packet_size = @as(usize, @intCast(if (packet_compressed) -varint.value else varint.value)) + header_size;

        if (data.len < packet_size) break; // Payload 还没收全

        const full_packet = data[0..packet_size];

        const payload = full_packet[header_size..];

        if (packet_compressed) {
            const decompressed = Protocol.decompressPayload(gpa, payload) catch |err| {
                std.log.err("解压失败: {}", .{err});
                return err;
            };
            defer gpa.free(decompressed);

            // 插件处理解压后的数据
            // try handlePacketHooks(packet_id, decompressed, is_client, session);
        } else {
            // 插件处理原始数据
            // try handlePacketHooks(packet_id, payload, is_client, session);
        }

        const direction = if (is_client) "C -> S" else "S -> C";
        std.debug.print("[{s}] Packet ID: {d}, Len: {d}\n", .{ direction, packet_id, packet_size });

        _ = try posix.write(dest_fd, full_packet);

        try buffer.replaceRange(gpa, 0, packet_size, &[_]u8{});
    }
}

fn cleanupSession(poll_fds: *std.ArrayList(posix.pollfd), idx: usize, sessions: *SessionMap) void {
    const fd = poll_fds.items[idx].fd;
    if (sessions.get(fd)) |session| {
        std.debug.print("关闭会话: {} 和 {}\n", .{ session.client_fd, session.server_fd });
        const c_fd = session.client_fd;
        const s_fd = session.server_fd;
        _ = sessions.remove(c_fd);
        _ = sessions.remove(s_fd);
        posix.close(session.client_fd);
        posix.close(session.server_fd);

        for (poll_fds.items, 0..) |pfd, j| {
            if (pfd.fd == (if (fd == c_fd) s_fd else c_fd)) {
                _ = poll_fds.swapRemove(j);
                break;
            }
        }
        session.deinit();
    }
    _ = poll_fds.swapRemove(idx);
}
