#!/bin/bash

watchexec -w . -e .slang -w ../tools/shader_types_gen -e .odin "sleep 1 && ./shader_compile.sh"
