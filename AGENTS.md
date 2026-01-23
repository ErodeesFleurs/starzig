# Agent Guidelines: starzig

This repository is a Zig refactoring of [StarryPy3k](https://github.com/StarryPy/StarryPy3k), a Starbound proxy. It handles packet interception, modification, and plugin-based command processing.

## 🛠 Build, Lint, and Test Commands

- **Build Project:** `zig build`
- **Run Application:** `zig build run`
- **Run All Tests:** `zig build test`
- **Run Single File Tests:** `zig test src/path/to/file.zig`
- **Run Filtered Tests:** `zig build test -- --filter "test_name"`
- **Format Code:** `zig fmt .`
- **Check Compilation (Fast):** `zig build --summary none`

## 🎨 Code Style & Conventions

### 1. Naming Conventions
- **Types (Structs, Enums, Unions):** `PascalCase` (e.g., `PacketHeader`, `ConnectionContext`).
- **Functions:** `snake_case` (e.g., `decode`, `send_message`).
- **Variables / Fields:** `snake_case` (e.g., `payload_size`, `allocator`).
- **Constants:** `snake_case` or `PascalCase` depending on scope.

### 2. Imports
- Use `const std = @import("std");` at the top of every file.
- Prefer relative imports for local files: `const packet = @import("../protocol/packet.zig");`.
- Common protocol types are often re-exported in `src/main.zig`.

### 3. Memory Management
- **Explicit Allocators:** Almost all functions requiring allocation must take a `std.mem.Allocator`.
- **Ownership:** The caller usually owns the memory returned by `decode` or `init` functions.
- **Cleanup:** Always use `defer allocator.free(slice)` or `defer object.deinit(allocator)` immediately after successful allocation.
- **Error Safety:** Use `errdefer` to clean up partial allocations when a multi-step operation fails.

### 4. Error Handling
- Use `!T` for return types that can fail.
- Use `try` for propagating errors.
- Catch specific errors only when necessary: `loadJson(...) catch |err| { ... }`.
- Avoid `catch unreachable` unless it is mathematically proven to be safe.

### 5. Types & Formatting
- **Indentation:** 4 spaces (standard `zig fmt`).
- **Strings:** Use `[]u8` or `[]const u8`. For protocol strings, use `types.StarString`.
- **Integers:** Starbound uses Big-endian for network transmission. Use `std.mem.readInt` or `writer.writeInt` with `.big`.
- **Enums:** Explicitly tag enums for protocol mapping: `pub const PacketType = enum(u8) { ... };`.

## 🏗 Architecture & Core Components

### Protocol Layer (`src/protocol/`)
- **VLQ:** Variable Length Quantities used for sizes and IDs.
- **Variant:** A complex Starbound type for nested data structures (JSON-like).
- **Packet:** Every packet has a `PacketHeader` (Type + Signed VLQ Size).

### Proxy & Connection (`src/proxy.zig`)
- **Proxy:** Orchestrates the listener and manages `active_connections`.
- **ConnectionContext:** The most important struct for plugins. It holds:
    - `client_conn` / `server_conn`
    - `player_name`, `player_uuid`, `world_id`
    - `allocator`
    - Helper methods: `sendMessage`, `warpToWorld`, `injectToClient`.

### Plugin System (`src/plugins/`)
- Plugins implement an interface (see `ChatPlugin` in `chat.zig`).
- Hooks include `activate`, `onPacket`, and event handlers like `onChatSent`.
- **Commands:** Chat commands are registered in `chat.zig` and handled via `Command` structs.

## 💾 Data & Storage
- Use `src/storage.zig` for persisting JSON data in the `data/` directory.
- Always check for `error.FileNotFound` when loading data for the first time.

## ⚠️ Security & Safety
- **Secrets:** Never commit `config/config.json` with real credentials.
- **Concurrency:** The `Proxy` uses a `mutex` for the `active_connections` list. Always lock before iterating or modifying the list.
- **Validation:** Always validate packet sizes and VLQ values to prevent memory exhaustion or overflows.
