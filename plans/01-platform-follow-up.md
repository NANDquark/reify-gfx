# Platform simplifications

## Status

`todo` — Implementation has not started.

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
