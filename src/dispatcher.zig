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
            if (!@hasField(PayloadUnion, decl.name)) {
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
                        // Discard any return value — the single-receiver
                        // dispatcher has no "consumable" loop to break out
                        // of, so a `bool` return on a notification handler
                        // (or a future consumable handler installed here as
                        // the sole listener) is dropped. The
                        // multi-receiver `MergeHooks.emit` is the one that
                        // honors the consumable flavor (RFC-PLUGIN-EVENTS
                        // O4, phase 7).
                        _ = @field(Base, name)(self.receiver, data);
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
        // This validation walks every receiver × every declaration.
        // Headroom over Zig's default 1000-branch eval quota so projects
        // with many hook receivers don't hit a non-obvious "quota
        // exceeded" wall as their hook surface grows. The per-event
        // lookup is `@hasField` (O(1)), so the cost here is just the
        // bounded receiver × declaration product.
        @setEvalBranchQuota(10000);
        for (ReceiverTypes) |RT| {
            const Base = UnwrapReceiver(RT);
            for (std.meta.declarations(Base)) |decl| {
                if (@hasDecl(Base, decl.name)) {
                    const DeclType = @TypeOf(@field(Base, decl.name));
                    const info = @typeInfo(DeclType);
                    if (info == .@"fn" and info.@"fn".params.len == 2) {
                        if (!@hasField(PayloadUnion, decl.name)) {
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

        /// Dispatch `payload` to every receiver that declares a handler for
        /// the active variant.
        ///
        /// Two flavors, chosen at comptime per variant
        /// (RFC-PLUGIN-EVENTS O4, phase 7):
        ///
        /// 1. **Notification (default).** The variant's payload struct has
        ///    no `consumable` decl (or it is `false`). Every receiver with
        ///    a matching declaration is invoked, regardless of return
        ///    value. This is the historical shape — `void` handlers,
        ///    unconditional fan-out, scanner-sort order
        ///    (`labelle-assembler/src/main_zig.zig:2854-2870`).
        ///
        /// 2. **Consumable (opt-in).** The variant's payload struct
        ///    declares `pub const consumable = true;` (RFC §1). Handlers
        ///    return `bool`; the dispatcher breaks the loop the moment a
        ///    handler returns `true`. The assembler emits the
        ///    consumable-event handlers in priority-descending order
        ///    (RFC O3 / phase 7), so the highest-priority consumer wins.
        ///
        /// The two paths coexist on a single `emit` entry — the flavor is
        /// a property of the payload (RFC §1), not of the call site. A
        /// receiver that returns `bool` from a notification handler is
        /// accepted; the return value is discarded.
        pub fn emit(self: Self, payload: PayloadUnion) void {
            // Comptime branch budget for the `switch (payload) { inline else }`
            // over PayloadUnion × the `inline for` over ReceiverTypes. Per
            // iteration cost is small (`@hasDecl`, `@field`, `UnwrapReceiver`)
            // but the product climbs fast — flying-platform-labelle (11
            // receivers × ~30 variants ≈ 330 iterations + per-iteration
            // comptime probes) trips Zig's default 1000-branch wall.
            // 100k is comfortable headroom for any realistic project; pure
            // comptime, no runtime cost.
            @setEvalBranchQuota(100000);
            switch (payload) {
                inline else => |data, tag| {
                    const name = @tagName(tag);
                    const VariantType = @TypeOf(data);
                    const variant_consumable = comptime isConsumable(VariantType);
                    inline for (0..ReceiverTypes.len) |i| {
                        const Base = UnwrapReceiver(ReceiverTypes[i]);
                        if (@hasDecl(Base, name)) {
                            if (variant_consumable) {
                                const handled = @field(Base, name)(self.receivers[i], data);
                                if (handled) break;
                            } else {
                                _ = @field(Base, name)(self.receivers[i], data);
                            }
                        }
                    }
                },
            }
        }
    };
}

/// True when `T` is a struct that declares `pub const consumable = true;`.
/// The marker selects the return-aware dispatch path (RFC-PLUGIN-EVENTS O4,
/// phase 7). Any other shape — no decl, a `false` decl, a non-struct payload
/// — stays on the notification path.
fn isConsumable(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (!@hasDecl(T, "consumable")) return false;
    const decl_type = @TypeOf(@field(T, "consumable"));
    if (decl_type != bool and decl_type != comptime_int) return false;
    return @field(T, "consumable") == true;
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
    // The duplicate-field check below is O(N²) over the combined
    // variant set; with engine `Events` (labelle-engine#578, 14
    // variants) plus a couple of plugins, N can climb past 30 and
    // each `std.mem.eql(u8, ...)` call inside the inner loop trips
    // Zig's default 1000-branch comptime evaluation cap. Bump it
    // here so every caller picks it up automatically — the
    // alternative (every project's generated main.zig sets its own
    // quota) duplicates the workaround across the toolkit.
    @setEvalBranchQuota(20000);
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
