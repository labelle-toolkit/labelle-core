const std = @import("std");
const testing = std.testing;
const root = @import("labelle-core");

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
