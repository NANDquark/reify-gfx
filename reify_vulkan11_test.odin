package reify

import "core:log"
import "core:strings"
import "core:testing"
import vk "vendor:vulkan"

@(test)
vulkan11_interface_subtyping :: proc(t: ^testing.T) {
	r := new(Vulkan11_Renderer)
	defer free(r)
	r.resources_allocator = context.allocator
	base: ^Renderer = r
	interface: Renderer_Backend_Interface
	interface = VULKAN11_RENDERER_BACKEND
	testing.expect(t, base == cast(^Renderer)r)
	r.gpu.limits = {
		textures  = 11,
		fonts     = 12,
		instances = 13,
	}
	testing.expect_value(t, interface.effective_limits(base), r.gpu.limits)
	interface.window_resize(base, 110, 111)
	testing.expect_value(t, r.window.width, i32(110))
	testing.expect_value(t, r.window.height, i32(111))
	interface.set_vsync(base, true)
	testing.expect(t, r.swapchain.vsync_enabled && !r.swapchain.needs_update)
	r.initialized = true
	interface.start(base, {}, 1)
	interface.draw_rect(base, {1, 2}, 3, 4, {255, 255, 255, 255})
	testing.expect_value(t, r.frame_contexts[r.frame_index].total_instances, 1)
	r.initialized = false
	testing.expect(t, !interface.present(base, {}))
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_State)
	for &frame in r.frame_contexts do delete(frame.draw_batches)
	interface.destroy(base)
	testing.expect_value(t, r.frame_index, 0)
	testing.expect_value(t, r.window.width, i32(0))
	testing.expect_value(t, interface.effective_limits(base), Negotiated_Limits{})
}

@(test)
vulkan11_device_report_logging :: proc(t: ^testing.T) {
	capture: Public_Error_Log
	test_logger := context.logger
	gpu: Vulkan11_GPU_Context
	gpu.capabilities.memory.memoryHeapCount = 1
	budget_states := [?]bool{false, true}
	for known in budget_states {
		gpu.capabilities.budget_known = known
		capture = {}
		context.logger = {
			procedure = public_error_log,
			data      = &capture,
		}
		vulkan11_report_device(&gpu)
		context.logger = test_logger
		testing.expect_value(t, capture.calls, 4)
		testing.expect_value(t, capture.level, log.Level.Info)
		message := string(capture.message[:capture.length])
		testing.expect(t, strings.contains(message, "Heap 0:"))
		testing.expect(
			t,
			strings.contains(
				message,
				"budget=0 usage=0 estimated headroom=0" if known else "budget=unknown",
			),
		)
	}
}

when RENDERER_BACKEND_TYPE == .Vulkan_1_1 {
	@(test)
	vulkan11_baseline_requirements :: proc(t: ^testing.T) {
		caps := vulkan11_capability_fixture()
		limits, rejection := vulkan11_compare_requirements(caps, vulkan11_requirements())
		testing.expect_value(t, rejection.error.category, Renderer_Error_Category.None)
		testing.expect_value(t, limits.textures, u32(VULKAN11_TEXTURE_MAX_COUNT))
		testing.expect_value(t, limits.instances, u32(QUAD_MAX_INSTANCES))
		caps.properties.limits.maxStorageBufferRange = 64
		caps.properties.limits.maxDrawIndexedIndexValue = 7
		limits, rejection = vulkan11_compare_requirements(caps, vulkan11_requirements())
		testing.expect_value(t, rejection.error.category, Renderer_Error_Category.None)
		testing.expect_value(t, limits.instances, u32(2))
		testing.expect_value(t, limits.fonts, u32(4))
		caps.properties.apiVersion = vk.API_VERSION_1_0
		_, rejection = vulkan11_compare_requirements(caps, vulkan11_requirements())
		testing.expect_value(t, rejection.error.category, Renderer_Error_Category.Unsupported_API)
		caps = vulkan11_capability_fixture()
		caps.swapchain = false
		_, rejection = vulkan11_compare_requirements(caps, vulkan11_requirements())
		testing.expect_value(
			t,
			rejection.error.category,
			Renderer_Error_Category.Missing_Extension,
		)
		for field in 0 ..< 5 {
			caps = vulkan11_capability_fixture()
			switch field {
			case 0:
				caps.properties.limits.maxPerStageDescriptorStorageBuffers = 1
			case 1:
				caps.properties.limits.maxBoundDescriptorSets = 1
			case 2:
				caps.properties.limits.maxDescriptorSetStorageBuffersDynamic = 0
			case 3:
				caps.properties.limits.maxPushConstantsSize = 63
			case 4:
				caps.properties.limits.maxPerStageResources = 2
			}
			_, rejection = vulkan11_compare_requirements(caps, vulkan11_requirements())
			testing.expect_value(
				t,
				rejection.error.category,
				Renderer_Error_Category.Insufficient_Limits,
			)
		}
		bindings := vulkan11_descriptor_bindings()
		testing.expect_value(t, bindings[0].descriptorCount, u32(1))
		testing.expect_value(
			t,
			bindings[0].descriptorType,
			vk.DescriptorType.STORAGE_BUFFER_DYNAMIC,
		)
		testing.expect_value(t, bindings[1].descriptorCount, u32(1))
	}

	@(test)
	vulkan11_ordered_texture_batches :: proc(t: ^testing.T) {
		r := new(Vulkan11_Renderer)
		defer free(r)
		r.backend_type = .Vulkan_1_1
		r.initialized = true
		r.resources_allocator = context.allocator
		r.window.width, r.window.height = 800, 600
		r.gpu.limits.instances = 20
		resize(&r.resources.textures, 3)
		defer delete(r.resources.textures)
		defer for &frame in r.frame_contexts do delete(frame.draw_batches)
		start(r, {}, 1)
		begin_screen_mode(r)
		draw_image(r, {idx = 1}, {}, alpha = 0.5)
		draw_image(r, {idx = 1}, {}, is_additive = true)
		draw_image(r, {idx = 2}, {})
		draw_image(r, {idx = 1}, {})
		draw_rect(r, {}, 10, 10, {255, 255, 255, 128})
		set_scissor(r, 10, 20, 30, 40)
		draw_image(r, {idx = 1}, {})
		end_screen_mode(r)
		draw_image(r, {idx = 1}, {})
		frame := &r.frame_contexts[r.frame_index]
		textures := [?]int{1, 2, 1, 0, 1, 1}
		counts := [?]int{2, 1, 1, 1, 1, 1}
		batch_index, offset: int
		for batch in frame.draw_batches {
			if batch.num_instances == 0 do continue
			testing.expect_value(t, batch.texture, textures[batch_index])
			testing.expect_value(t, batch.num_instances, counts[batch_index])
			testing.expect_value(t, batch.index_offset, offset)
			testing.expect_value(
				t,
				batch.projection_type,
				Projection_Type.World if batch_index == 5 else Projection_Type.Screen,
			)
			if batch_index >= 4 {
				testing.expect_value(
					t,
					batch.scissor,
					vk.Rect2D{offset = {10, 20}, extent = {30, 40}},
				)
			}
			offset += batch.num_instances
			batch_index += 1
		}
		testing.expect_value(t, batch_index, len(textures))
		testing.expect_value(t, frame.total_instances, 7)
		context.logger = log.nil_logger()
		draw_image(r, {idx = -1}, {})
		testing.expect(t, r.frame_failed)
		testing.expect_value(t, frame.total_instances, 7)
	}

	@(test)
	vulkan11_chunk_indices :: proc(t: ^testing.T) {
		capacities := [?]int{1, 2, 3, 17, QUAD_MAX_INSTANCES}
		for capacity in capacities {
			starts := [?]int{0, capacity - 1, capacity, capacity + 1}
			for start in starts {
				first := start
				end := start + capacity * 2 + 3
				for first < end {
					chunk, local, count := vulkan11_chunk_draw(first, end - first, capacity)
					testing.expect(t, count > 0 && count <= end - first)
					testing.expect(t, local >= 0 && local + count <= capacity)
					testing.expect_value(t, chunk * capacity + local, first)
					first += count
				}
				testing.expect_value(t, first, end)
			}
		}
	}

	@(test)
	vulkan11_cleanup_clears_state :: proc(t: ^testing.T) {
		r := new(Vulkan11_Renderer)
		defer free(r)
		r.initialized, r.loader_owned, r.stopped = true, true, true
		r.window.width = 800
		vulkan11_destroy(r)
		testing.expect(t, !r.initialized && !r.loader_owned && !r.stopped)
		testing.expect_value(t, r.window.width, i32(0))
		testing.expect(t, r.gpu.instance == {} && r.gpu.device == {})
	}

	vulkan11_capability_fixture :: proc() -> Vulkan11_Device_Capabilities {
		return {
			swapchain = true,
			memory = {
				memoryTypeCount = 1,
				memoryTypes = {0 = {propertyFlags = {.HOST_VISIBLE, .DEVICE_LOCAL}}},
			},
			properties11 = {maxMemoryAllocationSize = 128 * 1024 * 1024},
			properties = {
				apiVersion = vk.API_VERSION_1_1,
				limits = {
					maxPushConstantsSize = 128,
					maxStorageBufferRange = 128 * 1024 * 1024,
					maxPerStageDescriptorStorageBuffers = 4,
					maxDescriptorSetStorageBuffers = 4,
					maxDescriptorSetStorageBuffersDynamic = 4,
					maxBoundDescriptorSets = 4,
					maxPerStageDescriptorSamplers = 16,
					maxPerStageDescriptorSampledImages = 16,
					maxDescriptorSetSamplers = 16,
					maxDescriptorSetSampledImages = 16,
					maxPerStageResources = 128,
					maxDrawIndexedIndexValue = max(u32),
					maxMemoryAllocationCount = 4096,
					maxImageDimension2D = 4096,
				},
			},
		}
	}

	when bool(#config(Reify_Integration_Test, false)) {
		@(test)
		vulkan11_descriptor_pool_growth :: proc(t: ^testing.T) {
			f := integration_fixture_make(t)
			if f == nil do return
			context = integration_fixture_context(f)
			assert(integration_renderer_init(f))
			textures: [130]Texture_Handle
			for &texture in textures {
				handle, ok := texture_load(&f.renderer, f.white[:], 1, 1)
				assert(ok)
				texture = handle
			}
			assert(len(f.renderer.resources.texture_pools) >= 3)
			for _ in 0 ..< 6 {
				start(&f.renderer, {}, 1)
				for texture, i in textures {
					draw_image(&f.renderer, texture, {f32(i), 0})
				}
				assert(present(&f.renderer))
			}
		}
	}
}
