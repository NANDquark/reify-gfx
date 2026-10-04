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

Reify defaults to Vulkan 1.3. Select the owned Vulkan 1.1 compatibility backend
at build time with `odin run demo -out:/tmp/opencode/reify11-demo
-define:Renderer_Backend=vulkan11`. Explicit selection does not fall back.
Runtime Auto/selection is not implemented yet. See the [GLFW demo](demo/demo.odin) or
[SDL example](examples/sdl_vulkan/main.odin) for `renderer_new(info)` setup.
`renderer_new(info, allocator)` allocates and initializes the compile-time-selected
concrete backend, returning `(^Renderer, bool)`. Failure returns `nil, false` after
cleanup. Plain `Renderer` values are not sufficient backend storage. Pair a
successful allocation with `renderer_free(renderer)`, which releases GPU resources
and storage; do not use `free` on the base pointer. The storage allocator must
remain valid until `renderer_free` returns. `info.resources_allocator` independently selects
the allocator for backend resources.
The host window must outlive the renderer. Platform callbacks are defined in
[reify_platform.odin](reify_platform.odin).

Query the window provider's Vulkan instance extensions before `renderer_new` and handle
provider errors in the host. Supply the borrowed `[]cstring` in
`platform.vulkan.required_instance_extensions`; names must remain valid until
`renderer_new` returns and are not retained. Reify combines, deduplicates, and validates
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

`renderer_new` returns `(renderer, bool)`; `present` returns `bool`; `texture_load` and `font_load` return
`(handle, bool)`. `true` means success. Failures log detailed diagnostics through
Odin's `context.logger`; configure a logger to receive them. Resource loading
never publishes failed handles (the returned index is -1).
Invalid drawing handles or instance-capacity overflow reject the frame through
`present`; a new `start` resets that frame's validity. Driver/presentation failures stop
submission rather than reusing a failed fence or acquired-image semaphore; destroy
the renderer and create a new one. Device-loss recovery is not
automatic. Shared descriptor/font updates wait for GPU readers and may stall.
The Vulkan backend stops GPU use immediately when a resource operation detects
device loss; subsequent resource operations and `present` return `false`.
`renderer_free` stops the renderer, waits until the GPU is idle, and releases all
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

## Vulkan 1.1 compatibility backend

`Renderer_Backend=vulkan11` uses Vulkan 1.1 plus surface extensions and
`VK_KHR_swapchain`, conventional render passes, legacy barriers, binary
semaphores, and fences. It enables no optional device features. The compatibility
SPIR-V 1.3 shader exposes only `Shader` capability: no buffer addresses, bindless
descriptor indexing, draw parameters, int64, or scalar-layout requirement.
Device/surface checks still apply; version support alone is not sufficient.

Each frame binds an ordinary instance storage buffer (dynamic descriptor offsets
select aligned chunks) and one buffer of font records. Texture descriptor pools
grow in 64-set blocks; each texture owns one persistent sampler descriptor.
The texture quota is a policy cap, not an allocation guarantee. Per-stage sampler
limits apply to the one bound sampler, not the total number of loaded textures;
VMA can suballocate their image memory from shared blocks.
Only adjacent compatible texture draws merge, preserving transparency/additive
order, font atlases, camera/screen projection, and scissors. Fonts/instances are
bounded by negotiated storage/index/allocation limits. Shared resource updates
wait for GPU readers; texture staging is bounded and supports non-coherent memory.
The public drawing/resource/lifecycle API is unchanged. Debug capture on this
backend reports unsupported and never requires swapchain transfer-source usage.

Linux x86_64/GLFW, GTX 1070, NVIDIA 580.178.04 is the only tested hardware path.
Core and synchronization validation pass, including forced 17-instance chunks,
descriptor-pool growth, resource failures, and repeated lifecycle transitions.
Both backends produce byte-identical pixels for the integration parity scene:
overlapping/interleaved translucent and additive sprites, UV crops/rotation,
shapes, MSDF text, camera transforms, screen mode, and clipped boundaries.
This readback test uses optional transfer-source support only in its test fixture.
An actual older Vulkan 1.1/1.2 driver/device, AMD, Intel, Windows, and separate
graphics/present families remain untested; stage 3's hardware gate remains open.

Sample CPU costs for 10,000 sprites (unoptimized Odin tests, 8 frames after
warmup; timing is illustrative, not a portable benchmark):

| Backend / texture pattern | Draws/frame | CPU draw-list build | `present` wall time |
| --- | ---: | ---: | ---: |
| Vulkan 1.3 / one texture | 1 | 0.904 ms | 10.548 ms |
| Vulkan 1.3 / alternating two textures | 1 | 0.860 ms | 15.734 ms |
| Vulkan 1.1 / one texture | 1 | 1.166 ms | 11.170 ms |
| Vulkan 1.1 / alternating two textures | 10,000 | 1.984 ms | 11.535 ms |

`present` includes acquisition/presentation pacing and is not GPU execution time.
Compatibility prioritizes parity over bindless throughput. Alternating textures
increase draw calls and CPU batching/recording work; atlas-friendly scenes merge.

## Tests

Run package tests with `odin test . -out:/tmp/opencode/reify-tests`.
The opt-in integration suite creates hidden GLFW windows and requires a display and a
compatible Vulkan device:

```sh
odin test . -out:/tmp/opencode/reify-integration-tests \
  -define:Reify_Integration_Test=true -define:Reify_Enable_Validation=true
```

Windows remain hidden by default. Add `-define:Reify_Integration_Visible_Windows=true`
to show them for debugging and exercise native minimize/restore calls. Hidden mode
tests the same zero-framebuffer transitions through its platform callback without
asking the window manager to minimize or restore windows. This is not a headless
mode: a working display server is still required.

Integration scenarios use fresh window/renderer fixtures and serialize Vulkan
dispatch interception with the package's dispatch-mutating unit tests. They cover
initialization rollback, staging fallback and mixed rendering, resource rollback,
invalid dimensions, capacities, submission failures, pending uploads, and device loss.
Platform scenarios cover repeated renderer lifetimes, resize callbacks, vsync
transitions, minimize/restore, and resource loading during zero-framebuffer startup.

Run the same integration suite on the compatibility backend, forcing chunk
boundaries and enabling synchronization validation on Linux:

```sh
VK_LAYER_VALIDATE_SYNC=1 odin test . -out:/tmp/opencode/reify11-integration \
  -define:Renderer_Backend=vulkan11 -define:Reify_Integration_Test=true \
  -define:Reify_Enable_Validation=true -define:Reify_Vulkan11_Chunk_Instances=17
```

For pixel comparisons, run `integration_backend_parity` separately per backend
with `-define:ODIN_TEST_NAMES=reify.integration_backend_parity` and set
`REIFY_PARITY_OUTPUT` to a different `/tmp/opencode/*.ppm` path per run. Compare
the files with `cmp`; equal framebuffer extents are required. Test readback
requires optional surface transfer-source support. The CPU/draw-call measurement
is `reify.integration_texture_batch_cost` (run without forced small chunks for
the table above). `Reify_Vulkan11_Chunk_Instances` is a build-time maximum chunk
size for testing/tuning, not a runtime backend preference.

## Shader Tooling

Install `watchexec` if you want live shader rebuilds with the `watch` scripts.
`shader_compile` scripts require Slang, SPIR-V Tools, and Odin.
They emit separate `quad_vulkan13.spv` (SPIR-V 1.6/Vulkan 1.3) and
`quad_vulkan11.spv` (SPIR-V 1.3/Vulkan 1.1), audit capabilities/member layouts,
and generate common records plus separate `Quad11_Push_Constants` from reflection.
Backend sources are `quad_vulkan13.slang` and `quad_vulkan11.slang`; record and
shading logic is shared in `quad_common.slang`.

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
