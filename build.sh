#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pushd "$script_dir" >/dev/null

cmakeArgs=(
  -S lib/msdfgen
  -B lib/msdfgen/build
  -DMSDFGEN_CORE_ONLY=OFF
  -DMSDFGEN_USE_VCPKG=OFF
  -DMSDFGEN_DISABLE_SVG=ON
  -DMSDFGEN_USE_SKIA=OFF
  -DCMAKE_BUILD_TYPE=Release
)

if [[ -n "${VCPKG_ROOT:-}" ]]; then
  cmakeArgs+=(-DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake")
fi

if [[ -n "${FREETYPE_PATH:-}" ]]; then
  freetypeInclude="$FREETYPE_PATH/include"
  if [[ ! -d "$freetypeInclude" ]]; then
    echo "ERROR: FREETYPE_PATH is set to '$FREETYPE_PATH' but '$freetypeInclude' is missing." >&2
    exit 1
  fi

  freetypeLib=""
  for pattern in "$FREETYPE_PATH/lib/libfreetype"* "$FREETYPE_PATH/lib64/libfreetype"*; do
    for candidate in $pattern; do
      if [[ -f "$candidate" ]]; then
        freetypeLib="$candidate"
        break 2
      fi
    done
  done

  cmakeArgs+=("-DFREETYPE_INCLUDE_DIRS=$freetypeInclude")
  if [[ -n "$freetypeLib" ]]; then
    cmakeArgs+=("-DFREETYPE_LIBRARY=$freetypeLib")
  else
    echo "WARNING: FREETYPE_PATH set but no libfreetype.* was found under $FREETYPE_PATH/lib*; CMake might still fail." >&2
  fi
fi

cmake "${cmakeArgs[@]}"
cmake --build lib/msdfgen/build --config Release

pushd lib/vma >/dev/null
premake5 --vk-version=3 gmake
pushd build/make/linux >/dev/null
make config=release_x86_64
popd >/dev/null
popd >/dev/null

popd >/dev/null
