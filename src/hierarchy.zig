/// Hierarchy components — universal parent-child relationship types.
/// These live in core so both engine and renderer plugins can use them.

const std = @import("std");
const save_policy = @import("save_policy.zig");

/// Parent component — establishes parent-child hierarchy for position inheritance.
/// Parameterized by Entity type since we don't know the ECS backend at definition time.
///
/// Marked `.saveable` so parent-child relationships survive save/load;
/// `ChildrenComponent` is transient and rebuilt from `ParentComponent`
/// on load.
pub fn ParentComponent(comptime Entity: type) type {
    return struct {
        pub const save = save_policy.Saveable(.saveable, @This(), .{
            .entity_refs = &.{"entity"},
        });

        entity: Entity,
        inherit_rotation: bool = false,
        inherit_scale: bool = false,
    };
}

/// Children component — tracks child entities for hierarchical operations.
/// Automatically managed by the engine when Parent components are added/removed.
///
/// Backed by an `ArrayListUnmanaged` — there is no fixed cap, so a slot-heavy
/// entity (a room with many fixtures, a workstation with many storages) never
/// silently loses children (the old `MAX_CHILDREN = 16` buffer dropped
/// overflow, orphaning entities from teardown — #657).
///
/// **Heap ownership contract — single owner.** The list owns a heap
/// allocation, so exactly ONE owner must `deinit` it before the component is
/// dropped. The ECS backends (shipped and `MockEcsBackend`) are dumb value
/// stores that run NO destructors — deliberately, so there's never a second
/// freer racing the owner. The owner is:
///
///   * for a Game: the **engine** — the sole hierarchy manager — which calls
///     `deinit` at every choke point a `ChildrenComponent` is dropped
///     (entity-destroy, component-remove, ECS-reset, load-rebuild teardown);
///   * for a raw backend used without the engine (e.g. a core unit test on
///     `MockEcsBackend`): the **caller**, which must `deinit` the stored
///     component itself before it is dropped — i.e. before dropping the
///     entity / backend, AND before `removeComponent` or an `addComponent`
///     that overwrites an existing `ChildrenComponent` at the same entity
///     (both drop the old value by value, so the caller must `deinit` the
///     `getComponent` value first or the old list leaks).
///
/// A backend that auto-ran component destructors would double-free the first
/// case (engine tests run a Game on `MockEcsBackend`), which is why the
/// backends stay dumb. The `deinit` convention is `pub fn deinit(self,
/// allocator)`; the allocator MUST be the one `addChild` used.
///
/// `ArrayListUnmanaged` (not managed) is deliberate: it holds no allocator
/// pointer, so the ECS can bit-copy the component during pool relocation (a
/// move) without aliasing an allocator — only the drop path needs the
/// allocator, which callers supply.
pub fn ChildrenComponent(comptime Entity: type) type {
    return struct {
        const Self = @This();

        children: std.ArrayListUnmanaged(Entity) = .empty,

        pub fn getChildren(self: *const Self) []const Entity {
            return self.children.items;
        }

        /// Append `child`. OOM panics — matching the codebase's storage
        /// convention (`catch @panic("OOM")`); a child list outgrowing memory
        /// is unrecoverable, and silently dropping it is the very bug this
        /// replaces.
        pub fn addChild(self: *Self, allocator: std.mem.Allocator, child: Entity) void {
            self.children.append(allocator, child) catch @panic("OOM: ChildrenComponent.addChild");
        }

        pub fn removeChild(self: *Self, child: Entity) void {
            for (self.children.items, 0..) |c, i| {
                if (c == child) {
                    _ = self.children.swapRemove(i);
                    return;
                }
            }
        }

        pub fn count(self: *const Self) usize {
            return self.children.items.len;
        }

        /// Free the backing allocation. Call before the component is dropped —
        /// entity-destroy, component-remove, ECS-reset, or load-rebuild
        /// teardown — see the heap-ownership contract above. The allocator MUST
        /// be the one `addChild` was called with.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.children.deinit(allocator);
        }
    };
}
