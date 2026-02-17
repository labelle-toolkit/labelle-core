const std = @import("std");
const ecs_mod = @import("ecs.zig");
const component_mod = @import("component.zig");

/// Comptime plugin context — validates that the provided ECS type satisfies the
/// core trait interface and bundles convenience type aliases.
pub fn PluginContext(comptime cfg: struct { EcsType: type }) type {
    comptime {
        if (!@hasDecl(cfg.EcsType, "Entity"))
            @compileError(
                "PluginContext: EcsType must expose Entity type (got " ++ @typeName(cfg.EcsType) ++ ")",
            );

        const required_fns = .{ "createEntity", "destroyEntity", "entityExists", "add", "get", "has", "remove" };
        for (required_fns) |name| {
            if (!@hasDecl(cfg.EcsType, name))
                @compileError(
                    "PluginContext: EcsType must implement '" ++ name ++ "' (got " ++ @typeName(cfg.EcsType) ++ ")",
                );
        }
    }

    return struct {
        pub const Entity = cfg.EcsType.Entity;
        pub const EcsType = cfg.EcsType;
        pub const Payload = component_mod.ComponentPayload(cfg.EcsType.Entity);
    };
}

/// Test context — wraps MockEcsBackend with convenience init/deinit.
pub fn TestContext(comptime Entity: type) type {
    const Backend = ecs_mod.MockEcsBackend(Entity);

    return struct {
        pub const EcsType = ecs_mod.Ecs(Backend);
        pub const Payload = component_mod.ComponentPayload(Entity);

        backend: Backend,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .backend = Backend.init(allocator) };
        }

        pub fn ecs(self: *Self) EcsType {
            return .{ .backend = &self.backend };
        }

        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }
    };
}

/// Recording hooks — records dispatched event tags for test assertions.
pub fn RecordingHooks(comptime PayloadUnion: type) type {
    const Tag = std.meta.Tag(PayloadUnion);

    return struct {
        tags: std.ArrayListUnmanaged(Tag) = .{},
        allocator: std.mem.Allocator,
        cursor: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.tags.deinit(self.allocator);
        }

        pub fn emit(self: *Self, payload: PayloadUnion) void {
            switch (payload) {
                inline else => |_, tag| {
                    self.tags.append(self.allocator, tag) catch @panic("OOM in RecordingHooks");
                },
            }
        }

        pub fn expectNext(self: *Self, expected: Tag) !void {
            try std.testing.expect(self.cursor < self.tags.items.len);
            try std.testing.expectEqual(expected, self.tags.items[self.cursor]);
            self.cursor += 1;
        }

        pub fn expectEmpty(self: Self) !void {
            try std.testing.expectEqual(self.tags.items.len, self.cursor);
        }

        pub fn count(self: Self, tag: Tag) usize {
            var n: usize = 0;
            for (self.tags.items) |t| {
                if (t == tag) n += 1;
            }
            return n;
        }

        pub fn len(self: Self) usize {
            return self.tags.items.len;
        }

        pub fn reset(self: *Self) void {
            self.tags.clearRetainingCapacity();
            self.cursor = 0;
        }
    };
}
