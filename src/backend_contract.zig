//! The render backend contract — the 8th comptime contract, relocated from
//! `labelle-gfx/src/backend.zig` into `labelle-core` so a backend author has a
//! single ABI home (labelle-assembler#387, RFC §Q#2 "Where the contracts
//! live"). `labelle-gfx` now re-exports `Backend` + these value types from
//! here; `labelle-engine` aliases the value types (retiring the nominal-
//! distinctness that forced the `extern struct` `@ptrCast` reinterpret).
//!
//! Two named sub-surfaces live behind `Backend(Impl)`: the **draw API**
//! (`drawTriangle`/`drawTexturePro`/…) and the **asset-streaming/loader**
//! surface (`decodeImage`/`uploadTexture` + the font decls). See the RFC.

const std = @import("std");
const builtin = @import("builtin");

// Decode-buffer allocator for the legacy `loadTextureFromMemory`
// convenience wrapper. On `wasm32-emscripten` Zig's `page_allocator`
// resolves to `WasmAllocator`, which calls `@wasmMemoryGrow` directly
// and bypasses emscripten's `updateMemoryViews()` — the next stderr
// write then aborts with a spurious "segmentation fault" because the
// JS-side `HEAPU32` is detached. Route through libc (emscripten's
// malloc) on wasm; keep `page_allocator` on desktop. See
// `labelle-cli/docs/wasm-segfault-investigation.md` (#196).
const decode_allocator: std.mem.Allocator = if (builtin.target.os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;

// ── Shared value types (the render contract's asset-streaming surface) ──────
// These are the canonical ABI types. `labelle-gfx` and `labelle-engine` alias
// them; because they are now one nominal type across all three repos, the
// codegen marshal boundary no longer needs the `@ptrCast` reinterpret hack.

/// CPU-decoded image owned by the caller's allocator.
/// Phase 1 of the Asset Streaming RFC (labelle-engine#437): splits PNG decode
/// (worker-thread safe) from GPU upload (main/GL thread only). The pixel buffer
/// is allocator-owned so the asset catalog can free it on BOTH the success and
/// the discard paths (when a refcount hits zero between decode and upload).
pub const DecodedImage = struct {
    /// RGBA8 pixels, length == width * height * 4. Owned by the allocator passed
    /// to `decodeImage`; the caller frees via that same allocator.
    pixels: []u8,
    width: u32,
    height: u32,
};

/// Codepoint range to bake glyphs for, half-open [first, last).
/// Used by `FontBakeParams` to drive `decodeFont`. Phase 4 of the Asset
/// Streaming RFC (labelle-engine#448).
///
/// `extern struct` so the codegen marshal boundary's slice layout is locked.
/// See `Glyph` below for the full rationale.
pub const CodepointRange = extern struct {
    first: u32,
    last: u32,
};

/// One baked glyph in a font atlas. UV rect is in *pixels* of the atlas
/// (not normalised) — the renderer divides by atlas size once at upload
/// time. `xoff` / `yoff` already incorporate the glyph's bearing; the
/// renderer just adds them to the pen position.
///
/// `extern struct` with a locked field order (u16×4 then f32×3): the
/// assembler-generated `FontBackendAdapter` historically `@ptrCast`ed
/// slices between three structurally-identical-but-nominally-distinct
/// `Glyph` types (core/gfx/engine). With the type owned here and aliased
/// by gfx + engine, the cast collapses to identity — but the `extern`
/// layout guarantee is kept so any remaining marshal seam stays well-defined.
pub const Glyph = extern struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,
    xoff: f32,
    yoff: f32,
    advance: f32,
};

/// Sorted (by codepoint) lookup from Unicode codepoint to dense glyph
/// index. Renderers binary-search this per glyph. `extern` for the same
/// reason as `Glyph`.
pub const CodepointEntry = extern struct {
    codepoint: u32,
    glyph_index: u32,
};

/// One GPOS kern pair. `extern` for the same reason as `Glyph`.
pub const KernPair = extern struct {
    first: u32,
    second: u32,
    advance: f32,
};

/// Bake-time parameters for `decodeFont`. The same TTF baked at
/// different `pixel_height` / `ranges` / atlas dimensions produces a
/// distinct atlas — that's why these ride alongside the source bytes
/// instead of being inferred from the file. The engine carries this
/// via `AssetEntry.params` (a type-erased pointer) at register time
/// and the worker forwards it to `decodeFont`. See
/// `RFC-FONT-LOADER.md` §2.
pub const FontBakeParams = struct {
    /// Pixel height passed to the rasteriser. f32 because
    /// `stb_truetype` (the canonical decoder) takes f32.
    pixel_height: f32 = 16,

    /// Codepoint ranges to bake. Default is ASCII printable.
    /// Lifetime: borrowed; must outlive the decode call.
    ranges: []const CodepointRange = &.{ .{ .first = 0x20, .last = 0x7F } },

    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

/// CPU-decoded font atlas + glyph metrics, owned by the caller's
/// allocator. The bitmap, glyphs, codepoint_index, and kerning slices
/// are ALL allocator-owned and ALL must be freed by the caller on both
/// the success and discard paths (mirroring `DecodedImage.pixels` for
/// images).
pub const DecodedFont = struct {
    /// 8-bit alpha atlas. Length == width * height.
    bitmap: []u8,
    width: u32,
    height: u32,

    /// Dense per-glyph metrics, indexed by `CodepointEntry.glyph_index`.
    glyphs: []Glyph,

    /// Codepoint → glyph_index lookup, sorted by codepoint.
    codepoint_index: []const CodepointEntry,

    /// Vertical metrics in pixels at the baked size.
    ascent: f32,
    descent: f32, // negative (below baseline)
    line_gap: f32,
    line_height: f32, // precomputed: ascent - descent + line_gap

    /// Sparse kerning pairs. Empty when the font has no GPOS kern
    /// table or the decoder chose to skip them.
    kerning: []const KernPair,
};

/// Blend mode for the `drawMesh` textured-mesh primitive (draw sub-surface).
/// Mirrors the four blend modes a Spine skeleton attachment can request, so the
/// planned `labelle-spine` binding maps `spBlendMode` straight onto this enum
/// (labelle-gfx#290). Also useful for particles / deformation / custom meshes.
///
///   - `normal`   — standard src-alpha over.
///   - `additive` — src added to dst (glows, fire, energy).
///   - `multiply` — src multiplied with dst (shadows, tint darkening).
///   - `screen`   — inverse-multiply lighten.
///
/// A backend that only supports `normal` may treat the others as `normal` —
/// a quality degradation, not a contract violation.
pub const BlendMode = enum { normal, additive, multiply, screen };

// ── Material seam (per-draw curated shader effects, labelle-gfx#305) ─────────
// Purely additive value types + an OPTIONAL `@hasDecl`-gated draw decl (see
// `Backend(Impl).drawTextureProMaterial`). Declaring them changes no existing
// `extern` layout and adds no REQUIRED decl, so — exactly like `drawMesh` /
// `FontAtlas` / `uploadCompressed` — none of the `*_CONTRACT_VERSION` numbers
// bump (the file's rule: optional additions are non-breaking).

/// Curated built-in per-draw shader effect (material seam, labelle-gfx#305).
/// The contract NAMES the effect; each backend owns its shader dialect + impl.
/// v1 is a FIXED set — NOT arbitrary user shaders (the 5-backend × N-dialect
/// matrix is unsupportable). A backend implements as many as it can; the rest
/// degrade (draw the sprite with no material). `none` is the batch-friendly
/// default and never touches the material path.
pub const MaterialEffect = enum(u8) {
    none = 0,
    palette_swap,
    flash,
    dissolve,
    outline,
};

/// Per-effect uniform block — a FLAT `extern struct` (decided: NOT an
/// `extern union`, see RFC §9 Q5). Rationale: the marshal seam (the assembler-
/// generated backend adapter) reinterprets contract value types by locked
/// `extern struct` layout + `@ptrCast`, and EVERY existing contract type
/// (`Glyph`, `CodepointRange`, `CodepointEntry`, `KernPair`) is an `extern
/// struct` — there is ZERO `extern union` anywhere in the toolkit. A flat
/// struct is the proven, reinterpret-safe shape; the backend switches on
/// `Material.effect` and reads the fields that effect uses (unused = 0). The
/// named-superset layout below covers all four effects in ≤ 24 bytes.
pub const MaterialUniforms = extern struct {
    /// Effect color, linear 0..1. `flash`/`outline`: the effect color;
    /// `dissolve`: the burn-edge glow (`r,g,b` used, `a` ignored);
    /// `palette_swap`: unused.
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
    /// Primary scalar. `flash`: amount (0=sprite … 1=fully flashed) ·
    /// `dissolve`: threshold (0=solid … 1=gone) · `outline`: thickness (px) ·
    /// `palette_swap`: unused.
    scalar0: f32 = 0,
    /// Secondary scalar. `dissolve`: edge_width (px) · `outline`: softness
    /// (0=hard … 1=feathered) · others: unused.
    scalar1: f32 = 0,
    /// Aux backend-texture handle. `palette_swap`: the LUT ramp (0 = none →
    /// degrade) · `dissolve`: noise texture (0 = backend built-in) · others:
    /// unused. Plain `u32` handle — same shape as `drawMesh` taking a texture
    /// (RFC §9 Q4, decided).
    aux_texture: u32 = 0,
    /// `palette_swap`: active ramp entry count (≤ LUT width). Others: unused.
    aux_count: u32 = 0,
};

/// A per-draw material: a curated effect + its uniform block. Rides a sprite
/// draw. `effect == .none` is the fast path — the renderer never calls the
/// material draw for it. Small + copyable; lives inline on `SpriteVisual`.
///
/// GPU counterpart to the CPU-side `effects.TintPulse` (gfx): for a zero-cost,
/// every-backend tint swap use `effects.TintPulse`; for a shader-based flash
/// with soft edges / partial `amount` mix use `MaterialEffect.flash` here
/// (RFC §5).
pub const Material = extern struct {
    effect: MaterialEffect = .none,
    uniforms: MaterialUniforms = .{},
};

/// The curated material effects a backend `Impl` advertises (see
/// `materialCapabilities`). Consumed by (a) the provider manifest
/// `.capabilities` mirror (pluggable-backends), so an unsupported effect a game
/// *declares* surfaces as an early project-level note rather than a silent
/// per-frame drop, and (b) the renderer's warn-once table.
pub const MaterialCapabilities = struct { effects: []const MaterialEffect };

/// Which curated material effects `Impl` advertises. Empty when the backend has
/// no `drawTextureProMaterial` at all. When it declares the draw decl but no
/// fine-grained `materialSupported`, it is taken to support every built-in
/// effect (all of `MaterialEffect` except `none`). Comptime introspection —
/// analogous to `missingBackendDecls`, but for an OPTIONAL capability rather
/// than a required one, so it feeds negotiation/warn-once, NOT `assertBackend`
/// (a missing material is never a contract violation).
pub fn materialCapabilities(comptime Impl: type) MaterialCapabilities {
    comptime {
        if (!@hasDecl(Impl, "drawTextureProMaterial")) return .{ .effects = &.{} };
        var effects: []const MaterialEffect = &.{};
        for (std.enums.values(MaterialEffect)) |eff| {
            if (eff == .none) continue;
            if (@hasDecl(Impl, "materialSupported") and !Impl.materialSupported(eff)) continue;
            effects = effects ++ [_]MaterialEffect{eff};
        }
        return .{ .effects = effects };
    }
}

// ── Render-target sub-surface (post-fx foundation, labelle-gfx#305) ──────────
// Render-to-target already exists as ad-hoc `@hasDecl` probes at the gfx layer
// (the `game.*RenderTarget` forwarders, engine 1.82/1.83 — transport mirror +
// headless capture). RFC §2.1 promotes them into the formal contract as a
// NAMED OPTIONAL sub-surface so they are versioned, discoverable, and
// negotiable — the contracted floor the post-fx stack stands on. Like the
// material seam, these are `@hasDecl`-gated + OPTIONAL: a backend without render
// targets simply has no post-fx, and NONE of the `*_CONTRACT_VERSION` numbers
// bump. NOT reached by `missingBackendDecls`/`assertBackend` (they stay
// required-only, byte-identical); the paired-unit consistency ("all five or
// none") is a SEPARATE optional check (`missingRenderTargetDecls`).

/// A backend-native offscreen render-target handle. Plain `u32` — the same
/// opaque-handle shape the `game.*RenderTarget` forwarders already pass STRAIGHT
/// THROUGH (no catalog mapping), and what `applyPostPass` reads/writes. `0` is
/// the reserved INVALID handle (a backend without render targets returns it).
pub const RenderTargetId = u32;

/// The five decls that make up the OPTIONAL render-target sub-surface. A backend
/// opts in by declaring ALL five; declaring a proper subset is an optional-
/// consistency error (a backend with `createRenderTarget` but no
/// `drawRenderTarget` can't composite) surfaced by `missingRenderTargetDecls`.
pub const render_target_fn_decls = [_][]const u8{
    "createRenderTarget", "beginRenderTarget", "endRenderTarget",
    "drawRenderTarget",   "destroyRenderTarget",
};

/// True iff `Impl` implements the WHOLE render-target sub-surface (all five
/// decls). The post-fx stack's whole-seam gate: false ⇒ the stack is a no-op
/// (warn-once at init), the frame renders straight to the backbuffer.
pub fn hasRenderTargetSubSurface(comptime Impl: type) bool {
    comptime {
        for (render_target_fn_decls) |name| if (!@hasDecl(Impl, name)) return false;
        return true;
    }
}

/// Optional-consistency check for the render-target sub-surface (the "all five
/// or none" rule, mirroring the `isCompressed`+`uploadCompressed` paired unit).
/// Returns empty when `Impl` declares ALL five OR NONE of the five (both are
/// valid); returns the missing decls tagged `.render_target` only for a partial
/// implementation. Deliberately NOT part of `missingBackendDecls`/
/// `assertBackend` — a fully-absent render-target sub-surface is not a contract
/// violation, just "no post-fx". Consumed by negotiation/diagnostics, not the
/// required-decl gate.
pub fn missingRenderTargetDecls(comptime Impl: type) []const MissingDecl {
    comptime {
        var present: usize = 0;
        for (render_target_fn_decls) |name| {
            if (@hasDecl(Impl, name)) present += 1;
        }
        // All present or all absent → consistent, nothing to report.
        if (present == 0 or present == render_target_fn_decls.len) return &.{};
        var missing: []const MissingDecl = &.{};
        for (render_target_fn_decls) |name| {
            if (!@hasDecl(Impl, name)) {
                missing = missing ++ [_]MissingDecl{.{ .name = name, .sub_surface = .render_target }};
            }
        }
        return missing;
    }
}

// ── Post-fx seam (full-screen pass stack, labelle-gfx#305) ───────────────────
// The ping-pong is orchestrated by gfx (RFC §2.4); the backend only implements
// a SINGLE pass reading one render target and writing another. Same optional,
// `@hasDecl`-gated, degrade-with-warn-once shape as the material seam — no
// version bump. Value types are purely additive flat `extern struct`s (RFC §2.2,
// §9 Q5 — NOT `extern union`, the marshal-seam-safe shape every contract type
// uses).

/// Curated built-in full-screen post-fx pass (post-fx seam, labelle-gfx#305).
/// The contract NAMES the pass; each backend owns its shader dialect + impl. v1
/// is a FIXED set. A backend implements as many as it can via `applyPostPass`
/// and declines the rest through the optional `postPassSupported` — the gfx
/// driver SKIPS an unsupported pass (warn-once) and the remaining passes run.
pub const PostPassKind = enum(u8) {
    bloom,
    vignette,
    color_grade,
    crt,
};

/// Per-pass uniform block — a FLAT `extern struct` (decided RFC §9 Q5, same
/// marshal-seam rationale as `MaterialUniforms`: reinterpret-safe locked layout,
/// zero `extern union` anywhere in the toolkit). The backend switches on
/// `PostPass.kind` and reads the fields that pass uses (unused = 0).
pub const PostPassUniforms = extern struct {
    /// bloom: threshold · vignette: intensity · color_grade: strength ·
    /// crt: curvature.
    scalar0: f32 = 0,
    /// bloom: intensity · vignette: radius · crt: scanline.
    scalar1: f32 = 0,
    /// bloom: radius · vignette: softness · crt: mask.
    scalar2: f32 = 0,
    /// crt: aberration · others: unused.
    scalar3: f32 = 0,
    /// vignette: tint color (linear 0..1). Other passes: unused.
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    /// color_grade: the LUT backend-texture handle (RFC §9 Q3 — a 2D unrolled
    /// strip; 0 = no LUT → pass degrades to no-op). Others: unused.
    aux_texture: u32 = 0,
};

/// One full-screen post-fx pass: a curated kind + its uniform block. Ordered
/// into a stack the gfx driver composes via render-target ping-pong. Small +
/// copyable; `extern struct` so the assembler-generated marshal seam is locked.
pub const PostPass = extern struct {
    kind: PostPassKind,
    uniforms: PostPassUniforms = .{},
};

/// The curated post-fx passes a backend `Impl` advertises (see
/// `postFxCapabilities`). Consumed by (a) the provider manifest `.capabilities`
/// mirror (pluggable-backends), so a pass a game *declares* but the backend
/// can't do surfaces as an early project-level note rather than a silent
/// per-frame skip, and (b) the gfx driver's warn-once table.
pub const PostFxCapabilities = struct { passes: []const PostPassKind };

/// Which curated post-fx passes `Impl` advertises. Empty when the backend has no
/// `applyPostPass` at all. When it declares `applyPostPass` but no fine-grained
/// `postPassSupported`, it is taken to support every built-in pass. Comptime
/// introspection — analogous to `materialCapabilities`; feeds negotiation/
/// warn-once, NOT `assertBackend` (a skipped pass is never a contract violation).
pub fn postFxCapabilities(comptime Impl: type) PostFxCapabilities {
    comptime {
        if (!@hasDecl(Impl, "applyPostPass")) return .{ .passes = &.{} };
        var passes: []const PostPassKind = &.{};
        for (std.enums.values(PostPassKind)) |kind| {
            if (@hasDecl(Impl, "postPassSupported") and !Impl.postPassSupported(kind)) continue;
            passes = passes ++ [_]PostPassKind{kind};
        }
        return .{ .passes = passes };
    }
}

// ── Contract versions ───────────────────────────────────────────────────────
//
// Per-sub-surface contract-version integers (labelle-assembler#453, RFC
// §"Versioning — the `contract_version` field"). Each is a MONOTONIC integer,
// NOT semver: it bumps by 1 only on a BREAKING change to that surface's decl
// set/signatures — a required decl added/removed/renamed, a method signature
// changed, or an `extern struct` value-type field added. Optional
// (`@hasDecl`-gated) additions are non-breaking and do NOT bump the version.
//
// A backend declares which version it targets (e.g. `pub const
// targets_backend_contract: u32 = 1;`); the assembler-generated adapter asserts
// `N == M` against these constants at comptime. That `N == M` emit is a
// SEPARATE follow-up (needs a core release + pin bump) and is NOT done here —
// this file only provides the ABI home for the numbers.

/// Version of the **draw API** sub-surface — the primitive-drawing decls
/// (`drawTexturePro`/`drawRectangleRec`/`drawCircle`/`drawTriangle`/
/// `drawPolygon`/`drawLine`/`drawText`/`beginMode2D`/… — see `draw_fn_decls`).
/// Bump on any breaking change to that decl set or their signatures.
pub const DRAW_CONTRACT_VERSION: u32 = 1;

/// Version of the **asset-loader** sub-surface — the image + font
/// decode/upload/unload decls (`decodeImage`/`uploadTexture`/`unloadTexture`/
/// `loadTexture` + the `FontAtlas`/`decodeFont`/`uploadFontAtlas`/
/// `unloadFontAtlas` font decls — see `loader_fn_decls`). Bump on any breaking
/// change to that decl set, their signatures, or the shared value types
/// (`DecodedImage`/`DecodedFont`/`Glyph`/… — their `extern` layout is part of
/// this contract).
pub const LOADER_CONTRACT_VERSION: u32 = 1;

/// Composite render-contract version — the ergonomic single-number case for
/// callers (and the assembler) that don't distinguish the two render
/// sub-surfaces. Bump when EITHER `DRAW_CONTRACT_VERSION` or
/// `LOADER_CONTRACT_VERSION` bumps (a breaking change to either half is a
/// breaking change to the render backend contract as a whole).
pub const BACKEND_CONTRACT_VERSION: u32 = 1;

// ── Contract validation ─────────────────────────────────────────────────────

/// Required type decls every render backend `Impl` must define.
pub const required_type_decls = [_][]const u8{
    "Texture", "Color", "Rectangle", "Vector2", "Camera2D",
};

/// Required function decls for the **draw API** sub-surface — the
/// primitive-drawing + camera/coordinate half of the render contract. Versioned
/// by `DRAW_CONTRACT_VERSION`.
pub const draw_fn_decls = [_][]const u8{
    "drawTexturePro", "drawRectangleRec", "drawCircle",      "drawTriangle",
    "drawPolygon",    "drawLine",         "drawText",        "beginMode2D",
    "endMode2D",      "getScreenWidth",   "getScreenHeight", "screenToWorld",
    "worldToScreen",  "setDesignSize",
};

/// Required function decls for the **asset-loader** sub-surface — the image
/// decode/upload/unload half of the render contract (the font decls are
/// optional/`@hasDecl`-gated, so they are not required here). Versioned by
/// `LOADER_CONTRACT_VERSION`.
pub const loader_fn_decls = [_][]const u8{
    "loadTexture", "decodeImage", "uploadTexture", "unloadTexture",
};

/// Required function decls (the draw API + the image asset-loader surface).
///
/// This is the FLAT aggregate view every render backend must satisfy. It is
/// spelled out explicitly (rather than `draw_fn_decls ++ loader_fn_decls`) to
/// preserve the ORIGINAL decl order — the loader decls (`loadTexture`/
/// `decodeImage`/`uploadTexture`/`unloadTexture`) sit between `drawText` and
/// `beginMode2D`, not after `setDesignSize`. `missingBackendDecls` walks this
/// order, so keeping it stable keeps the `assertBackend` diagnostic text
/// byte-identical (a `draw ++ loader` concat would move the loader decls to the
/// tail and silently reword the compile error). The `draw_fn_decls` /
/// `loader_fn_decls` sub-lists remain the source of truth for the *tagged*,
/// sub-surface-aware view (`missingBackendDeclsBySubSurface`); this aggregate is
/// their union as a SET, just ordered for a stable flat diagnostic.
pub const required_fn_decls = [_][]const u8{
    "drawTexturePro", "drawRectangleRec", "drawCircle",      "drawTriangle",
    "drawPolygon",    "drawLine",         "drawText",        "loadTexture",
    "decodeImage",    "uploadTexture",    "unloadTexture",   "beginMode2D",
    "endMode2D",      "getScreenWidth",   "getScreenHeight", "screenToWorld",
    "worldToScreen",  "setDesignSize",
};

/// Required color-constant decls.
pub const required_color_decls = [_][]const u8{
    "white", "black", "red", "green", "blue", "transparent",
};

/// Which named sub-surface a required decl belongs to. `draw` and `loader` are
/// the two REQUIRED render sub-surfaces the file documents; `type` (required
/// value types) and `color` (required color constants) are cross-cutting and
/// reported under their own tags so the classification is total. `render_target`
/// and `post_fx` are the two OPTIONAL sub-surfaces (labelle-gfx#305) — they are
/// never returned by `subSurfaceOf`/`missingBackendDeclsBySubSurface` (which
/// classify REQUIRED decls only), but they tag the OPTIONAL diagnostics
/// (`missingRenderTargetDecls`) and document the seam. Used by
/// `missingBackendDeclsBySubSurface` to tell a caller *where* a missing decl
/// lives.
pub const RenderSubSurface = enum {
    type,
    draw,
    loader,
    color,
    /// Optional render-target sub-surface (`create/begin/end/draw/destroy
    /// RenderTarget`) — the post-fx foundation (RFC §2.1).
    render_target,
    /// Optional post-fx sub-surface (`applyPostPass` + `postPassSupported`) —
    /// the full-screen pass primitive (RFC §2.3).
    post_fx,

    /// Stable lowercase tag ("draw"/"loader"/…), handy for prefixing a
    /// diagnostic message.
    pub fn tag(self: RenderSubSurface) []const u8 {
        return @tagName(self);
    }
};

/// A missing required decl, tagged with the sub-surface it belongs to.
pub const MissingDecl = struct {
    /// The missing decl's name (or a paired-decl description for the
    /// `isCompressed`+`uploadCompressed` unit).
    name: []const u8,
    sub_surface: RenderSubSurface,
};

/// Classify a required decl `name` into its sub-surface. Comptime; asserts the
/// name is a known required decl (so a typo in a decl list fails loudly rather
/// than silently mis-classifying). The paired compressed-texture unit is a
/// loader concern.
pub fn subSurfaceOf(comptime name: []const u8) RenderSubSurface {
    comptime {
        for (required_type_decls) |n| if (std.mem.eql(u8, n, name)) return .type;
        for (draw_fn_decls) |n| if (std.mem.eql(u8, n, name)) return .draw;
        for (loader_fn_decls) |n| if (std.mem.eql(u8, n, name)) return .loader;
        for (required_color_decls) |n| if (std.mem.eql(u8, n, name)) return .color;
        @compileError("subSurfaceOf: '" ++ name ++ "' is not a known required render decl");
    }
}

/// Sub-surface-aware sibling of `missingBackendDecls`: returns each missing
/// required decl tagged with the sub-surface (`draw`/`loader`/`type`/`color`) it
/// belongs to, or an empty slice if `Impl` satisfies the contract. Lets a caller
/// report *which* render sub-surface a backend is missing decls from; callers
/// that don't care use `missingBackendDecls` (the flat name list) unchanged.
pub fn missingBackendDeclsBySubSurface(comptime Impl: type) []const MissingDecl {
    comptime {
        var missing: []const MissingDecl = &.{};
        for (required_type_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_]MissingDecl{.{ .name = name, .sub_surface = .type }};
        }
        for (draw_fn_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_]MissingDecl{.{ .name = name, .sub_surface = .draw }};
        }
        for (loader_fn_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_]MissingDecl{.{ .name = name, .sub_surface = .loader }};
        }
        for (required_color_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_]MissingDecl{.{ .name = name, .sub_surface = .color }};
        }
        // Optional-but-paired: a backend that defines one of the compressed-
        // texture pair without the other would silently fall back to CPU
        // decode (then fail) — surface it as a contract violation, mirroring
        // the check `loadTextureFromMemory` makes below. It's a loader concern.
        if (@hasDecl(Impl, "isCompressed") != @hasDecl(Impl, "uploadCompressed")) {
            missing = missing ++ [_]MissingDecl{.{
                .name = "isCompressed+uploadCompressed (must define both or neither)",
                .sub_surface = .loader,
            }};
        }
        return missing;
    }
}

/// Pure comptime check: returns the names of required decls `Impl` is
/// missing, or an empty slice if it satisfies the contract. `assertBackend`
/// wraps this with an `@compileError`; tests call it directly to assert
/// acceptance/rejection without triggering a compile failure.
///
/// Aggregate view (flat name list) preserved for callers that don't care which
/// sub-surface a decl belongs to; see `missingBackendDeclsBySubSurface` for the
/// tagged view. Walks `required_type_decls ++ required_fn_decls ++
/// required_color_decls` in that exact order (then appends the paired
/// compressed-texture unit) — the SAME order the pre-sub-surface-split
/// implementation used, so the `assertBackend` compile-error text is
/// byte-identical. (The tagged sibling groups draw-then-loader, which is a
/// different order — that's fine: the tagged view exists to report *where* a
/// decl lives, not to reproduce the flat diagnostic.)
pub fn missingBackendDecls(comptime Impl: type) []const []const u8 {
    comptime {
        var missing: []const []const u8 = &.{};
        // Plain `for` (not `inline for`): this whole block is already a
        // `comptime {}` scope, so the loop is comptime-evaluated and `name` is
        // comptime in each iteration; `inline` here is redundant and a Zig 0.16
        // compile error.
        for (required_type_decls ++ required_fn_decls ++ required_color_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_][]const u8{name};
        }
        // Optional-but-paired: a backend that defines one of the compressed-
        // texture pair without the other would silently fall back to CPU
        // decode (then fail) — surface it as a contract violation, mirroring
        // the check `loadTextureFromMemory` makes below. Appended last so the
        // flat diagnostic order matches the original implementation exactly.
        if (@hasDecl(Impl, "isCompressed") != @hasDecl(Impl, "uploadCompressed")) {
            missing = missing ++ [_][]const u8{"isCompressed+uploadCompressed (must define both or neither)"};
        }
        return missing;
    }
}

/// Fail loudly at comptime if `Impl` doesn't satisfy the render backend
/// contract, naming every missing decl. The formal replacement for the
/// duck-typed `@hasDecl` checks `Backend` made inline.
pub fn assertBackend(comptime Impl: type) void {
    comptime {
        const missing = missingBackendDecls(Impl);
        if (missing.len != 0) {
            var msg: []const u8 = "Backend does not satisfy the render contract — missing decl(s):";
            for (missing) |name| msg = msg ++ "\n  - " ++ name;
            @compileError(msg);
        }
    }
}

/// Creates a validated backend interface from an implementation type.
/// The implementation must provide all required types and functions.
pub fn Backend(comptime Impl: type) type {
    comptime assertBackend(Impl);

    return struct {
        pub const Implementation = Impl;

        pub const Texture = Impl.Texture;
        pub const Color = Impl.Color;
        pub const Rectangle = Impl.Rectangle;
        pub const Vector2 = Impl.Vector2;
        pub const Camera2D = Impl.Camera2D;

        /// Image dimensions of a GPU-compressed blob, read from its header
        /// without decoding. Named (not anonymous) so the type is stable across
        /// declaration sites — the `compressedDims` wrapper below **field-maps**
        /// a backend's own anonymous `{ width, height }` result into this; it
        /// does NOT rely on struct coercion (two distinct anonymous structs do
        /// not coerce — see the wrapper's note).
        pub const CompressedDims = struct { width: u32, height: u32 };

        pub const white = Impl.white;
        pub const black = Impl.black;
        pub const red = Impl.red;
        pub const green = Impl.green;
        pub const blue = Impl.blue;
        pub const transparent = Impl.transparent;

        pub inline fn color(r: u8, g: u8, b: u8, a: u8) Color {
            if (@hasDecl(Impl, "color")) {
                return Impl.color(r, g, b, a);
            } else {
                return .{ .r = r, .g = g, .b = b, .a = a };
            }
        }

        pub inline fn drawTexturePro(
            texture: Texture,
            source: Rectangle,
            dest: Rectangle,
            origin: Vector2,
            rotation: f32,
            tint: Color,
        ) void {
            Impl.drawTexturePro(texture, source, dest, origin, rotation, tint);
        }

        pub inline fn drawRectangleRec(rec: Rectangle, tint: Color) void {
            Impl.drawRectangleRec(rec, tint);
        }

        /// Filled rectangle rotated `rotation` radians around its centre
        /// `(center_x, center_y)`. `width`/`height` are in world pixels.
        ///
        /// Fallback strategy when the backend doesn't expose a native
        /// rotated-quad primitive:
        ///   - `rotation == 0` — `drawRectangleRec` (identical to the
        ///     existing axis-aligned fast path, zero cost).
        ///   - `rotation != 0` — draw the 4 rotated edges via
        ///     `drawLine`. Outlined rather than filled (no universal
        ///     fill-quad primitive across backends), but the rotation
        ///     is still visible — silently degrading to axis-aligned
        ///     would hide the transform entirely, which is worse than
        ///     a cosmetic outline-vs-fill divergence.
        ///
        /// Backends wanting the filled rotation add a `pub fn
        /// drawRectanglePro(cx, cy, w, h, rotation, tint) void`
        /// declaration to their gfx module; the shim detects it via
        /// `@hasDecl` and dispatches.
        pub inline fn drawRectanglePro(
            center_x: f32,
            center_y: f32,
            width: f32,
            height: f32,
            rotation: f32,
            tint: Color,
        ) void {
            if (@hasDecl(Impl, "drawRectanglePro")) {
                Impl.drawRectanglePro(center_x, center_y, width, height, rotation, tint);
                return;
            }
            if (rotation == 0) {
                const rec = Rectangle{
                    .x = center_x - width * 0.5,
                    .y = center_y - height * 0.5,
                    .width = width,
                    .height = height,
                };
                drawRectangleRec(rec, tint);
                return;
            }
            // Rotated outline fallback.
            const hw = width * 0.5;
            const hh = height * 0.5;
            const cos_r = @cos(rotation);
            const sin_r = @sin(rotation);
            const Pt = struct { x: f32, y: f32 };
            const corners = [_]Pt{
                .{ .x = -hw, .y = -hh },
                .{ .x = hw, .y = -hh },
                .{ .x = hw, .y = hh },
                .{ .x = -hw, .y = hh },
            };
            var rotated: [4]Pt = undefined;
            for (corners, 0..) |p, i| {
                rotated[i] = .{
                    .x = center_x + p.x * cos_r - p.y * sin_r,
                    .y = center_y + p.x * sin_r + p.y * cos_r,
                };
            }
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const a = rotated[i];
                const b = rotated[(i + 1) % 4];
                Impl.drawLine(a.x, a.y, b.x, b.y, 1.0, tint);
            }
        }

        pub inline fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
            Impl.drawCircle(center_x, center_y, radius, tint);
        }

        /// Filled triangle through the three absolute vertices `v1`,
        /// `v2`, `v3` (already in world/screen space — the caller has
        /// applied position + scale). Point/Color signature mirrors the
        /// backend's other primitives. Outlined triangles take the
        /// `drawLine` path in the retained-engine draw helper instead.
        pub inline fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, tint: Color) void {
            Impl.drawTriangle(v1, v2, v3, tint);
        }

        /// Filled polygon through the absolute rim vertices in `points`
        /// (already in world/screen space — the caller has applied centre +
        /// scale). Backends triangle-fan from `points[0]`, so any polygon
        /// star-shaped from `points[0]` renders correctly — convex polygons
        /// and pie sectors (centre + rim) both qualify; arbitrary concave
        /// shapes do not. Same Point/Color
        /// convention as `drawTriangle`; outlined polygons take the
        /// `drawLine` path in the retained-engine draw helper instead.
        pub inline fn drawPolygon(points: []const Vector2, tint: Color) void {
            Impl.drawPolygon(points, tint);
        }

        /// Textured triangle-mesh primitive — the load-bearing enabler for
        /// skeletal animation (Spine, labelle-gfx#290), and reusable for
        /// particles / mesh deformation / custom geometry. Draws an indexed
        /// triangle list sampling `texture`, with per-vertex UV **and**
        /// per-vertex color, under blend mode `blend`.
        ///
        /// The buffers mirror Spine's `RenderCommand` so the binding is a
        /// straight pass-through — no per-vertex struct repacking:
        ///   - `positions`: xy pairs in world/screen space (already
        ///     position+scale-applied by the caller). `len == 2 * numVerts`.
        ///   - `uvs`: uv pairs, normalised [0,1] into `texture`.
        ///     `len == 2 * numVerts`, parallel to `positions`.
        ///   - `colors`: per-vertex RGBA8 packed one-u32-per-vertex (a tint
        ///     multiplied with the sampled texel). `len == numVerts`.
        ///   - `indices`: triangle list into the vertex arrays (every 3 forms
        ///     one triangle). `len == 3 * numTris`.
        ///
        /// OPTIONAL primitive: a backend opts in by declaring `pub fn
        /// drawMesh(...)`. Backends that don't (raylib/sokol/wgpu/sdl today)
        /// omit it and this wrapper compiles to a no-op — adding it is
        /// non-breaking, so `DRAW_CONTRACT_VERSION` does NOT bump. The bgfx
        /// implementation lands in a follow-up (labelle-gfx#290).
        pub inline fn drawMesh(
            texture: Texture,
            positions: []const f32,
            uvs: []const f32,
            colors: []const u32,
            indices: []const u16,
            blend: BlendMode,
        ) void {
            if (@hasDecl(Impl, "drawMesh")) {
                Impl.drawMesh(texture, positions, uvs, colors, indices, blend);
            }
        }

        /// Material-aware sprite draw (material seam, labelle-gfx#305).
        /// Identical to `drawTexturePro` but carries a curated `Material`.
        ///
        /// OPTIONAL, mirroring `drawMesh`: a backend opts in by declaring `pub
        /// fn drawTextureProMaterial(...)`. Adding it is non-breaking, so
        /// `DRAW_CONTRACT_VERSION` does NOT bump.
        ///
        /// Two-level capability gating (the mechanism the seam hangs on):
        ///   1. Decl-level (`@hasDecl(Impl, "drawTextureProMaterial")`): does
        ///      the backend do materials at all? Absent → every material
        ///      degrades to a plain `drawTexturePro` (the sprite renders WITHOUT
        ///      the effect — a quality degradation, NOT a contract violation).
        ///      Same coarse gate as `drawMesh`.
        ///   2. Effect-level (optional `Impl.materialSupported(effect) bool`):
        ///      does the backend do THIS effect? Lets a backend ship `flash` +
        ///      `palette_swap` but not `dissolve` yet without an all-or-nothing
        ///      decl. Absent ⇒ "if I declared the draw decl, I do all built-ins."
        ///      An unsupported effect falls back to a plain `drawTexturePro`.
        ///
        /// `effect == .none` also falls through to the plain path — callers are
        /// expected to skip this wrapper for `.none` (the renderer branches on
        /// it), but the guard keeps the wrapper correct if they don't.
        pub inline fn drawTextureProMaterial(
            texture: Texture,
            source: Rectangle,
            dest: Rectangle,
            origin: Vector2,
            rotation: f32,
            tint: Color,
            material: Material,
        ) void {
            if (@hasDecl(Impl, "drawTextureProMaterial") and material.effect != .none) {
                // Fine-grained: the backend may implement the decl but not THIS effect.
                if (@hasDecl(Impl, "materialSupported")) {
                    if (!Impl.materialSupported(material.effect)) {
                        drawTexturePro(texture, source, dest, origin, rotation, tint);
                        return;
                    }
                }
                Impl.drawTextureProMaterial(texture, source, dest, origin, rotation, tint, material);
            } else {
                drawTexturePro(texture, source, dest, origin, rotation, tint);
            }
        }

        /// True if `Impl` advertises the curated material `effect`. Coarse gate
        /// first (no `drawTextureProMaterial` ⇒ false for everything), then the
        /// optional fine-grained `materialSupported` (absent ⇒ all built-ins).
        /// Runtime-callable mirror of the comptime `materialCapabilities`, for
        /// the renderer's per-effect degrade branch + warn-once table.
        pub inline fn materialSupported(effect: MaterialEffect) bool {
            if (!@hasDecl(Impl, "drawTextureProMaterial")) return false;
            if (effect == .none) return false;
            if (@hasDecl(Impl, "materialSupported")) return Impl.materialSupported(effect);
            return true;
        }

        // ── Render-target sub-surface (post-fx foundation, labelle-gfx#305) ──
        // The formal, contracted wrappers for the render-target sub-surface
        // (RFC §2.1) — promoted here from the ad-hoc gfx-layer `@hasDecl` probes
        // so the post-fx driver composes on a versioned floor. OPTIONAL: each is
        // `@hasDecl`-gated, so a backend without render targets compiles and the
        // whole post-fx stack degrades to a no-op (`hasRenderTargets()` false).
        // Handles are backend-native `u32` (no catalog mapping) — the same
        // straight-through convention as the `game.*RenderTarget` forwarders.

        /// True iff `Impl` implements the whole render-target sub-surface. The
        /// post-fx driver's whole-seam gate.
        pub inline fn hasRenderTargets() bool {
            return comptime hasRenderTargetSubSurface(Impl);
        }

        /// Create an offscreen render target `w`×`h` (design pixels). Returns a
        /// backend-native handle, or `0` (INVALID) on a backend without the
        /// sub-surface.
        pub inline fn createRenderTarget(w: u16, h: u16) RenderTargetId {
            if (@hasDecl(Impl, "createRenderTarget")) return Impl.createRenderTarget(w, h);
            return 0;
        }

        /// Redirect subsequent draws into render target `id` (until
        /// `endRenderTarget`). No-op on a backend without the sub-surface.
        pub inline fn beginRenderTarget(id: RenderTargetId) void {
            if (@hasDecl(Impl, "beginRenderTarget")) Impl.beginRenderTarget(id);
        }

        /// End the current render-target redirection (draws return to the
        /// backbuffer). No-op on a backend without the sub-surface.
        pub inline fn endRenderTarget() void {
            if (@hasDecl(Impl, "endRenderTarget")) Impl.endRenderTarget();
        }

        /// Composite render target `id` to the current target at `dest` (SCREEN
        /// space — top-left, Y-down, pixels), modulated by `tint`. No-op on a
        /// backend without the sub-surface.
        pub inline fn drawRenderTarget(id: RenderTargetId, dest: Rectangle, tint: Color) void {
            if (@hasDecl(Impl, "drawRenderTarget")) Impl.drawRenderTarget(id, dest, tint);
        }

        /// Release render target `id`. No-op on a backend without the
        /// sub-surface.
        pub inline fn destroyRenderTarget(id: RenderTargetId) void {
            if (@hasDecl(Impl, "destroyRenderTarget")) Impl.destroyRenderTarget(id);
        }

        // ── Post-fx pass primitive (labelle-gfx#305) ────────────────────────

        /// Apply ONE full-screen post-fx pass: sample `src`, write `dst`, under
        /// `pass`. `src`/`dst` are render-target handles from the render-target
        /// sub-surface. OPTIONAL, mirroring `drawMesh`/`drawTextureProMaterial`:
        /// a backend opts in with `pub fn applyPostPass(...)`. Two-level gating —
        /// the coarse `@hasDecl` here, then the optional fine-grained
        /// `postPassSupported(kind)` (absent ⇒ all built-ins). An unsupported
        /// pass is a silent no-op here; the gfx DRIVER checks `postPassSupported`
        /// itself so it can SKIP-without-advancing the ping-pong + warn-once.
        /// Non-breaking; no version bump.
        pub inline fn applyPostPass(pass: PostPass, src: RenderTargetId, dst: RenderTargetId) void {
            if (@hasDecl(Impl, "applyPostPass")) {
                if (@hasDecl(Impl, "postPassSupported") and !Impl.postPassSupported(pass.kind)) return;
                Impl.applyPostPass(pass, src, dst);
            }
        }

        /// True if `Impl` advertises the curated post-fx `kind`. Coarse gate
        /// first (no `applyPostPass` ⇒ false for everything), then the optional
        /// fine-grained `postPassSupported` (absent ⇒ all built-ins). Runtime-
        /// callable mirror of the comptime `postFxCapabilities`, for the gfx
        /// driver's per-pass skip branch + warn-once table.
        pub inline fn postPassSupported(kind: PostPassKind) bool {
            if (!@hasDecl(Impl, "applyPostPass")) return false;
            if (@hasDecl(Impl, "postPassSupported")) return Impl.postPassSupported(kind);
            return true;
        }

        pub inline fn drawRectangleLinesEx(rec: Rectangle, line_thick: f32, tint: Color) void {
            if (@hasDecl(Impl, "drawRectangleLinesEx")) {
                Impl.drawRectangleLinesEx(rec, line_thick, tint);
            } else {
                drawRectangleRec(rec, tint);
            }
        }

        pub inline fn drawCircleLines(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
            if (@hasDecl(Impl, "drawCircleLines")) {
                Impl.drawCircleLines(center_x, center_y, radius, tint);
            } else {
                drawCircle(center_x, center_y, radius, tint);
            }
        }

        pub inline fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
            Impl.drawLine(start_x, start_y, end_x, end_y, thickness, tint);
        }

        pub inline fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
            Impl.drawText(text, x, y, size, tint);
        }

        pub inline fn loadTexture(path: [:0]const u8) !Texture {
            return Impl.loadTexture(path);
        }

        /// Pure CPU decode, safe to call from a worker thread. Returns a
        /// `DecodedImage` whose `pixels` buffer is owned by `allocator` — the
        /// caller frees it via that same allocator on BOTH the success and
        /// the discard paths (see `uploadTexture`).
        pub inline fn decodeImage(
            file_type: [:0]const u8,
            data: []const u8,
            allocator: std.mem.Allocator,
        ) !DecodedImage {
            return Impl.decodeImage(file_type, data, allocator);
        }

        /// Main/GL thread only. Uploads a previously decoded image to the GPU
        /// and returns a backend `Texture`. Does NOT free `decoded.pixels` —
        /// the caller is responsible for freeing the buffer on both the success
        /// path and the discard path (e.g. when the asset catalog drops the
        /// asset between decode and upload).
        pub inline fn uploadTexture(decoded: DecodedImage) !Texture {
            return Impl.uploadTexture(decoded);
        }

        /// Convenience wrapper: decode + upload + free in one call. Equivalent
        /// to the previous `loadTextureFromMemory` contract; preserved so
        /// existing synchronous callers (renderer, retained engine, single-
        /// threaded games) keep working unchanged.
        pub inline fn loadTextureFromMemory(file_type: [:0]const u8, data: []const u8) !Texture {
            // GPU-compressed blobs (e.g. ASTC) upload as-is — no CPU decode —
            // on backends that support them. A backend opts in by exposing
            // `isCompressed` + `uploadCompressed`; every other backend, and any
            // non-compressed blob, falls through to the decode path below, so
            // PNG/BMP/TGA loading is unchanged (labelle-gfx#269 / assembler#341).
            comptime {
                // The two are a unit — a backend that defines one but not the
                // other would silently fall back to CPU decode (then fail), so
                // make that a compile error instead of a runtime mystery.
                if (@hasDecl(Impl, "isCompressed") != @hasDecl(Impl, "uploadCompressed"))
                    @compileError("Backend must define both 'isCompressed' and 'uploadCompressed', or neither");
            }
            if (@hasDecl(Impl, "isCompressed") and @hasDecl(Impl, "uploadCompressed")) {
                if (Impl.isCompressed(data)) return Impl.uploadCompressed(data);
            }
            const allocator = decode_allocator;
            const decoded = try Impl.decodeImage(file_type, data, allocator);
            defer allocator.free(decoded.pixels);
            return Impl.uploadTexture(decoded);
        }

        pub inline fn unloadTexture(texture: Texture) void {
            Impl.unloadTexture(texture);
        }

        // ── GPU-compressed (ASTC) for the async asset catalog ───────────────
        // The synchronous `loadTextureFromMemory` above diverts compressed
        // blobs to `uploadCompressed` itself. The async streaming catalog
        // (labelle-engine#450) does NOT go through that wrapper — it splits
        // worker-thread `decodeImage` from main-thread `uploadTexture` — so its
        // generated adapter needs these namespace-level probes to route a
        // compressed blob past the CPU decoder. `@hasDecl`-guarded so a backend
        // without ASTC support still compiles (isCompressed → always false).

        /// True if `data` is a GPU-compressed blob this backend can upload
        /// as-is (no CPU decode). False on backends without compressed support.
        pub inline fn isCompressed(data: []const u8) bool {
            if (@hasDecl(Impl, "isCompressed") and @hasDecl(Impl, "uploadCompressed")) {
                return Impl.isCompressed(data);
            }
            return false;
        }

        /// Upload a GPU-compressed blob straight to the GPU — no CPU decode.
        /// Only valid when `isCompressed(data)` is true.
        pub inline fn uploadCompressed(data: []const u8) !Texture {
            if (@hasDecl(Impl, "isCompressed") and @hasDecl(Impl, "uploadCompressed")) {
                return Impl.uploadCompressed(data);
            }
            return error.CompressedTexturesUnsupported;
        }

        /// Image dimensions of a compressed blob, read from its header without
        /// decoding. Lets the catalog adapter set a correct DecodedImage
        /// width/height (for sprite-scale math) before the GPU upload. Null if
        /// unsupported or the blob isn't a compressed format we accept.
        pub inline fn compressedDims(data: []const u8) ?CompressedDims {
            if (@hasDecl(Impl, "compressedDims")) {
                // Field-map the backend's own (anonymous) `{ width, height }`
                // result into the named `CompressedDims` rather than relying on
                // struct coercion: a backend's `compressedDims` return type is a
                // *distinct* anonymous struct, which does not coerce to the named
                // type (the latent reason the inline `compressedDims` test never
                // compiled — see labelle-assembler#387). Field-mapping is
                // value-identical and compiles for any `{ width: u32, height: u32 }`.
                if (Impl.compressedDims(data)) |d| {
                    return .{ .width = d.width, .height = d.height };
                }
                return null;
            }
            return null;
        }

        // ── Font atlas (Phase 4 of Asset Streaming RFC, labelle-engine#448) ──
        //
        // Backends opt in by declaring `FontAtlas` + `decodeFont` +
        // `uploadFontAtlas` + `unloadFontAtlas`. Backends that don't
        // implement fonts simply omit those decls; the wrappers below
        // are `@hasDecl`-guarded so existing backends keep compiling
        // unchanged. Once a backend implements one of the four, it
        // should implement all four — there's no half-state we know
        // how to handle.

        /// Opaque backend-side font atlas handle. Resolves to the
        /// backend's own type when present, or to a zero-sized struct
        /// otherwise so the rest of the wrapper still typechecks. The
        /// adapter on the assembler side narrows this to a real handle
        /// before crossing into `labelle-engine`'s `FontId` shape.
        pub const FontAtlas = if (@hasDecl(Impl, "FontAtlas")) Impl.FontAtlas else struct {};

        /// Pure CPU bake — runs on the asset worker thread. Returns a
        /// `DecodedFont` whose four owned slices (`bitmap`, `glyphs`,
        /// `codepoint_index`, `kerning`) are all from `allocator`; the
        /// caller frees each on BOTH the success and discard paths.
        /// Errors `error.FontBackendNotImplemented` when `Impl` doesn't
        /// supply a `decodeFont` — so the engine's loader surfaces a
        /// clean error in `lastError` instead of a link failure.
        pub inline fn decodeFont(
            file_type: [:0]const u8,
            data: []const u8,
            params: FontBakeParams,
            allocator: std.mem.Allocator,
        ) !DecodedFont {
            if (@hasDecl(Impl, "decodeFont")) {
                return Impl.decodeFont(file_type, data, params, allocator);
            }
            return error.FontBackendNotImplemented;
        }

        /// Main/GL thread only. Uploads the alpha atlas to a GPU
        /// texture and returns a backend `FontAtlas` handle. Does NOT
        /// free any of the slices in `decoded` — the caller frees them
        /// on both the success and discard paths, same contract as
        /// `uploadTexture` for `DecodedImage.pixels`.
        pub inline fn uploadFontAtlas(decoded: DecodedFont) !FontAtlas {
            if (@hasDecl(Impl, "uploadFontAtlas")) {
                return Impl.uploadFontAtlas(decoded);
            }
            return error.FontBackendNotImplemented;
        }

        /// Releases the GPU atlas + any backend-side glyph metadata
        /// the upload allocated. Counterpart to `uploadFontAtlas`.
        pub inline fn unloadFontAtlas(atlas: FontAtlas) void {
            if (@hasDecl(Impl, "unloadFontAtlas")) {
                Impl.unloadFontAtlas(atlas);
            }
        }

        pub inline fn beginMode2D(camera: Camera2D) void {
            Impl.beginMode2D(camera);
        }

        pub inline fn endMode2D() void {
            Impl.endMode2D();
        }

        pub inline fn getScreenWidth() i32 {
            return Impl.getScreenWidth();
        }

        pub inline fn getScreenHeight() i32 {
            return Impl.getScreenHeight();
        }

        pub inline fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
            return Impl.screenToWorld(pos, camera);
        }

        pub inline fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
            return Impl.worldToScreen(pos, camera);
        }

        pub inline fn setDesignSize(w: i32, h: i32) void {
            Impl.setDesignSize(w, h);
        }

        /// Convert a design-pixel coordinate (e.g. the output of
        /// `cam.worldToScreen` for a world-space entity) to its
        /// physical-framebuffer pixel position, applying the
        /// backend's aspect-preserving fit (pillarbox/letterbox)
        /// and bar offset.
        ///
        /// Use this when pinning an imgui window to a world-space
        /// entity: `igSetNextWindowPos` interprets coords in
        /// physical-framebuffer pixels (`igGetIO().DisplaySize`),
        /// but `worldToScreen` returns design pixels — the two
        /// diverge whenever physical ≠ design. See [labelle-gfx#253][1].
        ///
        /// Backends that don't pillarbox / letterbox (or that draw
        /// directly to the design canvas) can omit `designToPhysical`
        /// — this wrapper falls back to identity so the call still
        /// compiles and produces correct results when design ==
        /// physical. The sokol backend overrides; raylib uses the
        /// fallback today.
        ///
        /// [1]: https://github.com/labelle-toolkit/labelle-gfx/issues/253
        pub inline fn designToPhysical(pos: Vector2) Vector2 {
            if (@hasDecl(Impl, "designToPhysical")) {
                return Impl.designToPhysical(pos);
            } else {
                return pos;
            }
        }
    };
}

// Runnable tests live in `test/root_test.zig` (the test root `zig build test`
// actually executes) — see the "backend contract" tests there.
