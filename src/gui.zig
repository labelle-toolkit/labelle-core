/// Comptime-validated GUI interface.
/// The assembler provides the concrete Impl (Clay, ImGui, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
///
/// The contract requires begin/end frame hooks. Widget APIs vary wildly
/// between GUI libraries (Clay is layout-based, ImGui is cursor-based),
/// so game code accesses the backend type directly via GuiBackend.
pub fn GuiInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "begin")) @compileError("GUI impl must define 'begin'");
        if (!@hasDecl(Impl, "end")) @compileError("GUI impl must define 'end'");
    }

    return struct {
        /// The raw backend type — game code uses this for widget calls.
        pub const GuiBackend = Impl;

        // ── Lifecycle ──────────────────────────────────────────────

        pub inline fn begin() void {
            Impl.begin();
        }

        pub inline fn end() void {
            Impl.end();
        }

        // ── Input passthrough ──────────────────────────────────────

        /// Check if GUI is capturing mouse (for input passthrough).
        pub inline fn wantsMouse() bool {
            if (@hasDecl(Impl, "wantsMouse")) return Impl.wantsMouse();
            return false;
        }

        /// Check if GUI is capturing keyboard (for input passthrough).
        pub inline fn wantsKeyboard() bool {
            if (@hasDecl(Impl, "wantsKeyboard")) return Impl.wantsKeyboard();
            return false;
        }

        // ── Dev overlay ────────────────────────────────────────────

        /// Render a dev stats overlay (FPS, entity count, draw calls).
        pub inline fn devOverlay(fps: i32, entity_count: u32, draw_calls: u32) void {
            if (@hasDecl(Impl, "devOverlay")) Impl.devOverlay(fps, entity_count, draw_calls);
        }

        // ── Widget helpers (optional, for simple backends) ─────────

        pub inline fn buttonWidget(id: u32, text: [:0]const u8, x: i32, y: i32, w: i32, h: i32) bool {
            if (@hasDecl(Impl, "button")) return Impl.button(id, text, x, y, w, h);
            return false;
        }

        pub inline fn panelWidget(x: i32, y: i32, w: i32, h: i32) void {
            if (@hasDecl(Impl, "panel")) Impl.panel(x, y, w, h);
        }

        pub inline fn labelWidget(text: [:0]const u8, x: i32, y: i32, size: i32, r: u8, g: u8, b: u8) void {
            if (@hasDecl(Impl, "label")) Impl.label(text, x, y, size, r, g, b);
        }

        pub inline fn progressBarWidget(x: i32, y: i32, w: i32, h: i32, value: f32, r: u8, g: u8, b: u8) void {
            if (@hasDecl(Impl, "progressBar")) Impl.progressBar(x, y, w, h, value, r, g, b);
        }

        pub inline fn sliderWidget(id: u32, x: i32, y: i32, w: i32, h: i32, value: f32, min_val: f32, max_val: f32) f32 {
            if (@hasDecl(Impl, "slider")) return Impl.slider(id, x, y, w, h, value, min_val, max_val);
            return value;
        }

        pub inline fn checkboxWidget(id: u32, text: [:0]const u8, x: i32, y: i32, checked: bool) bool {
            if (@hasDecl(Impl, "checkbox")) return Impl.checkbox(id, text, x, y, checked);
            return checked;
        }
    };
}

/// Stub GUI for testing — all methods are no-ops.
pub const StubGui = struct {
    pub fn begin() void {}
    pub fn end() void {}
    pub fn wantsMouse() bool { return false; }
    pub fn wantsKeyboard() bool { return false; }
};
