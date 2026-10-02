#+private
package reify

import "base:runtime"
import "core:sync"
import "core:testing"
import vk "vendor:vulkan"

// Lifecycle tests serialize Vulkan dispatch and inject failures after ownership transfers.
@(test)
platform_lifecycle :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	state: Platform_Test_State
	info := Renderer_Init_Info {
		platform     = test_platform(&state),
		logical_size = {800, 600},
	}
	for missing in 0 ..< 4 {
		bad := info
		switch missing {
		case 0:
			bad.platform.get_framebuffer_size = nil
		case 1:
			bad.platform.vulkan.required_instance_extensions = nil
		case 2:
			bad.platform.vulkan.create_surface = nil
		case 3:
			bad.platform.vulkan.destroy_surface = nil
		}
		err := init(r, bad)
		testing.expect_value(t, err.category, Renderer_Error_Category.Missing_Capability)
		testing.expect(t, active_renderer == nil && !r.loader_owned)
	}
	other := new(Renderer)
	defer free(other)
	sync.atomic_store(&active_renderer, r)
	occupied := init(other, info)
	testing.expect_value(t, occupied.category, Renderer_Error_Category.Invalid_State)
	testing.expect(t, active_renderer == r && !other.loader_owned)
	destroy(other)
	testing.expect(t, active_renderer == r)
	sync.atomic_store(&active_renderer, cast(^Renderer)nil)
	for mode in Platform_Test_Mode {
		state = {
			mode = mode,
		}
		err := init(r, info)
		testing.expect(t, err.category != .None)
		testing.expect(t, active_renderer == nil && !r.loader_owned && r.gpu.instance == {})
		if mode == .Missing_Extension {
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
			testing.expect(t, state.instance_alive_at_destroy)
		}
		destroy(r)
		testing.expect(t, state.destroyed <= 1)
	}
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
	Surface_Failure,
	After_Surface_Failure,
	No_Present_Device,
	Device_Failure,
	Resource_Failure,
}
Platform_Test_State :: struct {
	mode:                      Platform_Test_Mode,
	created, destroyed:        int,
	instance_alive_at_destroy: bool,
	diagnostic:                [64]u8,
	extensions:                [1]cstring,
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
		vulkan = {test_extensions, test_surface_create, test_surface_destroy},
	}
}

@(private)
test_extensions :: proc(data: rawptr) -> ([]cstring, Platform_Error) {
	state := cast(^Platform_Test_State)data
	state.extensions[0] = vk.KHR_SURFACE_EXTENSION_NAME
	if state.mode == .Missing_Extension do state.extensions[0] = "VK_REIFY_missing_extension"
	return state.extensions[:], {}
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
) -> vk.Result {supported^ = true; return .SUCCESS}
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
