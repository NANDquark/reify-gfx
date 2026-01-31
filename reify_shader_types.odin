package reify

// Generated: 2026-01-31 19:35:20.953617785 +0000 UTC
// TODO: automatic padding based on slang offsets & sizes!

import vk "vendor:vulkan"

Vertex :: struct #align (16) {
    pos: [3]f32,
    uv: [2]f32,
}

MAX__PAD0 :: 3
Instance_Data :: struct #align (16) {
    model: Mat4f,
    texture_index: u32,
    _pad0: [MAX__PAD0]u32,
}

MAX_INSTANCES :: 1280
Shader_Data :: struct #align (16) {
    projection: Mat4f,
    view: Mat4f,
    instances: [MAX_INSTANCES]Instance_Data,
}

Push_Constants :: struct #align (16) {
    shader_data: vk.DeviceAddress,
}

