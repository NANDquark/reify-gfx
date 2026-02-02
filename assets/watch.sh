#!/bin/bash

watchexec -w . -e .slang -w ../tools/shader_types_gen -e .odin "sleep 0.5 && ./shader_compile.sh"
