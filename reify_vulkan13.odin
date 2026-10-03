package reify

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:image"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:time"
import "lib/vma"
import vk "vendor:vulkan"


SHADER_BYTES :: #load("assets/quad.spv")
MAX_FRAME_IN_FLIGHT :: 3
FONT_MAX_COUNT :: 128
FONT_BUFFER_SIZE :: FONT_MAX_COUNT * size_of(Quad_Font)
TEX_STAGING_BUFFER_SIZE :: 4 * mem.Megabyte
TEXTURE_MAX_COUNT :: 1024
DESC_BINDING_TEXTURES :: 0
DESC_BINDING_FONTS :: 1
ENABLE_VK_VALIDATION :: bool(#config(Reify_Enable_Validation, false))

Renderer :: struct {
	allocator:        mem.Allocator,
	platform:         Platform_Interface,
	initialized:      bool,
	// The Renderer has dynamically loaded the vulkan library, used for proper destruction in the case of partial failure
	loader_owned:     bool,
	stopped:          bool,
	frame_failed:     bool,
	frame_started:    bool,
	pending_upload:   One_Time_Cmd_Buffer,
	pending_texture:  Texture,
	framebuffer_size: [2]int,
	gpu:              GPU_Context,
	surface:          vk.SurfaceKHR,
	window:           struct {
		width:      i32,
		height:     i32,
		projection: Mat4f,
	},
	swapchain:        Swapchain_Context,
	resources:        struct {
		textures:             [dynamic]Texture, // TODO: convert to handle_map to support removals
		font_faces:           [dynamic]Font_Face,
		quad_fonts:           [dynamic]Quad_Font,
		desc_pool:            vk.DescriptorPool,
		desc_set:             vk.DescriptorSet,
		desc_set_layout:      vk.DescriptorSetLayout,
		index_buffer:         vk.Buffer,
		index_alloc:          vma.Allocation,
		font_staging_buffer:  vk.Buffer,
		font_staging_alloc:   vma.Allocation,
		font_staging_buf_ptr: [^]Quad_Font,
		font_device_buffer:   vk.Buffer,
		font_device_alloc:    vma.Allocation,
		tex_staging_buffer:   vk.Buffer,
		tex_staging_alloc:    vma.Allocation,
		tex_staging_size:     int,
		tex_sampler:          vk.Sampler,
		msdf_sampler:         vk.Sampler,
	},
	pipeline:         vk.Pipeline,
	pipeline_layout:  vk.PipelineLayout,
	command_pool:     vk.CommandPool,
	shader_module:    vk.ShaderModule,
	frame_index:      int,
	frame_contexts:   [MAX_FRAME_IN_FLIGHT]Frame_Context,
	perf:             Renderer_Perf_Stats,
}

GPU_Context :: struct {
	allocator:                   vma.Allocator,
	instance:                    vk.Instance,
	physical:                    vk.PhysicalDevice,
	device:                      vk.Device,
	queue:                       vk.Queue,
	queue_family:                u32,
	present_family:              u32,
	present_queue:               vk.Queue,
	capabilities:                Device_Capabilities,
	limits:                      Negotiated_Limits,
	surface_format:              vk.SurfaceFormatKHR,
	allocator_bytes:             [vk.MAX_MEMORY_HEAPS]u64,
	initial_allocation_estimate: u64,
}

Swapchain_Context :: struct {
	gpu:               ^GPU_Context,
	vsync_enabled:     bool,
	create_info:       vk.SwapchainCreateInfoKHR,
	handle:            vk.SwapchainKHR,
	images:            [dynamic]vk.Image,
	views:             [dynamic]vk.ImageView,
	render_semaphores: [dynamic]vk.Semaphore,
	needs_update:      bool,
}

Frame_Context :: struct {
	fence:                  vk.Fence,
	present_semaphore:      vk.Semaphore,
	command_buffer:         vk.CommandBuffer,
	shader_data:            Quad_Shader_Data,
	shader_data_buffer:     Shader_Data_Buffer,
	projection_type:        Projection_Type,
	world_projection_view:  Mat4f,
	screen_projection_view: Mat4f,
	total_instances:        int,
	draw_batches:           [dynamic]Draw_Batch,
}

Shader_Data_Buffer :: struct {
	alloc:       vma.Allocation,
	buffer:      vk.Buffer,
	device_addr: vk.DeviceAddress,
	mapped:      rawptr,
}

Draw_Batch :: struct {
	scissor:         vk.Rect2D,
	index_offset:    int,
	num_instances:   int,
	projection_type: Projection_Type,
}

Projection_Type :: enum {
	World, // Default
	Screen,
}

Mat4f :: matrix[4, 4]f32

Color :: [4]u8

Rect :: struct {
	x, y, w, h: f32,
}

// Translate a Vulkan result into the backend-independent renderer result.
@(private)
vk_result :: proc(res: vk.Result) -> Renderer_Result {
	#partial switch res {
	case .SUCCESS:
		return .Success
	case .ERROR_OUT_OF_HOST_MEMORY:
		return .Out_Of_Host_Memory
	case .ERROR_OUT_OF_DEVICE_MEMORY:
		return .Out_Of_Device_Memory
	case .ERROR_DEVICE_LOST:
		return .Device_Lost
	case .ERROR_SURFACE_LOST_KHR:
		return .Surface_Lost
	case .ERROR_INITIALIZATION_FAILED:
		return .Initialization_Failed
	case:
		return .Unknown
	}
}


@(private)
vulkan13_init :: proc(r: ^Renderer, info: Renderer_Init_Info) -> (err: Renderer_Error) {
	if r == nil {
		return renderer_error(.Platform, .Invalid_State, "renderer pointer is nil")
	}
	p := info.platform
	if p.get_framebuffer_size == nil ||
	   p.vulkan.create_surface == nil ||
	   p.vulkan.destroy_surface == nil {
		return renderer_error(
			.Platform,
			.Missing_Capability,
			"framebuffer size and all Vulkan surface callbacks are required",
		)
	}
	if info.logical_size.x < 0 ||
	   info.logical_size.y < 0 ||
	   info.logical_size.x > int(max(i32)) ||
	   info.logical_size.y > int(max(i32)) {
		return renderer_error(
			.Platform,
			.Invalid_State,
			"logical dimensions must fit nonnegative i32",
		)
	}
	if _, reserved := sync.atomic_compare_exchange_strong(&active_renderer, cast(^Renderer)nil, r);
	   !reserved {
		return renderer_error(.Platform, .Invalid_State, "only one active renderer is supported")
	}
	success := false
	defer {
		if !success {
			if r.loader_owned {
				vulkan13_destroy(r)
			} else {
				sync.atomic_store(&active_renderer, cast(^Renderer)nil)
			}
		}
	}
	r^ = {}
	r.allocator = info.allocator
	if r.allocator.procedure == nil do r.allocator = context.allocator
	context.allocator = r.allocator
	if info.temp_allocator.procedure != nil do context.temp_allocator = info.temp_allocator
	r.platform = p
	r.platform.vulkan.required_instance_extensions = nil
	if !renderer_loader_init() {
		return renderer_error(.Loader, .Vulkan_Failure, "Vulkan loader unavailable")
	}
	r.loader_owned = true
	if err := gpu_init(r, p.vulkan.required_instance_extensions); err.category != .None do return err
	framebuffer, framebuffer_err := r.platform.get_framebuffer_size(r.platform.user_data)
	if framebuffer_err.message != "" || framebuffer_err.result != .SUCCESS {
		return renderer_error(
			.Platform,
			.Platform_Failure,
			framebuffer_err.message,
			vk_result(framebuffer_err.result),
		)
	}
	if framebuffer.x < 0 ||
	   framebuffer.y < 0 ||
	   framebuffer.x > int(max(i32)) ||
	   framebuffer.y > int(max(i32)) {
		return renderer_error(
			.Platform,
			.Invalid_Input,
			"framebuffer dimensions must fit nonnegative i32",
		)
	}
	r.framebuffer_size = framebuffer
	r.gpu.initial_allocation_estimate = vulkan13_initial_allocation_estimate(r)
	fmt.printf(
		"Initial allocation estimate: %d bytes including fallback texture, descriptor allowance, swapchain pressure, and allocator/alignment allowance; not an allocation guarantee\n",
		r.gpu.initial_allocation_estimate,
	)
	r.swapchain.vsync_enabled = info.config.vsync
	r.window.width, r.window.height = i32(info.logical_size.x), i32(info.logical_size.y)
	r.window.projection = vk_ortho_projection(
		0,
		f32(max(1, r.window.width)),
		0,
		f32(max(1, r.window.height)),
		-1,
		1,
	)

	// Setup Index Buffer
	index_count := QUAD_MAX_INSTANCES * 6 // each sprite has 2 quads so 6 indices
	index_buf_size := vk.DeviceSize(index_count * size_of(u32))
	index_buf_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = index_buf_size,
		usage = {.INDEX_BUFFER},
	}
	index_buf_alloc_create_info := vma.Allocation_Create_Info {
		flags          = {.Host_Access_Sequential_Write, .Mapped},
		usage          = .Auto,
		required_flags = {.HOST_VISIBLE},
	}
	if res := vma.create_buffer(
		r.gpu.allocator,
		index_buf_create_info,
		index_buf_alloc_create_info,
		&r.resources.index_buffer,
		&r.resources.index_alloc,
		nil,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	alloc_info: vma.Allocation_Info
	vma.get_allocation_info(r.gpu.allocator, r.resources.index_alloc, &alloc_info)
	indices := cast([^]u32)alloc_info.mapped_data
	if indices == nil {
		return renderer_error(.Resources, .Allocation_Failure, "index buffer is not mapped")
	}
	for i in 0 ..< QUAD_MAX_INSTANCES {
		v_offset := u32(i * 4) // base vertex of quad
		i_offset := i * 6 // position in index buffer

		indices[i_offset + 0] = v_offset + 0
		indices[i_offset + 1] = v_offset + 1
		indices[i_offset + 2] = v_offset + 2
		indices[i_offset + 3] = v_offset + 2
		indices[i_offset + 4] = v_offset + 3
		indices[i_offset + 5] = v_offset + 0
	}
	if res := vma.flush_allocation(r.gpu.allocator, r.resources.index_alloc, 0, index_buf_size);
	   res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"index buffer flush failed",
			vk_result(res),
		)
	}

	// Init global samplers
	tex_sampler_create_info := vk.SamplerCreateInfo {
		sType            = .SAMPLER_CREATE_INFO,
		// Keep sprites pixel-crisp by default.
		magFilter        = .NEAREST,
		minFilter        = .NEAREST,
		mipmapMode       = .NEAREST,
		addressModeU     = .CLAMP_TO_EDGE,
		addressModeV     = .CLAMP_TO_EDGE,
		addressModeW     = .CLAMP_TO_EDGE,
		anisotropyEnable = false,
		maxAnisotropy    = 8, // widely used
		maxLod           = vk.LOD_CLAMP_NONE,
	}
	if res := vk.CreateSampler(
		r.gpu.device,
		&tex_sampler_create_info,
		nil,
		&r.resources.tex_sampler,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	msdf_sampler_create_info := vk.SamplerCreateInfo {
		sType            = .SAMPLER_CREATE_INFO,
		magFilter        = .LINEAR,
		minFilter        = .LINEAR,
		addressModeU     = .CLAMP_TO_EDGE,
		addressModeV     = .CLAMP_TO_EDGE,
		addressModeW     = .CLAMP_TO_EDGE,
		anisotropyEnable = false,
		maxAnisotropy    = 8, // widely used
		maxLod           = 0,
	}
	if res := vk.CreateSampler(
		r.gpu.device,
		&msdf_sampler_create_info,
		nil,
		&r.resources.msdf_sampler,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}

	// CPU & GPU Sync
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		u_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size  = size_of(Quad_Shader_Data),
			usage = {.SHADER_DEVICE_ADDRESS},
		}
		u_buffer_alloc_create_info := vma.Allocation_Create_Info {
			flags          = {.Host_Access_Sequential_Write},
			usage          = .Auto,
			required_flags = {.HOST_VISIBLE},
		}
		if res := vma.create_buffer(
			r.gpu.allocator,
			u_buffer_create_info,
			u_buffer_alloc_create_info,
			&r.frame_contexts[i].shader_data_buffer.buffer,
			&r.frame_contexts[i].shader_data_buffer.alloc,
			nil,
		); res != .SUCCESS {
			return renderer_error(
				.Resources,
				.Vulkan_Failure,
				"GPU resource initialization failed",
				vk_result(res),
			)
		}
		if res := vma.map_memory(
			r.gpu.allocator,
			r.frame_contexts[i].shader_data_buffer.alloc,
			&r.frame_contexts[i].shader_data_buffer.mapped,
		); res != .SUCCESS {
			return renderer_error(
				.Resources,
				.Vulkan_Failure,
				"GPU resource initialization failed",
				vk_result(res),
			)
		}
		if r.frame_contexts[i].shader_data_buffer.mapped == nil {
			return renderer_error(.Resources, .Allocation_Failure, "instance buffer is not mapped")
		}
		u_buffer_bda_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = r.frame_contexts[i].shader_data_buffer.buffer,
		}
		r.frame_contexts[i].shader_data_buffer.device_addr = vk.GetBufferDeviceAddress(
			r.gpu.device,
			&u_buffer_bda_info,
		)
		if r.frame_contexts[i].shader_data_buffer.device_addr == 0 ||
		   r.frame_contexts[i].shader_data_buffer.device_addr % align_of(Quad_Shader_Data) != 0 {
			return renderer_error(
				.Resources,
				.Insufficient_Limits,
				"instance device address is null or misaligned",
			)
		}
	}
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		if res := vk.CreateFence(
			r.gpu.device,
			&fence_create_info,
			nil,
			&r.frame_contexts[i].fence,
		); res != .SUCCESS {
			return renderer_error(
				.Resources,
				.Vulkan_Failure,
				"GPU resource initialization failed",
				vk_result(res),
			)
		}
		if res := vk.CreateSemaphore(
			r.gpu.device,
			&semaphore_create_info,
			nil,
			&r.frame_contexts[i].present_semaphore,
		); res != .SUCCESS {
			return renderer_error(
				.Resources,
				.Vulkan_Failure,
				"GPU resource initialization failed",
				vk_result(res),
			)
		}
	}

	// COMMAND BUFFERS
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.gpu.queue_family,
	}
	if res := vk.CreateCommandPool(r.gpu.device, &command_pool_create_info, nil, &r.command_pool);
	   res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	command_buffer_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		commandBufferCount = 1,
	}
	// TODO: This is awkward because by keeping command buffer in the Frame_Context
	// we cannot allocate an array of command buffers so we do it as two separate
	// allocations
	for &fctx in r.frame_contexts {
		if res := vk.AllocateCommandBuffers(
			r.gpu.device,
			&command_buffer_alloc_info,
			&fctx.command_buffer,
		); res != .SUCCESS {
			return renderer_error(
				.Resources,
				.Vulkan_Failure,
				"GPU resource initialization failed",
				vk_result(res),
			)
		}
	}

	// Init font buffers
	font_staging_buf_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = FONT_BUFFER_SIZE,
		usage = {.TRANSFER_SRC},
	}
	font_staging_buf_alloc_create_info := vma.Allocation_Create_Info {
		flags           = {.Host_Access_Sequential_Write, .Mapped},
		usage           = .Auto,
		required_flags  = {.HOST_VISIBLE},
		preferred_flags = {.HOST_COHERENT},
	}
	if res := vma.create_buffer(
		r.gpu.allocator,
		font_staging_buf_create_info,
		font_staging_buf_alloc_create_info,
		&r.resources.font_staging_buffer,
		&r.resources.font_staging_alloc,
		nil,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	font_staging_alloc_info: vma.Allocation_Info
	vma.get_allocation_info(
		r.gpu.allocator,
		r.resources.font_staging_alloc,
		&font_staging_alloc_info,
	)
	r.resources.font_staging_buf_ptr = cast([^]Quad_Font)font_staging_alloc_info.mapped_data
	if r.resources.font_staging_buf_ptr == nil {
		return renderer_error(.Resources, .Allocation_Failure, "font staging buffer is not mapped")
	}
	font_device_buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = FONT_BUFFER_SIZE,
		usage = {.TRANSFER_DST, .STORAGE_BUFFER},
	}
	font_device_alloc_create_info := vma.Allocation_Create_Info {
		usage          = .Auto,
		required_flags = {.DEVICE_LOCAL},
	}
	if res := vma.create_buffer(
		r.gpu.allocator,
		font_device_buffer_create_info,
		font_device_alloc_create_info,
		&r.resources.font_device_buffer,
		&r.resources.font_device_alloc,
		nil,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}

	// Textures globals
	tex_staging_buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(TEX_STAGING_BUFFER_SIZE),
		usage = {.TRANSFER_SRC},
	}
	tex_staging_alloc_create_info := vma.Allocation_Create_Info {
		flags          = {.Host_Access_Sequential_Write, .Mapped},
		usage          = .Auto,
		required_flags = {.HOST_VISIBLE},
	}
	staging_res := vk.Result.ERROR_OUT_OF_DEVICE_MEMORY
	for attempt in 0 ..< 4 {
		staging_size := TEX_STAGING_BUFFER_SIZE >> u32(attempt * 2)
		tex_staging_buffer_create_info.size = vk.DeviceSize(staging_size)
		staging_res = vma.create_buffer(
			r.gpu.allocator,
			tex_staging_buffer_create_info,
			tex_staging_alloc_create_info,
			&r.resources.tex_staging_buffer,
			&r.resources.tex_staging_alloc,
			nil,
		)
		if staging_res == .SUCCESS {
			r.resources.tex_staging_size = staging_size
			r.gpu.limits.staging_bytes = u32(staging_size)
			break
		}
		if staging_res != .ERROR_OUT_OF_DEVICE_MEMORY do break
	}
	if staging_res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"bounded texture staging allocation failed",
			vk_result(staging_res),
		)
	}

	// descriptors
	desc_layout_bindings := vulkan13_descriptor_bindings(r.gpu.limits.textures)
	desc_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(desc_layout_bindings),
		pBindings    = raw_data(desc_layout_bindings[:]),
	}
	if res := vk.CreateDescriptorSetLayout(
		r.gpu.device,
		&desc_layout_create_info,
		nil,
		&r.resources.desc_set_layout,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	desc_pool_sizes := [?]vk.DescriptorPoolSize {
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = r.gpu.limits.textures},
		{type = .STORAGE_BUFFER, descriptorCount = 1},
	}
	desc_pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = len(desc_pool_sizes),
		pPoolSizes    = raw_data(desc_pool_sizes[:]),
	}
	if res := vk.CreateDescriptorPool(
		r.gpu.device,
		&desc_pool_create_info,
		nil,
		&r.resources.desc_pool,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	desc_set_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = r.resources.desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.resources.desc_set_layout,
	}
	if res := vk.AllocateDescriptorSets(r.gpu.device, &desc_set_alloc, &r.resources.desc_set);
	   res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	font_info := vk.DescriptorBufferInfo {
		buffer = r.resources.font_device_buffer,
		range  = FONT_BUFFER_SIZE,
	}
	font_write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.resources.desc_set,
		dstBinding      = DESC_BINDING_FONTS,
		descriptorCount = 1,
		descriptorType  = .STORAGE_BUFFER,
		pBufferInfo     = &font_info,
	}
	vk.UpdateDescriptorSets(r.gpu.device, 1, &font_write, 0, nil)
	// Slot zero is a live fallback for every unused texture descriptor.
	if _, err := vulkan13_texture_load(r, []Color{{255, 255, 255, 255}}, 1, 1); err.category != .None do return err

	if res := vk_shader_module_init(r.gpu.device, &r.shader_module, SHADER_BYTES);
	   res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"shader module creation failed",
			vk_result(res),
		)
	}
	if res := vk_pipeline_init(
		r.gpu.device,
		Quad_Push_Constants,
		Quad_Instance,
		&r.resources.desc_set_layout,
		r.shader_module,
		&r.pipeline_layout,
		&r.pipeline,
		r.gpu.surface_format.format,
	); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"pipeline creation failed",
			vk_result(res),
		)
	}
	if err := vulkan13_update_swapchain(r); err.category != .None do return err
	r.initialized = true
	vulkan13_refresh_memory(&r.gpu)
	fmt.printf("Effective staging capacity: %d bytes\n", r.gpu.limits.staging_bytes)
	now := time.now()
	r.perf.last_log_time, r.perf.fps_last_log = now, now
	success = true
	return {}
}

vulkan13_set_vsync :: proc(r: ^Renderer, enabled: bool) {
	if r.swapchain.vsync_enabled == enabled do return
	r.swapchain.vsync_enabled = enabled
	if r.surface != {} {
		r.swapchain.needs_update = true
	}
}

vulkan13_destroy :: proc(r: ^Renderer) {
	if r == nil || !r.loader_owned do return

	context.allocator = r.allocator
	if r.gpu.device != {} {
		res := vk.DeviceWaitIdle(r.gpu.device)
		if res != .SUCCESS && res != .ERROR_DEVICE_LOST {
			panic(fmt.tprintf("GPU idle wait failed before cleanup: %v", res))
		}
		if r.pending_upload.cmd != {} do vk_one_time_cmd_buffer_destroy(&r.pending_upload)
		if r.pending_texture.image != {} {
			vk.DestroyImageView(r.gpu.device, r.pending_texture.view, nil)
			vma.destroy_image(r.gpu.allocator, r.pending_texture.image, r.pending_texture.alloc)
		}

		for i in 0 ..< MAX_FRAME_IN_FLIGHT {
			fctx := &r.frame_contexts[i]
			vk.DestroyFence(r.gpu.device, fctx.fence, nil)
			vk.DestroySemaphore(r.gpu.device, fctx.present_semaphore, nil)
			if fctx.shader_data_buffer.mapped != nil do vma.unmap_memory(r.gpu.allocator, fctx.shader_data_buffer.alloc)
			if fctx.shader_data_buffer.alloc != nil do vma.destroy_buffer(r.gpu.allocator, fctx.shader_data_buffer.buffer, fctx.shader_data_buffer.alloc)
			delete(fctx.draw_batches)
		}

		swapchain_context_destroy(&r.swapchain, r.gpu.device, allocator = r.allocator)

		// cleanup resources
		for t in r.resources.textures {
			vk.DestroyImageView(r.gpu.device, t.view, nil)
			vma.destroy_image(r.gpu.allocator, t.image, t.alloc)
			// t.sampler is shared in tex_sampler
		}
		delete(r.resources.textures)
		for &face in r.resources.font_faces {
			font_face_destroy(&face, r.allocator)
		}
		delete(r.resources.font_faces)
		vk.DestroySampler(r.gpu.device, r.resources.tex_sampler, nil)
		vk.DestroySampler(r.gpu.device, r.resources.msdf_sampler, nil)
		vk.DestroyDescriptorSetLayout(r.gpu.device, r.resources.desc_set_layout, nil)
		vk.DestroyDescriptorPool(r.gpu.device, r.resources.desc_pool, nil)
		if r.resources.index_alloc != nil do vma.destroy_buffer(r.gpu.allocator, r.resources.index_buffer, r.resources.index_alloc)
		if r.resources.tex_staging_alloc != nil do vma.destroy_buffer(r.gpu.allocator, r.resources.tex_staging_buffer, r.resources.tex_staging_alloc)
		if r.resources.font_staging_alloc != nil do vma.destroy_buffer(r.gpu.allocator, r.resources.font_staging_buffer, r.resources.font_staging_alloc)
		if r.resources.font_device_alloc != nil do vma.destroy_buffer(r.gpu.allocator, r.resources.font_device_buffer, r.resources.font_device_alloc)

		vk.DestroyPipelineLayout(r.gpu.device, r.pipeline_layout, nil)
		vk.DestroyPipeline(r.gpu.device, r.pipeline, nil)
		vk.DestroyCommandPool(r.gpu.device, r.command_pool, nil)
		vk.DestroyShaderModule(r.gpu.device, r.shader_module, nil)

		delete(r.resources.quad_fonts)
	}
	if r.gpu.allocator != nil do vma.destroy_allocator(r.gpu.allocator)
	if r.gpu.device != {} do vk.DestroyDevice(r.gpu.device, nil)
	if r.surface != {} do r.platform.vulkan.destroy_surface(r.platform.user_data, r.gpu.instance, r.surface)
	if r.gpu.instance != {} do vk.DestroyInstance(r.gpu.instance, nil)
	renderer_loader_shutdown()
	sync.atomic_store(&active_renderer, cast(^Renderer)nil)
	r^ = {}
}

@(private)
swapchain_context_init :: proc(
	sc: ^Swapchain_Context,
	gpu: ^GPU_Context,
	surface: vk.SurfaceKHR,
	surface_caps: vk.SurfaceCapabilitiesKHR,
	window_width, window_height: i32,
	recreate := false,
	allocator := context.allocator,
) -> Renderer_Error {
	context.allocator = allocator

	old := sc^
	sc^ = {
		vsync_enabled = old.vsync_enabled,
	}
	success := false
	defer {
		if success {
			swapchain_context_destroy(&old, gpu.device, allocator)
		} else {
			swapchain_context_destroy(sc, gpu.device, allocator)
			sc^ = old
		}
	}
	sc.gpu = gpu
	if .COLOR_ATTACHMENT not_in surface_caps.supportedUsageFlags {
		return renderer_error(
			.Presentation,
			.Missing_Capability,
			"surface does not support color attachment usage",
		)
	}

	present_mode: vk.PresentModeKHR = .FIFO
	if !sc.vsync_enabled {
		present_modes, res := vk_enumerate(
			vk.PresentModeKHR,
			physical = gpu.physical,
			surface = surface,
		)
		defer delete(present_modes, context.temp_allocator)
		if res != .SUCCESS {
			return renderer_error(
				.Presentation,
				.Vulkan_Failure,
				"present mode enumeration failed",
				vk_result(res),
			)
		}
		if len(present_modes) > 0 {
			for mode in present_modes {
				if mode == .IMMEDIATE {
					present_mode = .IMMEDIATE
					break
				}
			}
			if present_mode == .FIFO {
				for mode in present_modes {
					if mode == .MAILBOX {
						present_mode = .MAILBOX
						break
					}
				}
			}
		}
	}

	swapchain_extent: vk.Extent2D
	// Some platforms expose a fixed extent via currentExtent and require it verbatim.
	if surface_caps.currentExtent.width != max(u32) {
		swapchain_extent = surface_caps.currentExtent
	} else {
		req_width := window_width
		req_height := window_height
		if req_width < 0 do req_width = 0
		if req_height < 0 do req_height = 0

		clamped_width := u32(req_width)
		if clamped_width < surface_caps.minImageExtent.width do clamped_width = surface_caps.minImageExtent.width
		if clamped_width > surface_caps.maxImageExtent.width do clamped_width = surface_caps.maxImageExtent.width

		clamped_height := u32(req_height)
		if clamped_height < surface_caps.minImageExtent.height do clamped_height = surface_caps.minImageExtent.height
		if clamped_height > surface_caps.maxImageExtent.height do clamped_height = surface_caps.maxImageExtent.height

		swapchain_extent = vk.Extent2D {
			width  = clamped_width,
			height = clamped_height,
		}
	}

	families := [2]u32{gpu.queue_family, gpu.present_family}
	transform := surface_caps.currentTransform
	if .IDENTITY in surface_caps.supportedTransforms do transform = {.IDENTITY}
	alpha: vk.CompositeAlphaFlagsKHR
	alpha_preferences := [?]vk.CompositeAlphaFlagKHR {
		.OPAQUE,
		.PRE_MULTIPLIED,
		.POST_MULTIPLIED,
		.INHERIT,
	}
	for flag in alpha_preferences {
		if flag in surface_caps.supportedCompositeAlpha {
			alpha = {flag}
			break
		}
	}
	if alpha == {} {
		return renderer_error(
			.Presentation,
			.Missing_Capability,
			"surface has no supported composite alpha",
		)
	}
	image_count := max(surface_caps.minImageCount, u32(MAX_FRAME_IN_FLIGHT))
	if surface_caps.maxImageCount > 0 do image_count = min(image_count, surface_caps.maxImageCount)
	sc.create_info = vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = surface,
		minImageCount    = image_count,
		imageFormat      = gpu.surface_format.format,
		imageColorSpace  = gpu.surface_format.colorSpace,
		imageExtent      = swapchain_extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = transform,
		compositeAlpha   = alpha,
		presentMode      = present_mode,
		oldSwapchain     = old.handle,
	}
	if families[0] != families[1] {
		sc.create_info.imageSharingMode = .CONCURRENT
		sc.create_info.queueFamilyIndexCount = 2
		sc.create_info.pQueueFamilyIndices = &families[0]
	}
	new_handle: vk.SwapchainKHR
	res := vk.CreateSwapchainKHR(sc.gpu.device, &sc.create_info, nil, &new_handle)
	sc.create_info.pQueueFamilyIndices = nil
	if res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"swapchain initialization failed",
			vk_result(res),
		)
	}
	sc.handle = new_handle


	images, image_res := vk_enumerate(vk.Image, device = gpu.device, swapchain = sc.handle)
	defer delete(images, context.temp_allocator)
	if image_res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"swapchain image enumeration failed",
			vk_result(image_res),
		)
	}
	if len(images) == 0 {
		return renderer_error(.Presentation, .Missing_Capability, "swapchain returned no images")
	}
	swapchain_image_count := u32(len(images))
	append(&sc.images, ..images)
	clear(&sc.views)
	resize(&sc.views, int(swapchain_image_count))
	for &view in sc.views do view = {}
	for i in 0 ..< swapchain_image_count {
		view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = sc.images[i],
			viewType = .D2,
			format = sc.create_info.imageFormat,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if res := vk.CreateImageView(sc.gpu.device, &view_create_info, nil, &sc.views[i]);
		   res != .SUCCESS {
			return renderer_error(
				.Presentation,
				.Vulkan_Failure,
				"swapchain initialization failed",
				vk_result(res),
			)
		}
	}
	for s in sc.render_semaphores {
		vk.DestroySemaphore(sc.gpu.device, s, nil)
	}
	clear(&sc.render_semaphores)
	resize(&sc.render_semaphores, int(swapchain_image_count))
	for &semaphore in sc.render_semaphores do semaphore = {}
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for &s in sc.render_semaphores {
		if res := vk.CreateSemaphore(sc.gpu.device, &semaphore_create_info, nil, &s);
		   res != .SUCCESS {
			return renderer_error(
				.Presentation,
				.Vulkan_Failure,
				"swapchain initialization failed",
				vk_result(res),
			)
		}
	}

	sc.create_info.pQueueFamilyIndices = nil
	sc.create_info.oldSwapchain = {}
	success = true
	return {}
}

@(private)
swapchain_context_destroy :: proc(
	sc: ^Swapchain_Context,
	device: vk.Device,
	allocator := context.allocator,
) {
	context.allocator = allocator

	// The images in sc.images should not be destroyed because they are owned by
	// the swapchain and are released by vk.DestroySwapchainKHR
	delete(sc.images)
	for iv in sc.views {
		vk.DestroyImageView(device, iv, nil)
	}
	delete(sc.views)
	for s in sc.render_semaphores {
		vk.DestroySemaphore(device, s, nil)
	}
	delete(sc.render_semaphores)
	vk.DestroySwapchainKHR(device, sc.handle, nil)
}

@(private)
gpu_init :: proc(
	r: ^Renderer,
	required_extensions: []cstring,
	allocator := context.allocator,
) -> Renderer_Error {
	context.allocator = allocator
	dctx := &r.gpu
	if vk.EnumerateInstanceVersion == nil {
		return renderer_error(
			.Loader,
			.Unsupported_API,
			"Vulkan 1.3 loader required; loader exposes only Vulkan 1.0",
		)
	}
	loader_version: u32
	if res := vk.EnumerateInstanceVersion(&loader_version); res != .SUCCESS {
		return renderer_error(
			.Loader,
			.Vulkan_Failure,
			"loader version query failed",
			vk_result(res),
		)
	}
	if loader_version < vk.API_VERSION_1_3 {
		return renderer_error(
			.Loader,
			.Unsupported_API,
			fmt.tprintf("Vulkan 1.3 loader required; supported API %#x", loader_version),
		)
	}

	app_info := &vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		pApplicationName = "Reify",
		apiVersion = vk.API_VERSION_1_3,
	}
	instance_extensions := make([dynamic]cstring, context.temp_allocator)
	defer delete(instance_extensions)
	if reserve(&instance_extensions, len(required_extensions) + 1) != nil {
		return renderer_error(
			.Instance,
			.Allocation_Failure,
			"instance extension table allocation failed",
			.Out_Of_Host_Memory,
		)
	}
	append(&instance_extensions, vk.KHR_SURFACE_EXTENSION_NAME)
	for name in required_extensions {
		if name == nil {
			return renderer_error(.Instance, .Missing_Extension, "nil instance extension name")
		}
		duplicate := false
		for existing in instance_extensions {
			if string(existing) == string(name) {
				duplicate = true
				break
			}
		}
		if !duplicate do append(&instance_extensions, name)
	}

	available, ext_res := vk_enumerate(vk.ExtensionProperties)
	defer delete(available, context.temp_allocator)
	if ext_res != .SUCCESS {
		return renderer_error(
			.Instance,
			.Vulkan_Failure,
			"instance extension enumeration failed",
			vk_result(ext_res),
		)
	}
	for name in instance_extensions {
		if name == nil {
			return renderer_error(.Instance, .Missing_Extension, "nil instance extension name")
		}
		found := false
		for &ext in available {
			if string(name) == string(cstring(&ext.extensionName[0])) {
				found = true
				break
			}
		}
		if !found {
			return renderer_error(.Instance, .Missing_Extension, string(name), .Unknown)
		}
	}
	enabled_layers := [1]cstring{"VK_LAYER_KHRONOS_validation"}
	enabled_layer_count: u32
	if ENABLE_VK_VALIDATION {
		layers_properties, res := vk_enumerate(vk.LayerProperties)
		defer delete(layers_properties, context.temp_allocator)
		if res != .SUCCESS {
			return renderer_error(
				.Instance,
				.Vulkan_Failure,
				"instance layer enumeration failed",
				vk_result(res),
			)
		}
		for &prop in layers_properties {
			if string(enabled_layers[0]) == string(cstring(&prop.layerName[0])) {
				enabled_layer_count = 1
				break
			}
		}
		if enabled_layer_count == 0 do fmt.printf("Warning: Layer %s not found. Skipping...\n", enabled_layers[0])
	}
	instance_create_info := &vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = app_info,
		enabledExtensionCount = u32(len(instance_extensions)),
		ppEnabledExtensionNames = raw_data(instance_extensions),
		enabledLayerCount = enabled_layer_count,
		ppEnabledLayerNames = &enabled_layers[0],
	}
	if res := vk.CreateInstance(instance_create_info, nil, &dctx.instance); res != .SUCCESS {
		return renderer_error(
			.Instance,
			.Vulkan_Failure,
			"instance creation failed",
			vk_result(res),
		)
	}
	vk.load_proc_addresses(dctx.instance)

	surface, platform_err := r.platform.vulkan.create_surface(r.platform.user_data, dctx.instance)
	if platform_err.message != "" || platform_err.result != .SUCCESS {
		return renderer_error(
			.Surface,
			.Platform_Failure,
			platform_err.message,
			vk_result(platform_err.result),
		)
	}
	if surface == {} {
		return renderer_error(
			.Surface,
			.Platform_Failure,
			"surface callback returned a null surface",
		)
	}
	r.surface = surface

	// SELECT DEVICE
	phys_devices, device_res := vk_enumerate(vk.PhysicalDevice, instance = dctx.instance)
	defer delete(phys_devices, context.temp_allocator)
	if device_res != .SUCCESS {
		return renderer_error(
			.Device,
			.Vulkan_Failure,
			"physical device enumeration failed",
			vk_result(device_res),
		)
	}
	if len(phys_devices) == 0 {
		return renderer_error(.Device, .No_Present_Device, "no physical devices available")
	}
	candidates := make([dynamic]Device_Candidate, context.temp_allocator)
	defer delete(candidates)
	if reserve(&candidates, len(phys_devices)) != nil {
		return renderer_error(
			.Device,
			.Allocation_Failure,
			"device candidate table allocation failed",
			.Out_Of_Host_Memory,
		)
	}
	rejection := renderer_error(
		.Device,
		.No_Present_Device,
		"no graphics/presentation capable device for this surface",
	)
	req := vulkan13_requirements()
	for pd in phys_devices {
		graphics, present: u32 = max(u32), max(u32)
		queue_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(pd, &queue_count, nil)
		queues, queue_alloc_err := make(
			[]vk.QueueFamilyProperties,
			queue_count,
			context.temp_allocator,
		)
		defer delete(queues, context.temp_allocator)
		if queue_alloc_err != nil {
			return renderer_error(
				.Device,
				.Allocation_Failure,
				"queue table allocation failed",
				.Out_Of_Host_Memory,
			)
		}
		vk.GetPhysicalDeviceQueueFamilyProperties(pd, &queue_count, raw_data(queues))
		queues = queues[:queue_count]
		present_support, present_alloc_err := make([]bool, queue_count, context.temp_allocator)
		defer delete(present_support, context.temp_allocator)
		if present_alloc_err != nil {
			return renderer_error(
				.Device,
				.Allocation_Failure,
				"presentation queue table allocation failed",
				.Out_Of_Host_Memory,
			)
		}
		for q, i in queues {
			if q.queueCount == 0 do continue
			supported: b32
			if res := vk.GetPhysicalDeviceSurfaceSupportKHR(pd, u32(i), r.surface, &supported);
			   res != .SUCCESS {
				return renderer_error(
					.Device,
					.Vulkan_Failure,
					"presentation support query failed",
					vk_result(res),
				)
			}
			present_support[i] = bool(supported)
		}
		graphics, present = vulkan13_choose_queues(queues, present_support)
		if graphics == max(u32) || present == max(u32) {
			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(pd, &props)
			fmt.printf(
				"Rejected GPU %s: graphics queue=%v present queue=%v\n",
				cstring(&props.deviceName[0]),
				graphics != max(u32),
				present != max(u32),
			)
			continue
		}
		caps, err := vulkan13_query_device(pd)
		if err.category != .None do return err
		limits, rejected := vulkan13_compare_requirements(caps, req)
		if rejected.error.category == .None {
			texture_formats := [?]vk.Format{.R8G8B8A8_SRGB, .R8G8B8A8_UNORM}
			for format in texture_formats {
				if err := vulkan13_check_texture_format(
					pd,
					format,
					1,
					1,
					format == .R8G8B8A8_UNORM,
				); err.category != .None {
					rejected.error = err
					break
				}
			}
		}
		if rejected.error.category != .None {
			rejection = rejected.error
			rejection.stage = .Device
			fmt.printf(
				"Rejected GPU %s: %s\n",
				cstring(&caps.properties.deviceName[0]),
				error_message(&rejection),
			)
			continue
		}
		formats, res := vk_enumerate(vk.SurfaceFormatKHR, physical = pd, surface = r.surface)
		defer delete(formats, context.temp_allocator)
		if res != .SUCCESS {
			return renderer_error(
				.Device,
				.Vulkan_Failure,
				"surface format query failed",
				vk_result(res),
			)
		}
		_, format_ok := vulkan13_surface_format(formats)
		modes, mode_res := vk_enumerate(vk.PresentModeKHR, physical = pd, surface = r.surface)
		defer delete(modes, context.temp_allocator)
		if mode_res != .SUCCESS {
			return renderer_error(
				.Device,
				.Vulkan_Failure,
				"present mode query failed",
				vk_result(mode_res),
			)
		}
		surface_caps: vk.SurfaceCapabilitiesKHR
		if res := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(pd, r.surface, &surface_caps);
		   res != .SUCCESS {
			return renderer_error(
				.Device,
				.Vulkan_Failure,
				"surface capabilities query failed",
				vk_result(res),
			)
		}
		if !format_ok ||
		   len(modes) == 0 ||
		   .COLOR_ATTACHMENT not_in surface_caps.supportedUsageFlags {
			rejection = renderer_error(
				.Device,
				.Missing_Capability,
				"surface requires an sRGB nonlinear attachment, presentation modes, and COLOR_ATTACHMENT usage",
			)
			fmt.printf(
				"Rejected GPU %s: %s\n",
				cstring(&caps.properties.deviceName[0]),
				error_message(&rejection),
			)
			continue
		}
		append(
			&candidates,
			Device_Candidate {
				physical = pd,
				capabilities = caps,
				limits = limits,
				graphics = graphics,
				present = present,
				priority = vulkan13_device_priority(caps.properties.deviceType),
				usable_memory = vulkan13_candidate_memory(caps),
			},
		)
	}
	if len(candidates) == 0 do return rejection
	creation_error: Renderer_Error
	for _ in 0 ..< len(candidates) {
		best := vulkan13_choose_candidate(candidates[:])
		candidate := &candidates[best]
		candidate.tried = true
		dctx.physical, dctx.queue_family, dctx.present_family =
			candidate.physical, candidate.graphics, candidate.present
		dctx.capabilities, dctx.limits = candidate.capabilities, candidate.limits
		creation_error = gpu_create_device(dctx, req)
		if creation_error.category == .None do break
		fmt.printf(
			"GPU %s activation failed: %s (%v)\n",
			cstring(&candidate.capabilities.properties.deviceName[0]),
			error_message(&creation_error),
			creation_error.result,
		)
		if creation_error.result == .Out_Of_Host_Memory do return creation_error
	}
	if creation_error.category != .None do return creation_error
	formats, format_res := vk_enumerate(
		vk.SurfaceFormatKHR,
		physical = dctx.physical,
		surface = r.surface,
	)
	defer delete(formats, context.temp_allocator)
	if format_res != .SUCCESS {
		return renderer_error(
			.Device,
			.Vulkan_Failure,
			"surface format query failed",
			vk_result(format_res),
		)
	}
	dctx.surface_format, _ = vulkan13_surface_format(formats)
	if err := gpu_init_allocator(dctx); err.category != .None do return err
	vulkan13_report_device(dctx)
	return {}
}

@(private)
Vulkan13_Requirements :: struct {
	api_version: u32,
	features11:  vk.PhysicalDeviceVulkan11Features,
	features12:  vk.PhysicalDeviceVulkan12Features,
	features13:  vk.PhysicalDeviceVulkan13Features,
	textures:    u32,
}

@(private)
vulkan13_requirements :: proc() -> Vulkan13_Requirements {
	return {
		api_version = vk.API_VERSION_1_3,
		features11 = {sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, shaderDrawParameters = true},
		features12 = {
			sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			runtimeDescriptorArray = true,
			shaderSampledImageArrayNonUniformIndexing = true,
			bufferDeviceAddress = true,
		},
		features13 = {
			sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
			dynamicRendering = true,
			synchronization2 = true,
		},
		textures = TEXTURE_MAX_COUNT,
	}
}

@(private)
Device_Capabilities :: struct {
	properties:      vk.PhysicalDeviceProperties,
	properties11:    vk.PhysicalDeviceVulkan11Properties,
	properties12:    vk.PhysicalDeviceVulkan12Properties,
	properties13:    vk.PhysicalDeviceVulkan13Properties,
	features11:      vk.PhysicalDeviceVulkan11Features,
	features12:      vk.PhysicalDeviceVulkan12Features,
	features13:      vk.PhysicalDeviceVulkan13Features,
	memory:          vk.PhysicalDeviceMemoryProperties,
	budget_known:    bool,
	budgets, usages: [vk.MAX_MEMORY_HEAPS]vk.DeviceSize,
	swapchain:       bool,
}

@(private)
Device_Rejection :: struct {
	error: Renderer_Error,
}

@(private)
Device_Candidate :: struct {
	physical:          vk.PhysicalDevice,
	capabilities:      Device_Capabilities,
	limits:            Negotiated_Limits,
	graphics, present: u32,
	priority:          int,
	usable_memory:     u64,
	tried:             bool,
}

@(private)
vulkan13_query_device :: proc(
	pd: vk.PhysicalDevice,
) -> (
	c: Device_Capabilities,
	err: Renderer_Error,
) {
	c.properties11 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_PROPERTIES,
	}
	c.properties12 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES,
		pNext = &c.properties11,
	}
	c.properties13 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_PROPERTIES,
		pNext = &c.properties12,
	}
	props := vk.PhysicalDeviceProperties2 {
		sType = .PHYSICAL_DEVICE_PROPERTIES_2,
		pNext = &c.properties13,
	}
	vk.GetPhysicalDeviceProperties2(pd, &props)
	c.properties = props.properties
	c.features11 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
	}
	c.features12 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &c.features11,
	}
	c.features13 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext = &c.features12,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &c.features13,
	}
	vk.GetPhysicalDeviceFeatures2(pd, &features)
	extensions, res := vk_enumerate(vk.ExtensionProperties, physical = pd)
	defer delete(extensions, context.temp_allocator)
	if res != .SUCCESS {
		return c, renderer_error(
			.Device,
			.Vulkan_Failure,
			"device extension enumeration failed",
			vk_result(res),
		)
	}
	for &ext in extensions {
		name := string(cstring(&ext.extensionName[0]))
		if name == string(vk.KHR_SWAPCHAIN_EXTENSION_NAME) do c.swapchain = true
		if name == string(vk.EXT_MEMORY_BUDGET_EXTENSION_NAME) do c.budget_known = true
	}
	budget := vk.PhysicalDeviceMemoryBudgetPropertiesEXT {
		sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
	}
	memory := vk.PhysicalDeviceMemoryProperties2 {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
	}
	if c.budget_known do memory.pNext = &budget
	vk.GetPhysicalDeviceMemoryProperties2(pd, &memory)
	c.memory, c.budgets, c.usages = memory.memoryProperties, budget.heapBudget, budget.heapUsage
	// Returned records own values, not pointers into the query's stack.
	c.properties11.pNext, c.properties12.pNext, c.properties13.pNext = nil, nil, nil
	c.features11.pNext, c.features12.pNext, c.features13.pNext = nil, nil, nil
	return
}

@(private)
vulkan13_compare_requirements :: proc(
	c: Device_Capabilities,
	req: Vulkan13_Requirements,
) -> (
	Negotiated_Limits,
	Device_Rejection,
) {
	if c.properties.apiVersion < req.api_version {
		return {}, {renderer_error(.Device, .Unsupported_API, fmt.tprintf("requires Vulkan 1.3; supported API %#x", c.properties.apiVersion))}
	}
	if !c.swapchain {
		return {}, {renderer_error(.Device, .Missing_Extension, "requires VK_KHR_swapchain")}
	}
	checks := [?]struct {
		name:                string,
		required, supported: b32,
	} {
		{
			"shaderDrawParameters",
			req.features11.shaderDrawParameters,
			c.features11.shaderDrawParameters,
		},
		{
			"bufferDeviceAddress",
			req.features12.bufferDeviceAddress,
			c.features12.bufferDeviceAddress,
		},
		{
			"runtimeDescriptorArray",
			req.features12.runtimeDescriptorArray,
			c.features12.runtimeDescriptorArray,
		},
		{
			"shaderSampledImageArrayNonUniformIndexing",
			req.features12.shaderSampledImageArrayNonUniformIndexing,
			c.features12.shaderSampledImageArrayNonUniformIndexing,
		},
		{"dynamicRendering", req.features13.dynamicRendering, c.features13.dynamicRendering},
		{"synchronization2", req.features13.synchronization2, c.features13.synchronization2},
	}
	for check in checks {
		if bool(check.required) && !bool(check.supported) {
			return {}, {renderer_error(.Device, .Missing_Feature, fmt.tprintf("requires %s=true; supported=false", check.name))}
		}
	}
	l := c.properties.limits
	checks_limits := [?]struct {
		name:                string,
		required, supported: u64,
	} {
		{"maxPushConstantsSize", size_of(Quad_Push_Constants), u64(l.maxPushConstantsSize)},
		{"maxStorageBufferRange", FONT_BUFFER_SIZE, u64(l.maxStorageBufferRange)},
		{"maxPerStageDescriptorStorageBuffers", 1, u64(l.maxPerStageDescriptorStorageBuffers)},
		{"maxDescriptorSetStorageBuffers", 1, u64(l.maxDescriptorSetStorageBuffers)},
		{"maxBoundDescriptorSets", 1, u64(l.maxBoundDescriptorSets)},
		{"maxDrawIndexedIndexValue", QUAD_MAX_INSTANCES * 4 - 1, u64(l.maxDrawIndexedIndexValue)},
		{"maxMemoryAllocationCount", MAX_FRAME_IN_FLIGHT + 5, u64(l.maxMemoryAllocationCount)},
		{
			"maxMemoryAllocationSize",
			size_of(Quad_Shader_Data),
			u64(c.properties11.maxMemoryAllocationSize),
		},
		{"maxBufferSize", size_of(Quad_Shader_Data), u64(c.properties13.maxBufferSize)},
	}
	for check in checks_limits {
		if check.supported < check.required {
			return {}, {renderer_error(.Device, .Insufficient_Limits, fmt.tprintf("%s requires %d; supported %d", check.name, check.required, check.supported))}
		}
	}
	capacity := vulkan13_texture_capacity(l, req.textures)
	capacity = min(
		capacity,
		c.properties11.maxPerSetDescriptors - 1 if c.properties11.maxPerSetDescriptors > 0 else 0,
	)
	if capacity == 0 {
		return {}, {renderer_error(.Device, .Insufficient_Limits, "requires at least one combined image sampler plus one font storage buffer")}
	}
	return {
		textures = capacity,
		fonts = FONT_MAX_COUNT,
		instances = QUAD_MAX_INSTANCES,
		max_image_dimension = l.maxImageDimension2D,
	}, {}
}

@(private)
vulkan13_texture_capacity :: proc(l: vk.PhysicalDeviceLimits, requested: u32) -> u32 {
	resources := l.maxPerStageResources - 1 if l.maxPerStageResources > 0 else 0
	return min(
		requested,
		l.maxPerStageDescriptorSamplers,
		l.maxPerStageDescriptorSampledImages,
		l.maxDescriptorSetSamplers,
		l.maxDescriptorSetSampledImages,
		resources,
	)
}

@(private)
vulkan13_descriptor_bindings :: proc(capacity: u32) -> [2]vk.DescriptorSetLayoutBinding {
	return {
		{
			binding = DESC_BINDING_TEXTURES,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = capacity,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = DESC_BINDING_FONTS,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX, .FRAGMENT},
		},
	}
}

@(private)
vulkan13_heap_headroom :: proc(budget, usage: vk.DeviceSize) -> vk.DeviceSize {return(
		budget - usage if budget > usage else 0 \
	)}

@(private)
vulkan13_device_priority :: proc(kind: vk.PhysicalDeviceType) -> int {
	#partial switch kind {
	case .DISCRETE_GPU:
		return 4
	case .INTEGRATED_GPU:
		return 3
	case .VIRTUAL_GPU:
		return 2
	case .CPU:
		return 1
	}
	return 0
}

@(private)
vulkan13_candidate_memory :: proc(c: Device_Capabilities) -> u64 {
	c := c
	total: u64
	for heap, i in c.memory.memoryHeaps[:c.memory.memoryHeapCount] {
		if .DEVICE_LOCAL not_in heap.flags do continue
		bytes := vulkan13_heap_headroom(c.budgets[i], c.usages[i]) if c.budget_known else heap.size
		total += min(u64(bytes), max(u64) - total)
	}
	return total
}

@(private)
vulkan13_choose_candidate :: proc(candidates: []Device_Candidate) -> int {
	best := -1
	for candidate, i in candidates {
		if candidate.tried do continue
		if best < 0 || candidate.priority > candidates[best].priority || (candidate.priority == candidates[best].priority && candidate.usable_memory > candidates[best].usable_memory) do best = i
	}
	return best
}

@(private)
vulkan13_choose_queues :: proc(
	queues: []vk.QueueFamilyProperties,
	support: []bool,
) -> (
	graphics, present: u32,
) {
	graphics, present = max(u32), max(u32)
	for q, i in queues {
		if q.queueCount == 0 do continue
		if .GRAPHICS in q.queueFlags && graphics == max(u32) do graphics = u32(i)
		if support[i] && present == max(u32) do present = u32(i)
		if .GRAPHICS in q.queueFlags && support[i] do return u32(i), u32(i)
	}
	return
}

// Bounded retries handle a changing enumeration without using unwritten entries.
@(private)
vk_enumerate :: proc(
	$T: typeid,
	instance: vk.Instance = {},
	physical: vk.PhysicalDevice = {},
	surface: vk.SurfaceKHR = {},
	device: vk.Device = {},
	swapchain: vk.SwapchainKHR = {},
) -> (
	[]T,
	vk.Result,
) {
	for _ in 0 ..< 4 {
		count: u32
		res := vk_enumerate_query(T, instance, physical, surface, device, swapchain, &count, nil)
		if res != .SUCCESS && res != .INCOMPLETE do return nil, res
		if count == 0 do return nil, .SUCCESS
		items, allocation_error := make([]T, count, context.temp_allocator)
		if allocation_error != nil do return nil, .ERROR_OUT_OF_HOST_MEMORY
		res = vk_enumerate_query(
			T,
			instance,
			physical,
			surface,
			device,
			swapchain,
			&count,
			raw_data(items),
		)
		if res == .SUCCESS do return items[:count], res
		delete(items, context.temp_allocator)
		if res != .INCOMPLETE do return nil, res
	}
	return nil, .INCOMPLETE
}

@(private)
vk_enumerate_query :: proc(
	$T: typeid,
	instance: vk.Instance,
	physical: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	device: vk.Device,
	swapchain: vk.SwapchainKHR,
	count: ^u32,
	items: [^]T,
) -> vk.Result {
	when T == vk.ExtensionProperties {
		if physical != {} {
			return vk.EnumerateDeviceExtensionProperties(physical, nil, count, items)
		}
		return vk.EnumerateInstanceExtensionProperties(nil, count, items)
	} else when T == vk.LayerProperties {
		return vk.EnumerateInstanceLayerProperties(count, items)
	} else when T == vk.PhysicalDevice {
		return vk.EnumeratePhysicalDevices(instance, count, items)
	} else when T == vk.SurfaceFormatKHR {
		return vk.GetPhysicalDeviceSurfaceFormatsKHR(physical, surface, count, items)
	} else when T == vk.PresentModeKHR {
		return vk.GetPhysicalDeviceSurfacePresentModesKHR(physical, surface, count, items)
	} else when T == vk.Image {
		return vk.GetSwapchainImagesKHR(device, swapchain, count, items)
	}
	return .ERROR_INITIALIZATION_FAILED
}

@(private)
vulkan13_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> (vk.SurfaceFormatKHR, bool) {
	preferences := [?]vk.Format{.B8G8R8A8_SRGB, .R8G8B8A8_SRGB}
	for preferred in preferences {
		for f in formats {
			if f.colorSpace == .COLORSPACE_SRGB_NONLINEAR &&
			   (f.format == preferred || f.format == .UNDEFINED) {
				return {preferred, f.colorSpace}, true
			}
		}
	}
	return {}, false
}

@(private)
vulkan13_pixel_count :: proc(width, height: int) -> (int, bool) {
	if width <= 0 || height <= 0 || width > int(max(i32)) || height > int(max(i32)) do return 0, false
	if width > max(int) / height do return 0, false
	count := width * height
	if count > max(int) / size_of(Color) do return 0, false
	return count, true
}

@(private)
vulkan13_report_device :: proc(gpu: ^GPU_Context) {
	c := &gpu.capabilities
	p := &c.properties
	fmt.printf(
		"GPU: %s vendor=%#x device=%#x API=%d.%d.%d driver=%s (%s) version=%#x\n",
		cstring(&p.deviceName[0]),
		p.vendorID,
		p.deviceID,
		p.apiVersion >> 22,
		(p.apiVersion >> 12) & 0x3ff,
		p.apiVersion & 0xfff,
		cstring(&c.properties12.driverName[0]),
		cstring(&c.properties12.driverInfo[0]),
		p.driverVersion,
	)
	fmt.printf(
		"Queues: graphics=%d present=%d; capacities: textures=%d (one fallback slot), fonts=%d instances=%d; memory budget telemetry=%v\n",
		gpu.queue_family,
		gpu.present_family,
		gpu.limits.textures,
		gpu.limits.fonts,
		gpu.limits.instances,
		c.budget_known,
	)
	estimate := u64(
		MAX_FRAME_IN_FLIGHT * size_of(Quad_Shader_Data) +
		QUAD_MAX_INSTANCES * 6 * size_of(u32) +
		2 * FONT_BUFFER_SIZE +
		TEX_STAGING_BUFFER_SIZE,
	)
	fmt.printf(
		"Initial buffers: %d bytes before allocator/alignment overhead, textures, descriptors, and swapchain\n",
		estimate,
	)
	for heap, i in c.memory.memoryHeaps[:c.memory.memoryHeapCount] {
		host_visible := false
		for memory_type in c.memory.memoryTypes[:c.memory.memoryTypeCount] {
			if memory_type.heapIndex == u32(i) && .HOST_VISIBLE in memory_type.propertyFlags do host_visible = true
		}
		fmt.printf(
			"Heap %d: size=%d device-local=%v host-visible-types=%v",
			i,
			heap.size,
			.DEVICE_LOCAL in heap.flags,
			host_visible,
		)
		if c.budget_known {
			fmt.printf(
				" budget=%d usage=%d estimated headroom=%d\n",
				c.budgets[i],
				c.usages[i],
				vulkan13_heap_headroom(c.budgets[i], c.usages[i]),
			)
		} else {
			fmt.println(" budget=unknown")
		}
	}
}

@(private)
vulkan13_initial_allocation_estimate :: proc(r: ^Renderer) -> u64 {
	buffer_bytes := u64(
		MAX_FRAME_IN_FLIGHT * size_of(Quad_Shader_Data) +
		QUAD_MAX_INSTANCES * 6 * size_of(u32) +
		2 * FONT_BUFFER_SIZE +
		TEX_STAGING_BUFFER_SIZE,
	)
	width := u64(min(r.framebuffer_size.x, int(r.gpu.limits.max_image_dimension)))
	height := u64(min(r.framebuffer_size.y, int(r.gpu.limits.max_image_dimension)))
	swapchain_pixels := width * height
	swapchain_bytes :=
		min(swapchain_pixels, max(u64) / (size_of(Color) * MAX_FRAME_IN_FLIGHT)) *
		size_of(Color) *
		MAX_FRAME_IN_FLIGHT
	// Descriptor and block allowances are estimates, not driver memory requirements.
	descriptor_allowance := u64(r.gpu.limits.textures) * 64 + 64
	allocation_allowance := u64(64 * mem.Megabyte)
	extra := buffer_bytes + descriptor_allowance + allocation_allowance + 64 * mem.Kilobyte
	return min(swapchain_bytes, max(u64) - extra) + extra
}

@(private)
vulkan13_refresh_memory :: proc(gpu: ^GPU_Context) {
	c := &gpu.capabilities
	budget := vk.PhysicalDeviceMemoryBudgetPropertiesEXT {
		sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
	}
	props := vk.PhysicalDeviceMemoryProperties2 {
		sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
	}
	if c.budget_known do props.pNext = &budget
	vk.GetPhysicalDeviceMemoryProperties2(gpu.physical, &props)
	c.memory, c.budgets, c.usages = props.memoryProperties, budget.heapBudget, budget.heapUsage
	if gpu.allocator != nil {
		budgets: [vk.MAX_MEMORY_HEAPS]vma.Budget
		vma.get_heap_budgets(gpu.allocator, &budgets[0])
		for b, i in budgets[:c.memory.memoryHeapCount] do gpu.allocator_bytes[i] = u64(b.statistics.block_bytes)
	}
}

@(private)
vulkan13_memory_summary :: proc(gpu: ^GPU_Context) -> Memory_Summary {
	c := &gpu.capabilities
	summary := Memory_Summary {
		heap_count = c.memory.memoryHeapCount,
	}
	for heap, i in c.memory.memoryHeaps[:c.memory.memoryHeapCount] {
		s := &summary.heaps[i]
		s.size, s.device_local = u64(heap.size), .DEVICE_LOCAL in heap.flags
		s.budget_known = c.budget_known
		s.allocator_bytes = gpu.allocator_bytes[i]
		if c.budget_known {
			s.budget, s.usage = u64(c.budgets[i]), u64(c.usages[i])
			s.estimated_headroom = u64(vulkan13_heap_headroom(c.budgets[i], c.usages[i]))
		}
		for memory_type in c.memory.memoryTypes[:c.memory.memoryTypeCount] {
			if memory_type.heapIndex == u32(i) && .HOST_VISIBLE in memory_type.propertyFlags do s.host_visible = true
		}
	}
	return summary
}

@(private)
vulkan13_check_texture_format :: proc(
	pd: vk.PhysicalDevice,
	format: vk.Format,
	width, height: u32,
	linear_filter: bool,
) -> Renderer_Error {
	props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(pd, format, &props)
	required := vk.FormatFeatureFlags{.SAMPLED_IMAGE, .TRANSFER_DST}
	if linear_filter do required += {.SAMPLED_IMAGE_FILTER_LINEAR}
	if props.optimalTilingFeatures & required != required {
		return renderer_error(
			.Resources,
			.Missing_Capability,
			"texture format lacks sampling, transfer, or required linear filtering",
		)
	}
	image_props: vk.ImageFormatProperties
	res := vk.GetPhysicalDeviceImageFormatProperties(
		pd,
		format,
		.D2,
		.OPTIMAL,
		{.TRANSFER_DST, .SAMPLED},
		{},
		&image_props,
	)
	if res == .ERROR_FORMAT_NOT_SUPPORTED {
		return renderer_error(
			.Resources,
			.Missing_Capability,
			"sampled transfer-destination texture format unsupported",
			vk_result(res),
		)
	}
	if res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"texture format query failed",
			vk_result(res),
		)
	}
	if width > image_props.maxExtent.width ||
	   height > image_props.maxExtent.height ||
	   ._1 not_in image_props.sampleCounts ||
	   vk.DeviceSize(width) * vk.DeviceSize(height) * size_of(Color) >
		   image_props.maxResourceSize {
		return renderer_error(
			.Resources,
			.Insufficient_Limits,
			"texture exceeds format image limits",
		)
	}
	return {}
}

#assert(size_of(Quad_Instance) == 64 && align_of(Quad_Instance) == 16)
#assert(size_of(Quad_Font) == 16 && offset_of(Quad_Font, tex_size) == 8)
#assert(offset_of(Quad_Instance, color) == 32 && offset_of(Quad_Instance, uv_rect) == 48)
#assert(offset_of(Quad_Push_Constants, data) == 64)

gpu_create_device :: proc(dctx: ^GPU_Context, req: Vulkan13_Requirements) -> Renderer_Error {
	queue_familiy_priorities: f32 = 1.0
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = dctx.queue_family,
		queueCount       = 1,
		pQueuePriorities = &queue_familiy_priorities,
	}

	queue_infos := [2]vk.DeviceQueueCreateInfo{queue_create_info, queue_create_info}
	queue_infos[1].queueFamilyIndex = dctx.present_family
	queue_info_count: u32 = 1
	if dctx.present_family != dctx.queue_family do queue_info_count = 2

	// SETUP DEVICE
	device_extensions := [2]cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME,
		vk.EXT_MEMORY_BUDGET_EXTENSION_NAME,
	}
	extension_count: u32 = 1
	if dctx.capabilities.budget_known do extension_count = 2
	enabled_vk11_features := req.features11
	enabled_vk12_features := req.features12
	enabled_vk13_features := req.features13
	enabled_vk12_features.pNext = &enabled_vk11_features
	enabled_vk13_features.pNext = &enabled_vk12_features

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &enabled_vk13_features,
		queueCreateInfoCount    = queue_info_count,
		pQueueCreateInfos       = &queue_infos[0],
		enabledExtensionCount   = extension_count,
		ppEnabledExtensionNames = &device_extensions[0],
	}
	device: vk.Device
	if res := vk.CreateDevice(dctx.physical, &device_create_info, nil, &device); res != .SUCCESS {
		return renderer_error(
			.Device,
			.Vulkan_Failure,
			"logical device creation failed",
			vk_result(res),
		)
	}
	dctx.device = device
	vk.load_proc_addresses(dctx.device)
	bindings := vulkan13_descriptor_bindings(dctx.limits.textures)
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = &bindings[0],
	}
	layout_support := vk.DescriptorSetLayoutSupport {
		sType = .DESCRIPTOR_SET_LAYOUT_SUPPORT,
	}
	vk.GetDescriptorSetLayoutSupport(dctx.device, &layout_info, &layout_support)
	if !bool(layout_support.supported) {
		vk.DestroyDevice(dctx.device, nil)
		dctx.device = {}
		return renderer_error(
			.Device,
			.Insufficient_Limits,
			"negotiated descriptor layout is unsupported",
		)
	}
	vk.GetDeviceQueue(dctx.device, dctx.queue_family, 0, &dctx.queue)
	vk.GetDeviceQueue(dctx.device, dctx.present_family, 0, &dctx.present_queue)
	return {}
}

gpu_init_allocator :: proc(dctx: ^GPU_Context) -> Renderer_Error {
	when size_of(rawptr) == 8 {
		#assert(size_of(vma.Vulkan_Functions) == 216)
		#assert(offset_of(vma.Vulkan_Functions, get_physical_device_memory_properties2_khr) == 184)
		#assert(
			size_of(vma.Allocator_Create_Info) == 88 &&
			offset_of(vma.Allocator_Create_Info, vulkan_api_version) == 72,
		)
		#assert(size_of(vma.Budget) == 40 && size_of(vma.Allocation_Info) == 56)
	}
	// SETUP VMA
	vk_functions := vma.Vulkan_Functions {
		get_physical_device_properties             = vk.GetPhysicalDeviceProperties,
		get_physical_device_memory_properties      = vk.GetPhysicalDeviceMemoryProperties,
		allocate_memory                            = vk.AllocateMemory,
		free_memory                                = vk.FreeMemory,
		map_memory                                 = vk.MapMemory,
		unmap_memory                               = vk.UnmapMemory,
		flush_mapped_memory_ranges                 = vk.FlushMappedMemoryRanges,
		invalidate_mapped_memory_ranges            = vk.InvalidateMappedMemoryRanges,
		bind_buffer_memory                         = vk.BindBufferMemory,
		bind_image_memory                          = vk.BindImageMemory,
		get_buffer_memory_requirements             = vk.GetBufferMemoryRequirements,
		get_image_memory_requirements              = vk.GetImageMemoryRequirements,
		create_buffer                              = vk.CreateBuffer,
		destroy_buffer                             = vk.DestroyBuffer,
		create_image                               = vk.CreateImage,
		destroy_image                              = vk.DestroyImage,
		cmd_copy_buffer                            = vk.CmdCopyBuffer,
		get_buffer_memory_requirements2_khr        = vk.GetBufferMemoryRequirements2,
		get_image_memory_requirements2_khr         = vk.GetImageMemoryRequirements2,
		bind_buffer_memory2_khr                    = vk.BindBufferMemory2,
		bind_image_memory2_khr                     = vk.BindImageMemory2,
		get_physical_device_memory_properties2_khr = vk.GetPhysicalDeviceMemoryProperties2,
	}
	allocator_create_info := vma.Allocator_Create_Info {
		flags                           = {.Buffer_Device_Address},
		physical_device                 = dctx.physical,
		device                          = dctx.device,
		vulkan_functions                = &vk_functions,
		instance                        = dctx.instance,
		vulkan_api_version              = vk.API_VERSION_1_3,
		preferred_large_heap_block_size = min(
			vk.DeviceSize(32 * mem.Megabyte),
			dctx.capabilities.properties11.maxMemoryAllocationSize,
		),
	}
	if dctx.capabilities.budget_known do allocator_create_info.flags += {.Ext_Memory_Budget}
	if res := vma.create_allocator(allocator_create_info, &dctx.allocator); res != .SUCCESS {
		return renderer_error(
			.Resources,
			.Vulkan_Failure,
			"GPU resource initialization failed",
			vk_result(res),
		)
	}
	return {}
}

@(private)
_append_instance :: proc(r: ^Renderer, instance: Quad_Instance, pivot: Pivot = .Topleft) {
	if !vulkan13_drawing_ready(r) do return
	fctx := &r.frame_contexts[r.frame_index]
	if fctx.total_instances >= int(r.gpu.limits.instances) {
		vulkan13_reject_frame(r, "negotiated frame instance capacity reached")
		return
	}
	if instance.type == u32(Quad_Instance_Type.Sprite) ||
	   instance.type == u32(Quad_Instance_Type.MSDF) {
		if int(instance.texture_index) >= len(r.resources.textures) {
			vulkan13_reject_frame(r, "invalid texture index")
			return
		}
	}
	if instance.type == u32(Quad_Instance_Type.MSDF) &&
	   int(instance.data1) >= len(r.resources.font_faces) {
		vulkan13_reject_frame(r, "invalid font index")
		return
	}
	instance := instance
	switch pivot {
	case .Topleft:
		instance.pos += {instance.scale.x / 2, instance.scale.y / 2}
	case .Center:
		break
	}

	fctx.shader_data.instances[fctx.total_instances] = instance
	fctx.total_instances += 1
	fctx.draw_batches[len(fctx.draw_batches) - 1].num_instances += 1
}

vulkan13_reject_frame :: proc(r: ^Renderer, message: string) {
	if r.frame_failed do return
	log.errorf("reify drawing: %s", message)
	r.frame_failed = true
}

vulkan13_drawing_ready :: proc(r: ^Renderer) -> bool {
	if r == nil do return false
	if r.frame_failed do return false
	if !r.initialized ||
	   r.stopped ||
	   !r.frame_started ||
	   len(r.frame_contexts[r.frame_index].draw_batches) == 0 {
		vulkan13_reject_frame(
			r,
			"drawing requires an active frame on an initialized, running renderer",
		)
		return false
	}
	return true
}

vulkan13_start :: proc(r: ^Renderer, camera_position: [2]f32, camera_zoom: f32) {
	if r == nil || !r.initialized || r.stopped do return
	context.allocator = r.allocator
	r.frame_started = true
	r.frame_failed = false

	r.frame_index = (r.frame_index + 1) % MAX_FRAME_IN_FLIGHT
	fctx := &r.frame_contexts[r.frame_index]
	fctx.projection_type = .World

	// create the projection * view matrix for the world w/ camera
	center_x, center_y := f32(r.window.width) * 0.5, f32(r.window.height) * 0.5
	view := linalg.matrix4_translate([3]f32{center_x, center_y, 0})
	view *= linalg.matrix4_scale([3]f32{camera_zoom, camera_zoom, 1})
	view *= linalg.matrix4_translate([3]f32{-camera_position.x, -camera_position.y, 0})
	world_projection_view := r.window.projection * view

	fctx.world_projection_view = world_projection_view
	fctx.screen_projection_view = r.window.projection // screen space just uses view identity so no need to mult
	fctx.total_instances = 0
	clear(&fctx.draw_batches)
	if reserve(&fctx.draw_batches, 1) != nil {
		vulkan13_reject_frame(r, "frame batch allocation failed (out of host memory)")
		return
	}
	append(
		&fctx.draw_batches,
		Draw_Batch {
			scissor = vk.Rect2D {
				offset = {0, 0},
				extent = {
					width = u32(max(0, r.window.width)),
					height = u32(max(0, r.window.height)),
				},
			},
		},
	)
}

// Subsequent draw calls will use a screen-space projection matrix until `vulkan13_end_screen_mode` is called.
vulkan13_begin_screen_mode :: proc(r: ^Renderer) {
	if !vulkan13_drawing_ready(r) do return
	context.allocator = r.allocator

	fctx := &r.frame_contexts[r.frame_index]
	fctx.projection_type = .Screen
	// set scissor to create a new draw batch
	old_scissor := fctx.draw_batches[len(fctx.draw_batches) - 1].scissor
	vulkan13_set_scissor(
		r,
		old_scissor.offset.x,
		old_scissor.offset.y,
		old_scissor.extent.width,
		old_scissor.extent.height,
	)
}

// Sets the projection back to using the world projection and camera view matrixes
vulkan13_end_screen_mode :: proc(r: ^Renderer) {
	if !vulkan13_drawing_ready(r) do return
	context.allocator = r.allocator

	fctx := &r.frame_contexts[r.frame_index]
	if fctx.projection_type == .World do return

	fctx.projection_type = .World
	// set scissor to create a new draw batch
	old_scissor := fctx.draw_batches[len(fctx.draw_batches) - 1].scissor
	vulkan13_set_scissor(
		r,
		old_scissor.offset.x,
		old_scissor.offset.y,
		old_scissor.extent.width,
		old_scissor.extent.height,
	)
}

@(private)
vulkan13_present :: proc(
	r: ^Renderer,
	clear_color := Color{255, 0, 255, 255},
) -> (
	err: Renderer_Error,
) {
	if r == nil || !r.initialized {
		return renderer_error(.Presentation, .Invalid_State, "renderer is not initialized")
	}
	if r.stopped {
		return renderer_error(
			.Presentation,
			.Invalid_State,
			"renderer is stopped; destroy before reinitializing",
		)
	}
	if r.frame_failed {
		r.frame_started = false
		return renderer_error(
			.Presentation,
			.Invalid_Input,
			"frame rejected; see drawing diagnostic",
		)
	}
	defer {
		r.frame_started = false
		if err.category != .None {
			r.stopped = true
		}
	}
	if err := vulkan13_update_swapchain(r); err.category != .None do return err
	if r.framebuffer_size.x == 0 || r.framebuffer_size.y == 0 do return {}
	context.allocator = r.allocator

	fctx := &r.frame_contexts[r.frame_index]

	if res := vk.WaitForFences(r.gpu.device, 1, &fctx.fence, true, max(u64)); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"frame fence wait failed",
			vk_result(res),
		)
	}

	// Next swapchain image
	image_index: u32
	res := vk.AcquireNextImageKHR(
		r.gpu.device,
		r.swapchain.handle,
		max(u64),
		fctx.present_semaphore,
		0,
		&image_index,
	)
	if res == .ERROR_OUT_OF_DATE_KHR {
		r.swapchain.needs_update = true
		return {}
	}
	if res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		return renderer_error(
			.Presentation,
			.Surface_Lost if res == .ERROR_SURFACE_LOST_KHR else .Vulkan_Failure,
			"image acquisition failed",
			vk_result(res),
		)
	}
	if res == .SUBOPTIMAL_KHR do r.swapchain.needs_update = true

	// Store updated shader data
	mem.copy(fctx.shader_data_buffer.mapped, &fctx.shader_data, size_of(Quad_Shader_Data))
	if res := vma.flush_allocation(
		r.gpu.allocator,
		fctx.shader_data_buffer.alloc,
		0,
		size_of(Quad_Shader_Data),
	); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"instance buffer flush failed",
			vk_result(res),
		)
	}

	// Record command buffer
	cb := fctx.command_buffer
	if res := vk.ResetCommandBuffer(cb, {}); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"frame command reset failed",
			vk_result(res),
		)
	}
	cb_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if res := vk.BeginCommandBuffer(cb, &cb_begin_info); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"frame command begin failed",
			vk_result(res),
		)
	}
	output_barriers := []vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = r.swapchain.images[image_index],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
	}
	barrier_dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = u32(len(output_barriers)),
		pImageMemoryBarriers    = raw_data(output_barriers),
	}
	vk.CmdPipelineBarrier2(cb, &barrier_dep_info)
	color_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = r.swapchain.views[image_index],
		imageLayout = .ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = {color = {float32 = convert_color_f32(clear_color)}},
	}
	// dynamic rendering
	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {
			extent = {
				width = r.swapchain.create_info.imageExtent.width,
				height = r.swapchain.create_info.imageExtent.height,
			},
		},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
	}
	vk.CmdBeginRendering(cb, &rendering_info)
	// vulkan (0,0) is topleft like we want
	vp := vk.Viewport {
		x      = 0,
		y      = 0,
		width  = f32(r.swapchain.create_info.imageExtent.width),
		height = f32(r.swapchain.create_info.imageExtent.height),
	}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	vk.CmdBindPipeline(cb, .GRAPHICS, r.pipeline)
	vk.CmdBindDescriptorSets(cb, .GRAPHICS, r.pipeline_layout, 0, 1, &r.resources.desc_set, 0, nil)

	vk.CmdBindIndexBuffer(cb, r.resources.index_buffer, 0, .UINT32)
	for &batch in fctx.draw_batches {
		if batch.num_instances <= 0 do continue

		projection_view: Mat4f
		switch batch.projection_type {
		case .World:
			projection_view = fctx.world_projection_view
		case .Screen:
			projection_view = fctx.screen_projection_view
		}
		push_constants := Quad_Push_Constants {
			data            = fctx.shader_data_buffer.device_addr,
			projection_view = projection_view,
		}
		vk.CmdPushConstants(
			cb,
			r.pipeline_layout,
			{.VERTEX, .FRAGMENT},
			0,
			size_of(Quad_Push_Constants),
			&push_constants,
		)
		pixel_scissor := vulkan13_pixel_scissor(r, batch.scissor)
		vk.CmdSetScissor(cb, 0, 1, &pixel_scissor)
		batch_indices_to_draw := batch.num_instances * 6
		vk.CmdDrawIndexed(cb, u32(batch_indices_to_draw), 1, u32(batch.index_offset * 6), 0, 0)
	}

	vk.CmdEndRendering(cb)
	barrier_present := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {},
		oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		image = r.swapchain.images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	barrier_present_dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier_present,
	}
	vk.CmdPipelineBarrier2(cb, &barrier_present_dep_info)
	if res := vk.EndCommandBuffer(cb); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"frame command end failed",
			vk_result(res),
		)
	}
	// Submit command buffer
	wait_stages := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &fctx.present_semaphore,
		pWaitDstStageMask    = &wait_stages,
		commandBufferCount   = 1,
		pCommandBuffers      = &cb,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &r.swapchain.render_semaphores[image_index],
	}
	if res := vk.ResetFences(r.gpu.device, 1, &fctx.fence); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"frame fence reset failed",
			vk_result(res),
		)
	}
	if res := vk.QueueSubmit(r.gpu.queue, 1, &submit_info, fctx.fence); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"frame submission failed; renderer stopped",
			vk_result(res),
		)
	}

	// vulkan13_present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.swapchain.render_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain.handle,
		pImageIndices      = &image_index,
	}
	res = vk.QueuePresentKHR(r.gpu.present_queue, &present_info)
	if res == .ERROR_OUT_OF_DATE_KHR ||
	   res == .SUBOPTIMAL_KHR {r.swapchain.needs_update = true; return {}}
	if res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Surface_Lost if res == .ERROR_SURFACE_LOST_KHR else .Vulkan_Failure,
			"presentation failed",
			vk_result(res),
		)
	}
	return {}
}

vulkan13_window_resize :: proc(r: ^Renderer, width, height: i32) {
	if r.window.width == width && r.window.height == height do return
	r.window.width = width
	r.window.height = height
	r.window.projection = vk_ortho_projection(0, f32(max(1, width)), 0, f32(max(1, height)), -1, 1)
}

FULL_UV :: Rect {
	x = 0,
	y = 0,
	w = 1,
	h = 1,
}

vulkan13_draw_image :: proc(
	r: ^Renderer,
	tex: Texture_Handle,
	position: [2]f32,
	rotation: f32 = 0,
	scale := [2]f32{1, 1},
	rgb_tint := [3]u8{255, 255, 255},
	alpha: f32 = 1,
	uv_rect := FULL_UV,
	is_additive := false,
) {
	if !vulkan13_drawing_ready(r) do return
	if tex.idx < 0 || tex.idx >= len(r.resources.textures) {
		vulkan13_reject_frame(r, "invalid texture handle")
		return
	}
	texture := r.resources.textures[tex.idx]
	uv_scale := [2]f32{uv_rect.w, uv_rect.h}
	if uv_scale.x < 0 do uv_scale.x = -uv_scale.x
	if uv_scale.y < 0 do uv_scale.y = -uv_scale.y
	pixel_scale := [2]f32 {
		scale.x * f32(texture.width) * uv_scale.x,
		scale.y * f32(texture.height) * uv_scale.y,
	}
	color := Color{rgb_tint.r, rgb_tint.g, rgb_tint.b, u8(alpha * 255 + 0.5)}
	_append_instance(
		r,
		Quad_Instance {
			pos = position,
			scale = pixel_scale,
			rotation = rotation,
			texture_index = u32(tex.idx),
			color = convert_color_pma(color, is_additive),
			type = u32(Quad_Instance_Type.Sprite),
			uv_rect = {uv_rect.x, uv_rect.y, uv_rect.w, uv_rect.h},
		},
	)
}

Pivot :: enum {
	Center,
	Topleft,
}

vulkan13_draw_rect :: proc(
	r: ^Renderer,
	position: [2]f32,
	width, height: f32,
	color: Color,
	pivot: Pivot = .Topleft,
	rotation: f32 = 0,
	is_additive := false,
) {
	_append_instance(
		r,
		Quad_Instance {
			pos = position,
			scale = {width, height},
			rotation = rotation,
			color = convert_color_pma(color, is_additive),
			type = u32(Quad_Instance_Type.Rect),
			uv_rect = {0, 0, 1, 1},
		},
		pivot,
	)
}

vulkan13_draw_line :: proc(
	r: ^Renderer,
	p0: [2]f32,
	p1: [2]f32,
	thickness: int,
	color: Color,
	rounded := false,
	is_additive := false,
) {
	if thickness <= 0 do return

	thick := f32(math.max(1, thickness))

	center_pos := (p0 + p1) * 0.5
	width := linalg.distance(p0, p1)
	height := thick
	diff := p1 - p0
	if width <= 0 {
		vulkan13_draw_rect(
			r,
			p0 - [2]f32{thick * 0.5, thick * 0.5},
			thick,
			thick,
			color,
			is_additive = is_additive,
		)
		return
	}
	rot := linalg.atan2(diff.y, diff.x)

	if rounded {
		vulkan13_draw_circle(r, p0, height, color, is_additive)
		vulkan13_draw_circle(r, p1, height, color, is_additive)
	}

	vulkan13_draw_rect(
		r,
		center_pos,
		width,
		height,
		color,
		pivot = .Center,
		rotation = rot,
		is_additive = is_additive,
	)
}

vulkan13_draw_lines :: proc(
	r: ^Renderer,
	thickness: int,
	color: Color,
	rounded := false,
	is_additive := false,
	points: ..[2]f32,
) {
	if len(points) < 2 do return
	if thickness <= 0 do return

	for i in 0 ..< len(points) - 1 {
		vulkan13_draw_line(r, points[i], points[i + 1], thickness, color, rounded, is_additive)
	}
}

vulkan13_draw_circle :: proc(
	r: ^Renderer,
	position: [2]f32,
	radius: f32,
	color: Color,
	is_additive := false,
) {
	_append_instance(
		r,
		Quad_Instance {
			pos = position,
			scale = {radius, radius},
			color = convert_color_pma(color, is_additive),
			type = u32(Quad_Instance_Type.Circle),
			uv_rect = {0, 0, 1, 1},
		},
		pivot = .Center,
	)
}

vulkan13_draw_triangle :: proc(
	r: ^Renderer,
	p1, p2, p3: [2]f32,
	color: Color,
	is_additive := false,
) {
	_append_instance(
		r,
		Quad_Instance {
			pos = p1,
			scale = p2,
			rotation = p3.x,
			data1 = transmute(u32)p3.y,
			color = convert_color_pma(color, is_additive),
			type = u32(Quad_Instance_Type.Triangle),
			uv_rect = {0, 0, 1, 1},
		},
	)
}

vulkan13_draw_text :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	text: string,
	pos: [2]f32,
	font_size: int,
	color := Color{255, 255, 255, 255},
	spaces_per_tab := 4,
	allocator := context.temp_allocator,
) {
	if !vulkan13_drawing_ready(r) do return
	context.allocator = allocator

	layout := layout_text(r, font, text, font_size, pos, spaces_per_tab, r.allocator)
	defer delete(layout.quads)

	if font.idx < 0 || font.idx >= len(r.resources.font_faces) {
		vulkan13_reject_frame(r, "invalid font handle")
		return
	}
	face := r.resources.font_faces[font.idx]
	text_color := convert_color_pma(color, false)
	for quad in layout.quads {
		_append_instance(
			r,
			Quad_Instance {
				type = u32(Quad_Instance_Type.MSDF),
				pos = quad.pos,
				scale = quad.scale,
				color = text_color,
				uv_rect = {quad.uv_rect.x, quad.uv_rect.y, quad.uv_rect.w, quad.uv_rect.h},
				texture_index = u32(face.texture.idx),
				data1 = u32(font.idx),
			},
			pivot = .Center,
		)
	}
}

vulkan13_draw_fps :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	position: [2]f32,
	font_size: int,
	color := Color{255, 255, 255, 255},
	allocator := context.allocator,
) {
	context.allocator = allocator

	_fps_tracker_update()
	fps_text := fmt.tprintf("%d FPS", fps_tracker.display)
	vulkan13_draw_text(r, font, fps_text, position, font_size, color, allocator = allocator)
}

Font_Metrics :: struct {
	text_rect:        Rect,
	font_y_base:      f32,
	font_line_height: f32,
}

vulkan13_measure_text :: proc(
	r: ^Renderer,
	font_handle: Font_Face_Handle,
	text: string,
	font_size: int,
	spaces_per_tab := 4,
	allocator := context.allocator,
) -> Font_Metrics {
	context.allocator = allocator

	layout := layout_text(
		r,
		font_handle,
		text,
		font_size,
		spaces_per_tab = spaces_per_tab,
		allocator = r.allocator,
	)
	defer delete(layout.quads)

	if font_handle.idx < 0 || font_handle.idx >= len(r.resources.font_faces) do return {}
	font := r.resources.font_faces[font_handle.idx]
	glyph_scale := f32(font_size) / f32(font.size)

	return Font_Metrics {
		text_rect = layout.bounds,
		font_y_base = font.y_base * glyph_scale,
		font_line_height = font.line_height * glyph_scale,
	}
}

@(private)
FPS_Tracker :: struct {
	initialized: bool,
	last_time:   time.Time,
	frame_count: int,
	elapsed:     time.Duration,
	display:     int,
}

fps_tracker: FPS_Tracker

@(private)
_fps_tracker_update :: proc() {
	curr_time := time.now()
	if !fps_tracker.initialized {
		fps_tracker.initialized = true
		fps_tracker.last_time = curr_time
		return
	}

	dt := time.diff(fps_tracker.last_time, curr_time)
	fps_tracker.last_time = curr_time
	fps_tracker.frame_count += 1
	fps_tracker.elapsed += dt

	if fps_tracker.elapsed >= time.Second {
		fps_tracker.display = fps_tracker.frame_count
		fps_tracker.frame_count = 0
		fps_tracker.elapsed -= time.Second
	}
}

Text_Layout_Quad :: struct {
	pos:     [2]f32,
	scale:   [2]f32,
	uv_rect: Rect,
}

Text_Layout :: struct {
	quads:  [dynamic]Text_Layout_Quad,
	bounds: Rect,
}

layout_text :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	text: string,
	font_size: int,
	pos := [2]f32{0, 0},
	spaces_per_tab := 4,
	allocator := context.allocator,
) -> Text_Layout {
	context.allocator = allocator

	layout := Text_Layout {
		bounds = Rect{x = pos.x, y = pos.y, w = 0, h = 0},
	}

	if font_size <= 0 || len(text) == 0 {
		return layout
	}
	if font.idx < 0 || font.idx >= len(r.resources.font_faces) {
		return layout
	}

	face := r.resources.font_faces[font.idx]
	glyph_scale := f32(font_size) / f32(face.size)
	layout.quads = make([dynamic]Text_Layout_Quad, 0, len(text))

	space_glyph, space_exists := font_face_get_glyph(r, font, ' ')
	space_advance := 0.25 * face.line_height * glyph_scale // fallback
	if space_exists {
		space_advance = space_glyph.x_advance * glyph_scale
	}
	tab_advance := f32(spaces_per_tab) * space_advance

	start_x := pos.x
	pen_x := pos.x
	// vulkan13_draw_text/layout_text position is top-left; convert to baseline for glyph placement.
	pen_y := pos.y + face.y_base * glyph_scale

	min_x := start_x
	max_x := start_x
	line_top := pen_y - face.y_base * glyph_scale
	line_bottom := line_top + face.line_height * glyph_scale
	min_y := line_top
	max_y := line_bottom
	has_content := false

	for rr in text {
		switch rr {
		case '\n':
			has_content = true
			if pen_x > max_x do max_x = pen_x
			pen_x = start_x
			pen_y += face.line_height * glyph_scale
			line_top = pen_y - face.y_base * glyph_scale
			line_bottom = line_top + face.line_height * glyph_scale
			if line_top < min_y do min_y = line_top
			if line_bottom > max_y do max_y = line_bottom
			continue
		case '\t':
			pen_x += tab_advance
			has_content = true
			if pen_x > max_x do max_x = pen_x
			continue
		case ' ':
			pen_x += space_advance
			has_content = true
			if pen_x > max_x do max_x = pen_x
			continue
		}

		glyph, glyph_exists := font_face_get_glyph(r, font, rr)
		if !glyph_exists {
			continue
		}

		x := pen_x + glyph.x_offset * glyph_scale
		y := pen_y - face.y_base * glyph_scale + glyph.y_offset * glyph_scale

		if glyph.width > 0 && glyph.height > 0 {
			glyph_center := [2]f32 {
				x + glyph.width * glyph_scale * 0.5,
				y + glyph.height * glyph_scale * 0.5,
			}
			uv_scale := [2]f32{glyph.uv_rect.w, glyph.uv_rect.h}
			if uv_scale.x < 0 do uv_scale.x = -uv_scale.x
			if uv_scale.y < 0 do uv_scale.y = -uv_scale.y
			pixel_scale := [2]f32 {
				glyph_scale * f32(face.tex_size.x) * uv_scale.x,
				glyph_scale * f32(face.tex_size.y) * uv_scale.y,
			}
			append(
				&layout.quads,
				Text_Layout_Quad{pos = glyph_center, scale = pixel_scale, uv_rect = glyph.uv_rect},
			)

			glyph_min_x := x
			glyph_min_y := y
			glyph_max_x := x + glyph.width * glyph_scale
			glyph_max_y := y + glyph.height * glyph_scale
			if glyph_min_x < min_x do min_x = glyph_min_x
			if glyph_min_y < min_y do min_y = glyph_min_y
			if glyph_max_x > max_x do max_x = glyph_max_x
			if glyph_max_y > max_y do max_y = glyph_max_y
		}

		pen_x += glyph.x_advance * glyph_scale
		has_content = true
		if pen_x > max_x do max_x = pen_x
	}

	if !has_content {
		return layout
	}

	layout.bounds = Rect {
		x = min_x,
		y = min_y,
		w = max_x - min_x,
		h = max_y - min_y,
	}
	return layout
}

// Set the scissor/clip in SCREEN SPACE
vulkan13_set_scissor :: proc(r: ^Renderer, x, y: i32, width, height: u32) {
	if !vulkan13_drawing_ready(r) do return
	context.allocator = r.allocator
	fctx := &r.frame_contexts[r.frame_index]
	if reserve(&fctx.draw_batches, len(fctx.draw_batches) + 1) != nil {
		vulkan13_reject_frame(r, "frame batch allocation failed (out of host memory)")
		return
	}
	append(
		&fctx.draw_batches,
		Draw_Batch {
			index_offset = fctx.total_instances,
			scissor = vk.Rect2D{offset = {x, y}, extent = {width = width, height = height}},
			num_instances = 0,
			projection_type = fctx.projection_type,
		},
	)
}

// Reset the scissor/clip back to the full window
vulkan13_clear_scissor :: proc(r: ^Renderer) {
	context.allocator = r.allocator
	vulkan13_set_scissor(r, 0, 0, u32(max(0, r.window.width)), u32(max(0, r.window.height)))
}

convert_color_f32 :: proc(color: Color) -> [4]f32 {
	return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
}

// Convert color to the pre-multiplied alpha form necessary for shaders
@(private)
convert_color_pma :: proc(color: Color, is_additive := false) -> [4]f32 {
	color_srgb := convert_color_f32(color)
	alpha := color_srgb.a

	// Instance colors are authored in sRGB bytes, but rendering occurs in
	// linear space (sRGB swapchain attachment). Convert to linear first.
	linear_rgb := linalg.vector3_srgb_to_linear([3]f32{color_srgb.r, color_srgb.g, color_srgb.b})

	// pre-multiply alpha
	linear_rgb *= alpha

	if is_additive {
		return {linear_rgb.r, linear_rgb.g, linear_rgb.b, 0}
	} else {
		return {linear_rgb.r, linear_rgb.g, linear_rgb.b, alpha}
	}
}

@(private)
Texture :: struct {
	alloc:  vma.Allocation,
	image:  vk.Image,
	view:   vk.ImageView,
	width:  int,
	height: int,
}

Texture_Handle :: struct {
	idx: int,
}

Texture_Metrics :: struct {
	width, height: int,
}

Texture_Color_Space :: enum {
	SRGB,
	Linear,
}

// Create a Texture and upload it to the GPU and get back a handle which can be
// used later to render with that Texture.
@(private)
vulkan13_texture_load :: proc(
	r: ^Renderer,
	pixels: []Color,
	width, height: int,
	optional_sampler: Maybe(vk.Sampler) = nil,
	color_space: Texture_Color_Space = .SRGB,
) -> (
	handle: Texture_Handle,
	err: Renderer_Error,
) {
	defer if err.category == .Device_Lost do r.stopped = true
	context.allocator = r.allocator

	if r.gpu.allocator == nil || r.stopped {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Invalid_State, "renderer cannot load resources")
	}
	count, valid := vulkan13_pixel_count(width, height)
	if !valid || len(pixels) != count {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Invalid_Input, "texture requires positive dimensions, nonoverflowing RGBA size, and an exact pixel slice")
	}
	if u32(width) > r.gpu.limits.max_image_dimension ||
	   u32(height) > r.gpu.limits.max_image_dimension {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Insufficient_Limits, "texture dimensions exceed maxImageDimension2D")
	}
	if len(r.resources.textures) >= int(r.gpu.limits.textures) {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Capacity_Exhausted, "negotiated texture capacity reached (includes fallback slot)")
	}
	if reserve(&r.resources.textures, len(r.resources.textures) + 1) != nil {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Allocation_Failure, "texture table allocation failed", .Out_Of_Host_Memory)
	}

	sampler: vk.Sampler
	if real_sampler, ok := optional_sampler.?; ok {
		sampler = real_sampler
		if sampler == {} {
			return {
				idx = -1,
			}, renderer_error(.Resources, .Invalid_Input, "texture sampler is null")
		}
	} else {
		sampler = r.resources.tex_sampler
	}

	texture_format: vk.Format
	switch color_space {
	case .SRGB:
		texture_format = .R8G8B8A8_SRGB
	case .Linear:
		texture_format = .R8G8B8A8_UNORM
	}
	// External sampler handles have no queryable filter state; require linear support.
	if err := vulkan13_check_texture_format(r.gpu.physical, texture_format, u32(width), u32(height), sampler != r.resources.tex_sampler); err.category != .None do return {idx = -1}, err
	vulkan13_refresh_memory(&r.gpu)
	if res := vk.DeviceWaitIdle(r.gpu.device); res != .SUCCESS {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Vulkan_Failure, "waiting for shared resource readers failed", vk_result(res))
	}

	tex, create_res := vk_create_texture(
		r.gpu.device,
		r.gpu.allocator,
		texture_format,
		u32(width),
		u32(height),
		1,
		r.gpu.capabilities.properties11.maxMemoryAllocationSize,
	)
	if create_res != .SUCCESS {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Vulkan_Failure, "texture allocation/view creation failed", vk_result(create_res))
	}
	published := false
	defer if !published && r.pending_texture.image != tex.image {
		vk.DestroyImageView(r.gpu.device, tex.view, nil)
		vma.destroy_image(r.gpu.allocator, tex.image, tex.alloc)
	}
	idx := len(r.resources.textures)

	// copy image to the staging buffer
	tex_staging_buffer_ptr: rawptr
	if res := vma.map_memory(
		r.gpu.allocator,
		r.resources.tex_staging_alloc,
		&tex_staging_buffer_ptr,
	); res != .SUCCESS {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Vulkan_Failure, "texture staging map failed", vk_result(res))
	}
	defer vma.unmap_memory(r.gpu.allocator, r.resources.tex_staging_alloc)
	if tex_staging_buffer_ptr == nil {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Allocation_Failure, "texture staging map returned null")
	}
	tile_width := min(width, r.resources.tex_staging_size / size_of(Color))
	rows_per_chunk := r.resources.tex_staging_size / (tile_width * size_of(Color))
	for y := 0; y < height; y += rows_per_chunk {
		rows := min(rows_per_chunk, height - y)
		for x := 0; x < width; x += tile_width {
			columns := min(tile_width, width - x)
			chunk_count := columns * rows
			staged_pixels := ([^]Color)(tex_staging_buffer_ptr)[:chunk_count]
			for row in 0 ..< rows do copy(staged_pixels[row * columns:(row + 1) * columns], pixels[(y + row) * width + x:(y + row) * width + x + columns])
			data_size := chunk_count * size_of(Color)
			// Apply PMA + gamma-correct conversion for color textures.
			// Keep linear data (e.g. MSDF atlases) untouched.
			if color_space == .SRGB {
				for &p in staged_pixels {
					a := f32(p.a) / 255.0
					if a == 1 do continue
					if a == 0 {
						p.r, p.g, p.b = 0, 0, 0
						continue
					}

					srgb_color := [3]f32{f32(p.r) / 255, f32(p.g) / 255, f32(p.b) / 255}
					linear_color := linalg.vector3_srgb_to_linear(srgb_color)
					linear_color *= a // pre-multiply alpha properly in linear space
					srgb_color = linalg.vector3_linear_to_srgb(linear_color)

					p.r = u8(srgb_color.r * 255 + 0.5)
					p.g = u8(srgb_color.g * 255 + 0.5)
					p.b = u8(srgb_color.b * 255 + 0.5)
				}
			}
			if res := vma.flush_allocation(
				r.gpu.allocator,
				r.resources.tex_staging_alloc,
				0,
				vk.DeviceSize(data_size),
			); res != .SUCCESS {
				return {
					idx = -1,
				}, renderer_error(.Resources, .Vulkan_Failure, "texture staging flush failed", vk_result(res))
			}

			one_time_cb, begin_res := vk_one_time_cmd_buffer_begin(
				r.gpu.device,
				r.gpu.queue,
				r.command_pool,
			)
			if begin_res != .SUCCESS {
				return {
					idx = -1,
				}, renderer_error(.Resources, .Vulkan_Failure, "texture upload begin failed", vk_result(begin_res))
			}
			{
				// transfer from the staging buffer to the GPU
				staging_to_gpu_barrier := vk.DependencyInfo {
					sType                   = .DEPENDENCY_INFO,
					imageMemoryBarrierCount = 1,
					pImageMemoryBarriers    = &vk.ImageMemoryBarrier2 {
						sType = .IMAGE_MEMORY_BARRIER_2,
						srcStageMask = {},
						srcAccessMask = {},
						dstStageMask = {.TRANSFER},
						dstAccessMask = {.TRANSFER_WRITE},
						oldLayout = .UNDEFINED,
						newLayout = .TRANSFER_DST_OPTIMAL,
						image = tex.image,
						subresourceRange = vk.ImageSubresourceRange {
							aspectMask = {.COLOR},
							levelCount = 1,
							layerCount = 1,
						},
					},
				}
				if y == 0 && x == 0 do vk.CmdPipelineBarrier2(one_time_cb.cmd, &staging_to_gpu_barrier)

				// Tell GPU to move the bytes from staging to GPU
				img_buffer_img_copy := vk.BufferImageCopy {
					bufferOffset = vk.DeviceSize(0),
					imageSubresource = vk.ImageSubresourceLayers {
						aspectMask = {.COLOR},
						mipLevel = 0,
						layerCount = 1,
					},
					imageOffset = {x = i32(x), y = i32(y)},
					imageExtent = vk.Extent3D{width = u32(columns), height = u32(rows), depth = 1},
				}
				vk.CmdCopyBufferToImage(
					one_time_cb.cmd,
					r.resources.tex_staging_buffer,
					tex.image,
					.TRANSFER_DST_OPTIMAL,
					1,
					&img_buffer_img_copy,
				)

				// Tell GPU to optimize the data and make it available to the fragment
				// shaders
				gpu_to_frag_barrier := vk.DependencyInfo {
					sType                   = .DEPENDENCY_INFO,
					imageMemoryBarrierCount = 1,
					pImageMemoryBarriers    = &vk.ImageMemoryBarrier2 {
						sType = .IMAGE_MEMORY_BARRIER_2,
						srcStageMask = {.TRANSFER},
						srcAccessMask = {.TRANSFER_WRITE},
						dstStageMask = {.FRAGMENT_SHADER},
						dstAccessMask = {.SHADER_READ},
						oldLayout = .TRANSFER_DST_OPTIMAL,
						newLayout = .SHADER_READ_ONLY_OPTIMAL,
						image = tex.image,
						subresourceRange = vk.ImageSubresourceRange {
							aspectMask = {.COLOR},
							levelCount = 1,
							layerCount = 1,
						},
					},
				}
				if y + rows == height && x + columns == width do vk.CmdPipelineBarrier2(one_time_cb.cmd, &gpu_to_frag_barrier)
			}
			if res := vk_one_time_cmd_buffer_end(&one_time_cb); res != .SUCCESS {
				if one_time_cb.cmd != {} {
					r.pending_upload, r.pending_texture = one_time_cb, tex
					r.stopped = true
				}
				return {
					idx = -1,
				}, renderer_error(.Resources, .Vulkan_Failure, "texture upload failed", vk_result(res))
			}
		}
	}

	// Append the texture descriptor to the descriptor set and upload that
	// to the GPU so it's available to the shaders
	write_desc_set := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.resources.desc_set,
		dstBinding      = DESC_BINDING_TEXTURES,
		dstArrayElement = u32(idx),
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &{
			sampler = sampler,
			imageView = tex.view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		},
	}
	if idx == 0 {
		for slot in 0 ..< r.gpu.limits.textures {
			write_desc_set.dstArrayElement = slot
			vk.UpdateDescriptorSets(r.gpu.device, 1, &write_desc_set, 0, nil)
		}
	} else {
		vk.UpdateDescriptorSets(r.gpu.device, 1, &write_desc_set, 0, nil)
	}
	append(&r.resources.textures, tex)
	published = true

	return Texture_Handle{idx = idx}, {}
}

vulkan13_rollback_texture :: proc(r: ^Renderer, handle: Texture_Handle) {
	assert(handle.idx > 0 && handle.idx == len(r.resources.textures) - 1)
	tex := r.resources.textures[handle.idx]
	fallback := r.resources.textures[0]
	info := vk.DescriptorImageInfo {
		sampler     = r.resources.tex_sampler,
		imageView   = fallback.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = r.resources.desc_set,
		dstBinding      = DESC_BINDING_TEXTURES,
		dstArrayElement = u32(handle.idx),
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &info,
	}
	vk.UpdateDescriptorSets(r.gpu.device, 1, &write, 0, nil)
	vk.DestroyImageView(r.gpu.device, tex.view, nil)
	vma.destroy_image(r.gpu.allocator, tex.image, tex.alloc)
	resize(&r.resources.textures, handle.idx)
}

vulkan13_texture_get_metrics :: proc(
	r: ^Renderer,
	handle: Texture_Handle,
) -> (
	Texture_Metrics,
	bool,
) {
	if handle.idx < 0 || handle.idx >= len(r.resources.textures) {
		return {}, false
	}
	texture := r.resources.textures[handle.idx]
	return Texture_Metrics{width = texture.width, height = texture.height}, true
}

Font_Atlas :: struct {
	pages:          []string `json:"pages"`,
	chars:          []Font_Atlas_Char `json:"chars"`,
	info:           Font_Atlas_Info `json:"info"`,
	common:         Font_Atlas_Common `json:"common"`,
	distance_field: Font_Atlas_Distance_Field `json:"distanceField"`,
	kernings:       []Font_Atlas_Kerning `json:"kernings"`,
}

Font_Atlas_Info :: struct {
	face:      string `json:"face"`,
	size:      int `json:"size"`,
	bold:      int `json:"bold"`,
	italic:    int `json:"italic"`,
	charset:   []string `json:"charset"`,
	unicode:   int `json:"unicode"`,
	stretch_h: int `json:"stretchH"`,
	smooth:    int `json:"smooth"`,
	aa:        int `json:"aa"`,
	padding:   [4]int `json:"padding"`,
	spacing:   [2]int `json:"spacing"`,
}

Font_Atlas_Common :: struct {
	line_height:   f32 `json:"lineHeight"`,
	base:          f32 `json:"base"`,
	scale_w:       int `json:"scaleW"`,
	scale_h:       int `json:"scaleH"`,
	pages:         int `json:"pages"`,
	packed:        int `json:"packed"`,
	alpha_channel: int `json:"alphaChnl"`,
	red_channel:   int `json:"redChnl"`,
	green_channel: int `json:"greenChnl"`,
	blue_channel:  int `json:"blueChnl"`,
}

Font_Atlas_Distance_Field :: struct {
	field_type:     string `json:"fieldType"`,
	distance_range: f32 `json:"distanceRange"`,
}

Font_Atlas_Char :: struct {
	id:         int `json:"id"`, // unicode codepoint
	index:      int `json:"index"`,
	glyph_char: string `json:"char"`,
	width:      int `json:"width"`,
	height:     int `json:"height"`,
	xoffset:    int `json:"xoffset"`,
	yoffset:    int `json:"yoffset"`,
	xadvance:   int `json:"xadvance"`,
	channel:    int `json:"chnl"`,
	x:          int `json:"x"`,
	y:          int `json:"y"`,
	page:       int `json:"page"`,
}

Font_Atlas_Kerning :: struct {
	first:  int `json:"first"`,
	second: int `json:"second"`,
	amount: int `json:"amount"`,
}

Font_Atlas_Load_Error :: enum {
	Invalid_Page_Count,
	Invalid_Dimensions,
	Invalid_Pixel_Format,
	Empty_Glyphs,
	Packed_Channels_Not_Supported,
}

Font_Atlas_Error :: union {
	json.Unmarshal_Error,
	image.Error,
	Font_Atlas_Load_Error,
	Renderer_Error,
}

// Load a font atlas which follows the Bitmap Font (BMF) Format (https://typebits.gitlab.io/bmf-format/)
@(private)
vulkan13_font_load :: proc(
	r: ^Renderer,
	font_atlas_json: []byte,
	font_atlas_img: []byte,
) -> (
	handle: Font_Face_Handle,
	err: Font_Atlas_Error,
) {
	defer {
		if gpu_err, ok := err.(Renderer_Error); ok && gpu_err.category == .Device_Lost {
			r.stopped = true
		}
	}
	context.allocator = r.allocator
	if !r.initialized || r.stopped {
		return {idx = -1}, renderer_error(.Resources, .Invalid_State, "renderer cannot load fonts")
	}
	if len(r.resources.font_faces) >= int(r.gpu.limits.fonts) {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Capacity_Exhausted, "negotiated font capacity reached")
	}
	if reserve(&r.resources.font_faces, len(r.resources.font_faces) + 1) != nil ||
	   reserve(&r.resources.quad_fonts, len(r.resources.quad_fonts) + 1) != nil {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Allocation_Failure, "font table allocation failed", .Out_Of_Host_Memory)
	}

	// TODO: Better support for BMF pages (multiple images files). This function
	// can take in a map of image name to image bytes to avoid reify from having
	// to load files from disk.

	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena)
	font_atlas_allocator := mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	atlas: Font_Atlas
	json.unmarshal(font_atlas_json, &atlas, allocator = font_atlas_allocator) or_return

	if len(atlas.pages) != 1 || atlas.common.pages != 1 {
		return {}, Font_Atlas_Load_Error.Invalid_Page_Count
	}
	if atlas.common.scale_w <= 0 || atlas.common.scale_h <= 0 {
		return {}, Font_Atlas_Load_Error.Invalid_Dimensions
	}
	if atlas.info.size <= 0 ||
	   atlas.common.line_height <= 0 ||
	   math.is_nan(atlas.common.line_height) ||
	   math.is_inf(atlas.common.line_height) ||
	   atlas.distance_field.distance_range <= 0 ||
	   math.is_nan(atlas.distance_field.distance_range) ||
	   math.is_inf(atlas.distance_field.distance_range) {
		return {idx = -1}, Font_Atlas_Load_Error.Invalid_Dimensions
	}
	if len(atlas.chars) == 0 {
		return {}, Font_Atlas_Load_Error.Empty_Glyphs
	}
	if atlas.common.packed != 0 {
		return {}, Font_Atlas_Load_Error.Packed_Channels_Not_Supported
	}
	for glyph in atlas.chars {
		if glyph.page != 0 ||
		   glyph.x < 0 ||
		   glyph.y < 0 ||
		   glyph.width < 0 ||
		   glyph.height < 0 ||
		   glyph.x > atlas.common.scale_w ||
		   glyph.y > atlas.common.scale_h ||
		   glyph.width > atlas.common.scale_w - glyph.x ||
		   glyph.height > atlas.common.scale_h - glyph.y {
			return {idx = -1}, Font_Atlas_Load_Error.Invalid_Dimensions
		}
	}

	atlas_img := image.load_from_bytes(font_atlas_img, allocator = font_atlas_allocator) or_return
	if atlas_img.width != atlas.common.scale_w || atlas_img.height != atlas.common.scale_h {
		return {idx = -1}, Font_Atlas_Load_Error.Invalid_Dimensions
	}
	if atlas_img.depth != 8 || (atlas_img.channels != 3 && atlas_img.channels != 4) {
		return {}, Font_Atlas_Load_Error.Invalid_Pixel_Format
	}

	pixel_count, valid := vulkan13_pixel_count(atlas_img.width, atlas_img.height)
	if !valid {
		return {idx = -1}, Font_Atlas_Load_Error.Invalid_Dimensions
	}
	atlas_img_pixels, pixels_alloc_err := make(
		[]Color,
		pixel_count,
		allocator = font_atlas_allocator,
	)
	if pixels_alloc_err != nil {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Allocation_Failure, "font pixel conversion allocation failed", .Out_Of_Host_Memory)
	}
	if atlas_img.channels == 3 {
		src := atlas_img.pixels.buf[:]
		for i in 0 ..< pixel_count {
			si := i * 3
			atlas_img_pixels[i] = {src[si], src[si + 1], src[si + 2], 255}
		}
	} else if atlas_img.channels == 4 {
		src := slice.reinterpret([]Color, atlas_img.pixels.buf[:])
		copy(atlas_img_pixels, src)
	} else {
		panic(
			fmt.tprintf(
				"vulkan13_font_load unsupporter number of channels in atlas image, num_channels=%d",
				atlas_img.channels,
			),
		)
	}

	atlas_tex, texture_error := vulkan13_texture_load(
		r,
		atlas_img_pixels,
		atlas_img.width,
		atlas_img.height,
		r.resources.msdf_sampler,
		color_space = .Linear,
	)
	if texture_error.category != .None do return {idx = -1}, texture_error
	success := false
	defer if !success do vulkan13_rollback_texture(r, atlas_tex)

	face: Font_Face
	defer if !success do font_face_destroy(&face, r.allocator)
	face.texture = atlas_tex
	face.size = atlas.info.size
	face.line_height = atlas.common.line_height
	face.y_base = atlas.common.base
	face.distance_range = atlas.distance_field.distance_range
	face.tex_size = {atlas_img.width, atlas_img.height}

	glyphs, glyph_alloc_err := make([dynamic]Font_Face_Glyph, 0, len(atlas.chars))
	face.glyphs = glyphs
	if glyph_alloc_err != nil {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Allocation_Failure, "font glyph allocation failed", .Out_Of_Host_Memory)
	}
	lookup, lookup_alloc_err := make(map[rune]int, len(atlas.chars))
	face.glyph_lookup = lookup
	if lookup_alloc_err != nil {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Allocation_Failure, "font glyph lookup allocation failed", .Out_Of_Host_Memory)
	}
	for atlas_char in atlas.chars {
		face_glyph := Font_Face_Glyph {
			r         = rune(atlas_char.id),
			width     = f32(atlas_char.width),
			height    = f32(atlas_char.height),
			uv_rect   = {
				f32(atlas_char.x) / f32(atlas_img.width),
				f32(atlas_char.y) / f32(atlas_img.height),
				f32(atlas_char.width) / f32(atlas_img.width),
				f32(atlas_char.height) / f32(atlas_img.height),
			},
			x_offset  = f32(atlas_char.xoffset),
			y_offset  = f32(atlas_char.yoffset),
			x_advance = f32(atlas_char.xadvance),
		}

		// special case: unknown character glyph
		if atlas_char.id == 0 {
			face.missing_glyph = face_glyph
			// don't put it in the face.chars since it isn't printable anyways
			continue
		}

		glyph_idx := len(face.glyphs)
		face.glyph_lookup[face_glyph.r] = glyph_idx
		append(&face.glyphs, face_glyph)
	}

	handle = Font_Face_Handle {
		idx = len(r.resources.font_faces),
	}
	quad_font := Quad_Font {
		px_range = face.distance_range,
		tex_size = {u32(face.tex_size.x), u32(face.tex_size.y)},
	}

	data_size := size_of(Quad_Font)
	mem.copy(r.resources.font_staging_buf_ptr, &quad_font, data_size)
	if res := vma.flush_allocation(
		r.gpu.allocator,
		r.resources.font_staging_alloc,
		0,
		vk.DeviceSize(data_size),
	); res != .SUCCESS {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Vulkan_Failure, "font staging flush failed", vk_result(res))
	}
	one_time_cb, begin_res := vk_one_time_cmd_buffer_begin(
		r.gpu.device,
		r.gpu.queue,
		r.command_pool,
	)
	if begin_res != .SUCCESS {
		return {
			idx = -1,
		}, renderer_error(.Resources, .Vulkan_Failure, "font upload begin failed", vk_result(begin_res))
	}
	{
		region := vk.BufferCopy {
			srcOffset = 0,
			dstOffset = vk.DeviceSize(handle.idx * size_of(Quad_Font)),
			size      = vk.DeviceSize(data_size),
		}
		vk.CmdCopyBuffer(
			one_time_cb.cmd,
			r.resources.font_staging_buffer,
			r.resources.font_device_buffer,
			1,
			&region,
		)
		dep_info := vk.DependencyInfo {
			sType                    = .DEPENDENCY_INFO,
			bufferMemoryBarrierCount = 1,
			pBufferMemoryBarriers    = &vk.BufferMemoryBarrier2 {
				sType = .BUFFER_MEMORY_BARRIER_2,
				srcStageMask = {.TRANSFER},
				srcAccessMask = {.TRANSFER_WRITE},
				dstStageMask = {.VERTEX_SHADER, .FRAGMENT_SHADER},
				dstAccessMask = {.SHADER_READ},
				buffer = r.resources.font_device_buffer,
				offset = 0,
				size = vk.DeviceSize(vk.WHOLE_SIZE),
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			},
		}
		vk.CmdPipelineBarrier2(one_time_cb.cmd, &dep_info)
	}
	if res := vk_one_time_cmd_buffer_end(&one_time_cb); res != .SUCCESS {
		if one_time_cb.cmd != {} {
			r.pending_upload = one_time_cb
			r.stopped = true
		}
		return {
			idx = -1,
		}, renderer_error(.Resources, .Vulkan_Failure, "font upload failed", vk_result(res))
	}
	append(&r.resources.font_faces, face)
	append(&r.resources.quad_fonts, quad_font)
	success = true

	return
}

Font_Face :: struct {
	texture:        Texture_Handle,
	size:           int, // default size of glyphs
	line_height:    f32,
	y_base:         f32, // y offset (from top of line) where chars sit
	distance_range: f32,
	tex_size:       [2]int,
	glyph_lookup:   map[rune]int,
	glyphs:         [dynamic]Font_Face_Glyph,
	missing_glyph:  Font_Face_Glyph,
}

// TODO may need a Font_Face_Metrics to provide user code details like y_base,
// line_height, etc for layouting.

Font_Face_Glyph :: struct {
	r:         rune,
	uv_rect:   Rect,
	width:     f32,
	height:    f32,
	x_offset:  f32,
	y_offset:  f32,
	x_advance: f32,
}

Font_Face_Handle :: struct {
	idx: int,
}

font_face_get_glyph :: proc(
	r: ^Renderer,
	handle: Font_Face_Handle,
	char: rune,
) -> (
	Font_Face_Glyph,
	bool,
) {
	context.allocator = r.allocator

	if handle.idx < 0 || handle.idx >= len(r.resources.font_faces) {
		return {}, false
	}
	face := r.resources.font_faces[handle.idx]

	gid, exists := face.glyph_lookup[char]
	if !exists || gid > len(face.glyphs) - 1 {
		return face.missing_glyph, true
	}

	return face.glyphs[gid], true
}

font_face_destroy :: proc(face: ^Font_Face, allocator := context.allocator) {
	context.allocator = allocator
	delete(face.glyph_lookup)
	delete(face.glyphs)
}

@(private)
vulkan_lib: dynlib.Library

renderer_loader_init :: proc() -> bool {
	libs: []string
	when ODIN_OS == .Windows {
		libs = []string{"vulkan-1.dll"}
	} else when ODIN_OS == .Linux {
		libs = []string{"libvulkan.so.1", "libvulkan.so"}
	} else {
		return false
	}

	for name in libs {
		lib, ok := dynlib.load_library(name)
		if !ok do continue

		sym, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
		if !found {
			dynlib.unload_library(lib)
			continue
		}

		vulkan_lib = lib
		get_instance_proc_address: vk.ProcGetInstanceProcAddr = auto_cast sym
		vk.load_proc_addresses((rawptr)(get_instance_proc_address))
		if vk.CreateInstance == nil ||
		   vk.EnumerateInstanceExtensionProperties == nil ||
		   vk.EnumerateInstanceLayerProperties == nil {
			dynlib.unload_library(lib)
			vulkan_lib = {}
			continue
		}
		return true
	}
	return false
}

renderer_loader_shutdown :: proc() {
	dynlib.unload_library(vulkan_lib)
	vulkan_lib = {}
}

@(private)
active_renderer: ^Renderer

@(private)
vulkan13_update_swapchain :: proc(r: ^Renderer) -> Renderer_Error {
	size, platform_err := r.platform.get_framebuffer_size(r.platform.user_data)
	if platform_err.message != "" || platform_err.result != .SUCCESS {
		return renderer_error(
			.Platform,
			.Platform_Failure,
			platform_err.message,
			vk_result(platform_err.result),
		)
	}
	if size.x < 0 || size.y < 0 || size.x > int(max(i32)) || size.y > int(max(i32)) {
		return renderer_error(
			.Platform,
			.Platform_Failure,
			"framebuffer dimensions must fit nonnegative i32",
		)
	}
	if size != r.framebuffer_size {
		r.framebuffer_size = size
		r.swapchain.needs_update = true
	}
	if size.x == 0 || size.y == 0 do return {}
	if r.swapchain.handle != {} && !r.swapchain.needs_update do return {}
	if res := vk.DeviceWaitIdle(r.gpu.device); res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"waiting for swapchain work failed",
			vk_result(res),
		)
	}
	caps: vk.SurfaceCapabilitiesKHR
	if res := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.gpu.physical, r.surface, &caps);
	   res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Surface_Lost if res == .ERROR_SURFACE_LOST_KHR else .Vulkan_Failure,
			"surface capabilities query failed",
			vk_result(res),
		)
	}
	if caps.currentExtent.width == 0 || caps.currentExtent.height == 0 {
		r.framebuffer_size = {}
		return {}
	}
	formats, format_res := vk_enumerate(
		vk.SurfaceFormatKHR,
		physical = r.gpu.physical,
		surface = r.surface,
	)
	defer delete(formats, context.temp_allocator)
	if format_res != .SUCCESS {
		return renderer_error(
			.Presentation,
			.Vulkan_Failure,
			"surface format enumeration failed",
			vk_result(format_res),
		)
	}
	format, format_ok := vulkan13_surface_format(formats)
	if !format_ok {
		return renderer_error(
			.Presentation,
			.Missing_Capability,
			"surface requires an sRGB nonlinear attachment format; UNORM fallback is not supported",
		)
	}
	if format.format != r.gpu.surface_format.format {
		pipeline: vk.Pipeline
		layout: vk.PipelineLayout
		res := vk_pipeline_init(
			r.gpu.device,
			Quad_Push_Constants,
			Quad_Instance,
			&r.resources.desc_set_layout,
			r.shader_module,
			&layout,
			&pipeline,
			format.format,
		)
		if res != .SUCCESS {
			vk.DestroyPipelineLayout(r.gpu.device, layout, nil)
			return renderer_error(
				.Presentation,
				.Vulkan_Failure,
				"pipeline recreation for surface format failed",
				vk_result(res),
			)
		}
		vk.DestroyPipeline(r.gpu.device, r.pipeline, nil)
		vk.DestroyPipelineLayout(r.gpu.device, r.pipeline_layout, nil)
		r.pipeline, r.pipeline_layout = pipeline, layout
	}
	r.gpu.surface_format = format
	if err := swapchain_context_init(&r.swapchain, &r.gpu, r.surface, caps, i32(size.x), i32(size.y), recreate = r.swapchain.handle != {}, allocator = r.allocator); err.category != .None do return err
	r.swapchain.needs_update = false
	return {}
}

@(private)
vulkan13_pixel_scissor :: proc(r: ^Renderer, logical: vk.Rect2D) -> vk.Rect2D {
	extent := r.swapchain.create_info.imageExtent
	sx := f64(extent.width) / f64(max(1, r.window.width))
	sy := f64(extent.height) / f64(max(1, r.window.height))
	left := i64(clamp(math.floor(f64(logical.offset.x) * sx), 0, f64(extent.width)))
	top := i64(clamp(math.floor(f64(logical.offset.y) * sy), 0, f64(extent.height)))
	right := clamp(
		i64(math.ceil((f64(logical.offset.x) + f64(logical.extent.width)) * sx)),
		left,
		i64(extent.width),
	)
	bottom := clamp(
		i64(math.ceil((f64(logical.offset.y) + f64(logical.extent.height)) * sy)),
		top,
		i64(extent.height),
	)
	return {offset = {i32(left), i32(top)}, extent = {u32(right - left), u32(bottom - top)}}
}
