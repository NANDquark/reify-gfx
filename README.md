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

`odin run demo -out:/tmp/reify-demo`

Reify uses Vulkan 1.3. See the [GLFW demo](demo/demo.odin) or
[SDL example](examples/sdl_vulkan/main.odin) for `init(renderer, info)` setup.
The host window must outlive the renderer. Platform callbacks are defined in
[reify_platform.odin](reify_platform.odin).

Query the window provider's Vulkan instance extensions before `init` and handle
provider errors in the host. Supply the borrowed `[]cstring` in
`platform.vulkan.required_instance_extensions`; names must remain valid until
`init` returns and are not retained. Reify combines, deduplicates, and validates
them. The host owns callback state and the window; Reify destroys a successfully
created surface through the adapter before destroying its instance.

`window_resize` updates logical drawing dimensions/projection only (unchanged
sizes are a no-op). Pixel-size polling, presentation results, and vsync changes
drive swapchain recreation. Zero pixel size defers presentation until restored.

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
