//! RFC-FLOW-VOCABULARY phase 1 — comptime contracts.
//!
//! Three palette-facing types plus a `PinStyles` convention marker:
//!   * `FlowNode` — comptime factory that builds one palette-ready
//!     node a plugin (or game module) contributes. Reflection on
//!     `impl` provides pin names, types, and command/reporter kind;
//!     the other fields override defaults.
//!   * `PinSpec` — per-pin metadata override (label, default, docs),
//!     keyed by param name on `FlowNode.pins`.
//!   * `PinStyle` — per-Zig-type display metadata (label, color, icon).
//!     Defaults for primitives + `EntityId` ship in `default_pin_styles`.
//!   * `PinStyles` — *convention name only.* A plugin / game module
//!     declares `pub const PinStyles = struct { ... }`; the assembler
//!     walks it at discovery time (phase 2). The marker here exists so
//!     callers can `@hasDecl(mod, "PinStyles")` against a documented
//!     identifier and the doc-comment lives in one place.
//!
//! ## Deviation from the RFC sketch
//!
//! RFC §1 sketches `FlowNode` as a plain struct with `pins: anytype`
//! and `impl: anytype` fields. Zig does not allow `anytype` as a
//! struct-field type, so the actual `FlowNode` is a **comptime
//! factory function**: callers write
//!
//!     pub const apply_impulse = labelle.FlowNode(.{ .impl = applyImpulseImpl });
//!
//! …instead of the RFC's `labelle.FlowNode{ .impl = applyImpulseImpl }`.
//! The returned value carries `impl` (with its original Zig type
//! intact) as a comptime decl plus every other configured field; the
//! assembler reflects on it without ever needing to name the concrete
//! return type. The user-facing shape — fields and defaults — matches
//! the RFC. Phase 5 (plugin-side declarations) will use the factory
//! call form.
//!
//! No discovery walk lives here — that's phase 2 in `labelle-assembler`.
//! No editor consumption — that's phase 4 in `labelle-gui`. No
//! flow-codegen integration — phase 3. No plugin-side declarations —
//! phase 5. This module is *only* the foundation.

/// RGB(A) color used by `PinStyle.color` and the editor's pin renderer.
/// Mirrors the `Color` struct already in use across `labelle-gfx` and
/// `labelle-gui` so a future shared color story can collapse them
/// without touching flow vocabulary.
pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
};

/// The conventional entity-handle alias used by default pin styles.
/// Plugins / games typically define their own `EntityId` (usually
/// `pub const EntityId = u32;` matching their ECS backend); reflection
/// in flow-codegen treats it as a type alias and collapses it to its
/// underlying integer per RFC §2 "wire-fit rule". This declaration
/// exists so `default_pin_styles.entity_id_style` has a typed anchor
/// and `@hasDecl` checks in the assembler can find a default.
pub const EntityId = u32;

/// `command` and `reporter` are the two visual / structural flavors a
/// node can take. See RFC §6 "Command vs reporter visual" — commands
/// are rectangular with execution flow, reporters are rounded with
/// only data pins.
pub const FlowNodeKind = enum { command, reporter };

/// Per-pin display metadata. Reflection on `FlowNode.impl` gives names
/// and types; `PinSpec` lets the contributing module override labels
/// and supply text defaults.
pub const PinSpec = struct {
    /// Display label in the editor. Defaults to the param name,
    /// titlecased, when null.
    label: ?[]const u8 = null,
    /// Zig source text of the pin's default value, evaluated at
    /// codegen. Per RFC §2 ("structs must be wired"), only meaningful
    /// for primitives and enums; struct defaults need a constructor
    /// node wired into the input pin.
    default: ?[]const u8 = null,
    /// Tooltip text shown when hovering the pin in the editor.
    docs: ?[]const u8 = null,
};

/// Build one palette-ready flow node from a comptime config literal.
///
/// Recognized fields on `cfg`:
/// - `impl` (required) — the Zig function. First param is
///   `game: anytype` (threaded by codegen); remaining params become
///   input pins; the return value (if non-`void`) becomes the output
///   pin. Stored as a comptime decl on the returned value's type so
///   the original signature survives reflection.
/// - `display_name: ?[]const u8` — human label. Defaults to the
///   decl name, titlecased (resolved later by the assembler).
/// - `category: ?[]const u8` — palette section. Defaults to the
///   contributing module's name (resolved by the assembler).
/// - `docs: ?[]const u8` — tooltip text in the palette + on the node.
/// - `kind: ?FlowNodeKind` — when null, inferred from `impl`'s return
///   type: `void` → `.command`, otherwise → `.reporter`. Authors
///   override only for the rare side-effecting reporter or the
///   pure-value command.
/// - `pins` — anonymous struct keyed by param name; each value is a
///   `PinSpec` (or struct-literal coercible to one). Anything missing
///   is reflected from `impl`.
/// - `constructs: ?[]const u8` — fully-qualified Zig type name this
///   node returns, used as an editor hint (RFC-FLOW-VOCABULARY §1,
///   resolves open question O5). When set, the editor knows the node
///   produces a value of that type, so a `SetVariable` on a
///   struct-typed variable (which can't have an inline default per the
///   "structs must be wired" rule) can suggest matching constructor
///   nodes from the palette. Defaults to `null` — most nodes are
///   commands or scalar reporters; only nodes whose return value is a
///   struct meant to be wired into another node's input pin need to
///   set this. The string is opaque to core (editor + assembler
///   decide what counts as "matching"); the convention is the Zig
///   type's fully-qualified name (`"labelle_box2d.RayResult"`) or just
///   the bare name for project-local types (`"Color"`).
///
/// Example:
///
///     pub const apply_impulse = labelle.FlowNode(.{
///         .impl = applyImpulseImpl,
///     });
///
///     pub const set_velocity = labelle.FlowNode(.{
///         .impl = setVelocityImpl,
///         .pins = .{
///             .x = .{ .label = "Velocity X" },
///             .y = .{ .label = "Velocity Y" },
///         },
///     });
///
///     pub const ray_cast = labelle.FlowNode(.{
///         .impl = rayCastImpl,
///         .constructs = "labelle_box2d.RayResult",
///     });
pub fn FlowNode(comptime cfg: anytype) FlowNodeReturn(cfg) {
    const T = @TypeOf(cfg);
    return .{
        .display_name = if (@hasField(T, "display_name")) cfg.display_name else null,
        .category = if (@hasField(T, "category")) cfg.category else null,
        .docs = if (@hasField(T, "docs")) cfg.docs else null,
        .kind = if (@hasField(T, "kind")) cfg.kind else null,
        .constructs = if (@hasField(T, "constructs")) cfg.constructs else null,
        .pins = if (@hasField(T, "pins")) cfg.pins else .{},
    };
}

/// Concrete return type of `FlowNode(cfg)`. Each call produces a
/// distinct type because `Pins` (the anon-struct of `PinSpec`s) and
/// `impl` (the function's `@TypeOf`) vary per node. The assembler
/// reflects on these per-type at discovery time.
pub fn FlowNodeReturn(comptime cfg: anytype) type {
    const T = @TypeOf(cfg);
    if (!@hasField(T, "impl")) {
        @compileError("FlowNode config is missing required field `.impl`");
    }
    const Pins = if (@hasField(T, "pins")) @TypeOf(cfg.pins) else @TypeOf(.{});
    return struct {
        display_name: ?[]const u8,
        category: ?[]const u8,
        docs: ?[]const u8,
        kind: ?FlowNodeKind,
        /// Fully-qualified Zig type name this node constructs, or null
        /// when the node is not a constructor (RFC-FLOW-VOCABULARY §1,
        /// open question O5). Editor consults this to suggest matching
        /// constructor nodes when the user creates a `SetVariable` of
        /// a struct type that has no inline default widget.
        constructs: ?[]const u8,
        pins: Pins,

        /// The author-supplied function. Carried as a comptime decl
        /// (not a runtime field) so its full Zig type — including the
        /// `game: anytype` first param + arbitrary trailing params —
        /// survives. Reflection: `@TypeOf(@This().impl)`.
        pub const impl = cfg.impl;

        /// Marker the assembler uses to recognize a node-valued decl
        /// during the discovery walk. Cheaper than `@hasDecl(@This(), "impl")`
        /// + introspection on every public decl in a `FlowNodes` block.
        pub const __is_labelle_flow_node = true;
    };
}

/// Per-type display metadata for the editor. Defaults for primitives
/// + `EntityId` ship in `default_pin_styles`; plugins override or
/// extend for their own types by exporting `pub const PinStyles`.
pub const PinStyle = struct {
    label: ?[]const u8 = null,
    color: ?Color = null,
    /// Editor-defined icon glyph or name. Format is the editor's
    /// concern; core is opaque to it.
    icon: ?[]const u8 = null,
};

/// `PinStyles` convention marker. Plugins / game modules that want to
/// extend the per-type style palette declare their own:
///
///     pub const PinStyles = struct {
///         pub const BodyId = labelle.PinStyle{ .label = "Body", .color = blue };
///     };
///
/// The struct itself has no required shape; the assembler walks
/// `@TypeOf(mod.PinStyles)`'s decls at discovery time (phase 2). This
/// marker exists so the convention has a documented anchor.
pub const PinStyles = struct {};

// ─── Numeric widening (RFC-FLOW-VOCABULARY §2, open question O1) ───
//
// The wire-fit rule's auto-accepted numeric conversions, encoded as a
// comptime helper. Resolves RFC open question O1 by pinning the exact
// set of widenings the editor + codegen accept silently — every other
// numeric conversion needs an explicit `IntCast` / `IntToFloat` /
// `FloatToInt` node (not yet shipped) or a declared coercion (O4).
//
// **Auto-accepted** (matches Zig's implicit conversions for `@as`):
// - Same-sign integer widening: `i8 → i16 → i32 → i64 → i128`,
//   `u8 → u16 → u32 → u64 → u128`.
// - Unsigned → larger-signed (always representable):
//   `u8 → i16/i32/i64/i128`, `u16 → i32/i64/i128`,
//   `u32 → i64/i128`, `u64 → i128`.
// - Float widening: `f32 → f64`.
//
// **Explicitly NOT auto-accepted** (require an explicit conversion):
// - Int → Float of any width (`i32 → f32` is lossy for large ints).
// - Signed → Unsigned (sign loss).
// - Float → Int (precision/range loss; truncation surprises).
// - Narrowing in either direction (always loses bits).
//
// Type equality is the trivial case and is handled by the wire-fit
// caller before reaching here — `numericFits` consistently returns
// `true` for it anyway so a caller that doesn't pre-check stays
// correct.

/// True when a value of `from` can be implicitly widened to `to` under
/// the RFC §2 / O1 wire-fit rule. Trivially `true` when `from == to`.
/// Pure comptime; no allocation, no runtime overhead.
pub fn numericFits(comptime from: type, comptime to: type) bool {
    if (from == to) return true;
    const from_info = @typeInfo(from);
    const to_info = @typeInfo(to);

    // Integer → integer.
    if (from_info == .int and to_info == .int) {
        const f = from_info.int;
        const t = to_info.int;
        // Same-sign widening (must grow, never shrink).
        if (f.signedness == t.signedness) return t.bits >= f.bits;
        // Unsigned → signed: the signed target needs at least one more
        // bit than the unsigned source to represent every value
        // unambiguously (sign bit). `u8 → i16` fits; `u8 → i8` does not.
        if (f.signedness == .unsigned and t.signedness == .signed) {
            return t.bits > f.bits;
        }
        // Signed → unsigned: never auto-accepted (sign loss).
        return false;
    }

    // Float → float widening.
    if (from_info == .float and to_info == .float) {
        return to_info.float.bits >= from_info.float.bits;
    }

    // Int ↔ Float: never auto-accepted (lossy / surprising for large
    // ints, truncation surprises in the other direction).
    return false;
}

/// Default `PinStyle`s the editor ships for primitives + `EntityId`.
/// Plugin- and game-supplied `PinStyles` blocks layer on top (later
/// declarations win for any duplicate type key).
///
/// Palette chosen to read clearly against a neutral canvas:
///   - integers (u32/i32/u64/i64): teal-ish blue
///   - floats   (f32/f64):         warm orange
///   - booleans:                   green
///   - text     ([]const u8):      purple
///   - entity   (EntityId):        yellow / amber (distinct from
///                                 integers even though the underlying
///                                 type is `u32`, because the editor
///                                 keys these by alias name not the
///                                 collapsed underlying type)
pub const default_pin_styles = struct {
    pub const u32_style = PinStyle{
        .label = "Integer",
        .color = .{ .r = 90, .g = 156, .b = 196, .a = 255 },
    };
    pub const i32_style = PinStyle{
        .label = "Integer",
        .color = .{ .r = 90, .g = 156, .b = 196, .a = 255 },
    };
    pub const u64_style = PinStyle{
        .label = "Integer",
        .color = .{ .r = 90, .g = 156, .b = 196, .a = 255 },
    };
    pub const i64_style = PinStyle{
        .label = "Integer",
        .color = .{ .r = 90, .g = 156, .b = 196, .a = 255 },
    };
    pub const f32_style = PinStyle{
        .label = "Number",
        .color = .{ .r = 230, .g = 145, .b = 56, .a = 255 },
    };
    pub const f64_style = PinStyle{
        .label = "Number",
        .color = .{ .r = 230, .g = 145, .b = 56, .a = 255 },
    };
    pub const bool_style = PinStyle{
        .label = "Bool",
        .color = .{ .r = 106, .g = 168, .b = 79, .a = 255 },
    };
    pub const string_style = PinStyle{
        .label = "Text",
        .color = .{ .r = 142, .g = 124, .b = 195, .a = 255 },
    };
    pub const entity_id_style = PinStyle{
        .label = "Entity",
        .color = .{ .r = 241, .g = 194, .b = 50, .a = 255 },
    };
};
