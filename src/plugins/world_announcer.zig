const std = @import("std");
const proxy = @import("../proxy.zig");

const storage = @import("../storage.zig");

pub const WorldAnnouncerPlugin = struct {
    pub fn onPacket(self: *WorldAnnouncerPlugin, ctx: *proxy.ConnectionContext, p: *proxy.packet.Packet) !bool {
        _ = self;
        if (p.header.packet_type == .world_start) {
            if (ctx.world_id) |wid| {
                const s = storage.Storage.init(ctx.allocator, "data");
                const GreetingData = struct { greetings: std.json.ArrayHashMap([]const u8) };
                const parsed = s.loadJson("greetings.json", GreetingData) catch |err| {
                    if (err == error.FileNotFound) {
                        try ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Entering world: {s}", .{wid}));
                        return true;
                    }
                    return err;
                };
                defer parsed.deinit();

                if (parsed.value.greetings.map.get(wid)) |greeting| {
                    try ctx.sendMessage(greeting);
                } else {
                    try ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Entering world: {s}", .{wid}));
                }
            }
        }
        return true;
    }
};
