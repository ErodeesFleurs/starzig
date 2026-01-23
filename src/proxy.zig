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
    decompressor: ?*compression.ZstdStreamDecompressor,
    compressor: ?*compression.ZstdStreamCompressor,
    server_decompressor: ?*compression.ZstdStreamDecompressor,
    server_compressor: ?*compression.ZstdStreamCompressor,

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
            .decompressor = null,
            .compressor = null,
            .server_decompressor = null,
            .server_compressor = null,
            .entities = std.AutoHashMap(u64, *plugins.entity_manager.EntityInfo).init(allocator),
        };
    }

    fn deinit(self: *ConnectionContext) void {
        if (self.decompressor) |d| d.deinit();
        if (self.compressor) |c| c.deinit();
        if (self.server_decompressor) |d| d.deinit();
        if (self.server_compressor) |c| c.deinit();
        if (self.player_name) |name| self.allocator.free(name);
        if (self.world_id) |wid| self.allocator.free(wid);
        if (self.last_msg_from) |lmf| self.allocator.free(lmf);
        self.entities.deinit();
    }

    pub fn sendToClient(self: *ConnectionContext, p: *packet.Packet) !void {
        var bw_buf: [4096]u8 = undefined;
        var bw = self.client.writer(&bw_buf);
        const current_writer = &bw.interface;
        try p.header.encode(current_writer);
        try current_writer.writeAll(p.payload);
    }

    pub fn sendToServer(self: *ConnectionContext, p: *packet.Packet) !void {
        var bw_buf: [4096]u8 = undefined;
        var bw = self.server.writer(&bw_buf);
        const current_writer = &bw.interface;
        try p.header.encode(current_writer);
        try current_writer.writeAll(p.payload);
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

        try writer.writeAll(&[_]u8{1}); // WarpType.TO_WORLD
        try writer.writeAll(&[_]u8{2}); // WarpWorldType.PLAYER_WORLD
        var zero_uuid = [_]u8{0} ** 16;
        try writer.writeAll(&zero_uuid);
        try writer.writeAll(&[_]u8{2}); // flag 2
        try writer.writeInt(u32, @bitCast(pos[0]), .big);
        try writer.writeInt(u32, @bitCast(pos[1]), .big);
        try writer.writeAll(&[_]u8{0}); // trailing junk/zero

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

        var br_buf: [4096]u8 = undefined;
        var bw_buf: [4096]u8 = undefined;
        var br = from_stream.reader(&br_buf);
        var bw = to_stream.writer(&bw_buf);
        var current_reader = &br.file_reader.interface;
        var current_writer = &bw.interface;

        while (true) {
            const header = packet.PacketHeader.decode(current_reader) catch break;
            std.log.info("packet_type: {s} packet_size: {d} direction: {any}", .{ @tagName(header.packet_type), header.payload_size, from });

            const is_compressed = header.payload_size < 0;
            const payload_len = if (is_compressed)
                @as(usize, @intCast(@abs(header.payload_size)))
            else
                @as(usize, @intCast(header.payload_size));

            const raw_payload = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(raw_payload);
            var fw = std.io.Writer.fixed(raw_payload);
            const amt_read = try current_reader.vtable.stream(current_reader, &fw, .limited(payload_len));
            if (amt_read < payload_len) return error.EndOfStream;

            const payload = if (is_compressed)
                try compression.decompressZlib(self.allocator, raw_payload)
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
                try p.header.encode(current_writer);
                try current_writer.writeAll(p.payload);
            }

            // Zstd stream transition
            if (p.header.packet_type == .protocol_response) {
                std.log.info("Protocol response received, starting Zstd stream", .{});
                if (from == .server) {
                    self.server_decompressor = try compression.ZstdStreamDecompressor.init(self.allocator);
                    const WrappedReader = struct {
                        inner: *std.io.Reader,
                        decompressor: *compression.ZstdStreamDecompressor,
                        interface: std.io.Reader = undefined,

                        fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) error{ EndOfStream, ReadFailed, WriteFailed }!usize {
                            const self_ptr: *@This() = @fieldParentPtr("interface", r);
                            var buf: [4096]u8 = undefined;
                            const to_read = limit.slice(&buf);
                            const n = self_ptr.decompressor.read(self_ptr.inner, to_read) catch return error.ReadFailed;
                            return w.write(to_read[0..n]) catch return error.WriteFailed;
                        }
                    };
                    const wr = try self.allocator.create(WrappedReader);
                    wr.* = .{
                        .inner = current_reader,
                        .decompressor = self.server_decompressor.?,
                        .interface = .{
                            .vtable = &.{ .stream = WrappedReader.stream },
                            .buffer = &[_]u8{},
                            .end = 0,
                            .seek = 0,
                        },
                    };
                    current_reader = &wr.interface;

                    self.compressor = try compression.ZstdStreamCompressor.init(self.allocator);
                    const WrappedWriter = struct {
                        inner: *std.io.Writer,
                        compressor: *compression.ZstdStreamCompressor,
                        interface: std.io.Writer = undefined,

                        fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
                            const self_ptr: *@This() = @fieldParentPtr("interface", w);
                            var total: usize = 0;
                            for (data) |slice| {
                                total += self_ptr.compressor.write(self_ptr.inner, slice) catch return error.WriteFailed;
                            }
                            if (splat > 0) {
                                const last = data[data.len - 1];
                                for (0..splat) |_| {
                                    _ = self_ptr.compressor.write(self_ptr.inner, last) catch return error.WriteFailed;
                                }
                            }
                            return total;
                        }
                    };
                    const ww = try self.allocator.create(WrappedWriter);
                    ww.* = .{
                        .inner = current_writer,
                        .compressor = self.compressor.?,
                        .interface = .{ .vtable = &.{ .drain = WrappedWriter.drain }, .buffer = &[_]u8{}, .end = 0 },
                    };
                    current_writer = &ww.interface;
                } else {
                    self.decompressor = try compression.ZstdStreamDecompressor.init(self.allocator);
                    const WrappedReader = struct {
                        inner: *std.io.Reader,
                        decompressor: *compression.ZstdStreamDecompressor,
                        interface: std.io.Reader = undefined,

                        fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) error{ EndOfStream, ReadFailed, WriteFailed }!usize {
                            const self_ptr: *@This() = @fieldParentPtr("interface", r);
                            var buf: [4096]u8 = undefined;
                            const to_read = limit.slice(&buf);
                            const n = self_ptr.decompressor.read(self_ptr.inner, to_read) catch return error.ReadFailed;
                            return w.write(to_read[0..n]) catch return error.WriteFailed;
                        }
                    };
                    const wr = try self.allocator.create(WrappedReader);
                    wr.* = .{
                        .inner = current_reader,
                        .decompressor = self.decompressor.?,
                        .interface = .{
                            .vtable = &.{ .stream = WrappedReader.stream },
                            .buffer = &[_]u8{},
                            .end = 0,
                            .seek = 0,
                        },
                    };
                    current_reader = &wr.interface;

                    self.server_compressor = try compression.ZstdStreamCompressor.init(self.allocator);
                    const WrappedWriter = struct {
                        inner: *std.io.Writer,
                        compressor: *compression.ZstdStreamCompressor,
                        interface: std.io.Writer = undefined,

                        fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
                            const self_ptr: *@This() = @fieldParentPtr("interface", w);
                            var total: usize = 0;
                            for (data) |slice| {
                                total += self_ptr.compressor.write(self_ptr.inner, slice) catch return error.WriteFailed;
                            }
                            if (splat > 0) {
                                const last = data[data.len - 1];
                                for (0..splat) |_| {
                                    _ = self_ptr.compressor.write(self_ptr.inner, last) catch return error.WriteFailed;
                                }
                            }
                            return total;
                        }
                    };
                    const ww = try self.allocator.create(WrappedWriter);
                    ww.* = .{
                        .inner = current_writer,
                        .compressor = self.server_compressor.?,
                        .interface = .{ .vtable = &.{ .drain = WrappedWriter.drain }, .buffer = &[_]u8{}, .end = 0 },
                    };
                    current_writer = &ww.interface;
                }
            }
        }
    }
};
