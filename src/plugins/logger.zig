const std = @import("std");
const packet = @import("../protocol/packet.zig");
const proxy = @import("../proxy.zig");
const storage = @import("../storage.zig");

pub const LoggerPlugin = struct {
    enabled: bool = true,

    pub fn activate(self: *LoggerPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = ctx;
        if (config == .object) {
            if (config.object.get("enabled")) |e| {
                self.enabled = e.bool;
            }
        }
    }

    pub fn onPacket(self: *LoggerPlugin, ctx: *proxy.ConnectionContext, p: *packet.Packet) !bool {
        if (!self.enabled) return true;

        // Filter out very common packets from console log to avoid spam
        if (p.header.packet_type != .step_update and p.header.packet_type != .universe_time_update) {
            std.log.info("[{s}] Packet: type={s}, size={}", .{ ctx.player_name orelse "Unknown", @tagName(p.header.packet_type), p.header.payload_size });
        }

        const log_entry = struct {
            timestamp: i64,
            type: []const u8,
            size: i64,
            player: []const u8,
        }{
            .timestamp = std.time.timestamp(),
            .type = @tagName(p.header.packet_type),
            .size = p.header.payload_size,
            .player = ctx.player_name orelse "Unknown",
        };

        const s = storage.Storage.init(ctx.allocator, "data");
        self.appendLog(s, "packets.log", log_entry) catch |err| {
            std.log.err("Failed to log packet: {any}", .{err});
        };

        return true;
    }

    fn appendLog(self: *LoggerPlugin, s: storage.Storage, file_name: []const u8, data: anytype) !void {
        _ = self;
        std.fs.cwd().makePath(s.base_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        var dir = try std.fs.cwd().openDir(s.base_path, .{});
        defer dir.close();

        const file = dir.openFile(file_name, .{ .mode = .read_write }) catch |err| blk: {
            if (err == error.FileNotFound) {
                const f = try dir.createFile(file_name, .{});
                f.close();
                break :blk try dir.openFile(file_name, .{ .mode = .read_write });
            }
            return err;
        };
        defer file.close();

        try file.seekFromEnd(0);

        var out = std.io.Writer.Allocating.init(s.allocator);
        defer out.deinit();
        try std.json.Stringify.value(data, .{}, &out.writer);
        try file.writeAll(out.written());
        try file.writeAll("\n");
    }
};
