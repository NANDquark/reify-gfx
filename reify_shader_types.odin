package reify

// Generated: 2026-02-02 06:16:19.705272507 +0000 UTC
// TODO: automatic padding based on slang offsets & sizes!

import vk "vendor:vulkan"

SPRITE_MAX__PAD0 :: 1
Sprite_Instance :: struct #align (16) {
    pos: [2]f32,
    scale: [2]f32,
    rotation: f32,
    texture_index: u32,
    type: [2]u16,
    _pad0: [SPRITE_MAX__PAD0]u32,
    color: [4]f32,
}

SPRITE_MAX_INSTANCES :: 102400
Sprite_Shader_Data :: struct #align (16) {
    projection_view: Mat4f,
    instances: [SPRITE_MAX_INSTANCES]Sprite_Instance,
}

Sprite_Push_Constants :: struct #align (16) {
    data: vk.DeviceAddress,
}

Sprite_Instance_Type :: enum u8 {
	Sprite = 0,
	Rect = 1,
	Circle = 2,
}

