# Custom shaders

## Status

`todo` — Implementation has not started.

Implementation stage 5, after [04-renderer-selection.md](04-renderer-selection.md).
See [00-roadmap.md](00-roadmap.md) for the ordered roadmap and shared decisions.

## Intent and initial scope

Support application-defined shading while retaining Reify's drawing API, flat
instance data, order-preserving batches, and two owned Vulkan backends. SDL GPU
is retired and is not a shader target.

Start with custom fragment effects on existing primitives using Reify's normal
vertex shader. The first interface transforms the built-in shaded color, with UV,
local coordinates, instance color/type, and application parameters as inputs.
This supports tinting, grayscale, fades, and procedural overlays without giving
applications access to renderer-private pointers or descriptor indices.

Later extend the versioned interface to full fragment evaluation, auxiliary
textures, and custom vertex transforms. Arbitrary meshes, compute shaders,
offscreen post-processing, depth, and multiple render targets require additional
rendering APIs and are follow-on work, not hidden requirements of this first step.

## Public shader and material resources

Add backend-neutral, generation-checked `Shader_Handle` and `Material_Handle`
resources to the registry established by the runtime-selection plan.

- A shader identifies an immutable package: compiled backend variants, ABI version,
  entry points, interface metadata, and resource/feature requirements.
- A material references a shader and owns an application parameter block. Later
  versions may add auxiliary texture bindings through ordinary `Texture_Handle`s.
- `shader_load`, `material_create`, parameter update, and destroy operations return
  structured errors for invalid packages, unsupported interfaces, or allocation
  failures. Do not expose raw Vulkan modules, pipelines, or GPU addresses.
- `set_material(renderer, material)` changes the material for subsequent draws;
  `reset_material` restores built-in shading. `start` resets material selection
  each frame. Internal text/shape expansion preserves the selected material.

Define effect semantics explicitly: built-in sprite sampling, shape coverage,
MSDF text, and instance tint produce a linear premultiplied color first; the custom
effect receives and returns that representation. Additive instances currently
encode emission with zero alpha and nonzero RGB, so do not automatically erase
RGB at zero alpha or unpremultiply without a guard. Discard is allowed, with its
coverage/performance consequences documented. Geometry/scissor remain unchanged.

Keep the current premultiplied blend state in the initial version. New blend
modes are explicit pipeline variants, not inferred from shader code.

## Versioned shader interface and offline build

Provide a small Reify-owned Slang interface/include and generated wrappers for
each backend. Conceptual application hook:

```text
shade_effect(fragment_input, built_in_linear_premultiplied_color, parameters)
    -> linear_premultiplied_color
```

Wrappers own stage entry points, geometry expansion, instance/font access, primary
texture sampling, projection, and binding numbers. Expose named values and helper
functions rather than making `Shader_Data*` or Vulkan 1.3 descriptor layout part
of the public authoring contract. Reserve a shader ABI version and hash that
covers input/output layouts, wrapper semantics, and parameter metadata.

Compile one authoring source through two wrappers into distinct SPIR-V artifacts:

| Variant | Renderer integration |
| --- | --- |
| `vulkan13` | Existing device-address instances and bindless primary textures |
| `vulkan11` | Instance storage buffer and one primary texture per batch |

Use explicit Vulkan/SPIR-V targets and run `spirv-val` for each target. A portable
effect must not introduce physical pointers, non-uniform descriptor indexing, or
other optional features into the Vulkan 1.1 wrapper. Compiling a second variant
does not automatically make an arbitrary Vulkan 1.3 program portable.

Ship precompiled packages at runtime; do not require a shader compiler on end-user
machines. Extend the current shell/PowerShell shader tooling and type generator
to build packages, validate output, and emit parameter layout metadata with
compiler options, artifact hashes, wrapper ABI, and target requirements.
Use the installed compiler's supported reflection output/API; validate member
offsets and strides rather than inferring uniform-buffer layout from Odin types.
Slang distinguishes type layout by how data is bound; see its
[reflection documentation](https://docs.shader-slang.org/en/latest/external/slang/docs/user-guide/09-reflection.html).

Built-in shader artifacts from earlier stages continue to work while the package
tooling is introduced. Convert them to the versioned wrapper interface alongside
custom effects, with visual parity checks. A package may combine stage entry
points in one module or use separate modules; record the choice explicitly.

## Parameters, bindings, and batching

For the initial ABI, use one read-only material uniform-buffer binding at set 2,
binding 0 in both backends. Reserve sets 0 and 1 for engine resources: Vulkan 1.1
uses them for frame data and its primary texture; Vulkan 1.3 may reserve an empty
set 1. Ordinary uniform buffers avoid adding GPU-pointer or descriptor-indexing
requirements to custom parameter access.

Include this binding in total descriptor/per-stage limits and descriptor-pool
accounting from the robustness plan. Check `maxUniformBufferRange`, alignment,
binding count, and pipeline-layout compatibility. At stage 5, reserve this
headroom before finalizing texture capacity; account for material memory in the
budget model. Do not assume spare resources beyond previously negotiated limits.

Validate parameter size/layout against package metadata. Prefer generated typed
Odin packing helpers, with a checked byte-block API for advanced callers. Copy
parameter bytes into owned material state. During draw recording, snapshot the
material version and parameter bytes into frame-owned storage, with aligned
uniform-buffer ranges and descriptors retained until the frame completes.

A material update after one draw must not retroactively change that draw.
Extend the batch key with shader/pipeline identity and material snapshot identity,
alongside projection/scissor and the compatibility backend's texture identity.
Merge adjacent equivalent batches only. Never reorder transparent draws by
shader, material, or texture. More effects and parameter changes can mean more
draw calls; expose this cost in existing performance counters.

For the first implementation, changing parameters creates a new batch snapshot.
Per-instance custom parameter records can be a later optimization if measured
batch fragmentation justifies extending the instance format.

## Pipeline creation and lifetime

Generalize `vk_pipeline_init` to accept shader stages, entry points, pipeline
layout, and the actual attachment format. Use separate backend construction for
Vulkan 1.3 dynamic rendering and Vulkan 1.1 render-pass compatibility.

Cache pipelines in memory by shader artifact/version, interface layout, blend
state, attachment format, sample count, and backend render-pass compatibility.
Avoid parameter values in the key. Precreate required pipelines at shader load
or an explicit prepare step; do not unexpectedly compile on every draw.
Disk pipeline caches are optional later work.

Shader/material destruction invalidates public handles for new calls while
retaining internal references for already recorded/in-flight work. Retire old
pipelines, descriptor sets, and uniform storage only after relevant fences signal.
Surface format changes rebuild affected pipelines using the established swapchain
lifecycle. Report shader/pipeline creation failure without damaging working ones.

## Runtime selection, replay, and development reload

Expose package support for both backends. Portable packages include both variants;
allow an explicitly marked Vulkan 1.3-only package, but explain that it can prevent
a switch to Vulkan 1.1. Required shader manifests can be passed with initialization
requirements so Auto considers them before choosing a backend/device.

If a shader is loaded after device creation, its requirements must fit the active
device's **enabled** features and negotiated limits, not merely supported features.
Return an error for missing requirements; loading a shader must not silently
recreate the device or switch backend. A host can request an explicit change.

Store package bytes or reload callbacks and material values in the shared registry.
Before a backend change, verify variants for every live shader and replay resources
in dependency order: textures/fonts and shader packages, then materials. Preserve
public handles and report missing variants before teardown where possible.

Development hot reload is optional: compile/validate off the render path, create
replacement GPU state on the renderer thread, then publish at a frame boundary.
Keep the last good shader after failure. ABI/parameter-layout changes require
explicit material recreation or migration; never reinterpret old parameter bytes.
Bound reload memory use and defer old-state destruction until work completes.

## Incremental delivery and acceptance

1. Define the fragment-effect ABI, package metadata, parameter packing, and offline
   wrapper builds. Validate a pass-through effect against built-in rendering.
2. Implement shader/material resources, frame snapshots, and pipeline/batch changes
   in Vulkan 1.3 with a grayscale and animated-tint example.
3. Implement the Vulkan 1.1 wrapper and binding path, verifying the same effects
   without raising its hardware baseline.
4. Integrate runtime capability reports, backend-switch replay, destruction, and
   optional hot reload. Document portability and costs.
5. Only after this contract is stable, design auxiliary textures/full fragment
   hooks, then custom vertex transforms, as explicit additional ABI versions.

Acceptance includes both-backend visual comparisons, MSDF text, additive colors,
translucent ordering, scissors, multiple materials in one frame, parameter updates
between draws, and swapchain format changes. Test invalid handles, parameter
layout mismatch, missing variants, unsupported capabilities, pipeline allocation
failure, material destruction with pending frames, reload failure, and backend
switch/restoration. Run SPIR-V and Vulkan validation and verify no unintended
Vulkan 1.1 feature requirements. Measure additional draws and uniform memory use.

The initial feature is complete when applications can ship a custom fragment
effect on both owned backends, control its parameters through Reify, and retain
correct resource lifetime and runtime-selection behavior.
