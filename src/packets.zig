const std = @import("std");

const Direction = enum {
    ClientToServer,
    ServerToClient,
};

pub const PackedHandler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PackedHandler {
        return PackedHandler{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PackedHandler) void {
        _ = self;
    }

    pub fn process(self: *PackedHandler, data: []const u8, direction: Direction) !void {
        _ = self;
        _ = direction;
        return data;
    }
};

pub const VarInt = struct {
    pub fn read(reader: anytype) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;

        while (true) {
            const byte = try reader.readByte();
            result |= @as(u64, byte & 0x7F) << shift;

            if (byte & 0x80 == 0) {
                return result;
            }

            shift += 7;
            if (shift >= 64) {
                return error.VarintTooLarge;
            }
        }
    }

    pub fn write(writer: anytype, value: u64) !void {
        var v = value;
        while (v > 0x7F) {
            try writer.writeByte(@as(u8, (v & 0x7F) | 0x80));
            v >>= 7;
        }
        try writer.writeByte(@as(u8, v));
    }
};

pub const PacketType = enum(u8) {
    ClientConnect = 0,
    ServerConnect = 1,
    ClientDisconnectRequest = 2,
    ChatSent = 3,
    _,
};

pub const PacketHeader = packed struct {
    length: u32,
    packet_type: u8,
};
