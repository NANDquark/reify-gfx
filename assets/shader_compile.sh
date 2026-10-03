#!/bin/bash
set -euo pipefail

# compile both shader stages into one file, this requires each stage has a unique function name

slangc quad_vulkan13.slang \
    -target spirv \
    -profile spirv_1_6 \
    -entry vertMain \
    -stage vertex \
    -entry fragMain \
    -stage fragment \
    -reflection-json quad_shader_types.json \
    -o quad_vulkan13.spv

slangc quad_vulkan11.slang -target spirv \
    -profile spirv_1_3 \
    -entry vertMain \
    -stage vertex \
    -entry fragMain \
    -stage fragment \
    -reflection-json quad_vulkan11_shader_types.json \
    -o quad_vulkan11.spv

odin run ../tools/validate_quad_shader
odin run ../tools/shader_types_gen
