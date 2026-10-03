#+private
package reify

import "base:runtime"
import "core:sync"
import "core:testing"
import vk "vendor:vulkan"

// Lifecycle tests serialize Vulkan dispatch and inject failures after ownership transfers.
@(test)
platform_lifecycle :: proc(t: ^testing.T) {
	sync.mutex_lock(&platform_test_dispatch_mutex)
	defer sync.mutex_unlock(&platform_test_dispatch_mutex)
	r := new(Renderer)
	defer free(r)
	state: Platform_Test_State
	info := Renderer_Init_Info {
		platform     = test_platform(&state),
		logical_size = {800, 600},
	}
	for missing in 0 ..< 3 {
		bad := info
		switch missing {
		case 0:
			bad.platform.get_framebuffer_size = nil
		case 1:
			bad.platform.vulkan.create_surface = nil
		case 2:
			bad.platform.vulkan.destroy_surface = nil
		}
		err := vulkan13_init(r, bad)
		testing.expect_value(t, err.category, Renderer_Error_Category.Missing_Capability)
		testing.expect(t, active_renderer == nil && !r.loader_owned)
	}
	other := new(Renderer)
	defer free(other)
	sync.atomic_store(&active_renderer, r)
	occupied := vulkan13_init(other, info)
	testing.expect_value(t, occupied.category, Renderer_Error_Category.Invalid_State)
	testing.expect(t, active_renderer == r && !other.loader_owned)
	destroy(other)
	testing.expect(t, active_renderer == r)
	sync.atomic_store(&active_renderer, cast(^Renderer)nil)
	for mode in Platform_Test_Mode {
		state = {
			mode       = mode,
			extensions = {vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_SURFACE_EXTENSION_NAME},
		}
		if mode == .Missing_Extension do state.extensions[0] = "VK_REIFY_missing_extension"
		if mode == .Nil_Extension do state.extensions[0] = nil
		err := vulkan13_init(r, info)
		testing.expect(t, err.category != .None)
		testing.expect(t, active_renderer == nil && !r.loader_owned && r.gpu.instance == {})
		testing.expect(t, len(r.platform.vulkan.required_instance_extensions) == 0)
		if mode == .Missing_Extension || mode == .Nil_Extension {
			testing.expect_value(t, err.category, Renderer_Error_Category.Missing_Extension)
			testing.expect_value(t, state.created, 0)
		} else if mode == .Surface_Failure {
			testing.expect_value(t, err.stage, Renderer_Error_Stage.Surface)
			testing.expect_value(t, state.created, 1)
			testing.expect_value(t, state.destroyed, 0)
			state.diagnostic = {}
			testing.expect_value(t, error_message(&err), "injected surface failure")
		} else {
			if mode == .No_Present_Device do testing.expect_value(t, err.category, Renderer_Error_Category.No_Present_Device)
			testing.expect_value(t, state.created, 1)
			testing.expect_value(t, state.destroyed, 1)
			if mode == .Resource_Failure do testing.expect_value(t, err.stage, Renderer_Error_Stage.Resources)
			if mode == .Incompatible_First || mode == .Retry_Candidate {
				testing.expect_value(t, err.stage, Renderer_Error_Stage.Resources)
				testing.expect_value(t, test_candidate_queries, 2)
				testing.expect_value(
					t,
					test_candidate_creations,
					1 if mode == .Incompatible_First else 2,
				)
			}
			testing.expect(t, state.instance_alive_at_destroy)
		}
		destroy(r)
		testing.expect(t, state.destroyed <= 1)
	}
}

// Logical size changes cannot schedule or alter pixel presentation resources.
@(test)
platform_logical_resize :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.window.width, r.window.height = 800, 600
	r.window.projection = vk_ortho_projection(0, 800, 0, 600, -1, 1)
	r.swapchain.handle = vk.SwapchainKHR(123)
	r.swapchain.create_info.imageExtent = {1600, 1200}
	original := r.swapchain
	projection := r.window.projection
	for _ in 0 ..< 5 do window_resize(r, 800, 600)
	testing.expect_value(t, r.window.projection, projection)
	testing.expect_value(t, r.swapchain.handle, original.handle)
	testing.expect_value(t, r.swapchain.create_info.imageExtent, original.create_info.imageExtent)
	testing.expect_value(t, r.swapchain.needs_update, original.needs_update)
	window_resize(r, 400, 300)
	testing.expect_value(t, r.window.width, i32(400))
	testing.expect_value(t, r.window.height, i32(300))
	testing.expect_value(t, r.window.projection, vk_ortho_projection(0, 400, 0, 300, -1, 1))
	testing.expect_value(t, r.swapchain.handle, original.handle)
	testing.expect_value(t, r.swapchain.create_info.imageExtent, original.create_info.imageExtent)
	testing.expect_value(t, r.swapchain.needs_update, original.needs_update)
	r.swapchain.needs_update = true
	window_resize(r, 0, 0)
	testing.expect(t, r.swapchain.needs_update)
	testing.expect_value(t, r.window.projection, vk_ortho_projection(0, 1, 0, 1, -1, 1))
}

@(test)
platform_scissor_scaling :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	r.window.width, r.window.height = 800, 600
	r.swapchain.create_info.imageExtent = {1600, 900}
	testing.expect_value(
		t,
		vulkan13_pixel_scissor(r, {offset = {-10, 10}, extent = {110, 20}}),
		vk.Rect2D{offset = {0, 15}, extent = {200, 30}},
	)
	testing.expect_value(
		t,
		vulkan13_pixel_scissor(r, {offset = {900, 700}, extent = {max(u32), max(u32)}}),
		vk.Rect2D{offset = {1600, 900}, extent = {0, 0}},
	)
}

Platform_Test_Mode :: enum {
	Missing_Extension,
	Nil_Extension,
	Surface_Failure,
	After_Surface_Failure,
	No_Present_Device,
	Device_Failure,
	Resource_Failure,
	Incompatible_First,
	Retry_Candidate,
}
Platform_Test_State :: struct {
	mode:                      Platform_Test_Mode,
	created, destroyed:        int,
	instance_alive_at_destroy: bool,
	diagnostic:                [64]u8,
	extensions:                [2]cstring,
}

// Serialized loader tests inspect instance requests without creating a GPU device.
@(test)
platform_instance_layers :: proc(t: ^testing.T) {
	sync.mutex_lock(&platform_test_dispatch_mutex)
	defer sync.mutex_unlock(&platform_test_dispatch_mutex)
	if !testing.expect(t, renderer_loader_init()) do return
	defer renderer_loader_shutdown()
	saved_layers := vk.EnumerateInstanceLayerProperties
	saved_create := vk.CreateInstance
	defer {
		vk.EnumerateInstanceLayerProperties = saved_layers
		vk.CreateInstance = saved_create
	}
	vk.EnumerateInstanceLayerProperties = test_instance_layers
	vk.CreateInstance = test_instance_request
	r := new(Renderer)
	defer free(r)
	for mode in Instance_Layer_Test_Mode {
		instance_layer_test = {
			mode = mode,
		}
		err := gpu_init(r, []cstring{vk.KHR_SURFACE_EXTENSION_NAME, vk.KHR_SURFACE_EXTENSION_NAME})
		testing.expect_value(t, err.stage, Renderer_Error_Stage.Instance)
		testing.expect_value(
			t,
			err.category,
			Renderer_Error_Category.Allocation_Failure if ENABLE_VK_VALIDATION && (mode == .Count_Failure || mode == .Properties_Failure) else Renderer_Error_Category.Vulkan_Failure,
		)
		testing.expect(t, r.gpu.instance == {})
		if ENABLE_VK_VALIDATION && (mode == .Count_Failure || mode == .Properties_Failure) {
			testing.expect_value(t, err.result, Renderer_Result.Out_Of_Host_Memory)
			testing.expect_value(t, error_message(&err), "instance layer enumeration failed")
			testing.expect(t, !instance_layer_test.create_called)
			testing.expect_value(t, instance_layer_test.calls, 1 if mode == .Count_Failure else 2)
		} else {
			testing.expect_value(t, err.result, Renderer_Result.Initialization_Failed)
			testing.expect(t, instance_layer_test.create_called)
			testing.expect_value(t, instance_layer_test.extension_count, u32(1))
			testing.expect_value(
				t,
				instance_layer_test.layer_count,
				u32(1) if ENABLE_VK_VALIDATION && mode == .Present else u32(0),
			)
			testing.expect_value(t, instance_layer_test.calls, 2 if ENABLE_VK_VALIDATION else 0)
			if instance_layer_test.layer_count == 1 do testing.expect(t, instance_layer_test.validation_name)
		}
	}
	instance_layer_test = {
		mode = .Missing,
	}
	err := gpu_init(r, nil)
	testing.expect_value(t, err.result, Renderer_Result.Initialization_Failed)
	testing.expect_value(t, instance_layer_test.extension_count, u32(1))
}

Instance_Layer_Test_Mode :: enum {
	Present,
	Missing,
	Count_Failure,
	Properties_Failure,
}
@(private)
platform_test_dispatch_mutex: sync.Mutex
@(private)
instance_layer_test: struct {
	mode:                           Instance_Layer_Test_Mode,
	calls:                          int,
	create_called, validation_name: bool,
	layer_count, extension_count:   u32,
}

@(private)
test_instance_layers :: proc "system" (
	count: ^u32,
	properties: [^]vk.LayerProperties,
) -> vk.Result {
	context = runtime.default_context()
	instance_layer_test.calls += 1
	if instance_layer_test.mode == .Count_Failure ||
	   (instance_layer_test.mode == .Properties_Failure && properties != nil) {
		return .ERROR_OUT_OF_HOST_MEMORY
	}
	count^ = 1
	if properties != nil {
		properties[0] = {}
		name := "VK_LAYER_REIFY_unrelated"
		if instance_layer_test.mode == .Present do name = "VK_LAYER_KHRONOS_validation"
		copy(properties[0].layerName[:], name)
	}
	return .SUCCESS
}

@(private)
test_instance_request :: proc "system" (
	info: ^vk.InstanceCreateInfo,
	allocations: ^vk.AllocationCallbacks,
	instance: ^vk.Instance,
) -> vk.Result {
	context = runtime.default_context()
	instance_layer_test.create_called = true
	instance_layer_test.extension_count = info.enabledExtensionCount
	instance_layer_test.layer_count = info.enabledLayerCount
	if info.enabledLayerCount == 1 do instance_layer_test.validation_name = string(info.ppEnabledLayerNames[0]) == "VK_LAYER_KHRONOS_validation"
	return .ERROR_INITIALIZATION_FAILED
}

@(private)
test_saved_enumerate: vk.ProcEnumeratePhysicalDevices
@(private)
test_saved_support: vk.ProcGetPhysicalDeviceSurfaceSupportKHR
@(private)
test_saved_device_proc: vk.ProcGetDeviceProcAddr

@(private)
test_saved_create_device: vk.ProcCreateDevice

@(private)
test_platform :: proc(state: ^Platform_Test_State) -> Platform_Interface {
	return {
		user_data = state,
		get_framebuffer_size = test_framebuffer,
		vulkan = {state.extensions[:], test_surface_create, test_surface_destroy},
	}
}

@(private)
test_framebuffer :: proc(data: rawptr) -> ([2]int, Platform_Error) {return {800, 600}, {}}

@(private)
test_surface_create :: proc(
	data: rawptr,
	instance: vk.Instance,
) -> (
	vk.SurfaceKHR,
	Platform_Error,
) {
	state := cast(^Platform_Test_State)data
	state.created += 1
	if state.mode == .Surface_Failure {
		message :: "injected surface failure"
		copy(state.diagnostic[:], message)
		return {}, {message = string(state.diagnostic[:len(message)]), result = .ERROR_INITIALIZATION_FAILED}
	}
	test_saved_enumerate = vk.EnumeratePhysicalDevices
	test_saved_support = vk.GetPhysicalDeviceSurfaceSupportKHR
	test_saved_create_device = vk.CreateDevice
	test_saved_device_proc = vk.GetDeviceProcAddr
	test_saved_surface_formats = vk.GetPhysicalDeviceSurfaceFormatsKHR
	test_saved_surface_modes = vk.GetPhysicalDeviceSurfacePresentModesKHR
	test_saved_surface_caps = vk.GetPhysicalDeviceSurfaceCapabilitiesKHR
	test_saved_features = vk.GetPhysicalDeviceFeatures2
	test_candidate_queries, test_candidate_creations = 0, 0
	test_candidate_mode = state.mode
	vk.GetPhysicalDeviceSurfaceFormatsKHR = test_surface_formats
	vk.GetPhysicalDeviceSurfacePresentModesKHR = test_surface_modes
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR = test_surface_caps
	#partial switch state.mode {
	case .After_Surface_Failure:
		vk.EnumeratePhysicalDevices = test_enumeration_failure
	case .No_Present_Device:
		vk.GetPhysicalDeviceSurfaceSupportKHR = test_surface_unsupported
	case .Resource_Failure:
		vk.GetPhysicalDeviceSurfaceSupportKHR = test_surface_supported
		vk.GetDeviceProcAddr = test_resource_proc
	case .Device_Failure:
		vk.GetPhysicalDeviceSurfaceSupportKHR = test_surface_supported
		vk.CreateDevice = test_device_failure
	case .Incompatible_First, .Retry_Candidate:
		vk.EnumeratePhysicalDevices = test_multiple_devices
		vk.GetPhysicalDeviceFeatures2 = test_candidate_features
		vk.GetPhysicalDeviceSurfaceSupportKHR = test_surface_supported
		vk.CreateDevice = test_candidate_device
		vk.GetDeviceProcAddr = test_resource_proc

	}
	return vk.SurfaceKHR(1), {}
}

@(private)
test_surface_destroy :: proc(data: rawptr, instance: vk.Instance, surface: vk.SurfaceKHR) {
	state := cast(^Platform_Test_State)data
	state.destroyed += 1
	vk.EnumeratePhysicalDevices = test_saved_enumerate
	vk.GetPhysicalDeviceSurfaceSupportKHR = test_saved_support
	vk.CreateDevice = test_saved_create_device
	vk.GetDeviceProcAddr = test_saved_device_proc
	vk.GetPhysicalDeviceSurfaceFormatsKHR = test_saved_surface_formats
	vk.GetPhysicalDeviceSurfacePresentModesKHR = test_saved_surface_modes
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR = test_saved_surface_caps
	vk.GetPhysicalDeviceFeatures2 = test_saved_features
	count: u32
	state.instance_alive_at_destroy =
		vk.EnumeratePhysicalDevices(instance, &count, nil) == .SUCCESS
}

@(private)
test_enumeration_failure :: proc "system" (
	instance: vk.Instance,
	count: ^u32,
	devices: [^]vk.PhysicalDevice,
) -> vk.Result {return .ERROR_OUT_OF_HOST_MEMORY}
@(private)
test_surface_supported :: proc "system" (
	device: vk.PhysicalDevice,
	family: u32,
	surface: vk.SurfaceKHR,
	supported: ^b32,
) -> vk.Result {
	supported^ = true
	return .SUCCESS
}
@(private)
test_device_failure :: proc "system" (
	physical: vk.PhysicalDevice,
	info: ^vk.DeviceCreateInfo,
	allocations: ^vk.AllocationCallbacks,
	device: ^vk.Device,
) -> vk.Result {return .ERROR_OUT_OF_DEVICE_MEMORY}

@(private)
test_resource_proc :: proc "system" (device: vk.Device, name: cstring) -> vk.ProcVoidFunction {
	context = runtime.default_context()
	if string(name) == "vkCreateSampler" do return auto_cast test_sampler_failure
	return test_saved_device_proc(device, name)
}

@(private)
test_sampler_failure :: proc "system" (
	device: vk.Device,
	info: ^vk.SamplerCreateInfo,
	allocations: ^vk.AllocationCallbacks,
	sampler: ^vk.Sampler,
) -> vk.Result {
	return .ERROR_OUT_OF_DEVICE_MEMORY
}

@(private)
test_surface_unsupported :: proc "system" (
	device: vk.PhysicalDevice,
	family: u32,
	surface: vk.SurfaceKHR,
	supported: ^b32,
) -> vk.Result {
	supported^ = false
	return .SUCCESS
}

test_saved_features: vk.ProcGetPhysicalDeviceFeatures2
test_candidate_queries, test_candidate_creations: int
test_candidate_mode: Platform_Test_Mode

test_multiple_devices :: proc "system" (
	instance: vk.Instance,
	count: ^u32,
	devices: [^]vk.PhysicalDevice,
) -> vk.Result {
	if devices == nil {
		count^ = 2
		return .SUCCESS
	}
	one: u32 = 1
	res := test_saved_enumerate(instance, &one, devices)
	if res != .SUCCESS && res != .INCOMPLETE do return res
	if one == 0 {
		count^ = 0
		return .SUCCESS
	}
	devices[1], count^ = devices[0], 2
	return .SUCCESS
}

test_candidate_features :: proc "system" (
	pd: vk.PhysicalDevice,
	features: [^]vk.PhysicalDeviceFeatures2,
) {
	test_saved_features(pd, features)
	test_candidate_queries += 1
	if test_candidate_mode == .Incompatible_First && test_candidate_queries == 1 do (cast(^vk.PhysicalDeviceVulkan13Features)features[0].pNext).dynamicRendering = false
}

test_candidate_device :: proc "system" (
	pd: vk.PhysicalDevice,
	info: ^vk.DeviceCreateInfo,
	callbacks: ^vk.AllocationCallbacks,
	device: ^vk.Device,
) -> vk.Result {
	test_candidate_creations += 1
	if test_candidate_mode == .Retry_Candidate && test_candidate_creations == 1 do return .ERROR_OUT_OF_DEVICE_MEMORY
	return test_saved_create_device(pd, info, callbacks, device)
}

test_saved_surface_formats: vk.ProcGetPhysicalDeviceSurfaceFormatsKHR
test_saved_surface_modes: vk.ProcGetPhysicalDeviceSurfacePresentModesKHR
test_saved_surface_caps: vk.ProcGetPhysicalDeviceSurfaceCapabilitiesKHR

test_surface_formats :: proc "system" (
	pd: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	count: ^u32,
	items: [^]vk.SurfaceFormatKHR,
) -> vk.Result {
	count^ = 1
	if items != nil do items[0] = {.B8G8R8A8_SRGB, .COLORSPACE_SRGB_NONLINEAR}
	return .SUCCESS
}
test_surface_modes :: proc "system" (
	pd: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	count: ^u32,
	items: [^]vk.PresentModeKHR,
) -> vk.Result {
	count^ = 1
	if items != nil do items[0] = .FIFO
	return .SUCCESS
}
test_surface_caps :: proc "system" (
	pd: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	caps: [^]vk.SurfaceCapabilitiesKHR,
) -> vk.Result {
	caps[0] = {
		supportedUsageFlags = {.COLOR_ATTACHMENT},
	}
	return .SUCCESS
}
