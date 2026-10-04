# Runtime renderer detection and selection

## Status

`todo` — Implementation has not started.

Implementation stage 4, after [03-vulkan11-compatibility.md](03-vulkan11-compatibility.md).
See [00-roadmap.md](00-roadmap.md) for shared decisions and gates.

## Intent and relationship to the other plans

Replace the current compile-time `Renderer_Backend` choice with runtime selection
from the backends included in the application. Provide both automatic selection
and an explicit user preference editable through an in-app settings screen.
This document is an implementation plan, not implemented functionality.

Supported preferences are `auto`, `vulkan13`, and `vulkan11`.
`vulkan11` becomes selectable only after its implementation is available. The
application may ship a subset of backends; build settings control inclusion,
while runtime configuration controls which included backend is active.

SDL GPU is already retired in stage 1, including its host-project shader dependency.
SDL remains an optional window/surface provider outside Reify core. A persisted
`sdlgpu` preference requires an explicit migration to `auto` with a notice.

This replaces stage 3's interim compile-time selection with runtime dispatch.
Keep the established initialization descriptor and platform ownership, routing
initialization through the selection manager. Use the capability checks in
[02-vulkan13-robustness.md](02-vulkan13-robustness.md) rather than guessing support from
GPU names, API versions alone, or reported VRAM size.

## Configuration and public API

Keep configuration storage and the settings UI in the host application. Reify
defines the typed config, availability report, and selection operations. Example
persisted application setting:

```json
{
  "renderer": {
    "backend": "auto"
  }
}
```

Distinguish requested preference from the actual active backend. `auto` remains
the saved value even when it resolves to `vulkan13`; loading the application on
another machine should rerun detection. Invalid config values produce a useful
configuration error and a host-controlled recovery to `auto`.

Proposed operations, with final Odin signatures decided during implementation:

- `probe_backends(platform, requirements)` returns backend/device candidates,
  support status, effective limits, and rejection reasons.
- `init(renderer, info)` keeps the stage 1 signature; extend `info.config` with
  backend preference and required resource/capability metadata. Return `false` and
  log failure details; expose fallback details in the selection report.
- `renderer_backend(renderer)` reports the active backend. The current global,
  argument-free query must become instance-specific.
- `renderer_selection(renderer)` reports requested preference, active backend,
  selected device, and supported capabilities.
- `request_backend_change(renderer, preference)` queues a change for a safe point;
  it never destroys the renderer while a draw call is executing.
- `apply_backend_change(...)` reports success, failure/restoration, or that host
  window recreation/application restart is required.

Configuration precedence is a host-provided launch/session override, then the
saved in-app preference, then `auto`. Reify receives the resolved typed config;
it does not read environment variables or write a settings file itself.

Initially expose backend selection only. A later GPU override should use stable
device identity where available, not enumeration indices, and apply the same
capability checks. Keep it distinct from choosing the rendering backend.

## Automatic selection policy

1. Identify compiled-in Vulkan backends and validate the host's Vulkan surface
   callback interface without creating GPU devices.
2. Probe the actual window/surface and devices for each viable backend. For Vulkan,
   reuse the requirement evaluator and surface-aware device checks from the
   robustness/platform plans. Probe with a loader-supported instance version;
   failure to support 1.3 must not prevent attempting 1.1.
3. Rank valid candidates in the default order: Vulkan 1.3, then Vulkan 1.1.
   Rank eligible devices within each backend deterministically. This expresses a
   preference for the modern path, not a benchmark-derived speed guarantee.
4. Attempt complete initialization of the best candidate. If it fails for a
   candidate-specific reason, clean up and try the next candidate. Bound retries;
   stop for global failures such as invalid host state or exhausted host memory.
5. Return the active backend/device and a concise explanation if a preferred
   candidate failed. If none work, return all useful rejection reasons.

Probing means “eligible to attempt initialization,” not guaranteed success.
Budgets, surfaces, drivers, and allocation outcomes can change between probing
and initialization. Optional extensions and diagnostic layers must not become
accidental hard requirements. Cache immutable device details only as an
optimization; revalidate live surface and memory conditions on activation.

If neither Vulkan backend works, return an unsupported-renderer result. There is
no SDL GPU or implicit non-Vulkan fallback.

Automatic selection happens at initialization or an explicit apply operation.
Do not change backends periodically because memory budgets or measured frame
times fluctuate. Full automatic device-loss recovery is separate work.

## Explicit selection and in-app settings

An explicit preference tries only that backend, although it may select among
compatible GPUs. If unavailable, report why and offer the user `Auto` or another
supported choice. Never silently report an explicit choice as successful while
running a different backend. A launch-time config override can provide a recovery
route when an application cannot display its settings screen.

The host settings screen should show:

- `Auto (recommended)` and included backend choices with short descriptions.
- The current active backend and GPU separately from the requested preference.
- Unavailable options with actionable reasons, such as missing Vulkan feature,
  unsupported descriptor capacity, backend not included, or missing surface adapter.
- An Apply action and a clear indication when the change requires a restart.

Keep raw extension/limit dumps in an optional diagnostic view. Preserve pending
settings separately from committed settings; persist the preference only after
successful activation. For restart-required changes, stage it explicitly and
retain the previous known-working setting until the next successful startup.

## Runtime dispatch and backend state

Replace build-time concrete `Renderer` and `Renderer_Interface` selection with
runtime selection on a Reify-owned backend enum. Keep the selected procedure
table paired with its concrete backend storage, using a tagged backend-state
union or equivalent owned state reference so only the selected state is active.
The existing tables contain renderer operations, not a dynamic plugin interface.

Move shared public types out of backend-specific files. Dispatch every operation,
including initialization/destruction, resource loading, metrics, camera/screen
mode, scissor, resize, vsync, performance logging, and debug capture. Unsupported
optional operations return a capability/error rather than silently doing nothing.

Keep loader ownership in the selection/backend lifecycle; callers must not choose
which Vulkan loader initializer to call before selection. Audit global Vulkan
function pointers and shared loader handles. Initially perform probes and backend
activation serially, with one active renderer/device per process as established
in stage 1. UI availability queries while rendering use captured capability
reports; they must not create/destroy instances or overwrite global dispatch.
Fresh surface/device probes during a change run after the old backend is quiesced
and torn down, then revalidate eligibility. Treat preflight reports as provisional
and retain the restoration path. Concurrent device dispatch is separate work.

## Resources and backend changes

GPU buffers, texture descriptors, and backend-local font objects cannot survive
device destruction. Define a backend-neutral resource registry before supporting
transparent live switching:

- Public texture/font handles refer to registry entries with generation checks,
  not backend array indices. Each active backend maps these to its own resources.
- Entries retain immutable source data or a host-supplied reload callback and
  metadata sufficient to reconstruct the resource. Decide ownership explicitly;
  never retain pointers into temporary caller pixel/JSON buffers.
- Texture replay preserves color space, premultiplication, dimensions, and sampler
  intent. Font replay preserves metrics, atlas data, and handle relationships.
- Retaining CPU sources increases memory use. Allow reload callbacks as an
  alternative and document their errors, lifetime, and thread/context rules.
- If a resource cannot be replayed, report that live switching is unavailable;
  the in-app preference can still be applied through a restart.

Before switching, compare current resource requirements with the candidate's
effective limits. A backend that can initialize may not fit the current scene.
Reject the switch cleanly if capacity is insufficient; do not drop textures,
invalidate public handles, or reorder transparent draws to force it to fit.

Apply changes outside a frame using a state machine:

1. Validate the preference and candidate; finish the current frame and stop new
   submissions/resource mutations.
2. Record the active selection and backend-neutral settings. Ensure all resources
   have replay data, and wait for outstanding rendering/presentation as required.
3. Release the old backend's GPU resources, surface, and device in
   lifecycle order. Keep the host window and resource registry when compatible.
4. Initialize the selected candidate, replay resources, and restore viewport,
   vsync, and other persistent settings. Validate a complete frame before marking
   the change committed; resume normal rendering with the same public handles.
5. On failure, clean up the candidate and attempt to reconstruct the prior working
   backend from the registry. Return both the change failure and restoration
   result. If restoration also fails, leave a defined stopped state and let the
   host display a platform error/restart path rather than continuing to draw.

Do not promise an atomic GPU-level rollback: both backends may not coexist on one
window, memory may be insufficient for duplicate resources, and the current
Vulkan dispatch is global. Restoration is a reconstruction attempt.

Both backends use the same Vulkan-capable host window. Recreate the surface for
the new instance as needed through the platform adapter. If a platform requires
window recreation, return that requirement to the host; Reify must not secretly
destroy a host-owned window. A host may choose a restart instead.

## Delivery sequence

1. **Backend availability and diagnostics:** reuse the completed platform contract
   and both capability evaluators to provide candidate reports.
2. **Runtime startup selection:** add typed config, explicit/automatic policies,
   runtime state/dispatch, loader lifecycle, and initialization fallback. Remove
   the old build-time selected-backend assumption; retain build-time inclusion.
3. **In-app configuration:** provide host-facing availability/selection APIs and
   demonstrate a settings UI. Initially apply changes on restart, with a clear
   restart-required result and config recovery behavior.
4. **Resource replay:** migrate handles to the neutral registry and add CPU-source
   ownership/reload callbacks and replay validation.
5. **Live apply:** add the safe-point state machine, resource replay, restoration,
   and platform/window-transition handling. Keep restart as a supported fallback.
6. **Documentation:** update the other plans and README to describe runtime
   selection, compiled-in availability, config precedence, and switch semantics.

## Validation and completion criteria

- Table-driven policy checks: preferred backend available; only Vulkan 1.1
  available; no suitable device; excluded backend; explicit
  unsupported selection; and multiple GPUs with different support levels.
- Inject initialization failures and confirm bounded fallback, full cleanup, and
  retention of useful diagnostics. Explicit mode must never silently fall back.
- Test a single executable selecting each included backend on representative
  hardware, with both GLFW and SDL hosts where applicable.
- Exercise in-app changes between both Vulkan backends, `Auto` resolving to the
  current backend, unsupported window transitions, failed resource reload, and
  failed restoration. An unchanged resolved backend should be a no-op.
- Confirm stable public handles, text metrics, texture appearance, draw order,
  viewport/scissor behavior, and settings across successful switches. Test scene
  requirements exceeding the compatibility backend's negotiated capacity.
- Run Vulkan validation across repeated switches, resize/minimize, uploads, and
  pending frames. Check cleanup and memory growth over repeated cycles.

Completion means users can select a backend without rebuilding, Auto selects and
initializes a supported candidate with clear diagnostics, explicit preferences
are honored, and in-app changes have a documented safe apply/restart path.
