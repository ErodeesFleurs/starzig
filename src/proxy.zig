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
        while (it.next()) |session_ptr| {
            session_ptr.*.deinit();
        }
        self.sessions.deinit();
        self.poll_fds.deinit(self.allocator);
        self.listener.deinit();
    }

    pub fn run(self: *Proxy) !void {
        std.debug.print("StarryPy-Zig Proxy started...\n", .{});

        while (true) {
            const ready_count = try posix.poll(self.poll_fds.items, -1);
            if (ready_count == 0) continue;

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
                } else {
                    if (self.sessions.get(pfd.fd)) |session| {
                        session.handleData(pfd.fd) catch {
                            self.cleanupSession(session);
                        };
                    }
                }
            }
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

        // Remove from poll_fds
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
