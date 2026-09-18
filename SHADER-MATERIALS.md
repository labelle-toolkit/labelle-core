# Game-owned shader materials

`shader_material.zig` defines the generic contract consumed by the renderer, engine and generated game packages. It deliberately contains no water, fog or lamp semantics.

## Descriptor and values

Descriptors provide renderer-specific fragment binaries, named parameters, texture bindings and alpha/additive blending. They use the renderer's sprite vertex format. Parameter kinds are `scalar`, `vec2`, `vec3`, `vec4`, and `mat4`; `count` is the number of elements. Callers provide tightly packed floats. Backends pad scalar/vector uniforms to vec4 GPU registers; matrices remain mat4.

Empty defaults mean zero initialization. Nonempty defaults and updates must match the exact typed length, and all floats must be finite. Names must be ASCII shader identifiers of at most 63 bytes, unique across parameters and textures. `s_tex`, `u_material_rect` and BGFX predefined names are reserved. `u_material_rect` is set per draw from the sprite's atlas region; `s_tex` samples the sprite texture.

The baseline contract permits 16 parameters, four auxiliary textures and 64 uniform vec4 registers including the atlas rectangle. These are validation ceilings, not a claim that every backend supports every descriptor. Unsupported renderers and shader creation failures must return errors.

## Ownership

`createShaderMaterial` borrows its descriptor only for the call. Implementations copy data retained afterward and own GPU resources. Texture handles are borrowed; the caller must keep the underlying resources resident. The engine layer handles catalog pinning for game-facing bindings.

`Id` is an opaque 64-bit generation-bearing handle. `.none` means absent. It is runtime state, never authored in a prefab. Destroy is idempotent; stale handles must not mutate a later instance reusing a slot. Renderer teardown invalidates all IDs. Higher layers must recreate instances after device/context loss or report the invalidation without drawing unrelated state.

## Optional backend API

- `shaderMaterialSupported() bool`
- `createShaderMaterial(Descriptor) !Id`
- `setShaderParameter(Id, name, []const f32) !void`
- `setShaderTexture(Id, name, BackendTextureId) !void`
- `destroyShaderMaterial(Id) void`

The existing `drawTextureProMaterial` call carries `Material.shader`. A live game shader takes precedence over the curated effect. Unsupported or stale shader instances draw the ordinary sprite as fallback. Backends without the complete API still compile and report unsupported creation/update operations.

## Compatibility

`backend_contract.MATERIAL_CONTRACT_VERSION` is **2**. `Material` grows from 36 to 48 bytes, with an eight-byte aligned shader handle at offset 40. This is an ABI change: all producers, adapters and renderers exchanging the payload must use the same core type and rebuild together. Required primitive draw signatures and their version remain unchanged; consumers with a separate material marshalling ABI must check this material version explicitly.

Existing curated materials and the old water contract remain available while game-side migration is verified. Removing the latter is a separately reviewed breaking cleanup, not implied by the presence of this API.
