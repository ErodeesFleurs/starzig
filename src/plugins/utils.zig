const std = @import("std");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");

pub fn isAdmin(ctx: *proxy.ConnectionContext) !bool {
    if (ctx.player_uuid == null) return false;
    const uuid_str = try ctx.player_uuid.?.toString(ctx.allocator);
    defer ctx.allocator.free(uuid_str);

    const s = storage.Storage.init(ctx.allocator, "data");
    const AdminList = struct { admins: [][]const u8 };
    const parsed = s.loadJson("admins.json", AdminList) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer parsed.deinit();

    for (parsed.value.admins) |admin| {
        if (std.mem.eql(u8, uuid_str, admin)) return true;
    }
    return false;
}

pub fn findConnectionByName(proxy_ptr: *proxy.Proxy, name: []const u8) ?*proxy.ConnectionContext {
    proxy_ptr.mutex.lock();
    defer proxy_ptr.mutex.unlock();

    for (proxy_ptr.active_connections.items) |ctx| {
        if (ctx.player_name) |pname| {
            if (std.mem.eql(u8, pname, name)) return ctx;
        }
    }
    return null;
}
