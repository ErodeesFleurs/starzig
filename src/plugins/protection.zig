const std = @import("std");
const packet = @import("../protocol/packet.zig");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");
const utils = @import("utils.zig");

pub const ProtectedArea = struct {
    world_id: []const u8,
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    owners: [][]const u8,

    pub fn contains(self: ProtectedArea, x: i32, y: i32) bool {
        const min_x = @min(self.x1, self.x2);
        const max_x = @max(self.x1, self.x2);
        const min_y = @min(self.y1, self.y2);
        const max_y = @max(self.y1, self.y2);
        return x >= min_x and x <= max_x and y >= min_y and y <= max_y;
    }
};

pub const ProtectionPlugin = struct {
    protected_areas: std.ArrayListUnmanaged(ProtectedArea) = .{},

    pub fn activate(self: *ProtectionPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = config;
        const s = storage.Storage.init(ctx.allocator, "data");
        const ProtectionData = struct { areas: []ProtectedArea };
        const parsed = s.loadJson("protection.json", ProtectionData) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer parsed.deinit();

        for (parsed.value.areas) |area| {
            var owners = std.ArrayListUnmanaged([]const u8){};
            for (area.owners) |owner| {
                try owners.append(ctx.allocator, try ctx.allocator.dupe(u8, owner));
            }
            try self.protected_areas.append(ctx.allocator, .{
                .world_id = try ctx.allocator.dupe(u8, area.world_id),
                .x1 = area.x1,
                .y1 = area.y1,
                .x2 = area.x2,
                .y2 = area.y2,
                .owners = try owners.toOwnedSlice(ctx.allocator),
            });
        }
    }

    pub fn deactivate(self: *ProtectionPlugin, ctx: *proxy.ConnectionContext) !void {
        for (self.protected_areas.items) |area| {
            ctx.allocator.free(area.world_id);
            for (area.owners) |owner| ctx.allocator.free(owner);
            ctx.allocator.free(area.owners);
        }
        self.protected_areas.deinit(ctx.allocator);
    }

    pub fn onModifyTileList(self: *ProtectionPlugin, ctx: *proxy.ConnectionContext, p: packet.ModifyTileList) !bool {
        if (try utils.isAdmin(ctx)) return true;

        const world_id = ctx.world_id orelse return true;
        const uuid = ctx.player_uuid orelse return true;
        const uuid_str = try uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        for (p.tiles) |tile| {
            if (self.findAreaAt(world_id, tile.x, tile.y)) |area| {
                var is_owner = false;
                for (area.owners) |owner| {
                    if (std.mem.eql(u8, owner, uuid_str)) {
                        is_owner = true;
                        break;
                    }
                }
                if (!is_owner) {
                    try ctx.sendMessage("This area is protected.");
                    return false;
                }
            }
        }
        return true;
    }

    pub fn onEntityInteract(self: *ProtectionPlugin, ctx: *proxy.ConnectionContext, p: packet.EntityInteract) !bool {
        _ = p;
        if (try utils.isAdmin(ctx)) return true;

        const world_id = ctx.world_id orelse return true;
        const pos = ctx.player_pos;
        const uuid = ctx.player_uuid orelse return true;
        const uuid_str = try uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        if (self.findAreaAt(world_id, @intFromFloat(pos[0]), @intFromFloat(pos[1]))) |area| {
            var is_owner = false;
            for (area.owners) |owner| {
                if (std.mem.eql(u8, owner, uuid_str)) {
                    is_owner = true;
                    break;
                }
            }
            if (!is_owner) {
                try ctx.sendMessage("Interaction is protected in this area.");
                return false;
            }
        }

        return true;
    }

    pub fn onChatSent(self: *ProtectionPlugin, ctx: *proxy.ConnectionContext, chat: packet.ChatSent) !bool {
        if (!std.mem.startsWith(u8, chat.message, "/")) return true;

        var it = std.mem.splitScalar(u8, chat.message[1..], ' ');
        const cmd_name = it.first();

        if (std.mem.eql(u8, cmd_name, "protect")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("You do not have permission to use this command.");
                return false;
            }
            const radius = std.fmt.parseInt(i32, it.next() orelse "10", 10) catch 10;
            const world_id = ctx.world_id orelse return true;
            const pos_x: i32 = @intFromFloat(ctx.player_pos[0]);
            const pos_y: i32 = @intFromFloat(ctx.player_pos[1]);

            const uuid = ctx.player_uuid orelse return true;
            const uuid_str = try uuid.toString(ctx.allocator);
            defer ctx.allocator.free(uuid_str);

            var owners = try ctx.allocator.alloc([]const u8, 1);
            owners[0] = try ctx.allocator.dupe(u8, uuid_str);

            try self.protected_areas.append(ctx.allocator, .{
                .world_id = try ctx.allocator.dupe(u8, world_id),
                .x1 = pos_x - radius,
                .y1 = pos_y - radius,
                .x2 = pos_x + radius,
                .y2 = pos_y + radius,
                .owners = owners,
            });

            try self.save(ctx.allocator);
            try ctx.sendMessage("Area protected!");
            return false;
        } else if (std.mem.eql(u8, cmd_name, "unprotect")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("You do not have permission to use this command.");
                return false;
            }
            const world_id = ctx.world_id orelse return true;
            const pos_x: i32 = @intFromFloat(ctx.player_pos[0]);
            const pos_y: i32 = @intFromFloat(ctx.player_pos[1]);

            var removed = false;
            var i: usize = 0;
            while (i < self.protected_areas.items.len) {
                const area = self.protected_areas.items[i];
                if (std.mem.eql(u8, area.world_id, world_id) and area.contains(pos_x, pos_y)) {
                    ctx.allocator.free(area.world_id);
                    _ = self.protected_areas.swapRemove(i);
                    removed = true;
                    // Continue to remove all overlapping protections at this spot
                } else {
                    i += 1;
                }
            }

            if (removed) {
                try self.save(ctx.allocator);
                try ctx.sendMessage("Protection removed.");
            } else {
                try ctx.sendMessage("No protection found at your position.");
            }
            return false;
        } else if (std.mem.eql(u8, cmd_name, "add_builder")) {
            if (!try utils.isAdmin(ctx)) {
                try ctx.sendMessage("Permission denied.");
                return false;
            }
            const target_name = it.next() orelse {
                try ctx.sendMessage("Usage: /add_builder <player_name>");
                return false;
            };

            const target_ctx = utils.findConnectionByName(ctx.proxy, target_name) orelse {
                try ctx.sendMessage("Player offline.");
                return false;
            };

            const target_uuid = target_ctx.player_uuid orelse return true;
            const target_uuid_str = try target_uuid.toString(ctx.allocator);
            defer ctx.allocator.free(target_uuid_str);

            const world_id = ctx.world_id orelse return true;
            const pos_x: i32 = @intFromFloat(ctx.player_pos[0]);
            const pos_y: i32 = @intFromFloat(ctx.player_pos[1]);

            if (self.findAreaAt(world_id, pos_x, pos_y)) |area| {
                var exists = false;
                for (area.owners) |owner| {
                    if (std.mem.eql(u8, owner, target_uuid_str)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    const old_owners = area.owners;
                    var new_owners = try ctx.allocator.alloc([]const u8, old_owners.len + 1);
                    for (old_owners, 0..) |o, idx| new_owners[idx] = try ctx.allocator.dupe(u8, o);
                    new_owners[old_owners.len] = try ctx.allocator.dupe(u8, target_uuid_str);

                    // Note: In place update of owners slice. Since it's a pointer in the arraylist items.
                    // Actually we need to update the area in the list.
                    for (self.protected_areas.items) |*a| {
                        if (a == area) {
                            for (a.owners) |o| ctx.allocator.free(o);
                            ctx.allocator.free(a.owners);
                            a.owners = new_owners;
                            break;
                        }
                    }
                    try self.save(ctx.allocator);
                    try ctx.sendMessage("Builder added!");
                } else {
                    try ctx.sendMessage("Player is already a builder.");
                }
            } else {
                try ctx.sendMessage("No protected area here.");
            }
            return false;
        }

        return true;
    }

    fn findAreaAt(self: *ProtectionPlugin, world_id: []const u8, x: i32, y: i32) ?*ProtectedArea {
        for (self.protected_areas.items) |*area| {
            if (std.mem.eql(u8, area.world_id, world_id)) {
                if (area.contains(x, y)) return area;
            }
        }
        return null;
    }

    fn isProtected(self: *ProtectionPlugin, world_id: []const u8, x: i32, y: i32) bool {
        return self.findAreaAt(world_id, x, y) != null;
    }

    fn save(self: *ProtectionPlugin, allocator: std.mem.Allocator) !void {
        const s = storage.Storage.init(allocator, "data");
        const ProtectionData = struct { areas: []ProtectedArea };
        try s.saveJson("protection.json", ProtectionData{ .areas = self.protected_areas.items });
    }
};
