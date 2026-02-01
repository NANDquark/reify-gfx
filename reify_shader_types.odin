package reify

// Generated: 2026-02-01 06:02:35.716294261 +0000 UTC
// TODO: automatic padding based on slang offsets & sizes!

import vk "vendor:vulkan"

SPRITE_MAX__PAD0 :: 2
Sprite_Instance :: struct #align (16) {
    pos: [2]f32,
    scale: [2]f32,
    rotation: f32,
    texture_index: u32,
    _pad0: [SPRITE_MAX__PAD0]u32,
    color: [4]f32,
}

SPRITE_MAX_SPRITES :: 102400
Sprite_Shader_Data :: struct #align (16) {
    projection_view: Mat4f,
    sprites: [SPRITE_MAX_SPRITES]Sprite_Instance,
}

Sprite_Push_Constants :: struct #align (16) {
    data: vk.DeviceAddress,
}

