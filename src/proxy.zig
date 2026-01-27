const std = @import("std");
const net = std.net;
const posix = std.posix;
const Session = @import("session.zig").Session;

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    listener: net.Server,
    target_addr: net.Address,
    sessions: std.AutoHashMap(posix.socket_t, *Session),
    poll_fds: std.ArrayList(posix.pollfd),

    const TIMEOUT_MS = 60000; // 60秒无活动则断开

    pub fn init(allocator: std.mem.Allocator, listen_ip: []const u8, listen_port: u16, target_ip: []const u8, target_port: u16) !Proxy {
        const listen_addr = try net.Address.parseIp(listen_ip, listen_port);
        const target_addr = try net.Address.parseIp(target_ip, target_port);

        var listener = try listen_addr.listen(.{ .reuse_address = true, .force_nonblocking = true });
        errdefer listener.deinit();

        var poll_fds = std.ArrayList(posix.pollfd).empty;
        errdefer poll_fds.deinit(allocator);

        try poll_fds.append(allocator, .{
            .fd = listener.stream.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        });

        return Proxy{
            .allocator = allocator,
            .listener = listener,
            .target_addr = target_addr,
            .sessions = std.AutoHashMap(posix.socket_t, *Session).init(allocator),
            .poll_fds = poll_fds,
        };
    }

    pub fn deinit(self: *Proxy) void {
        var it = self.sessions.valueIterator();
        var seen = std.AutoHashMap(*Session, void).init(self.allocator);
        defer seen.deinit();

        while (it.next()) |session_ptr| {
            const session = session_ptr.*;
            if (seen.get(session) == null) {
                session.deinit();
                seen.put(session, {}) catch {};
            }
        }
        self.sessions.deinit();
        self.poll_fds.deinit(self.allocator);
        self.listener.deinit();
    }

    pub fn run(self: *Proxy) !void {
        std.debug.print("StarryPy-Zig Proxy started...\n", .{});

        while (true) {
            // 在 poll 之前，根据发送队列状态更新 events
            for (self.poll_fds.items) |*pfd| {
                if (pfd.fd == self.listener.stream.handle) continue;
                if (self.sessions.get(pfd.fd)) |session| {
                    pfd.events = posix.POLL.IN;
                    if (session.hasPendingData(pfd.fd)) {
                        pfd.events |= posix.POLL.OUT;
                    }
                }
            }

            const ready_count = try posix.poll(self.poll_fds.items, 1000); // 1秒超时以执行维护任务

            if (ready_count > 0) {
                var i: usize = self.poll_fds.items.len;
                while (i > 0) {
                    i -= 1;
                    const pfd = &self.poll_fds.items[i];
                    if (pfd.revents == 0) continue;

                    if (pfd.fd == self.listener.stream.handle) {
                        if (pfd.revents & posix.POLL.IN != 0) {
                            self.acceptClient() catch |err| {
                                std.debug.print("Failed to accept client: {}\n", .{err});
                            };
                        }
                    } else if (self.sessions.get(pfd.fd)) |session| {
                        // 处理可写事件 (Flush)
                        if (pfd.revents & posix.POLL.OUT != 0) {
                            session.flush(pfd.fd) catch {
                                self.cleanupSession(session);
                                continue;
                            };
                        }
                        // 处理可读事件
                        if (pfd.revents & posix.POLL.IN != 0) {
                            session.handleData(pfd.fd) catch {
                                self.cleanupSession(session);
                                continue;
                            };
                        }
                        // 处理错误
                        if (pfd.revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
                            self.cleanupSession(session);
                        }
                    }
                }
            }

            // 定时清理超时会话
            try self.checkTimeouts();
        }
    }

    fn checkTimeouts(self: *Proxy) !void {
        const now = std.time.milliTimestamp();
        var it = self.sessions.valueIterator();

        var to_remove = std.ArrayList(*Session).empty;
        defer to_remove.deinit(self.allocator);

        var seen = std.AutoHashMap(*Session, void).init(self.allocator);
        defer seen.deinit();

        while (it.next()) |session_ptr| {
            const session = session_ptr.*;
            if (seen.get(session) != null) continue;
            try seen.put(session, {});

            if (now - session.last_active_ms > TIMEOUT_MS) {
                try to_remove.append(self.allocator, session);
            }
        }

        for (to_remove.items) |session| {
            std.debug.print("Session timeout: {} <-> {}\n", .{ session.client_fd, session.server_fd });
            self.cleanupSession(session);
        }
    }

    fn acceptClient(self: *Proxy) !void {
        const client_conn = try self.listener.accept();
        errdefer client_conn.stream.close();
        try setNonBlock(client_conn.stream.handle);

        const server_stream = try net.tcpConnectToAddress(self.target_addr);
        errdefer server_stream.close();
        try setNonBlock(server_stream.handle);

        const session = try Session.init(self.allocator, client_conn.stream.handle, server_stream.handle);
        errdefer session.deinit();

        try self.sessions.put(client_conn.stream.handle, session);
        try self.sessions.put(server_stream.handle, session);

        try self.poll_fds.append(self.allocator, .{ .fd = client_conn.stream.handle, .events = posix.POLL.IN, .revents = 0 });
        try self.poll_fds.append(self.allocator, .{ .fd = server_stream.handle, .events = posix.POLL.IN, .revents = 0 });

        std.debug.print("Session activated: FD {} <-> FD {}\n", .{ session.client_fd, session.server_fd });
    }

    fn cleanupSession(self: *Proxy, session: *Session) void {
        const c_fd = session.client_fd;
        const s_fd = session.server_fd;

        _ = self.sessions.remove(c_fd);
        _ = self.sessions.remove(s_fd);

        var i: usize = 0;
        while (i < self.poll_fds.items.len) {
            const fd = self.poll_fds.items[i].fd;
            if (fd == c_fd or fd == s_fd) {
                _ = self.poll_fds.swapRemove(i);
            } else {
                i += 1;
            }
        }

        std.debug.print("Session closed: {} and {}\n", .{ c_fd, s_fd });
        session.deinit();
    }

    fn setNonBlock(fd: posix.socket_t) !void {
        const flags = posix.O{ .NONBLOCK = true };
        _ = try posix.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(flags)))));
    }
};
