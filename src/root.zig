const std = @import("std");

pub const dispatcher = @import("dispatcher.zig");
pub const ecs = @import("ecs.zig");
pub const component = @import("component.zig");
pub const context = @import("context.zig");

// Re-exports — public API
pub const HookDispatcher = dispatcher.HookDispatcher;
pub const MergeHooks = dispatcher.MergeHooks;
pub const UnwrapReceiver = dispatcher.UnwrapReceiver;

pub const Ecs = ecs.Ecs;
pub const ZigEcsBackend = ecs.ZigEcsBackend;
pub const DefaultEcs = ecs.DefaultEcs;
pub const MockEcsBackend = ecs.MockEcsBackend;

pub const ComponentPayload = component.ComponentPayload;

pub const PluginContext = context.PluginContext;
pub const TestContext = context.TestContext;
pub const RecordingHooks = context.RecordingHooks;

/// Standard engine lifecycle events — parameterized by Entity type.
pub fn EngineHookPayload(comptime Entity: type) type {
    return union(enum) {
        game_init: GameInitInfo,
        game_deinit: void,
        frame_start: FrameInfo,
        frame_end: FrameInfo,
        scene_load: SceneInfo,
        scene_unload: SceneInfo,
        entity_created: EntityInfo(Entity),
        entity_destroyed: EntityInfo(Entity),
    };
}

pub const GameInitInfo = struct {
    allocator: std.mem.Allocator,
};

pub const FrameInfo = struct {
    frame_number: u64,
    dt: f32,
};

pub const SceneInfo = struct {
    name: []const u8,
};

pub fn EntityInfo(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
        prefab_name: ?[]const u8 = null,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

// -- Dispatcher tests --

const SimplePayload = union(enum) {
    ping: u32,
    pong: []const u8,
};

test "dispatcher: basic emit calls receiver method" {
    const Receiver = struct {
        ping_value: u32 = 0,

        pub fn ping(self: *@This(), value: u32) void {
            self.ping_value = value;
        }
    };

    var recv = Receiver{};
    const D = HookDispatcher(SimplePayload, *Receiver, .{});
    const d = D{ .receiver = &recv };

    d.emit(.{ .ping = 42 });
    try testing.expectEqual(42, recv.ping_value);

    d.emit(.{ .pong = "hello" });
    try testing.expectEqual(42, recv.ping_value);
}

test "dispatcher: partial handling compiles" {
    const Receiver = struct {
        pub fn ping(_: @This(), _: u32) void {}
    };

    const D = HookDispatcher(SimplePayload, Receiver, .{});
    const d = D{ .receiver = .{} };
    d.emit(.{ .ping = 1 });
    d.emit(.{ .pong = "test" });
}

test "MergeHooks: calls receivers in tuple order" {
    var order: [3]u8 = .{ 0, 0, 0 };
    var idx: u8 = 0;
    const idx_ptr = &idx;
    const order_ptr = &order;

    const ReceiverA = struct {
        order: *[3]u8,
        idx: *u8,

        pub fn ping(self: @This(), _: u32) void {
            self.order[self.idx.*] = 'A';
            self.idx.* += 1;
        }
    };

    const ReceiverB = struct {
        order: *[3]u8,
        idx: *u8,

        pub fn ping(self: @This(), _: u32) void {
            self.order[self.idx.*] = 'B';
            self.idx.* += 1;
        }

        pub fn pong(self: @This(), _: []const u8) void {
            self.order[self.idx.*] = 'b';
            self.idx.* += 1;
        }
    };

    const Merged = MergeHooks(SimplePayload, .{ ReceiverA, ReceiverB });
    const merged = Merged{ .receivers = .{
        ReceiverA{ .order = order_ptr, .idx = idx_ptr },
        ReceiverB{ .order = order_ptr, .idx = idx_ptr },
    } };

    merged.emit(.{ .ping = 1 });
    try testing.expectEqual('A', order[0]);
    try testing.expectEqual('B', order[1]);

    merged.emit(.{ .pong = "x" });
    try testing.expectEqual('b', order[2]);
}

// -- ECS tests (zig-ecs backend) --

test "DefaultEcs: create entity, add/get/has/remove component" {
    var backend = ZigEcsBackend.init(testing.allocator);
    defer backend.deinit();

    const e = DefaultEcs{ .backend = &backend };

    const entity = e.createEntity();
    try testing.expect(e.entityExists(entity));

    const Position = struct { x: f32, y: f32 };

    e.add(entity, Position{ .x = 10, .y = 20 });
    try testing.expect(e.has(entity, Position));

    const pos = e.get(entity, Position).?;
    try testing.expectEqual(10.0, pos.x);
    try testing.expectEqual(20.0, pos.y);

    pos.x = 99;
    try testing.expectEqual(99.0, e.get(entity, Position).?.x);

    e.remove(entity, Position);
    try testing.expect(!e.has(entity, Position));

    e.destroyEntity(entity);
    try testing.expect(!e.entityExists(entity));
}

test "DefaultEcs: multiple component types on same entity" {
    var backend = ZigEcsBackend.init(testing.allocator);
    defer backend.deinit();

    const e = DefaultEcs{ .backend = &backend };

    const Position = struct { x: f32, y: f32 };
    const Health = struct { current: u32, max: u32 };

    const entity = e.createEntity();
    e.add(entity, Position{ .x = 1, .y = 2 });
    e.add(entity, Health{ .current = 100, .max = 100 });

    try testing.expect(e.has(entity, Position));
    try testing.expect(e.has(entity, Health));
    try testing.expectEqual(100, e.get(entity, Health).?.current);

    e.remove(entity, Position);
    try testing.expect(!e.has(entity, Position));
    try testing.expect(e.has(entity, Health));
}

// -- MockEcsBackend tests --

test "MockEcsBackend: works through trait" {
    var ctx = TestContext(u32).init(testing.allocator);
    defer ctx.deinit();

    const e = ctx.ecs();
    const entity = e.createEntity();

    const Position = struct { x: f32, y: f32 };
    e.add(entity, Position{ .x = 5, .y = 10 });

    try testing.expect(e.has(entity, Position));
    try testing.expectEqual(5.0, e.get(entity, Position).?.x);
}

// -- PluginContext tests --

test "PluginContext: validates and exposes correct types" {
    const Ctx = PluginContext(.{ .EcsType = DefaultEcs });

    var backend = ZigEcsBackend.init(testing.allocator);
    defer backend.deinit();
    const e: Ctx.EcsType = .{ .backend = &backend };

    const entity: Ctx.Entity = e.createEntity();
    try testing.expect(e.entityExists(entity));
}

// -- RecordingHooks tests --

test "RecordingHooks: records and asserts event sequence" {
    var recorder = RecordingHooks(SimplePayload).init(testing.allocator);
    defer recorder.deinit();

    recorder.emit(.{ .ping = 42 });
    recorder.emit(.{ .pong = "hello" });
    recorder.emit(.{ .ping = 99 });

    try testing.expectEqual(3, recorder.len());
    try testing.expectEqual(2, recorder.count(.ping));
    try testing.expectEqual(1, recorder.count(.pong));

    try recorder.expectNext(.ping);
    try recorder.expectNext(.pong);
    try recorder.expectNext(.ping);
    try recorder.expectEmpty();
}

// -- Integration: zig-ecs + hooks --

test "integration: plugin pattern with DefaultEcs and hooks" {
    // Simulate a plugin that uses core's DefaultEcs and hooks
    const InPayload = union(enum) {
        add_item: struct { entity_id: ecs.ZigEcsBackend.Entity, name: []const u8 },
    };

    const OutPayload = union(enum) {
        item_added: struct { entity_id: ecs.ZigEcsBackend.Entity, name: []const u8 },
    };

    var backend = ZigEcsBackend.init(testing.allocator);
    defer backend.deinit();

    const e = DefaultEcs{ .backend = &backend };
    const entity = e.createEntity();

    // Game receiver
    const GameRecv = struct {
        last_name: ?[]const u8 = null,

        pub fn item_added(self: *@This(), p: anytype) void {
            self.last_name = p.name;
        }
    };

    var game_recv = GameRecv{};

    const OutDispatcher = HookDispatcher(OutPayload, *GameRecv, .{});

    // Bound receiver
    const BoundRecv = struct {
        out: OutDispatcher,

        pub fn add_item(self: @This(), p: anytype) void {
            self.out.emit(.{ .item_added = .{
                .entity_id = p.entity_id,
                .name = p.name,
            } });
        }
    };

    const InDispatcher = HookDispatcher(InPayload, BoundRecv, .{});
    const in_hooks = InDispatcher{
        .receiver = .{
            .out = .{ .receiver = &game_recv },
        },
    };

    in_hooks.emit(.{ .add_item = .{ .entity_id = entity, .name = "sword" } });
    try testing.expectEqualStrings("sword", game_recv.last_name.?);
}
