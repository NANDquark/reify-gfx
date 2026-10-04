package reify

import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"
import "lib/vma"
import vk "vendor:vulkan"

@(test)
vulkan13_present_error_style :: proc(t: ^testing.T) {
	testing.expect(t, !vulkan13_present(nil))
	r := new(Vulkan13_Rendererer)
	defer free(r)
	testing.expect(t, !vulkan13_present(r))
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_State)
	testing.expect(t, !r.stopped)

	r.initialized = true
	r.stopped = true
	testing.expect(t, !vulkan13_present(r))
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_State)

	r.stopped = false
	r.frame_started = true
	r.frame_failed = true
	testing.expect(t, !vulkan13_present(r))
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_Input)
	testing.expect(t, !r.frame_started && !r.stopped)

	r.frame_failed = false
	r.frame_started = true
	r.platform.get_framebuffer_size = proc(_: rawptr) -> ([2]int, Platform_Error) {
		return {}, {}
	}
	testing.expect(t, vulkan13_present(r))
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.None)
	testing.expect(t, !r.frame_started && !r.stopped)

	r.frame_started = true
	r.platform.get_framebuffer_size = proc(_: rawptr) -> ([2]int, Platform_Error) {
		return {}, {message = "framebuffer query failed", result = .ERROR_DEVICE_LOST}
	}
	testing.expect(t, !vulkan13_present(r))
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Platform_Failure)
	testing.expect_value(t, r.last_error.result, Renderer_Result.Device_Lost)
	testing.expect_value(t, error_message(&r.last_error), "framebuffer query failed")
	testing.expect(t, !r.frame_started && r.stopped)
}

@(test)
vulkan13_texture_error_style :: proc(t: ^testing.T) {
	handle, ok := vulkan13_texture_load(nil, nil, 0, 0)
	testing.expect(t, !ok && handle.idx == -1)
	r := new(Vulkan13_Rendererer)
	defer free(r)
	r.resources_allocator = context.allocator
	defer delete(r.resources.textures)
	handle, ok = vulkan13_texture_load(r, nil, 0, 0)
	testing.expect(t, !ok && handle.idx == -1)
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_State)
	testing.expect(t, !r.stopped)

	// Validation rejects these inputs before any allocator or device calls.
	r.gpu.allocator = cast(vma.Allocator)uintptr(1)
	r.last_error = renderer_error(.Resources, .Device_Lost, "stale diagnostic")
	handle, ok = vulkan13_texture_load(r, nil, 0, 0)
	testing.expect(t, !ok && handle.idx == -1)
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_Input)
	testing.expect(t, !r.stopped)

	pixels := []Color{{255, 255, 255, 255}}
	handle, ok = vulkan13_texture_load(r, pixels, 1, 1)
	testing.expect(t, !ok && handle.idx == -1)
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Insufficient_Limits)

	r.gpu.limits.max_image_dimension = 1
	handle, ok = vulkan13_texture_load(r, pixels, 1, 1)
	testing.expect(t, !ok && handle.idx == -1)
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Capacity_Exhausted)

	r.gpu.limits.textures = 1
	handle, ok = vulkan13_texture_load_with_sampler(r, pixels, 1, 1, vk.Sampler{})
	testing.expect(t, !ok && handle.idx == -1)
	testing.expect_value(t, r.last_error.category, Renderer_Error_Category.Invalid_Input)
	testing.expect_value(t, error_message(&r.last_error), "texture sampler is null")
	testing.expect(t, !r.stopped)
}

@(test)
vulkan13_interface_subtyping :: proc(t: ^testing.T) {
	r := new(Vulkan13_Rendererer)
	defer free(r)
	r.resources_allocator = context.allocator
	base: ^Renderer = r
	interface: Renderer_Backend_Interface
	interface = VULKAN13_RENDERER_BACKEND
	testing.expect(t, base == cast(^Renderer)r)
	r.gpu.limits = {
		textures  = 13,
		fonts     = 14,
		instances = 15,
	}
	testing.expect_value(t, interface.effective_limits(base), r.gpu.limits)
	interface.window_resize(base, 130, 131)
	testing.expect_value(t, r.window.width, i32(130))
	testing.expect_value(t, r.window.height, i32(131))
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
vulkan13_device_report_logging :: proc(t: ^testing.T) {
	capture: Public_Error_Log
	test_logger := context.logger
	gpu: Vulkan13_GPU_Context
	gpu.capabilities.memory.memoryHeapCount = 1
	budget_states := [?]bool{false, true}
	for known in budget_states {
		gpu.capabilities.budget_known = known
		capture = {}
		context.logger = {
			procedure = public_error_log,
			data      = &capture,
		}
		vulkan13_report_device(&gpu)
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

when RENDERER_BACKEND_TYPE == .Vulkan_1_3 {

	@(test)
	vulkan13_cleanup_clears_state :: proc(t: ^testing.T) {
		r := new(Vulkan13_Rendererer)
		defer free(r)
		r.resources_allocator = context.allocator
		r.platform.user_data = r
		r.initialized = true
		r.loader_owned = true
		r.stopped = true
		r.frame_started = true
		r.frame_failed = true
		r.window.width, r.window.height = 800, 600
		r.framebuffer_size = {1600, 1200}
		r.perf.draw_calls = 7
		r.frame_index = 2
		r.gpu.limits.instances = 42
		r.swapchain.needs_update = true
		common: ^Renderer = r
		testing.expect(t, common == cast(^Renderer)r)
		vulkan13_destroy(r)

		testing.expect(t, !r.initialized && !r.loader_owned && !r.stopped)
		testing.expect(t, !r.frame_started && !r.frame_failed)
		testing.expect(t, r.resources_allocator.procedure == nil && r.platform.user_data == nil)
		testing.expect_value(t, r.window.width, i32(0))
		testing.expect_value(t, r.window.height, i32(0))
		testing.expect_value(t, r.framebuffer_size, [2]int{})
		testing.expect_value(t, r.perf.draw_calls, 0)
		testing.expect_value(t, r.frame_index, 0)
		testing.expect_value(t, r.gpu.limits.instances, u32(0))
		testing.expect(t, !r.swapchain.needs_update)
	}

	@(test)
	vulkan13_requirement_fixtures :: proc(t: ^testing.T) {
		req := vulkan13_requirements()
		good := vulkan13_capability_fixture()
		limits, rejected := vulkan13_compare_requirements(good, req)
		testing.expect_value(t, rejected.error.category, Renderer_Error_Category.None)
		testing.expect_value(t, limits.textures, u32(VULKAN13_TEXTURE_MAX_COUNT))
		// Optional indexing, anisotropy, and memory budgets are not shader requirements.
		testing.expect(
			t,
			!good.budget_known && !bool(good.features12.descriptorBindingVariableDescriptorCount),
		)
		for feature in 0 ..< 6 {
			candidate := good
			switch feature {
			case 0:
				candidate.features11.shaderDrawParameters = false
			case 1:
				candidate.features12.bufferDeviceAddress = false
			case 2:
				candidate.features12.runtimeDescriptorArray = false
			case 3:
				candidate.features12.shaderSampledImageArrayNonUniformIndexing = false
			case 4:
				candidate.features13.dynamicRendering = false
			case 5:
				candidate.features13.synchronization2 = false
			}
			_, rejection := vulkan13_compare_requirements(candidate, req)
			testing.expect_value(
				t,
				rejection.error.category,
				Renderer_Error_Category.Missing_Feature,
			)
			testing.expect(t, len(error_message(&rejection.error)) > 0)
		}
		for bad in 0 ..< 4 {
			candidate := good
			switch bad {
			case 0:
				candidate.properties.apiVersion = vk.API_VERSION_1_2
			case 1:
				candidate.swapchain = false
			case 2:
				candidate.properties.limits.maxStorageBufferRange = VULKAN13_FONT_BUFFER_SIZE - 1
			case 3:
				candidate.properties13.maxBufferSize = size_of(Quad_Shader_Data) - 1
			}
			_, rejection := vulkan13_compare_requirements(candidate, req)
			testing.expect(t, rejection.error.category != .None)
		}
	}

	@(test)
	vulkan13_descriptor_capacity :: proc(t: ^testing.T) {
		l := vulkan13_capability_fixture().properties.limits
		for bound in 0 ..< 5 {
			limited := l
			switch bound {
			case 0:
				limited.maxPerStageDescriptorSamplers = 7
			case 1:
				limited.maxPerStageDescriptorSampledImages = 7
			case 2:
				limited.maxDescriptorSetSamplers = 7
			case 3:
				limited.maxDescriptorSetSampledImages = 7
			case 4:
				limited.maxPerStageResources = 8
			}
			testing.expect_value(t, vulkan13_texture_capacity(limited, 1024), u32(7))
		}
		l.maxPerStageResources = 0
		testing.expect_value(t, vulkan13_texture_capacity(l, 1024), u32(0))
		l.maxPerStageResources = 1
		testing.expect_value(t, vulkan13_texture_capacity(l, 1024), u32(0))
		bindings := vulkan13_descriptor_bindings(7)
		testing.expect_value(t, bindings[0].descriptorCount, u32(7))
		testing.expect_value(t, bindings[1].descriptorCount, u32(1))
	}

	@(test)
	vulkan13_heap_accounting :: proc(t: ^testing.T) {
		testing.expect_value(t, vulkan13_heap_headroom(10, 7), vk.DeviceSize(3))
		testing.expect_value(t, vulkan13_heap_headroom(10, 11), vk.DeviceSize(0))
		testing.expect_value(
			t,
			vulkan13_heap_headroom(max(vk.DeviceSize), max(vk.DeviceSize)),
			vk.DeviceSize(0),
		)
		gpu: Vulkan13_GPU_Context
		c := &gpu.capabilities
		c.memory.memoryHeapCount = 1
		c.memory.memoryHeaps[0] = {
			size  = 100,
			flags = {.DEVICE_LOCAL},
		}
		c.memory.memoryTypeCount = 3
		c.memory.memoryTypes[0] = {
			propertyFlags = {.DEVICE_LOCAL},
			heapIndex     = 0,
		}
		c.memory.memoryTypes[1] = {
			propertyFlags = {.HOST_VISIBLE},
			heapIndex     = 0,
		}
		c.memory.memoryTypes[2] = {
			propertyFlags = {.HOST_VISIBLE, .HOST_COHERENT},
			heapIndex     = 0,
		}
		summary := vulkan13_memory_summary(&gpu)
		testing.expect_value(t, summary.heap_count, u32(1))
		testing.expect_value(t, summary.heaps[0].size, u64(100))
		testing.expect(
			t,
			summary.heaps[0].device_local &&
			summary.heaps[0].host_visible &&
			!summary.heaps[0].budget_known,
		)
		c.budget_known, c.budgets[0], c.usages[0] = true, 80, 90
		summary = vulkan13_memory_summary(&gpu)
		testing.expect(t, summary.heaps[0].budget_known)
		testing.expect_value(t, summary.heaps[0].estimated_headroom, u64(0))
	}

	@(test)
	vulkan13_input_and_submission_bounds :: proc(t: ^testing.T) {
		context.logger = log.nil_logger()
		invalid_sizes := [][2]int {
			{0, 1},
			{-1, 1},
			{1, 0},
			{max(int), 2},
			{int(max(u32)), int(max(u32))},
		}
		for size in invalid_sizes {
			_, ok := vulkan13_pixel_count(size.x, size.y)
			testing.expect(t, !ok)
		}
		count, ok := vulkan13_pixel_count(3, 7)
		testing.expect(t, ok)
		testing.expect_value(t, count, 21)
		r := new(Vulkan13_Rendererer)
		defer free(r)
		r.backend_type = .Vulkan_1_3
		r.resources_allocator = context.allocator
		handle, load_ok := texture_load(r, nil, 0, 1)
		testing.expect_value(t, handle.idx, -1)
		testing.expect(t, !load_ok)
		r.initialized = true
		r.gpu.limits.instances = 1
		start(r, {}, 1)
		defer for &frame in r.frame_contexts do delete(frame.draw_batches)
		vulkan13_append_instance(r, {type = u32(Quad_Instance_Type.Rect)})
		vulkan13_append_instance(r, {type = u32(Quad_Instance_Type.Rect)})
		testing.expect_value(t, r.frame_contexts[r.frame_index].total_instances, 1)
		testing.expect(t, r.frame_failed)
		testing.expect(t, !present(r))
		testing.expect(t, !r.stopped)
		start(r, {}, 1)
		vulkan13_draw_image(r, {idx = -1}, {})
		testing.expect(t, r.frame_failed)
		testing.expect_value(t, r.frame_contexts[r.frame_index].total_instances, 0)
	}

	@(test)
	vulkan13_enumeration_retry :: proc(t: ^testing.T) {
		sync.mutex_lock(&platform_test_dispatch_mutex)
		defer sync.mutex_unlock(&platform_test_dispatch_mutex)
		saved := vk.EnumerateInstanceExtensionProperties
		defer vk.EnumerateInstanceExtensionProperties = saved
		vk.EnumerateInstanceExtensionProperties = robustness_extensions
		robustness_enumeration_calls = 0
		items, res := vk_enumerate(vk.ExtensionProperties)
		defer delete(items, context.temp_allocator)
		testing.expect_value(t, res, vk.Result.SUCCESS)
		testing.expect_value(t, len(items), 2)
		testing.expect_value(t, robustness_enumeration_calls, 4)
	}

	@(test)
	vulkan13_format_preferences :: proc(t: ^testing.T) {
		_, ok := vulkan13_surface_format(
			[]vk.SurfaceFormatKHR{{.B8G8R8A8_UNORM, .COLORSPACE_SRGB_NONLINEAR}},
		)
		testing.expect(t, !ok)
		f, valid := vulkan13_surface_format(
			[]vk.SurfaceFormatKHR{{.R8G8B8A8_SRGB, .COLORSPACE_SRGB_NONLINEAR}},
		)
		testing.expect(t, valid)
		testing.expect_value(t, f.format, vk.Format.R8G8B8A8_SRGB)
		testing.expect(
			t,
			vulkan13_device_priority(.DISCRETE_GPU) > vulkan13_device_priority(.INTEGRATED_GPU),
		)
	}

	@(test)
	vulkan13_candidate_and_queue_selection :: proc(t: ^testing.T) {
		candidates := [3]Vulkan13_Device_Candidate {
			{priority = vulkan13_device_priority(.DISCRETE_GPU), usable_memory = 1, tried = true},
			{priority = vulkan13_device_priority(.INTEGRATED_GPU), usable_memory = max(u64)},
			{priority = vulkan13_device_priority(.DISCRETE_GPU), usable_memory = 0},
		}
		testing.expect_value(t, vulkan13_choose_candidate(candidates[:]), 2)
		candidates[2].tried = true
		testing.expect_value(t, vulkan13_choose_candidate(candidates[:]), 1)
		candidates[1].tried = true
		testing.expect_value(t, vulkan13_choose_candidate(candidates[:]), -1)
		queues := []vk.QueueFamilyProperties {
			{queueFlags = {.GRAPHICS}, queueCount = 1},
			{queueFlags = {.TRANSFER}, queueCount = 1},
		}
		graphics, present := vulkan13_choose_queues(queues, []bool{false, true})
		testing.expect_value(t, graphics, u32(0))
		testing.expect_value(t, present, u32(1))
		queues[1].queueFlags = {.GRAPHICS}
		graphics, present = vulkan13_choose_queues(queues, []bool{false, true})
		testing.expect_value(t, graphics, u32(1))
		testing.expect_value(t, present, u32(1))
	}

	@(private)
	vulkan13_capability_fixture :: proc() -> Vulkan13_Device_Capabilities {
		req := vulkan13_requirements()
		return {
			properties = {
				apiVersion = vk.API_VERSION_1_3,
				limits = {
					maxPushConstantsSize = 128,
					maxStorageBufferRange = VULKAN13_FONT_BUFFER_SIZE,
					maxPerStageDescriptorStorageBuffers = 1,
					maxDescriptorSetStorageBuffers = 1,
					maxBoundDescriptorSets = 1,
					maxDrawIndexedIndexValue = max(u32),
					maxMemoryAllocationCount = 4096,
					maxPerStageDescriptorSamplers = 1024,
					maxPerStageDescriptorSampledImages = 1024,
					maxDescriptorSetSamplers = 1024,
					maxDescriptorSetSampledImages = 1024,
					maxPerStageResources = 1025,
					maxImageDimension2D = 4096,
				},
			},
			properties11 = {
				maxMemoryAllocationSize = size_of(Quad_Shader_Data),
				maxPerSetDescriptors = 1025,
			},
			properties13 = {maxBufferSize = size_of(Quad_Shader_Data)},
			features11 = req.features11,
			features12 = req.features12,
			features13 = req.features13,
			swapchain = true,
		}
	}

	@(private)
	robustness_enumeration_calls: int
	@(private)
	robustness_extensions :: proc "system" (
		layer: cstring,
		count: ^u32,
		items: [^]vk.ExtensionProperties,
	) -> vk.Result {
		robustness_enumeration_calls += 1
		if items == nil {
			count^ = 1 if robustness_enumeration_calls == 1 else 2
			return .SUCCESS
		}
		if robustness_enumeration_calls == 2 {
			count^ = 1
			return .INCOMPLETE
		}
		items[0], items[1], count^ = {}, {}, 2
		return .SUCCESS
	}

}
