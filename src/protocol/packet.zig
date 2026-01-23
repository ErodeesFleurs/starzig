const std = @import("std");
pub const vlq = @import("vlq.zig");

pub const types = @import("types.zig");

fn readExactly(reader: anytype, writer: *std.io.Writer, length: usize) !usize {
    const ReaderType = @TypeOf(reader);
    const PtrInfo = @typeInfo(ReaderType);
    const T = if (PtrInfo == .pointer) PtrInfo.pointer.child else ReaderType;

    if (@hasDecl(T, "vtable")) {
        return reader.vtable.stream(@constCast(reader), writer, .limited(length));
    } else if (ReaderType == *std.io.Reader) {
        return reader.vtable.stream(reader, writer, .limited(length));
    } else if (@hasDecl(T, "read")) {
        // Generic fallback for any type that has .read()
        var buf: [1024]u8 = undefined;
        var total: usize = 0;
        while (total < length) {
            const to_read = @min(buf.len, length - total);
            const n = try reader.read(buf[0..to_read]);
            if (n == 0) break;
            try writer.writeAll(buf[0..n]);
            total += n;
        }
        return total;
    } else {
        @compileError("Unsupported reader type: " ++ @typeName(ReaderType));
    }
}

fn readNoEof(reader: anytype, buf: []u8) !void {
    var fw = std.io.Writer.fixed(buf);
    const n = try readExactly(reader, &fw, buf.len);
    if (n < buf.len) return error.EndOfStream;
}

pub const PacketType = enum(u8) {
    protocol_request = 0,
    protocol_response = 1,
    server_disconnect = 2,
    connect_success = 3,
    connect_failure = 4,
    handshake_challenge = 5,
    chat_received = 6,
    universe_time_update = 7,
    message_player_rule = 8,
    player_warp_result = 9,
    client_connect = 11,
    client_disconnect_request = 12,
    player_warp = 14,
    fly_ship = 15,
    chat_sent = 16,
    client_context_update = 18,
    world_start = 19,
    world_stop = 20,
    give_item = 29,
    entity_interact_result = 31,
    modify_tile_list = 35,
    spawn_entity = 39,
    entity_interact = 40,
    entity_create = 45,
    entity_message = 51,
    entity_message_response = 52,
    entity_destroy = 53,
    step_update = 54,
    _,
};

pub const ModifyTileList = struct {
    tiles: []Tile,

    pub const Tile = struct {
        x: i32,
        y: i32,
        layer: u8,
        action: u8,
        content: u32,
    };

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !ModifyTileList {
        const count = try vlq.Vlq.decode(reader);
        var tiles = try allocator.alloc(Tile, count);
        errdefer allocator.free(tiles);

        for (0..count) |i| {
            var b: [1]u8 = undefined;
            var fw = std.io.Writer.fixed(&b);
            _ = try readExactly(reader, &fw, 1);
            const layer = b[0];
            _ = try readExactly(reader, &fw, 1);
            const action = b[0];
            tiles[i] = Tile{
                .x = try reader.readInt(i32, .big),
                .y = try reader.readInt(i32, .big),
                .layer = layer,
                .action = action,
                .content = try reader.readInt(u32, .big),
            };
        }

        return ModifyTileList{ .tiles = tiles };
    }

    pub fn encode(self: ModifyTileList, writer: anytype) !void {
        try vlq.Vlq.encode(writer, self.tiles.len);
        for (self.tiles) |tile| {
            try writer.writeInt(i32, tile.x, .big);
            try writer.writeInt(i32, tile.y, .big);
            _ = try writer.write(&[_]u8{tile.layer});
            _ = try writer.write(&[_]u8{tile.action});
            try writer.writeInt(u32, tile.content, .big);
        }
    }

    pub fn deinit(self: ModifyTileList, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
    }
};

pub const WarpType = enum(u8) {
    to_world = 1,
    to_player = 2,
    to_alias = 3,
};

pub const PlayerWarp = struct {
    warp_type: WarpType,
    world_id: []u8,
    player_uuid: ?types.UUID = null,
    alias: ?[]u8 = null,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !PlayerWarp {
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const w_type = @as(WarpType, @enumFromInt(b[0]));
        var world_id: []u8 = undefined;
        var player_uuid: ?types.UUID = null;
        var alias: ?[]u8 = null;

        switch (w_type) {
            .to_world => {
                world_id = try types.StarString.decode(allocator, reader);
            },
            .to_player => {
                player_uuid = try types.UUID.decode(reader);
                world_id = try allocator.dupe(u8, "");
            },
            .to_alias => {
                alias = try types.StarString.decode(allocator, reader);
                world_id = try allocator.dupe(u8, "");
            },
        }

        return PlayerWarp{
            .warp_type = w_type,
            .world_id = world_id,
            .player_uuid = player_uuid,
            .alias = alias,
        };
    }

    pub fn encode(self: PlayerWarp, writer: anytype) !void {
        _ = try writer.write(&[_]u8{@intFromEnum(self.warp_type)});
        switch (self.warp_type) {
            .to_world => try types.StarString.encode(writer, self.world_id),
            .to_player => try self.player_uuid.?.encode(writer),
            .to_alias => try types.StarString.encode(writer, self.alias.?),
        }
    }

    pub fn deinit(self: PlayerWarp, allocator: std.mem.Allocator) void {
        allocator.free(self.world_id);
        if (self.alias) |a| allocator.free(a);
    }
};

pub const WorldStart = struct {
    planet: @import("variant.zig").Variant,
    sky_data: []u8,
    weather_data: []u8,
    player_start: [2]f32,
    world_properties: @import("variant.zig").Variant,
    client_id: u32,
    local_interpolation_mode: bool,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !WorldStart {
        const planet = try @import("variant.zig").Variant.decode(allocator, reader);
        errdefer planet.deinit(allocator);
        const sky_data = try types.StarByteArray.decode(allocator, reader);
        errdefer allocator.free(sky_data);
        const weather_data = try types.StarByteArray.decode(allocator, reader);
        errdefer allocator.free(weather_data);

        const player_start = [2]f32{
            @bitCast(try reader.readInt(u32, .big)),
            @bitCast(try reader.readInt(u32, .big)),
        };

        const world_properties = try @import("variant.zig").Variant.decode(allocator, reader);
        errdefer world_properties.deinit(allocator);

        const client_id = try reader.readInt(u32, .big);
        var b_mode: [1]u8 = undefined;
        var fw_mode = std.io.Writer.fixed(&b_mode);
        _ = try readExactly(reader, &fw_mode, 1);
        const local_interpolation_mode = b_mode[0] != 0;

        return WorldStart{
            .planet = planet,
            .sky_data = sky_data,
            .weather_data = weather_data,
            .player_start = player_start,
            .world_properties = world_properties,
            .client_id = client_id,
            .local_interpolation_mode = local_interpolation_mode,
        };
    }

    pub fn encode(self: WorldStart, writer: anytype) !void {
        try self.planet.encode(writer);
        try types.StarByteArray.encode(writer, self.sky_data);
        try types.StarByteArray.encode(writer, self.weather_data);
        try writer.writeInt(u32, @bitCast(self.player_start[0]), .big);
        try writer.writeInt(u32, @bitCast(self.player_start[1]), .big);
        try self.world_properties.encode(writer);
        try writer.writeInt(u32, self.client_id, .big);
        try writer.writeAll(&[_]u8{if (self.local_interpolation_mode) 1 else 0});
    }

    pub fn deinit(self: WorldStart, allocator: std.mem.Allocator) void {
        self.planet.deinit(allocator);
        allocator.free(self.sky_data);
        allocator.free(self.weather_data);
        self.world_properties.deinit(allocator);
    }
};

pub const GiveItem = struct {
    name: []u8,
    count: u32,
    variant: u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !GiveItem {
        const name = try types.StarString.decode(allocator, reader);
        const count = try reader.readInt(u32, .big);
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const variant = b[0];
        return GiveItem{
            .name = name,
            .count = count,
            .variant = variant,
        };
    }

    pub fn encode(self: GiveItem, writer: anytype) !void {
        try types.StarString.encode(writer, self.name);
        try writer.writeInt(u32, self.count, .big);
        try writer.writeAll(&[_]u8{self.variant});
    }

    pub fn deinit(self: GiveItem, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const EntityCreate = struct {
    entity_id: u64,
    entity_type: []u8,
    store_data: []u8,
    unique_id: ?[]u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !EntityCreate {
        const entity_id = try vlq.Vlq.decode(reader);
        const entity_type = try types.StarString.decode(allocator, reader);
        errdefer allocator.free(entity_type);
        const store_data = try types.StarByteArray.decode(allocator, reader);
        errdefer allocator.free(store_data);
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const has_unique_id = b[0] != 0;
        const unique_id = if (has_unique_id) try types.StarString.decode(allocator, reader) else null;

        return EntityCreate{
            .entity_id = entity_id,
            .entity_type = entity_type,
            .store_data = store_data,
            .unique_id = unique_id,
        };
    }

    pub fn encode(self: EntityCreate, writer: anytype) !void {
        try vlq.Vlq.encode(writer, self.entity_id);
        try types.StarString.encode(writer, self.entity_type);
        try types.StarByteArray.encode(writer, self.store_data);
        if (self.unique_id) |uid| {
            try writer.writeAll(&[_]u8{1});
            try types.StarString.encode(writer, uid);
        } else {
            try writer.writeAll(&[_]u8{0});
        }
    }

    pub fn deinit(self: EntityCreate, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_type);
        allocator.free(self.store_data);
        if (self.unique_id) |uid| allocator.free(uid);
    }
};

pub const SpawnEntity = struct {
    entity_type: []u8,
    position: [2]f32,
    variant: @import("variant.zig").Variant,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !SpawnEntity {
        const entity_type = try types.StarString.decode(allocator, reader);
        errdefer allocator.free(entity_type);
        const position = [2]f32{
            @bitCast(try reader.readInt(u32, .big)),
            @bitCast(try reader.readInt(u32, .big)),
        };
        const variant = try @import("variant.zig").Variant.decode(allocator, reader);

        return SpawnEntity{
            .entity_type = entity_type,
            .position = position,
            .variant = variant,
        };
    }

    pub fn encode(self: SpawnEntity, writer: anytype) !void {
        try types.StarString.encode(writer, self.entity_type);
        try writer.writeInt(u32, @bitCast(self.position[0]), .big);
        try writer.writeInt(u32, @bitCast(self.position[1]), .big);
        try self.variant.encode(writer);
    }

    pub fn deinit(self: SpawnEntity, allocator: std.mem.Allocator) void {
        allocator.free(self.entity_type);
        self.variant.deinit(allocator);
    }
};

pub const EntityInteract = struct {
    source_entity_id: u64,
    target_entity_id: u64,

    pub fn decode(reader: anytype) !EntityInteract {
        const source = try vlq.Vlq.decode(reader);
        const target = try vlq.Vlq.decode(reader);
        return EntityInteract{
            .source_entity_id = source,
            .target_entity_id = target,
        };
    }

    pub fn encode(self: EntityInteract, writer: anytype) !void {
        try vlq.Vlq.encode(writer, self.source_entity_id);
        try vlq.Vlq.encode(writer, self.target_entity_id);
    }
};

pub const EntityDestroy = struct {
    entity_id: u64,
    death: bool,

    pub fn decode(reader: anytype) !EntityDestroy {
        const entity_id = try vlq.Vlq.decode(reader);
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const death = b[0] != 0;
        return EntityDestroy{
            .entity_id = entity_id,
            .death = death,
        };
    }

    pub fn encode(self: EntityDestroy, writer: anytype) !void {
        try vlq.Vlq.encode(writer, self.entity_id);
        try writer.writeAll(&[_]u8{if (self.death) 1 else 0});
    }
};

pub const PacketHeader = struct {
    packet_type: PacketType,
    payload_size: i64,

    pub fn decode(reader: anytype) !PacketHeader {
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        const amt = try readExactly(reader, &fw, 1);
        if (amt == 0) return error.EndOfStream;
        const p_type = @as(PacketType, @enumFromInt(b[0]));
        const size = try vlq.SignedVlq.decode(reader);

        return PacketHeader{
            .packet_type = p_type,
            .payload_size = size,
        };
    }

    pub fn encode(self: PacketHeader, writer: anytype) !void {
        try writer.writeAll(&[_]u8{@intFromEnum(self.packet_type)});
        try vlq.SignedVlq.encode(writer, self.payload_size);
    }
};

pub const Packet = struct {
    header: PacketHeader,
    payload: []u8,

    pub fn deinit(self: Packet, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub const ChatHeader = struct {
    mode: u8,
    channel: []u8,
    client_id: u16,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !ChatHeader {
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const mode = b[0];
        var channel: []u8 = undefined;
        var client_id: u16 = 0;

        if (mode == 0 or mode == 1) {
            channel = try types.StarString.decode(allocator, reader);
            client_id = try reader.readInt(u16, .big);
        } else {
            channel = try allocator.dupe(u8, "");
            _ = try readExactly(reader, &fw, 1); // junk
            client_id = try reader.readInt(u16, .big);
        }

        return ChatHeader{
            .mode = mode,
            .channel = channel,
            .client_id = client_id,
        };
    }

    pub fn encode(self: ChatHeader, writer: anytype) !void {
        try writer.writeAll(&[_]u8{self.mode});
        if (self.mode == 0 or self.mode == 1) {
            try types.StarString.encode(writer, self.channel);
            try writer.writeInt(u16, self.client_id, .big);
        } else {
            try writer.writeAll(&[_]u8{0});
            try writer.writeInt(u16, self.client_id, .big);
        }
    }

    pub fn deinit(self: ChatHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
    }
};

pub const ChatReceived = struct {
    header: ChatHeader,
    name: []u8,
    junk: u8,
    message: []u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !ChatReceived {
        const header = try ChatHeader.decode(allocator, reader);
        errdefer header.deinit(allocator);
        const name = try types.StarString.decode(allocator, reader);
        errdefer allocator.free(name);
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const junk = b[0];
        const message = try types.StarString.decode(allocator, reader);

        return ChatReceived{
            .header = header,
            .name = name,
            .junk = junk,
            .message = message,
        };
    }

    pub fn encode(self: ChatReceived, writer: anytype) !void {
        try self.header.encode(writer);
        try types.StarString.encode(writer, self.name);
        try writer.writeAll(&[_]u8{self.junk});
        try types.StarString.encode(writer, self.message);
    }

    pub fn deinit(self: ChatReceived, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        allocator.free(self.name);
        allocator.free(self.message);
    }
};

pub const ChatSent = struct {
    message: []u8,
    send_mode: u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !ChatSent {
        const message = try types.StarString.decode(allocator, reader);
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const mode = b[0];
        return ChatSent{ .message = message, .send_mode = mode };
    }

    pub fn encode(self: ChatSent, writer: anytype) !void {
        try types.StarString.encode(writer, self.message);
        try writer.writeAll(&[_]u8{self.send_mode});
    }

    pub fn deinit(self: ChatSent, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub const WorldChunks = struct {
    length: u64,
    // We store the raw data for now as WorldChunks is complex and vary in size
    data: []u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !WorldChunks {
        const len = try vlq.Vlq.decode(reader);
        var list = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
        errdefer list.deinit(allocator);

        for (0..len) |_| {
            const v1 = try vlq.Vlq.decode(reader);
            const c1 = try allocator.alloc(u8, v1);
            defer allocator.free(c1);
            try readNoEof(reader, c1);

            var b: [1]u8 = undefined;
            var fw = std.io.Writer.fixed(&b);
            _ = try readExactly(reader, &fw, 1);
            const sep = b[0];

            const v2 = try vlq.Vlq.decode(reader);
            const c2 = try allocator.alloc(u8, v2);
            defer allocator.free(c2);
            try readNoEof(reader, c2);

            try vlq.Vlq.encode(list.writer(allocator), v1);
            try list.appendSlice(allocator, c1);
            try list.append(allocator, sep);
            try vlq.Vlq.encode(list.writer(allocator), v2);
            try list.appendSlice(allocator, c2);
        }

        return WorldChunks{
            .length = len,
            .data = try list.toOwnedSlice(allocator),
        };
    }

    pub fn encode(self: WorldChunks, writer: anytype) !void {
        try vlq.Vlq.encode(writer, self.length);
        try writer.writeAll(self.data);
    }

    pub fn deinit(self: WorldChunks, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const ClientConnect = struct {
    asset_digest: []u8,
    allow_mismatch: bool,
    uuid: types.UUID,
    name: []u8,
    species: []u8,
    shipdata: WorldChunks,
    ship_level: u32,
    max_fuel: u32,
    crew_size: u32,
    fuel_efficiency: f32,
    ship_speed: f32,
    ship_capabilities: [][]u8,
    intro_complete: bool,
    account: []u8,

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !ClientConnect {
        const asset_digest = try types.StarByteArray.decode(allocator, reader);
        errdefer allocator.free(asset_digest);
        var b: [1]u8 = undefined;
        var fw = std.io.Writer.fixed(&b);
        _ = try readExactly(reader, &fw, 1);
        const allow_mismatch = b[0] != 0;
        const uuid = try types.UUID.decode(reader);
        const name = try types.StarString.decode(allocator, reader);
        errdefer allocator.free(name);
        const species = try types.StarString.decode(allocator, reader);
        errdefer allocator.free(species);
        const shipdata = try WorldChunks.decode(allocator, reader);
        errdefer shipdata.deinit(allocator);

        const ship_level = try reader.readInt(u32, .big);
        const max_fuel = try reader.readInt(u32, .big);
        const crew_size = try reader.readInt(u32, .big);
        const fuel_efficiency: f32 = @bitCast(try reader.readInt(u32, .big));
        const ship_speed: f32 = @bitCast(try reader.readInt(u32, .big));

        const cap_len = try vlq.Vlq.decode(reader);
        var ship_capabilities = try allocator.alloc([]u8, cap_len);
        errdefer {
            for (ship_capabilities) |cap| allocator.free(cap);
            allocator.free(ship_capabilities);
        }
        for (0..cap_len) |i| {
            ship_capabilities[i] = try types.StarString.decode(allocator, reader);
        }

        var b_intro: [1]u8 = undefined;
        var fw_intro = std.io.Writer.fixed(&b_intro);
        _ = try readExactly(reader, &fw_intro, 1);
        const intro_complete = b_intro[0] != 0;
        const account = try types.StarString.decode(allocator, reader);

        return ClientConnect{
            .asset_digest = asset_digest,
            .allow_mismatch = allow_mismatch,
            .uuid = uuid,
            .name = name,
            .species = species,
            .shipdata = shipdata,
            .ship_level = ship_level,
            .max_fuel = max_fuel,
            .crew_size = crew_size,
            .fuel_efficiency = fuel_efficiency,
            .ship_speed = ship_speed,
            .ship_capabilities = ship_capabilities,
            .intro_complete = intro_complete,
            .account = account,
        };
    }

    pub fn encode(self: ClientConnect, writer: anytype) !void {
        try types.StarByteArray.encode(writer, self.asset_digest);
        try writer.writeAll(&[_]u8{if (self.allow_mismatch) 1 else 0});
        try self.uuid.encode(writer);
        try types.StarString.encode(writer, self.name);
        try types.StarString.encode(writer, self.species);
        try self.shipdata.encode(writer);
        try writer.writeInt(u32, self.ship_level, .big);
        try writer.writeInt(u32, self.max_fuel, .big);
        try writer.writeInt(u32, self.crew_size, .big);
        try writer.writeInt(u32, @bitCast(self.fuel_efficiency), .big);
        try writer.writeInt(u32, @bitCast(self.ship_speed), .big);

        try vlq.Vlq.encode(writer, self.ship_capabilities.len);
        for (self.ship_capabilities) |cap| {
            try types.StarString.encode(writer, cap);
        }

        try writer.writeAll(&[_]u8{if (self.intro_complete) 1 else 0});
        try types.StarString.encode(writer, self.account);
    }

    pub fn deinit(self: ClientConnect, allocator: std.mem.Allocator) void {
        allocator.free(self.asset_digest);
        allocator.free(self.name);
        allocator.free(self.species);
        self.shipdata.deinit(allocator);
        for (self.ship_capabilities) |cap| allocator.free(cap);
        allocator.free(self.ship_capabilities);
        allocator.free(self.account);
    }
};

pub const ProtocolRequest = struct {
    client_build: u32,

    pub fn decode(reader: anytype) !ProtocolRequest {
        return ProtocolRequest{
            .client_build = try reader.readInt(u32, .big),
        };
    }

    pub fn encode(self: ProtocolRequest, writer: anytype) !void {
        try writer.writeInt(u32, self.client_build, .big);
    }
};

pub const ConnectSuccess = struct {
    client_id: i64,
    server_uuid: types.UUID,
    planet_orbital_levels: i32,
    satellite_orbital_levels: i32,
    chunk_size: i32,
    xy_min: i32,
    xy_max: i32,
    z_min: i32,
    z_max: i32,

    pub fn decode(reader: anytype) !ConnectSuccess {
        return ConnectSuccess{
            .client_id = @intCast(try vlq.Vlq.decode(reader)),
            .server_uuid = try types.UUID.decode(reader),
            .planet_orbital_levels = try reader.readInt(i32, .big),
            .satellite_orbital_levels = try reader.readInt(i32, .big),
            .chunk_size = try reader.readInt(i32, .big),
            .xy_min = try reader.readInt(i32, .big),
            .xy_max = try reader.readInt(i32, .big),
            .z_min = try reader.readInt(i32, .big),
            .z_max = try reader.readInt(i32, .big),
        };
    }

    pub fn encode(self: ConnectSuccess, writer: anytype) !void {
        try vlq.Vlq.encode(writer, self.client_id);
        try self.server_uuid.encode(writer);
        try writer.writeInt(i32, self.planet_orbital_levels, .big);
        try writer.writeInt(i32, self.satellite_orbital_levels, .big);
        try writer.writeInt(i32, self.chunk_size, .big);
        try writer.writeInt(i32, self.xy_min, .big);
        try writer.writeInt(i32, self.xy_max, .big);
        try writer.writeInt(i32, self.z_min, .big);
        try writer.writeInt(i32, self.z_max, .big);
    }
};
