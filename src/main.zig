const std = @import("std");
const net = std.net;
const Proxy = @import("proxy.zig").Proxy;
const loadConfig = @import("config.zig").loadConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 加载配置
    const cfg = try loadConfig("config/config.json", allocator);
    defer cfg.deinit(allocator);

    std.log.info("Starting StarryPy Zig proxy...", .{});
    std.log.info("Listening on port {d}", .{cfg.proxy_port});
    std.log.info("Backend server: {s}:{d}", .{ cfg.backend_host, cfg.backend_port });

    // 创建并启动代理
    var proxy = try Proxy.init(allocator, cfg);
    defer proxy.deinit();

    try proxy.run();
}
