const std = @import("std");

pub const Storage = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) Storage {
        return Storage{
            .allocator = allocator,
            .base_path = base_path,
        };
    }

    pub fn saveJson(self: Storage, file_name: []const u8, data: anytype) !void {
        if (std.fs.cwd().access(self.base_path, .{})) |_| {} else |_| {
            try std.fs.cwd().makePath(self.base_path);
        }
        var dir = try std.fs.cwd().openDir(self.base_path, .{});
        defer dir.close();

        const file = try dir.createFile(file_name, .{});
        defer file.close();

        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();

        try std.json.Stringify.value(data, .{}, &out.writer);
        try file.writeAll(out.written());
    }

    pub fn loadJson(self: Storage, file_name: []const u8, T: type) !std.json.Parsed(T) {
        var dir = std.fs.cwd().openDir(self.base_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try std.fs.cwd().makePath(self.base_path);
                return error.FileNotFound;
            }
            return err;
        };
        defer dir.close();

        const file = try dir.openFile(file_name, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        return try std.json.parseFromSlice(T, self.allocator, content, .{ .ignore_unknown_fields = true });
    }
};
