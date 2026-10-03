# Reify - 2D Graphics Rendering on GPU

## Prerequisites

External dependencies:
- Odin compiler
- Vulkan SDK (includes slangc)
- SPIR-V Tools (`spirv-val`, `spirv-dis`) for the shader contract audit
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

## Vulkan 1.3 requirements and resource failures

Reify requires Vulkan 1.3, swapchain presentation, buffer device addresses,
dynamic rendering, synchronization2, runtime descriptor arrays, non-uniform
sampled-image indexing, and the generated shader's draw-parameters capability.
Incompatible devices are filtered before activation; integrated GPUs are eligible.
The renderer does not silently select another backend.

`effective_limits(renderer)` reports fixed texture/font/instance capacities and
the reusable staging size. Texture capacity includes one reserved fallback slot;
fonts also consume a texture slot. Texture input must contain exactly
`width * height` RGBA pixels with positive, supported dimensions.
`memory_summary(renderer)` reports heaps once, host-visible/device-local properties,
allocator block bytes, and optional advisory budget/headroom telemetry. Heap size
is not free memory, and a budget is not an allocation guarantee.

`init` and `present` return `bool`; `texture_load` and `font_load` return
`(handle, bool)`. `true` means success. Failures log detailed diagnostics through
Odin's `context.logger`; configure a logger to receive them. Resource loading
never publishes failed handles (the returned index is -1).
Invalid drawing handles or instance-capacity overflow reject the frame through
`present`; a new `start` resets that frame's validity. Driver/presentation failures stop
submission rather than reusing a failed fence or acquired-image semaphore; destroy
the renderer before explicitly initializing again. Device-loss recovery is not
automatic. Shared descriptor/font updates wait for GPU readers and may stall.
The Vulkan backend stops GPU use immediately when a resource operation detects
device loss; subsequent resource operations and `present` return `false`.
`destroy` stops the renderer, waits until the GPU is idle, and releases all
resources; it returns nothing. An idle-wait failure other than device loss is
fatal, since GPU completion cannot be established. Call it once when finished
and keep the host window/callback state alive until it returns.
Upload wait failures retain their unpublished resources and stop the renderer
when completion cannot be established.
Debug capture returns false unless the actual swapchain has transfer-source usage.
Minimized/zero-extent frames and out-of-date acquisition defer presentation and
return `true`, not failure.

## Expected Compatibility

Vulkan 1.3 is the baseline but devices must satisfy the features,
resource limits, texture formats, and surface requirements described above.
Compatible discrete and integrated GPUs are eligible. Unsupported configurations
are rejected with diagnostics.

| Configuration | Expected compatibility / validation status |
| --- | --- |
| NVIDIA Turing and newer (GeForce RTX 20 series from ~2018, GTX 16 series from ~2019, and later generations) | Expected to meet the renderer's feature requirements with a suitable driver; generation-specific hardware/runtime validation still needed. |
| NVIDIA Pascal (GeForce GTX 10 series, ~2016) | Expected baseline with a suitable Vulkan 1.3 driver; one Linux/GLFW configuration validated. Other cards and drivers still need testing. |
| NVIDIA Maxwell and older (GeForce GTX 900 series, ~2014–2015, and earlier generations) | No compatibility assumption; Vulkan version alone does not establish the required feature/limit support. Runtime capability checks and hardware testing are required. |
| AMD and Intel discrete/integrated GPUs, including unified-memory systems | Eligible when runtime requirements pass; real-device validation still needed. |
| Windows x86_64 | Build tooling exists; build, shader tooling, and runtime validation still needed. |

The validated NVIDIA sample is a GTX 1070 on Linux x86_64, driver 580.178.04,
Vulkan 1.4.312, using GLFW. Package tests, lifecycle smoke, and robustness
integration pass with core/synchronization validation; robustness integration
also passes GPU-assisted validation. This does not certify an entire generation.
Older drivers and different OS/window-system combinations need separate testing,
even on newer GPUs. The runtime requirement checks remain authoritative.

## Tests

Run package tests with `odin test . -out:/tmp/opencode/reify-tests`.
The opt-in integration suite creates GLFW windows and requires a display and a
compatible Vulkan device:

```sh
odin test . -out:/tmp/opencode/reify-integration-tests \
  -define:Reify_Integration_Test=true -define:Reify_Enable_Validation=true
```

Integration scenarios use fresh window/renderer fixtures and serialize Vulkan
dispatch interception with the package's dispatch-mutating unit tests. They cover
initialization rollback, staging fallback and mixed rendering, resource rollback,
invalid dimensions, capacities, submission failures, pending uploads, and device loss.
Platform scenarios cover repeated renderer lifetimes, resize callbacks, vsync
transitions, minimize/restore, and resource loading during zero-framebuffer startup.

## Shader Tooling

Install `watchexec` if you want live shader rebuilds with the `watch` scripts.
`shader_compile` scripts require Slang, SPIR-V Tools, and Odin.

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
