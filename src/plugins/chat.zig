const std = @import("std");
const packet = @import("../protocol/packet.zig");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");
const utils = @import("utils.zig");

pub const Command = struct {
    name: []const u8,
    handler: *const fn (*proxy.ConnectionContext, []const []const u8) anyerror!void,
    perm: []const u8 = "user",
};

pub const ChatPlugin = struct {
    pub fn activate(self: *ChatPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = self;
        _ = ctx;
        _ = config;
    }

    const commands = [_]Command{
        .{ .name = "ping", .handler = handlePing, .perm = "user" },
        .{ .name = "who", .handler = handleWho, .perm = "user" },
        .{ .name = "tp", .handler = handleTp, .perm = "admin" },
        .{ .name = "promote", .handler = handlePromote, .perm = "admin" },
        .{ .name = "players", .handler = handlePlayers, .perm = "user" },
        .{ .name = "list", .handler = handlePlayers, .perm = "user" },
        .{ .name = "say", .handler = handleSay, .perm = "admin" },
        .{ .name = "broadcast", .handler = handleBroadcast, .perm = "admin" },
        .{ .name = "demote", .handler = handleDemote, .perm = "admin" },
        .{ .name = "msg", .handler = handleMsg, .perm = "user" },
        .{ .name = "tell", .handler = handleMsg, .perm = "user" },
        .{ .name = "m", .handler = handleMsg, .perm = "user" },
        .{ .name = "r", .handler = handleReply, .perm = "user" },
        .{ .name = "me", .handler = handleMe, .perm = "user" },
        .{ .name = "here", .handler = handleHere, .perm = "user" },
        .{ .name = "help", .handler = handleHelp, .perm = "user" },
        .{ .name = "h", .handler = handleHelp, .perm = "user" },
        .{ .name = "p", .handler = handlePing, .perm = "user" },
        .{ .name = "w", .handler = handleWho, .perm = "user" },
        .{ .name = "ls", .handler = handlePlayers, .perm = "user" },
        .{ .name = "b", .handler = handleBroadcast, .perm = "admin" },
        .{ .name = "set_greeting", .handler = handleSetGreeting, .perm = "admin" },
        .{ .name = "give", .handler = handleGive, .perm = "admin" },
        .{ .name = "mute", .handler = handleMute, .perm = "admin" },
        .{ .name = "unmute", .handler = handleUnmute, .perm = "admin" },
        .{ .name = "claim", .handler = handleClaim, .perm = "user" },
        .{ .name = "unclaim", .handler = handleUnclaim, .perm = "user" },
    };

    pub fn onChatSent(self: *ChatPlugin, ctx: *proxy.ConnectionContext, chat: packet.ChatSent) !bool {
        _ = self;
        if (std.mem.startsWith(u8, chat.message, "/")) {
            var it = std.mem.splitScalar(u8, chat.message[1..], ' ');
            const cmd_name = it.first();

            inline for (commands) |cmd| {
                if (std.mem.eql(u8, cmd_name, cmd.name)) {
                    if (std.mem.eql(u8, cmd.perm, "admin")) {
                        if (!try utils.isAdmin(ctx)) {
                            try ctx.sendMessage("You do not have permission to use this command.");
                            return false;
                        }
                    }

                    var args = std.ArrayListUnmanaged([]const u8){};
                    defer args.deinit(ctx.allocator);
                    while (it.next()) |arg| {
                        try args.append(ctx.allocator, arg);
                    }
                    try cmd.handler(ctx, args.items);
                    return false;
                }
            }
        } else {
            std.log.info("[CHAT] {s}: {s}", .{ ctx.player_name orelse "Unknown", chat.message });
        }
        return true;
    }

    pub fn onPacket(self: *ChatPlugin, ctx: *proxy.ConnectionContext, p: *packet.Packet) !bool {
        _ = self;
        _ = ctx;
        _ = p;
        return true;
    }

    fn handlePing(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        try ctx.sendMessage("Pong from Zig StarryPy!");
    }

    fn handleWho(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        const name = ctx.player_name orelse "Unknown";
        const uuid_str = if (ctx.player_uuid) |u| try u.toString(ctx.allocator) else try ctx.allocator.dupe(u8, "Unknown");
        defer ctx.allocator.free(uuid_str);

        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "You are {s} [UUID: {s}]", .{ name, uuid_str });
        try ctx.sendMessage(msg);
    }

    fn handleWarp(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /warp <world_id>");
            return;
        }
        try ctx.warpToWorld(args[0]);
        try ctx.sendMessage("Warping you...");
    }

    fn handleTp(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /tp <entity_id> OR /tp <x> <y>");
            return;
        }

        if (args.len == 1) {
            const target_id = std.fmt.parseInt(u64, args[0], 10) catch {
                try ctx.sendMessage("Invalid entity ID.");
                return;
            };

            if (ctx.entities.get(target_id)) |info| {
                try ctx.warpToPos(info.position);
                try ctx.sendMessage("Teleported to entity.");
            } else {
                try ctx.sendMessage("Entity not found.");
            }
        } else if (args.len == 2) {
            const x = std.fmt.parseFloat(f32, args[0]) catch {
                try ctx.sendMessage("Invalid X coordinate.");
                return;
            };
            const y = std.fmt.parseFloat(f32, args[1]) catch {
                try ctx.sendMessage("Invalid Y coordinate.");
                return;
            };

            try ctx.warpToPos(.{ x, y });
            try ctx.sendMessage("Teleported to coordinates.");
        }
    }

    fn handlePromote(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /promote <player_name>");
            return;
        }

        const target_name = args[0];
        const target_ctx = utils.findConnectionByName(ctx.proxy, target_name);

        const s = storage.Storage.init(ctx.allocator, "data");
        const AdminList = struct { admins: [][]const u8 };

        if (target_ctx) |t_ctx| {
            const target_uuid = t_ctx.player_uuid orelse {
                try ctx.sendMessage("Player has no UUID.");
                return;
            };
            const target_uuid_str = try target_uuid.toString(ctx.allocator);
            defer ctx.allocator.free(target_uuid_str);

            var current_admins = blk: {
                break :blk s.loadJson("admins.json", AdminList) catch |err| {
                    if (err == error.FileNotFound) {
                        const empty = AdminList{ .admins = try ctx.allocator.alloc([]const u8, 0) };
                        try s.saveJson("admins.json", empty);
                        ctx.allocator.free(empty.admins);
                        break :blk try s.loadJson("admins.json", AdminList);
                    } else return err;
                };
            };
            defer current_admins.deinit();

            for (current_admins.value.admins) |admin| {
                if (std.mem.eql(u8, admin, target_uuid_str)) {
                    try ctx.sendMessage("Player is already an admin.");
                    return;
                }
            }

            var new_list = std.ArrayListUnmanaged([]const u8){};
            defer new_list.deinit(ctx.allocator);
            for (current_admins.value.admins) |admin| {
                try new_list.append(ctx.allocator, try ctx.allocator.dupe(u8, admin));
            }
            try new_list.append(ctx.allocator, try ctx.allocator.dupe(u8, target_uuid_str));

            try s.saveJson("admins.json", AdminList{ .admins = new_list.items });
            try ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Player {s} promoted successfully!", .{target_name}));
            try t_ctx.sendMessage("You have been promoted to admin!");

            for (new_list.items) |item| ctx.allocator.free(item);
        } else {
            try ctx.sendMessage("Player not found or offline.");
        }
    }

    fn handleDemote(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /demote <player_name>");
            return;
        }

        const target_name = args[0];
        const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
            try ctx.sendMessage("Player not found or offline.");
            return;
        };

        const target_uuid = target_ctx.player_uuid orelse {
            try ctx.sendMessage("Player has no UUID.");
            return;
        };

        const target_uuid_str = try target_uuid.toString(ctx.allocator);
        defer ctx.allocator.free(target_uuid_str);

        const s = storage.Storage.init(ctx.allocator, "data");
        const AdminList = struct { admins: [][]const u8 };

        var current_admins = s.loadJson("admins.json", AdminList) catch |err| {
            try ctx.sendMessage("Failed to load admin list.");
            return err;
        };
        defer current_admins.deinit();

        var found = false;
        var new_list = std.ArrayListUnmanaged([]const u8){};
        defer new_list.deinit(ctx.allocator);
        for (current_admins.value.admins) |admin| {
            if (std.mem.eql(u8, admin, target_uuid_str)) {
                found = true;
                continue;
            }
            try new_list.append(ctx.allocator, try ctx.allocator.dupe(u8, admin));
        }

        if (!found) {
            try ctx.sendMessage("Player is not an admin.");
            for (new_list.items) |item| ctx.allocator.free(item);
            return;
        }

        try s.saveJson("admins.json", AdminList{ .admins = new_list.items });
        try ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Player {s} demoted.", .{target_name}));
        try target_ctx.sendMessage("You have been demoted.");

        for (new_list.items) |item| ctx.allocator.free(item);
    }

    fn handleMsg(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 2) {
            try ctx.sendMessage("Usage: /msg <player_name> <message>");
            return;
        }

        const target_name = args[0];
        const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
            try ctx.sendMessage("Player not found or offline.");
            return;
        };

        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);
        for (args[1..], 0..) |arg, i| {
            if (i > 0) try buf.append(ctx.allocator, ' ');
            try buf.appendSlice(ctx.allocator, arg);
        }

        const sender_name = ctx.player_name orelse "Unknown";

        if (target_ctx.last_msg_from) |old| ctx.allocator.free(old);
        target_ctx.last_msg_from = try ctx.allocator.dupe(u8, sender_name);

        const to_msg = try std.fmt.allocPrint(ctx.allocator, "[Msg From: {s}] {s}", .{ sender_name, buf.items });
        defer ctx.allocator.free(to_msg);
        try target_ctx.sendMessage(to_msg);

        const from_msg = try std.fmt.allocPrint(ctx.allocator, "[Msg To: {s}] {s}", .{ target_name, buf.items });
        defer ctx.allocator.free(from_msg);
        try ctx.sendMessage(from_msg);
    }

    fn handleReply(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /r <message>");
            return;
        }

        const target_name = ctx.last_msg_from orelse {
            try ctx.sendMessage("Nobody has messaged you yet.");
            return;
        };

        const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
            try ctx.sendMessage("Target player is now offline.");
            return;
        };

        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);
        for (args, 0..) |arg, i| {
            if (i > 0) try buf.append(ctx.allocator, ' ');
            try buf.appendSlice(ctx.allocator, arg);
        }

        const sender_name = ctx.player_name orelse "Unknown";

        if (target_ctx.last_msg_from) |old| ctx.allocator.free(old);
        target_ctx.last_msg_from = try ctx.allocator.dupe(u8, sender_name);

        const to_msg = try std.fmt.allocPrint(ctx.allocator, "[Msg From: {s}] {s}", .{ sender_name, buf.items });
        defer ctx.allocator.free(to_msg);
        try target_ctx.sendMessage(to_msg);

        const from_msg = try std.fmt.allocPrint(ctx.allocator, "[Msg To: {s}] {s}", .{ target_name, buf.items });
        defer ctx.allocator.free(from_msg);
        try ctx.sendMessage(from_msg);
    }

    fn handleMe(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) return;
        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        for (args, 0..) |arg, i| {
            if (i > 0) try buf.append(ctx.allocator, ' ');
            try buf.appendSlice(ctx.allocator, arg);
        }

        const sender_name = ctx.player_name orelse "Unknown";
        const msg = try std.fmt.allocPrint(ctx.allocator, "^#f0f;* {s} {s}", .{ sender_name, buf.items });
        defer ctx.allocator.free(msg);

        const p = ctx.proxy;
        p.mutex.lock();
        defer p.mutex.unlock();

        for (p.active_connections.items) |conn| {
            try conn.sendMessage(msg);
        }
    }

    fn handleHere(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        const p = ctx.proxy;
        const my_world = ctx.world_id orelse {
            try ctx.sendMessage("You are not on a planet.");
            return;
        };

        p.mutex.lock();
        defer p.mutex.unlock();

        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        try buf.appendSlice(ctx.allocator, "Players here:\n");
        var count: u32 = 0;
        for (p.active_connections.items) |conn| {
            if (conn.world_id) |w| {
                if (std.mem.eql(u8, w, my_world)) {
                    try std.fmt.format(buf.writer(ctx.allocator), "- {s}\n", .{conn.player_name orelse "Unknown"});
                    count += 1;
                }
            }
        }

        if (count == 0) {
            try ctx.sendMessage("Nobody else is here.");
        } else {
            try ctx.sendMessage(buf.items);
        }
    }

    fn handleHelp(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        try buf.appendSlice(ctx.allocator, "Available commands: ");
        inline for (commands, 0..) |cmd, i| {
            if (i > 0) try buf.appendSlice(ctx.allocator, ", ");
            try buf.appendSlice(ctx.allocator, "/");
            try buf.appendSlice(ctx.allocator, cmd.name);
        }
        try ctx.sendMessage(buf.items);
    }

    fn handleSay(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) return;
        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        for (args, 0..) |arg, i| {
            if (i > 0) try buf.append(ctx.allocator, ' ');
            try buf.appendSlice(ctx.allocator, arg);
        }

        try ctx.sendChatToClient("Server", buf.items);
    }

    fn handleBroadcast(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) return;
        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        for (args, 0..) |arg, i| {
            if (i > 0) try buf.append(ctx.allocator, ' ');
            try buf.appendSlice(ctx.allocator, arg);
        }

        const p = ctx.proxy;
        p.mutex.lock();
        defer p.mutex.unlock();

        for (p.active_connections.items) |conn| {
            try conn.sendChatToClient("BROADCAST", buf.items);
        }
    }

    fn handlePlayers(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        const p = ctx.proxy;
        p.mutex.lock();
        defer p.mutex.unlock();

        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        try buf.appendSlice(ctx.allocator, "Connected players:\n");
        for (p.active_connections.items) |conn| {
            const name = conn.player_name orelse "Unknown";
            const world = conn.world_id orelse "Loading...";
            try std.fmt.format(buf.writer(ctx.allocator), "- {s} in {s}\n", .{ name, world });
        }

        try ctx.sendMessage(buf.items);
    }

    fn handleSetGreeting(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        const wid = ctx.world_id orelse {
            try ctx.sendMessage("You are not on a planet.");
            return;
        };

        var buf = std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0) catch unreachable;
        defer buf.deinit(ctx.allocator);

        for (args, 0..) |arg, i| {
            if (i > 0) try buf.append(ctx.allocator, ' ');
            try buf.appendSlice(ctx.allocator, arg);
        }

        const s = storage.Storage.init(ctx.allocator, "data");
        const GreetingData = struct { greetings: std.json.ArrayHashMap([]const u8) };

        var current = blk: {
            break :blk s.loadJson("greetings.json", GreetingData) catch |err| {
                if (err == error.FileNotFound) {
                    var map = std.json.ArrayHashMap([]const u8){};
                    try s.saveJson("greetings.json", GreetingData{ .greetings = map });
                    map.deinit(ctx.allocator);
                    break :blk try s.loadJson("greetings.json", GreetingData);
                } else return err;
            };
        };
        defer current.deinit();

        if (buf.items.len == 0) {
            _ = current.value.greetings.map.swapRemove(wid);
            try ctx.sendMessage("Greeting cleared.");
        } else {
            try current.value.greetings.map.put(ctx.allocator, try ctx.allocator.dupe(u8, wid), try ctx.allocator.dupe(u8, buf.items));
            try ctx.sendMessage("Greeting set!");
        }

        try s.saveJson("greetings.json", current.value);
    }

    fn handleGive(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /give <item> [count]");
            return;
        }

        const item_name = args[0];
        const count = if (args.len >= 2) std.fmt.parseInt(u32, args[1], 10) catch 1 else 1;

        var give = packet.GiveItem{
            .name = try ctx.allocator.dupe(u8, item_name),
            .count = count,
            .variant = 0,
        };
        defer give.deinit(ctx.allocator);

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(ctx.allocator);
        var w_adapter = buf.writer(ctx.allocator).adaptToNewApi(&.{});
        try give.encode(&w_adapter.new_interface);

        try ctx.injectToClient(.give_item, buf.items);
        try ctx.sendMessage("Item sent.");
    }

    fn handleMute(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /mute <player_name>");
            return;
        }

        const target_name = args[0];
        const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
            try ctx.sendMessage("Player not found.");
            return;
        };

        const target_uuid = target_ctx.player_uuid orelse {
            try ctx.sendMessage("Player has no UUID.");
            return;
        };
        const uuid_str = try target_uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        const mute_p = @import("mod.zig").Registry.getMutePlugin();
        try mute_p.mute(ctx, uuid_str);
        try ctx.sendMessage("Player muted.");
        try target_ctx.sendMessage("^red;You have been muted by an admin.");
    }

    fn handleUnmute(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        if (args.len < 1) {
            try ctx.sendMessage("Usage: /unmute <player_name>");
            return;
        }

        const target_name = args[0];
        const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
            try ctx.sendMessage("Player not found.");
            return;
        };

        const target_uuid = target_ctx.player_uuid orelse {
            try ctx.sendMessage("Player has no UUID.");
            return;
        };
        const uuid_str = try target_uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        const mute_p = @import("mod.zig").Registry.getMutePlugin();
        try mute_p.unmute(ctx, uuid_str);
        try ctx.sendMessage("Player unmuted.");
        try target_ctx.sendMessage("^green;You have been unmuted.");
    }

    fn handleClaim(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        const claim_p = @import("mod.zig").Registry.getClaimPlugin();
        try claim_p.handleClaim(ctx, args);
    }

    fn handleUnclaim(ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        const claim_p = @import("mod.zig").Registry.getClaimPlugin();
        try claim_p.handleUnclaim(ctx, args);
    }
};
