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
    var fields: [Types.len]std.builtin.Type.StructField = undefined;
    for (0..Types.len) |i| {
        const name = std.fmt.comptimePrint("{d}", .{i});
        fields[i] = .{
            .name = name,
            .type = Types[i],
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Types[i]),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
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
