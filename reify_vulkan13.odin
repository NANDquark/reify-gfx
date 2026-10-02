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
IMAGE_FORMAT := vk.Format.B8G8R8A8_SRGB
FONT_MAX_COUNT :: 128
FONT_BUFFER_SIZE :: FONT_MAX_COUNT * size_of(Quad_Font)
TEX_STAGING_BUFFER_SIZE :: 128 * mem.Megabyte
TEXTURE_MAX_COUNT :: 1024
DESC_BINDING_TEXTURES :: 0
DESC_BINDING_FONTS :: 1
ENABLE_VK_VALIDATION :: bool(#config(Reify_Enable_Validation, false))

Renderer :: struct {
	allocator:        mem.Allocator,
	platform:         Platform_Interface,
	initialized:      bool,
	loader_owned:     bool,
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
	instance:       vk.Instance,
	physical:       vk.PhysicalDevice,
	device:         vk.Device,
	queue:          vk.Queue,
	queue_family:   u32,
	present_family: u32,
	present_queue:  vk.Queue,
	allocator:      vma.Allocator,
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


vulkan13_init :: proc(r: ^Renderer, info: Renderer_Init_Info) -> Renderer_Error {
	if r == nil do return renderer_error(.Platform, .Invalid_State, "renderer pointer is nil")
	p := info.platform
	if p.get_framebuffer_size == nil ||
	   p.vulkan.required_instance_extensions == nil ||
	   p.vulkan.create_surface == nil ||
	   p.vulkan.destroy_surface == nil {
		return renderer_error(
			.Platform,
			.Missing_Capability,
			"framebuffer size and all Vulkan surface callbacks are required",
		)
	}
	if info.logical_size.x < 0 || info.logical_size.y < 0 || info.logical_size.x > int(max(i32)) || info.logical_size.y > int(max(i32)) do return renderer_error(.Platform, .Invalid_State, "logical dimensions must fit nonnegative i32")
	if _, reserved := sync.atomic_compare_exchange_strong(&active_renderer, cast(^Renderer)nil, r); !reserved do return renderer_error(.Platform, .Invalid_State, "only one active renderer is supported")
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
	if !renderer_loader_init() do return renderer_error(.Loader, .Vulkan_Failure, "Vulkan loader unavailable")
	r.loader_owned = true
	extensions, platform_err := p.vulkan.required_instance_extensions(p.user_data)
	if platform_err.message != "" || platform_err.result != .SUCCESS do return renderer_error(.Platform, .Platform_Failure, platform_err.message, platform_err.result)
	if err := gpu_init(r, extensions); err.category != .None do return err
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
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}
	if res := vma.create_buffer(r.gpu.allocator, index_buf_create_info, index_buf_alloc_create_info, &r.resources.index_buffer, &r.resources.index_alloc, nil); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	alloc_info: vma.Allocation_Info
	vma.get_allocation_info(r.gpu.allocator, r.resources.index_alloc, &alloc_info)
	indices := cast([^]u32)alloc_info.mapped_data
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
	vma.flush_allocation(r.gpu.allocator, r.resources.index_alloc, 0, index_buf_size)

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
	if res := vk.CreateSampler(r.gpu.device, &tex_sampler_create_info, nil, &r.resources.tex_sampler); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
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
	if res := vk.CreateSampler(r.gpu.device, &msdf_sampler_create_info, nil, &r.resources.msdf_sampler); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)

	// CPU & GPU Sync
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		u_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size  = size_of(Quad_Shader_Data),
			usage = {.SHADER_DEVICE_ADDRESS},
		}
		u_buffer_alloc_create_info := vma.Allocation_Create_Info {
			flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
			usage = .Auto,
		}
		if res := vma.create_buffer(r.gpu.allocator, u_buffer_create_info, u_buffer_alloc_create_info, &r.frame_contexts[i].shader_data_buffer.buffer, &r.frame_contexts[i].shader_data_buffer.alloc, nil); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
		if res := vma.map_memory(r.gpu.allocator, r.frame_contexts[i].shader_data_buffer.alloc, &r.frame_contexts[i].shader_data_buffer.mapped); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
		u_buffer_bda_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = r.frame_contexts[i].shader_data_buffer.buffer,
		}
		r.frame_contexts[i].shader_data_buffer.device_addr = vk.GetBufferDeviceAddress(
			r.gpu.device,
			&u_buffer_bda_info,
		)
	}
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		if res := vk.CreateFence(r.gpu.device, &fence_create_info, nil, &r.frame_contexts[i].fence); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
		if res := vk.CreateSemaphore(r.gpu.device, &semaphore_create_info, nil, &r.frame_contexts[i].present_semaphore); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	}

	// COMMAND BUFFERS
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.gpu.queue_family,
	}
	if res := vk.CreateCommandPool(r.gpu.device, &command_pool_create_info, nil, &r.command_pool); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	command_buffer_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		commandBufferCount = 1,
	}
	// TODO: This is awkward because by keeping command buffer in the Frame_Context
	// we cannot allocate an array of command buffers so we do it as two separate
	// allocations
	for &fctx in r.frame_contexts {
		if res := vk.AllocateCommandBuffers(r.gpu.device, &command_buffer_alloc_info, &fctx.command_buffer); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
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
	if res := vma.create_buffer(r.gpu.allocator, font_staging_buf_create_info, font_staging_buf_alloc_create_info, &r.resources.font_staging_buffer, &r.resources.font_staging_alloc, nil); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	font_staging_alloc_info: vma.Allocation_Info
	vma.get_allocation_info(
		r.gpu.allocator,
		r.resources.font_staging_alloc,
		&font_staging_alloc_info,
	)
	r.resources.font_staging_buf_ptr = cast([^]Quad_Font)font_staging_alloc_info.mapped_data
	font_device_buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = FONT_BUFFER_SIZE,
		usage = {.TRANSFER_DST, .STORAGE_BUFFER},
	}
	font_device_alloc_create_info := vma.Allocation_Create_Info {
		usage          = .Auto,
		required_flags = {.DEVICE_LOCAL},
	}
	if res := vma.create_buffer(r.gpu.allocator, font_device_buffer_create_info, font_device_alloc_create_info, &r.resources.font_device_buffer, &r.resources.font_device_alloc, nil); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)

	// Textures globals
	tex_staging_buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(TEX_STAGING_BUFFER_SIZE),
		usage = {.TRANSFER_SRC},
	}
	tex_staging_alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Host_Access_Sequential_Write, .Mapped},
		usage = .Auto,
	}
	if res := vma.create_buffer(r.gpu.allocator, tex_staging_buffer_create_info, tex_staging_alloc_create_info, &r.resources.tex_staging_buffer, &r.resources.tex_staging_alloc, nil); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)

	// descriptors
	desc_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = DESC_BINDING_TEXTURES,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = TEXTURE_MAX_COUNT,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = DESC_BINDING_FONTS,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = FONT_MAX_COUNT,
			stageFlags = {.VERTEX, .FRAGMENT},
		},
	}
	desc_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(desc_layout_bindings),
		pBindings    = raw_data(desc_layout_bindings[:]),
	}
	if res := vk.CreateDescriptorSetLayout(r.gpu.device, &desc_layout_create_info, nil, &r.resources.desc_set_layout); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	desc_pool_sizes := [?]vk.DescriptorPoolSize {
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = TEXTURE_MAX_COUNT},
		{type = .STORAGE_BUFFER, descriptorCount = FONT_MAX_COUNT},
	}
	desc_pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = len(desc_pool_sizes),
		pPoolSizes    = raw_data(desc_pool_sizes[:]),
	}
	if res := vk.CreateDescriptorPool(r.gpu.device, &desc_pool_create_info, nil, &r.resources.desc_pool); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	desc_pool_count := u32(TEXTURE_MAX_COUNT)
	desc_set_alloc_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts  = &desc_pool_count,
	}
	desc_set_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &desc_set_alloc_info,
		descriptorPool     = r.resources.desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.resources.desc_set_layout,
	}
	if res := vk.AllocateDescriptorSets(r.gpu.device, &desc_set_alloc, &r.resources.desc_set); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)

	if res := vk_shader_module_init(r.gpu.device, &r.shader_module, SHADER_BYTES); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "shader module creation failed", res)
	if res := vk_pipeline_init(r.gpu.device, Quad_Push_Constants, Quad_Instance, &r.resources.desc_set_layout, r.shader_module, &r.pipeline_layout, &r.pipeline); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "pipeline creation failed", res)
	if err := vulkan13_update_swapchain(r); err.category != .None do return err
	r.initialized = true
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
		vk.DeviceWaitIdle(r.gpu.device)

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

	sc.gpu = gpu

	if recreate {
		for &swi in sc.views {
			vk.DestroyImageView(sc.gpu.device, swi, nil)
			swi = {}
		}
	}

	present_mode: vk.PresentModeKHR = .FIFO
	if !sc.vsync_enabled {
		present_mode_count: u32
		if res := vk.GetPhysicalDeviceSurfacePresentModesKHR(sc.gpu.physical, surface, &present_mode_count, nil); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
		if present_mode_count > 0 {
			present_modes := make([]vk.PresentModeKHR, present_mode_count, allocator)
			defer delete(present_modes)
			if res := vk.GetPhysicalDeviceSurfacePresentModesKHR(sc.gpu.physical, surface, &present_mode_count, raw_data(present_modes)); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
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
	sc.create_info = vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = surface,
		minImageCount    = surface_caps.minImageCount,
		imageFormat      = IMAGE_FORMAT,
		imageColorSpace  = .COLORSPACE_SRGB_NONLINEAR,
		imageExtent      = swapchain_extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = {.IDENTITY},
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		oldSwapchain     = sc.handle if recreate else {},
	}
	if families[0] != families[1] {
		sc.create_info.imageSharingMode = .CONCURRENT
		sc.create_info.queueFamilyIndexCount = 2
		sc.create_info.pQueueFamilyIndices = &families[0]
	}
	new_handle: vk.SwapchainKHR
	res := vk.CreateSwapchainKHR(sc.gpu.device, &sc.create_info, nil, &new_handle)
	sc.create_info.pQueueFamilyIndices = nil
	if res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
	sc.handle = new_handle

	if recreate do vk.DestroySwapchainKHR(sc.gpu.device, sc.create_info.oldSwapchain, nil)

	swapchain_image_count: u32
	if res := vk.GetSwapchainImagesKHR(sc.gpu.device, sc.handle, &swapchain_image_count, nil); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
	resize(&sc.images, swapchain_image_count)
	if res := vk.GetSwapchainImagesKHR(sc.gpu.device, sc.handle, &swapchain_image_count, raw_data(sc.images)); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
	clear(&sc.views)
	resize(&sc.views, int(swapchain_image_count))
	for &view in sc.views do view = {}
	for i in 0 ..< swapchain_image_count {
		view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = sc.images[i],
			viewType = .D2,
			format = IMAGE_FORMAT,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if res := vk.CreateImageView(sc.gpu.device, &view_create_info, nil, &sc.views[i]); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
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
		if res := vk.CreateSemaphore(sc.gpu.device, &semaphore_create_info, nil, &s); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "swapchain initialization failed", res)
	}

	sc.create_info.pQueueFamilyIndices = nil
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

	app_info := &vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		pApplicationName = "Reify",
		apiVersion = vk.API_VERSION_1_3,
	}
	instance_extensions := make([dynamic]cstring, context.temp_allocator)
	defer delete(instance_extensions)
	append(&instance_extensions, vk.KHR_SURFACE_EXTENSION_NAME)
	for name in required_extensions {
		if name == nil do return renderer_error(.Instance, .Missing_Extension, "nil instance extension name")
		duplicate := false
		for existing in instance_extensions {
			if string(existing) == string(name) {
				duplicate = true
				break
			}
		}
		if !duplicate do append(&instance_extensions, name)
	}

	ext_count: u32
	if res := vk.EnumerateInstanceExtensionProperties(nil, &ext_count, nil); res != .SUCCESS do return renderer_error(.Instance, .Vulkan_Failure, "instance extension enumeration failed", res)
	available := make([]vk.ExtensionProperties, ext_count, context.temp_allocator)
	defer delete(available, context.temp_allocator)
	if res := vk.EnumerateInstanceExtensionProperties(nil, &ext_count, raw_data(available)); res != .SUCCESS do return renderer_error(.Instance, .Vulkan_Failure, "instance extension enumeration failed", res)
	for name in instance_extensions {
		if name == nil do return renderer_error(.Instance, .Missing_Extension, "nil instance extension name")
		found := false
		for &ext in available {
			if string(name) == string(cstring(&ext.extensionName[0])) {
				found = true
				break
			}
		}
		if !found do return renderer_error(.Instance, .Missing_Extension, string(name), .ERROR_EXTENSION_NOT_PRESENT)
	}
	count: u32
	vk.EnumerateInstanceLayerProperties(&count, nil)
	layers_properties := make([]vk.LayerProperties, count, context.temp_allocator)
	defer delete(layers_properties, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&count, raw_data(layers_properties))
	enabled_layers := make([dynamic]cstring, context.temp_allocator)
	defer delete(enabled_layers)
	if ENABLE_VK_VALIDATION {
		desired_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
		for desired in desired_layers {
			found := false
			for &prop in layers_properties {
				if desired == cstring(&prop.layerName[0]) {
					found = true
					break
				}
			}
			if found {
				append(&enabled_layers, desired)
			} else {
				fmt.printf("Warning: Layer %s not found. Skipping...\n", desired)
			}
		}
	}
	instance_create_info := &vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = app_info,
		enabledExtensionCount   = u32(len(instance_extensions)),
		ppEnabledExtensionNames = raw_data(instance_extensions),
		enabledLayerCount       = u32(len(enabled_layers)), // Now dynamically 0 or 1
		ppEnabledLayerNames     = raw_data(enabled_layers),
	}
	if res := vk.CreateInstance(instance_create_info, nil, &dctx.instance); res != .SUCCESS do return renderer_error(.Instance, .Vulkan_Failure, "instance creation failed", res)
	vk.load_proc_addresses(dctx.instance)

	surface, platform_err := r.platform.vulkan.create_surface(r.platform.user_data, dctx.instance)
	if platform_err.message != "" || platform_err.result != .SUCCESS do return renderer_error(.Surface, .Platform_Failure, platform_err.message, platform_err.result)
	if surface == {} do return renderer_error(.Surface, .Platform_Failure, "surface callback returned a null surface")
	r.surface = surface

	// SELECT DEVICE
	device_count: u32
	if res := vk.EnumeratePhysicalDevices(dctx.instance, &device_count, nil); res != .SUCCESS do return renderer_error(.Device, .Vulkan_Failure, "physical device enumeration failed", res)
	if device_count == 0 do return renderer_error(.Device, .No_Present_Device, "no physical devices available")
	phys_devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	defer delete(phys_devices, context.temp_allocator)
	if res := vk.EnumeratePhysicalDevices(dctx.instance, &device_count, raw_data(phys_devices)); res != .SUCCESS do return renderer_error(.Device, .Vulkan_Failure, "physical device enumeration failed", res)
	best_score := min(int)
	for pd in phys_devices {
		graphics, present: u32 = max(u32), max(u32)
		queue_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(pd, &queue_count, nil)
		queues := make([]vk.QueueFamilyProperties, queue_count, context.temp_allocator)
		defer delete(queues, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(pd, &queue_count, raw_data(queues))
		for q, i in queues {
			if q.queueCount == 0 do continue
			supported: b32
			if res := vk.GetPhysicalDeviceSurfaceSupportKHR(pd, u32(i), r.surface, &supported); res != .SUCCESS do return renderer_error(.Device, .Vulkan_Failure, "presentation support query failed", res)
			if .GRAPHICS in q.queueFlags && graphics == max(u32) do graphics = u32(i)
			if bool(supported) && present == max(u32) do present = u32(i)
			if .GRAPHICS in q.queueFlags &&
			   bool(supported) {graphics, present = u32(i), u32(i); break}
		}
		if graphics == max(u32) || present == max(u32) do continue
		score := vk_rate_phys_device(pd)
		if score > best_score {
			dctx.physical, dctx.queue_family, dctx.present_family = pd, graphics, present
			best_score = score
		}
	}
	if dctx.physical == {} do return renderer_error(.Device, .No_Present_Device, "no graphics/presentation capable device for this surface")
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
	device_extensions := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	enabled_vk10_features := vk.PhysicalDeviceFeatures {
		samplerAnisotropy = true,
	}
	enabled_vk11_features := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters = true,
	}
	enabled_vk12_features := vk.PhysicalDeviceVulkan12Features {
		sType                                    = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                                    = &enabled_vk11_features,
		descriptorIndexing                       = true,
		descriptorBindingVariableDescriptorCount = true,
		runtimeDescriptorArray                   = true,
		bufferDeviceAddress                      = true,
	}
	enabled_vk13_features := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &enabled_vk12_features,
		synchronization2 = true,
		dynamicRendering = true,
	}

	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &enabled_vk13_features,
		queueCreateInfoCount    = queue_info_count,
		pQueueCreateInfos       = &queue_infos[0],
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pEnabledFeatures        = &enabled_vk10_features,
	}
	if res := vk.CreateDevice(dctx.physical, &device_create_info, nil, &dctx.device); res != .SUCCESS do return renderer_error(.Device, .Vulkan_Failure, "logical device creation failed", res)
	vk.load_proc_addresses(dctx.device)
	vk.GetDeviceQueue(dctx.device, dctx.queue_family, 0, &dctx.queue)
	vk.GetDeviceQueue(dctx.device, dctx.present_family, 0, &dctx.present_queue)

	// SETUP VMA
	vk_functions := vma.Vulkan_Functions {
		get_physical_device_properties        = vk.GetPhysicalDeviceProperties,
		get_physical_device_memory_properties = vk.GetPhysicalDeviceMemoryProperties,
		allocate_memory                       = vk.AllocateMemory,
		free_memory                           = vk.FreeMemory,
		map_memory                            = vk.MapMemory,
		unmap_memory                          = vk.UnmapMemory,
		flush_mapped_memory_ranges            = vk.FlushMappedMemoryRanges,
		invalidate_mapped_memory_ranges       = vk.InvalidateMappedMemoryRanges,
		bind_buffer_memory                    = vk.BindBufferMemory,
		bind_image_memory                     = vk.BindImageMemory,
		get_buffer_memory_requirements        = vk.GetBufferMemoryRequirements,
		get_image_memory_requirements         = vk.GetImageMemoryRequirements,
		create_buffer                         = vk.CreateBuffer,
		destroy_buffer                        = vk.DestroyBuffer,
		create_image                          = vk.CreateImage,
		destroy_image                         = vk.DestroyImage,
		cmd_copy_buffer                       = vk.CmdCopyBuffer,
	}
	allocator_create_info := vma.Allocator_Create_Info {
		flags            = {.Buffer_Device_Address},
		physical_device  = dctx.physical,
		device           = dctx.device,
		vulkan_functions = &vk_functions,
		instance         = dctx.instance,
	}
	if res := vma.create_allocator(allocator_create_info, &dctx.allocator); res != .SUCCESS do return renderer_error(.Resources, .Vulkan_Failure, "GPU resource initialization failed", res)
	return {}
}

@(private)
_append_instance :: proc(r: ^Renderer, instance: Quad_Instance, pivot: Pivot = .Topleft) {
	instance := instance
	switch pivot {
	case .Topleft:
		instance.pos += {instance.scale.x / 2, instance.scale.y / 2}
	case .Center:
		break
	}

	fctx := &r.frame_contexts[r.frame_index]
	fctx.shader_data.instances[fctx.total_instances] = instance
	fctx.total_instances += 1
	if len(fctx.draw_batches) <= 0 {
		log.error("Renderer draw_* called before Renderer vulkan13_start")
	}
	fctx.draw_batches[len(fctx.draw_batches) - 1].num_instances += 1
}

vulkan13_start :: proc(r: ^Renderer, camera_position: [2]f32, camera_zoom: f32) {
	context.allocator = r.allocator

	r.frame_index = (r.frame_index + 1) % MAX_FRAME_IN_FLIGHT
	fctx := &r.frame_contexts[r.frame_index]

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

vulkan13_present :: proc(r: ^Renderer, clear_color := Color{255, 0, 255, 255}) -> Renderer_Error {
	if r == nil || !r.initialized do return renderer_error(.Presentation, .Invalid_State, "renderer is not initialized")
	if err := vulkan13_update_swapchain(r); err.category != .None do return err
	if r.framebuffer_size.x == 0 || r.framebuffer_size.y == 0 do return {}
	context.allocator = r.allocator

	fctx := &r.frame_contexts[r.frame_index]

	vk_assert(vk.WaitForFences(r.gpu.device, 1, &fctx.fence, true, max(u64)))

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
	if res == .ERROR_OUT_OF_DATE_KHR {r.swapchain.needs_update = true; return {}}
	if res != .SUCCESS && res != .SUBOPTIMAL_KHR do return renderer_error(.Presentation, .Surface_Lost if res == .ERROR_SURFACE_LOST_KHR else .Vulkan_Failure, "image acquisition failed", res)
	if res == .SUBOPTIMAL_KHR do r.swapchain.needs_update = true
	vk_assert(vk.ResetFences(r.gpu.device, 1, &fctx.fence))

	// Store updated shader data
	mem.copy(fctx.shader_data_buffer.mapped, &fctx.shader_data, size_of(Quad_Shader_Data))
	vma.flush_allocation(
		r.gpu.allocator,
		fctx.shader_data_buffer.alloc,
		0,
		size_of(Quad_Shader_Data),
	)

	// Record command buffer
	cb := fctx.command_buffer
	vk_assert(vk.ResetCommandBuffer(cb, {}))
	cb_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_assert(vk.BeginCommandBuffer(cb, &cb_begin_info))
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
	vk.EndCommandBuffer(cb)
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
	vk_assert(vk.QueueSubmit(r.gpu.queue, 1, &submit_info, fctx.fence))

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
	if res != .SUCCESS do return renderer_error(.Presentation, .Surface_Lost if res == .ERROR_SURFACE_LOST_KHR else .Vulkan_Failure, "presentation failed", res)
	return {}
}

vulkan13_window_resize :: proc(r: ^Renderer, width, height: i32) {
	context.allocator = r.allocator

	r.window.width = width
	r.window.height = height
	r.window.projection = vk_ortho_projection(0, f32(max(1, width)), 0, f32(max(1, height)), -1, 1)
	r.swapchain.needs_update = true
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
	context.allocator = allocator

	layout := layout_text(r, font, text, font_size, pos, spaces_per_tab, r.allocator)
	defer delete(layout.quads)

	if font.idx > len(r.resources.font_faces) - 1 {
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
	if font.idx > len(r.resources.font_faces) - 1 {
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
	context.allocator = r.allocator
	fctx := &r.frame_contexts[r.frame_index]
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
vulkan13_texture_load :: proc(
	r: ^Renderer,
	pixels: []Color,
	width, height: int,
	optional_sampler: Maybe(vk.Sampler) = nil,
	color_space: Texture_Color_Space = .SRGB,
) -> Texture_Handle {
	context.allocator = r.allocator

	if len(r.resources.textures) == TEXTURE_MAX_COUNT {
		panic("maximum 1024 textures reached")
	}

	sampler: vk.Sampler
	if real_sampler, ok := optional_sampler.?; ok {
		sampler = real_sampler
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

	tex := vk_create_texture(
		r.gpu.device,
		r.gpu.allocator,
		texture_format,
		u32(width),
		u32(height),
		1,
	)
	idx := len(r.resources.textures)
	append(&r.resources.textures, tex)

	// copy image to the staging buffer
	tex_staging_buffer_ptr: rawptr
	vk_assert(
		vma.map_memory(r.gpu.allocator, r.resources.tex_staging_alloc, &tex_staging_buffer_ptr),
	)
	data_size := len(pixels) * size_of(Color)
	mem.copy(tex_staging_buffer_ptr, raw_data(pixels), data_size)
	// Apply PMA + gamma-correct conversion for color textures.
	// Keep linear data (e.g. MSDF atlases) untouched.
	if color_space == .SRGB {
		staged_pixels := ([^]Color)(tex_staging_buffer_ptr)[:len(pixels)]
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
	vma.flush_allocation(
		r.gpu.allocator,
		r.resources.tex_staging_alloc,
		0,
		vk.DeviceSize(data_size),
	)

	one_time_cb := vk_one_time_cmd_buffer_begin(r.gpu.device, r.gpu.queue, r.command_pool)
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
		vk.CmdPipelineBarrier2(one_time_cb.cmd, &staging_to_gpu_barrier)

		// Tell GPU to move the bytes from staging to GPU
		img_buffer_img_copy := vk.BufferImageCopy {
			bufferOffset = vk.DeviceSize(0),
			imageSubresource = vk.ImageSubresourceLayers {
				aspectMask = {.COLOR},
				mipLevel = 0,
				layerCount = 1,
			},
			imageExtent = vk.Extent3D{width = u32(width), height = u32(height), depth = 1},
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
		vk.CmdPipelineBarrier2(one_time_cb.cmd, &gpu_to_frag_barrier)
	}
	vk_one_time_cmd_buffer_end(&one_time_cb)
	vma.unmap_memory(r.gpu.allocator, r.resources.tex_staging_alloc)

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
	vk.UpdateDescriptorSets(r.gpu.device, 1, &write_desc_set, 0, nil)
	vk_assert(vk.QueueWaitIdle(r.gpu.queue))

	return Texture_Handle{idx = idx}
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

Font_Atlas_Error :: union #shared_nil {
	json.Unmarshal_Error,
	image.Error,
	Font_Atlas_Load_Error,
}

// Load a font atlas which follows the Bitmap Font (BMF) Format (https://typebits.gitlab.io/bmf-format/)
vulkan13_font_load :: proc(
	r: ^Renderer,
	font_atlas_json: []byte,
	font_atlas_img: []byte,
) -> (
	handle: Font_Face_Handle,
	err: Font_Atlas_Error,
) {
	context.allocator = r.allocator

	// TODO: Better support for BMF pages (multiple images files). This function
	// can take in a map of image name to image bytes to avoid reify from having
	// to load files from disk.

	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena)
	font_atlas_allocator := mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	atlas := new(Font_Atlas)
	json.unmarshal(font_atlas_json, atlas, allocator = font_atlas_allocator) or_return

	if len(atlas.pages) != 1 || atlas.common.pages != 1 {
		return {}, Font_Atlas_Load_Error.Invalid_Page_Count
	}
	if atlas.common.scale_w <= 0 || atlas.common.scale_h <= 0 {
		return {}, Font_Atlas_Load_Error.Invalid_Dimensions
	}
	if len(atlas.chars) == 0 {
		return {}, Font_Atlas_Load_Error.Empty_Glyphs
	}
	if atlas.common.packed != 0 {
		return {}, Font_Atlas_Load_Error.Packed_Channels_Not_Supported
	}

	atlas_img := image.load_from_bytes(font_atlas_img, allocator = font_atlas_allocator) or_return
	if atlas_img.depth != 8 || (atlas_img.channels != 3 && atlas_img.channels != 4) {
		return {}, Font_Atlas_Load_Error.Invalid_Pixel_Format
	}

	pixel_count := atlas_img.width * atlas_img.height
	atlas_img_pixels := make([]Color, pixel_count, allocator = font_atlas_allocator)
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

	atlas_tex := vulkan13_texture_load(
		r,
		atlas_img_pixels,
		atlas_img.width,
		atlas_img.height,
		r.resources.msdf_sampler,
		color_space = .Linear,
	)

	face: Font_Face
	face.texture = atlas_tex
	face.size = atlas.info.size
	face.line_height = atlas.common.line_height
	face.y_base = atlas.common.base
	face.distance_range = atlas.distance_field.distance_range
	face.tex_size = {atlas_img.width, atlas_img.height}

	face.glyphs = make([dynamic]Font_Face_Glyph, 0, len(atlas.chars))
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
	append(&r.resources.font_faces, face)
	append(
		&r.resources.quad_fonts,
		Quad_Font {
			px_range = face.distance_range,
			tex_size = {u32(face.tex_size.x), u32(face.tex_size.y)},
		},
	)

	data_size := len(r.resources.font_faces) * size_of(Quad_Font)
	mem.copy(r.resources.font_staging_buf_ptr, raw_data(r.resources.quad_fonts), data_size)
	vma.flush_allocation(
		r.gpu.allocator,
		r.resources.font_staging_alloc,
		0,
		vk.DeviceSize(data_size),
	)
	one_time_cb := vk_one_time_cmd_buffer_begin(r.gpu.device, r.gpu.queue, r.command_pool)
	{
		region := vk.BufferCopy {
			srcOffset = 0,
			dstOffset = 0,
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
				buffer = r.resources.font_device_buffer,
				offset = 0,
				size = vk.DeviceSize(vk.WHOLE_SIZE),
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			},
		}
		vk.CmdPipelineBarrier2(one_time_cb.cmd, &dep_info)
	}
	vk_one_time_cmd_buffer_end(&one_time_cb)
	writes := [?]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = r.resources.desc_set,
			dstBinding = DESC_BINDING_FONTS,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = r.resources.font_device_buffer,
				offset = 0,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
	}
	vk.UpdateDescriptorSets(r.gpu.device, len(writes), raw_data(writes[:]), 0, nil)
	vk_assert(vk.QueueWaitIdle(r.gpu.queue))

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

	if handle.idx > len(r.resources.font_faces) - 1 {
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
	if platform_err.message != "" || platform_err.result != .SUCCESS do return renderer_error(.Platform, .Platform_Failure, platform_err.message, platform_err.result)
	if size.x < 0 || size.y < 0 || size.x > int(max(i32)) || size.y > int(max(i32)) do return renderer_error(.Platform, .Platform_Failure, "framebuffer dimensions must fit nonnegative i32")
	if size != r.framebuffer_size {r.framebuffer_size = size; r.swapchain.needs_update = true}
	if size.x == 0 || size.y == 0 do return {}
	if r.swapchain.handle != {} && !r.swapchain.needs_update do return {}
	if res := vk.DeviceWaitIdle(r.gpu.device); res != .SUCCESS do return renderer_error(.Presentation, .Vulkan_Failure, "waiting for swapchain work failed", res)
	caps: vk.SurfaceCapabilitiesKHR
	if res := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.gpu.physical, r.surface, &caps); res != .SUCCESS do return renderer_error(.Presentation, .Surface_Lost if res == .ERROR_SURFACE_LOST_KHR else .Vulkan_Failure, "surface capabilities query failed", res)
	if caps.currentExtent.width == 0 ||
	   caps.currentExtent.height == 0 {r.framebuffer_size = {}; return {}}
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
