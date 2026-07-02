pub const coordinates = @import("coordinates.zig");
pub const dispatcher = @import("dispatcher.zig");
pub const ecs = @import("ecs.zig");
pub const position = @import("position.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");
pub const gui = @import("gui.zig");
pub const gizmos = @import("gizmos.zig");
pub const render = @import("render.zig");
// The render backend contract — the 8th comptime contract, relocated from
// labelle-gfx (labelle-assembler#387). gfx + engine now alias these types.
pub const backend_contract = @import("backend_contract.zig");
pub const window_contract = @import("window_contract.zig");
pub const mock_backend = @import("mock_backend.zig");
// Behavioral conformance suites (labelle-assembler#453). Parameterized over a
// backend Impl; asserts contract-level *behavior*, not just decl shape.
pub const conformance = @import("conformance.zig");
pub const video = @import("video.zig");
pub const hierarchy = @import("hierarchy.zig");
pub const prefab = @import("prefab.zig");
pub const log = @import("log.zig");
pub const typed_log = @import("typed_log.zig");
pub const save_policy = @import("save_policy.zig");
pub const serde = @import("serde.zig");
pub const flow = @import("flow.zig");
pub const gamepad = @import("gamepad.zig");
pub const gamepad_source = @import("gamepad_source/root.zig");
// Backend-agnostic Android JNI seam (labelle-core#310). A backend adapter
// registers its Android gamepad glue here at startup via
// `core.registerAndroidBackend(...)`; core's Android gamepad source routes
// through it instead of linking sokol's `sapp_*` symbols directly.
pub const android_backend = @import("android_backend.zig");

// Re-exports
pub const HookDispatcher = dispatcher.HookDispatcher;
pub const MergeHooks = dispatcher.MergeHooks;
pub const MergeHookPayloads = dispatcher.MergeHookPayloads;
pub const UnwrapReceiver = dispatcher.UnwrapReceiver;

pub const Ecs = ecs.Ecs;
pub const MockEcsBackend = ecs.MockEcsBackend;
pub const GenericQueryIterator = ecs.GenericQueryIterator;
pub const QueryResult = ecs.QueryResult;
pub const validateComponentTuple = ecs.validateComponentTuple;

pub const AudioInterface = audio.AudioInterface;
pub const StubAudio = audio.StubAudio;
pub const assertAudio = audio.assertAudio;
pub const missingAudioDecls = audio.missingAudioDecls;
pub const required_audio_decls = audio.required_audio_decls;
pub const AudioSubSurface = audio.AudioSubSurface;
pub const audioSubSurfaceOf = audio.audioSubSurfaceOf;
pub const audio_playback_decls = audio.audio_playback_decls;
pub const audio_loader_decls = audio.audio_loader_decls;
// Per-sub-surface contract versions (labelle-assembler#453). See the ABI-home
// files for what a bump means.
pub const AUDIO_PLAYBACK_CONTRACT_VERSION = audio.AUDIO_PLAYBACK_CONTRACT_VERSION;
pub const AUDIO_LOADER_CONTRACT_VERSION = audio.AUDIO_LOADER_CONTRACT_VERSION;

pub const InputInterface = input.InputInterface;
pub const StubInput = input.StubInput;
pub const assertInput = input.assertInput;
pub const missingInputDecls = input.missingInputDecls;
pub const required_input_decls = input.required_input_decls;
pub const INPUT_CONTRACT_VERSION = input.INPUT_CONTRACT_VERSION;

pub const Window = window_contract.Window;
pub const assertWindow = window_contract.assertWindow;
pub const missingWindowDecls = window_contract.missingWindowDecls;
pub const required_window_decls = window_contract.required_window_decls;
pub const StubWindow = window_contract.StubWindow;
pub const WINDOW_CONTRACT_VERSION = window_contract.WINDOW_CONTRACT_VERSION;

// Gamepad event contract (core#18) — COPY-only value types crossing the
// hotplug ring buffer, plus the per-OS source skeleton.
pub const GamepadEvent = gamepad.GamepadEvent;
pub const GamepadDescription = gamepad.GamepadDescription;
pub const GamepadSourceClass = gamepad.SourceClass;
pub const GamepadTypeHint = gamepad.TypeHint;
pub const GamepadUnavailableReason = gamepad.UnavailableReason;

// Android backend seam re-exports (core#310) so engine + backend adapters can
// call `core.registerAndroidBackend(ctx)` without reaching into the submodule.
pub const AndroidBackendContext = android_backend.AndroidBackendContext;
pub const registerAndroidBackend = android_backend.registerAndroidBackend;

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

// Render backend contract (relocated from labelle-gfx, labelle-assembler#387).
pub const Backend = backend_contract.Backend;
pub const assertBackend = backend_contract.assertBackend;
pub const missingBackendDecls = backend_contract.missingBackendDecls;
// Sub-surface-aware split + reporting (labelle-assembler#453).
pub const missingBackendDeclsBySubSurface = backend_contract.missingBackendDeclsBySubSurface;
pub const subSurfaceOf = backend_contract.subSurfaceOf;
pub const RenderSubSurface = backend_contract.RenderSubSurface;
pub const MissingDecl = backend_contract.MissingDecl;
pub const draw_fn_decls = backend_contract.draw_fn_decls;
pub const loader_fn_decls = backend_contract.loader_fn_decls;
pub const required_fn_decls = backend_contract.required_fn_decls;
// Render-contract versions: the two named sub-surfaces + the composite.
pub const DRAW_CONTRACT_VERSION = backend_contract.DRAW_CONTRACT_VERSION;
pub const LOADER_CONTRACT_VERSION = backend_contract.LOADER_CONTRACT_VERSION;
pub const BACKEND_CONTRACT_VERSION = backend_contract.BACKEND_CONTRACT_VERSION;
pub const DecodedImage = backend_contract.DecodedImage;
pub const DecodedFont = backend_contract.DecodedFont;
pub const FontBakeParams = backend_contract.FontBakeParams;
pub const CodepointRange = backend_contract.CodepointRange;
pub const Glyph = backend_contract.Glyph;
pub const CodepointEntry = backend_contract.CodepointEntry;
pub const KernPair = backend_contract.KernPair;
pub const MockBackend = mock_backend.MockBackend;

pub const VideoInterface = video.VideoInterface;
pub const StubVideo = video.StubVideo;
pub const VideoComponent = video.VideoComponent;
pub const VideoFit = video.VideoFit;

pub const LogLevel = log.LogLevel;
pub const LogSinkInterface = log.LogSinkInterface;
pub const StubLogSink = log.StubLogSink;
pub const StderrLogSink = log.StderrLogSink;

pub const LogEntry = typed_log.LogEntry;
pub const TypedLog = typed_log.TypedLog;

pub const SavePolicy = save_policy.SavePolicy;
pub const Saveable = save_policy.Saveable;
pub const SaveableOptions = save_policy.SaveableOptions;
pub const hasSavePolicy = save_policy.hasSavePolicy;
pub const getSavePolicy = save_policy.getSavePolicy;
pub const getEntityRefFields = save_policy.getEntityRefFields;
pub const getSkipFields = save_policy.getSkipFields;
pub const getRefArrayFields = save_policy.getRefArrayFields;
pub const getRemapExclude = save_policy.getRemapExclude;
pub const hasPostLoad = save_policy.hasPostLoad;
pub const getPostLoadMarkers = save_policy.getPostLoadMarkers;
pub const getPostLoadCreate = save_policy.getPostLoadCreate;
pub const isRemapExcluded = save_policy.isRemapExcluded;
pub const shouldSkipField = save_policy.shouldSkipField;

pub const ParentComponent = hierarchy.ParentComponent;
pub const ChildrenComponent = hierarchy.ChildrenComponent;

pub const PrefabInstance = prefab.PrefabInstance;
pub const PrefabChild = prefab.PrefabChild;

pub const Position = position.Position;
pub const PositionI = position.PositionI;

pub const CoordinateSystem = coordinates.CoordinateSystem;
pub const GamePosition = coordinates.GamePosition;
pub const ScreenPosition = coordinates.ScreenPosition;
pub const gameToScreen = coordinates.gameToScreen;
pub const screenToGame = coordinates.screenToGame;

// Y-axis convention (RFC labelle-engine#638) — the single source of truth for
// "which way is +Y" that gfx#276 and engine#639 route every vertical flip
// through. `toScreenY` is the canonical flip; `screenToLogicalY` its inverse.
pub const YAxis = coordinates.YAxis;
pub const toScreenY = coordinates.toScreenY;
pub const screenToLogicalY = coordinates.screenToLogicalY;

// RFC-FLOW-VOCABULARY phase 1: comptime contracts for plugin-extensible
// flow nodes. No discovery walk here — that lives in labelle-assembler.
pub const FlowNode = flow.FlowNode;
pub const FlowNodeReturn = flow.FlowNodeReturn;
pub const FlowNodeKind = flow.FlowNodeKind;
pub const PinSpec = flow.PinSpec;
pub const PinStyle = flow.PinStyle;
pub const PinStyles = flow.PinStyles;
pub const Color = flow.Color;
pub const EntityId = flow.EntityId;
pub const default_pin_styles = flow.default_pin_styles;
pub const numericFits = flow.numericFits;
pub const Coercion = flow.Coercion;
pub const CoercionReturn = flow.CoercionReturn;
pub const Coercions = flow.Coercions;

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

