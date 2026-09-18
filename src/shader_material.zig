//! Backend-neutral game-owned shader contract. Effect state belongs to games.
//! Descriptors are borrowed for create only; implementations must own retained data.
const std = @import("std");
const BackendTextureId = @import("backend_contract.zig").BackendTextureId;

pub const VERSION: u32 = 1;
pub const MAX_PARAMETERS = 16;
pub const MAX_TEXTURES = 4;
pub const MAX_REGISTERS = 64;
pub const MAX_NAME = 63;

/// Generation-bearing opaque handle. Never serialize a live handle into a prefab.
pub const Id = enum(u64) { none = 0, _ };
pub const Kind = enum { scalar, vec2, vec3, vec4, mat4 };
pub const Sampler = enum { point, linear };
pub const Blend = enum { alpha, additive };
pub const ShaderVariants = struct {
    glsl: []const u8 = &.{},
    essl: []const u8 = &.{},
    spv: []const u8 = &.{},
    mtl: []const u8 = &.{},
    dx11: []const u8 = &.{},
};
pub const Parameter = struct {
    name: [:0]const u8,
    kind: Kind = .vec4,
    count: u16 = 1,
    /// Empty means zero initialization; otherwise exactly channels(kind)*count.
    defaults: []const f32 = &.{},
};
pub const TextureBinding = struct {
    name: [:0]const u8,
    texture: BackendTextureId = .none,
    sampler: Sampler = .point,
};
pub const Descriptor = struct {
    version: u32 = VERSION,
    label: []const u8 = "",
    shaders: ShaderVariants,
    parameters: []const Parameter = &.{},
    textures: []const TextureBinding = &.{},
    blend: Blend = .alpha,
};
pub const Error = error{
    Unsupported,
    InvalidDescriptor,
    DuplicateBinding,
    InvalidName,
    InvalidCount,
    InvalidDefault,
    InvalidHandle,
    UnknownParameter,
    UnknownTexture,
    ParameterShapeMismatch,
    NonFiniteParameter,
    InvalidTexture,
    CapacityExceeded,
    OutOfMemory,
    InvalidShader,
    ShaderLinkFailed,
    UniformCreationFailed,
};

pub fn channels(kind: Kind) usize {
    return switch (kind) {
        .scalar => 1,
        .vec2 => 2,
        .vec3 => 3,
        .vec4 => 4,
        .mat4 => 16,
    };
}
pub fn registers(parameter: Parameter) usize {
    return @as(usize, parameter.count) * (if (parameter.kind == .mat4) @as(usize, 4) else 1);
}
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    for ([_][]const u8{ "s_tex", "u_material_rect", "u_viewRect", "u_viewTexel", "u_view", "u_invView", "u_proj", "u_invProj", "u_viewProj", "u_invViewProj", "u_model", "u_modelView", "u_modelViewProj", "u_alphaRef4" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return false;
    }
    return true;
}
pub fn validateParameter(parameter: Parameter, values: []const f32) Error!void {
    if (parameter.count == 0 or registers(parameter) > MAX_REGISTERS) return error.InvalidCount;
    if (values.len != channels(parameter.kind) * parameter.count) return error.ParameterShapeMismatch;
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteParameter;
}
pub fn validateDescriptor(descriptor: Descriptor) Error!void {
    if (descriptor.version != VERSION) return error.InvalidDescriptor;
    if (descriptor.parameters.len > MAX_PARAMETERS or descriptor.textures.len > MAX_TEXTURES) return error.CapacityExceeded;
    const variants = descriptor.shaders;
    if (variants.glsl.len + variants.essl.len + variants.spv.len + variants.mtl.len + variants.dx11.len == 0) return error.InvalidShader;
    // One register is reserved for u_material_rect, supplied by the draw path.
    var total: usize = 1;
    for (descriptor.parameters, 0..) |parameter, i| {
        if (!validName(parameter.name)) return error.InvalidName;
        if (parameter.count == 0) return error.InvalidCount;
        total += registers(parameter);
        if (total > MAX_REGISTERS) return error.CapacityExceeded;
        if (parameter.defaults.len != 0) validateParameter(parameter, parameter.defaults) catch return error.InvalidDefault;
        for (descriptor.parameters[0..i]) |previous| if (std.mem.eql(u8, parameter.name, previous.name)) return error.DuplicateBinding;
        for (descriptor.textures) |texture| if (std.mem.eql(u8, parameter.name, texture.name)) return error.DuplicateBinding;
    }
    for (descriptor.textures, 0..) |texture, i| {
        if (!validName(texture.name)) return error.InvalidName;
        for (descriptor.textures[0..i]) |previous| if (std.mem.eql(u8, texture.name, previous.name)) return error.DuplicateBinding;
    }
}

test "reject malformed defaults, duplicate bindings and reserved names" {
    var d = Descriptor{ .shaders = .{ .spv = "compiled" } };
    d.parameters = &.{.{ .name = "u_level", .kind = .scalar, .defaults = &.{0} }};
    try validateDescriptor(d);
    d.parameters = &.{.{ .name = "u_level", .kind = .vec2, .defaults = &.{0} }};
    try std.testing.expectError(error.InvalidDefault, validateDescriptor(d));
    d.parameters = &.{ .{ .name = "u_level" }, .{ .name = "u_level" } };
    try std.testing.expectError(error.DuplicateBinding, validateDescriptor(d));
    d.parameters = &.{.{ .name = "u_material_rect" }};
    try std.testing.expectError(error.InvalidName, validateDescriptor(d));
    d.parameters = &.{.{ .name = "u_data" }};
    d.textures = &.{.{ .name = "u_data" }};
    try std.testing.expectError(error.DuplicateBinding, validateDescriptor(d));
}
test "bounded arrays and finite typed updates" {
    const p = Parameter{ .name = "u_values", .kind = .vec2, .count = 2 };
    try validateParameter(p, &.{ 1, 2, 3, 4 });
    try std.testing.expectError(error.ParameterShapeMismatch, validateParameter(p, &.{1}));
    try std.testing.expectError(error.NonFiniteParameter, validateParameter(p, &.{ 1, 2, std.math.nan(f32), 4 }));
    const d = Descriptor{ .shaders = .{ .spv = "compiled" }, .parameters = &.{.{ .name = "u_many", .count = 64 }} };
    try std.testing.expectError(error.CapacityExceeded, validateDescriptor(d));
}
test "empty shaders and unknown versions are actionable failures" {
    try std.testing.expectError(error.InvalidShader, validateDescriptor(.{ .shaders = .{} }));
    try std.testing.expectError(error.InvalidDescriptor, validateDescriptor(.{ .version = 2, .shaders = .{ .spv = "compiled" } }));
}
