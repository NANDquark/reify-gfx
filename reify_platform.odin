package reify

import "core:mem"
import "core:log"
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

Negotiated_Limits :: struct {
	textures, fonts, instances: u32,
	max_image_dimension:        u32,
	staging_bytes:              u32,
}

effective_limits :: proc(r: ^Renderer) -> Negotiated_Limits {
	if r == nil || !r.initialized do return {}
	when RENDERER_BACKEND == "vulkan13" {
		return r.backend.gpu.limits
	} else when RENDERER_BACKEND == "vulkan11" {
		return r.backend.gpu.limits
	}
}

Memory_Heap_Summary :: struct {
	size, budget, usage, estimated_headroom, allocator_bytes: u64,
	device_local, host_visible, budget_known:                 bool,
}

Memory_Summary :: struct {
	heaps:      [vk.MAX_MEMORY_HEAPS]Memory_Heap_Summary,
	heap_count: u32,
}

// Budget telemetry is advisory; allocator_bytes includes allocator block overhead.
memory_summary :: proc(r: ^Renderer) -> Memory_Summary {
	if r == nil || !r.initialized do return {}
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_refresh_memory(&r.backend.gpu)
		return vulkan13_memory_summary(&r.backend.gpu)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_refresh_memory(&r.backend.gpu)
		return vulkan11_memory_summary(&r.backend.gpu)
	}
}

@(private)
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
@(private)
Renderer_Error_Category :: enum {
	None,
	Invalid_State,
	Missing_Capability,
	Missing_Extension,
	Platform_Failure,
	Vulkan_Failure,
	No_Present_Device,
	Surface_Lost,
	Unsupported_API,
	Missing_Feature,
	Insufficient_Limits,
	Invalid_Input,
	Capacity_Exhausted,
	Allocation_Failure,
	Device_Lost,
}
@(private)
Renderer_Result :: enum i32 {
	None,
	Success,
	Out_Of_Host_Memory,
	Out_Of_Device_Memory,
	Device_Lost,
	Surface_Lost,
	Initialization_Failed,
	Unknown,
}

// Internal diagnostics are copied into the value and require no separate allocation/free.
@(private)
Renderer_Error :: struct {
	stage:             Renderer_Error_Stage,
	category:          Renderer_Error_Category,
	result:            Renderer_Result,
	diagnostic:        [512]u8,
	diagnostic_length: int,
}

@(private)
error_message :: proc(err: ^Renderer_Error) -> string {
	return string(err.diagnostic[:err.diagnostic_length])
}

@(private)
renderer_log_error :: proc(err: Renderer_Error) {
	if err.category == .None do return
	err := err
	log.errorf("reify %s %v: %v (%v, %v)", RENDERER_BACKEND, err.stage, error_message(&err), err.category, err.result)
}

@(private)
renderer_error :: proc(
	stage: Renderer_Error_Stage,
	category: Renderer_Error_Category,
	message: string,
	result: Renderer_Result = .None,
) -> Renderer_Error {
	category := category
	if category == .Vulkan_Failure {
		#partial switch result {
		case .Out_Of_Host_Memory, .Out_Of_Device_Memory:
			category = .Allocation_Failure
		case .Device_Lost:
			category = .Device_Lost
		case .Surface_Lost:
			category = .Surface_Lost
		}
	}
	err := Renderer_Error {
		stage    = stage,
		category = category,
		result   = result,
	}
	err.diagnostic_length = copy(err.diagnostic[:], transmute([]u8)message)
	return err
}
