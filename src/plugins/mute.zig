const std = @import("std");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");
const utils = @import("utils.zig");

pub const MutePlugin = struct {
    mutes: std.StringArrayHashMapUnmanaged(void) = .{},

    pub fn activate(self: *MutePlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = config;
        const s = storage.Storage.init(ctx.allocator, "data");
        const MuteList = struct { mutes: [][]const u8 };

        var list = s.loadJson("mutes.json", MuteList) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer list.deinit();

        for (list.value.mutes) |uuid| {
            try self.mutes.put(ctx.allocator, try ctx.allocator.dupe(u8, uuid), {});
        }
    }

    pub fn deactivate(self: *MutePlugin, ctx: *proxy.ConnectionContext) !void {
        var it = self.mutes.iterator();
        while (it.next()) |entry| {
            ctx.allocator.free(entry.key_ptr.*);
        }
        self.mutes.deinit(ctx.allocator);
    }

    pub fn onChatSent(self: *MutePlugin, ctx: *proxy.ConnectionContext, chat: @import("../protocol/packet.zig").ChatSent) !bool {
        _ = chat;
        if (ctx.player_uuid) |uuid| {
            const uuid_str = try uuid.toString(ctx.allocator);
            defer ctx.allocator.free(uuid_str);
            if (self.mutes.contains(uuid_str)) {
                try ctx.sendMessage("^red;You are muted.");
                return false;
            }
        }
        return true;
    }

    pub fn mute(self: *MutePlugin, ctx: *proxy.ConnectionContext, target_uuid_str: []const u8) !void {
        if (!self.mutes.contains(target_uuid_str)) {
            try self.mutes.put(ctx.allocator, try ctx.allocator.dupe(u8, target_uuid_str), {});
            try self.save(ctx.allocator);
        }
    }

    pub fn unmute(self: *MutePlugin, ctx: *proxy.ConnectionContext, target_uuid_str: []const u8) !void {
        if (self.mutes.getEntry(target_uuid_str)) |entry| {
            const key = entry.key_ptr.*;
            _ = self.mutes.swapRemove(target_uuid_str);
            ctx.allocator.free(key);
            try self.save(ctx.allocator);
        }
    }

    fn save(self: *MutePlugin, allocator: std.mem.Allocator) !void {
        const s = storage.Storage.init(allocator, "data");
        var list = std.ArrayListUnmanaged([]const u8){};
        defer list.deinit(allocator);

        var it = self.mutes.iterator();
        while (it.next()) |entry| {
            try list.append(allocator, entry.key_ptr.*);
        }

        const MuteList = struct { mutes: [][]const u8 };
        try s.saveJson("mutes.json", MuteList{ .mutes = list.items });
    }
};
