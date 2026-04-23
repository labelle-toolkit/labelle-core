/// Prefab lineage components — universal markers that an entity was
/// instantiated from a prefab, plus the tree position inside that prefab
/// for child entities. Consumed by engine save/load to re-instantiate
/// prefab structure (and bring back non-saveable components like Sprite)
/// on load, then replay saved overrides on top.
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
/// Lives in labelle-core so both the engine and renderer plugins can
/// observe prefab lineage without reaching across the dep graph.

const save_policy = @import("save_policy.zig");

/// Marker attached to the **root** entity of a prefab instantiation.
///
/// `path` is the prefab identifier as declared in the scene jsonc
/// (e.g. `"hydroponics"` for `prefabs/hydroponics.jsonc`). `overrides`
/// is an opaque JSON blob the engine produces at spawn time capturing
/// the instance-specific overrides (e.g. a scene-level `Position`
/// override). On load the engine re-instantiates the prefab from
/// `path`, then replays `overrides` on top — save format v3 uses this
/// as the structural half of the two-phase load.
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

/// Marker attached to each **child** entity created as part of a
/// prefab instantiation. `root` points back to the `PrefabInstance`
/// root entity; `local_path` records the child's position inside the
/// prefab tree (e.g. `"children[0]"`, `"children[2].children[0]"`).
///
/// On save: emitted alongside the other components on the child
/// entity, so Phase 1 on load can map each newly-spawned child entity
/// back to its saved ID via `(root, local_path)` lookup — that's what
/// makes saved entity refs into prefab children remap correctly.
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
