const std = @import("std");
const testing = std.testing;
const root = @import("labelle-core");

const backend_contract = root.backend_contract;
const HookDispatcher = root.HookDispatcher;
const MergeHooks = root.MergeHooks;
const Ecs = root.Ecs;
const MockEcsBackend = root.MockEcsBackend;
const Position = root.Position;
const AudioInterface = root.AudioInterface;
const StubAudio = root.StubAudio;
const InputInterface = root.InputInterface;
const StubInput = root.StubInput;
const GuiInterface = root.GuiInterface;
const StubGui = root.StubGui;
const LogSinkInterface = root.LogSinkInterface;
const StubLogSink = root.StubLogSink;
const StderrLogSink = root.StderrLogSink;
const GizmoInterface = root.GizmoInterface;
const StubGizmos = root.StubGizmos;
const RenderInterface = root.RenderInterface;
const StubRender = root.StubRender;
const ParentComponent = root.ParentComponent;
const ChildrenComponent = root.ChildrenComponent;
const PrefabInstance = root.PrefabInstance;
const PrefabChild = root.PrefabChild;
const CoordinateSystem = root.CoordinateSystem;
const GamePosition = root.GamePosition;
const ScreenPosition = root.ScreenPosition;
const gameToScreen = root.gameToScreen;
const screenToGame = root.screenToGame;
const YAxis = root.YAxis;
const toScreenY = root.toScreenY;
const screenToLogicalY = root.screenToLogicalY;

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

// RFC-PLUGIN-EVENTS O4, phase 7 — consumable event flavor.
//
// A consumable event's payload struct declares `pub const consumable = true;`
// and its handlers return `bool`. `MergeHooks.emit` switches to the
// return-aware path at comptime for variants whose payload is marked
// consumable, and breaks out of the receiver loop the moment a handler
// returns `true`. Notification events (no marker / `false` marker) keep the
// pre-RFC fan-out semantics — every receiver runs regardless of return
// value the handler may incidentally hand back.

const ConsumablePayload = union(enum) {
    /// Marked consumable: handlers return `bool`, dispatch breaks on `true`.
    click: ClickEvent,
    /// Plain notification — no marker, every listener runs unconditionally.
    moved: MovedEvent,
};

const ClickEvent = struct {
    x: f32,
    y: f32,
    pub const consumable = true;
};

const MovedEvent = struct {
    dx: f32,
    dy: f32,
};

test "MergeHooks: consumable event stops on first handler that returns true" {
    var call_log: [4]u8 = .{ 0, 0, 0, 0 };
    var idx: u8 = 0;
    const idx_ptr = &idx;
    const log_ptr = &call_log;

    // The high-priority handler consumes the click. The assembler emits
    // it ahead of the low-priority one (RFC O3 / phase 7 — priority-desc
    // sort confined to consumable events); the test mimics that order
    // explicitly so the dispatcher contract is what's under test.
    const HighPriority = struct {
        log: *[4]u8,
        idx: *u8,
        pub fn click(self: @This(), _: ClickEvent) bool {
            self.log[self.idx.*] = 'H';
            self.idx.* += 1;
            return true; // consume — stops propagation
        }
    };

    const LowPriority = struct {
        log: *[4]u8,
        idx: *u8,
        pub fn click(self: @This(), _: ClickEvent) bool {
            self.log[self.idx.*] = 'L';
            self.idx.* += 1;
            return false;
        }
    };

    const Merged = MergeHooks(ConsumablePayload, .{ HighPriority, LowPriority });
    const merged = Merged{ .receivers = .{
        HighPriority{ .log = log_ptr, .idx = idx_ptr },
        LowPriority{ .log = log_ptr, .idx = idx_ptr },
    } };

    merged.emit(.{ .click = .{ .x = 10, .y = 20 } });

    // High-priority ran and consumed. Low-priority MUST NOT have been
    // called — that's the consumable contract.
    try testing.expectEqual(@as(u8, 1), idx);
    try testing.expectEqual(@as(u8, 'H'), call_log[0]);
    try testing.expectEqual(@as(u8, 0), call_log[1]);
}

test "MergeHooks: consumable event falls through when the first handler returns false" {
    var call_log: [4]u8 = .{ 0, 0, 0, 0 };
    var idx: u8 = 0;
    const idx_ptr = &idx;
    const log_ptr = &call_log;

    const FirstDecliner = struct {
        log: *[4]u8,
        idx: *u8,
        pub fn click(self: @This(), _: ClickEvent) bool {
            self.log[self.idx.*] = 'F';
            self.idx.* += 1;
            return false; // not handled — propagate
        }
    };

    const SecondConsumer = struct {
        log: *[4]u8,
        idx: *u8,
        pub fn click(self: @This(), _: ClickEvent) bool {
            self.log[self.idx.*] = 'S';
            self.idx.* += 1;
            return true; // consume here
        }
    };

    const ThirdSkipped = struct {
        log: *[4]u8,
        idx: *u8,
        pub fn click(self: @This(), _: ClickEvent) bool {
            self.log[self.idx.*] = 'T';
            self.idx.* += 1;
            return false;
        }
    };

    const Merged = MergeHooks(ConsumablePayload, .{ FirstDecliner, SecondConsumer, ThirdSkipped });
    const merged = Merged{ .receivers = .{
        FirstDecliner{ .log = log_ptr, .idx = idx_ptr },
        SecondConsumer{ .log = log_ptr, .idx = idx_ptr },
        ThirdSkipped{ .log = log_ptr, .idx = idx_ptr },
    } };

    merged.emit(.{ .click = .{ .x = 0, .y = 0 } });

    // First and second ran; third was skipped because second consumed.
    try testing.expectEqual(@as(u8, 2), idx);
    try testing.expectEqual(@as(u8, 'F'), call_log[0]);
    try testing.expectEqual(@as(u8, 'S'), call_log[1]);
    try testing.expectEqual(@as(u8, 0), call_log[2]);
}

test "MergeHooks: notification event fans out to every listener regardless of returns" {
    var call_count: u8 = 0;
    const ptr = &call_count;

    // Handlers that return `bool` for a NOTIFICATION event — the
    // dispatcher must NOT honor `true` as "consumed" here. The break is
    // gated on the variant's payload struct declaring `consumable`;
    // `MovedEvent` does not, so all receivers run.
    const ReceiverA = struct {
        counter: *u8,
        pub fn moved(self: @This(), _: MovedEvent) bool {
            self.counter.* += 1;
            return true; // intentional: must NOT short-circuit a notification.
        }
    };

    const ReceiverB = struct {
        counter: *u8,
        pub fn moved(self: @This(), _: MovedEvent) void {
            self.counter.* += 10;
        }
    };

    const ReceiverC = struct {
        counter: *u8,
        pub fn moved(self: @This(), _: MovedEvent) bool {
            self.counter.* += 100;
            return false;
        }
    };

    const Merged = MergeHooks(ConsumablePayload, .{ ReceiverA, ReceiverB, ReceiverC });
    const merged = Merged{ .receivers = .{
        ReceiverA{ .counter = ptr },
        ReceiverB{ .counter = ptr },
        ReceiverC{ .counter = ptr },
    } };

    merged.emit(.{ .moved = .{ .dx = 1, .dy = 2 } });

    // All three ran: 1 + 10 + 100. The `true` return from A did NOT stop
    // the loop because `MovedEvent` is not marked consumable.
    try testing.expectEqual(@as(u8, 111), call_count);
}

const MergeHookPayloads = root.MergeHookPayloads;

test "MergeHookPayloads: merges two unions into one" {
    const EnginePayload = union(enum) {
        frame_start: u32,
        entity_created: u64,
    };
    const PluginPayload = union(enum) {
        collision_begin: struct { a: u32, b: u32 },
        collision_end: struct { a: u32, b: u32 },
    };

    const Merged = MergeHookPayloads(.{ EnginePayload, PluginPayload });

    // Should have all 4 fields
    const fields = @typeInfo(Merged).@"union".fields;
    try testing.expectEqual(4, fields.len);

    // Can construct and switch on merged values
    const v1: Merged = .{ .frame_start = 42 };
    const v2: Merged = .{ .collision_begin = .{ .a = 1, .b = 2 } };

    switch (v1) {
        .frame_start => |val| try testing.expectEqual(42, val),
        else => unreachable,
    }
    switch (v2) {
        .collision_begin => |val| {
            try testing.expectEqual(1, val.a);
            try testing.expectEqual(2, val.b);
        },
        else => unreachable,
    }
}

test "MergeHookPayloads: works with HookDispatcher" {
    const PayloadA = union(enum) { ping: u32 };
    const PayloadB = union(enum) { pong: []const u8 };
    const Merged = MergeHookPayloads(.{ PayloadA, PayloadB });

    const Receiver = struct {
        ping_val: u32 = 0,
        pub fn ping(self: *@This(), val: u32) void {
            self.ping_val = val;
        }
    };

    var recv = Receiver{};
    const D = HookDispatcher(Merged, *Receiver, .{});
    const d = D{ .receiver = &recv };

    d.emit(.{ .ping = 99 });
    try testing.expectEqual(99, recv.ping_val);

    // pong has no handler — should be a no-op
    d.emit(.{ .pong = "hello" });
    try testing.expectEqual(99, recv.ping_val);
}

test "MockEcsBackend: create entity, add/get/has/remove component" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const entity = e.createEntity();
    try testing.expect(e.entityExists(entity));
    try testing.expectEqual(1, e.entityCount());

    const Pos = struct { x: f32, y: f32 };

    e.add(entity, Pos{ .x = 10, .y = 20 });
    try testing.expect(e.has(entity, Pos));

    const pos = e.get(entity, Pos).?;
    try testing.expectEqual(10.0, pos.x);
    try testing.expectEqual(20.0, pos.y);

    pos.x = 99;
    try testing.expectEqual(99.0, e.get(entity, Pos).?.x);

    e.remove(entity, Pos);
    try testing.expect(!e.has(entity, Pos));

    e.destroyEntity(entity);
    try testing.expect(!e.entityExists(entity));
    try testing.expectEqual(0, e.entityCount());
}

test "MockEcsBackend: multiple component types on same entity" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Health = struct { current: u32, max: u32 };

    const entity = e.createEntity();
    e.add(entity, Pos{ .x = 1, .y = 2 });
    e.add(entity, Health{ .current = 100, .max = 100 });

    try testing.expect(e.has(entity, Pos));
    try testing.expect(e.has(entity, Health));
    try testing.expectEqual(100, e.get(entity, Health).?.current);

    e.remove(entity, Pos);
    try testing.expect(!e.has(entity, Pos));
    try testing.expect(e.has(entity, Health));
}

test "MockEcsBackend: entityCount tracks alive entities" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    try testing.expectEqual(0, e.entityCount());

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    _ = e.createEntity();
    try testing.expectEqual(3, e.entityCount());

    e.destroyEntity(e1);
    try testing.expectEqual(2, e.entityCount());

    e.destroyEntity(e2);
    try testing.expectEqual(1, e.entityCount());
}

/// Regression backend for labelle-core#59.
///
/// Models a "real" ECS backend (e.g. the zig_ecs wrapper) whose `getComponent`
/// does an UNCHECKED lookup: on a dead / recycled / never-valid entity id it
/// reads a stale sparse-set slot and hands back a use-after-free pointer — the
/// segfault the issue reports when a flows `entity_created` tick handler calls
/// `getComponent(payload.entity, C)` after the entity was destroyed.
///
/// Unlike `MockEcsBackend` — whose `AutoHashMap`-backed `alive.contains` is safe
/// for ANY key and so already returns null — here `entityExists` is the ONLY
/// safe validity probe and reaching `getComponent`/`hasComponent` with a dead id
/// IS the bug. So the test process survives even when the guard is ABSENT (a
/// clean assertion failure, not a crashed runner), the "unsafe" branch does not
/// literally deref freed memory: it bumps `dead_lookups` and returns the stale
/// (non-null) pointer that lingers in `storage`. The regression test then proves
/// the core-side guard in `Ecs.get()`/`Ecs.has()` routed AROUND that branch
/// (`dead_lookups == 0`, null/false returned). Without the guard, `get()` falls
/// straight through and returns the stale pointer — the exact use-after-free.
fn Issue59SpyBackend(comptime Comp: type) type {
    return struct {
        pub const Entity = u32;

        next_id: Entity = 1,
        alive: std.AutoHashMap(Entity, void),
        // Deliberately NOT cleared on destroy: models a sparse-set slot that
        // lingers after the entity dies, so an unchecked read returns a stale
        // (use-after-free) pointer rather than a clean null.
        storage: std.AutoHashMap(Entity, Comp),
        dead_lookups: usize = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .alive = std.AutoHashMap(Entity, void).init(allocator),
                .storage = std.AutoHashMap(Entity, Comp).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.alive.deinit();
            self.storage.deinit();
        }

        pub fn createEntity(self: *Self) Entity {
            const id = self.next_id;
            self.next_id += 1;
            self.alive.put(id, {}) catch @panic("OOM");
            return id;
        }

        pub fn destroyEntity(self: *Self, entity: Entity) void {
            _ = self.alive.remove(entity); // storage slot intentionally lingers
        }

        pub fn entityExists(self: *Self, entity: Entity) bool {
            return self.alive.contains(entity); // the SAFE validity probe
        }

        pub fn entityCount(self: *Self) usize {
            return self.alive.count();
        }

        pub fn addComponent(self: *Self, entity: Entity, component: Comp) void {
            self.storage.put(entity, component) catch @panic("OOM");
        }

        /// UNCHECKED read — the crash surface. A conformant caller must have
        /// validated `entity` first (which the fixed `Ecs.get()` now does).
        pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
            comptime std.debug.assert(T == Comp);
            if (!self.alive.contains(entity)) {
                // In a real backend this branch derefs freed memory / an
                // out-of-range slot and segfaults. Record it instead so the
                // guard's effect is observable without crashing the runner.
                self.dead_lookups += 1;
            }
            return self.storage.getPtr(entity);
        }

        pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
            comptime std.debug.assert(T == Comp);
            if (!self.alive.contains(entity)) self.dead_lookups += 1;
            return self.storage.contains(entity);
        }

        pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
            comptime std.debug.assert(T == Comp);
            _ = self.storage.remove(entity);
        }

        // ── Trait decls required by Ecs() but not exercised by this test ──
        // (present so `Ecs(Issue59SpyBackend(..))` satisfies the comptime
        // contract; never called, so the bodies are intentionally trivial).
        pub fn View(comptime includes: anytype, comptime excludes: anytype) type {
            _ = includes;
            _ = excludes;
            return struct {
                pub fn next(_: *@This()) ?Entity {
                    return null;
                }
                pub fn deinit(_: *@This()) void {}
            };
        }

        pub fn view(self: *Self, comptime includes: anytype, comptime excludes: anytype) View(includes, excludes) {
            _ = self;
            return .{};
        }

        pub fn QueryIterator(comptime components: anytype) type {
            _ = components;
            return struct {
                pub fn next(_: *@This()) ?Entity {
                    return null;
                }
                pub fn deinit(_: *@This()) void {}
            };
        }

        pub fn query(self: *Self, comptime components: anytype) QueryIterator(components) {
            _ = self;
            return .{};
        }
    };
}

test "Ecs.get/has on a destroyed or never-valid entity id returns null without an unsafe backend lookup (labelle-core#59)" {
    const Marker = struct { tag: u32 };
    var backend = Issue59SpyBackend(Marker).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(Issue59SpyBackend(Marker)){ .backend = &backend };

    const entity = e.createEntity();
    e.add(entity, Marker{ .tag = 7 });

    // Live entity: the normal read path still works (and takes no dead lookup).
    try testing.expectEqual(@as(u32, 7), e.get(entity, Marker).?.tag);
    try testing.expect(e.has(entity, Marker));

    // Destroy it. The sparse-set slot lingers (modelling the real backend), so
    // an UNGUARDED getComponent would return the stale use-after-free pointer.
    e.destroyEntity(entity);
    try testing.expect(!e.entityExists(entity));

    // The #59 crash path: reading the now-dead id (as an event payload would).
    // The core-side guard must short-circuit on `entityExists` and return
    // null/false WITHOUT calling the backend's unchecked lookup.
    try testing.expect(e.get(entity, Marker) == null);
    try testing.expect(!e.has(entity, Marker));

    // The other "id shape from a payload" case: a never-valid / fabricated id.
    try testing.expect(e.get(9999, Marker) == null);
    try testing.expect(!e.has(9999, Marker));

    // Proof the guard routed AROUND the crash surface: the unsafe branch a real
    // backend segfaults in was never entered. Without the fix this is non-zero
    // (and `e.get(entity, Marker)` above would have returned the stale pointer).
    try testing.expectEqual(@as(usize, 0), backend.dead_lookups);
}

test "MockEcsBackend: view iterates entities with matching components" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };

    // e1 has Pos only, e2 has Pos+Vel, e3 has Vel only
    const e1 = backend.createEntity();
    const e2 = backend.createEntity();
    const e3 = backend.createEntity();

    backend.addComponent(e1, Pos{ .x = 1, .y = 0 });
    backend.addComponent(e2, Pos{ .x = 2, .y = 0 });
    backend.addComponent(e2, Vel{ .dx = 1, .dy = 0 });
    backend.addComponent(e3, Vel{ .dx = 2, .dy = 0 });

    // View with Pos only — should match e1 and e2
    {
        var v = backend.view(.{Pos}, .{});
        defer v.deinit();
        var count: usize = 0;
        while (v.next()) |_| count += 1;
        try testing.expectEqual(2, count);
    }

    // View with Pos+Vel — should match only e2
    {
        var v = backend.view(.{ Pos, Vel }, .{});
        defer v.deinit();
        var count: usize = 0;
        var found: u32 = 0;
        while (v.next()) |entity| {
            count += 1;
            found = entity;
        }
        try testing.expectEqual(1, count);
        try testing.expectEqual(e2, found);
    }
}

test "MockEcsBackend: viewExcluding filters out excluded components" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };
    const Locked = struct {};

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    e.add(e1, Pos{ .x = 1, .y = 0 });
    e.add(e2, Pos{ .x = 2, .y = 0 });
    e.add(e2, Locked{});
    e.add(e3, Pos{ .x = 3, .y = 0 });
    e.add(e3, Vel{ .dx = 1, .dy = 0 });

    // viewExcluding: Pos but not Locked — should match e1 and e3
    {
        var v = e.viewExcluding(.{Pos}, .{Locked});
        defer v.deinit();
        var count: usize = 0;
        while (v.next()) |entity| {
            count += 1;
            try testing.expect(entity != e2);
        }
        try testing.expectEqual(2, count);
    }
}

test "Position: basic math" {
    const a = Position{ .x = 3, .y = 4 };
    const b = Position{ .x = 1, .y = 2 };

    const sum = a.add(b);
    try testing.expectEqual(4.0, sum.x);
    try testing.expectEqual(6.0, sum.y);

    const diff = a.sub(b);
    try testing.expectEqual(2.0, diff.x);
    try testing.expectEqual(2.0, diff.y);

    try testing.expectEqual(5.0, a.length());
    try testing.expectEqual(a.distance(b), diff.length());

    const scaled = b.scale(3);
    try testing.expectEqual(3.0, scaled.x);
    try testing.expectEqual(6.0, scaled.y);
}

test "AudioInterface(StubAudio) compiles" {
    const Audio = AudioInterface(StubAudio);
    Audio.playSound(0);
    Audio.stopSound(0);
    Audio.setVolume(0.5);
}

test "InputInterface(StubInput) compiles" {
    const Input = InputInterface(StubInput);
    try testing.expect(!Input.isKeyDown(0));
    try testing.expect(!Input.isKeyPressed(0));
    try testing.expectEqual(0.0, Input.getMouseX());
    try testing.expectEqual(0.0, Input.getMouseY());
}

test "GuiInterface(StubGui) compiles" {
    const Gui = GuiInterface(StubGui);
    Gui.begin();
    Gui.end();
    try testing.expect(!Gui.wantsMouse());
    try testing.expect(!Gui.wantsKeyboard());
}

test "GizmoInterface(StubGizmos) draws and counts" {
    const Gizmo = GizmoInterface(StubGizmos);
    StubGizmos.reset();

    Gizmo.drawLine(0, 0, 10, 10, 0xFF0000);
    Gizmo.drawRect(5, 5, 20, 20, 0x00FF00);
    Gizmo.drawCircle(50, 50, 10, 0x0000FF);
    Gizmo.drawText(0, 0, "debug", 0xFFFFFF);
    Gizmo.drawLineBetween(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, 0xFF0000);

    try testing.expectEqual(2, StubGizmos.getLineCount());
    try testing.expectEqual(1, StubGizmos.getRectCount());
    try testing.expectEqual(1, StubGizmos.getCircleCount());
    try testing.expectEqual(1, StubGizmos.getTextCount());
}

test "RenderInterface(StubRender) validates" {
    const Renderer = StubRender(u32);
    _ = RenderInterface(Renderer);

    var r = Renderer.init(testing.allocator);
    defer r.deinit();

    r.trackEntity(1, .sprite);
    try testing.expectEqual(1, r.tracked_count);

    r.untrackEntity(1);
    try testing.expectEqual(0, r.tracked_count);

    r.render();
    try testing.expectEqual(1, r.render_count);

    r.setScreenHeight(600);
    r.clear();
    try testing.expectEqual(0, r.tracked_count);
}

test "StubRender: component types have expected fields" {
    const Renderer = StubRender(u32);
    const sprite = Renderer.Sprite{ .sprite_name = "hero" };
    try testing.expectEqualStrings("hero", sprite.sprite_name);

    const shape = Renderer.Shape{
        .shape = .{ .rectangle = .{ .width = 50, .height = 50 } },
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expect(shape.visible);
}

test "MockEcsBackend: single component query with data access" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    e.add(e1, Pos{ .x = 1, .y = 2 });
    e.add(e2, Pos{ .x = 3, .y = 4 });
    // e3 has no Pos

    _ = e3;

    var q = e.query(.{Pos});
    defer q.deinit();

    var count: usize = 0;
    var sum_x: f32 = 0;
    while (q.next()) |row| {
        sum_x += row.comp_0.x;
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expectEqual(4.0, sum_x); // 1 + 3
}

test "MockEcsBackend: multi-component query" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Health = struct { current: u32, max: u32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    // e1: Pos + Health
    e.add(e1, Pos{ .x = 10, .y = 20 });
    e.add(e1, Health{ .current = 100, .max = 100 });

    // e2: Pos only
    e.add(e2, Pos{ .x = 30, .y = 40 });

    // e3: Health only
    e.add(e3, Health{ .current = 50, .max = 50 });

    var q = e.query(.{ Pos, Health });
    defer q.deinit();

    var count: usize = 0;
    while (q.next()) |row| {
        try testing.expectEqual(10.0, row.comp_0.x);
        try testing.expectEqual(100, row.comp_1.current);
        count += 1;
    }
    try testing.expectEqual(1, count);
}

test "ParentComponent and ChildrenComponent" {
    const Parent = ParentComponent(u32);
    const Children = ChildrenComponent(u32);

    const p = Parent{ .entity = 42 };
    try testing.expectEqual(42, p.entity);
    try testing.expect(!p.inherit_rotation);

    const c = Children{};
    try testing.expectEqual(@as(usize, 0), c.count());
}

test "ChildrenComponent grows past the old 16 cap without dropping (+ no leak)" {
    // #657: the old `[16]Entity` buffer silently dropped overflow, orphaning
    // fixtures from teardown. The ArrayList backing has no cap. Using
    // `testing.allocator` doubles as the heap-ownership guard: if `deinit`
    // failed to free the backing allocation, the test would fail on a leak.
    const Children = ChildrenComponent(u32);
    var c = Children{};
    defer c.deinit(testing.allocator);

    var i: u32 = 0;
    while (i < 100) : (i += 1) c.addChild(testing.allocator, i);
    try testing.expectEqual(@as(usize, 100), c.count());
    try testing.expectEqual(@as(u32, 0), c.getChildren()[0]);
    try testing.expectEqual(@as(u32, 99), c.getChildren()[99]);

    // swapRemove semantics: removing an interior id pulls the last into its
    // slot, so order is not preserved but every other id survives.
    c.removeChild(50);
    try testing.expectEqual(@as(usize, 99), c.count());
    for (c.getChildren()) |ch| try testing.expect(ch != 50);

    // Removing a non-member is a no-op.
    c.removeChild(9999);
    try testing.expectEqual(@as(usize, 99), c.count());
}

test "ParentComponent is saveable with entity ref" {
    // Regression for #11 — Parent used to have no save declaration, so
    // parent-child hierarchies were lost on save/load and children
    // rendered at their saved local Position as if it were world-space.
    // This test pins the save contract: `.saveable` + `entity` in
    // `entity_refs` so the ID-remap table rewrites the parent handle
    // on load.
    const Parent = ParentComponent(u32);

    try testing.expect(root.hasSavePolicy(Parent));
    try testing.expectEqual(root.SavePolicy.saveable, root.getSavePolicy(Parent).?);

    const refs = root.getEntityRefFields(Parent);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("entity", refs[0]);
}

test "MockEcsBackend frees heap-owning ChildrenComponent (no leak)" {
    // codex #65: storing a ChildrenComponent through the ECS allocates in
    // `addChild`; the mock must free that backing list on remove / overwrite /
    // teardown, or `testing.allocator` flags the leak here.
    const Children = ChildrenComponent(u32);
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit(); // teardown must free the surviving child list

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    // Stored-and-survives: freed by backend teardown.
    const parent = e.createEntity();
    var kids = Children{};
    var i: u32 = 0;
    while (i < 30) : (i += 1) kids.addChild(testing.allocator, i);
    e.add(parent, kids); // moves the ArrayList into storage (don't deinit `kids`)
    try testing.expectEqual(@as(usize, 30), e.get(parent, Children).?.count());

    // Explicit remove must free too (not just teardown).
    const p2 = e.createEntity();
    var kids2 = Children{};
    kids2.addChild(testing.allocator, 7);
    e.add(p2, kids2);
    e.remove(p2, Children);

    // Overwrite of the same (entity, T) must free the prior list.
    var kids3 = Children{};
    kids3.addChild(testing.allocator, 1);
    e.add(parent, kids3); // overwrites the 30-child list → prior must be freed
    try testing.expectEqual(@as(usize, 1), e.get(parent, Children).?.count());
}

test "ChildrenComponent stays transient (rebuilt from Parent on load)" {
    // The engine derives Children from Parent, so persisting it would
    // double-source the relationship. Keep it unsaved — Parent is the
    // authoritative edge. If this test starts failing, the Parent-only
    // save strategy in #11 is out of sync with the hierarchy design.
    const Children = ChildrenComponent(u32);
    try testing.expect(!root.hasSavePolicy(Children));
}

test "PrefabInstance: default construction + field shape" {
    const pi = PrefabInstance{};
    try testing.expectEqualStrings("", pi.path);
    try testing.expectEqualStrings("", pi.overrides);

    const seeded = PrefabInstance{
        .path = "hydroponics",
        .overrides = "{\"Position\":{\"x\":156}}",
    };
    try testing.expectEqualStrings("hydroponics", seeded.path);
    try testing.expectEqualStrings("{\"Position\":{\"x\":156}}", seeded.overrides);
}

test "PrefabInstance is saveable (no entity refs)" {
    // PrefabInstance carries no entity handles — just the prefab path
    // + opaque overrides blob. `.saveable` + empty `entity_refs` pins
    // that contract so the engine's save mixin knows to round-trip it
    // without running the ID-remap table over anything.
    try testing.expect(root.hasSavePolicy(PrefabInstance));
    try testing.expectEqual(root.SavePolicy.saveable, root.getSavePolicy(PrefabInstance).?);

    const refs = root.getEntityRefFields(PrefabInstance);
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "PrefabChild: default construction + field shape" {
    const Child = PrefabChild(u32);
    const c = Child{ .root = 42, .local_path = "children[0]" };
    try testing.expectEqual(@as(u32, 42), c.root);
    try testing.expectEqualStrings("children[0]", c.local_path);
}

test "PrefabChild is saveable with entity ref on `root`" {
    // `root` points back at the PrefabInstance root entity and MUST
    // be remapped through the load `id_map` — otherwise children of a
    // prefab would lose their lineage back to the root entity after
    // save/load, breaking the two-phase restore's `(root, local_path)`
    // keying. Mirrors `ParentComponent`'s `entity_refs = &.{"entity"}`
    // contract (see the Parent test above).
    const Child = PrefabChild(u32);

    try testing.expect(root.hasSavePolicy(Child));
    try testing.expectEqual(root.SavePolicy.saveable, root.getSavePolicy(Child).?);

    const refs = root.getEntityRefFields(Child);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("root", refs[0]);
}

test "PrefabChild generic: different Entity types compile independently" {
    // Confirms the comptime generic accepts any unsigned integer
    // Entity handle type without collapsing them to the same concrete
    // type (zig-ecs uses u32; future backends could differ).
    const C32 = PrefabChild(u32);
    const C64 = PrefabChild(u64);
    try testing.expect(C32 != C64);

    const c32 = C32{ .root = 1, .local_path = "children[0]" };
    const c64 = C64{ .root = 0xFFFF_FFFF_0000_0000, .local_path = "children[1]" };
    try testing.expectEqual(@as(u32, 1), c32.root);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_0000_0000), c64.root);
}

test "gameToScreen: converts Y-up to Y-down" {
    // Screen height 600: game y=0 (bottom) -> screen y=600 (bottom)
    try testing.expectEqual(@as(f32, 600.0), gameToScreen(0, 600));
    // game y=600 (top) -> screen y=0 (top)
    try testing.expectEqual(@as(f32, 0.0), gameToScreen(600, 600));
    // game y=100 -> screen y=500
    try testing.expectEqual(@as(f32, 500.0), gameToScreen(100, 600));
}

test "screenToGame: converts Y-down to Y-up" {
    // screen y=0 (top) -> game y=600 (top)
    try testing.expectEqual(@as(f32, 600.0), screenToGame(0, 600));
    // screen y=600 (bottom) -> game y=0 (bottom)
    try testing.expectEqual(@as(f32, 0.0), screenToGame(600, 600));
    // screen y=100 -> game y=500
    try testing.expectEqual(@as(f32, 500.0), screenToGame(100, 600));
}

test "gameToScreen and screenToGame are inverse operations" {
    const screen_height: f32 = 480;
    const original_y: f32 = 123.45;

    const screen_y = gameToScreen(original_y, screen_height);
    const round_trip = screenToGame(screen_y, screen_height);
    try testing.expectApproxEqAbs(original_y, round_trip, 0.001);
}

test "toScreenY: .up flips (matches the renderer's height - y)" {
    // .up = bottom-origin: y=0 -> screen height, y=height -> 0.
    try testing.expectEqual(@as(f32, 600.0), toScreenY(.up, 0, 600));
    try testing.expectEqual(@as(f32, 0.0), toScreenY(.up, 600, 600));
    try testing.expectEqual(@as(f32, 500.0), toScreenY(.up, 100, 600));
    // .up must agree with the existing renderer flip / gameToScreen exactly.
    try testing.expectEqual(gameToScreen(123.0, 600.0), toScreenY(.up, 123.0, 600.0));
}

test "toScreenY: .down is identity (matches screen space)" {
    try testing.expectEqual(@as(f32, 0.0), toScreenY(.down, 0, 600));
    try testing.expectEqual(@as(f32, 600.0), toScreenY(.down, 600, 600));
    try testing.expectEqual(@as(f32, 100.0), toScreenY(.down, 100, 600));
}

test "screenToLogicalY: .up flips, .down is identity" {
    try testing.expectEqual(@as(f32, 600.0), screenToLogicalY(.up, 0, 600));
    try testing.expectEqual(@as(f32, 0.0), screenToLogicalY(.up, 600, 600));
    try testing.expectEqual(@as(f32, 250.0), screenToLogicalY(.down, 250, 600));
}

test "toScreenY/screenToLogicalY are inverse for both axes" {
    const height: f32 = 600;
    inline for (.{ YAxis.up, YAxis.down }) |axis| {
        for ([_]f32{ 0, 1, 100, 250.5, 599, 600 }) |y| {
            const screen = toScreenY(axis, y, height);
            try testing.expectEqual(y, screenToLogicalY(axis, screen, height));
        }
    }
}

test "GamePosition.toScreen and ScreenPosition.toGame" {
    const game_pos = GamePosition{ .pos = .{ .x = 50, .y = 100 } };
    const screen_pos = game_pos.toScreen(600);

    try testing.expectEqual(@as(f32, 50.0), screen_pos.pos.x);
    try testing.expectEqual(@as(f32, 500.0), screen_pos.pos.y);

    const back = screen_pos.toGame(600);
    try testing.expectEqual(@as(f32, 50.0), back.pos.x);
    try testing.expectEqual(@as(f32, 100.0), back.pos.y);
}

test "CoordinateSystem enum values" {
    try testing.expect(CoordinateSystem.y_up != CoordinateSystem.y_down);
}

test "Query: single component with data access" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    e.add(e1, Pos{ .x = 10, .y = 20 });
    e.add(e2, Pos{ .x = 30, .y = 40 });

    var q = e.query(.{Pos});
    defer q.deinit();

    var count: usize = 0;
    var sum_x: f32 = 0;
    while (q.next()) |row| {
        sum_x += row.comp_0.x;
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expectEqual(40.0, sum_x); // 10 + 30
}

test "Query: multiple components with data access" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    // e1 has both Pos and Vel
    e.add(e1, Pos{ .x = 1, .y = 2 });
    e.add(e1, Vel{ .dx = 10, .dy = 20 });

    // e2 has only Pos — should NOT appear in query(.{Pos, Vel})
    e.add(e2, Pos{ .x = 3, .y = 4 });

    // e3 has both
    e.add(e3, Pos{ .x = 5, .y = 6 });
    e.add(e3, Vel{ .dx = 50, .dy = 60 });

    var q = e.query(.{ Pos, Vel });
    defer q.deinit();

    var count: usize = 0;
    var sum_dx: f32 = 0;
    while (q.next()) |row| {
        // Verify both component pointers are accessible
        sum_dx += row.comp_1.dx;
        try testing.expect(row.comp_0.x > 0);
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expectEqual(60.0, sum_dx); // 10 + 50
}

test "Query: mutable pointers allow component modification" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };

    const entity = e.createEntity();
    e.add(entity, Pos{ .x = 0, .y = 0 });
    e.add(entity, Vel{ .dx = 5, .dy = 10 });

    // Use query to modify position based on velocity
    var q = e.query(.{ Pos, Vel });
    defer q.deinit();

    while (q.next()) |row| {
        row.comp_0.x += row.comp_1.dx;
        row.comp_0.y += row.comp_1.dy;
    }

    // Verify modification persisted
    const pos = e.get(entity, Pos).?;
    try testing.expectEqual(5.0, pos.x);
    try testing.expectEqual(10.0, pos.y);
}

const CapturingLogSink = struct {
    const LogLevel = root.LogLevel;

    var last_level: ?LogLevel = null;
    var last_scope: []const u8 = "";
    var last_elapsed: f64 = 0;
    var call_count: usize = 0;

    pub fn write(
        level: LogLevel,
        comptime scope: []const u8,
        elapsed_s: f64,
        comptime _: []const u8,
        _: anytype,
    ) void {
        last_level = level;
        last_scope = scope;
        last_elapsed = elapsed_s;
        call_count += 1;
    }

    fn reset() void {
        last_level = null;
        last_scope = "";
        last_elapsed = 0;
        call_count = 0;
    }
};

test "LogSinkInterface forwards level, scope, and elapsed time to sink" {
    const Log = LogSinkInterface(CapturingLogSink);
    CapturingLogSink.reset();

    Log.write(.info, "player", 1.5, "spawned at ({d}, {d})", .{ 10, 20 });

    try testing.expectEqual(root.LogLevel.info, CapturingLogSink.last_level.?);
    try testing.expectEqualStrings("player", CapturingLogSink.last_scope);
    try testing.expectApproxEqAbs(@as(f64, 1.5), CapturingLogSink.last_elapsed, 1e-9);
    try testing.expectEqual(@as(usize, 1), CapturingLogSink.call_count);
}

test "LogSinkInterface tracks multiple writes" {
    const Log = LogSinkInterface(CapturingLogSink);
    CapturingLogSink.reset();

    Log.write(.debug, "physics", 0.0, "step", .{});
    Log.write(.warn, "audio", 2.5, "buffer underrun", .{});

    try testing.expectEqual(root.LogLevel.warn, CapturingLogSink.last_level.?);
    try testing.expectEqualStrings("audio", CapturingLogSink.last_scope);
    try testing.expectApproxEqAbs(@as(f64, 2.5), CapturingLogSink.last_elapsed, 1e-9);
    try testing.expectEqual(@as(usize, 2), CapturingLogSink.call_count);
}

test "LogSinkInterface with empty scope" {
    const Log = LogSinkInterface(CapturingLogSink);
    CapturingLogSink.reset();

    Log.write(.err, "", 0.123, "fatal", .{});

    try testing.expectEqual(root.LogLevel.err, CapturingLogSink.last_level.?);
    try testing.expectEqualStrings("", CapturingLogSink.last_scope);
}

test "StubLogSink is a valid LogSinkInterface implementation" {
    const Log = LogSinkInterface(StubLogSink);
    Log.write(.info, "test", 0.0, "{s}", .{"msg"});
    Log.flush();
}

test "StderrLogSink is a valid LogSinkInterface implementation" {
    // Validates the full write path compiles (format string + tuple concat).
    // Output goes to stderr which is expected in test runs.
    const Log = LogSinkInterface(StderrLogSink);
    Log.write(.debug, "test", 0.0, "compile check", .{});
}

test "TypedLog is reachable through the labelle-core public API" {
    // The typed structured-decision log is consumed by caretaker rules,
    // schedulers, and command buffers. This test exists to catch a
    // regression where the re-export breaks without anyone noticing.
    var log = root.TypedLog(4){};
    log.setTick(7);
    log.add("test", "entity {d}", .{42});

    try testing.expectEqual(@as(usize, 1), log.slice().len);
    try testing.expectEqualStrings("test", log.slice()[0].rule);
    try testing.expectEqual(@as(u64, 7), log.slice()[0].tick);
    try testing.expectEqualStrings("entity 42", log.slice()[0].message());

    // LogEntry is also a public re-export.
    const entry: root.LogEntry = .{ .rule = "x", .msg_len = 0 };
    try testing.expectEqualStrings("x", entry.rule);
}

// ---------------------------------------------------------------------------
// RFC-FLOW-VOCABULARY phase 1 — comptime contracts.
//
// These tests pin the shape of `FlowNode` / `PinSpec` / `PinStyle` /
// `PinStyles` and the `default_pin_styles` set. The assembler (phase 2)
// and flow-codegen (phase 3) will rely on these shapes; the gui (phase
// 4) and plugin authors (phase 5) layer on top. No discovery walk is
// exercised here — that's not in this phase.
// ---------------------------------------------------------------------------

const FlowNode = root.FlowNode;
const FlowNodeKind = root.FlowNodeKind;
const PinSpec = root.PinSpec;
const PinStyle = root.PinStyle;
const PinStyles = root.PinStyles;
const Color = root.Color;
const EntityId = root.EntityId;
const default_pin_styles = root.default_pin_styles;

// Sample impls used by the FlowNode tests. They mimic the shapes
// real plugins will use: first param `game: anytype`, remaining params
// are input pins, return type drives `kind` inference.

fn sampleCommandImpl(game: anytype, body_id: u32, x: f32, y: f32) void {
    _ = game;
    _ = body_id;
    _ = x;
    _ = y;
}

fn sampleReporterImpl(game: anytype, body_id: u32) f32 {
    _ = game;
    _ = body_id;
    return 0.0;
}

test "FlowNode: minimal config (only impl) gets all defaults" {
    // Authors should be able to write `FlowNode(.{ .impl = foo })` and
    // get every other field defaulted. This is the one-line happy path
    // the RFC §1 motivation calls out — "A minimal `FlowNode` is one
    // line. Defaults absorb the verbosity."
    const node = FlowNode(.{ .impl = sampleCommandImpl });

    try testing.expectEqual(@as(?[]const u8, null), node.display_name);
    try testing.expectEqual(@as(?[]const u8, null), node.category);
    try testing.expectEqual(@as(?[]const u8, null), node.docs);
    try testing.expectEqual(@as(?FlowNodeKind, null), node.kind);

    // `pins` defaults to `.{}` (empty anon-struct); we can introspect
    // it via @typeInfo. No fields means "every pin reflects from impl".
    const pins_info = @typeInfo(@TypeOf(node.pins));
    try testing.expectEqual(@as(usize, 0), pins_info.@"struct".fields.len);

    // The marker decl is what the assembler will scan for.
    try testing.expect(@hasDecl(@TypeOf(node), "__is_labelle_flow_node"));
    try testing.expect(@TypeOf(node).__is_labelle_flow_node);
}

test "FlowNode: impl is preserved as a comptime decl with original type" {
    // The assembler reflects on `@TypeOf(@This().impl)` to discover
    // pin names + types. If the function type were erased to e.g.
    // `*const anyopaque`, that reflection would lose param names.
    // Pin both: the decl exists and `@TypeOf` is the original function
    // type.
    const node = FlowNode(.{ .impl = sampleCommandImpl });

    try testing.expect(@hasDecl(@TypeOf(node), "impl"));
    try testing.expectEqual(@TypeOf(sampleCommandImpl), @TypeOf(@TypeOf(node).impl));

    // The function value itself is the same.
    try testing.expectEqual(&sampleCommandImpl, &@TypeOf(node).impl);
}

test "FlowNode: all fields set is accepted and preserved" {
    // Maximum-config form — covers every overrideable field at once.
    // Useful as a contract test that the factory doesn't silently
    // drop a field it doesn't recognize.
    const node = FlowNode(.{
        .impl = sampleCommandImpl,
        .display_name = "Apply Impulse",
        .category = "Physics",
        .docs = "Apply a linear impulse to the given body.",
        .kind = FlowNodeKind.command,
        .pins = .{
            .body_id = PinSpec{ .label = "Body" },
            .x = PinSpec{ .label = "Velocity X", .default = "0" },
            .y = PinSpec{ .label = "Velocity Y", .default = "0" },
        },
    });

    try testing.expectEqualStrings("Apply Impulse", node.display_name.?);
    try testing.expectEqualStrings("Physics", node.category.?);
    try testing.expectEqualStrings(
        "Apply a linear impulse to the given body.",
        node.docs.?,
    );
    try testing.expectEqual(FlowNodeKind.command, node.kind.?);

    try testing.expectEqualStrings("Body", node.pins.body_id.label.?);
    try testing.expectEqualStrings("Velocity X", node.pins.x.label.?);
    try testing.expectEqualStrings("0", node.pins.x.default.?);
    try testing.expectEqualStrings("Velocity Y", node.pins.y.label.?);
}

test "FlowNode: reporter impl (non-void return) is accepted" {
    // The factory doesn't enforce the void/non-void → command/reporter
    // mapping itself — the assembler does that during codegen, per
    // RFC §1. The factory just preserves the impl's type so the
    // assembler can read its return type via reflection. Pin that the
    // factory accepts a reporter impl with no `kind` field set.
    const node = FlowNode(.{ .impl = sampleReporterImpl });

    try testing.expectEqual(@as(?FlowNodeKind, null), node.kind);

    // Reflection sees the return type the assembler will key on.
    const ImplT = @TypeOf(@TypeOf(node).impl);
    const fn_info = @typeInfo(ImplT).@"fn";
    try testing.expectEqual(f32, fn_info.return_type.?);
}

test "FlowNode: missing impl is a compile error" {
    // The factory must reject configs without `.impl`. This test
    // documents the contract — flipping it to a runtime check would
    // be a regression because the whole point is to fail fast at
    // discovery time, not at game runtime.
    //
    // We can't `try expectError(@compileError(...))` on this directly
    // — comptime errors abort compilation — so the inverse is what's
    // covered above: minimal config WITH impl compiles. If someone
    // changes the factory to make impl optional, this test block can
    // be flipped to assert the absent case compiles, and the diff
    // will be obvious in code review.
    const node = FlowNode(.{ .impl = sampleCommandImpl });
    _ = node;
}

test "FlowNode: each call produces a distinct return type" {
    // The factory's return type is generic over the config — two
    // impls with different signatures must produce two different
    // types so reflection sees the right pin shape per node.
    const a = FlowNode(.{ .impl = sampleCommandImpl });
    const b = FlowNode(.{ .impl = sampleReporterImpl });
    try testing.expect(@TypeOf(a) != @TypeOf(b));
}

test "FlowNodeKind: command and reporter are distinct" {
    try testing.expect(FlowNodeKind.command != FlowNodeKind.reporter);
}

test "PinSpec: default construction has every field null" {
    const spec = PinSpec{};
    try testing.expectEqual(@as(?[]const u8, null), spec.label);
    try testing.expectEqual(@as(?[]const u8, null), spec.default);
    try testing.expectEqual(@as(?[]const u8, null), spec.docs);
}

test "PinSpec: full construction round-trips every field" {
    const spec = PinSpec{
        .label = "Velocity X",
        .default = "0.0",
        .docs = "Linear velocity along world X.",
    };
    try testing.expectEqualStrings("Velocity X", spec.label.?);
    try testing.expectEqualStrings("0.0", spec.default.?);
    try testing.expectEqualStrings("Linear velocity along world X.", spec.docs.?);
}

test "PinStyle: default construction has every field null" {
    const style = PinStyle{};
    try testing.expectEqual(@as(?[]const u8, null), style.label);
    try testing.expectEqual(@as(?Color, null), style.color);
    try testing.expectEqual(@as(?[]const u8, null), style.icon);
}

test "PinStyle: full construction round-trips every field" {
    const style = PinStyle{
        .label = "Body",
        .color = .{ .r = 50, .g = 100, .b = 200, .a = 255 },
        .icon = "physics",
    };
    try testing.expectEqualStrings("Body", style.label.?);
    try testing.expectEqual(@as(u8, 50), style.color.?.r);
    try testing.expectEqual(@as(u8, 100), style.color.?.g);
    try testing.expectEqual(@as(u8, 200), style.color.?.b);
    try testing.expectEqualStrings("physics", style.icon.?);
}

test "Color: defaults to opaque white" {
    const c = Color{};
    try testing.expectEqual(@as(u8, 255), c.r);
    try testing.expectEqual(@as(u8, 255), c.g);
    try testing.expectEqual(@as(u8, 255), c.b);
    try testing.expectEqual(@as(u8, 255), c.a);
}

test "Color: white and black constants" {
    try testing.expectEqual(@as(u8, 255), Color.white.r);
    try testing.expectEqual(@as(u8, 0), Color.black.r);
    try testing.expectEqual(@as(u8, 255), Color.black.a);
}

test "EntityId: collapses to u32 for default pin styles" {
    // EntityId is a type alias, so the underlying type collapses to
    // u32 per the §2 wire-fit rule. Pin that here so a future change
    // (e.g. wrapping it in a `struct { id: u32 }`) is a deliberate
    // breaking change with a failing test in this very file.
    try testing.expectEqual(u32, EntityId);
}

test "PinStyles: convention marker exists and is a struct" {
    // PinStyles is a convention name — phase 2 (assembler) walks
    // `mod.PinStyles`'s decls. The marker here exists so the
    // convention has a documented anchor. Pin that it's reachable
    // and is a struct (the only shape the assembler will scan).
    const info = @typeInfo(PinStyles);
    try testing.expect(info == .@"struct");
}

test "default_pin_styles: ships an entry for every primitive + EntityId" {
    // The editor + assembler key default styles by decl name on this
    // namespace. Pin that every promised default is present and the
    // colors are sane (non-zero alpha). If a future change drops one,
    // the test names below say which.
    try testing.expect(@hasDecl(default_pin_styles, "u32_style"));
    try testing.expect(@hasDecl(default_pin_styles, "i32_style"));
    try testing.expect(@hasDecl(default_pin_styles, "u64_style"));
    try testing.expect(@hasDecl(default_pin_styles, "i64_style"));
    try testing.expect(@hasDecl(default_pin_styles, "f32_style"));
    try testing.expect(@hasDecl(default_pin_styles, "f64_style"));
    try testing.expect(@hasDecl(default_pin_styles, "bool_style"));
    try testing.expect(@hasDecl(default_pin_styles, "string_style"));
    try testing.expect(@hasDecl(default_pin_styles, "entity_id_style"));

    // Spot-check the integer + float + entity styles' labels — the
    // editor renders these in the palette and the tooltip on a pin.
    try testing.expectEqualStrings("Integer", default_pin_styles.u32_style.label.?);
    try testing.expectEqualStrings("Integer", default_pin_styles.i32_style.label.?);
    try testing.expectEqualStrings("Number", default_pin_styles.f32_style.label.?);
    try testing.expectEqualStrings("Number", default_pin_styles.f64_style.label.?);
    try testing.expectEqualStrings("Bool", default_pin_styles.bool_style.label.?);
    try testing.expectEqualStrings("Text", default_pin_styles.string_style.label.?);
    try testing.expectEqualStrings("Entity", default_pin_styles.entity_id_style.label.?);

    // Every shipped color has a non-zero alpha — a transparent default
    // would be a footgun.
    try testing.expect(default_pin_styles.u32_style.color.?.a > 0);
    try testing.expect(default_pin_styles.f32_style.color.?.a > 0);
    try testing.expect(default_pin_styles.bool_style.color.?.a > 0);
    try testing.expect(default_pin_styles.string_style.color.?.a > 0);
    try testing.expect(default_pin_styles.entity_id_style.color.?.a > 0);
}

// ─── numericFits: RFC §2 / O1 wire-fit widening table ──────────────
//
// Pin the exact set of auto-accepted numeric conversions resolved by
// the RFC's open question O1. Editor (labelle-gui/flow_node_catalog)
// and codegen (flow-codegen) both consult this helper for primitive
// pin compatibility; the tests here are the source of truth.

const numericFits = root.numericFits;

test "numericFits: equality always fits" {
    try testing.expect(numericFits(i32, i32));
    try testing.expect(numericFits(u32, u32));
    try testing.expect(numericFits(f32, f32));
    try testing.expect(numericFits(bool, bool));
}

test "numericFits: same-sign integer widening accepted" {
    try testing.expect(numericFits(i8, i16));
    try testing.expect(numericFits(i8, i32));
    try testing.expect(numericFits(i16, i32));
    try testing.expect(numericFits(i32, i64));
    try testing.expect(numericFits(i64, i128));

    try testing.expect(numericFits(u8, u16));
    try testing.expect(numericFits(u8, u32));
    try testing.expect(numericFits(u16, u32));
    try testing.expect(numericFits(u32, u64));
    try testing.expect(numericFits(u64, u128));
}

test "numericFits: integer narrowing refused" {
    try testing.expect(!numericFits(i32, i16));
    try testing.expect(!numericFits(i64, i32));
    try testing.expect(!numericFits(u32, u16));
    try testing.expect(!numericFits(u64, u32));
}

test "numericFits: unsigned to larger signed accepted, equal-or-smaller signed refused" {
    // Unsigned → strictly-larger signed: every value representable.
    try testing.expect(numericFits(u8, i16));
    try testing.expect(numericFits(u8, i32));
    try testing.expect(numericFits(u16, i32));
    try testing.expect(numericFits(u16, i64));
    try testing.expect(numericFits(u32, i64));
    try testing.expect(numericFits(u32, i128));
    try testing.expect(numericFits(u64, i128));

    // Unsigned → equal-or-smaller signed: would lose the high bit.
    try testing.expect(!numericFits(u8, i8));
    try testing.expect(!numericFits(u16, i16));
    try testing.expect(!numericFits(u32, i32));
    try testing.expect(!numericFits(u64, i64));
    try testing.expect(!numericFits(u32, i16));
}

test "numericFits: signed to unsigned refused (sign loss)" {
    try testing.expect(!numericFits(i8, u8));
    try testing.expect(!numericFits(i8, u16));
    try testing.expect(!numericFits(i32, u32));
    try testing.expect(!numericFits(i32, u64));
    try testing.expect(!numericFits(i64, u64));
}

test "numericFits: float widening accepted, narrowing refused" {
    try testing.expect(numericFits(f32, f64));
    try testing.expect(!numericFits(f64, f32));
}

test "numericFits: int <-> float refused (lossy / surprising)" {
    // Int → float: lossy for large ints (f32 only has 24 bits of
    // mantissa, f64 only 53).
    try testing.expect(!numericFits(i32, f32));
    try testing.expect(!numericFits(i32, f64));
    try testing.expect(!numericFits(i64, f64));
    try testing.expect(!numericFits(u32, f32));
    try testing.expect(!numericFits(u32, f64));
    try testing.expect(!numericFits(u64, f64));

    // Float → int: truncation surprises.
    try testing.expect(!numericFits(f32, i32));
    try testing.expect(!numericFits(f64, i64));
    try testing.expect(!numericFits(f32, u32));
}

test "numericFits: aliases collapse via Zig type equality" {
    // `EntityId` is `u32` — same underlying type, so it fits both ways
    // trivially. The wire-fit caller relies on this: it doesn't have a
    // separate "alias" branch.
    try testing.expect(numericFits(EntityId, u32));
    try testing.expect(numericFits(u32, EntityId));
    try testing.expect(numericFits(EntityId, EntityId));
    // EntityId widens to u64 the same way u32 does.
    try testing.expect(numericFits(EntityId, u64));
    // EntityId → i32: same as u32 → i32, sign-bit collision → refused.
    try testing.expect(!numericFits(EntityId, i32));
    // EntityId → i64: same as u32 → i64, widens cleanly.
    try testing.expect(numericFits(EntityId, i64));
}

test "FlowNode: constructs defaults to null when omitted" {
    const node = FlowNode(.{ .impl = sampleCommandImpl });
    try testing.expectEqual(@as(?[]const u8, null), node.constructs);
}

test "FlowNode: constructs is preserved when set" {
    // RFC-FLOW-VOCABULARY §1, open question O5 — the editor needs a way
    // to know which nodes return a value of a given Zig type so it can
    // suggest constructor nodes for struct-typed variables.
    const node = FlowNode(.{
        .impl = sampleReporterImpl,
        .constructs = "labelle_box2d.RayResult",
    });
    try testing.expectEqualStrings("labelle_box2d.RayResult", node.constructs.?);
}

test "default_pin_styles: same-class types share a color" {
    // Per the palette choice documented on `default_pin_styles`,
    // every integer width shares one color, both float widths share
    // one color. This isn't load-bearing for codegen, but the editor's
    // visual coherence depends on it, so pin the contract.
    const int_color = default_pin_styles.u32_style.color.?;
    try testing.expect(default_pin_styles.i32_style.color.?.r == int_color.r);
    try testing.expect(default_pin_styles.u64_style.color.?.r == int_color.r);
    try testing.expect(default_pin_styles.i64_style.color.?.r == int_color.r);

    const float_color = default_pin_styles.f32_style.color.?;
    try testing.expect(default_pin_styles.f64_style.color.?.r == float_color.r);

    // Entity uses a different color than plain integers, even though
    // its underlying type is u32 — keeps wires from a `u32` integer
    // pin into an `EntityId` pin visually distinct.
    try testing.expect(default_pin_styles.entity_id_style.color.?.r != int_color.r);
}

// ---------------------------------------------------------------------------
// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared Coercions.
//
// Pin the comptime shape: the factory reflects `From`/`To` from the
// impl's signature, exposes `convert` as a comptime decl, sets the
// `__is_labelle_coercion` marker the assembler scans for, and rejects
// degenerate shapes (`void` return, non-single-param impls) at compile
// time. Discovery and emission live in labelle-assembler — the
// contract this module asserts is purely the factory's reflected
// surface.
// ---------------------------------------------------------------------------

const Coercion = root.Coercion;
const Coercions = root.Coercions;

// Sample coercions used below. The thin `body_to_entity` shape is the
// canonical use case: a nominal bridge between two integer-aliased
// handle types where the runtime cost is just a copy / reinterpret.

const BodyId = enum(u32) { _ };

fn bodyToEntityImpl(b: BodyId) u32 {
    return @intFromEnum(b);
}

fn intToFloatImpl(x: i32) f64 {
    return @as(f64, @floatFromInt(x));
}

test "Coercion: From/To reflect from impl signature" {
    const c = Coercion(.{ .impl = bodyToEntityImpl });
    const T = @TypeOf(c);
    try testing.expectEqual(BodyId, T.From);
    try testing.expectEqual(u32, T.To);
}

test "Coercion: convert is preserved with original function type" {
    // Mirror the FlowNode preservation test: the assembler scans the
    // emitted PluginCoercions for `convert`; downstream codegen reads
    // it as a normal function. The decl must carry the original Zig
    // type so reflection sees a single-param fn.
    const c = Coercion(.{ .impl = bodyToEntityImpl });
    const T = @TypeOf(c);
    try testing.expect(@hasDecl(T, "convert"));
    try testing.expectEqual(@TypeOf(bodyToEntityImpl), @TypeOf(T.convert));
    try testing.expectEqual(&bodyToEntityImpl, &T.convert);
}

test "Coercion: marker decl present" {
    // The assembler keys discovery off this marker — same convention
    // as `__is_labelle_flow_node` on `FlowNode`.
    const c = Coercion(.{ .impl = bodyToEntityImpl });
    try testing.expect(@hasDecl(@TypeOf(c), "__is_labelle_coercion"));
    try testing.expect(@TypeOf(c).__is_labelle_coercion);
}

test "Coercion: distinct calls produce distinct return types" {
    const a = Coercion(.{ .impl = bodyToEntityImpl });
    const b = Coercion(.{ .impl = intToFloatImpl });
    try testing.expect(@TypeOf(a) != @TypeOf(b));
}

test "Coercion: docs round-trip when set" {
    const c = Coercion(.{
        .impl = bodyToEntityImpl,
        .docs = "Reinterpret a BodyId handle as an EntityId.",
    });
    try testing.expectEqualStrings(
        "Reinterpret a BodyId handle as an EntityId.",
        c.docs.?,
    );
}

test "Coercion: docs defaults to null" {
    const c = Coercion(.{ .impl = bodyToEntityImpl });
    try testing.expectEqual(@as(?[]const u8, null), c.docs);
}

test "Coercion: convert is callable and produces the expected value" {
    // The factory doesn't wrap or rebind `impl`, so `convert(x)` must
    // dispatch identically to calling the impl directly. Pin that so
    // codegen's `<plugin>__<name>.convert(<expr>)` site behaves like
    // a plain function call (no thunks, no `game` smuggling).
    const T = @TypeOf(Coercion(.{ .impl = bodyToEntityImpl }));
    const result = T.convert(@enumFromInt(42));
    try testing.expectEqual(@as(u32, 42), result);
}

test "Coercions: convention marker is a struct" {
    // The `Coercions` decl in `flow.zig` is just a documentation
    // anchor — `@hasDecl(mod, "Coercions")` is the assembler's
    // contact point, same shape as `PinStyles`.
    try testing.expectEqual(@typeInfo(Coercions).@"struct".fields.len, 0);
}

// Compile-error sanitization: every check below documents the
// negative case as a comment, then asserts the positive case still
// compiles. Flipping a check from rejection to acceptance shows up
// here on review.

test "Coercion: single-param impl is the only accepted shape" {
    // A two-param impl (`fn (game: anytype, x: BodyId) u32`) is rejected
    // at comptime — coercions don't thread `game` (declare a FlowNode
    // for that). A zero-param impl is rejected too. The positive case:
    const c = Coercion(.{ .impl = bodyToEntityImpl });
    _ = c;
}

test "Coercion: non-void return is the only accepted shape" {
    // A `void`-returning impl is rejected at comptime — a coercion
    // must produce a value to wrap an edge expression. The positive
    // case:
    const c = Coercion(.{ .impl = bodyToEntityImpl });
    _ = c;
}

// ── Gamepad event contract (core#18) ─────────────────────────────
// Wave-0 fallback proof: a backend Impl with NO gamepad-event decls
// (StubInput) yields 0 events / 0 descriptions through InputInterface,
// and the per-OS gamepad_source skeleton drains 0 by default.

test "InputInterface: backend with no decls yields 0 gamepad events" {
    const I = InputInterface(StubInput);
    var evbuf: [8]root.GamepadEvent = undefined;
    try testing.expectEqual(@as(usize, 0), I.pollGamepadEvents(&evbuf));
    var dbuf: [8]root.GamepadDescription = undefined;
    try testing.expectEqual(@as(usize, 0), I.describeGamepads(&dbuf));
}

test "InputInterface: backend declaring decls is dispatched" {
    const FakeBackend = struct {
        pub fn isKeyDown(_: u32) bool {
            return false;
        }
        pub fn isKeyPressed(_: u32) bool {
            return false;
        }
        pub fn pollGamepadEvents(out: []root.GamepadEvent) usize {
            if (out.len == 0) return 0;
            out[0] = root.GamepadEvent.connected(0, "Fake Pad");
            return 1;
        }
        pub fn describeGamepads(out: []root.GamepadDescription) usize {
            if (out.len == 0) return 0;
            out[0] = .{ .slot = 0, .connected = true };
            return 1;
        }
    };
    const I = InputInterface(FakeBackend);
    var evbuf: [4]root.GamepadEvent = undefined;
    try testing.expectEqual(@as(usize, 1), I.pollGamepadEvents(&evbuf));
    try testing.expectEqualStrings("Fake Pad", evbuf[0].nameSlice());
    try testing.expectEqual(@as(u32, 0), evbuf[0].id());
    var dbuf: [4]root.GamepadDescription = undefined;
    try testing.expectEqual(@as(usize, 1), I.describeGamepads(&dbuf));
}

test "gamepad_source: selected platform drains 0 events by default" {
    var evbuf: [8]root.GamepadEvent = undefined;
    root.gamepad_source.init();
    defer root.gamepad_source.deinit();
    try testing.expectEqual(@as(usize, 0), root.gamepad_source.pollEvents(&evbuf));
}

// ── Render backend contract (relocated from labelle-gfx, labelle-assembler#387) ──

const Backend = root.Backend;
const MockBackend = root.MockBackend;
const missingBackendDecls = root.missingBackendDecls;

test "assertWindow: required core accepted; loop vs callback capability-gated" {
    // The reference stub satisfies the required core → no missing decls.
    try testing.expectEqual(@as(usize, 0), comptime root.missingWindowDecls(root.StubWindow).len);

    // StubWindow declares no shouldQuit → it's a callback-model window; the
    // interface still instantiates and ownsLoop()/canScreenshot() report false.
    const CallbackW = root.Window(root.StubWindow);
    try testing.expect(!CallbackW.ownsLoop());
    try testing.expect(!CallbackW.canScreenshot());
    try testing.expect(!CallbackW.shouldQuit()); // fallback: keep running
    // StubWindow declares neither surface-loss hook → probe false + no-op safe.
    try testing.expect(!CallbackW.supportsSurfaceLoss());
    CallbackW.surfaceLost();
    CallbackW.surfaceRestored();

    // A loop-model window adds shouldQuit + a screenshot path → capabilities flip.
    const LoopW = struct {
        pub fn width() i32 {
            return 0;
        }
        pub fn height() i32 {
            return 0;
        }
        pub fn frameDuration() f64 {
            return 0;
        }
        pub fn requestQuit() void {}
        pub fn shouldQuit() bool {
            return true;
        }
        pub fn takeScreenshot(_: [:0]const u8) void {}
    };
    const W = root.Window(LoopW);
    try testing.expect(W.ownsLoop());
    try testing.expect(W.canScreenshot());
    try testing.expect(W.shouldQuit());
    // LoopW declares neither surface-loss hook → probe false.
    try testing.expect(!W.supportsSurfaceLoss());

    // Missing a required core decl (frameDuration) → reported, not silent.
    const Incomplete = struct {
        pub fn width() i32 {
            return 0;
        }
        pub fn height() i32 {
            return 0;
        }
        pub fn requestQuit() void {}
    };
    const missing = comptime root.missingWindowDecls(Incomplete);
    try testing.expect(missing.len > 0);
    var saw_fd = false;
    inline for (missing) |name| {
        if (std.mem.eql(u8, name, "frameDuration")) saw_fd = true;
    }
    try testing.expect(saw_fd);
}

// A window backend that declares BOTH surface-loss hooks, mutating file-local
// counters so the positive dispatch path is observable. Mirrors the `LoopW`
// habit above rather than adding optionals to StubWindow.
var lossy_lost_calls: u32 = 0;
var lossy_restored_calls: u32 = 0;
const LossyWindow = struct {
    pub fn width() i32 {
        return 0;
    }
    pub fn height() i32 {
        return 0;
    }
    pub fn frameDuration() f64 {
        return 0;
    }
    pub fn requestQuit() void {}
    pub fn surfaceLost() void {
        lossy_lost_calls += 1;
    }
    pub fn surfaceRestored() void {
        lossy_restored_calls += 1;
    }
};

test "window: surface-loss hooks dispatch when both are declared" {
    try testing.expectEqual(@as(usize, 0), comptime root.missingWindowDecls(LossyWindow).len);
    const W = root.Window(LossyWindow);
    try testing.expect(W.supportsSurfaceLoss());

    lossy_lost_calls = 0;
    lossy_restored_calls = 0;
    W.surfaceLost();
    W.surfaceRestored();
    try testing.expectEqual(@as(u32, 1), lossy_lost_calls);
    try testing.expectEqual(@as(u32, 1), lossy_restored_calls);
}

test "window: half a surface-loss pair is a contract violation" {
    // Declares surfaceLost only — the required core is satisfied, but the
    // unpaired half must be surfaced as a missing decl (Window() would fail
    // assertWindow at comptime; missingWindowDecls reports it directly).
    const HalfLossy = struct {
        pub fn width() i32 {
            return 0;
        }
        pub fn height() i32 {
            return 0;
        }
        pub fn frameDuration() f64 {
            return 0;
        }
        pub fn requestQuit() void {}
        pub fn surfaceLost() void {}
    };
    const missing = comptime root.missingWindowDecls(HalfLossy);
    try testing.expect(missing.len > 0);
    var saw_pair = false;
    inline for (missing) |name| {
        if (std.mem.eql(u8, name, "surfaceLost+surfaceRestored (must define both or neither)")) saw_pair = true;
    }
    try testing.expect(saw_pair);
}

test "assertInput: complete impl accepted, incomplete impl reported" {
    // The reference stub satisfies the contract → no missing decls.
    try testing.expectEqual(@as(usize, 0), comptime root.missingInputDecls(root.StubInput).len);

    // Input is permissive: a keyboard-only impl (no mouse/touch/gamepad) still
    // satisfies the contract — those degrade via InputInterface's fallbacks.
    const KeyboardOnly = struct {
        pub fn isKeyDown(_: u32) bool {
            return false;
        }
        pub fn isKeyPressed(_: u32) bool {
            return false;
        }
    };
    try testing.expectEqual(@as(usize, 0), comptime root.missingInputDecls(KeyboardOnly).len);
    // And it instantiates through the interface (assertInput passes).
    _ = root.InputInterface(KeyboardOnly);

    // Missing a required decl (isKeyPressed) → reported, not silent.
    const Incomplete = struct {
        pub fn isKeyDown(_: u32) bool {
            return false;
        }
    };
    const missing = comptime root.missingInputDecls(Incomplete);
    try testing.expect(missing.len > 0);
    var saw_pressed = false;
    inline for (missing) |name| {
        if (std.mem.eql(u8, name, "isKeyPressed")) saw_pressed = true;
    }
    try testing.expect(saw_pressed);
}

test "assertAudio: complete impl accepted, incomplete impl reported" {
    // The reference stub satisfies the contract → no missing decls.
    try testing.expectEqual(@as(usize, 0), comptime root.missingAudioDecls(root.StubAudio).len);

    // Audio is permissive: a required-only impl (no loader/music/global) still
    // satisfies the contract — those degrade via AudioInterface's fallbacks.
    const MinimalAudio = struct {
        pub fn playSound(_: u32) void {}
        pub fn stopSound(_: u32) void {}
    };
    try testing.expectEqual(@as(usize, 0), comptime root.missingAudioDecls(MinimalAudio).len);
    // And it instantiates through the interface (assertAudio passes).
    _ = root.AudioInterface(MinimalAudio);

    // Missing a required decl (stopSound) → reported, not silent.
    const Incomplete = struct {
        pub fn playSound(_: u32) void {}
    };
    const missing = comptime root.missingAudioDecls(Incomplete);
    try testing.expect(missing.len > 0);
    var saw_stop = false;
    inline for (missing) |name| {
        if (std.mem.eql(u8, name, "stopSound")) saw_stop = true;
    }
    try testing.expect(saw_stop);
}

test "audio sub-surface split: playback/loader arrays are disjoint and total" {
    @setEvalBranchQuota(10000); // nested comptime membership + audioSubSurfaceOf walks

    // No decl appears in both sub-surfaces (disjoint).
    inline for (root.audio_playback_decls) |p| {
        inline for (root.audio_loader_decls) |l| {
            try testing.expect(!std.mem.eql(u8, p, l));
        }
    }

    // Spot-check the classifier.
    try testing.expectEqual(root.AudioSubSurface.playback, comptime root.audioSubSurfaceOf("playSound"));
    try testing.expectEqual(root.AudioSubSurface.loader, comptime root.audioSubSurfaceOf("loadSound"));
    try testing.expectEqual(root.AudioSubSurface.playback, comptime root.audioSubSurfaceOf("update"));
    try testing.expectEqual(root.AudioSubSurface.loader, comptime root.audioSubSurfaceOf("unloadMusic"));

    // Every array member classifies back to its own array.
    inline for (root.audio_playback_decls) |name| {
        try testing.expectEqual(root.AudioSubSurface.playback, comptime root.audioSubSurfaceOf(name));
    }
    inline for (root.audio_loader_decls) |name| {
        try testing.expectEqual(root.AudioSubSurface.loader, comptime root.audioSubSurfaceOf(name));
    }

    // Every required decl is a playback decl (both required decls drive
    // already-loaded ids). required_audio_decls ⊂ audio_playback_decls.
    inline for (root.required_audio_decls) |req| {
        var found = false;
        inline for (root.audio_playback_decls) |p| {
            if (std.mem.eql(u8, req, p)) found = true;
        }
        try testing.expect(found);
    }
}

test "required_audio_decls is frozen order (byte-identical diagnostics)" {
    // assertAudio walks this array, so its compile-error text is stable only if
    // this order never drifts. Freeze the exact sequence.
    const expected = [_][]const u8{ "playSound", "stopSound" };
    try testing.expectEqual(expected.len, root.required_audio_decls.len);
    inline for (expected, 0..) |name, i| {
        try testing.expectEqualStrings(name, root.required_audio_decls[i]);
    }
}

test "assertBackend: complete impl accepted, incomplete impl reported" {
    // The reference impl satisfies the contract → no missing decls.
    try testing.expectEqual(@as(usize, 0), comptime missingBackendDecls(MockBackend).len);

    // A deliberately-incomplete impl (only one type decl) → reported, not silent.
    const Incomplete = struct {
        pub const Texture = struct {};
    };
    const missing = comptime missingBackendDecls(Incomplete);
    try testing.expect(missing.len > 0);
    // Texture is present; Color (a required type) is among those reported.
    var saw_color = false;
    inline for (missing) |name| {
        if (std.mem.eql(u8, name, "Color")) saw_color = true;
    }
    try testing.expect(saw_color);
}

// ── Contract versioning (labelle-assembler#453) ─────────────────────────────
//
// FOUNDATION only: these assert the per-contract / per-sub-surface version
// constants exist, are reachable through the public API, and are `1`. The
// assembler-side `N == M` emit is a deferred follow-up (needs a core release +
// pin bump) and is intentionally NOT tested here.

test "contract versions: all constants are reachable and equal 1" {
    try testing.expectEqual(@as(u32, 1), root.DRAW_CONTRACT_VERSION);
    try testing.expectEqual(@as(u32, 1), root.LOADER_CONTRACT_VERSION);
    try testing.expectEqual(@as(u32, 1), root.BACKEND_CONTRACT_VERSION);
    try testing.expectEqual(@as(u32, 1), root.WINDOW_CONTRACT_VERSION);
    try testing.expectEqual(@as(u32, 1), root.INPUT_CONTRACT_VERSION);
    try testing.expectEqual(@as(u32, 1), root.AUDIO_PLAYBACK_CONTRACT_VERSION);
    try testing.expectEqual(@as(u32, 1), root.AUDIO_LOADER_CONTRACT_VERSION);

    // Types are u32 (a comptime_int would silently coerce elsewhere).
    try testing.expectEqual(u32, @TypeOf(root.BACKEND_CONTRACT_VERSION));
}

test "render sub-surface split: draw_fn_decls + loader_fn_decls partition required_fn_decls" {
    @setEvalBranchQuota(10000); // nested comptime membership + subSurfaceOf walks
    // The two sub-surfaces partition the aggregate as a SET — same count, no
    // overlap, and every aggregate decl lands in exactly one sub-surface.
    // (Positional equality is NOT asserted: required_fn_decls preserves the
    // ORIGINAL flat order, in which the loader decls are interleaved between
    // the draw decls, not appended — see the golden-order test below.)
    try testing.expectEqual(
        root.draw_fn_decls.len + root.loader_fn_decls.len,
        root.required_fn_decls.len,
    );

    // No decl appears in both sub-surfaces (disjoint).
    inline for (root.draw_fn_decls) |d| {
        inline for (root.loader_fn_decls) |l| {
            try testing.expect(!std.mem.eql(u8, d, l));
        }
    }

    // Every sub-surface decl classifies back to that sub-surface and is a
    // member of the aggregate.
    inline for (root.draw_fn_decls) |name| {
        try testing.expectEqual(root.RenderSubSurface.draw, comptime root.subSurfaceOf(name));
        var found = false;
        inline for (root.required_fn_decls) |agg| {
            if (std.mem.eql(u8, name, agg)) found = true;
        }
        try testing.expect(found);
    }
    inline for (root.loader_fn_decls) |name| {
        try testing.expectEqual(root.RenderSubSurface.loader, comptime root.subSurfaceOf(name));
        var found = false;
        inline for (root.required_fn_decls) |agg| {
            if (std.mem.eql(u8, name, agg)) found = true;
        }
        try testing.expect(found);
    }

    // And every aggregate decl classifies as draw OR loader (total, no stray).
    inline for (root.required_fn_decls) |name| {
        const ss = comptime root.subSurfaceOf(name);
        try testing.expect(ss == .draw or ss == .loader);
    }
}

test "required_fn_decls preserves the original flat order (byte-identical diagnostics)" {
    // The aggregate order is load-bearing: `missingBackendDecls` walks it, so
    // `assertBackend`'s compile-error text is byte-identical to the pre-split
    // implementation only if this order never drifts. The loader decls
    // (loadTexture/decodeImage/uploadTexture/unloadTexture) MUST sit between
    // `drawText` and `beginMode2D`. Freezing the exact sequence here makes any
    // reordering (e.g. a `draw_fn_decls ++ loader_fn_decls` regression that
    // tails the loader decls) a loud, obvious test failure.
    const expected = [_][]const u8{
        "drawTexturePro", "drawRectangleRec", "drawCircle",      "drawTriangle",
        "drawPolygon",    "drawLine",         "drawText",        "loadTexture",
        "decodeImage",    "uploadTexture",    "unloadTexture",   "beginMode2D",
        "endMode2D",      "getScreenWidth",   "getScreenHeight", "screenToWorld",
        "worldToScreen",  "setDesignSize",
    };
    try testing.expectEqual(expected.len, root.required_fn_decls.len);
    inline for (expected, 0..) |name, i| {
        try testing.expect(std.mem.eql(u8, name, root.required_fn_decls[i]));
    }
}

test "missingBackendDeclsBySubSurface: classifies a missing draw decl vs a missing loader decl" {
    // A deliberately-incomplete impl: has every required decl EXCEPT one draw
    // decl (drawTriangle) and one loader decl (decodeImage). The tagged report
    // must place each under the right sub-surface.
    // Local color type under an unambiguous name (the file already has a
    // file-level `const Color`, so a container decl named `Color` cannot be
    // *referenced* by that bare name inside the struct — alias it instead).
    const RGBA = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };
    const Incomplete = struct {
        // Required types.
        pub const Texture = struct {};
        pub const Color = RGBA;
        pub const Rectangle = struct {};
        pub const Vector2 = struct {};
        pub const Camera2D = struct {};
        // Required color constants.
        pub const white: RGBA = .{};
        pub const black: RGBA = .{};
        pub const red: RGBA = .{};
        pub const green: RGBA = .{};
        pub const blue: RGBA = .{};
        pub const transparent: RGBA = .{};
        // Draw decls — drawTriangle intentionally OMITTED.
        pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: RGBA) void {}
        pub fn drawRectangleRec(_: Rectangle, _: RGBA) void {}
        pub fn drawCircle(_: f32, _: f32, _: f32, _: RGBA) void {}
        pub fn drawPolygon(_: []const Vector2, _: RGBA) void {}
        pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: RGBA) void {}
        pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: RGBA) void {}
        pub fn beginMode2D(_: Camera2D) void {}
        pub fn endMode2D() void {}
        pub fn getScreenWidth() i32 {
            return 0;
        }
        pub fn getScreenHeight() i32 {
            return 0;
        }
        pub fn screenToWorld(p: Vector2, _: Camera2D) Vector2 {
            return p;
        }
        pub fn worldToScreen(p: Vector2, _: Camera2D) Vector2 {
            return p;
        }
        pub fn setDesignSize(_: i32, _: i32) void {}
        // Loader decls — decodeImage intentionally OMITTED.
        pub fn loadTexture(_: [:0]const u8) !Texture {
            return .{};
        }
        pub fn uploadTexture(_: root.DecodedImage) !Texture {
            return .{};
        }
        pub fn unloadTexture(_: Texture) void {}
    };

    const missing = comptime root.missingBackendDeclsBySubSurface(Incomplete);
    // Exactly the two we omitted are missing.
    try testing.expectEqual(@as(usize, 2), missing.len);

    var draw_ss: ?root.RenderSubSurface = null;
    var loader_ss: ?root.RenderSubSurface = null;
    inline for (missing) |m| {
        if (std.mem.eql(u8, m.name, "drawTriangle")) draw_ss = m.sub_surface;
        if (std.mem.eql(u8, m.name, "decodeImage")) loader_ss = m.sub_surface;
    }
    try testing.expectEqual(root.RenderSubSurface.draw, draw_ss.?);
    try testing.expectEqual(root.RenderSubSurface.loader, loader_ss.?);

    // Aggregate view is unchanged (same names, order-preserving: draw before loader).
    const flat = comptime root.missingBackendDecls(Incomplete);
    try testing.expectEqual(@as(usize, 2), flat.len);
    try testing.expect(std.mem.eql(u8, flat[0], "drawTriangle"));
    try testing.expect(std.mem.eql(u8, flat[1], "decodeImage"));

    // subSurfaceOf classifies known decls directly.
    try testing.expectEqual(root.RenderSubSurface.type, comptime root.subSurfaceOf("Texture"));
    try testing.expectEqual(root.RenderSubSurface.color, comptime root.subSurfaceOf("white"));
    try testing.expectEqual(root.RenderSubSurface.draw, comptime root.subSurfaceOf("drawTexturePro"));
    try testing.expectEqual(root.RenderSubSurface.loader, comptime root.subSurfaceOf("uploadTexture"));
}

test "Backend: loadTextureFromMemory diverts compressed blobs past the CPU decoder" {
    // #341: a backend exposing isCompressed/uploadCompressed gets compressed
    // blobs uploaded as-is; everything else takes the decode path unchanged.
    const B = Backend(MockBackend);

    // Sentinel-"MOCK" blob → uploadCompressed (sentinel 4096×4096), no decode.
    const compressed = try B.loadTextureFromMemory("astc", "MOCK\x00\x00\x00\x00payload");
    try testing.expectEqual(@as(i32, 4096), compressed.width);

    // Ordinary blob → decodeImage + uploadTexture (the 1×1 mock stub).
    const decoded = try B.loadTextureFromMemory("png", "ordinary-non-compressed-bytes");
    try testing.expectEqual(@as(i32, 1), decoded.width);
}

test "Backend: compressedDims reads dims from a compressed blob without decoding" {
    // The async catalog adapter probes header dims via the namespace-level
    // wrapper; the named CompressedDims type unifies the backend's anonymous result.
    const B = Backend(MockBackend);

    // Sentinel-"MOCK" blob → mock reports its sentinel 4096×4096 dims.
    const dims = B.compressedDims("MOCK\x00\x00\x00\x00payload");
    try testing.expect(dims != null);
    try testing.expectEqual(@as(u32, 4096), dims.?.width);
    try testing.expectEqual(@as(u32, 4096), dims.?.height);
    try testing.expectEqual(B.CompressedDims, @TypeOf(dims.?));

    // Non-compressed blob → null (no dims to read without decoding).
    try testing.expectEqual(@as(?B.CompressedDims, null), B.compressedDims("ordinary-bytes"));
}

test "Backend: drawMesh optional primitive records via the mock backend" {
    // labelle-gfx#290: the textured-mesh primitive (Spine enabler). The mock
    // opts in by declaring `drawMesh`, so the wrapper forwards and the mock
    // records the texture, vertex/index counts, and blend mode.
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    const B = Backend(MockBackend);

    const tex = try B.loadTexture("atlas.png");

    // A textured quad: 4 verts (xy pairs), 6 indices (two triangles).
    const positions = [_]f32{ 0, 0, 32, 0, 32, 32, 0, 32 };
    const uvs = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 1 };
    const colors = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF };
    const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };
    B.drawMesh(tex, &positions, &uvs, &colors, &indices, .additive);

    const meshes = MockBackend.getMeshCalls();
    try testing.expectEqual(@as(usize, 1), meshes.len);
    try testing.expectEqual(@as(usize, 1), MockBackend.getMeshCallCount());
    try testing.expectEqual(tex.id, meshes[0].texture_id);
    try testing.expectEqual(@as(usize, 4), meshes[0].vertex_count);
    try testing.expectEqual(@as(usize, 6), meshes[0].index_count);
    try testing.expectEqual(MockBackend.BlendMode.additive, meshes[0].blend);
    try testing.expectEqual(root.BlendMode.additive, meshes[0].blend);
}

test "Backend: drawMesh is a no-op (non-breaking) on a backend lacking it" {
    // A backend that satisfies the required render surface but does NOT declare
    // `drawMesh` still instantiates through `Backend(Impl)`, and the wrapper
    // compiles to a no-op call — proving the optional primitive is non-breaking
    // for the four backends that don't implement it yet.
    const NoMesh = struct {
        pub const Texture = struct { id: u32 };
        pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
        pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };
        pub const Vector2 = struct { x: f32, y: f32 };
        pub const Camera2D = struct { zoom: f32 = 1 };
        const C = @This().Color;

        pub const white = C{ .r = 255, .g = 255, .b = 255, .a = 255 };
        pub const black = C{ .r = 0, .g = 0, .b = 0, .a = 255 };
        pub const red = C{ .r = 255, .g = 0, .b = 0, .a = 255 };
        pub const green = C{ .r = 0, .g = 255, .b = 0, .a = 255 };
        pub const blue = C{ .r = 0, .g = 0, .b = 255, .a = 255 };
        pub const transparent = C{ .r = 0, .g = 0, .b = 0, .a = 0 };

        pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: C) void {}
        pub fn drawRectangleRec(_: Rectangle, _: C) void {}
        pub fn drawCircle(_: f32, _: f32, _: f32, _: C) void {}
        pub fn drawTriangle(_: Vector2, _: Vector2, _: Vector2, _: C) void {}
        pub fn drawPolygon(_: []const Vector2, _: C) void {}
        pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: C) void {}
        pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: C) void {}
        pub fn loadTexture(_: [:0]const u8) !Texture {
            return .{ .id = 1 };
        }
        pub fn decodeImage(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) !root.DecodedImage {
            const pixels = try allocator.alloc(u8, 4);
            @memset(pixels, 0);
            return .{ .pixels = pixels, .width = 1, .height = 1 };
        }
        pub fn uploadTexture(_: root.DecodedImage) !Texture {
            return .{ .id = 2 };
        }
        pub fn unloadTexture(_: Texture) void {}
        pub fn beginMode2D(_: Camera2D) void {}
        pub fn endMode2D() void {}
        pub fn getScreenWidth() i32 {
            return 640;
        }
        pub fn getScreenHeight() i32 {
            return 480;
        }
        pub fn screenToWorld(pos: Vector2, _: Camera2D) Vector2 {
            return pos;
        }
        pub fn worldToScreen(pos: Vector2, _: Camera2D) Vector2 {
            return pos;
        }
        pub fn setDesignSize(_: i32, _: i32) void {}
    };

    // No drawMesh decl → the contract still accepts the backend (optional).
    try testing.expect(!@hasDecl(NoMesh, "drawMesh"));
    try testing.expectEqual(@as(usize, 0), comptime missingBackendDecls(NoMesh).len);

    const B = Backend(NoMesh);
    const tex = try B.loadTexture("x.png");
    const positions = [_]f32{ 0, 0, 1, 0, 1, 1 };
    const uvs = [_]f32{ 0, 0, 1, 0, 1, 1 };
    const colors = [_]u32{ 0, 0, 0 };
    const indices = [_]u16{ 0, 1, 2 };
    // Compiles and is a no-op (the @hasDecl gate elides the forward).
    B.drawMesh(tex, &positions, &uvs, &colors, &indices, .multiply);
}

test "Backend: drawTextureProMaterial forwards a supported effect to the mock backend" {
    // labelle-gfx#305: the per-draw material seam. The mock opts in by declaring
    // `drawTextureProMaterial` + `materialSupported`; a supported effect
    // (`flash`) forwards the exact effect + uniforms and records a MaterialCall.
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    const B = Backend(MockBackend);

    const tex = try B.loadTexture("atlas.png");
    const rect = MockBackend.Rectangle{ .x = 1, .y = 2, .width = 3, .height = 4 };
    const origin = MockBackend.Vector2{ .x = 0, .y = 0 };
    const material = root.Material{
        .effect = .flash,
        .uniforms = .{ .r = 1, .g = 0.5, .b = 0.25, .a = 1, .scalar0 = 0.75 },
    };
    B.drawTextureProMaterial(tex, rect, rect, origin, 0, B.white, material);

    // Went through the material path, not the plain drawTexturePro path.
    try testing.expectEqual(@as(usize, 1), MockBackend.getMaterialCallCount());
    try testing.expectEqual(@as(usize, 0), MockBackend.getDrawCallCount());
    const calls = MockBackend.getMaterialCalls();
    try testing.expectEqual(tex.id, calls[0].texture_id);
    try testing.expectEqual(root.MaterialEffect.flash, calls[0].material.effect);
    try testing.expectEqual(@as(f32, 0.75), calls[0].material.uniforms.scalar0);
    try testing.expectEqual(@as(f32, 0.5), calls[0].material.uniforms.g);
}

test "Backend: drawTextureProMaterial degrades an unsupported effect to a plain sprite" {
    // The mock declines `outline`, so `materialSupported(.outline) == false` and
    // the wrapper falls back to `drawTexturePro` — the sprite still draws (no
    // MaterialCall), a quality degradation, not a contract violation.
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    const B = Backend(MockBackend);

    try testing.expect(!B.materialSupported(.outline));
    try testing.expect(B.materialSupported(.flash));
    try testing.expect(B.materialSupported(.palette_swap));
    try testing.expect(!B.materialSupported(.none)); // never a material effect

    const tex = try B.loadTexture("atlas.png");
    const rect = MockBackend.Rectangle{ .x = 0, .y = 0, .width = 8, .height = 8 };
    const origin = MockBackend.Vector2{ .x = 0, .y = 0 };
    B.drawTextureProMaterial(tex, rect, rect, origin, 0, B.white, .{ .effect = .outline });

    try testing.expectEqual(@as(usize, 0), MockBackend.getMaterialCallCount());
    try testing.expectEqual(@as(usize, 1), MockBackend.getDrawCallCount());
}

test "Backend: a `.none` material always takes the plain draw path" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    const B = Backend(MockBackend);

    const tex = try B.loadTexture("atlas.png");
    const rect = MockBackend.Rectangle{ .x = 0, .y = 0, .width = 8, .height = 8 };
    const origin = MockBackend.Vector2{ .x = 0, .y = 0 };
    B.drawTextureProMaterial(tex, rect, rect, origin, 0, B.white, .{}); // .none default

    try testing.expectEqual(@as(usize, 0), MockBackend.getMaterialCallCount());
    try testing.expectEqual(@as(usize, 1), MockBackend.getDrawCallCount());
}

test "materialCapabilities: reports the mock's advertised effects; empty for a materialless backend" {
    // The mock advertises exactly flash + palette_swap (order = MaterialEffect
    // enum order, minus `none`).
    const caps = comptime root.materialCapabilities(MockBackend);
    try testing.expectEqual(@as(usize, 2), caps.effects.len);
    try testing.expectEqual(root.MaterialEffect.palette_swap, caps.effects[0]);
    try testing.expectEqual(root.MaterialEffect.flash, caps.effects[1]);

    // A backend without `drawTextureProMaterial` advertises nothing, and the
    // wrapper compiles to a pure `drawTexturePro` degrade (zero cost).
    const NoMaterial = struct {
        pub const Texture = struct { id: u32 };
        pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
        pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };
        pub const Vector2 = struct { x: f32, y: f32 };
        pub const Camera2D = struct { zoom: f32 = 1 };
        const C = @This().Color;

        pub const white = C{ .r = 255, .g = 255, .b = 255, .a = 255 };
        pub const black = C{ .r = 0, .g = 0, .b = 0, .a = 255 };
        pub const red = C{ .r = 255, .g = 0, .b = 0, .a = 255 };
        pub const green = C{ .r = 0, .g = 255, .b = 0, .a = 255 };
        pub const blue = C{ .r = 0, .g = 0, .b = 255, .a = 255 };
        pub const transparent = C{ .r = 0, .g = 0, .b = 0, .a = 0 };

        var draws: usize = 0;

        pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: C) void {
            draws += 1;
        }
        pub fn drawRectangleRec(_: Rectangle, _: C) void {}
        pub fn drawCircle(_: f32, _: f32, _: f32, _: C) void {}
        pub fn drawTriangle(_: Vector2, _: Vector2, _: Vector2, _: C) void {}
        pub fn drawPolygon(_: []const Vector2, _: C) void {}
        pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: C) void {}
        pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: C) void {}
        pub fn loadTexture(_: [:0]const u8) !Texture {
            return .{ .id = 1 };
        }
        pub fn decodeImage(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) !root.DecodedImage {
            const pixels = try allocator.alloc(u8, 4);
            @memset(pixels, 0);
            return .{ .pixels = pixels, .width = 1, .height = 1 };
        }
        pub fn uploadTexture(_: root.DecodedImage) !Texture {
            return .{ .id = 2 };
        }
        pub fn unloadTexture(_: Texture) void {}
        pub fn beginMode2D(_: Camera2D) void {}
        pub fn endMode2D() void {}
        pub fn getScreenWidth() i32 {
            return 640;
        }
        pub fn getScreenHeight() i32 {
            return 480;
        }
        pub fn screenToWorld(pos: Vector2, _: Camera2D) Vector2 {
            return pos;
        }
        pub fn worldToScreen(pos: Vector2, _: Camera2D) Vector2 {
            return pos;
        }
        pub fn setDesignSize(_: i32, _: i32) void {}
    };

    // No material decl → still a valid backend (optional), empty capabilities,
    // and `materialSupported` is false for every effect.
    try testing.expect(!@hasDecl(NoMaterial, "drawTextureProMaterial"));
    try testing.expectEqual(@as(usize, 0), comptime missingBackendDecls(NoMaterial).len);
    const empty = comptime root.materialCapabilities(NoMaterial);
    try testing.expectEqual(@as(usize, 0), empty.effects.len);

    const B = Backend(NoMaterial);
    try testing.expect(!B.materialSupported(.flash));
    const tex = try B.loadTexture("x.png");
    const rect = NoMaterial.Rectangle{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const origin = NoMaterial.Vector2{ .x = 0, .y = 0 };
    // Every material degrades to a plain draw; compiles + runs at zero cost.
    B.drawTextureProMaterial(tex, rect, rect, origin, 0, B.white, .{ .effect = .flash });
    try testing.expectEqual(@as(usize, 1), NoMaterial.draws);
}

// ── Render-target sub-surface + post-fx seam (labelle-gfx#305, RFC §2) ───────

/// A backend satisfying ONLY the required render contract — no material, no
/// render-target sub-surface, no post-fx. Proves the optional seams degrade to
/// zero-cost no-ops on a backend that opts into none of them.
const MinimalBackend = struct {
    pub const Texture = struct { id: u32 };
    pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
    pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };
    pub const Vector2 = struct { x: f32, y: f32 };
    pub const Camera2D = struct { zoom: f32 = 1 };
    const C = @This().Color;

    pub const white = C{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = C{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const red = C{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green = C{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue = C{ .r = 0, .g = 0, .b = 255, .a = 255 };
    pub const transparent = C{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: C) void {}
    pub fn drawRectangleRec(_: Rectangle, _: C) void {}
    pub fn drawCircle(_: f32, _: f32, _: f32, _: C) void {}
    pub fn drawTriangle(_: Vector2, _: Vector2, _: Vector2, _: C) void {}
    pub fn drawPolygon(_: []const Vector2, _: C) void {}
    pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: C) void {}
    pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: C) void {}
    pub fn loadTexture(_: [:0]const u8) !Texture {
        return .{ .id = 1 };
    }
    pub fn decodeImage(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) !root.DecodedImage {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0);
        return .{ .pixels = pixels, .width = 1, .height = 1 };
    }
    pub fn uploadTexture(_: root.DecodedImage) !Texture {
        return .{ .id = 2 };
    }
    pub fn unloadTexture(_: Texture) void {}
    pub fn beginMode2D(_: Camera2D) void {}
    pub fn endMode2D() void {}
    pub fn getScreenWidth() i32 {
        return 640;
    }
    pub fn getScreenHeight() i32 {
        return 480;
    }
    pub fn screenToWorld(pos: Vector2, _: Camera2D) Vector2 {
        return pos;
    }
    pub fn worldToScreen(pos: Vector2, _: Camera2D) Vector2 {
        return pos;
    }
    pub fn setDesignSize(_: i32, _: i32) void {}
};

test "render-target sub-surface: mock implements all five; a materialless backend implements none" {
    // The mock declares the whole sub-surface → `hasRenderTargetSubSurface`
    // true and the post-fx driver has a target to ping-pong on.
    try testing.expect(comptime backend_contract.hasRenderTargetSubSurface(MockBackend));
    // Both "all five" and "none" are CONSISTENT → no optional-consistency error.
    try testing.expectEqual(@as(usize, 0), comptime backend_contract.missingRenderTargetDecls(MockBackend).len);

    // A backend with none of the five is also consistent (it simply has no
    // post-fx — a fully-absent sub-surface is not a violation).
    const NoTargets = MinimalBackend;
    try testing.expect(!comptime backend_contract.hasRenderTargetSubSurface(NoTargets));
    try testing.expectEqual(@as(usize, 0), comptime backend_contract.missingRenderTargetDecls(NoTargets).len);
    // Still a valid backend — the sub-surface is optional, out of `assertBackend`.
    try testing.expectEqual(@as(usize, 0), comptime missingBackendDecls(NoTargets).len);
}

test "render-target sub-surface: a PARTIAL implementation is an optional-consistency error" {
    // A backend that declares some-but-not-all five can't composite — surface it
    // as an optional-consistency error (the "all five or none" rule), tagged
    // `.render_target`, WITHOUT failing `assertBackend`.
    // `missingRenderTargetDecls`/`missingBackendDecls` both classify purely by
    // `@hasDecl`, so the fixture only needs the two RT decls it declares.
    const PartialTargets = struct {
        // Declares create + begin but NOT end/draw/destroy.
        pub fn createRenderTarget(_: u16, _: u16) u32 {
            return 1;
        }
        pub fn beginRenderTarget(_: u32) void {}
    };
    const missing = comptime backend_contract.missingRenderTargetDecls(PartialTargets);
    try testing.expectEqual(@as(usize, 3), missing.len);
    for (missing) |m| try testing.expectEqual(backend_contract.RenderSubSurface.render_target, m.sub_surface);
    try testing.expect(!comptime backend_contract.hasRenderTargetSubSurface(PartialTargets));
}

test "Backend.applyPostPass forwards a supported pass and skips an unsupported one" {
    // labelle-gfx#305: the post-fx pass primitive. The mock advertises
    // bloom + vignette and declines color_grade + crt.
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    const B = Backend(MockBackend);

    try testing.expect(B.postPassSupported(.bloom));
    try testing.expect(B.postPassSupported(.vignette));
    try testing.expect(!B.postPassSupported(.color_grade));
    try testing.expect(!B.postPassSupported(.crt));

    const t_a = B.createRenderTarget(320, 240);
    const t_b = B.createRenderTarget(320, 240);
    try testing.expect(t_a != 0 and t_b != 0 and t_a != t_b);

    // A supported pass records; an unsupported pass is a silent no-op at the
    // wrapper level (the gfx DRIVER is what warn-once's + skips-without-advance).
    B.applyPostPass(.{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.8 } }, t_a, t_b);
    B.applyPostPass(.{ .kind = .crt }, t_b, t_a); // unsupported → no-op
    try testing.expectEqual(@as(usize, 1), MockBackend.getPostPassCallCount());
    const calls = MockBackend.getPostPassCalls();
    try testing.expectEqual(backend_contract.PostPassKind.bloom, calls[0].kind);
    try testing.expectEqual(t_a, calls[0].src);
    try testing.expectEqual(t_b, calls[0].dst);
}

test "postFxCapabilities: reports the mock's advertised passes; empty for a post-fx-less backend" {
    const caps = comptime backend_contract.postFxCapabilities(MockBackend);
    try testing.expectEqual(@as(usize, 2), caps.passes.len);
    try testing.expectEqual(backend_contract.PostPassKind.bloom, caps.passes[0]);
    try testing.expectEqual(backend_contract.PostPassKind.vignette, caps.passes[1]);

    // A backend without `applyPostPass` advertises nothing and `postPassSupported`
    // is false for every kind — the whole stack degrades at zero cost.
    const empty = comptime backend_contract.postFxCapabilities(MinimalBackend);
    try testing.expectEqual(@as(usize, 0), empty.passes.len);
    const B = Backend(MinimalBackend);
    try testing.expect(!B.postPassSupported(.bloom));
    try testing.expect(!B.hasRenderTargets());
    // The render-target wrappers compile + no-op on a backend without them.
    try testing.expectEqual(@as(u32, 0), B.createRenderTarget(1, 1));
    B.beginRenderTarget(0);
    B.applyPostPass(.{ .kind = .bloom }, 0, 0); // compiles, no-op
    B.endRenderTarget();
}

// ---------------------------------------------------------------------------
// Behavioral conformance suites (labelle-assembler#453).
//
// `root.conformance` provides per-contract behavioral suites parameterized over
// a backend `Impl`. These self-tests run each suite against the reference impls
// — the mock render backend, StubWindow, StubInput, StubAudio — which is the
// correctness proof for the suites themselves (a backend repo calls the exact
// same `try root.conformance.runXSuite(MyBackend)`).
// ---------------------------------------------------------------------------

const conformance = root.conformance;

test "conformance: render suite passes for the reference MockBackend" {
    // MockBackend advertises the compressed-texture AND font capabilities, so
    // this exercises the capability-gated branches (font atlas invariants,
    // compressed probes) on top of the always-on behavioral checks.
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();
    try conformance.runRenderSuite(MockBackend);
}

test "conformance: render suite passes for a minimal (no-capability) backend" {
    // A backend that satisfies only the required render surface — no font,
    // no compressed textures, no designToPhysical — must still pass. This
    // pins that the capability gates correctly SKIP the optional checks
    // (and that the designToPhysical identity fallback fires).
    const Minimal = struct {
        pub const Texture = struct { id: u32 };
        pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
        pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };
        pub const Vector2 = struct { x: f32, y: f32 };
        pub const Camera2D = struct { zoom: f32 = 1, ox: f32 = 0, oy: f32 = 0 };
        // @This().Color disambiguates from the file-scope `const Color = root.Color`.
        const C = @This().Color;

        pub const white = C{ .r = 255, .g = 255, .b = 255, .a = 255 };
        pub const black = C{ .r = 0, .g = 0, .b = 0, .a = 255 };
        pub const red = C{ .r = 255, .g = 0, .b = 0, .a = 255 };
        pub const green = C{ .r = 0, .g = 255, .b = 0, .a = 255 };
        pub const blue = C{ .r = 0, .g = 0, .b = 255, .a = 255 };
        pub const transparent = C{ .r = 0, .g = 0, .b = 0, .a = 0 };

        pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: C) void {}
        pub fn drawRectangleRec(_: Rectangle, _: C) void {}
        pub fn drawCircle(_: f32, _: f32, _: f32, _: C) void {}
        pub fn drawTriangle(_: Vector2, _: Vector2, _: Vector2, _: C) void {}
        pub fn drawPolygon(_: []const Vector2, _: C) void {}
        pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: C) void {}
        pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: C) void {}
        pub fn loadTexture(_: [:0]const u8) !Texture {
            return .{ .id = 1 };
        }
        pub fn decodeImage(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) !root.DecodedImage {
            const pixels = try allocator.alloc(u8, 2 * 3 * 4);
            @memset(pixels, 0);
            return .{ .pixels = pixels, .width = 2, .height = 3 };
        }
        pub fn uploadTexture(_: root.DecodedImage) !Texture {
            return .{ .id = 2 };
        }
        pub fn unloadTexture(_: Texture) void {}
        pub fn beginMode2D(_: Camera2D) void {}
        pub fn endMode2D() void {}
        pub fn getScreenWidth() i32 {
            return 640;
        }
        pub fn getScreenHeight() i32 {
            return 480;
        }
        pub fn screenToWorld(pos: Vector2, cam: Camera2D) Vector2 {
            return .{ .x = (pos.x - cam.ox) / cam.zoom, .y = (pos.y - cam.oy) / cam.zoom };
        }
        pub fn worldToScreen(pos: Vector2, cam: Camera2D) Vector2 {
            return .{ .x = pos.x * cam.zoom + cam.ox, .y = pos.y * cam.zoom + cam.oy };
        }
        pub fn setDesignSize(_: i32, _: i32) void {}
    };
    try conformance.runRenderSuite(Minimal);
}

test "conformance: partial font backend is rejected (all-or-nothing capability)" {
    // A backend that declares SOME font decls but not the full set is a
    // half-implemented surface. The render suite must FAIL it rather than treat
    // it as "not a font backend" and silently pass (the pre-fix behavior).
    const PartialFont = struct {
        pub const Texture = struct { id: u32 };
        pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
        pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };
        pub const Vector2 = struct { x: f32, y: f32 };
        pub const Camera2D = struct { zoom: f32 = 1 };
        const C = @This().Color;

        pub const white = C{ .r = 255, .g = 255, .b = 255, .a = 255 };
        pub const black = C{ .r = 0, .g = 0, .b = 0, .a = 255 };
        pub const red = C{ .r = 255, .g = 0, .b = 0, .a = 255 };
        pub const green = C{ .r = 0, .g = 255, .b = 0, .a = 255 };
        pub const blue = C{ .r = 0, .g = 0, .b = 255, .a = 255 };
        pub const transparent = C{ .r = 0, .g = 0, .b = 0, .a = 0 };

        pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: C) void {}
        pub fn drawRectangleRec(_: Rectangle, _: C) void {}
        pub fn drawCircle(_: f32, _: f32, _: f32, _: C) void {}
        pub fn drawTriangle(_: Vector2, _: Vector2, _: Vector2, _: C) void {}
        pub fn drawPolygon(_: []const Vector2, _: C) void {}
        pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: C) void {}
        pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: C) void {}
        pub fn loadTexture(_: [:0]const u8) !Texture {
            return .{ .id = 1 };
        }
        pub fn decodeImage(_: [:0]const u8, _: []const u8, allocator: std.mem.Allocator) !root.DecodedImage {
            const pixels = try allocator.alloc(u8, 4);
            @memset(pixels, 0);
            return .{ .pixels = pixels, .width = 1, .height = 1 };
        }
        pub fn uploadTexture(_: root.DecodedImage) !Texture {
            return .{ .id = 2 };
        }
        pub fn unloadTexture(_: Texture) void {}
        pub fn beginMode2D(_: Camera2D) void {}
        pub fn endMode2D() void {}
        pub fn getScreenWidth() i32 {
            return 640;
        }
        pub fn getScreenHeight() i32 {
            return 480;
        }
        pub fn screenToWorld(p: Vector2, _: Camera2D) Vector2 {
            return p;
        }
        pub fn worldToScreen(p: Vector2, _: Camera2D) Vector2 {
            return p;
        }
        pub fn setDesignSize(_: i32, _: i32) void {}

        // Partial font surface: declares decodeFont only — missing FontAtlas,
        // uploadFontAtlas, unloadFontAtlas.
        pub fn decodeFont(_: [:0]const u8, _: []const u8, _: root.FontBakeParams, _: std.mem.Allocator) !root.DecodedFont {
            return error.FontBackendNotImplemented;
        }
    };
    try testing.expectError(error.IncompleteFontCapability, conformance.runRenderSuite(PartialFont));
}

test "conformance: window suite passes for StubWindow (callback model)" {
    try conformance.runWindowSuite(root.StubWindow);
}

test "conformance: window suite passes for a loop-model window" {
    // Exercises the ownsLoop()/canScreenshot() == true branches.
    const LoopW = struct {
        pub fn width() i32 {
            return 800;
        }
        pub fn height() i32 {
            return 600;
        }
        pub fn frameDuration() f64 {
            return 0.016;
        }
        pub fn requestQuit() void {}
        pub fn shouldQuit() bool {
            return false;
        }
        pub fn isFullscreen() bool {
            return false;
        }
        pub fn setFullscreen(_: bool) void {}
        pub fn setVsync(_: bool) void {}
        pub fn takeScreenshot(_: [:0]const u8) void {}
    };
    try conformance.runWindowSuite(LoopW);
}

test "conformance: window suite passes for a surface-loss-capable window" {
    // Exercises the supportsSurfaceLoss() == true branch of the probe check.
    // The suite does NOT call the declared hooks (a real surfaceRestored needs
    // a live surface), so it only asserts the probe agrees with @hasDecl.
    try conformance.runWindowSuite(LossyWindow);
}

test "conformance: input suite passes for StubInput (keyboard-only fallbacks)" {
    // StubInput declares no gamepad hotplug decls, so this drives every
    // absent-capability fallback assertion in the input suite.
    try conformance.runInputSuite(root.StubInput);
}

test "conformance: input suite passes for a backend advertising gamepad hotplug" {
    // A backend WITH pollGamepadEvents/describeGamepads must satisfy the
    // buffer-bound safety invariant (empty buffer → 0; result <= capacity).
    const FullInput = struct {
        pub fn isKeyDown(_: u32) bool {
            return false;
        }
        pub fn isKeyPressed(_: u32) bool {
            return false;
        }
        pub fn pollGamepadEvents(out: []root.GamepadEvent) usize {
            if (out.len == 0) return 0;
            out[0] = root.GamepadEvent.connected(0, "Conformance Pad");
            return 1;
        }
        pub fn describeGamepads(out: []root.GamepadDescription) usize {
            if (out.len == 0) return 0;
            out[0] = .{ .slot = 0, .connected = true };
            return 1;
        }
    };
    try conformance.runInputSuite(FullInput);
}

test "conformance: audio suite passes for StubAudio" {
    try conformance.runAudioSuite(root.StubAudio);
}

test "conformance: audio suite passes for a minimal (required-only) audio backend" {
    // Only the required playSound/stopSound pair — every other method is
    // absent, so this drives the audio fallback assertions (loadSound → 0,
    // isSoundPlaying → false, etc.).
    const MinimalAudio = struct {
        pub fn playSound(_: u32) void {}
        pub fn stopSound(_: u32) void {}
    };
    try conformance.runAudioSuite(MinimalAudio);
}
