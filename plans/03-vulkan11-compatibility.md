# Vulkan 1.1 compatibility renderer

## Status

`in-progress` — The build-selected Vulkan 1.1 backend, isolated state, conventional
render passes, legacy synchronization, frame-owned storage-buffer chunks,
persistent texture descriptors/growable pools, ordered batching, and public API
dispatch are implemented. Public drawing procedures live in `reify_drawing.odin`;
facade performance accounting/resource error handling surround backend-only calls.
Font layout/records and color conversion are shared;
GPU orchestration, uploads, batching, and capture remain backend-owned. Separate
SPIR-V 1.3 tooling validates the compatibility shader with only `Shader` capability.

Available Linux/GLFW GTX 1070 validation covers both backends, lifecycle/resource
failures, pool growth, and forced 17-instance chunks. The representative parity
scene produces byte-identical readback images on both backends. Core package,
GLFW demo, and SDL example compile checks pass with each build selection. All
16 Vulkan 1.3 and 12 Vulkan 1.1 package tests pass; integration suites pass 34 and
31 tests respectively, including synchronization validation with no reported
errors. The 31-test Vulkan 1.1 suite also passes with forced 17-instance chunks;
all three shader-audit tests pass. CPU batch-cost measurements/reproduction are in
README. The compatibility delivery gate remains open: an actual older Vulkan
1.1/1.2 driver/device is not
available. AMD, Intel, Windows, and separate-family real-device paths are also
unverified; API 1.1 requests on this NVIDIA driver do not establish that coverage.

### Separate initial checkpoint: Renderer/state split

This checkpoint preserves the Vulkan 1.3 backend and does not add `vulkan11`
selection. The facade owns loader lifetime, the active-renderer reservation,
initialization flags, failure cleanup dispatch, and the final public reset.
Backend cleanup releases its GPU state without resetting common ownership.
The build-selected state is embedded through a compile-time alias; Odin `using`
promotion preserves existing backend field access without introducing a
procedure table or shared Vulkan orchestration layer. Drawing, resource upload,
font layout, batching, and submission remain in the Vulkan 1.3 implementation.

Checkpoint verification: core package, GLFW demo, and SDL example compile
checks pass; all 15 package tests and all 31 tests with the opt-in integration
suite pass. The integration suite also passes with synchronization validation
enabled and no reported validation errors on the available Linux/NVIDIA GTX 1070
configuration. Tests cover backend-only cleanup, preflight state preservation,
initialization rollback, repeated lifetimes, resize/minimize, uploads, and
resource/submission failures. Windows and other GPUs are not verified by this
checkpoint. A clean adversarial review is required before checkpoint delivery.

Implementation stage 3, after [02-vulkan13-robustness.md](02-vulkan13-robustness.md).
See [00-roadmap.md](00-roadmap.md) for shared decisions and gates.

## Intent

Add an alternate `vulkan11` backend for older Windows/Linux gaming hardware.
Select it through the existing compile-time `Renderer_Backend` config:

```sh
odin run demo -define:Renderer_Backend=vulkan11
```

This document records the stage-3 design and its remaining validation gate.
Retain only Reify-owned `vulkan13` and `vulkan11` backends; retire SDL GPU.
Applications should use the same public drawing, texture, font, camera, and
scissor APIs with either Vulkan backend. The command above describes an interim
build option; [04-renderer-selection.md](04-renderer-selection.md) defines the intended
runtime `auto` / `vulkan13` / `vulkan11` configuration and supersedes that option.

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

1. Accept `vulkan11` in config validation and add explicit dispatch branches for
   every public operation. SDL GPU dispatch is already removed in stage 1.
   Include the internal loader lifecycle,
   instance access, surface setup, resource loading, metrics, frame submission,
   resize, vsync, logging, and destruction.
2. Move the public `Renderer` declaration into `reify.odin`. Keep common
   allocator/platform ownership, lifecycle flags, logical dimensions, and
   performance statistics there. Extract the Vulkan instance/device/queue context,
   backend capabilities and limits, VMA allocator, surface handle, GPU resources,
   swapchain, frame contexts/index, descriptors, pipelines, command pool, shader
   module, and pending-upload state into `Vulkan13_Renderer_State` in
   `reify_vulkan13.odin`; add an independent `Vulkan11_Renderer_State` in
   `reify_vulkan11.odin`. Initially embed only the build-selected backend state;
   stage 4 introduces tagged runtime state. Reuse public handle/value types.
3. Keep the interface small: the existing public API and explicit backend dispatch
   are the facade. Do not introduce a general graphics abstraction, procedure
   table, or shared Vulkan orchestration layer. Almost entirely parallel Vulkan
   1.1 functions are acceptable when they make feature use and ownership clearer.
   Share only demonstrably backend-neutral logic where useful: pure shape
   generation, instance records, color conversion, font parsing/layout, and image
   decoding. Several such definitions currently live in `reify_vulkan13.odin`;
   move them deliberately into cohesive shared slices, not merely to avoid
   duplication. Shared font layout should consume font data rather than reach
   through backend resource state. Keep batching, chunk indexing, uploads, and
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

Use `init(renderer, info)` and the surface callbacks established in stage 1:
instance, surface, compatible physical device/queues, then device/resources.
Do not add a public `set_surface` step or revive manual loader initialization.
The implemented stage-1 descriptor is `Renderer_Init_Info` with `platform`,
`logical_size`, allocator options, and `config.vsync`. Both `init` and `present`
return `bool`; log detailed failure diagnostics through `context.logger`.
Resource loading returns `(handle, bool)`, without caller-facing error records.
Resource loading is valid after successful initialization, including when a
minimized window has deferred swapchain creation.

On failure, report the selected backend and concrete missing capability, clean
up partial state, and return `false`. The selection
manager may try another candidate in Auto mode; explicit selection must not
silently switch backends. Keep retry decisions internal and preserve the public
boolean/logging contract from the platform plan.

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

1. **Selection and initialization:** config dispatch, isolated state, device
   checks, surface-dependent selection, and a clear-only Vulkan 1.1 frame.
2. **Geometry:** instance storage buffers, compatibility shader/tooling, index
   handling, solid shapes, camera/screen mode, and scissors.
3. **Textures and fonts:** persistent descriptors, ordered texture batches,
   uploads, MSDF text, resource lifetime, and limit-aware chunking.
4. **Lifecycle and parity:** resize/minimize, vsync, teardown, diagnostics,
   performance counters, demo selection, and build/run documentation.

Acceptance checks:

- Build the demo with `Renderer_Backend=vulkan11` and validation enabled; also
  compile the existing `vulkan13` backend for regressions. Once runtime selection
  lands, exercise both options in the same executable.
- Run on an actual older Vulkan 1.1/1.2 device/driver plus modern NVIDIA, AMD,
  and Intel hardware where available. Merely requesting API 1.1 on a modern GPU
  does not prove the absence of optional-feature dependencies.
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

## References

- [No Graphics API](https://www.sebastianaaltonen.com/blog/no-graphics-api)
- [Vulkan descriptor arrays](https://docs.vulkan.org/guide/latest/descriptor_arrays.html)
- [Vulkan support checks](https://docs.vulkan.org/guide/latest/checking_for_support.html)

The storage-buffer and texture-batch design above is specific to this
renderer, not a compatibility guarantee supplied by those references.
