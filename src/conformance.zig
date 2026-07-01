//! Behavioral conformance suites for the labelle backend contracts
//! (labelle-assembler#453, ecosystem-hardening follow-up to the pluggable-
//! backends epic #386).
//!
//! ## Why this exists
//! `backend_contract.assertBackend` / `input.assertInput` /
//! `window_contract.assertWindow` / `audio.AudioInterface` verify a backend's
//! **decl shape** — that the right method *names* exist. They do NOT verify
//! **behavior**: a backend can have `screenToWorld`/`worldToScreen` with the
//! right signatures but a broken (non-invertible) transform, a `color()` that
//! swaps channels, a `decodeImage` that returns a mis-sized buffer, or a
//! capability probe (`ownsLoop`, `canScreenshot`) that lies about `@hasDecl`.
//!
//! Each `runXSuite(comptime Impl: type) !void` below is parameterized over a
//! provider's `Impl` and asserts the *contract-level* behavioral invariants
//! that hold for **every** conformant backend, plus the capability-gated
//! invariants for each optional (`@hasDecl`-advertised) feature the `Impl`
//! actually declares. A provider is conformant iff it passes the suite for the
//! surfaces + capabilities it advertises.
//!
//! ## How a backend repo calls these
//! ```zig
//! const core = @import("labelle-core");
//! test "my render backend is behaviorally conformant" {
//!     try core.conformance.runRenderSuite(MyBackend);
//! }
//! test "my window backend is behaviorally conformant" {
//!     try core.conformance.runWindowSuite(MyWindow);
//! }
//! // ...runInputSuite / runAudioSuite likewise.
//! ```
//! The suites self-test against the reference impls (`mock_backend.MockBackend`,
//! `StubWindow`, `StubInput`, `StubAudio`) in `test/root_test.zig` — those
//! passing is the correctness proof for the suites themselves.
//!
//! ## What is behavioral vs shape-only (and why)
//! Anything requiring a real GPU, window surface, audio device, or a live OS
//! input source **cannot** be verified host-side and is documented per-check as
//! out-of-scope shape-only (we call the method to prove it links + doesn't
//! crash, but assert nothing about pixels/samples/frames). We never fake those.
//!
//! Known contract-surface gaps that block deeper behavioral testing — feed the
//! "contract versioning / sub-surface split" follow-up rather than being forced:
//!   - **Camera2D shape is unspecified** by the render contract, so the
//!     `screenToWorld`∘`worldToScreen` inverse round-trip only runs when the
//!     backend's `Camera2D` is default-constructible to a sane (invertible)
//!     identity. Backends whose `Camera2D` has no field defaults are skipped
//!     with this note.
//!   - **Input has no state-injection seam** — the contract exposes no way to
//!     synthesize a key/button press, so edge-vs-held semantics
//!     (`isKeyPressed` vs `isKeyDown`) cannot be verified for an arbitrary
//!     backend host-side. We verify the universally-checkable invariants
//!     (fallback defaults, gamepad buffer-bound safety) instead.
//!   - **Audio has no `DeviceSink`/mixer contract** in labelle-core today
//!     (only `AudioInterface`), and no host audio device — so mixer/level
//!     invariants aren't expressible. We verify id/handle + fallback semantics.
//!   - **Compressed-texture blobs** are backend-magic-keyed; there's no
//!     contract-level "known compressed blob", so compressed upload behavior is
//!     shape-only for a generic `Impl` (the paired-decl invariant is already
//!     enforced by `missingBackendDecls`).

const std = @import("std");
const testing = std.testing;

const backend_contract = @import("backend_contract.zig");
const window_contract = @import("window_contract.zig");
const input_mod = @import("input.zig");
const audio_mod = @import("audio.zig");

const Backend = backend_contract.Backend;
const Window = window_contract.Window;
const InputInterface = input_mod.InputInterface;
const AudioInterface = audio_mod.AudioInterface;
const GamepadEvent = input_mod.GamepadEvent;
const GamepadDescription = input_mod.GamepadDescription;

// ── embedded fixtures ────────────────────────────────────────────────────────

/// A real, minimal, valid 1×1 8-bit RGBA PNG (IHDR + IDAT + IEND, zlib-
/// compressed scanline). Fed to `decodeImage` / `loadTextureFromMemory` so the
/// buffer-size + decode→upload invariants run against a genuinely decodable blob
/// — a real PNG-validating decoder rejects arbitrary text before the invariant
/// is ever checked, so a text placeholder would only pass for a byte-ignoring
/// mock. Any conformant PNG decoder yields a 1×1 (width*height*4 == 4) buffer.
const valid_png_1x1_rgba = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x10, 0x54, 0x32, 0x76,
    0x01, 0x00, 0x01, 0x59, 0x00, 0xab, 0xcc, 0x74, 0x37, 0xbb, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

// ── comptime helpers ────────────────────────────────────────────────────────

/// True when `T` is a struct all of whose fields carry a default value — i.e.
/// `T{}` compiles. Used to decide whether a backend's `Camera2D` can be
/// default-constructed for the coordinate round-trip check.
fn isDefaultConstructible(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".fields) |f| {
        if (f.default_value_ptr == null) return false;
    }
    return true;
}

/// True when `C` looks like an RGBA color struct (has `r`/`g`/`b`/`a` fields).
/// The render contract's `color()` fallback assumes this shape; gating on it
/// keeps the channel-round-trip check honest for exotic color reprs.
///
/// The `@typeInfo(...) == .@"struct"` guard is load-bearing: `@hasField` is a
/// compile ERROR (not `false`) on a non-struct type, so a backend whose `Color`
/// is an opaque scalar (e.g. `Color = u32`, a packed RGBA word) would fail to
/// compile the suite entirely. Guarding first lets those backends be SKIPPED
/// (the channel round-trip isn't expressible for a scalar) rather than rejected.
fn hasRgbaChannels(comptime C: type) bool {
    if (@typeInfo(C) != .@"struct") return false;
    return @hasField(C, "r") and @hasField(C, "g") and @hasField(C, "b") and @hasField(C, "a");
}

/// True when `V` has `x`/`y` fields (the conventional Vector2 shape the draw
/// API and coordinate methods use). Guards on `.@"struct"` first for the same
/// reason as `hasRgbaChannels` — a non-struct `Vector2` (array/scalar repr) is
/// skipped, not a compile error.
fn hasXY(comptime V: type) bool {
    if (@typeInfo(V) != .@"struct") return false;
    return @hasField(V, "x") and @hasField(V, "y");
}

fn colorEql(a: anytype, b: @TypeOf(a)) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

// ── Render suite ─────────────────────────────────────────────────────────────

/// Behavioral conformance for the render backend contract (`Backend(Impl)`).
///
/// BEHAVIORAL (asserted): value-type ABI layout, color channel round-trip,
/// color-constant distinctness/opacity, screen-dim read stability,
/// `decodeImage` buffer sizing, decode→upload pipeline wiring,
/// `designToPhysical` identity fallback, coordinate inverse round-trip
/// (capability-gated on a default-constructible camera), and the font atlas
/// invariants (capability-gated).
///
/// SHAPE-ONLY (called, not asserted — no host GPU): the draw primitives and
/// compressed-blob probes. We prove they link and don't crash; pixels are not
/// observable host-side.
pub fn runRenderSuite(comptime Impl: type) !void {
    const B = Backend(Impl); // re-runs assertBackend at comptime.

    try runRenderValueTypeChecks();

    // ── Color channel round-trip (BEHAVIORAL) ──
    // `color(r,g,b,a)` must map each argument to the matching channel — a
    // backend that swaps R/B would pass the shape check but fail here.
    if (comptime hasRgbaChannels(B.Color)) {
        const c = B.color(12, 34, 56, 78);
        try testing.expectEqual(@as(u8, 12), c.r);
        try testing.expectEqual(@as(u8, 34), c.g);
        try testing.expectEqual(@as(u8, 56), c.b);
        try testing.expectEqual(@as(u8, 78), c.a);

        // Color constants: distinct + sane opacity. white/black/red/green/blue
        // are required decls; each primary must be pairwise distinct so a
        // backend that aliases (e.g. blue == red) is caught, and every
        // non-transparent constant must be fully opaque (a == 255) while
        // `transparent` must be fully transparent (a == 0). Checking only a
        // subset (as before) let an alpha-0 "opaque" constant or a red==blue
        // swap slip through.
        // All 10 unordered pairs among white/black/red/green/blue must be
        // distinct — checking only a subset let aliases like `white == red` or
        // `black == blue` slip through.
        try testing.expect(!colorEql(B.white, B.black));
        try testing.expect(!colorEql(B.white, B.red));
        try testing.expect(!colorEql(B.white, B.green));
        try testing.expect(!colorEql(B.white, B.blue));
        try testing.expect(!colorEql(B.black, B.red));
        try testing.expect(!colorEql(B.black, B.green));
        try testing.expect(!colorEql(B.black, B.blue));
        try testing.expect(!colorEql(B.red, B.green));
        try testing.expect(!colorEql(B.green, B.blue));
        try testing.expect(!colorEql(B.red, B.blue));
        try testing.expectEqual(@as(u8, 255), B.white.a);
        try testing.expectEqual(@as(u8, 255), B.black.a);
        try testing.expectEqual(@as(u8, 255), B.red.a);
        try testing.expectEqual(@as(u8, 255), B.green.a);
        try testing.expectEqual(@as(u8, 255), B.blue.a);
        try testing.expectEqual(@as(u8, 0), B.transparent.a);
    }

    // ── Screen-dimension reads are stable/pure (BEHAVIORAL) ──
    // Reading twice with no intervening mutation must return the same value
    // (a read accessor must not have side effects that shift the answer).
    const w0 = B.getScreenWidth();
    const w1 = B.getScreenWidth();
    try testing.expectEqual(w0, w1);
    const h0 = B.getScreenHeight();
    const h1 = B.getScreenHeight();
    try testing.expectEqual(h0, h1);

    // ── decodeImage buffer sizing (BEHAVIORAL) ──
    // Documented invariant: `pixels.len == width * height * 4`, RGBA8, and the
    // buffer is owned by the caller's allocator (freed here). testing.allocator
    // catches a leak or a mis-sized/over-freed buffer.
    {
        const decoded = try B.decodeImage("png", &valid_png_1x1_rgba, testing.allocator);
        defer testing.allocator.free(decoded.pixels);
        try testing.expect(decoded.width > 0);
        try testing.expect(decoded.height > 0);
        try testing.expectEqual(
            @as(usize, decoded.width) * @as(usize, decoded.height) * 4,
            decoded.pixels.len,
        );

        // ── decode → upload → unload pipeline wiring (BEHAVIORAL) ──
        // uploadTexture consumes a DecodedImage and yields a backend Texture;
        // the caller still owns `pixels` (freed by the defer above).
        const tex = try B.uploadTexture(decoded);
        B.unloadTexture(tex);
    }

    // ── file-based loadTexture (BEHAVIORAL: the file loader is wired) ──
    // `loadTexture` (file-path based) is a REQUIRED contract decl, so the suite
    // must actually invoke it — exercising only `loadTextureFromMemory` would let
    // a backend whose file loader always errors (but whose decodeImage/upload
    // path works) pass. We do NOT depend on a cwd `conformance.png` (it doesn't
    // exist in a backend repo — the original bug): instead write the embedded PNG
    // to a temp file and load THAT, then clean up. `Texture` is a backend-opaque
    // type with no contract-specified shape, so we can't assert its fields
    // generically — the successful `try` (loader returned without error) IS the
    // sane-handle assertion; unloading it proves the load→unload pair links.
    {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "conformance.png", .data = &valid_png_1x1_rgba });
        // `realPathFileAlloc` yields a NUL-terminated absolute path for the
        // `[:0]const u8` path contract; freed on the way out.
        const z_path = try tmp.dir.realPathFileAlloc(testing.io, "conformance.png", testing.allocator);
        defer testing.allocator.free(z_path);
        const tex = try B.loadTexture(z_path);
        B.unloadTexture(tex);
    }

    // loadTextureFromMemory convenience wrapper (decode+upload+free) returns a
    // Texture for an ordinary (non-compressed) blob (BEHAVIORAL: the wrapper is
    // wired). Fed the real PNG so a decode-validating backend actually reaches
    // the upload step instead of erroring on a bogus payload.
    {
        const tex = try B.loadTextureFromMemory("png", &valid_png_1x1_rgba);
        B.unloadTexture(tex);
    }

    // ── designToPhysical identity fallback (BEHAVIORAL, capability-gated) ──
    // Backends that don't pillarbox omit `designToPhysical`; the wrapper must
    // then return its argument unchanged. We can only assert the fallback (a
    // custom mapping is backend-specific and not generically checkable).
    if (comptime !@hasDecl(Impl, "designToPhysical")) {
        if (comptime hasXY(B.Vector2)) {
            var p: B.Vector2 = std.mem.zeroes(B.Vector2);
            p.x = 123.5;
            p.y = -42.25;
            const q = B.designToPhysical(p);
            try testing.expectEqual(p.x, q.x);
            try testing.expectEqual(p.y, q.y);
        }
    }

    // ── Coordinate inverse round-trip (BEHAVIORAL, capability-gated) ──
    // screenToWorld and worldToScreen must be mutual inverses. Requires a
    // default-constructible (sane identity) camera + an x/y Vector2, since the
    // contract doesn't specify Camera2D's shape (see module doc).
    if (comptime isDefaultConstructible(B.Camera2D) and hasXY(B.Vector2)) {
        const cam: B.Camera2D = .{};
        var p: B.Vector2 = std.mem.zeroes(B.Vector2);
        p.x = 137.0;
        p.y = 91.5;
        const round = B.screenToWorld(B.worldToScreen(p, cam), cam);
        try testing.expectApproxEqAbs(p.x, round.x, 0.01);
        try testing.expectApproxEqAbs(p.y, round.y, 0.01);

        // beginMode2D/endMode2D are callable with a valid camera (SHAPE-ONLY:
        // no observable host effect, just proves the pass scope links).
        B.beginMode2D(cam);
        B.endMode2D();
    }

    // ── Draw primitives (SHAPE-ONLY smoke: no host GPU to observe pixels) ──
    // We only prove each primitive links and doesn't crash with valid args.
    // The texture comes from the in-memory PNG fixture via `loadTextureFromMemory`
    // — NOT from an on-disk `loadTexture("conformance.png")`, which a real
    // filesystem-backed backend would fail with file-not-found in a backend repo
    // (no such file exists there). The in-memory path exercises the same
    // decode→upload→Texture wiring the draw calls need without touching the cwd.
    {
        const tex = try B.loadTextureFromMemory("png", &valid_png_1x1_rgba);
        defer B.unloadTexture(tex);
        const rect: B.Rectangle = std.mem.zeroes(B.Rectangle);
        const v: B.Vector2 = std.mem.zeroes(B.Vector2);
        B.drawTexturePro(tex, rect, rect, v, 0, B.white);
        B.drawRectangleRec(rect, B.white);
        B.drawRectanglePro(0, 0, 10, 10, 0, B.white);
        B.drawRectanglePro(0, 0, 10, 10, 1.0, B.white); // rotated fallback path
        B.drawCircle(0, 0, 5, B.white);
        B.drawTriangle(v, v, v, B.white);
        const poly = [_]B.Vector2{ v, v, v };
        B.drawPolygon(&poly, B.white);
        B.drawLine(0, 0, 10, 10, 1, B.white);
        B.drawText("hi", 0, 0, 12, B.white);
        B.drawRectangleLinesEx(rect, 1, B.white);
        B.drawCircleLines(0, 0, 5, B.white);
    }

    // ── Compressed-texture capability (SHAPE-ONLY, capability-gated) ──
    // No contract-level "known compressed blob" exists, so we can only prove
    // the probes are callable and return the right *types* without crashing.
    if (comptime @hasDecl(Impl, "isCompressed") and @hasDecl(Impl, "uploadCompressed")) {
        _ = B.isCompressed("conformance-probe"); // bool, must not crash
        _ = B.compressedDims("conformance-probe"); // ?CompressedDims
    }

    // ── Font atlas capability (BEHAVIORAL, capability-gated) ──
    try runFontChecks(Impl, B);
}

/// Value-type ABI checks for the shared render-contract types. These are
/// `Impl`-independent (the types are canonical in `backend_contract`), but they
/// belong to the render contract's asset-streaming surface, so they run at the
/// head of the render suite. BEHAVIORAL: field round-trips + the extern layout
/// guarantee the marshal boundary depends on.
fn runRenderValueTypeChecks() !void {
    // Glyph / CodepointRange / CodepointEntry / KernPair are `extern struct`
    // with a locked layout — the codegen marshal boundary reinterprets slices
    // of them across repos, so the extern layout must not silently regress.
    inline for (.{
        backend_contract.Glyph,
        backend_contract.CodepointRange,
        backend_contract.CodepointEntry,
        backend_contract.KernPair,
    }) |T| {
        try testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(T).@"struct".layout);
    }

    // Field round-trip: a constructed value reads back what was written.
    const g = backend_contract.Glyph{ .u0 = 1, .v0 = 2, .u1 = 3, .v1 = 4, .xoff = 5, .yoff = 6, .advance = 7 };
    try testing.expectEqual(@as(u16, 1), g.u0);
    try testing.expectEqual(@as(u16, 4), g.v1);
    try testing.expectEqual(@as(f32, 7), g.advance);

    const cr = backend_contract.CodepointRange{ .first = 0x20, .last = 0x7F };
    try testing.expectEqual(@as(u32, 0x20), cr.first);
    try testing.expectEqual(@as(u32, 0x7F), cr.last);

    const ce = backend_contract.CodepointEntry{ .codepoint = 65, .glyph_index = 3 };
    try testing.expectEqual(@as(u32, 65), ce.codepoint);
    try testing.expectEqual(@as(u32, 3), ce.glyph_index);

    const kp = backend_contract.KernPair{ .first = 1, .second = 2, .advance = -1.5 };
    try testing.expectEqual(@as(f32, -1.5), kp.advance);

    // FontBakeParams defaults (ASCII printable, 16px, 512x512) — the loader
    // relies on these when a caller omits params.
    const params = backend_contract.FontBakeParams{};
    try testing.expectEqual(@as(f32, 16), params.pixel_height);
    try testing.expectEqual(@as(u32, 512), params.atlas_width);
    try testing.expectEqual(@as(u32, 512), params.atlas_height);
    try testing.expectEqual(@as(usize, 1), params.ranges.len);
    try testing.expectEqual(@as(u32, 0x20), params.ranges[0].first);
}

/// Font atlas capability checks. BEHAVIORAL: bitmap sizing, glyph presence,
/// sorted codepoint index, glyph-index bounds, and the documented
/// `line_height == ascent - descent + line_gap` precompute.
///
/// The font capability is ALL-OR-NOTHING: a backend either declares the full
/// set (`decodeFont` + `FontAtlas` + `uploadFontAtlas` + `unloadFontAtlas`) or
/// none of it. A backend that declares SOME but not all is a half-implemented
/// surface — the suite fails with `error.IncompleteFontCapability` rather than
/// silently treating it as "not a font backend" (the old guard did the latter,
/// so a backend missing e.g. `unloadFontAtlas` reported success).
///
/// The decode-behavioral half needs a genuinely decodable font blob. A real
/// TTF-validating decoder rejects arbitrary bytes, so the suite uses a
/// BACKEND-PROVIDED fixture: a backend exposes `pub const conformanceFontBytes:
/// []const u8` (and optionally `pub const conformanceFontType: [:0]const u8`,
/// default "ttf") pointing at a tiny valid font it can decode. When no fixture
/// is provided the decode→bake→upload behavioral checks are SKIPPED (documented)
/// — the decl-completeness invariant above still holds. (Embedding a universal
/// valid TTF here isn't practical the way a 1×1 PNG is; the fixture seam keeps
/// the check real for backends that opt in.)
fn runFontChecks(comptime Impl: type, comptime B: type) !void {
    const has_decode = @hasDecl(Impl, "decodeFont");
    const has_atlas = @hasDecl(Impl, "FontAtlas");
    const has_upload = @hasDecl(Impl, "uploadFontAtlas");
    const has_unload = @hasDecl(Impl, "unloadFontAtlas");
    const has_all = comptime (has_decode and has_atlas and has_upload and has_unload);
    const has_any = comptime (has_decode or has_atlas or has_upload or has_unload);

    if (comptime !has_all) {
        // Half-implemented font surface → contract violation, not a silent skip.
        if (comptime has_any) return error.IncompleteFontCapability;
        return; // not a font backend — nothing to verify.
    }

    if (comptime !@hasDecl(Impl, "conformanceFontBytes")) {
        // Full font backend but no decodable fixture — the decode-behavioral
        // checks can't run against a synthetic blob for a real decoder. Skip
        // them (documented); the all-or-nothing decl invariant already passed.
        return;
    }

    const font_type: [:0]const u8 = comptime if (@hasDecl(Impl, "conformanceFontType"))
        Impl.conformanceFontType
    else
        "ttf";

    const params = backend_contract.FontBakeParams{};
    const font = try B.decodeFont(font_type, Impl.conformanceFontBytes, params, testing.allocator);
    defer {
        testing.allocator.free(font.bitmap);
        testing.allocator.free(font.glyphs);
        testing.allocator.free(font.codepoint_index);
        testing.allocator.free(font.kerning);
    }

    // Alpha atlas: 8-bit, length == width * height.
    try testing.expect(font.width > 0);
    try testing.expect(font.height > 0);
    try testing.expectEqual(@as(usize, font.width) * @as(usize, font.height), font.bitmap.len);

    // At least one baked glyph, and the codepoint index is sorted by codepoint
    // (renderers binary-search it — an unsorted index is a silent lookup bug).
    try testing.expect(font.glyphs.len >= 1);
    if (font.codepoint_index.len >= 2) {
        var i: usize = 1;
        while (i < font.codepoint_index.len) : (i += 1) {
            try testing.expect(font.codepoint_index[i - 1].codepoint <= font.codepoint_index[i].codepoint);
        }
    }

    // Every codepoint_index entry must point at a real glyph: `glyph_index <
    // glyphs.len`. Renderers index `font.glyphs[entry.glyph_index]` directly, so
    // an out-of-range index is an out-of-bounds read waiting to happen.
    for (font.codepoint_index) |entry| {
        try testing.expect(entry.glyph_index < font.glyphs.len);
    }

    // Documented precompute: line_height == ascent - descent + line_gap
    // (descent is negative). A backend that forgets this makes multi-line text
    // layout drift.
    try testing.expectApproxEqAbs(
        font.ascent - font.descent + font.line_gap,
        font.line_height,
        0.001,
    );

    // upload → unload pipeline (SHAPE-ONLY beyond "returns a handle": no host
    // GPU to inspect the uploaded atlas).
    const atlas = try B.uploadFontAtlas(font);
    B.unloadFontAtlas(atlas);
}

// ── Window suite ─────────────────────────────────────────────────────────────

/// Behavioral conformance for the window contract (`Window(Impl)`).
///
/// BEHAVIORAL (asserted): capability-probe truthfulness (`ownsLoop`/
/// `canScreenshot` must agree with `@hasDecl`), the `shouldQuit`/`isFullscreen`
/// fallback semantics for callback-model backends, `frameDuration` sign, and
/// dimension-read stability.
///
/// SHAPE-ONLY: `requestQuit`/`setFullscreen`/`setVsync` are called to prove
/// they link + no-op safely; `takeScreenshot` is NOT called (it would touch the
/// filesystem and needs a real surface).
pub fn runWindowSuite(comptime Impl: type) !void {
    const W = Window(Impl); // re-runs assertWindow at comptime.

    // ── Capability probes must not lie (BEHAVIORAL) ──
    // ownsLoop / canScreenshot are pure `@hasDecl` reflections; a probe that
    // disagrees with reality would mislead the splice's loop-vs-callback choice.
    try testing.expectEqual(@hasDecl(Impl, "shouldQuit"), W.ownsLoop());
    try testing.expectEqual(@hasDecl(Impl, "takeScreenshot"), W.canScreenshot());

    // ── Callback-model fallbacks (BEHAVIORAL) ──
    // A callback backend (no shouldQuit) must report "keep running" (false) —
    // the OS/browser pump ends it via requestQuit, not this gate.
    if (comptime !@hasDecl(Impl, "shouldQuit")) {
        try testing.expect(!W.shouldQuit());
    }
    // No fullscreen support → isFullscreen fallback is false.
    if (comptime !@hasDecl(Impl, "isFullscreen")) {
        try testing.expect(!W.isFullscreen());
    }

    // ── Dimension reads are stable/pure (BEHAVIORAL) ──
    try testing.expectEqual(W.width(), W.width());
    try testing.expectEqual(W.height(), W.height());

    // ── frameDuration is elapsed seconds → non-negative (BEHAVIORAL) ──
    try testing.expect(W.frameDuration() >= 0);

    // ── Display toggles + requestQuit are no-op-safe (SHAPE-ONLY smoke) ──
    W.setVsync(true);
    W.setVsync(false);
    W.setFullscreen(false);
    W.requestQuit();
    // takeScreenshot intentionally NOT called (filesystem + real surface).
}

// ── Input suite ──────────────────────────────────────────────────────────────

/// Behavioral conformance for the input contract (`InputInterface(Impl)`).
///
/// BEHAVIORAL (asserted): the fallback defaults for every optional capability
/// the `Impl` does NOT declare (mouse/touch/wheel/gamepad return 0/false), and
/// the gamepad hotplug buffer-bound safety invariant (never write past `out`,
/// return 0 for an empty buffer).
///
/// SHAPE-ONLY / OUT-OF-SCOPE: edge-vs-held key semantics (`isKeyPressed` vs
/// `isKeyDown`) — the contract has no state-injection seam, so we cannot
/// synthesize a press host-side. We call the keyboard accessors (they must
/// return a bool) but assert nothing about their value.
pub fn runInputSuite(comptime Impl: type) !void {
    const I = InputInterface(Impl); // re-runs assertInput at comptime.

    // ── Keyboard accessors are callable + bool-typed (SHAPE-ONLY) ──
    // No host key source → values are backend/timing specific; only type-check.
    const kd: bool = I.isKeyDown(0);
    const kp: bool = I.isKeyPressed(0);
    const kr: bool = I.isKeyReleased(0);
    _ = .{ kd, kp, kr };

    // ── Fallback defaults for absent optional capabilities (BEHAVIORAL) ──
    // The interface promises 0/false when a backend omits a capability; a
    // regression here silently breaks headless/keyboard-only backends.
    if (comptime !@hasDecl(Impl, "getMouseX")) try testing.expectEqual(@as(f32, 0), I.getMouseX());
    if (comptime !@hasDecl(Impl, "getMouseY")) try testing.expectEqual(@as(f32, 0), I.getMouseY());
    if (comptime !@hasDecl(Impl, "isMouseButtonDown")) try testing.expect(!I.isMouseButtonDown(0));
    if (comptime !@hasDecl(Impl, "isMouseButtonPressed")) try testing.expect(!I.isMouseButtonPressed(0));
    if (comptime !@hasDecl(Impl, "isMouseButtonReleased")) try testing.expect(!I.isMouseButtonReleased(0));
    if (comptime !@hasDecl(Impl, "getMouseWheelMove")) try testing.expectEqual(@as(f32, 0), I.getMouseWheelMove());
    if (comptime !@hasDecl(Impl, "getTouchCount")) try testing.expectEqual(@as(u32, 0), I.getTouchCount());
    if (comptime !@hasDecl(Impl, "getTouchX")) try testing.expectEqual(@as(f32, 0), I.getTouchX(0));
    if (comptime !@hasDecl(Impl, "getTouchY")) try testing.expectEqual(@as(f32, 0), I.getTouchY(0));
    if (comptime !@hasDecl(Impl, "getTouchId")) try testing.expectEqual(@as(u64, 0), I.getTouchId(0));
    if (comptime !@hasDecl(Impl, "isGamepadAvailable")) try testing.expect(!I.isGamepadAvailable(0));
    if (comptime !@hasDecl(Impl, "isGamepadButtonDown")) try testing.expect(!I.isGamepadButtonDown(0, 0));
    if (comptime !@hasDecl(Impl, "isGamepadButtonPressed")) try testing.expect(!I.isGamepadButtonPressed(0, 0));
    if (comptime !@hasDecl(Impl, "getGamepadAxisValue")) try testing.expectEqual(@as(f32, 0), I.getGamepadAxisValue(0, 0));

    // ── Gamepad hotplug buffer-bound safety (BEHAVIORAL) ──
    // Universal invariant regardless of declared capability: an empty output
    // buffer drains 0, and a poll never claims more events than the buffer
    // holds (a backend writing past `out` is memory-unsafe).
    {
        var empty: [0]GamepadEvent = undefined;
        try testing.expectEqual(@as(usize, 0), I.pollGamepadEvents(&empty));
        var buf: [4]GamepadEvent = undefined;
        try testing.expect(I.pollGamepadEvents(&buf) <= buf.len);

        var dempty: [0]GamepadDescription = undefined;
        try testing.expectEqual(@as(usize, 0), I.describeGamepads(&dempty));
        var dbuf: [4]GamepadDescription = undefined;
        try testing.expect(I.describeGamepads(&dbuf) <= dbuf.len);
    }

    // ── updateGestures is no-op-safe (SHAPE-ONLY smoke) ──
    I.updateGestures(0.016);
}

// ── Audio suite ──────────────────────────────────────────────────────────────

/// Behavioral conformance for the audio contract (`AudioInterface(Impl)`).
///
/// BEHAVIORAL (asserted): fallback semantics for absent optional capabilities
/// (`loadSound`/`loadMusic` return 0, `isSoundPlaying`/`isMusicPlaying` return
/// false when the backend omits them).
///
/// SHAPE-ONLY / OUT-OF-SCOPE: actual playback, mixing, and volume levels —
/// there is no host audio device and no `DeviceSink`/mixer contract in
/// labelle-core today (see module doc). We call the sound + music + global
/// surface to prove it links and is no-op-safe, but assert nothing audible.
///
/// The load→play→stop chain is only driven with an id we can produce WITHOUT
/// reading a file that doesn't exist in a backend repo: either the fallback id 0
/// (when the backend omits `loadSound`/`loadMusic`, the interface returns 0
/// without touching the filesystem) or a backend-provided fixture path
/// (`pub const conformanceSoundPath`/`conformanceMusicPath: [:0]const u8`). A
/// real loader with no fixture skips the file-backed smoke — the old code read a
/// hard-coded `conformance.wav`/`.ogg` that only a byte-ignoring stub tolerated.
pub fn runAudioSuite(comptime Impl: type) !void {
    const A = AudioInterface(Impl); // re-runs the playSound/stopSound gate.

    // ── Fallback semantics (BEHAVIORAL — no device or file needed) ──
    // A backend that omits a capability must degrade to a safe default; these
    // hold for id 0 without loading anything.
    if (comptime !@hasDecl(Impl, "loadSound"))
        try testing.expectEqual(@as(u32, 0), A.loadSound("conformance.wav"));
    if (comptime !@hasDecl(Impl, "isSoundPlaying"))
        try testing.expect(!A.isSoundPlaying(0));
    if (comptime !@hasDecl(Impl, "loadMusic"))
        try testing.expectEqual(@as(u32, 0), A.loadMusic("conformance.ogg"));
    if (comptime !@hasDecl(Impl, "isMusicPlaying"))
        try testing.expect(!A.isMusicPlaying(0));

    // ── Sound-effect surface (SHAPE-ONLY smoke) ──
    {
        const maybe_sid: ?u32 = blk: {
            if (comptime !@hasDecl(Impl, "loadSound")) break :blk @as(u32, 0);
            if (comptime @hasDecl(Impl, "conformanceSoundPath")) break :blk A.loadSound(Impl.conformanceSoundPath);
            break :blk null; // real loader, no fixture → skip file-backed smoke
        };
        if (maybe_sid) |sid| {
            A.playSound(sid);
            A.setSoundVolume(sid, 0.5);
            _ = A.isSoundPlaying(sid); // bool, must not crash
            A.stopSound(sid);
            A.unloadSound(sid);
        }
    }

    // ── Music (streaming) surface (SHAPE-ONLY smoke) — same fixture gating ──
    {
        const maybe_mid: ?u32 = blk: {
            if (comptime !@hasDecl(Impl, "loadMusic")) break :blk @as(u32, 0);
            if (comptime @hasDecl(Impl, "conformanceMusicPath")) break :blk A.loadMusic(Impl.conformanceMusicPath);
            break :blk null;
        };
        if (maybe_mid) |mid| {
            A.playMusic(mid);
            A.setMusicVolume(mid, 0.5);
            A.updateMusic(mid);
            _ = A.isMusicPlaying(mid);
            A.pauseMusic(mid);
            A.resumeMusic(mid);
            A.stopMusic(mid);
            A.unloadMusic(mid);
        }
    }

    // ── Global surface (SHAPE-ONLY smoke) ──
    A.setVolume(0.75);
    A.update();
}
