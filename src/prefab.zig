/// Prefab lineage tracking components — each records that an entity was
/// instantiated from a prefab and (for children) where inside that
/// prefab's tree the entity sits. Consumed by engine save/load to
/// re-instantiate prefab structure (and bring back non-saveable
/// components like Sprite) on load, then replay saved overrides on top.
///
/// Note on terminology: `SavePolicy.marker` means a zero-size component
/// that's tracked in the save file by presence only. These components
/// carry data and use `SavePolicy.saveable`, so calling them "markers"
/// would conflict with that primitive. They're **tracking components**.
///
/// See `labelle-engine/RFC-SAVE-LOAD-PREFABS.md` for the full design
/// (two-phase load: Phase 1 re-instantiates prefabs, Phase 2 applies
/// saved component data).
///
/// Slice 1 adds the data types only. The engine's save/load mixin
/// handles them as built-ins (same special-case channel as `Position`
/// and `Parent`) — see `src/game/save_load_mixin.zig` in labelle-engine.
/// Phase 1 itself (`spawnFromPrefab`, jsonc bridge tagging,
/// two-phase load semantics) lands in a subsequent slice.
///
/// ## Memory ownership contract for `[]const u8` fields
///
/// `PrefabInstance.path`, `PrefabInstance.overrides`, and
/// `PrefabChild.local_path` are string slices. **The component does
/// not own its backing memory.** The producer (typically
/// `spawnFromPrefab` at spawn time or the save mixin's loader on F9)
/// is responsible for allocating the bytes into an arena whose
/// lifetime covers the entity: the active world's
/// `nested_entity_arena` on load, the prefab asset's own storage at
/// spawn time (strings are typically static literals from the parsed
/// jsonc). Arena reset on scene change frees everything at once — no
/// per-entity free needed, no leak risk.
///
/// `[]const u8` is chosen over a fixed-size `BoundedArray(u8, N)` on
/// purpose: `overrides` is a variable-size JSON blob that can grow
/// with scene-level override complexity, and capping it would
/// silently truncate legitimate content. `path` and `local_path`
/// are typically short (tens of bytes), so the slice overhead is
/// acceptable.
///
/// Lives in labelle-core so both the engine and renderer plugins can
/// observe prefab lineage without reaching across the dep graph.

const save_policy = @import("save_policy.zig");

/// Tracking component attached to the **root** entity of a prefab
/// instantiation.
///
/// `path` is the prefab identifier as declared in the scene jsonc
/// (e.g. `"hydroponics"` for `prefabs/hydroponics.jsonc`). `overrides`
/// is an opaque JSON blob the engine produces at spawn time capturing
/// the instance-specific overrides (e.g. a scene-level `Position`
/// override). On load the engine re-instantiates the prefab from
/// `path`, then replays `overrides` on top — save format v3 uses this
/// as the structural half of the two-phase load.
///
/// Both string fields are **borrowed** — see the "Memory ownership
/// contract" note at the top of this file.
///
/// Not parameterised over `Entity` — the type carries no entity
/// references, just two string slices. The engine's built-in save
/// handler emits `path` and `overrides` as JSON strings and reads
/// them back symmetrically; the game's `ComponentRegistry` does not
/// see this type unless a game explicitly registers it.
pub const PrefabInstance = struct {
    pub const save = save_policy.Saveable(.saveable, @This(), .{});

    path: []const u8 = "",
    overrides: []const u8 = "",
};

/// Tracking component attached to each **child** entity created as
/// part of a prefab instantiation. `root` points back to the
/// `PrefabInstance` root entity; `local_path` records the child's
/// position inside the prefab tree (e.g. `"children[0]"`,
/// `"children[2].children[0]"`).
///
/// On save: emitted alongside the other components on the child
/// entity, so Phase 1 on load can map each newly-spawned child entity
/// back to its saved ID via `(root, local_path)` lookup — that's what
/// makes saved entity refs into prefab children remap correctly.
///
/// `local_path` is **borrowed** — see the "Memory ownership contract"
/// note at the top of this file.
///
/// Parameterised over `Entity` because `root` holds a native ECS
/// entity handle; mirrors `ParentComponent(Entity)`. The engine's
/// save handler serialises `root` as `u64` in the save file and
/// remaps it through the load `id_map`.
pub fn PrefabChild(comptime Entity: type) type {
    return struct {
        pub const save = save_policy.Saveable(.saveable, @This(), .{
            .entity_refs = &.{"root"},
        });

        root: Entity,
        local_path: []const u8 = "",
    };
}
