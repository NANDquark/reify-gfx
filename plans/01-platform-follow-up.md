# Platform simplifications

## Status

`completed` — Logical resize updates dimensions/projection only; surface adapters
supply borrowed extension slices without retaining names after initialization;
validation-layer enumeration is conditional, checked, and uses a fixed array/count.
Platform documentation and stage-2 layer guidance are updated.

Validation: core, GLFW, and SDL checks and all four lifecycle/scissor/resize/layer
tests passed with validation enabled and disabled (Odin memory tracking enabled).
Tests cover missing/nil/duplicate extensions, rollback, unchanged/changed logical
resize, absent validation layers, and both layer-enumeration failure points.
GLFW smoke and SDL smoke (`Example_Smoke_Test=true`, `Example_Frames=48`) passed
with Vulkan validation, exercising pixel resize, injected zero-size/restoration,
vsync changes, and successful-init borrowed-slice release. No validation diagnostics.
Physical DPI changes, separate queue-family hardware, and Windows remain untested.

Small follow-up to [01-platform.md](01-platform.md), before stage 2.

## Changes

1. Make logical resize update only the stored dimensions and projection, returning
   early when unchanged. Leave swapchain recreation to framebuffer-size polling,
   out-of-date/suboptimal results, and vsync changes. This avoids the SDL example
   recreating its swapchain every frame.
2. Replace the instance-extension callback with a borrowed `[]cstring` field in
   `Vulkan_Surface_Interface`. Hosts query extensions before calling `init` and
   handle provider errors themselves. Names remain valid through synchronous
   initialization; Reify still combines, deduplicates, and validates them. Update
   adapters, callback validation, tests, and the platform contract documentation.
3. Enumerate validation layers only when validation is enabled. Replace dynamic
   layer lists and the generic requested-layer loop with one fixed array and an
   enabled count. Check enumeration results and retain the missing-layer warning.

Keep surface callbacks, ownership, `init(renderer, info)`, structured errors, and
backend `when` dispatch unchanged. Coordinate layer handling with stage 2.

## Validation

- Check the core and both examples; run lifecycle/scissor tests.
- Verify repeated identical logical resize leaves the swapchain unchanged;
  changed logical size updates projection without forcing recreation.
- Run GLFW smoke and SDL checks with validation, covering pixel resize,
  zero-size restoration, and vsync changes.
- Verify missing/duplicate extensions and initialization rollback; no borrowed
  extension names remain after initialization.
- Check validation-enabled and disabled builds, including missing-layer handling.
