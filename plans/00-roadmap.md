# Renderer implementation roadmap

These documents describe planned work; each plan's status tracks implementation.
Work in the order below; each
stage should leave a buildable, usable renderer before starting the next. Existing
source findings in the documents describe the repository before implementation.

## Plan status workflow

Each numbered implementation plan has a `Status` section with one of three values:

- `todo`: implementation has not started. Writing or reviewing the plan does not
  change this status.
- `in-progress`: implementation has started, but required work or validation remains.
- `completed`: the plan's implementation and required validation are complete and
  its delivery gate is satisfied. Explicitly deferred follow-on work is excluded.

Update the individual plan to `in-progress` when implementation begins. As work
proceeds, keep a short note in its status section describing completed work,
remaining work, and any blockers or outstanding validation. Update it to
`completed` only when its completion criteria are met, recording a concise
validation summary. If required work is reopened, return it to `in-progress`.

Keep status updates with the corresponding implementation changes so the next
person can see the actual state. The individual plan is the source of truth;
this roadmap does not duplicate statuses in its dependency table.

## Priority and dependencies

| Order | Plan | Prerequisite | Independently usable result |
| --- | --- | --- | --- |
| 1 | [Platform integration](01-platform.md) | Current renderer | Standalone Vulkan 1.3 renderer, no Substrate or SDL GPU dependency, explicit platform ownership |
| 2 | [Vulkan 1.3 robustness](02-vulkan13-robustness.md) | Stage 1 | Verified hardware selection, resource limits, memory handling, actionable errors |
| 3 | [Vulkan 1.1 compatibility](03-vulkan11-compatibility.md) | Stage 2 | Alternate owned backend, initially selectable at build time, matching public drawing behavior |
| 4 | [Runtime selection](04-renderer-selection.md) | Stage 3 | One executable with Auto and explicit backend selection, in-app settings, then safe live switching |
| 5 | [Custom shaders](05-custom-shaders.md) | Stage 4, including registry/replay | Portable custom fragment effects and materials on both Vulkan backends |

Platform integration goes first because device selection needs a real surface and
clear failure cleanup. Harden that single backend before reusing infrastructure
for compatibility. Runtime selection then coordinates two working implementations;
custom shaders extend the resulting resource registry instead of creating a second
handle/lifetime system.

The first checkpoint inside stage 1 is SDL GPU removal and a working Vulkan 1.3
demo. Complete it before introducing the new platform interface. No later stage
maintains SDL GPU compatibility or its shader/build dependencies.

## Shared decisions

These decisions apply to every plan. Change the relevant documents together if
implementation reveals a reason to revise them.

### Backends and selection

- Retain only Reify-owned `vulkan13` and `vulkan11`. Remove SDL GPU in stage 1.
  SDL and GLFW can still supply windows/surfaces through host adapters.
- Stages 1–2 retain the existing build-time `vulkan13` choice. Stage 3 temporarily
  adds build-time `vulkan11` selection so it can be validated independently.
- Stage 4 replaces selected-backend build config with runtime `auto`, `vulkan13`,
  and `vulkan11`; build config then controls inclusion only. Auto prefers 1.3,
  then 1.1, among candidates meeting hardware and application requirements.
- Explicit backend selection never silently falls back. Auto may try another
  validated candidate after bounded, properly cleaned-up initialization failure.
  A backend does not select its own replacement.
- The host owns settings persistence and UI. Precedence is explicit launch/session
  override, saved preference, then Auto. Preserve requested and active selections
  separately. Handle retired `sdlgpu` settings as an explicit host migration.

### Platform, initialization, and errors

- Keep one `init(renderer, info)` contract. Stage 1 introduces `Renderer_Init_Info`;
  stage 4 extends its config with runtime preference and application requirements.
  Stage 5 supplies shader requirements through that same mechanism.
- Reify manages loader lifetime. The host owns the window and callback state;
  Reify owns the Vulkan instance/device and invokes adapter surface destruction
  exactly once after successful surface creation, before instance destruction.
- Initialize instance, then surface, then select a present-capable device/queues,
  then create GPU resources. Do not add a second manual `set_surface` lifecycle.
- Support separate graphics/presentation queue families using concurrent swapchain
  sharing initially. Both backends follow this policy.
- Initially permit one active renderer/device per process because dispatch is
  global. No background probes that overwrite dispatch while rendering. Cached UI
  reports are provisional; fresh activation probes run in the serialized lifecycle.
- Stage 1 defines common structured errors and rollback ownership; later stages
  extend those types rather than adding incompatible error APIs.
- Drawing coordinates are logical; swapchain/viewport/scissor extents are pixels.
  Adapters report framebuffer size and the host supplies logical resize updates.
  Zero-size windows defer presentation while valid resource operations continue.

### Resources and rendering behavior

- Preserve submission order, premultiplied linear color, additive behavior, MSDF
  text, camera/screen mode, and scissor semantics. Texture/material batching may
  merge adjacent compatible draws only.
- Fix the font buffer to one descriptor containing many font records in stage 2;
  stage 3 reuses that model. Vulkan 1.3 retains bindless texture indexing; Vulkan
  1.1 uses one texture per batch and ordinary instance storage buffers.
- Negotiate limits before allocation, report effective capacities, and check
  inputs/handles before GPU use. Memory budgets are advisory, not allocation promises.
- Initially wait for affected in-flight work before publishing mutable shared
  descriptor/font changes. Frame-owned instance uploads remain separate. More
  elaborate per-frame resource versions are performance follow-ups.
- Stage 4 owns the neutral, generation-checked texture/font registry and replay
  callbacks. Stage 5 extends it for shader/material resources. Live switching
  requires replayability and enough capacity on the target; otherwise use a
  documented restart path or reject an unsupported selection.
- Stage 5 snapshots material parameters into frame-owned storage so changes never
  alter already recorded draws. Reserve its descriptor/buffer budget during
  initialization; earlier hardware checks must be extended with actual shader use.
- Vulkan 1.1 shaders must retain the compatibility baseline. Custom packages
  declare per-backend variants; missing variants or disabled features are errors,
  not reasons to silently substitute an effect or recreate a live device.

## Delivery gates

1. **Platform gate:** current demo builds without sibling Substrate/parent shader
   assets; SDL GPU is removed; surface lifetime/failure cleanup and basic rendering
   work through the new interface. Future backends are not required for this gate.
2. **Robustness gate:** suitability filtering and safe resource limits work on the
   current backend; diagnostics distinguish incompatibility from allocation/driver
   failure. Validation and focused failure checks pass.
3. **Compatibility gate:** both build-selected backends render the parity scenes;
   Vulkan 1.1 does not accidentally require modern optional features. Document
   real-device coverage and any untested hardware rather than inferring support.
4. **Runtime gates:** ship startup Auto/explicit selection first, then in-app
   preference with restart apply. Next complete registry/replay and live switching
   with restoration and a defined stopped state on unrecoverable failure. Stage 5
   depends on this resource/lifecycle foundation, not just the settings dropdown.
5. **Shader gate:** pass-through and custom effects work on both backends, resource
   replay and lifetime remain correct, and incompatible packages fail clearly.
   Advanced vertex/fragment hooks and post-processing are later extensions.

Run checks appropriate to each implementation step; do not turn this roadmap into
an unrelated full-engine rewrite. Keep completed behavior intact while later
stages extend it. Report missing test hardware and blocked external prerequisites
explicitly; a documentation change alone does not satisfy an implementation gate.

## Scope after review

The review reconciled backend ownership, compile-time versus runtime milestones,
the initialization signature, surface creation order, error ownership, queue
sharing, resource mutation, global dispatch/probing, and shader replay. The
numbered plans use these same decisions. Their remaining design details can be
resolved during their owning stage without implementing later stages early.

Not included: automatic device-loss recovery, concurrent devices/renderers,
arbitrary external Vulkan-device adoption, non-Vulkan rendering backends, a full
windowing framework, or an unrestricted shader/render-graph API.
