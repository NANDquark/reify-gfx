#!/bin/bash

# compile both shader stages into one file, this requires each stage has a unique function name
slangc quad.slang \
    -target spirv \
    -entry vertMain \
    -stage vertex \
    -entry fragMain \
    -stage fragment \
    -reflection-json quad_shader_types.json \
    -o quad.spv

odin run ../tools/shader_types_gen
