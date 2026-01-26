const std = @import("std");
const posix = std.posix;

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
    }
};
