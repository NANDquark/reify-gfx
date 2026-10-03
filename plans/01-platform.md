# Reify-owned platform integration

## Status

`completed` — SDL GPU and Substrate coupling removed; the owned platform/error
contract, ordered instance/surface/device initialization, rollback, framebuffer
handling, and separate-queue sharing are implemented. Public backend dispatch
retains `when Renderer_Backend` branches. GLFW and SDL3 hosts are standalone;
README migration instructions and validation scripts are updated.

Validation: core, GLFW, and SDL checks passed from an isolated `/tmp` copy with
no sibling Substrate or parent assets; the isolated GLFW demo also built.
The full GLFW sprite/additive/text scene ran with Vulkan validation without
diagnostics. GLFW smoke checks passed resize, minimize/restore, vsync changes,
repeated initialization/destruction, clean shutdown with submitted work, and
injected zero-size initialization/resource loading/restoration. SDL3 rendering
and shutdown passed with validation. Lifecycle/scissor tests passed with
validation and Odin memory tracking: missing callbacks/extensions, concurrent
renderer rejection, surface creation failure, no present-capable device,
post-surface/device/resource failures, exactly-once surface destruction before
instance teardown, repeated destroy, and scaled/clamped scissors. Retired
`sdlgpu` selection fails with the migration diagnostic.

Coverage limits: separate graphics/presentation families and physical monitor
DPI changes were not exercised on hardware; scissor scaling has focused checks.
Windows and other window-system configurations were not run. Vulkan 1.1 remains
stage 3 work; hardware/descriptor robustness remains stage 2 work.

Implementation stage 1. See [00-roadmap.md](00-roadmap.md) for shared decisions and gates.
This stage ships with the existing `vulkan13` backend; later stages add the
compatibility backend and runtime selection without changing platform ownership.

## Intent

Remove Reify's dependency on the sibling `substrate` package. Define a small
Reify-owned interface through which an application supplies the window-system
capabilities required by its renderer backend. The concrete API is implemented in
`reify_platform.odin`; this document records its scope and delivery criteria.

Keep window creation, event polling, input, timing, and application lifecycle in
the host application. Reify owns rendering and presentation resources. A host may
use GLFW, SDL, Substrate, or native window APIs without exposing those choices to
the general drawing API.

Both Reify-owned backends, `vulkan13` and the planned `vulkan11`, use the same
Vulkan platform contract. Retire SDL GPU; SDL may remain a host window/surface
provider through an external adapter. Runtime backend selection is specified in
[04-renderer-selection.md](04-renderer-selection.md). This work adds no windowing library.

## Starting coupling

- `reify.odin` imports `../substrate`, accepts `^pf.Platform` in `init`, obtains
  Vulkan instance extensions from `pf.vulkan_required_extensions`, and checks
  `pf.Current_Platform_Type` when selecting SDL GPU.
- `reify_sdlgpu_backend.odin` imports Substrate solely to obtain an SDL window
  through `pf.get_sdl_window` during initialization.
- Vulkan surface creation already happens outside the renderer, followed by
  `set_surface`; Vulkan teardown currently destroys the supplied surface.
- `demo/demo.odin` uses GLFW directly, accesses `renderer.gpu.instance`, and calls
  an older `init` signature. Its resource-loading calls also need checking against
  the current public API before it can serve as a working migration example.
- The SDL GPU shader loads reference `../../assets/shaders`, outside this repo.
  Retiring that backend also removes this host-project asset dependency.

## Proposed public contract

`reify_platform.odin` defines the initialization descriptor and explicitly named
capabilities. The following summarizes the contract; see that file for Odin types:

```text
Platform_Interface
    user_data: opaque pointer to host-owned adapter state
    get_framebuffer_size(user_data) -> pixel dimensions or platform error
    vulkan: Vulkan_Surface_Interface

Vulkan_Surface_Interface
    required_instance_extensions: borrowed []cstring extension names
    create_surface(user_data, instance) -> surface or platform error
    destroy_surface(user_data, instance, surface)

Renderer_Init_Info
    platform: Platform_Interface
    initial logical viewport size
    allocator / temporary allocator options
    config: renderer configuration (runtime backend preference added in stage 4)

init(renderer, info) -> bool (failure details are logged)
```

Validate the Vulkan callback contract instead of using a platform-name enum or
Substrate compile-time configuration. GLFW and SDL adapters implement the same
contract and keep typed window pointers in their opaque host state. Reify core
does not import or link either window library and exposes no SDL GPU capability.

Extension names must come from the window provider; do not hardcode X11, Wayland,
Win32, or display-server environment checks in Reify. Reify validates and combines
those names with its own backend-required extensions, deduplicating by name.
Hosts query extensions before `init` and handle provider errors themselves. Names
and their slice must remain valid through synchronous `init`; Reify retains no
borrowed extension names or host-owned scratch slices afterward.

Use a consistent Odin callback calling convention and document context handling.
Callbacks run synchronously on the calling thread, with a valid Odin context;
the host must call initialization and destruction on a thread permitted by its
window library. Host state must remain valid until renderer destruction finishes.
Callbacks must not reenter the same renderer.

## Ownership and initialization order

| Resource | Responsibility |
| --- | --- |
| Window, window-library runtime, adapter state | Host creates and destroys after the renderer |
| Vulkan loader lifetime | Reify initializes before instance creation and releases after all renderer use |
| Vulkan instance/device, swapchain, render resources | Reify |
| Vulkan surface | Adapter creates; Reify retains it and invokes adapter destruction exactly once |

For Vulkan, initialize in this order:

1. The host queries extensions; Reify validates the interface and initializes the loader.
2. Create the Vulkan instance for the selected backend's API baseline.
3. Invoke `create_surface` with that instance and check its result.
4. Select a physical device and queues using the actual surface's presentation
   support, along with the renderer's features and limits.
5. Create the logical device, allocator, frame resources, and swapchain when the
   framebuffer has nonzero extent.
6. Return success only after reaching a well-defined initialized state. A
   minimized window may defer swapchain creation while still allowing resource
   loading and later resumption.

This replaces the current two-stage `init` / `set_surface` API. The callback solves
the need for an instance before surface creation while allowing device selection
to consider presentation support. Keep both Vulkan backends consistent.

Unwind failures in reverse order. `create_surface` owns cleanup of partial work
on failure; once it succeeds, Reify is responsible for eventually calling
`destroy_surface`, including if later device initialization fails. Invoke that
callback before destroying the Vulkan instance. For the initial adapters, use
default Vulkan allocation callbacks consistently during surface creation and
destruction. Do not support borrowed, externally owned surfaces in the first API;
that would require a distinct ownership option.

Make loader lifetime balanced and safe for sequential renderer creation and
failure cleanup. Initially allow only one active renderer/device per process
because Vulkan dispatch is global; reject unsupported concurrent initialization.
Use backend-neutral loader entry points internally so stage 4 can reuse them.

## Window size and presentation events

Distinguish logical viewport dimensions from framebuffer pixel dimensions. Use
framebuffer pixels for swapchain extent and Vulkan viewport/scissor coordinates.
Keep application drawing coordinates in the documented logical coordinate space;
convert scissors with an explicit scale and clamp them to the framebuffer. Audit
existing camera/screen projection behavior to prevent a high-DPI regression.

The host continues to deliver resize notifications through the public resize
entry point, which only updates stored logical dimensions and projection and
returns early for unchanged dimensions. Reify polls framebuffer size for pixel
changes and queries it before swapchain recreation,
including after out-of-date results or display-scale changes. A zero extent means
pause presentation until drawable again, not initialization failure or a busy
recreation loop. Both Vulkan backends follow the same logical-size contract.

Keep vsync selection, swapchain formats, queue synchronization, and presentation
inside the backend. The adapter does not acquire images, submit GPU work, or own
frame fences. Native window destruction/replacement requires renderer teardown
and reinitialization initially; surface-loss errors should be reported clearly.

## Errors and adapter examples

Return `false` on initialization failure and log the stage/category, diagnostic
message, and underlying Vulkan result or SDL message where applicable.
Distinguish missing platform capability, missing extension, surface creation,
no suitable present-capable device, and GPU-resource initialization failures.
Copy diagnostic text when the provider's error string is temporary.

Missing surface callbacks should produce a useful log diagnostic rather than a Substrate
compile-time assertion. Reject the retired `sdlgpu` selection with a migration
message pointing to currently implemented choices (`vulkan13` at this stage;
`auto` and `vulkan11` become available in later stages).

Provide a small GLFW adapter in the demo: enumerate extensions, create/destroy a
surface, and query framebuffer pixel size. Keep GLFW imports out of Reify core.
Document an SDL adapter supplying Vulkan surface callbacks and framebuffer size.
A Substrate adapter can live in the consuming application;
the Reify library and its default examples must not import Substrate.

Use one authoritative initialization path, `init(renderer, info)`. Migrate the
repo's callers away from direct `renderer.gpu.instance` access, manual loader
initialization, and `set_surface`. Do not introduce a second surface ownership
mode through compatibility wrappers; document the public API migration.

## Implementation sequence

1. **Retire SDL GPU first:** remove its implementation, renderer state, dispatch,
   shader references, `get_sdl_window` usage, and `Current_Platform_Type` guard.
   Preserve shared utility functions still needed by Vulkan. Confirm the Vulkan
   demo builds/runs before proceeding; fix its stale call sites as needed. This
   checkpoint retains the remaining Substrate integration until step 2.
2. **Define the boundary:** introduce interface/error types, callback contracts,
   ownership documentation, and the new initialization descriptor.
3. **Migrate Vulkan:** move instance/surface/device setup into the ordered flow,
   validate presentation before selecting a device, and implement complete failure
   cleanup. Support separate graphics/present families using concurrent swapchain
   sharing. Stage 2 adds the full hardware requirement evaluator; stage 3 reuses
   this initialization flow for `vulkan11`.
4. **Remove coupling:** verify both Substrate imports are gone, update every changed call
   site, and ensure core files contain no Substrate types or configuration names.
   Keep adapters outside the core package to avoid package cycles.
5. **Make examples standalone:** update the GLFW demo to current APIs, provide
   SDL Vulkan-surface integration instructions/example, and verify the removed
   backend no longer causes parent-project asset loads.
6. **Document migration:** update README initialization examples, backend-specific
   capabilities, resize/high-DPI behavior, lifetime order, and failure handling.
   Reconcile the initialization section of `03-vulkan11-compatibility.md` with this contract.

## Validation and completion criteria

- Build from a checkout without a sibling Substrate directory or parent-project
  shader assets. Vulkan builds must not require GLFW/SDL through the core platform
  interface; demos/adapters may require their own window libraries.
- Build and run the GLFW demo with `vulkan13`, and `vulkan11` when available; run
  an SDL-hosted Vulkan example where supported.
- Use focused failure-injection checks for missing callbacks, surface creation
  failure, and later initialization failure. Verify surface destruction exactly
  once and correct ordering relative to instance/window destruction.
- Exercise resize, minimize/restore, high-DPI scale changes, vsync changes,
  repeated initialize/destroy, and clean shutdown with GPU work in flight.
- Run Vulkan validation and verify device selection against the actual surface.
  Test separate graphics/present queue handling where available.
- Preserve drawing and resource-loading behavior. No host needs to include a
  Substrate type, know the selected Vulkan version to create its surface, or reach
  into renderer GPU state to initialize Reify.

The deliverable is a narrow platform integration contract plus migrated backends
and examples. A general platform framework, runtime renderer switching, arbitrary
external Vulkan device adoption, and expanded OS support remain separate work.
