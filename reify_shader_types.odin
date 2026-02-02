package reify

// Generated: 2026-02-02 06:19:04.684696124 +0000 UTC
// TODO: automatic padding based on slang offsets & sizes!

import vk "vendor:vulkan"

QUAD_MAX__PAD0 :: 1
Quad_Instance :: struct #align (16) {
    pos: [2]f32,
    scale: [2]f32,
    rotation: f32,
    texture_index: u32,
    type: [2]u16,
    _pad0: [QUAD_MAX__PAD0]u32,
    color: [4]f32,
}

QUAD_MAX_INSTANCES :: 102400
Quad_Shader_Data :: struct #align (16) {
    projection_view: Mat4f,
    instances: [QUAD_MAX_INSTANCES]Quad_Instance,
}

Quad_Push_Constants :: struct #align (16) {
    data: vk.DeviceAddress,
}

Quad_Instance_Type :: enum u8 {
	Sprite = 0,
	Rect = 1,
	Circle = 2,
}

