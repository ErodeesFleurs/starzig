const std = @import("std");
const packet = @import("../protocol/packet.zig");
const proxy = @import("../proxy.zig");

pub const chat = @import("chat.zig");
pub const logger = @import("logger.zig");
pub const entity_manager = @import("entity_manager.zig");
pub const protection = @import("protection.zig");
pub const motd = @import("motd.zig");
pub const world_announcer = @import("world_announcer.zig");
pub const warp = @import("warp.zig");
pub const player_manager = @import("player_manager.zig");
pub const tpa = @import("tpa.zig");
pub const mute = @import("mute.zig");
pub const claim = @import("claim.zig");

pub const ChatPlugin = chat.ChatPlugin;
pub const LoggerPlugin = logger.LoggerPlugin;
pub const EntityManagerPlugin = entity_manager.EntityManagerPlugin;
pub const ProtectionPlugin = protection.ProtectionPlugin;
pub const MotdPlugin = motd.MotdPlugin;
pub const WorldAnnouncerPlugin = world_announcer.WorldAnnouncerPlugin;
pub const WarpPlugin = warp.WarpPlugin;
pub const PlayerManagerPlugin = player_manager.PlayerManagerPlugin;
pub const TpaPlugin = tpa.TpaPlugin;
pub const MutePlugin = mute.MutePlugin;
pub const ClaimPlugin = claim.ClaimPlugin;

pub const PluginHook = enum {
    on_packet_received,
    on_packet_sent,
    on_client_connect,
    on_client_disconnect,
};

const PluginList = struct {
    entity_manager: EntityManagerPlugin,
    chat: ChatPlugin,
    logger: LoggerPlugin,
    protection: ProtectionPlugin,
    motd: MotdPlugin,
    world_announcer: WorldAnnouncerPlugin,
    warp: WarpPlugin,
    player_manager: PlayerManagerPlugin,
    tpa: TpaPlugin,
    mute: MutePlugin,
    claim: ClaimPlugin,
};

var active_plugins: PluginList = undefined;

pub const Registry = struct {
    pub fn initAll() !void {
        active_plugins = .{
            .entity_manager = .{},
            .chat = .{},
            .logger = .{},
            .protection = .{},
            .motd = .{},
            .world_announcer = .{},
            .warp = .{},
            .player_manager = .{},
            .tpa = .{},
            .mute = .{},
            .claim = .{},
        };
    }

    pub fn activateAll(ctx: *proxy.ConnectionContext, plugin_config: std.json.Value) !void {
        inline for (std.meta.fields(PluginList)) |field| {
            const plugin = &@field(active_plugins, field.name);
            const config = if (plugin_config == .object)
                plugin_config.object.get(field.name) orelse .null
            else
                .null;

            if (std.meta.hasFn(field.type, "activate")) {
                try plugin.activate(ctx, config);
            }
        }
    }

    pub fn deactivateAll(ctx: *proxy.ConnectionContext) !void {
        inline for (std.meta.fields(PluginList)) |field| {
            if (std.meta.hasFn(field.type, "deactivate")) {
                const plugin = &@field(active_plugins, field.name);
                try plugin.deactivate(ctx);
            }
        }
    }

    pub fn callOnPacket(ctx: *proxy.ConnectionContext, p: *packet.Packet) !bool {
        var allowed = true;

        // Generic Packet Hook
        inline for (std.meta.fields(PluginList)) |field| {
            const plugin = &@field(active_plugins, field.name);
            if (std.meta.hasFn(field.type, "onPacket")) {
                if (!try plugin.onPacket(ctx, p)) {
                    allowed = false;
                }
            }
        }

        // Specific Packet Hooks
        switch (p.header.packet_type) {
            .chat_sent => {
                inline for (std.meta.fields(PluginList)) |field| {
                    if (std.meta.hasFn(field.type, "onChatSent")) {
                        var fbs = std.io.fixedBufferStream(p.payload);
                        const chat_p = try packet.ChatSent.decode(ctx.allocator, fbs.reader());
                        defer chat_p.deinit(ctx.allocator);
                        if (!try @field(active_plugins, field.name).onChatSent(ctx, chat_p)) {
                            allowed = false;
                        }
                    }
                }
            },
            .entity_create => {
                inline for (std.meta.fields(PluginList)) |field| {
                    if (std.meta.hasFn(field.type, "onEntityCreate")) {
                        var fbs = std.io.fixedBufferStream(p.payload);
                        const entity_p = try packet.EntityCreate.decode(ctx.allocator, fbs.reader());
                        defer entity_p.deinit(ctx.allocator);
                        if (!try @field(active_plugins, field.name).onEntityCreate(ctx, entity_p)) {
                            allowed = false;
                        }
                    }
                }
            },
            .entity_destroy => {
                inline for (std.meta.fields(PluginList)) |field| {
                    if (std.meta.hasFn(field.type, "onEntityDestroy")) {
                        var fbs = std.io.fixedBufferStream(p.payload);
                        const destroy_p = try packet.EntityDestroy.decode(fbs.reader());
                        if (!try @field(active_plugins, field.name).onEntityDestroy(ctx, destroy_p)) {
                            allowed = false;
                        }
                    }
                }
            },
            .modify_tile_list => {
                inline for (std.meta.fields(PluginList)) |field| {
                    if (std.meta.hasFn(field.type, "onModifyTileList")) {
                        var fbs = std.io.fixedBufferStream(p.payload);
                        const tile_p = try packet.ModifyTileList.decode(ctx.allocator, fbs.reader());
                        defer tile_p.deinit(ctx.allocator);
                        if (!try @field(active_plugins, field.name).onModifyTileList(ctx, tile_p)) {
                            allowed = false;
                        }
                    }
                }
            },
            .entity_interact => {
                inline for (std.meta.fields(PluginList)) |field| {
                    if (std.meta.hasFn(field.type, "onEntityInteract")) {
                        var fbs = std.io.fixedBufferStream(p.payload);
                        const interact_p = try packet.EntityInteract.decode(fbs.reader());
                        if (!try @field(active_plugins, field.name).onEntityInteract(ctx, interact_p)) {
                            allowed = false;
                        }
                    }
                }
            },
            .step_update => {
                inline for (std.meta.fields(PluginList)) |field| {
                    if (std.meta.hasFn(field.type, "onStepUpdate")) {
                        if (!try @field(active_plugins, field.name).onStepUpdate(ctx, p.payload)) {
                            allowed = false;
                        }
                    }
                }
            },
            else => {},
        }

        return allowed;
    }

    pub fn getMutePlugin() *MutePlugin {
        return &active_plugins.mute;
    }

    pub fn getClaimPlugin() *ClaimPlugin {
        return &active_plugins.claim;
    }
};
