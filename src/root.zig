pub const coordinates = @import("coordinates.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const ecs = @import("ecs.zig");
pub const position = @import("position.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");
pub const gui = @import("gui.zig");
pub const gizmos = @import("gizmos.zig");
pub const render = @import("render.zig");
pub const hierarchy = @import("hierarchy.zig");

// Re-exports
pub const HookDispatcher = dispatcher.HookDispatcher;
pub const MergeHooks = dispatcher.MergeHooks;
pub const UnwrapReceiver = dispatcher.UnwrapReceiver;

pub const Ecs = ecs.Ecs;
pub const MockEcsBackend = ecs.MockEcsBackend;
pub const GenericQueryIterator = ecs.GenericQueryIterator;
pub const QueryResult = ecs.QueryResult;
pub const validateComponentTuple = ecs.validateComponentTuple;

pub const AudioInterface = audio.AudioInterface;
pub const StubAudio = audio.StubAudio;

pub const InputInterface = input.InputInterface;
pub const StubInput = input.StubInput;

pub const GuiInterface = gui.GuiInterface;
pub const StubGui = gui.StubGui;

pub const GizmoComponent = gizmos.GizmoComponent;
pub const GizmoDraw = gizmos.GizmoDraw;
pub const GizmoInterface = gizmos.GizmoInterface;
pub const GizmoVisibility = gizmos.GizmoVisibility;
pub const StubGizmos = gizmos.StubGizmos;

pub const RenderInterface = render.RenderInterface;
pub const StubRender = render.StubRender;
pub const VisualType = render.VisualType;

pub const ParentComponent = hierarchy.ParentComponent;
pub const ChildrenComponent = hierarchy.ChildrenComponent;

pub const Position = position.Position;
pub const PositionI = position.PositionI;

pub const CoordinateSystem = coordinates.CoordinateSystem;
pub const GamePosition = coordinates.GamePosition;
pub const ScreenPosition = coordinates.ScreenPosition;
pub const gameToScreen = coordinates.gameToScreen;
pub const screenToGame = coordinates.screenToGame;

/// Standard engine lifecycle events — parameterized by Entity type.
pub fn EngineHookPayload(comptime Entity: type) type {
    return union(enum) {
        entity_created: EntityInfo(Entity),
        entity_destroyed: EntityInfo(Entity),
        frame_start: FrameInfo,
        frame_end: FrameInfo,
    };
}

pub const FrameInfo = struct {
    dt: f32,
};

pub fn EntityInfo(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
    };
}

