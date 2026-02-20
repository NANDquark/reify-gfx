# Reify - 2D Graphics Rendering on GPU

## Prerequisites

External dependencies:
- Odin compiler
- Vulkan SDK (includes slangc)
- CMake
- Premake5
- A C++ toolchain (MSVC on Windows, GCC/Clang on Linux)
- `vcpkg` (Windows only, set VCPKG_ROOT or put it on PAHT)
- `watchexec` (optional, for shader watch mode)

## Initialize Submodules

```
git submodule update --init --recursive
```

## Build Internal `./lib` Dependencies

Windows (PowerShell):

```powershell
./build.ps1
```

Linux (shell):

```bash
./build.sh
```

These scripts build both internal dependencies (`lib/msdfgen` and `lib/vma`).
Expected outputs include:

- `lib/msdfgen/build/Release/msdfgen-c.lib` (Windows) or `lib/msdfgen/build/libmsdfgen-c.a` (Linux)
- `lib/msdfgen/build/Release/msdfgen-ext-c.lib` (Windows) or `lib/msdfgen/build/libmsdfgen-ext-c.a` (Linux)
- `lib/vma/vma_windows_x86_64.lib` (Windows)
- `lib/vma/libvma_linux_x86_64.a` (Linux x86_64)

## Build And Run Demo

`odin run demo`

## Shader Tooling

Install `watchexec` if you want live shader rebuilds with the `watch` scripts.
`shader_compile` scripts only require `slangc`.

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
- `watchexec` not found when running watch scripts: install `watchexec` with your platform package manager, then rerun `assets/watch.sh` or `assets/watch.ps1`.
- Missing Vulkan loader/runtime: install Vulkan runtime and ensure loader is available (`vulkan-1.dll` on Windows, `libvulkan.so.1` on Linux).
- Missing validation layer: install Vulkan SDK/layers and re-run validation scripts.
- Missing build tools required by `build.ps1`/`build.sh`: open the correct developer shell or install/configure the required toolchain and rerun the script.
