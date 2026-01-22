const std = @import("std");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");
const utils = @import("utils.zig");

pub const WarpPoint = struct {
    name: []const u8,
    world_id: []const u8,
    x: f32,
    y: f32,
};

pub const WarpPlugin = struct {
    warps: std.ArrayListUnmanaged(WarpPoint) = .{},

    pub fn activate(self: *WarpPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = config;
        const s = storage.Storage.init(ctx.allocator, "data");
        const WarpData = struct { warps: []WarpPoint };
        const parsed = s.loadJson("warps.json", WarpData) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer parsed.deinit();

        for (parsed.value.warps) |wp| {
            try self.warps.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, wp.name),
                .world_id = try ctx.allocator.dupe(u8, wp.world_id),
                .x = wp.x,
                .y = wp.y,
            });
        }
    }

    pub fn deactivate(self: *WarpPlugin, ctx: *proxy.ConnectionContext) !void {
        for (self.warps.items) |wp| {
            ctx.allocator.free(wp.name);
            ctx.allocator.free(wp.world_id);
        }
        self.warps.deinit(ctx.allocator);
    }

    pub fn onChatSent(self: *WarpPlugin, ctx: *proxy.ConnectionContext, chat: proxy.packet.ChatSent) !bool {
        if (!std.mem.startsWith(u8, chat.message, "/")) return true;

        var it = std.mem.splitScalar(u8, chat.message[1..], ' ');
        const cmd_name = it.first();

        if (std.mem.eql(u8, cmd_name, "setwarp")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("You do not have permission to use this command.");
                return false;
            }
            const name = it.next() orelse {
                try ctx.sendMessage("Usage: /setwarp <name>");
                return false;
            };

            const world_id = ctx.world_id orelse {
                try ctx.sendMessage("Unknown world ID.");
                return false;
            };

            // Remove existing warp if it exists
            for (self.warps.items, 0..) |wp, i| {
                if (std.mem.eql(u8, wp.name, name)) {
                    ctx.allocator.free(wp.name);
                    ctx.allocator.free(wp.world_id);
                    _ = self.warps.swapRemove(i);
                    break;
                }
            }

            try self.warps.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, name),
                .world_id = try ctx.allocator.dupe(u8, world_id),
                .x = ctx.player_pos[0],
                .y = ctx.player_pos[1],
            });

            try self.save(ctx.allocator);
            try ctx.sendMessage("Warp point set!");
            return false;
        } else if (std.mem.eql(u8, cmd_name, "delwarp")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("You do not have permission to use this command.");
                return false;
            }
            const name = it.next() orelse {
                try ctx.sendMessage("Usage: /delwarp <name>");
                return false;
            };

            for (self.warps.items, 0..) |wp, i| {
                if (std.mem.eql(u8, wp.name, name)) {
                    ctx.allocator.free(wp.name);
                    ctx.allocator.free(wp.world_id);
                    _ = self.warps.swapRemove(i);
                    try self.save(ctx.allocator);
                    try ctx.sendMessage("Warp point deleted.");
                    return false;
                }
            }
            try ctx.sendMessage("Warp point not found.");
            return false;
        } else if (std.mem.eql(u8, cmd_name, "warp") or std.mem.eql(u8, cmd_name, "w")) {
            // Note: /w is also who/warp alias now, need to be careful.
            // In chat.zig we have /w for who. Let's use /wp for warp if we want an alias.
            const name = it.next() orelse {
                try ctx.sendMessage("Usage: /warp <name>");
                return false;
            };

            for (self.warps.items) |wp| {
                if (std.mem.eql(u8, wp.name, name)) {
                    // If same world, just teleport
                    if (std.mem.eql(u8, wp.world_id, ctx.world_id orelse "")) {
                        try ctx.warpToPos(.{ wp.x, wp.y });
                    } else {
                        // Different world requires a WorldWarp packet
                        try ctx.warpToWorld(wp.world_id);

                        // Queue the position warp for when the player arrives
                        ctx.pending_warp_pos = .{ wp.x, wp.y };

                        try ctx.sendMessage("Warping to world...");
                    }
                    return false;
                }
            }
            // If command was specifically /warp, tell them not found.
            // If it was /w and we are here, it might be intended for who.
            // But plugin order matters.
            if (std.mem.eql(u8, cmd_name, "warp")) {
                try ctx.sendMessage("Warp point not found.");
                return false;
            }
            return true;
        } else if (std.mem.eql(u8, cmd_name, "warps")) {
            var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "Available warps: ");
            for (self.warps.items, 0..) |wp, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
                try buf.appendSlice(ctx.allocator, wp.name);
            }
            try ctx.sendMessage(buf.items);
            return false;
        }

        return true;
    }

    pub fn onPacket(self: *WarpPlugin, ctx: *proxy.ConnectionContext, p: *proxy.packet.Packet) !bool {
        _ = self;
        _ = ctx;
        _ = p;
        return true;
    }

    fn save(self: *WarpPlugin, allocator: std.mem.Allocator) !void {
        const s = storage.Storage.init(allocator, "data");
        const WarpData = struct { warps: []WarpPoint };
        try s.saveJson("warps.json", WarpData{ .warps = self.warps.items });
    }
};
