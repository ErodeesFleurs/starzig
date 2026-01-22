const std = @import("std");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");
const utils = @import("utils.zig");

pub const PlayerData = struct {
    name: []const u8,
    uuid: []const u8,
    first_joined: i64,
    last_seen: i64,
    banned: bool = false,
    homes: []const HomeEntry,

    pub const HomeEntry = struct {
        name: []const u8,
        world_id: []const u8,
        x: f32,
        y: f32,
    };
};

pub const InternalPlayerData = struct {
    name: []const u8,
    uuid: []const u8,
    first_joined: i64,
    last_seen: i64,
    banned: bool = false,
    homes: std.StringArrayHashMap(PlayerData.HomeEntry),
};

pub const PlayerManagerPlugin = struct {
    players: std.StringArrayHashMapUnmanaged(InternalPlayerData) = .{},

    pub fn activate(self: *PlayerManagerPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = config;
        const s = storage.Storage.init(ctx.allocator, "data");
        const LoadedData = struct { players: []const PlayerData };

        const parsed = s.loadJson("players.json", LoadedData) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer parsed.deinit();

        for (parsed.value.players) |p| {
            var homes = std.StringArrayHashMap(PlayerData.HomeEntry).init(ctx.allocator);
            for (p.homes) |h| {
                try homes.put(try ctx.allocator.dupe(u8, h.name), .{
                    .name = try ctx.allocator.dupe(u8, h.name),
                    .world_id = try ctx.allocator.dupe(u8, h.world_id),
                    .x = h.x,
                    .y = h.y,
                });
            }

            try self.players.put(ctx.allocator, try ctx.allocator.dupe(u8, p.uuid), .{
                .name = try ctx.allocator.dupe(u8, p.name),
                .uuid = try ctx.allocator.dupe(u8, p.uuid),
                .first_joined = p.first_joined,
                .last_seen = p.last_seen,
                .banned = p.banned,
                .homes = homes,
            });
        }
    }

    pub fn deactivate(self: *PlayerManagerPlugin, ctx: *proxy.ConnectionContext) !void {
        var it = self.players.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.value_ptr.name);
            ctx.allocator.free(entry.value_ptr.uuid);
            var hit = entry.value_ptr.homes.iterator();
            while (hit.next()) |hentry| {
                ctx.allocator.free(hentry.key_ptr.*);
                ctx.allocator.free(hentry.value_ptr.name);
                ctx.allocator.free(hentry.value_ptr.world_id);
            }
            entry.value_ptr.homes.deinit();
        }
        self.players.deinit(ctx.allocator);
    }

    pub fn onPacket(self: *PlayerManagerPlugin, ctx: *proxy.ConnectionContext, p: *proxy.packet.Packet) !bool {
        if (p.header.packet_type == .client_connect) {
            if (ctx.player_uuid) |uuid| {
                const uuid_str = try uuid.toString(ctx.allocator);
                defer ctx.allocator.free(uuid_str);

                if (self.players.getPtr(uuid_str)) |data| {
                    if (data.banned) {
                        try ctx.sendMessage("You are banned from this server.");
                        // Disconnect the client
                        ctx.state = .disconnected;
                        return false;
                    }
                    data.last_seen = std.time.timestamp();
                    if (ctx.player_name) |name| {
                        ctx.allocator.free(data.name);
                        data.name = try ctx.allocator.dupe(u8, name);
                    }
                } else {
                    const homes = std.StringArrayHashMap(PlayerData.HomeEntry).init(ctx.allocator);
                    try self.players.put(ctx.allocator, try ctx.allocator.dupe(u8, uuid_str), .{
                        .name = try ctx.allocator.dupe(u8, ctx.player_name orelse "Unknown"),
                        .uuid = try ctx.allocator.dupe(u8, uuid_str),
                        .first_joined = std.time.timestamp(),
                        .last_seen = std.time.timestamp(),
                        .homes = homes,
                    });
                }
                try self.save(ctx.allocator);
            }
        }
        return true;
    }

    pub fn onChatSent(self: *PlayerManagerPlugin, ctx: *proxy.ConnectionContext, chat: proxy.packet.ChatSent) !bool {
        if (!std.mem.startsWith(u8, chat.message, "/")) return true;

        var it = std.mem.splitScalar(u8, chat.message[1..], ' ');
        const cmd_name = it.first();

        if (std.mem.eql(u8, cmd_name, "sethome")) {
            const home_name = it.next() orelse "default";
            const uuid = ctx.player_uuid orelse return true;
            const uuid_str = try uuid.toString(ctx.allocator);
            defer ctx.allocator.free(uuid_str);

            if (self.players.getPtr(uuid_str)) |data| {
                if (data.homes.getPtr(home_name)) |home| {
                    ctx.allocator.free(home.world_id);
                    home.world_id = try ctx.allocator.dupe(u8, ctx.world_id orelse "");
                    home.x = ctx.player_pos[0];
                    home.y = ctx.player_pos[1];
                } else {
                    try data.homes.put(try ctx.allocator.dupe(u8, home_name), .{
                        .name = try ctx.allocator.dupe(u8, home_name),
                        .world_id = try ctx.allocator.dupe(u8, ctx.world_id orelse ""),
                        .x = ctx.player_pos[0],
                        .y = ctx.player_pos[1],
                    });
                }
                try self.save(ctx.allocator);
                try ctx.sendMessage("Home set!");
            }
            return false;
        } else if (std.mem.eql(u8, cmd_name, "home")) {
            const home_name = it.next() orelse "default";
            const uuid = ctx.player_uuid orelse return true;
            const uuid_str = try uuid.toString(ctx.allocator);
            defer ctx.allocator.free(uuid_str);

            if (self.players.get(uuid_str)) |data| {
                if (data.homes.get(home_name)) |home| {
                    if (std.mem.eql(u8, home.world_id, ctx.world_id orelse "")) {
                        try ctx.warpToPos(.{ home.x, home.y });
                    } else {
                        try ctx.warpToWorld(home.world_id);
                        ctx.pending_warp_pos = .{ home.x, home.y };
                        try ctx.sendMessage("Warping to home world...");
                    }
                } else {
                    try ctx.sendMessage("Home not found.");
                }
            }
            return false;
        } else if (std.mem.eql(u8, cmd_name, "ban")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("Permission denied.");
                return false;
            }

            const target_name = it.next() orelse {
                try ctx.sendMessage("Usage: /ban <player>");
                return false;
            };

            var found = false;
            var it_p = self.players.iterator();
            while (it_p.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.name, target_name)) {
                    entry.value_ptr.banned = true;
                    found = true;
                    break;
                }
            }

            if (found) {
                try self.save(ctx.allocator);
                if (utils.findConnectionByName(ctx.proxy, target_name)) |target_ctx| {
                    try target_ctx.sendMessage("You have been banned.");
                    target_ctx.state = .disconnected;
                }
                try ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Player {s} banned.", .{target_name}));
            } else {
                try ctx.sendMessage("Player not found in database.");
            }
            return false;
        } else if (std.mem.eql(u8, cmd_name, "unban")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("Permission denied.");
                return false;
            }

            const target_name = it.next() orelse {
                try ctx.sendMessage("Usage: /unban <player>");
                return false;
            };

            var found = false;
            var it_p = self.players.iterator();
            while (it_p.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.name, target_name)) {
                    entry.value_ptr.banned = false;
                    found = true;
                    break;
                }
            }

            if (found) {
                try self.save(ctx.allocator);
                try ctx.sendMessage(try std.fmt.allocPrint(ctx.allocator, "Player {s} unbanned.", .{target_name}));
            } else {
                try ctx.sendMessage("Player not found in database.");
            }
            return false;
        }

        return true;
    }

    fn save(self: *PlayerManagerPlugin, allocator: std.mem.Allocator) !void {
        const s = storage.Storage.init(allocator, "data");
        const SavedData = struct { players: []const PlayerData };

        var p_list = std.ArrayListUnmanaged(PlayerData){};
        defer {
            for (p_list.items) |p| {
                allocator.free(p.homes);
            }
            p_list.deinit(allocator);
        }

        var it = self.players.iterator();
        while (it.next()) |entry| {
            var h_list = std.ArrayListUnmanaged(PlayerData.HomeEntry){};
            var hit = entry.value_ptr.homes.iterator();
            while (hit.next()) |hentry| {
                try h_list.append(allocator, hentry.value_ptr.*);
            }

            try p_list.append(allocator, .{
                .name = entry.value_ptr.name,
                .uuid = entry.value_ptr.uuid,
                .first_joined = entry.value_ptr.first_joined,
                .last_seen = entry.value_ptr.last_seen,
                .banned = entry.value_ptr.banned,
                .homes = try h_list.toOwnedSlice(allocator),
            });
        }

        try s.saveJson("players.json", SavedData{ .players = p_list.items });
    }
};
