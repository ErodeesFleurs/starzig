const std = @import("std");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");
const utils = @import("utils.zig");
const packet = @import("../protocol/packet.zig");

pub const Claim = struct {
    world_id: []const u8,
    owner_uuid: []const u8,
    owner_name: []const u8,
    members: [][]const u8,
};

pub const ClaimPlugin = struct {
    claims: std.StringArrayHashMapUnmanaged(Claim) = .{},

    pub fn activate(self: *ClaimPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = config;
        const s = storage.Storage.init(ctx.allocator, "data");
        const ClaimData = struct { claims: []Claim };

        const parsed = s.loadJson("claims.json", ClaimData) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer parsed.deinit();

        for (parsed.value.claims) |c| {
            var members = std.ArrayListUnmanaged([]const u8){};
            for (c.members) |m| {
                try members.append(ctx.allocator, try ctx.allocator.dupe(u8, m));
            }

            try self.claims.put(ctx.allocator, try ctx.allocator.dupe(u8, c.world_id), .{
                .world_id = try ctx.allocator.dupe(u8, c.world_id),
                .owner_uuid = try ctx.allocator.dupe(u8, c.owner_uuid),
                .owner_name = try ctx.allocator.dupe(u8, c.owner_name),
                .members = try members.toOwnedSlice(ctx.allocator),
            });
        }
    }

    pub fn deactivate(self: *ClaimPlugin, ctx: *proxy.ConnectionContext) !void {
        var it = self.claims.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
            ctx.allocator.free(entry.value_ptr.world_id);
            ctx.allocator.free(entry.value_ptr.owner_uuid);
            ctx.allocator.free(entry.value_ptr.owner_name);
            for (entry.value_ptr.members) |m| ctx.allocator.free(m);
            ctx.allocator.free(entry.value_ptr.members);
        }
        self.claims.deinit(ctx.allocator);
    }

    fn isAllowed(self: *ClaimPlugin, ctx: *proxy.ConnectionContext) !bool {
        if (try utils.isAdmin(ctx)) return true;
        const world_id = ctx.world_id orelse return true;
        const claim = self.claims.get(world_id) orelse return true;

        const uuid = ctx.player_uuid orelse return false;
        const uuid_str = try uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        if (std.mem.eql(u8, claim.owner_uuid, uuid_str)) return true;
        for (claim.members) |m| {
            if (std.mem.eql(u8, m, uuid_str)) return true;
        }
        return false;
    }

    pub fn onModifyTileList(self: *ClaimPlugin, ctx: *proxy.ConnectionContext, p: packet.ModifyTileList) !bool {
        _ = p;
        if (!try self.isAllowed(ctx)) {
            try ctx.sendMessage("^red;This planet is claimed by another player.");
            return false;
        }
        return true;
    }

    pub fn onEntityInteract(self: *ClaimPlugin, ctx: *proxy.ConnectionContext, p: packet.EntityInteract) !bool {
        _ = p;
        if (!try self.isAllowed(ctx)) {
            try ctx.sendMessage("^red;This planet is claimed. Interaction denied.");
            return false;
        }
        return true;
    }

    pub fn handleClaim(self: *ClaimPlugin, ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        const world_id = ctx.world_id orelse {
            try ctx.sendMessage("You are not on a planet.");
            return;
        };

        if (self.claims.contains(world_id)) {
            try ctx.sendMessage("This planet is already claimed.");
            return;
        }

        const uuid = ctx.player_uuid orelse return;
        const uuid_str = try uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        try self.claims.put(ctx.allocator, try ctx.allocator.dupe(u8, world_id), .{
            .world_id = try ctx.allocator.dupe(u8, world_id),
            .owner_uuid = try ctx.allocator.dupe(u8, uuid_str),
            .owner_name = try ctx.allocator.dupe(u8, ctx.player_name orelse "Unknown"),
            .members = try ctx.allocator.alloc([]const u8, 0),
        });

        try self.save(ctx.allocator);
        try ctx.sendMessage("^green;Planet claimed successfully!");
    }

    pub fn handleUnclaim(self: *ClaimPlugin, ctx: *proxy.ConnectionContext, args: []const []const u8) !void {
        _ = args;
        const world_id = ctx.world_id orelse return;
        const claim = self.claims.get(world_id) orelse {
            try ctx.sendMessage("This planet is not claimed.");
            return;
        };

        const isAdmin = try utils.isAdmin(ctx);
        const uuid = ctx.player_uuid orelse return;
        const uuid_str = try uuid.toString(ctx.allocator);
        defer ctx.allocator.free(uuid_str);

        if (!isAdmin and !std.mem.eql(u8, claim.owner_uuid, uuid_str)) {
            try ctx.sendMessage("Only the owner can unclaim this planet.");
            return;
        }

        if (self.claims.getEntry(world_id)) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            _ = self.claims.swapRemove(world_id);
            ctx.allocator.free(key);
            ctx.allocator.free(value.world_id);
            ctx.allocator.free(value.owner_uuid);
            ctx.allocator.free(value.owner_name);
            for (value.members) |m| ctx.allocator.free(m);
            ctx.allocator.free(value.members);
            try self.save(ctx.allocator);
            try ctx.sendMessage("Planet unclaimed.");
        }
    }

    fn save(self: *ClaimPlugin, allocator: std.mem.Allocator) !void {
        const s = storage.Storage.init(allocator, "data");
        const ClaimData = struct { claims: []Claim };
        try s.saveJson("claims.json", ClaimData{ .claims = self.claims.values() });
    }
};
