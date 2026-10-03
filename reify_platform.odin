package reify

import "core:mem"
import vk "vendor:vulkan"

// Callbacks use the calling thread's Odin context and must not reenter the renderer.
// Host state and the window remain alive until destroy returns. Extension names
// remain valid through synchronous initialization; platform diagnostics are borrowed
// through the synchronous callback call. Hosts query extensions and handle provider
// errors before init. Reify does not retain extension names after init.
Platform_Interface :: struct {
	user_data:            rawptr,
	get_framebuffer_size: proc(user_data: rawptr) -> ([2]int, Platform_Error),
	vulkan:               Vulkan_Surface_Interface,
}

Vulkan_Surface_Interface :: struct {
	required_instance_extensions: []cstring,
	create_surface:               proc(
		user_data: rawptr,
		instance: vk.Instance,
	) -> (
		vk.SurfaceKHR,
		Platform_Error,
	),
	destroy_surface:              proc(
		user_data: rawptr,
		instance: vk.Instance,
		surface: vk.SurfaceKHR,
	),
}

// On failure, create_surface cleans up its partial work. Successful surfaces
// are destroyed exactly once by Reify, before the instance, with nil allocations.
Platform_Error :: struct {
	message: string,
	result:  vk.Result,
}

Renderer_Init_Info :: struct {
	platform:       Platform_Interface,
	logical_size:   [2]int,
	allocator:      mem.Allocator,
	temp_allocator: mem.Allocator,
	config:         Renderer_Config,
}

Renderer_Config :: struct {
	vsync: bool,
}

Renderer_Error_Stage :: enum {
	None,
	Platform,
	Loader,
	Instance,
	Surface,
	Device,
	Resources,
	Presentation,
}
Renderer_Error_Category :: enum {
	None,
	Invalid_State,
	Missing_Capability,
	Missing_Extension,
	Platform_Failure,
	Vulkan_Failure,
	No_Present_Device,
	Surface_Lost,
}

// Diagnostics are copied into the value and require no separate allocation/free.
Renderer_Error :: struct {
	stage:             Renderer_Error_Stage,
	category:          Renderer_Error_Category,
	result:            vk.Result,
	diagnostic:        [512]u8,
	diagnostic_length: int,
}

error_message :: proc(err: ^Renderer_Error) -> string {
	return string(err.diagnostic[:err.diagnostic_length])
}

@(private)
renderer_error :: proc(
	stage: Renderer_Error_Stage,
	category: Renderer_Error_Category,
	message: string,
	result: vk.Result = .SUCCESS,
) -> Renderer_Error {
	err := Renderer_Error {
		stage    = stage,
		category = category,
		result   = result,
	}
	err.diagnostic_length = copy(err.diagnostic[:], transmute([]u8)message)
	return err
}
