const std = @import("std");
const proxy = @import("proxy.zig");
const plugins = @import("plugins/mod.zig");
const config = @import("config.zig");

pub const vlq = @import("protocol/vlq.zig");
pub const types = @import("protocol/types.zig");
pub const variant = @import("protocol/variant.zig");
pub const packet = @import("protocol/packet.zig");
pub const compression = @import("protocol/compression.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    const cfg = config.Config.load(allocator, "config/config.json") catch |err| {
        std.log.err("Failed to load config: {any}", .{err});
        return err;
    };

    try plugins.Registry.initAll();

    var p = try proxy.Proxy.init(
        allocator,
        cfg.listen_port,
        cfg.upstream_host,
        cfg.upstream_port,
    );
    try p.run(cfg.plugins);
}

test {
    _ = vlq;
    _ = types;
    _ = variant;
    _ = packet;
    _ = compression;
}

test {
    std.testing.refAllDecls(@This());
}
