# Vulkan 1.3 hardware validation and robustness

## Status

`todo` — Implementation has not started.

Implementation stage 2, after [01-platform.md](01-platform.md).
See [00-roadmap.md](00-roadmap.md) for shared decisions and gates.

## Intent

Harden the existing `vulkan13` renderer so it selects suitable hardware, validates
its complete requirements, respects memory/resource limits, and reports failures
without leaving partially initialized state. Preserve its buffer-device-address,
bindless-texture, dynamic-rendering design. This is an implementation plan, not an
implemented change or a claim that all Vulkan 1.3 devices support this renderer.

Coordinate surface-dependent initialization with [01-platform.md](01-platform.md).
An unsupported device can receive a diagnostic suggesting the separately selected
backend in [03-vulkan11-compatibility.md](03-vulkan11-compatibility.md); do not silently switch backends.

## Findings in the current implementation

- `vk_select_phys_device` ranks devices without first validating the required API,
  feature bits, descriptor limits, formats, queues, or presentation support.
- `gpu_init` requests Vulkan 1.3 and enables feature bits without querying their
  support. It also requests anisotropy even though both built-in samplers disable it.
- `vk_rate_phys_device` checks the instance extension
  `VK_KHR_get_physical_device_properties2` in the device extension list before
  querying memory budgets. The relevant optional device extension is
  `VK_EXT_memory_budget`; `heapBudget` alone is not available headroom.
- The layout reserves 128 font storage-buffer descriptors although the shader
  uses one buffer of font records. Variable descriptor counts are requested
  without a variable-count layout binding.
- Texture sampling indexes a descriptor array using per-instance data. The
  shader decorations and enabled non-uniform indexing features need auditing.
- The texture staging allocation is fixed at 128 MiB, and texture upload copies
  the supplied pixel slice without first proving it fits the allocation.
- Some allocations allow VMA to select non-host-visible memory, but code assumes
  mapped access is available, including dereferencing index-buffer mapped data.
- Swapchain creation assumes a particular format/color space, identity transform,
  and opaque composite alpha. Expected environmental/allocation failures usually
  reach `vk_assert` rather than a recoverable result.

## 1. Define requirements and separate query from enablement

Introduce internal `Vulkan13_Requirements`, `Device_Capabilities`,
`Device_Rejection`, and `Negotiated_Limits` records. Keep queried support separate
from the smaller feature chain passed to `vkCreateDevice`. A single requirement
description should drive selection, enablement, diagnostics, and focused tests.

At startup:

1. Resolve loader entry points safely. Query `vkEnumerateInstanceVersion` when
   available; its absence implies a 1.0 loader and cannot satisfy this backend.
2. Enumerate instance extensions and requested validation layers, checking results
   and handling changing counts/`VK_INCOMPLETE`. Deduplicate names and distinguish
   required surface extensions from optional diagnostics.
3. Require core 1.3 support in both loader and candidate device. Do not require
   historical extension names for functionality already provided by core 1.3.
4. Query physical-device properties, Vulkan 1.1/1.2/1.3 features/properties, memory
   properties, device extensions, and queues. Build valid `pNext` chains without
   duplicating promoted feature structures.
5. Require `VK_KHR_swapchain` and the precise shader/renderer features below.
   Enable optional device extensions only when supported and actually used.

| Capability | Policy |
| --- | --- |
| `dynamicRendering`, `synchronization2`, `bufferDeviceAddress` | Query and enable for this implementation |
| `runtimeDescriptorArray` | Required while the shader declares an unsized texture descriptor array |
| `shaderSampledImageArrayNonUniformIndexing` | Require for per-instance texture selection within a draw; emit matching non-uniform shader annotations/decorations |
| Other descriptor-indexing bits | Derive from actual shader capabilities and binding flags; do not treat `descriptorIndexing` as enabling all subfeatures |
| Variable descriptor count | Remove feature and allocation-chain usage unless a deliberate variable-sized binding is implemented |
| Anisotropy / draw parameters | Remove unused requests after checking compiled shader capabilities and sampler behavior |
| Memory budget extension | Optional; missing budget telemetry must not itself reject a device |

Validate generated SPIR-V against Vulkan 1.3 and inspect declared capabilities,
extensions, layouts, and non-uniform decorations. `nointerpolation` does not make
a texture index dynamically uniform across the draw. Shader compiler output is
part of the hardware contract, not merely the handwritten source.

## 2. Filter devices before ranking

Reuse the surface-first initialization established by `01-platform.md`.
Check presentation support for that surface, a graphics queue, swapchain formats,
present modes, and required image usages. Support separate graphics/present
families using the concurrent swapchain-sharing policy established in stage 1.

Collect rejection reasons for every device. Rank only valid candidates using
explicit priorities; do not let `maxImageDimension2D` numerically overwhelm GPU
type preference. Consider usable memory; user device overrides are deferred,
without rejecting integrated GPUs merely because they use shared memory.

If device creation fails, unwind candidate state and consider the next validated
candidate when the failure is candidate-specific. Stop with the original cause
for global failures such as exhausted host memory. Distinguish unsupported
hardware from transient allocation or driver/device failure.

## 3. Descriptor and shader-resource limits

Fix the font binding to one storage-buffer descriptor with a range covering the
font-record array. Remove the currently unused variable-count allocation chain.
Use a fixed descriptor count chosen at initialization for the unsized shader
texture array; a runtime shader array does not require variable-count allocation.

Determine texture capacity from the requested cap and all applicable ordinary
layout limits: per-stage and per-set sampler/sample-image limits, total per-stage
resources, other bindings, and `vkGetDescriptorSetLayoutSupport`. A combined image
sampler consumes both sampler and sampled-image allowances. Update-after-bind
limits cannot be substituted unless that layout model and its features are used.

Initialize every potentially accessed descriptor. Prefer filling unused slots
with a valid fallback texture rather than adding a partially-bound requirement.
Validate texture/font handles and array indices on the CPU. Keep descriptor pool
counts consistent with actual set counts, including any per-frame copies.

Do not update the shared descriptor set while pending commands can use it.
Initially wait for affected work before publishing resource changes. Per-frame
descriptor sets are a later optimization if measured stalls justify them.
Apply the same discipline to shared font buffers and resource destruction.
Adding update-after-bind is a separate feature/lifetime design, not a blanket fix.

Check push-constant size and stage coverage, descriptor buffer range/alignment,
index-buffer bounds, vertex-index arithmetic, and generated CPU/shader layouts.
For physical-address instance reads, enforce allocation size, address alignment,
and live allocation lifetime directly; `maxStorageBufferRange` is not a substitute
for physical-pointer bounds. Optional robust-buffer features must not be assumed
to make arbitrary device-address accesses safe.

Choose and expose effective capacities once at initialization. If a smaller
texture capacity is allowed, apply it consistently to layout allocation, resource
loading, and diagnostics. Do not silently shrink live tables or overwrite old
resources when capacity is reached. Supporting fewer instances than the compiled
shader capacity still requires an explicit CPU bound check on every submission.

## 4. Heap sizes, budgets, and allocation policy

Record heap sizes/flags and the memory types that refer to each heap. Count each
heap once, and distinguish device-local, host-visible, and unified-memory cases.
A heap's total size is not currently free memory, and a memory type's property
flags do not imply that every resource can use it; honor `memoryTypeBits`.

When `VK_EXT_memory_budget` is supported, query budget and usage and compute
estimated headroom as `max(0, heapBudget - heapUsage)` per heap. Treat these as
changing estimates, not allocation guarantees. Without the extension, report
budget as unknown and use heap properties plus allocator accounting; do not label
total heap size as free VRAM. See the [memory budget specification](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_memory_budget.html).

Build an initial allocation estimate covering every in-flight instance buffer,
indices, font buffers, staging allocations, textures, descriptor overhead, and
swapchain pressure. Use actual resource memory requirements where available and
allow for alignment/block overhead. Avoid a blanket minimum-VRAM rule: a small
scene on an integrated GPU can be valid even without a large dedicated heap.

Configure VMA with the actual Vulkan API version, enabled extension flags, and
required function pointers. Audit the local Odin binding against the bundled VMA
library before enabling budget support. Account for allocation-count and
individual allocation/resource-size limits; heap capacity alone is insufficient.

Replace the unconditional 128 MiB staging requirement with bounded reusable
staging capacity and tiled/row upload chunks. Where mapped access is mandatory,
request host-visible memory; otherwise implement a real staging fallback with
the appropriate transfer usage flags. Check mapping results before dereferencing,
flush non-coherent writes, invalidate CPU readback, and balance map/unmap calls.

On allocation failure, roll back the new resource and return a useful error.
Permit only bounded retries that make a concrete change, such as a smaller
staging chunk. Do not spin, destroy live assets, or automatically change backend.
Recheck budgets during substantial resource growth, without expensive full-device
enumeration or noisy logging each frame.

## 5. Formats, surfaces, and upload validation

- Query surface format/color-space pairs and choose a supported preference.
  Preserve the intended color conversion; an sRGB-to-UNORM fallback requires
  deliberate output handling. Keep image views and dynamic-rendering pipeline
  attachment formats consistent, rebuilding pipelines when the format changes.
- Respect supported transforms, composite alpha, image usages, image-count bounds,
  and fixed/clamped extents. Use FIFO when a preferred vsync-off mode is unavailable.
  Defer presentation at zero framebuffer extent and requery on recreation.
- Check texture format support for the actual type, tiling, usage, size, and sample
  count. Verify sampled-image/transfer support and linear filtering for MSDF
  textures; descriptor capacity alone says nothing about format suitability.
- Validate positive dimensions before unsigned conversion, checked multiplication
  of width/height/pixel size, exact input slice requirements, image limits, staging
  capacity, and copy-region bounds. Publish a texture handle only after creation,
  upload, and descriptor publication succeed; rollback must leave tables intact.
- Audit upload barriers, especially font transfer writes to shader reads, and
  ensure updates cannot race earlier frame reads. Preserve texture color-space
  and premultiplied-alpha behavior across chunked uploads.
- Treat debug capture as optional. Validate transfer-source usage support and
  actual swapchain creation flags before copying, or use an intermediate target.
  A surface suitable for presentation need not support screenshot readback.

## 6. Failure reporting and lifecycle

Extend the platform stage's common error types for loader/extension/feature
incompatibility, insufficient limits, invalid input, capacity exhaustion,
allocation failure, surface loss,
and device loss. Reserve assertions for internal invariants. Propagate failures
through `init`, resource loading, and presentation instead of logging and
continuing with invalid state; coordinate public error types with `01-platform.md`.

Report GPU name, vendor/device IDs, driver identity/version, API version, enabled
optional capabilities, selected queues, effective capacities, and memory summary.
For rejection, show the required and supported values. Decode driver versions
appropriately rather than assuming every vendor uses Vulkan version packing.

Make partial initialization destructible in reverse dependency order. Preserve
in-flight resource lifetimes and presentation-semaphore reuse rules. Reset frame
fences only when a submission will follow; handle acquire failures without making
the next frame wait forever. On device loss, stop submission and expose failure;
full recovery/reinitialization is separate from ordinary swapchain recreation.

## Implementation order and validation

1. Add query/requirement records, diagnostics, and correct extension/feature checks.
2. Fix descriptor requirements and shader capability declarations, then validate
   candidate limits before logical-device creation.
3. Integrate full candidate filtering into the existing surface-first flow; harden
   format/queue and swapchain negotiation without changing the initialization API.
4. Correct VMA/mapping assumptions, budget queries, bounded staging, upload input
   checks, and safe resource publication/lifetime handling.
5. Propagate expected failures, complete partial cleanup, and expose effective
   limits and actionable diagnostics to callers.

Use focused tests for requirement comparison, descriptor-capacity calculations,
heap accounting/headroom saturation, integer overflow, and initialization unwind.
Include synthetic candidates with missing optional features, small limits,
multiple memory types on one heap, no budget extension, and separate queues.
Inject allocation/map/upload failures to verify no invalid handle is published.

Validate the generated shaders and run Vulkan core, synchronization, and where
available GPU-assisted validation on representative NVIDIA, AMD, and Intel
devices. Exercise mixed textures in one draw, empty frames, maximum capacities,
resource loading while frames are pending, non-coherent memory, resize/minimize,
vsync changes, and repeated initialization/destruction. Capability fixtures and
modern-GPU testing do not replace actual older-driver testing.

Completion means unsuitable hardware is rejected before unsupported use, suitable
hardware is selected even when another GPU is incompatible, normal resource
failures leave the renderer consistent, and representative rendering remains
visually equivalent without validation errors. Keep broader rendering fallbacks
in the separate compatibility backend.

## Further references

- [Descriptor arrays](https://docs.vulkan.org/guide/latest/descriptor_arrays.html)
- [Descriptor-indexing feature bits](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceDescriptorIndexingFeatures.html)
