const std = @import("std");

// ── Contract versions ───────────────────────────────────────────────────────
//
// Audio spans two sub-surfaces (labelle-assembler#453, RFC §"Versioning"): the
// **playback** surface validated by `AudioInterface` below (`playSound`/
// `stopSound` required, the rest `@hasDecl`-gated), and the **loader** surface —
// the sound/music decode path, which is generated adapter code with no comptime
// validator of its own elsewhere, so per the RFC's "both audio halves get one
// ABI home" its version constant lives here alongside the playback one.
//
// Both are MONOTONIC integers, NOT semver: bump by 1 only on a BREAKING change
// to that surface's decl set/signatures; `@hasDecl`-gated optional additions do
// NOT bump them. A backend declares the versions it targets; the assembler-
// generated adapter asserts `N == M` — that emit is a deferred follow-up, these
// constants are its ABI home.

/// Version of the audio **playback** sub-surface — the `AudioInterface` decls
/// (`playSound`/`stopSound` required; `loadSound`/`isSoundPlaying`/music/global
/// capability-gated).
pub const AUDIO_PLAYBACK_CONTRACT_VERSION: u32 = 1;

/// Version of the audio **loader** sub-surface — the sound/music decode path
/// emitted as generated adapter code (no comptime validator of its own), homed
/// here per the RFC's "both audio halves get one ABI home".
pub const AUDIO_LOADER_CONTRACT_VERSION: u32 = 1;

// ── Audio contract (formalized — mirrors backend_contract.zig / input.zig) ───
//
// The duck-typed inline `@hasDecl` gate `AudioInterface` used is lifted into the
// same shape the render `Backend` and `InputInterface` contracts use: a
// required-decls array + a `missingAudioDecls` query + an `assertAudio` gate.
// Like input, audio is intentionally permissive — only `playSound`/`stopSound`
// are required; everything else stays OPTIONAL and degrades via the `@hasDecl`
// fallbacks in `AudioInterface`.

/// The minimum every audio backend must declare. Kept deliberately small —
/// the rest of the surface degrades gracefully via the `@hasDecl` fallbacks
/// in `AudioInterface`. All members are **playback** decls
/// (`AUDIO_PLAYBACK_CONTRACT_VERSION`).
pub const required_audio_decls = [_][]const u8{ "playSound", "stopSound" };

/// Names of required decls `Impl` is missing, or an empty slice. Mirrors
/// `backend_contract.missingBackendDecls` / `input.missingInputDecls` /
/// `window_contract.missingWindowDecls`.
pub fn missingAudioDecls(comptime Impl: type) []const []const u8 {
    comptime {
        var missing: []const []const u8 = &.{};
        // Plain `for` (not `inline for`) — already a comptime scope; `inline`
        // is a Zig 0.16 compile error here (see backend_contract).
        for (required_audio_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_][]const u8{name};
        }
        return missing;
    }
}

/// Fail loudly at comptime, naming every missing decl. Mirrors
/// `backend_contract.assertBackend` / `input.assertInput` / `assertWindow`.
pub fn assertAudio(comptime Impl: type) void {
    comptime {
        const missing = missingAudioDecls(Impl);
        if (missing.len != 0) {
            var msg: []const u8 = "Audio impl does not satisfy the audio contract — missing decl(s):";
            for (missing) |name| msg = msg ++ "\n  - " ++ name;
            @compileError(msg);
        }
    }
}

// ── Sub-surface classification (playback vs loader) ──────────────────────────
//
// Mirrors the render tagged view (`backend_contract.RenderSubSurface` +
// `subSurfaceOf`). Audio's two sub-surfaces are already named and versioned
// above (`AUDIO_PLAYBACK_CONTRACT_VERSION`/`AUDIO_LOADER_CONTRACT_VERSION`);
// these arrays classify every interface decl into its sub-surface so a caller
// can tell *where* a decl lives. Both required decls are playback decls, so a
// tagged missing-decl view would only ever report `.playback` — we ship the
// classifier + arrays and skip the tagged query (see #54).

/// The **loader** sub-surface decls (`AUDIO_LOADER_CONTRACT_VERSION`) — the
/// path/IO-facing acquire/release of sound and music ids. All optional.
pub const audio_loader_decls = [_][]const u8{
    "loadSound", "unloadSound", "loadMusic", "unloadMusic",
};

/// The **playback** sub-surface decls (`AUDIO_PLAYBACK_CONTRACT_VERSION`) — drive
/// already-loaded ids and global mix state. Includes the two required decls;
/// the rest are optional.
pub const audio_playback_decls = [_][]const u8{
    "playSound",   "stopSound",     "isSoundPlaying", "setSoundVolume",
    "playMusic",   "stopMusic",     "pauseMusic",     "resumeMusic",
    "isMusicPlaying", "setMusicVolume", "updateMusic", "setVolume",
    "update",
};

/// Which named sub-surface an audio decl belongs to. Stable lowercase `tag()`
/// mirrors `backend_contract.RenderSubSurface.tag`.
pub const AudioSubSurface = enum {
    playback,
    loader,

    pub fn tag(self: AudioSubSurface) []const u8 {
        return @tagName(self);
    }
};

/// Classify an audio decl `name` into its sub-surface. Comptime; asserts the
/// name is a known interface decl (a typo fails loudly rather than silently
/// mis-classifying — mirrors `backend_contract.subSurfaceOf`).
pub fn audioSubSurfaceOf(comptime name: []const u8) AudioSubSurface {
    comptime {
        for (audio_playback_decls) |n| if (std.mem.eql(u8, n, name)) return .playback;
        for (audio_loader_decls) |n| if (std.mem.eql(u8, n, name)) return .loader;
        @compileError("audioSubSurfaceOf: '" ++ name ++ "' is not a known audio decl");
    }
}

/// Comptime-validated audio interface.
/// The assembler provides the concrete Impl (raylib, sokol, miniaudio, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
pub fn AudioInterface(comptime Impl: type) type {
    comptime assertAudio(Impl);

    return struct {
        pub const Implementation = Impl;

        // ── Sound effects ──────────────────────────────────────────

        pub inline fn loadSound(path: [:0]const u8) u32 {
            if (@hasDecl(Impl, "loadSound")) return Impl.loadSound(path);
            return 0;
        }

        pub inline fn unloadSound(id: u32) void {
            if (@hasDecl(Impl, "unloadSound")) Impl.unloadSound(id);
        }

        pub inline fn playSound(id: u32) void {
            Impl.playSound(id);
        }

        pub inline fn stopSound(id: u32) void {
            Impl.stopSound(id);
        }

        pub inline fn isSoundPlaying(id: u32) bool {
            if (@hasDecl(Impl, "isSoundPlaying")) return Impl.isSoundPlaying(id);
            return false;
        }

        pub inline fn setSoundVolume(id: u32, volume: f32) void {
            if (@hasDecl(Impl, "setSoundVolume")) Impl.setSoundVolume(id, volume);
        }

        // ── Music (streaming) ──────────────────────────────────────

        pub inline fn loadMusic(path: [:0]const u8) u32 {
            if (@hasDecl(Impl, "loadMusic")) return Impl.loadMusic(path);
            return 0;
        }

        pub inline fn unloadMusic(id: u32) void {
            if (@hasDecl(Impl, "unloadMusic")) Impl.unloadMusic(id);
        }

        pub inline fn playMusic(id: u32) void {
            if (@hasDecl(Impl, "playMusic")) Impl.playMusic(id);
        }

        pub inline fn stopMusic(id: u32) void {
            if (@hasDecl(Impl, "stopMusic")) Impl.stopMusic(id);
        }

        pub inline fn pauseMusic(id: u32) void {
            if (@hasDecl(Impl, "pauseMusic")) Impl.pauseMusic(id);
        }

        pub inline fn resumeMusic(id: u32) void {
            if (@hasDecl(Impl, "resumeMusic")) Impl.resumeMusic(id);
        }

        pub inline fn isMusicPlaying(id: u32) bool {
            if (@hasDecl(Impl, "isMusicPlaying")) return Impl.isMusicPlaying(id);
            return false;
        }

        pub inline fn setMusicVolume(id: u32, volume: f32) void {
            if (@hasDecl(Impl, "setMusicVolume")) Impl.setMusicVolume(id, volume);
        }

        /// Must be called each frame to keep music streams fed.
        pub inline fn updateMusic(id: u32) void {
            if (@hasDecl(Impl, "updateMusic")) Impl.updateMusic(id);
        }

        // ── Global ────────────────────────────────────────────────

        pub inline fn setVolume(volume: f32) void {
            if (@hasDecl(Impl, "setVolume")) Impl.setVolume(volume);
        }

        /// Must be called each frame to keep music streams fed and
        /// perform any per-frame audio housekeeping.
        pub inline fn update() void {
            if (@hasDecl(Impl, "update")) Impl.update();
        }
    };
}

/// Stub audio for testing — all methods are no-ops.
pub const StubAudio = struct {
    // Conformance-suite fixtures (labelle-assembler#453). The stub's loaders
    // ignore the path, so these just let `conformance.runAudioSuite` drive the
    // file-backed load→play→stop smoke against the reference stub; a real
    // backend would point these at tiny valid assets it can open.
    pub const conformanceSoundPath: [:0]const u8 = "conformance-fixture.wav";
    pub const conformanceMusicPath: [:0]const u8 = "conformance-fixture.ogg";

    pub fn playSound(_: u32) void {}
    pub fn stopSound(_: u32) void {}
    pub fn setVolume(_: f32) void {}
    pub fn loadSound(_: [:0]const u8) u32 { return 0; }
    pub fn unloadSound(_: u32) void {}
    pub fn isSoundPlaying(_: u32) bool { return false; }
    pub fn setSoundVolume(_: u32, _: f32) void {}
    pub fn loadMusic(_: [:0]const u8) u32 { return 0; }
    pub fn unloadMusic(_: u32) void {}
    pub fn playMusic(_: u32) void {}
    pub fn stopMusic(_: u32) void {}
    pub fn pauseMusic(_: u32) void {}
    pub fn resumeMusic(_: u32) void {}
    pub fn isMusicPlaying(_: u32) bool { return false; }
    pub fn setMusicVolume(_: u32, _: f32) void {}
    pub fn updateMusic(_: u32) void {}
    pub fn update() void {}
};
