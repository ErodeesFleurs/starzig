const std = @import("std");
const toml = @import("toml");

pub const Config = struct {
    proxy_port: u16,
    backend_host: []const u8,
    backend_port: u16,
    motd: []const u8,
    owner_uuid: []const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.backend_host);
        allocator.free(self.motd);
        allocator.free(self.owner_uuid);
    }
};

pub fn loadConfig(path: []const u8, allocator: std.mem.Allocator) !Config {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);
    _ = try file.readAll(buffer);
    const doc = try toml.parse(allocator, buffer);
    defer doc.deinit();
    const proxy_port = try doc.getInt("proxy_port");
    const backend_host = try doc.getStringAlloc(allocator, "backend_host");
    const backend_port = try doc.getInt("backend_port");
    const motd = try doc.getStringAlloc(allocator, "motd");
    const owner_uuid = try doc.getStringAlloc(allocator, "owner_uuid");
    return Config{
        .proxy_port = @as(u16, proxy_port),
        .backend_host = backend_host,
        .backend_port = @as(u16, backend_port),
        .motd = motd,
        .owner_uuid = owner_uuid,
    };
}
