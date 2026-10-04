# Vulkan 1.1 compatibility renderer

## Status

`complete` — Stage-3 implementation and validation on the available Linux/GLFW
GTX 1070 configuration are complete. The Vulkan 1.1 backend owns conventional
render passes, legacy synchronization, frame-owned storage-buffer chunks,
persistent texture descriptors/growable pools, ordered batching, and uploads.
Its SPIR-V 1.3 shader requires only the `Shader` capability.

Public drawing procedures, font records/layout, color conversion, and the common
`Renderer` base struct live in `reify.odin`. Both concrete backends embed this base
first with `using`. Their constant `Renderer_Backend_Interface` tables accept
`^Renderer` and hold concrete procedures directly through Odin subtype polymorphism.
`renderer_new(info, allocator)` allocates the build-selected concrete storage;
the facade dispatches through `backend_type`. `renderer_free` releases GPU state
and storage. The facade preserves the storage allocator across backend cleanup.
GPU orchestration, uploads, batching, and capture remain backend-owned.

Available validation covers both backends, initialization/resource failures,
allocation rollback, repeated lifetimes, resize/minimize, descriptor-pool growth,
and forced 17-instance Vulkan 1.1 chunks. The representative parity scene produces
byte-identical readback images. Package and integration suites, GLFW demo and SDL
example compile checks, and shader-audit tests pass. Integration runs include
core and synchronization validation. CPU batch-cost measurements/reproduction
are in README.

Current verification totals: 26 Vulkan 1.1 and 30 Vulkan 1.3 package tests;
46 and 49 tests respectively with the opt-in integration suites. The Vulkan 1.1
integration run forces 17-instance chunks. All three shader-audit tests pass.

Completion is not a hardware compatibility certification. An actual older Vulkan
1.1/1.2 driver/device, AMD, Intel, Windows, and separate graphics/present queue
families remain unverified follow-up coverage. Requesting API 1.1 on the available
modern NVIDIA driver does not establish those results. Runtime Auto/selection
remains stage 4 and is not implemented here.

Implementation stage 3, after [02-vulkan13-robustness.md](02-vulkan13-robustness.md).
See [00-roadmap.md](00-roadmap.md) for shared decisions and gates.

## Intent

Add an alternate `vulkan11` backend for older Windows/Linux gaming hardware.
Select it through the existing compile-time `Renderer_Backend` config:

```sh
odin run demo -out:/tmp/opencode/reify11-demo -define:Renderer_Backend=vulkan11
```

This document records the completed stage-3 design and remaining hardware coverage.
Retain only Reify-owned `vulkan13` and `vulkan11` backends; retire SDL GPU.
Applications should use the same public drawing, texture, font, camera, and
scissor APIs with either Vulkan backend. The command above describes an interim
build option; [04-renderer-selection.md](04-renderer-selection.md) plans runtime
`auto` / `vulkan13` / `vulkan11` configuration to replace it in a later stage.

Preserve the useful parts of the “No Graphics API” approach: flat instance data,
vertex pulling, few pipelines, and bulk uploads. The compatibility backend trades
GPU pointers and bindless texture access for a few persistent buffer bindings and
additional texture batches. It does not need a general graphics abstraction layer.

## Capability baseline

- Vulkan 1.1 loader and physical device, platform surface extensions, and
  `VK_KHR_swapchain`.
- Conventional render passes/framebuffers, `vkCmdPipelineBarrier`,
  `vkQueueSubmit`, binary semaphores, and fences.
- Read-only storage buffers in vertex/fragment shaders, an index buffer, and one
  combined image sampler per texture batch.
- No required buffer device addresses, descriptor indexing, runtime descriptor
  arrays, variable descriptor counts, update-after-bind, synchronization2,
  dynamic rendering, timeline semaphores, shader int64, or scalar block layout.
- No required anisotropic filtering or draw-parameter shader built-ins. Keep
  samplers non-anisotropic and derive geometry from the vertex index.

Vulkan version alone is not sufficient. Check descriptor limits, storage-buffer
range/alignment, push-constant size, framebuffer/image dimensions, supported
formats and filtering, memory types, and presentation capabilities. Choose
capacities from those limits rather than copying the current fixed allocations.
Do not promise a user-coverage percentage until the actual requirements have been
tested against representative devices and drivers.

## Backend integration

The relevant starting points are `reify.odin` (config and dispatch),
`reify_vulkan13.odin` (renderer state and implementation),
`reify_vulkan_helpers.odin`, and `assets/quad_vulkan13.slang`.

1. Accept `vulkan11` in config validation and select its `Renderer_Backend_Interface`
   procedure table for public dispatch. SDL GPU dispatch is removed in stage 1.
   Include the internal loader lifecycle,
   instance access, surface setup, resource loading, metrics, frame submission,
   resize, vsync, logging, and destruction.
2. Keep the public `Renderer` base struct and common declarations in
   `reify.odin`. Keep common allocator/platform ownership, lifecycle flags,
   logical dimensions, and performance statistics in `Renderer`, embedded
   first with `using` in each backend state. Backend procedures take their own
   state pointers and populate `Renderer_Backend_Interface` base-pointer entries
   directly, without explicit casts or adapters.
   Extract the Vulkan instance/device/queue context,
   backend capabilities and limits, VMA allocator, surface handle, GPU resources,
   swapchain, frame contexts/index, descriptors, pipelines, command pool, shader
   module, and pending-upload state into `Vulkan13_Rendererer` in
   `reify_vulkan13.odin` and independent `Vulkan11_Renderer` storage in
   `reify_vulkan11.odin`. `renderer_new` allocates only the build-selected concrete
   state and returns its base pointer. Plain `Renderer` values are not sufficient
   backend storage. Stage 4 introduces runtime selection. Reuse public handle/value
   types.
3. Keep the interface focused on the existing renderer operations. Each backend
   owns its constant procedure table; a table must be paired with matching
   concrete storage. Do not introduce a general graphics abstraction or shared
   Vulkan orchestration layer. Almost entirely parallel Vulkan
   1.1 functions are acceptable when they make feature use and ownership clearer.
   Share demonstrably backend-neutral records, color conversion, and font layout
   in `reify.odin`. Font parsing/image decoding and their resource orchestration
   remain in the backend loading procedures. Shared font layout consumes font
   data rather than reaching through backend resource state. Keep batching,
   chunk indexing, uploads, and
   submission backend-owned; do not call Vulkan 1.3 initialization or drawing
   routines from the new backend.
4. Audit helpers before reuse. In particular, the current pipeline helper uses
   `VkPipelineRenderingCreateInfo`, and upload helpers/capture paths may assume
   modern barriers. Add compatibility-specific implementations where needed.
5. Audit demo and platform integration for assumptions that a Vulkan backend is
   specifically named `vulkan13`. Keep unrelated platform changes out of scope.
6. Establish a single common lifecycle owner for loader reservation, public
   lifecycle flags, and partial-initialization cleanup dispatch. Each backend
   cleans up and clears its own state; the facade resets the public renderer
   after backend cleanup. Preserve the one-active-renderer rule and surface
   destruction contract without duplicating ownership between the two backends.

## Device and surface initialization

Query loader support and require at least Vulkan 1.1. Load only supported core 1.1
and enabled extension entry points; set the allocator's Vulkan API version
accordingly and do not enable VMA buffer-device-address allocation flags.

Filter candidates for compatibility before ranking them. Validate swapchain
extension support, graphics queues, the actual surface's presentation support,
surface formats/present modes, and required format features. Prefer a combined
graphics/present queue; support separate families with concurrent swapchain
sharing initially to avoid excluding otherwise suitable hardware.

Use `renderer_new(info, allocator)` and the surface callbacks established in stage 1:
instance, surface, compatible physical device/queues, then device/resources.
Do not add a public `set_surface` step or revive manual loader initialization.
The descriptor is `Renderer_Init_Info` with `platform`, `logical_size`,
`resources_allocator`, `temp_allocator`, and `config.vsync`. The constructor
returns `(^Renderer, bool)` and logs initialization failures through
`context.logger`; failure returns `nil, false` after cleanup. Pair successful
construction with `renderer_free(renderer)` and keep the host window/callback
state alive until it returns. The storage allocator and resource allocator have
independent lifetimes and must remain valid for their allocations.
`present` returns `bool`: zero-size windows and out-of-date acquisition defer
presentation and return `true`, not a fatal failure. `texture_load` returns
`(Texture_Handle, bool)`; `font_load` returns `(Font_Face_Handle, Font_Atlas_Error)`
with a nil error on success. Failed resource handles have index `-1`.
Resource loading is valid after successful initialization, including when a
minimized window has deferred swapchain creation.

On failure, report the selected backend and concrete missing capability, clean
up partial state, and return `nil, false`. Device-candidate retries stay inside the
selected backend; explicit selection never silently switches backends. Auto-mode
backend fallback belongs to the future selection manager, not stage 3.

## Shader and resource layout

Use two descriptor sets:

| Set | Binding | Resource |
| --- | --- | --- |
| 0 | 0 | One read-only instance storage buffer for the current frame/chunk |
| 0 | 1 | One read-only storage buffer containing font records |
| 1 | 0 | One combined image sampler for the current texture batch |

Replace `pc.data->instances[index]` with `instances[index]` in a compatibility
shader. Keep the instance layout and vertex-index-based quad expansion. Push
constants carry the projection matrix and, if needed, a chunk/base index; no GPU
address is passed to the shader. Confirm CPU/shader member offsets and alignment
through reflection, using standard storage-buffer layout rules.

The font buffer contains many `Font` records but requires only **one descriptor**.
The original Vulkan 1.3 layout allocated `FONT_MAX_COUNT` descriptors for this
binding; stage 2 corrects that and this backend follows the corrected model.

Allocate instance storage per in-flight frame. Size or split it according to
`maxStorageBufferRange` and allocation limits. For chunks, define local vertex
indices/base offsets consistently so shaders cannot index outside the currently
bound range. Use host-visible staging plus device-local storage when appropriate;
allow suitable host-visible memory on integrated GPUs. Handle non-coherent flush
alignment rather than requiring coherent memory. Avoid a mandatory 128 MiB
texture staging allocation; upload in bounded chunks.

Create persistent texture descriptor sets on texture load, with growable pools.
No per-object descriptor allocation is necessary. Bind a valid white fallback
texture for untextured shapes. Preserve sprite and MSDF sampling behavior.
Do not overwrite descriptors, font data, or uploaded resources still used by
in-flight commands. Initially wait for relevant work before publishing resource
changes, matching stage 2; per-frame versions are a later optimization.

## Order-preserving texture batches

Extend the compatibility batch key with texture/sampler identity alongside the
existing scissor and projection state. Merge only adjacent compatible draws.
Never globally sort by texture: premultiplied alpha, additive draws, text, and
overlapping shapes must retain submission order.

Each batch binds one texture and issues an indexed draw over its contiguous
instance range. Font glyphs use their atlas texture; font metrics remain indexed
within the single font storage buffer. This removes texture descriptor-array
indexing entirely, including non-uniform indexing requirements.

Begin with this simple strategy. Atlas packing or texture arrays can reduce draw
counts later, but introduce separate packing, filtering, dimension, and format
constraints and are not required for the first implementation.

## Render passes, uploads, and presentation

- Create a conventional single-color render pass and a framebuffer for each
  swapchain image view. Build pipelines with the render pass/subpass, without a
  dynamic-rendering `pNext` chain. Preserve current blend and color-space behavior.
- Use `vkCmdBeginRenderPass` / `vkCmdEndRenderPass`. Express image transitions
  and upload dependencies with legacy stage/access masks and layouts such as
  `COLOR_ATTACHMENT_OPTIMAL`, `TRANSFER_DST_OPTIMAL`, and
  `SHADER_READ_ONLY_OPTIMAL`.
- Rewrite synchronization by dependency rather than mechanically casting
  synchronization2 flags. Cover transfer writes to vertex/fragment storage reads,
  texture sampling, host writes, and presentation.
- Use frame fences for CPU reuse, acquisition semaphores per frame, and render
  completion semaphores tied to swapchain images so presentation consumption is
  respected. Reset a submit fence only when a submission will follow.
- Recreate framebuffers with swapchain image views; rebuild render-pass-dependent
  pipelines if the surface format changes. Handle zero-size/minimized windows,
  resize, out-of-date/suboptimal results, and vsync changes.
- Honor surface usage flags; debug capture must not make transfer-source support
  a mandatory presentation requirement. A compatibility capture path may use an
  intermediate render target or report capture unsupported.

## Shader tooling

Add a distinct compatibility shader/artifact, for example
`assets/quad_vulkan11.slang` and `assets/quad_vulkan11.spv`. Share pure shading
functions and record definitions where practical; isolate binding declarations
and instance access.

Update both shader compile scripts to emit an explicit Vulkan 1.1-compatible
SPIR-V target (no newer than SPIR-V 1.3). Validate with
`spirv-val --target-env vulkan1.1` and inspect capabilities for accidental physical
storage-buffer addressing or descriptor-indexing requirements. Do not rely on
the shader compiler's default target.

Extend `tools/shader_types_gen` to handle the separate reflection input and
compatibility push constants without duplicating common Odin type names or
overwriting the Vulkan 1.3 push-constant layout.

## Implementation sequence and acceptance

1. **Complete — Selection and initialization:** config dispatch, isolated state, device
   checks, surface-dependent selection, and a clear-only Vulkan 1.1 frame.
2. **Complete — Geometry:** instance storage buffers, compatibility shader/tooling, index
   handling, solid shapes, camera/screen mode, and scissors.
3. **Complete — Textures and fonts:** persistent descriptors, ordered texture batches,
   uploads, MSDF text, resource lifetime, and limit-aware chunking.
4. **Complete — Lifecycle and parity:** resize/minimize, vsync, teardown, diagnostics,
   performance counters, demo selection, and build/run documentation.

Acceptance checks completed on the available Linux/NVIDIA path:

- Build the demo with `Renderer_Backend=vulkan11` and validation enabled; also
  compile the existing `vulkan13` backend for regressions. Once runtime selection
  lands, exercise both options in the same executable.
- Compare representative scenes across both Vulkan backends: overlapping
  translucent sprites, interleaved textures, additive content, all shapes, MSDF
  fonts, UV rectangles, rotations, camera transforms, and scissor boundaries.
- Exercise empty frames, multiple in-flight frames, resources loaded after
  rendering starts, storage-buffer chunk boundaries, descriptor-pool growth,
  repeated resize/minimize/restore, and unsupported-device diagnostics.
- Add focused checks for order-preserving batching and chunk indexing. Run
  synchronization validation and require no validation errors on the tested path.
- Measure texture-alternating scenes as well as atlas-friendly scenes. Report
  increased draw calls and CPU cost explicitly; visual parity and broader device
  compatibility take priority over matching bindless throughput.

Hardware follow-up: run on an actual older Vulkan 1.1/1.2 device/driver and AMD,
Intel, Windows, and separate-queue-family configurations when available. These
remain unverified; API 1.1 requests on a modern NVIDIA driver are not substitutes.

## References

- [No Graphics API](https://www.sebastianaaltonen.com/blog/no-graphics-api)
- [Vulkan descriptor arrays](https://docs.vulkan.org/guide/latest/descriptor_arrays.html)
- [Vulkan support checks](https://docs.vulkan.org/guide/latest/checking_for_support.html)

The storage-buffer and texture-batch design above is specific to this
renderer, not a compatibility guarantee supplied by those references.
