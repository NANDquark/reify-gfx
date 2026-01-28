package reify

import vk "vendor:vulkan"

// TODO: automatic padding based on slang offsets & sizes!

Instance_Data :: struct #align (16) {
    transform: Mat4f,
    texture_index: u32,
}

Shader_Data :: struct #align (16) {
    projection: Mat4f,
    view: Mat4f,
    light_pos: [4]f32,
    instances: [3]Instance_Data,
}

Push_Constants :: struct #align (16) {
    shader_data: vk.DeviceAddress,
}

