/// Comptime-validated video interface (Flying-Platform/flying-platform-labelle#549).
///
/// Lets the engine and game scripts play decoded video through the active
/// backend without depending on any backend or codec. The assembler fills the
/// `Impl` slot at build time with the backend's video implementation (e.g. the
/// bgfx backend's `VideoBackend`, wrapping its AMediaCodec/ffmpeg decoders +
/// dynamic-texture `VideoPlayer`).
///
/// Video is an **optional capability**: unlike `AudioInterface`, it requires NO
/// decls — every method is `@hasDecl`-gated and degrades to a no-op. So a
/// backend that doesn't implement video (raylib/sokol today) still satisfies the
/// interface; callers probe `supported()` (true iff the backend can open video)
/// and otherwise skip the intro / show a static splash.
///
/// Handle model mirrors `AudioInterface`'s music streams: `open` returns an
/// opaque `u32` id (0 = failure / unsupported), and the backend owns the player
/// pool behind it. Per frame the game calls `update(id, dt)` (decode + upload +
/// A/V sync) then `draw(id, dest)`; `close(id)` releases it.
pub fn VideoInterface(comptime Impl: type) type {
    return struct {
        pub const Implementation = Impl;

        /// True iff the active backend can actually decode + play video. Game
        /// code should branch on this (intro vs. skip/splash) rather than
        /// assuming `open` succeeds.
        pub inline fn supported() bool {
            return @hasDecl(Impl, "openVideo");
        }

        /// Open a video by resource path (a backend asset / file path). Returns a
        /// handle, or 0 on failure or when video is unsupported.
        pub inline fn open(path: [:0]const u8) u32 {
            if (@hasDecl(Impl, "openVideo")) return Impl.openVideo(path);
            return 0;
        }

        /// Advance playback by `dt` seconds: decode the due frame, upload it to
        /// the GPU, and keep audio/video in sync. Call once per frame.
        pub inline fn update(id: u32, dt: f32) void {
            if (@hasDecl(Impl, "updateVideo")) Impl.updateVideo(id, dt);
        }

        /// Draw the current frame into the destination rect (screen-space, in the
        /// engine's design coordinates — the backend maps to the surface).
        pub inline fn draw(id: u32, x: f32, y: f32, w: f32, h: f32) void {
            if (@hasDecl(Impl, "drawVideo")) Impl.drawVideo(id, x, y, w, h);
        }

        /// True while the stream still has frames (false once it has ended). A
        /// non-looping intro uses this to know when to hand off to the game.
        pub inline fn isPlaying(id: u32) bool {
            if (@hasDecl(Impl, "isVideoPlaying")) return Impl.isVideoPlaying(id);
            return false;
        }

        /// Pixel dimensions of the video, or `.{ 0, 0 }` if unknown/unsupported.
        pub inline fn dimensions(id: u32) struct { w: u32, h: u32 } {
            if (@hasDecl(Impl, "videoDimensions")) {
                const d = Impl.videoDimensions(id);
                return .{ .w = d.w, .h = d.h };
            }
            return .{ .w = 0, .h = 0 };
        }

        /// Release the player and its decoder/texture/audio.
        pub inline fn close(id: u32) void {
            if (@hasDecl(Impl, "closeVideo")) Impl.closeVideo(id);
        }
    };
}

/// Stub video for engine-only testing — no decls, so `supported()` is false and
/// every call is a no-op (matches a backend without video).
pub const StubVideo = struct {};

/// Prefab-placeable video: attach to an entity and the engine's video system
/// plays the clip at that entity's world position — so a project can author
/// multiple videos in multiple places (in-world screens, billboards) purely via
/// prefabs/scenes, the same way it places sprites.
///
/// The path is stored inline so the component owns it (null-terminated for the
/// backend's `open`), avoiding a dangling slice into scene data. The runtime
/// `handle` is filled lazily by the system on first tick.
pub const VideoComponent = struct {
    path_buf: [192]u8 = [_]u8{0} ** 192,
    path_len: u16 = 0,
    /// Runtime player handle (0 = not opened yet). System-managed.
    handle: u32 = 0,
    /// Draw size in the entity's coordinate space; the dest rect is anchored at
    /// the entity's Position. 0 means "use the video's native pixel size".
    width: f32 = 0,
    height: f32 = 0,
    /// Skip drawing without closing the player (e.g. off-screen culling).
    visible: bool = true,

    pub fn init(path: []const u8, width: f32, height: f32) VideoComponent {
        var c = VideoComponent{ .width = width, .height = height };
        c.setPath(path);
        return c;
    }

    pub fn setPath(self: *VideoComponent, p: []const u8) void {
        const n = @min(p.len, self.path_buf.len - 1);
        @memcpy(self.path_buf[0..n], p[0..n]);
        self.path_buf[n] = 0;
        self.path_len = @intCast(n);
    }

    pub fn pathZ(self: *const VideoComponent) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }
};

test "StubVideo: unsupported, all calls no-op" {
    const std = @import("std");
    const V = VideoInterface(StubVideo);
    try std.testing.expect(!V.supported());
    try std.testing.expectEqual(@as(u32, 0), V.open("x"));
    try std.testing.expect(!V.isPlaying(1));
    try std.testing.expectEqual(@as(u32, 0), V.dimensions(1).w);
    V.update(1, 0.016); // no-op
    V.draw(1, 0, 0, 100, 100); // no-op
    V.close(1); // no-op
}

test "VideoComponent: owns a null-terminated path" {
    const std = @import("std");
    var c = VideoComponent.init("assets/intro.mp4", 320, 240);
    try std.testing.expectEqualStrings("assets/intro.mp4", c.pathZ());
    try std.testing.expectEqual(@as(f32, 320), c.width);
    try std.testing.expectEqual(@as(u32, 0), c.handle);
    try std.testing.expect(c.visible);
    c.setPath("b.mp4");
    try std.testing.expectEqualStrings("b.mp4", c.pathZ());
}

test "VideoInterface: a video-capable impl is dispatched" {
    const std = @import("std");
    const FakeBackend = struct {
        var opened: u32 = 0;
        pub fn openVideo(_: [:0]const u8) u32 {
            return 7;
        }
        pub fn updateVideo(_: u32, _: f32) void {
            opened += 1;
        }
        pub fn isVideoPlaying(_: u32) bool {
            return true;
        }
        pub fn videoDimensions(_: u32) struct { w: u32, h: u32 } {
            return .{ .w = 320, .h = 240 };
        }
    };
    const V = VideoInterface(FakeBackend);
    try std.testing.expect(V.supported());
    try std.testing.expectEqual(@as(u32, 7), V.open("intro"));
    V.update(7, 0.016);
    try std.testing.expectEqual(@as(u32, 1), FakeBackend.opened);
    try std.testing.expect(V.isPlaying(7));
    try std.testing.expectEqual(@as(u32, 320), V.dimensions(7).w);
}
