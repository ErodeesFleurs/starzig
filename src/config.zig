const std = @import("std");

pub const Config = struct {
    listen_port: u16 = 21025,
    upstream_host: []const u8 = "127.0.0.1",
    upstream_port: u16 = 21024,
    plugins: std.json.Value = .null,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(data);

        const parse_config: std.json.Parsed(Config) = try std.json.parseFromSlice(Config, allocator, data, .{ .ignore_unknown_fields = true });

        var cfg = parse_config.value;

        cfg.upstream_host = try allocator.dupe(u8, parse_config.value.upstream_host);
        return cfg;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.upstream_host);
    }
};
