const std = @import("std");
const net = std.net;
const Config = @import("config").Config;
const PacketHandler = @import("packets").PacketHandler;

pub const Proxy = struct {
    allocator: std.mem.Allocator,
    config: Config,
    server: net.Server,
    packet_handler: PacketHandler,
    clients: std.AutoHashMap(net.StreamServer.Connection, ClientContext),

    const ClientContext = struct {
        client_stream: net.Stream,
        server_stream: net.Stream,
        client_addr: net.Address,
        uuid: []const u8,
        connected_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Proxy {
        const address = try net.Address.parseIp("0.0.0.0", config.proxy_port);
        var server = net.StreamServer.init(.{
            .reuse_address = true,
        });

        try server.listen(address);

        return Proxy{
            .allocator = allocator,
            .config = config,
            .server = server,
            .packet_handler = try PacketHandler.init(allocator),
            .clients = std.AutoHashMap(net.StreamServer.Connection, ClientContext).init(allocator),
        };
    }

    pub fn deinit(self: *Proxy) void {
        self.server.deinit();
        self.packet_handler.deinit();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const ctx = entry.value_ptr;
            ctx.client_stream.close();
            ctx.server_stream.close();
            self.allocator.free(ctx.uuid);
        }
        self.clients.deinit();
    }

    pub fn run(self: *Proxy) !void {
        std.log.info("Proxy running on port {d}", .{self.config.proxy_port});

        while (true) {
            const connection = try self.server.accept();
            std.log.info("New connection from {s}", .{connection.address});

            // 为每个连接启动一个协程/线程
            var handle = try std.Thread.spawn(.{}, handleConnection, .{
                self.allocator, self.config, connection, &self.packet_handler,
            });
            handle.detach();
        }
    }

    fn handleConnection(
        allocator: std.mem.Allocator,
        config: Config,
        client_conn: net.StreamServer.Connection,
        packet_handler: *PacketHandler,
    ) !void {
        defer client_conn.stream.close();
        _ = allocator;
        // 连接到后端Starbound服务器
        const backend_addr = try net.Address.parseIp(config.backend_host, config.backend_port);
        var server_stream = try net.tcpConnectToAddress(backend_addr);
        defer server_stream.close();

        std.log.info("Connected to backend server", .{});

        // 创建双向转发
        var client_to_server = try std.Thread.spawn(.{}, forwardData, .{
            .source = client_conn.stream,
            .dest = server_stream,
            .direction = .client_to_server,
            .packet_handler = packet_handler,
        });

        var server_to_client = try std.Thread.spawn(.{}, forwardData, .{
            .source = server_stream,
            .dest = client_conn.stream,
            .direction = .server_to_client,
            .packet_handler = packet_handler,
        });

        client_to_server.join();
        server_to_client.join();
    }

    fn forwardData(args: struct {
        source: net.Stream,
        dest: net.Stream,
        direction: enum { client_to_server, server_to_client },
        packet_handler: *PacketHandler,
    }) !void {
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = try args.source.read(&buffer);
            if (bytes_read == 0) break;

            // 处理数据包（这里可以添加协议解析和修改）
            const processed_data = try args.packet_handler.process(
                buffer[0..bytes_read],
                args.direction,
            );

            // 转发处理后的数据
            try args.dest.writeAll(processed_data);
        }
    }
};
