package reify

// Generated: 2026-01-28 22:31:54.433916737 +0000 UTC

import vk "vendor:vulkan"

// TODO: automatic padding based on slang offsets & sizes!

Vertex :: struct #align (16) {
    pos: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
}

Instance_Data :: struct #align (16) {
    transform: Mat4f,
    texture_index: u32,
    _pad0: [3]u32,
}

Shader_Data :: struct #align (16) {
    projection: Mat4f,
    view: Mat4f,
    light_pos: [4]f32,
    instances: [10240]Instance_Data,
}

Push_Constants :: struct #align (16) {
    shader_data: vk.DeviceAddress,
}

