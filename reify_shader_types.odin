package reify

// Generated: 2026-02-10 22:01:36.385313456 +0000 UTC
// TODO: automatic padding based on slang offsets & sizes!

import vk "vendor:vulkan"

Quad_Instance :: struct #align (16) {
    pos: [2]f32,
    scale: [2]f32,
    rotation: f32,
    texture_index: u32,
    type: u32,
    data1: u32,
    color: [4]f32,
    uv_rect: [4]f32,
}

Quad_Font :: struct #align (16) {
    px_range: f32,
    _pad0: u32,
    tex_size: [2]u32,
}

QUAD_MAX_INSTANCES :: 102400
Quad_Shader_Data :: struct #align (16) {
    instances: [QUAD_MAX_INSTANCES]Quad_Instance,
}

Quad_Push_Constants :: struct #align (16) {
    projection_view: Mat4f,
    data: vk.DeviceAddress,
}

Quad_Instance_Type :: enum u8 {
	Sprite = 0,
	Rect = 1,
	Circle = 2,
	Triangle = 3,
	MSDF = 4,
}

