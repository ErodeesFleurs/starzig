const std = @import("std");
const proxy = @import("../proxy.zig");
const utils = @import("utils.zig");

pub const TeleportRequest = struct {
    sender_name: []const u8,
    timestamp: i64,
};

pub const TpaPlugin = struct {
    // Map of target_player_name -> Request
    requests: std.StringArrayHashMapUnmanaged(TeleportRequest) = .{},

    pub fn activate(self: *TpaPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = self;
        _ = ctx;
        _ = config;
    }

    pub fn deactivate(self: *TpaPlugin, ctx: *proxy.ConnectionContext) !void {
        var it = self.requests.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            ctx.allocator.free(entry.value_ptr.sender_name);
        }
        self.requests.deinit(ctx.allocator);
    }

    pub fn onChatSent(self: *TpaPlugin, ctx: *proxy.ConnectionContext, chat: proxy.packet.ChatSent) !bool {
        if (!std.mem.startsWith(u8, chat.message, "/")) return true;

        var it = std.mem.splitScalar(u8, chat.message[1..], ' ');
        const cmd_name = it.first();

        if (std.mem.eql(u8, cmd_name, "tpa")) {
            const target_name = it.next() orelse {
                try ctx.sendMessage("Usage: /tpa <player>");
                return false;
            };

            const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
                try ctx.sendMessage("Player not found.");
                return false;
            };

            if (target_ctx == ctx) {
                try ctx.sendMessage("You cannot teleport to yourself.");
                return false;
            }

            const sender_name = ctx.player_name orelse "Unknown";

            // Remove old request if exists
            if (self.requests.fetchSwapRemove(target_name)) |entry| {
                ctx.allocator.free(entry.key);
                ctx.allocator.free(entry.value.sender_name);
            }

            try self.requests.put(ctx.allocator, try ctx.allocator.dupe(u8, target_name), .{
                .sender_name = try ctx.allocator.dupe(u8, sender_name),
                .timestamp = std.time.timestamp(),
            });

            try target_ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Teleport request from {s}. Type /tpaccept or /tpdeny.", .{sender_name}));
            try ctx.sendMessage("Teleport request sent.");
            return false;
        } else if (std.mem.eql(u8, cmd_name, "tpaccept")) {
            const my_name = ctx.player_name orelse return true;
            if (self.requests.fetchSwapRemove(my_name)) |entry| {
                defer {
                    ctx.allocator.free(entry.key);
                    ctx.allocator.free(entry.value.sender_name);
                }

                const sender_ctx = utils.findConnectionByName(ctx.proxy, entry.value.sender_name) orelse {
                    try ctx.sendMessage("Sender is no longer online.");
                    return false;
                };

                // Teleport sender to me
                if (std.mem.eql(u8, sender_ctx.world_id orelse "", ctx.world_id orelse "unknown")) {
                    try sender_ctx.warpToPos(ctx.player_pos);
                } else {
                    try sender_ctx.warpToWorld(ctx.world_id orelse "");
                    sender_ctx.pending_warp_pos = ctx.player_pos;
                }

                try ctx.sendMessage("Request accepted.");
                try sender_ctx.sendMessage("Teleporting...");
                return false;
            } else {
                try ctx.sendMessage("No pending teleport requests.");
                return false;
            }
        } else if (std.mem.eql(u8, cmd_name, "tpdeny")) {
            const my_name = ctx.player_name orelse return true;
            if (self.requests.fetchSwapRemove(my_name)) |entry| {
                ctx.allocator.free(entry.key);
                ctx.allocator.free(entry.value.sender_name);
                try ctx.sendMessage("Request denied.");
                return false;
            } else {
                try ctx.sendMessage("No pending teleport requests.");
                return false;
            }
        }

        return true;
    }
};
