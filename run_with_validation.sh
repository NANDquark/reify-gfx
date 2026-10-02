#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
demo_tmp_dir="$(mktemp -d /tmp/reify-validation.XXXXXX)"
demo_binary="$demo_tmp_dir/demo"
trap 'rm -f -- "$demo_binary"; rmdir -- "$demo_tmp_dir"' EXIT
odin build "$script_dir/demo" -out:"$demo_binary" -define:Reify_Enable_Validation=true
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation "$demo_binary"
