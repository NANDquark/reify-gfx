#!/bin/bash

# compile both shader stages into one file, this requires each stage has a unique function name
slangc shader.slang \
    -target spirv \
    -entry vertMain \
    -stage vertex \
    -entry fragMain \
    -stage fragment \
    -reflection-json shader_types.json \
    -o shader.spv

odin run ../tools/shader_types_gen
