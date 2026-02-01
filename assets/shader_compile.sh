#!/bin/bash

# compile both shader stages into one file, this requires each stage has a unique function name
slangc sprite.slang \
    -target spirv \
    -entry vertMain \
    -stage vertex \
    -entry fragMain \
    -stage fragment \
    -reflection-json sprite_shader_types.json \
    -o sprite.spv

odin run ../tools/shader_types_gen
