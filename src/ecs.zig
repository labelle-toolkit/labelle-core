const std = @import("std");
const zig_ecs = @import("zig_ecs");

// ============================================================
// ECS Trait — comptime interface for pluggable backends
// ============================================================

/// Comptime ECS trait — defines the operations any ECS backend must support.
/// Plugins parameterize on this; the game provides the concrete type.
/// Everything resolves at comptime, zero runtime overhead.
pub fn Ecs(comptime Backend: type) type {
    comptime {
        if (!@hasDecl(Backend, "Entity"))
            @compileError("ECS backend must define Entity type, found: " ++ @typeName(Backend));
        const required = .{ "createEntity", "destroyEntity", "entityExists" };
        for (required) |name| {
            if (!@hasDecl(Backend, name))
                @compileError("ECS backend must implement " ++ name);
        }
    }

    return struct {
        pub const Entity = Backend.Entity;
        backend: *Backend,

        const Self = @This();

        pub fn createEntity(self: Self) Entity {
            return self.backend.createEntity();
        }

        pub fn destroyEntity(self: Self, entity: Entity) void {
            self.backend.destroyEntity(entity);
        }

        pub fn entityExists(self: Self, entity: Entity) bool {
            return self.backend.entityExists(entity);
        }

        pub fn add(self: Self, entity: Entity, component: anytype) void {
            self.backend.addComponent(entity, component);
        }

        pub fn get(self: Self, entity: Entity, comptime T: type) ?*T {
            return self.backend.getComponent(entity, T);
        }

        pub fn has(self: Self, entity: Entity, comptime T: type) bool {
            return self.backend.hasComponent(entity, T);
        }

        pub fn remove(self: Self, entity: Entity, comptime T: type) void {
            self.backend.removeComponent(entity, T);
        }
    };
}

// ============================================================
// Default Backend — zig-ecs adapter
// ============================================================

/// zig-ecs wrapped to satisfy the Ecs(Backend) trait.
/// This is core's default backend — plugins get it out of the box.
pub const ZigEcsBackend = struct {
    pub const Entity = zig_ecs.Entity;

    inner: zig_ecs.Registry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ZigEcsBackend {
        return .{
            .inner = zig_ecs.Registry.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZigEcsBackend) void {
        self.inner.deinit();
    }

    pub fn createEntity(self: *ZigEcsBackend) Entity {
        return self.inner.create();
    }

    pub fn destroyEntity(self: *ZigEcsBackend, entity: Entity) void {
        self.inner.destroy(entity);
    }

    pub fn entityExists(self: *ZigEcsBackend, entity: Entity) bool {
        return self.inner.valid(entity);
    }

    pub fn addComponent(self: *ZigEcsBackend, entity: Entity, component: anytype) void {
        self.inner.add(entity, component);
    }

    pub fn getComponent(self: *ZigEcsBackend, entity: Entity, comptime T: type) ?*T {
        return self.inner.tryGet(T, entity);
    }

    pub fn hasComponent(self: *ZigEcsBackend, entity: Entity, comptime T: type) bool {
        return self.inner.tryGet(T, entity) != null;
    }

    pub fn removeComponent(self: *ZigEcsBackend, entity: Entity, comptime T: type) void {
        self.inner.remove(T, entity);
    }
};

/// Convenience alias — the default ECS type for most users.
pub const DefaultEcs = Ecs(ZigEcsBackend);

// ============================================================
// Mock Backend — for testing without zig-ecs
// ============================================================

/// Mock ECS backend for testing — satisfies the Ecs trait with in-memory storage.
pub fn MockEcsBackend(comptime EntityType: type) type {
    return struct {
        pub const Entity = EntityType;

        const CleanupFn = *const fn (*Self) void;

        next_id: EntityType = 1,
        alive: std.AutoHashMap(EntityType, void),
        storages: std.AutoHashMap(usize, *anyopaque),
        cleanups: std.ArrayListUnmanaged(CleanupFn) = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .alive = std.AutoHashMap(EntityType, void).init(allocator),
                .storages = std.AutoHashMap(usize, *anyopaque).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.cleanups.items) |cleanup| {
                cleanup(self);
            }
            self.cleanups.deinit(self.allocator);
            self.storages.deinit();
            self.alive.deinit();
        }

        pub fn createEntity(self: *Self) EntityType {
            const id = self.next_id;
            self.next_id += 1;
            self.alive.put(id, {}) catch @panic("OOM");
            return id;
        }

        pub fn destroyEntity(self: *Self, entity: EntityType) void {
            _ = self.alive.remove(entity);
        }

        pub fn entityExists(self: *Self, entity: EntityType) bool {
            return self.alive.contains(entity);
        }

        pub fn addComponent(self: *Self, entity: EntityType, component: anytype) void {
            const T = @TypeOf(component);
            const storage = self.getOrCreateStorage(T);
            storage.put(entity, component) catch @panic("OOM");
        }

        pub fn getComponent(self: *Self, entity: EntityType, comptime T: type) ?*T {
            const storage = self.getStorage(T) orelse return null;
            return storage.getPtr(entity);
        }

        pub fn hasComponent(self: *Self, entity: EntityType, comptime T: type) bool {
            const storage = self.getStorage(T) orelse return false;
            return storage.contains(entity);
        }

        pub fn removeComponent(self: *Self, entity: EntityType, comptime T: type) void {
            const storage = self.getStorage(T) orelse return;
            _ = storage.remove(entity);
        }

        fn getOrCreateStorage(self: *Self, comptime T: type) *std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            if (self.storages.get(tid)) |raw| {
                return @ptrCast(@alignCast(raw));
            }
            const storage = self.allocator.create(std.AutoHashMap(EntityType, T)) catch @panic("OOM");
            storage.* = std.AutoHashMap(EntityType, T).init(self.allocator);
            self.storages.put(tid, @ptrCast(storage)) catch @panic("OOM");

            self.cleanups.append(self.allocator, &struct {
                fn cleanup(s: *Self) void {
                    const id = typeId(T);
                    if (s.storages.get(id)) |raw| {
                        const typed: *std.AutoHashMap(EntityType, T) = @ptrCast(@alignCast(raw));
                        typed.deinit();
                        s.allocator.destroy(typed);
                    }
                }
            }.cleanup) catch @panic("OOM");

            return storage;
        }

        fn getStorage(self: *Self, comptime T: type) ?*std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            const raw = self.storages.get(tid) orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        fn typeId(comptime T: type) usize {
            return @intFromPtr(&struct {
                comptime {
                    _ = T;
                }
                var x: u8 = 0;
            }.x);
        }
    };
}
