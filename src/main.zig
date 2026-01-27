const std = @import("std");
const Proxy = @import("proxy.zig").Proxy;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var proxy = try Proxy.init(allocator, "127.0.0.1", 21025, "127.0.0.1", 21024);
    defer proxy.deinit();

    try proxy.run();
}
