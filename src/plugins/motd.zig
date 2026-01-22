const std = @import("std");
const proxy = @import("../proxy.zig");

pub const MotdPlugin = struct {
    motd: []const u8 = "Welcome to StarryPy Zig Edition!",

    pub fn activate(self: *MotdPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = self;
        _ = ctx;
        _ = config;
        // Motd is usually sent after connect_success or when the world starts.
        // We can hook into on_client_connect or just check state in onPacket.
    }

    pub fn onPacket(self: *MotdPlugin, ctx: *proxy.ConnectionContext, p: *proxy.packet.Packet) !bool {
        if (p.header.packet_type == .connect_success) {
            try ctx.sendMessage(self.motd);
        }
        return true;
    }
};
