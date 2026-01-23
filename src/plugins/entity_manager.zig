const std = @import("std");
const packet = @import("../protocol/packet.zig");
const proxy = @import("../proxy.zig");

pub const EntityType = enum {
    player,
    monster,
    npc,
    object,
    itemdrop,
    projectile,
    unknown,
};

pub const EntityInfo = struct {
    entity_id: u64,
    entity_type_name: []u8,
    entity_type: EntityType = .unknown,
    position: [2]f32 = .{ 0, 0 },
};

pub const EntityManagerPlugin = struct {
    pub fn activate(self: *EntityManagerPlugin, ctx: *proxy.ConnectionContext, config: std.json.Value) !void {
        _ = self;
        _ = ctx;
        _ = config;
    }

    pub fn onEntityCreate(self: *EntityManagerPlugin, ctx: *proxy.ConnectionContext, create: packet.EntityCreate) !bool {
        _ = self;
        const info = try ctx.allocator.create(EntityInfo);
        info.* = .{
            .entity_id = create.entity_id,
            .entity_type_name = try ctx.allocator.dupe(u8, create.entity_type),
            .entity_type = classifyEntity(create.entity_type),
        };
        try ctx.entities.put(create.entity_id, info);
        return true;
    }

    pub fn onStepUpdate(self: *EntityManagerPlugin, ctx: *proxy.ConnectionContext, payload: []const u8) !bool {
        _ = self;
        var fbs = std.io.fixedBufferStream(payload);
        const reader = fbs.reader();
        // StepUpdate payload: [remote_steps: Vlq][entity_updates: Vlq]
        _ = try packet.vlq.Vlq.decode(reader); // remote_steps
        const num_updates = try packet.vlq.Vlq.decode(reader);

        for (0..num_updates) |_| {
            const entity_id = try packet.vlq.Vlq.decode(reader);
            const update_len = try packet.vlq.Vlq.decode(reader);
            const update_data = try ctx.allocator.alloc(u8, update_len);
            defer ctx.allocator.free(update_data);
            var total: usize = 0;
            while (total < update_len) {
                const n = try reader.read(update_data[total..]);
                if (n == 0) break;
                total += n;
            }
            if (total < update_len) return error.EndOfStream;

            if (ctx.entities.get(entity_id)) |info| {
                if (update_data.len >= 8) {
                    // Movement updates often start with two f32s (8 bytes)
                    const x: f32 = @bitCast(std.mem.readInt(u32, update_data[0..4], .big));
                    const y: f32 = @bitCast(std.mem.readInt(u32, update_data[4..8], .big));

                    // Simple sanity check: positions in Starbound are rarely exactly 0.0 or massive
                    if (@abs(x) < 1000000 and @abs(y) < 1000000) {
                        info.position = .{ x, y };
                    }
                }
            }

            if (ctx.client_id) |cid| {
                if (entity_id == @as(u64, @intCast(cid))) {
                    if (update_data.len >= 8) {
                        const x: f32 = @bitCast(std.mem.readInt(u32, update_data[0..4], .big));
                        const y: f32 = @bitCast(std.mem.readInt(u32, update_data[4..8], .big));
                        if (@abs(x) < 1000000 and @abs(y) < 1000000) {
                            ctx.player_pos = .{ x, y };
                        }
                    }
                }
            }
        }
        return true;
    }

    pub fn onEntityDestroy(self: *EntityManagerPlugin, ctx: *proxy.ConnectionContext, destroy: packet.EntityDestroy) !bool {
        _ = self;
        if (ctx.entities.fetchRemove(destroy.entity_id)) |entry| {
            ctx.allocator.free(entry.value.entity_type_name);
            ctx.allocator.destroy(entry.value);
        }
        return true;
    }

    pub fn onPacket(self: *EntityManagerPlugin, ctx: *proxy.ConnectionContext, p: *packet.Packet) !bool {
        _ = self;
        if (p.header.packet_type == .world_stop) {
            var it = ctx.entities.iterator();
            while (it.next()) |entry| {
                ctx.allocator.free(entry.value_ptr.*.entity_type_name);
                ctx.allocator.destroy(entry.value_ptr.*);
            }
            ctx.entities.clearRetainingCapacity();
        }
        return true;
    }

    fn classifyEntity(name: []const u8) EntityType {
        if (std.mem.eql(u8, name, "player")) return .player;
        if (std.mem.eql(u8, name, "monster")) return .monster;
        if (std.mem.eql(u8, name, "npc")) return .npc;
        if (std.mem.eql(u8, name, "object")) return .object;
        if (std.mem.eql(u8, name, "itemdrop")) return .itemdrop;
        if (std.mem.eql(u8, name, "projectile")) return .projectile;
        return .unknown;
    }
};
