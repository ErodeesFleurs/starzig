const std = @import("std");
pub const net = std.net;
pub const packet = @import("protocol/packet.zig");
pub const compression = @import("protocol/compression.zig");
const plugins = @import("plugins/mod.zig");

pub const ConnectionState = enum {
    handshake,
    connected,
    disconnected,
};

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    listen_address: net.Address,
    target_address: net.Address,
    active_connections: std.ArrayListUnmanaged(*ConnectionContext) = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, listen_port: u16, target_host: []const u8, target_port: u16) !Proxy {
        const listen_addr = try net.Address.parseIp("0.0.0.0", listen_port);
        const target_addr = try net.Address.parseIp(target_host, target_port);
        return Proxy{
            .allocator = allocator,
            .listen_address = listen_addr,
            .target_address = target_addr,
        };
    }

    pub fn run(self: *Proxy, plugin_config: std.json.Value) !void {
        var server = try self.listen_address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        std.log.info("Proxy listening on {f}", .{self.listen_address});

        while (true) {
            const conn = try server.accept();
            std.log.info("New connection from {f}", .{conn.address});

            const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn, plugin_config });
            thread.detach();
        }
    }

    fn handleConnection(self: *Proxy, client_conn: net.Server.Connection, plugin_config: std.json.Value) void {
        defer client_conn.stream.close();

        const server_stream = net.tcpConnectToAddress(self.target_address) catch |err| {
            std.log.err("Failed to connect to target server: {any}", .{err});
            return;
        };
        defer server_stream.close();

        var context = ConnectionContext.init(self.allocator, client_conn.stream, server_stream) catch |err| {
            std.log.err("Failed to initialize connection context: {any}", .{err});
            return;
        };
        context.proxy = self;
        defer context.deinit();

        self.mutex.lock();
        self.active_connections.append(self.allocator, &context) catch |err| {
            std.log.err("Failed to track connection: {any}", .{err});
        };
        self.mutex.unlock();

        defer {
            self.mutex.lock();
            for (self.active_connections.items, 0..) |conn, i| {
                if (conn == &context) {
                    _ = self.active_connections.swapRemove(i);
                    break;
                }
            }
            self.mutex.unlock();
        }

        std.log.info("Handshake starting for {f}", .{client_conn.address});

        plugins.Registry.activateAll(&context, plugin_config) catch |err| {
            std.log.err("Failed to activate plugins: {any}", .{err});
        };
        defer plugins.Registry.deactivateAll(&context) catch |err| {
            std.log.err("Error during plugin deactivation: {any}", .{err});
        };

        // The bridge handles the two-way traffic
        context.bridge() catch |err| {
            std.log.err("Connection error: {any}", .{err});
        };

        std.log.info("Connection from {f} closed", .{client_conn.address});
    }
};

pub const ConnectionContext = struct {
    proxy: *Proxy,
    allocator: std.mem.Allocator,
    client: net.Stream,
    server: net.Stream,
    state: ConnectionState,
    compressed: bool,
    decompressor: compression.Decompressor,
    compressor: compression.Compressor,

    // Player info
    player_name: ?[]u8 = null,
    player_uuid: ?packet.types.UUID = null,
    client_id: ?i64 = null,
    world_id: ?[]u8 = null,
    player_pos: [2]f32 = .{ 0, 0 },
    pending_warp_pos: ?[2]f32 = null,
    last_msg_from: ?[]u8 = null,
    entities: std.AutoHashMap(u64, *plugins.entity_manager.EntityInfo),

    fn init(allocator: std.mem.Allocator, client: net.Stream, server: net.Stream) !ConnectionContext {
        return ConnectionContext{
            .proxy = undefined, // Set after creation
            .allocator = allocator,
            .client = client,
            .server = server,
            .state = .handshake,
            .compressed = false,
            .decompressor = try compression.Decompressor.init(),
            .compressor = try compression.Compressor.init(),
            .entities = std.AutoHashMap(u64, *plugins.entity_manager.EntityInfo).init(allocator),
        };
    }

    fn deinit(self: *ConnectionContext) void {
        self.decompressor.deinit();
        self.compressor.deinit();
        if (self.player_name) |name| self.allocator.free(name);
        if (self.world_id) |wid| self.allocator.free(wid);
        if (self.last_msg_from) |lmf| self.allocator.free(lmf);
        self.entities.deinit();
    }

    pub fn sendToClient(self: *ConnectionContext, p: *packet.Packet) !void {
        const writer = std.io.AnyWriter{
            .context = &self.client,
            .writeFn = struct {
                fn write(ptr: *const anyopaque, src: []const u8) anyerror!usize {
                    const s: *const net.Stream = @ptrCast(@alignCast(ptr));
                    return s.write(src);
                }
            }.write,
        };
        try p.header.encode(writer);
        try self.client.writeAll(p.payload);
    }

    pub fn sendToServer(self: *ConnectionContext, p: *packet.Packet) !void {
        const writer = std.io.AnyWriter{
            .context = &self.server,
            .writeFn = struct {
                fn write(ptr: *const anyopaque, src: []const u8) anyerror!usize {
                    const s: *const net.Stream = @ptrCast(@alignCast(ptr));
                    return s.write(src);
                }
            }.write,
        };
        try p.header.encode(writer);
        try self.server.writeAll(p.payload);
    }

    pub fn sendMessage(self: *ConnectionContext, message: []const u8) !void {
        try self.sendChatToClient("StarryPy", message);
    }

    pub fn sendChatToClient(self: *ConnectionContext, name: []const u8, message: []const u8) !void {
        var chat = packet.ChatReceived{
            .header = .{
                .mode = 2, // Broadcast/System
                .channel = try self.allocator.dupe(u8, ""),
                .client_id = 0,
            },
            .name = try self.allocator.dupe(u8, name),
            .junk = 0,
            .message = try self.allocator.dupe(u8, message),
        };
        defer chat.deinit(self.allocator);

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        try chat.encode(buf.writer(self.allocator));

        const header = packet.PacketHeader{
            .packet_type = .chat_received,
            .payload_size = @intCast(buf.items.len),
        };
        var p = packet.Packet{
            .header = header,
            .payload = buf.items,
        };
        try self.sendToClient(&p);
    }

    pub fn injectToClient(self: *ConnectionContext, p_type: packet.PacketType, payload: []const u8) !void {
        const header = packet.PacketHeader{
            .packet_type = p_type,
            .payload_size = @intCast(payload.len),
        };
        var p = packet.Packet{
            .header = header,
            .payload = @constCast(payload),
        };
        try self.sendToClient(&p);
    }

    pub fn injectToServer(self: *ConnectionContext, p_type: packet.PacketType, payload: []const u8) !void {
        const header = packet.PacketHeader{
            .packet_type = p_type,
            .payload_size = @intCast(payload.len),
        };
        var p = packet.Packet{
            .header = header,
            .payload = @constCast(payload),
        };
        try self.sendToServer(&p);
    }

    pub fn warpToPos(self: *ConnectionContext, pos: [2]f32) !void {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeByte(1); // WarpType.TO_WORLD
        try writer.writeByte(2); // WarpWorldType.PLAYER_WORLD
        var zero_uuid = [_]u8{0} ** 16;
        try writer.writeAll(&zero_uuid);
        try writer.writeByte(2); // flag 2
        try writer.writeInt(u32, @bitCast(pos[0]), .big);
        try writer.writeInt(u32, @bitCast(pos[1]), .big);
        try writer.writeByte(0); // trailing junk/zero

        try self.injectToClient(.player_warp, buf.items);
    }

    pub fn warpToWorld(self: *ConnectionContext, world_id: []const u8) !void {
        var warp = packet.PlayerWarp{
            .warp_type = .to_world,
            .world_id = try self.allocator.dupe(u8, world_id),
        };
        defer warp.deinit(self.allocator);

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        try warp.encode(buf.writer(self.allocator));

        try self.injectToClient(.player_warp, buf.items);
    }

    fn bridge(self: *ConnectionContext) !void {
        const C2S = struct {
            ctx: *ConnectionContext,
            fn run(ctx: *ConnectionContext) void {
                ctx.processStream(.client, .server) catch {};
            }
        };

        const c2s_thread = try std.Thread.spawn(.{}, C2S.run, .{self});
        try self.processStream(.server, .client);
        c2s_thread.join();
    }

    const Direction = enum { client, server };

    fn processStream(self: *ConnectionContext, from: Direction, to: Direction) !void {
        const from_stream = if (from == .client) self.client else self.server;
        const to_stream = if (to == .client) self.client else self.server;

        const reader = std.io.AnyReader{
            .context = &from_stream,
            .readFn = struct {
                fn read(ptr: *const anyopaque, dest: []u8) anyerror!usize {
                    const s: *const net.Stream = @ptrCast(@alignCast(ptr));
                    return s.read(dest);
                }
            }.read,
        };
        const writer = std.io.AnyWriter{
            .context = &to_stream,
            .writeFn = struct {
                fn write(ptr: *const anyopaque, src: []const u8) anyerror!usize {
                    const s: *const net.Stream = @ptrCast(@alignCast(ptr));
                    return s.write(src);
                }
            }.write,
        };

        while (true) {
            const header = packet.PacketHeader.decode(reader) catch break;
            std.log.info("packet_type: {s} packet_size: {d}", .{ @tagName(header.packet_type), header.payload_size });

            const is_compressed = header.payload_size < 0;
            const payload_len = if (is_compressed)
                @as(usize, @intCast(@abs(header.payload_size)))
            else
                @as(usize, @intCast(header.payload_size));

            const raw_payload = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(raw_payload);
            try reader.readNoEof(raw_payload);

            const payload = if (is_compressed)
                try self.decompressor.decompress(self.allocator, raw_payload)
            else
                try self.allocator.dupe(u8, raw_payload);

            var p = packet.Packet{
                .header = header,
                .payload = payload,
            };
            defer p.deinit(self.allocator);

            // Intercept handshake packets to track connection state
            if (p.header.packet_type == .client_connect) {
                var fbs = std.io.fixedBufferStream(p.payload);
                const connect = try packet.ClientConnect.decode(self.allocator, fbs.reader());
                defer connect.deinit(self.allocator);

                if (self.player_name) |old| self.allocator.free(old);
                self.player_name = try self.allocator.dupe(u8, connect.name);
                self.player_uuid = connect.uuid;
                std.log.info("Player connecting: {s} ({any})", .{ connect.name, connect.uuid });
            } else if (p.header.packet_type == .connect_success) {
                var fbs = std.io.fixedBufferStream(p.payload);
                const success = try packet.ConnectSuccess.decode(fbs.reader());
                self.client_id = success.client_id;
                self.state = .connected;
                std.log.info("Connection success: client_id={any}", .{success.client_id});
            } else if (p.header.packet_type == .world_start) {
                var fbs = std.io.fixedBufferStream(p.payload);
                const start = try packet.WorldStart.decode(self.allocator, fbs.reader());
                defer start.deinit(self.allocator);

                if (self.world_id) |old| self.allocator.free(old);
                self.world_id = try start.planet.toString(self.allocator);
                self.player_pos = start.player_start;
                std.log.info("World start: {s} at {any}", .{ self.world_id orelse "Unknown", self.player_pos });

                if (self.pending_warp_pos) |pos| {
                    try self.warpToPos(pos);
                    self.pending_warp_pos = null;
                }
            }

            // Run plugins
            const allowed = try plugins.Registry.callOnPacket(self, &p);

            if (allowed) {
                try p.header.encode(writer);
                try writer.writeAll(p.payload);
            }
        }
    }
};
