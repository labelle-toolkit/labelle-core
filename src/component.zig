/// Component lifecycle payload — passed to onAdd, onReady, onRemove callbacks.
/// Entity type is comptime so plugins aren't locked to any specific type.
///
/// game_ptr is NOT included — plugins receive the game reference once at init
/// time via the create() protocol and store it internally.
pub fn ComponentPayload(comptime Entity: type) type {
    return struct {
        entity_id: Entity,
    };
}
