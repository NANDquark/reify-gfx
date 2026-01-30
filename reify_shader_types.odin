package reify

// Generated: 2026-01-30 04:25:40.568014374 +0000 UTC
// TODO: automatic padding based on slang offsets & sizes!

import vk "vendor:vulkan"

Vertex :: struct #align (16) {
    pos: [3]f32,
    uv: [2]f32,
}

Instance_Data :: struct #align (16) {
    model: Mat4f,
    texture_index: u32,
    _pad0: [3]u32,
}

Shader_Data :: struct #align (16) {
    projection: Mat4f,
    view: Mat4f,
    instances: [1280]Instance_Data,
}

Push_Constants :: struct #align (16) {
    shader_data: vk.DeviceAddress,
}

