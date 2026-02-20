# Reify - 2D Graphics Rendering on GPU

## Prerequisites

External dependencies (keep these generic to your platform/package manager):

- Odin compiler
- Vulkan runtime/loader (and Vulkan SDK if you need validation layers and C headers)
- CMake
- A C++ toolchain (MSVC on Windows, GCC/Clang on Linux)
- `slangc` for shader compilation
- `watchexec` (optional, for shader watch mode)

## Initialize Submodules

```
git submodule update --init --recursive
```

## Build Internal `./lib` Dependencies

### `lib/msdfgen` (Windows + Linux)

```
cmake -S lib/msdfgen -B lib/msdfgen/build -DMSDFGEN_CORE_ONLY=OFF -DMSDFGEN_USE_VCPKG=OFF -DMSDFGEN_DISABLE_SVG=ON -DMSDFGEN_USE_SKIA=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build lib/msdfgen/build --config Release
```

This should produce:

- `lib/msdfgen/build/Release/msdfgen-c.lib` (Windows) or `lib/msdfgen/build/libmsdfgen-c.a` (Linux)
- `lib/msdfgen/build/Release/msdfgen-ext-c.lib` (Windows) or `lib/msdfgen/build/libmsdfgen-ext-c.a` (Linux)

### `lib/vma` (Windows x86_64)

Run from a VS x64 developer shell (or ensure `premake5`, `cl.exe`, and `lib.exe` are in `PATH`):

```
cd lib/vma
premake5 --vk-version=3 vs2022
cd build
build.bat
cd ../..
```

This should produce:

- `lib/vma/vma_windows_x86_64.lib`

### `lib/vma` (Linux)

Keep the existing shell workflow from `lib/vma/README.md` (Premake + make).
The Odin import expects a generated `lib/vma/libvma_linux_x86_64.a` on Linux x86_64.

## Build And Run Demo

Linux:

```
odin build demo
./demo.bin
```

Windows:

```
odin build demo
demo.exe
```

## Validation-Layer Run

Linux shell:

```
./run_with_validation.sh
```

Windows PowerShell:

```
run_with_validation.ps1
```

## Shader Tooling

Linux shell:

```
cd assets
./shader_compile.sh
./watch.sh
```

Windows PowerShell:

```
powershell -ExecutionPolicy Bypass -File .\assets\shader_compile.ps1
powershell -ExecutionPolicy Bypass -File .\assets\watch.ps1
```

## Troubleshooting

- Missing `.lib`/`.a` artifacts: rebuild `lib/msdfgen` and `lib/vma` and confirm output paths above.
- Missing Vulkan loader/runtime: install Vulkan runtime and ensure loader is available (`vulkan-1.dll` on Windows, `libvulkan.so.1` on Linux).
- Missing validation layer: install Vulkan SDK/layers and re-run validation scripts.
- Missing `premake5`/`cmake`/MSVC in `PATH`: open the correct developer shell or update environment configuration before building.
