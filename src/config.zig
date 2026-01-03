const std = @import("std");

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

    const buffer = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(buffer);

    const parser = try std.json.parseFromSlice(Config, allocator, buffer, .{
        .ignore_unknown_fields = true,
    });
    defer parser.deinit();

    var cfg = parser.value;
    const host_copy = try allocator.dupe(u8, cfg.backend_host);
    const motd_copy = try allocator.dupe(u8, cfg.motd);
    const owner_uuid_copy = try allocator.dupe(u8, cfg.owner_uuid);

    cfg.backend_host = host_copy;
    cfg.motd = motd_copy;
    cfg.owner_uuid = owner_uuid_copy;

    return cfg;
}
