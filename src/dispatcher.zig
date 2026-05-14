const std = @import("std");

pub fn UnwrapReceiver(comptime T: type) type {
    var Current = T;
    while (@typeInfo(Current) == .pointer) {
        Current = @typeInfo(Current).pointer.child;
    }
    return Current;
}

pub fn HookDispatcher(
    comptime PayloadUnion: type,
    comptime Receiver: type,
    comptime options: struct { exhaustive: bool = false },
) type {
    const Base = UnwrapReceiver(Receiver);

    comptime {
        for (std.meta.declarations(Base)) |decl| {
            if (fieldIndex(PayloadUnion, decl.name) == null) {
                if (@hasDecl(Base, decl.name)) {
                    const DeclType = @TypeOf(@field(Base, decl.name));
                    const info = @typeInfo(DeclType);
                    if (info == .@"fn" and info.@"fn".params.len == 2) {
                        @compileError(
                            "Handler '" ++ decl.name ++ "' in " ++ @typeName(Base) ++
                                " doesn't match any event in " ++ @typeName(PayloadUnion) ++
                                ". Did you mean one of: " ++ fieldNames(PayloadUnion) ++ "?",
                        );
                    }
                }
            }
        }

        if (options.exhaustive) {
            for (std.meta.fields(PayloadUnion)) |field| {
                if (!@hasDecl(Base, field.name)) {
                    @compileError(
                        "Exhaustive mode: event '" ++ field.name ++ "' in " ++
                            @typeName(PayloadUnion) ++ " has no handler in " ++
                            @typeName(Base),
                    );
                }
            }
        }
    }

    return struct {
        receiver: Receiver,

        const Self = @This();

        pub fn emit(self: Self, payload: PayloadUnion) void {
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    if (@hasDecl(Base, name)) {
                        @field(Base, name)(self.receiver, data);
                    }
                },
            }
        }

        pub fn hasHandler(comptime event_name: []const u8) bool {
            return @hasDecl(Base, event_name);
        }
    };
}

pub fn MergeHooks(
    comptime PayloadUnion: type,
    comptime ReceiverTypes: anytype,
) type {
    comptime {
        for (ReceiverTypes) |RT| {
            const Base = UnwrapReceiver(RT);
            for (std.meta.declarations(Base)) |decl| {
                if (@hasDecl(Base, decl.name)) {
                    const DeclType = @TypeOf(@field(Base, decl.name));
                    const info = @typeInfo(DeclType);
                    if (info == .@"fn" and info.@"fn".params.len == 2) {
                        if (fieldIndex(PayloadUnion, decl.name) == null) {
                            @compileError(
                                "Handler '" ++ decl.name ++ "' in " ++ @typeName(Base) ++
                                    " doesn't match any event in " ++ @typeName(PayloadUnion),
                            );
                        }
                    }
                }
            }
        }
    }

    return struct {
        receivers: ReceiverInstances(ReceiverTypes),

        const Self = @This();

        pub fn emit(self: Self, payload: PayloadUnion) void {
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    inline for (0..ReceiverTypes.len) |i| {
                        const Base = UnwrapReceiver(ReceiverTypes[i]);
                        if (@hasDecl(Base, name)) {
                            @field(Base, name)(self.receivers[i], data);
                        }
                    }
                },
            }
        }
    };
}

fn ReceiverInstances(comptime Types: anytype) type {
    var types_arr: [Types.len]type = undefined;
    for (0..Types.len) |i| {
        types_arr[i] = Types[i];
    }
    const types_final = types_arr;
    return @Tuple(&types_final);
}

/// Merge multiple tagged union types into one combined union.
/// Used to combine engine hook payloads with plugin hook payloads.
///
/// Usage:
///   const Merged = MergeHookPayloads(.{
///       engine.HookPayload(Entity),
///       box2d.HookPayload,
///       gfx.HookPayload,
///   });
///
/// The result is a tagged union with all fields from all input unions.
/// Duplicate field names are a compile error.
pub fn MergeHookPayloads(comptime unions: anytype) type {
    const unions_info = @typeInfo(@TypeOf(unions));

    // Count total fields across all unions
    comptime var total_fields: usize = 0;
    inline for (unions_info.@"struct".fields) |tuple_field| {
        const U = @field(unions, tuple_field.name);
        const info = @typeInfo(U);
        if (info != .@"union") @compileError("MergeHookPayloads: expected union type, got " ++ @typeName(U));
        total_fields += info.@"union".fields.len;
    }

    // Build merged fields array
    comptime var field_names: [total_fields][]const u8 = undefined;
    comptime var field_types: [total_fields]type = undefined;
    comptime var field_attrs: [total_fields]std.builtin.Type.UnionField.Attributes = undefined;
    comptime var idx: usize = 0;

    inline for (unions_info.@"struct".fields) |tuple_field| {
        const U = @field(unions, tuple_field.name);
        const u_info = @typeInfo(U).@"union";
        for (u_info.fields) |field| {
            // Check for duplicates
            for (field_names[0..idx]) |existing_name| {
                if (std.mem.eql(u8, existing_name, field.name)) {
                    @compileError("MergeHookPayloads: duplicate field '" ++ field.name ++ "' found in multiple unions");
                }
            }
            field_names[idx] = field.name;
            field_types[idx] = field.type;
            field_attrs[idx] = .{ .@"align" = field.alignment };
            idx += 1;
        }
    }

    // Build tag enum values
    comptime var tag_values: [total_fields]std.math.IntFittingRange(0, if (total_fields > 0) total_fields - 1 else 0) = undefined;
    for (0..total_fields) |i| {
        tag_values[i] = @intCast(i);
    }

    const Tag = @Enum(
        std.math.IntFittingRange(0, if (total_fields > 0) total_fields - 1 else 0),
        .exhaustive,
        &field_names,
        &tag_values,
    );

    return @Union(.auto, Tag, &field_names, &field_types, &field_attrs);
}

fn fieldIndex(comptime T: type, comptime name: []const u8) ?usize {
    for (std.meta.fields(T), 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return i;
    }
    return null;
}

fn fieldNames(comptime T: type) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (std.meta.fields(T), 0..) |field, i| {
            if (i > 0) result = result ++ ", ";
            result = result ++ field.name;
        }
        return result;
    }
}
