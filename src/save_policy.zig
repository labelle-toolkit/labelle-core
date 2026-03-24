/// Save policy declarations for ECS components.
///
/// Components can declare their serialization behavior by adding a
/// `pub const save_policy` field. Plugins (e.g. save/load) discover
/// this at comptime via the ComponentRegistry.
///
/// Example:
/// ```
/// pub const Stored = struct {
///     pub const save_policy: SavePolicy = .saveable;
///     pub const entity_ref_fields = .{"storage_id"};
///
///     storage_id: u64,
/// };
/// ```
pub const SavePolicy = enum {
    /// Serialized and restored on load.
    saveable,
    /// Stripped on load — re-derived by scripts each frame.
    transient,
    /// Zero-size marker from prefab — not serialized.
    marker,
};

/// Check if a type declares a save_policy.
pub fn hasSavePolicy(comptime T: type) bool {
    return @hasDecl(T, "save_policy");
}

/// Get the save_policy of a type, or null if not declared.
pub fn getSavePolicy(comptime T: type) ?SavePolicy {
    if (@hasDecl(T, "save_policy")) return @field(T, "save_policy");
    return null;
}

/// Check if a type declares entity_ref_fields for auto-remapping.
pub fn hasEntityRefFields(comptime T: type) bool {
    return @hasDecl(T, "entity_ref_fields");
}

/// Check if a type declares skip_fields for serialization.
pub fn hasSkipFields(comptime T: type) bool {
    return @hasDecl(T, "skip_fields");
}

/// Check if a field name should be skipped based on the type's skip_fields declaration.
pub fn shouldSkipField(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "skip_fields")) return false;
    const skip = @field(T, "skip_fields");
    for (skip) |name| {
        if (comptime std.mem.eql(u8, name, field_name)) return true;
    }
    return false;
}

const std = @import("std");
const testing = std.testing;

test "SavePolicy enum values" {
    try testing.expectEqual(SavePolicy.saveable, SavePolicy.saveable);
    try testing.expect(SavePolicy.saveable != SavePolicy.transient);
    try testing.expect(SavePolicy.transient != SavePolicy.marker);
}

test "hasSavePolicy detects declaration" {
    const WithPolicy = struct {
        pub const save_policy: SavePolicy = .saveable;
        x: f32 = 0,
    };
    const WithoutPolicy = struct {
        x: f32 = 0,
    };

    try testing.expect(hasSavePolicy(WithPolicy));
    try testing.expect(!hasSavePolicy(WithoutPolicy));
}

test "getSavePolicy returns correct value" {
    const Saveable = struct {
        pub const save_policy: SavePolicy = .saveable;
    };
    const Transient = struct {
        pub const save_policy: SavePolicy = .transient;
    };
    const NoDeclare = struct {};

    try testing.expectEqual(SavePolicy.saveable, getSavePolicy(Saveable).?);
    try testing.expectEqual(SavePolicy.transient, getSavePolicy(Transient).?);
    try testing.expectEqual(@as(?SavePolicy, null), getSavePolicy(NoDeclare));
}

test "shouldSkipField checks skip_fields" {
    const WithSkip = struct {
        pub const skip_fields = .{ "storages", "eis_slots" };
        storages: u32 = 0,
        eis_slots: u32 = 0,
        name: u32 = 0,
    };
    const NoSkip = struct {
        name: u32 = 0,
    };

    try testing.expect(shouldSkipField(WithSkip, "storages"));
    try testing.expect(shouldSkipField(WithSkip, "eis_slots"));
    try testing.expect(!shouldSkipField(WithSkip, "name"));
    try testing.expect(!shouldSkipField(NoSkip, "name"));
}

test "hasEntityRefFields detects declaration" {
    const WithRefs = struct {
        pub const entity_ref_fields = .{"storage_id"};
        storage_id: u64 = 0,
    };
    const WithoutRefs = struct {
        value: f32 = 0,
    };

    try testing.expect(hasEntityRefFields(WithRefs));
    try testing.expect(!hasEntityRefFields(WithoutRefs));
}
