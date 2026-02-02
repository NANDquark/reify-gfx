package reify

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "lib/vma"
import "vendor:glfw"
import vk "vendor:vulkan"

SHADER_BYTES :: #load("assets/sprite.spv")
MAX_FRAME_IN_FLIGHT :: 3
IMAGE_FORMAT := vk.Format.B8G8R8A8_SRGB
TEX_STAGING_BUFFER_SIZE :: 128 * mem.Megabyte
TEX_DESCRIPTOR_POOL_COUNT :: 1024

Renderer :: struct {
	gpu:             GPU_Context,
	surface:         vk.SurfaceKHR,
	window:          struct {
		width:      i32,
		height:     i32,
		projection: Mat4f,
	},
	swapchain:       Swapchain_Context,
	resources:       struct {
		textures:            [dynamic]Texture,
		sprites:             [dynamic]Sprite,
		index_buffer:        vk.Buffer,
		index_alloc:         vma.Allocation,
		tex_staging_buffer:  vk.Buffer,
		tex_staging_alloc:   vma.Allocation,
		tex_desc_pool:       vk.DescriptorPool,
		tex_desc_set:        vk.DescriptorSet,
		tex_desc_set_layout: vk.DescriptorSetLayout,
		tex_sampler:         vk.Sampler,
	},
	pipeline:        vk.Pipeline,
	pipeline_layout: vk.PipelineLayout,
	command_pool:    vk.CommandPool,
	shader_module:   vk.ShaderModule,
	frame_index:     int,
	frame_contexts:  [MAX_FRAME_IN_FLIGHT]Frame_Context,
}

GPU_Context :: struct {
	instance:     vk.Instance,
	physical:     vk.PhysicalDevice,
	device:       vk.Device,
	queue:        vk.Queue,
	queue_family: u32,
	allocator:    vma.Allocator,
}

Swapchain_Context :: struct {
	gpu:               ^GPU_Context,
	create_info:       vk.SwapchainCreateInfoKHR,
	handle:            vk.SwapchainKHR,
	images:            [dynamic]vk.Image,
	views:             [dynamic]vk.ImageView,
	render_semaphores: [dynamic]vk.Semaphore,
	needs_update:      bool,
}

Frame_Context :: struct {
	fence:              vk.Fence,
	present_semaphore:  vk.Semaphore,
	shader_data:        Sprite_Shader_Data,
	shader_data_buffer: Shader_Data_Buffer,
	num_sprites:        int,
	command_buffer:     vk.CommandBuffer,
}

init :: proc(r: ^Renderer, window: glfw.WindowHandle) {
	defer free_all(context.temp_allocator)

	gpu_init(&r.gpu)

	// SETUP SURFACE
	vk_assert(glfw.CreateWindowSurface(r.gpu.instance, window, nil, &r.surface))
	r.window.width, r.window.height = glfw.GetWindowSize(window)
	r.window.projection = vk_ortho_projection(
		0,
		f32(r.window.width),
		0,
		f32(r.window.height),
		-1,
		1,
	)
	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_assert(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.gpu.physical, r.surface, &surface_caps))
	swapchain_context_init(
		&r.swapchain,
		&r.gpu,
		r.surface,
		surface_caps,
		r.window.width,
		r.window.height,
	)

	// Setup Index Buffer
	index_count := SPRITE_MAX_INSTANCES * 6 // each sprite has 2 quads so 6 indices
	index_buf_size := vk.DeviceSize(index_count * size_of(u32))
	buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = index_buf_size,
		usage = {.INDEX_BUFFER},
	}
	buffer_alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}
	vk_assert(
		vma.create_buffer(
			r.gpu.allocator,
			buffer_create_info,
			buffer_alloc_create_info,
			&r.resources.index_buffer,
			&r.resources.index_alloc,
			nil,
		),
	)
	alloc_info: vma.Allocation_Info
	vma.get_allocation_info(r.gpu.allocator, r.resources.index_alloc, &alloc_info)
	indices := cast([^]u32)alloc_info.mapped_data
	for i in 0 ..< SPRITE_MAX_INSTANCES {
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

	// Init global sampler
	sampler_create_info := vk.SamplerCreateInfo {
		sType            = .SAMPLER_CREATE_INFO,
		magFilter        = .LINEAR,
		minFilter        = .LINEAR,
		mipmapMode       = .LINEAR,
		addressModeU     = .CLAMP_TO_EDGE,
		addressModeV     = .CLAMP_TO_EDGE,
		addressModeW     = .CLAMP_TO_EDGE,
		anisotropyEnable = true,
		maxAnisotropy    = 8, // widely used
		maxLod           = vk.LOD_CLAMP_NONE,
	}
	vk_assert(vk.CreateSampler(r.gpu.device, &sampler_create_info, nil, &r.resources.tex_sampler))

	// CPU & GPU Sync
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		u_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size  = size_of(Sprite_Shader_Data),
			usage = {.SHADER_DEVICE_ADDRESS},
		}
		u_buffer_alloc_create_info := vma.Allocation_Create_Info {
			flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
			usage = .Auto,
		}
		vk_assert(
			vma.create_buffer(
				r.gpu.allocator,
				u_buffer_create_info,
				u_buffer_alloc_create_info,
				&r.frame_contexts[i].shader_data_buffer.buffer,
				&r.frame_contexts[i].shader_data_buffer.alloc,
				nil,
			),
		)
		vk_assert(
			vma.map_memory(
				r.gpu.allocator,
				r.frame_contexts[i].shader_data_buffer.alloc,
				&r.frame_contexts[i].shader_data_buffer.mapped,
			),
		)
		u_buffer_bda_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = r.frame_contexts[i].shader_data_buffer.buffer,
		}
		r.frame_contexts[i].shader_data_buffer.device_addr = vk.GetBufferDeviceAddress(
			r.gpu.device,
			&u_buffer_bda_info,
		)
	}
	resize(&r.swapchain.render_semaphores, len(r.swapchain.images))
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		vk_assert(
			vk.CreateFence(r.gpu.device, &fence_create_info, nil, &r.frame_contexts[i].fence),
		)
		vk_assert(
			vk.CreateSemaphore(
				r.gpu.device,
				&semaphore_create_info,
				nil,
				&r.frame_contexts[i].present_semaphore,
			),
		)
	}
	for &s in r.swapchain.render_semaphores {
		vk_assert(vk.CreateSemaphore(r.gpu.device, &semaphore_create_info, nil, &s))
	}

	// COMMAND BUFFERS
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = r.gpu.queue_family,
	}
	vk_assert(vk.CreateCommandPool(r.gpu.device, &command_pool_create_info, nil, &r.command_pool))
	command_buffer_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = r.command_pool,
		commandBufferCount = 1,
	}
	// TODO: This is awkward because by keeping command buffer in the Frame_Context
	// we cannot allocate an array of command buffers so we do it as two separate
	// allocations
	for &fctx in r.frame_contexts {
		vk_assert(
			vk.AllocateCommandBuffers(
				r.gpu.device,
				&command_buffer_alloc_info,
				&fctx.command_buffer,
			),
		)
	}

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
	vk_assert(
		vma.create_buffer(
			r.gpu.allocator,
			tex_staging_buffer_create_info,
			tex_staging_alloc_create_info,
			&r.resources.tex_staging_buffer,
			&r.resources.tex_staging_alloc,
			nil,
		),
	)
	tex_desc_var_flags := vk.DescriptorBindingFlags{.VARIABLE_DESCRIPTOR_COUNT}
	tex_desc_binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = 1,
		pBindingFlags = &tex_desc_var_flags,
	}
	tex_desc_layout_binding := vk.DescriptorSetLayoutBinding {
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = TEX_DESCRIPTOR_POOL_COUNT,
		stageFlags      = {.FRAGMENT},
	}
	tex_desc_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &tex_desc_binding_flags,
		bindingCount = 1,
		pBindings    = &tex_desc_layout_binding,
	}
	vk_assert(
		vk.CreateDescriptorSetLayout(
			r.gpu.device,
			&tex_desc_layout_create_info,
			nil,
			&r.resources.tex_desc_set_layout,
		),
	)
	tex_pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = TEX_DESCRIPTOR_POOL_COUNT,
	}
	tex_desc_pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &tex_pool_size,
	}
	vk_assert(
		vk.CreateDescriptorPool(
			r.gpu.device,
			&tex_desc_pool_create_info,
			nil,
			&r.resources.tex_desc_pool,
		),
	)
	tex_desc_pool_count := u32(TEX_DESCRIPTOR_POOL_COUNT)
	tex_desc_set_alloc_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts  = &tex_desc_pool_count,
	}
	tex_desc_set_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &tex_desc_set_alloc_info,
		descriptorPool     = r.resources.tex_desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &r.resources.tex_desc_set_layout,
	}
	vk_assert(
		vk.AllocateDescriptorSets(r.gpu.device, &tex_desc_set_alloc, &r.resources.tex_desc_set),
	)

	vk_shader_module_init(r.gpu.device, &r.shader_module, SHADER_BYTES)
	vk_pipeline_init(
		r.gpu.device,
		Sprite_Push_Constants,
		Sprite_Instance,
		&r.resources.tex_desc_set_layout,
		r.shader_module,
		&r.pipeline_layout,
		&r.pipeline,
	)
}

// Camera is at position (x, y) with zoom z
start :: proc(r: ^Renderer, camera_position: [2]f32, camera_zoom: f32) -> ^Frame_Context {
	r.frame_index = (r.frame_index + 1) % MAX_FRAME_IN_FLIGHT
	fctx := &r.frame_contexts[r.frame_index]

	center_x, center_y := f32(r.window.width) * 0.5, f32(r.window.height) * 0.5
	view := linalg.matrix4_translate([3]f32{center_x, center_y, 0})
	view *= linalg.matrix4_scale([3]f32{camera_zoom, camera_zoom, 1})
	view *= linalg.matrix4_translate([3]f32{-camera_position.x, -camera_position.y, 0})

	fctx.shader_data.projection_view = r.window.projection * view
	fctx.num_sprites = 0

	return fctx
}

present :: proc(r: ^Renderer) {
	fctx := &r.frame_contexts[r.frame_index]

	vk_assert(vk.WaitForFences(r.gpu.device, 1, &fctx.fence, true, max(u64)))
	vk_assert(vk.ResetFences(r.gpu.device, 1, &fctx.fence))

	// Next image
	image_index: u32
	if res := vk_chk_swapchain(
		vk.AcquireNextImageKHR(
			r.gpu.device,
			r.swapchain.handle,
			max(u64),
			fctx.present_semaphore,
			0,
			&image_index,
		),
	); res == .Swapchain_Must_Update {
		r.swapchain.needs_update = true
	}

	// Store updated shader data
	mem.copy(fctx.shader_data_buffer.mapped, &fctx.shader_data, size_of(Sprite_Shader_Data))
	vma.flush_allocation(
		r.gpu.allocator,
		fctx.shader_data_buffer.alloc,
		0,
		size_of(Sprite_Shader_Data),
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
		clearValue = {color = {float32 = {0, 0, 0.2, 1}}},
	}
	// dynamic rendering
	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {extent = {width = u32(r.window.width), height = u32(r.window.height)}},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
		// pDepthAttachment = &depth_attachment_info,
	}
	vk.CmdBeginRendering(cb, &rendering_info)
	// here we swap the y-axis since vulkan y-axis point down
	vp := vk.Viewport {
		x      = 0,
		y      = f32(r.window.height),
		width  = f32(r.window.width),
		height = -f32(r.window.height),
	}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	scissor := vk.Rect2D {
		extent = {width = u32(r.window.width), height = u32(r.window.height)},
	}
	vk.CmdSetScissor(cb, 0, 1, &scissor)
	vk.CmdBindPipeline(cb, .GRAPHICS, r.pipeline)
	vk.CmdBindDescriptorSets(
		cb,
		.GRAPHICS,
		r.pipeline_layout,
		0,
		1,
		&r.resources.tex_desc_set,
		0,
		nil,
	)

	vk.CmdBindIndexBuffer(cb, r.resources.index_buffer, 0, .UINT32)
	push_constants := Sprite_Push_Constants {
		data = fctx.shader_data_buffer.device_addr,
	}
	vk.CmdPushConstants(
		cb,
		r.pipeline_layout,
		{.VERTEX, .FRAGMENT},
		0,
		size_of(Sprite_Push_Constants),
		&push_constants,
	)
	total_indices_to_draw := fctx.num_sprites * 6
	vk.CmdDrawIndexed(cb, u32(total_indices_to_draw), 1, 0, 0, 0)

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
	// present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &r.swapchain.render_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &r.swapchain.handle,
		pImageIndices      = &image_index,
	}
	if res := vk_chk_swapchain(vk.QueuePresentKHR(r.gpu.queue, &present_info));
	   res == .Swapchain_Must_Update {
		r.swapchain.needs_update = true
	}

	// window resize or something like that
	if r.swapchain.needs_update {
		vk.DeviceWaitIdle(r.gpu.device)
		surface_caps: vk.SurfaceCapabilitiesKHR
		vk_assert(
			vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.gpu.physical, r.surface, &surface_caps),
		)
		swapchain_context_init(
			&r.swapchain,
			&r.gpu,
			r.surface,
			surface_caps,
			r.window.width,
			r.window.height,
			recreate = true,
		)
	}
}

destroy :: proc(r: ^Renderer) {
	vk_assert(vk.DeviceWaitIdle(r.gpu.device))

	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		fctx := &r.frame_contexts[i]
		vk.DestroyFence(r.gpu.device, fctx.fence, nil)
		vk.DestroySemaphore(r.gpu.device, fctx.present_semaphore, nil)
		vma.unmap_memory(r.gpu.allocator, fctx.shader_data_buffer.alloc)
		vma.destroy_buffer(
			r.gpu.allocator,
			fctx.shader_data_buffer.buffer,
			fctx.shader_data_buffer.alloc,
		)
	}

	swapchain_context_destroy(&r.swapchain, r.gpu.device, r.gpu.allocator)

	vma.destroy_buffer(r.gpu.allocator, r.resources.index_buffer, r.resources.index_alloc)

	for t in r.resources.textures {
		vk.DestroyImageView(r.gpu.device, t.view, nil)
		vma.destroy_image(r.gpu.allocator, t.image, t.alloc)
		// t.sampler is shared in tex_sampler
	}
	vk.DestroySampler(r.gpu.device, r.resources.tex_sampler, nil)
	vk.DestroyDescriptorSetLayout(r.gpu.device, r.resources.tex_desc_set_layout, nil)
	vk.DestroyDescriptorPool(r.gpu.device, r.resources.tex_desc_pool, nil)
	vma.destroy_buffer(
		r.gpu.allocator,
		r.resources.tex_staging_buffer,
		r.resources.tex_staging_alloc,
	)

	vk.DestroyPipelineLayout(r.gpu.device, r.pipeline_layout, nil)
	vk.DestroyPipeline(r.gpu.device, r.pipeline, nil)
	vk.DestroyCommandPool(r.gpu.device, r.command_pool, nil)
	vk.DestroyShaderModule(r.gpu.device, r.shader_module, nil)

	vk.DestroySurfaceKHR(r.gpu.instance, r.surface, nil)

	gpu_destroy(&r.gpu)
}

Shader_Data_Buffer :: struct {
	alloc:       vma.Allocation,
	buffer:      vk.Buffer,
	device_addr: vk.DeviceAddress,
	mapped:      rawptr,
}

Mat4f :: matrix[4, 4]f32

window_resize :: proc(r: ^Renderer, width, height: i32) {
	r.window.width = width
	r.window.height = height
	r.window.projection = vk_ortho_projection(0, f32(width), 0, f32(height), -1, 1)
	r.swapchain.needs_update = true
}

swapchain_context_init :: proc(
	sc: ^Swapchain_Context,
	gpu: ^GPU_Context,
	surface: vk.SurfaceKHR,
	surface_caps: vk.SurfaceCapabilitiesKHR,
	window_width, window_height: i32,
	recreate := false,
) {
	sc.gpu = gpu

	if recreate {
		for swi in sc.views {
			vk.DestroyImageView(sc.gpu.device, swi, nil)
		}
	}

	sc.create_info = vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = surface,
		minImageCount = surface_caps.minImageCount,
		imageFormat = IMAGE_FORMAT,
		imageColorSpace = .COLORSPACE_SRGB_NONLINEAR,
		// surface extent had max int width/height since it was uninitialized
		imageExtent = vk.Extent2D{width = u32(window_width), height = u32(window_height)},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = {.IDENTITY},
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		oldSwapchain = sc.handle if recreate else {},
	}
	vk_assert(vk.CreateSwapchainKHR(sc.gpu.device, &sc.create_info, nil, &sc.handle))


	swapchain_image_count: u32
	vk_assert(vk.GetSwapchainImagesKHR(sc.gpu.device, sc.handle, &swapchain_image_count, nil))
	resize(&sc.images, swapchain_image_count)
	vk_assert(
		vk.GetSwapchainImagesKHR(
			sc.gpu.device,
			sc.handle,
			&swapchain_image_count,
			raw_data(sc.images),
		),
	)
	resize(&sc.views, int(swapchain_image_count))
	for i in 0 ..< swapchain_image_count {
		view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = sc.images[i],
			viewType = .D2,
			format = IMAGE_FORMAT,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk_assert(vk.CreateImageView(sc.gpu.device, &view_create_info, nil, &sc.views[i]))
	}

	if recreate {
		// must be destroyed after the new swapchain is created w/ the oldSwapchain passed in so the drivers can be clever and reuse internal resources to reduce the cost of a new swapchain
		vk.DestroySwapchainKHR(sc.gpu.device, sc.create_info.oldSwapchain, nil)
	}
}

swapchain_context_destroy :: proc(
	sc: ^Swapchain_Context,
	device: vk.Device,
	allocator: vma.Allocator,
) {
	for iv in sc.views {
		vk.DestroyImageView(device, iv, nil)
	}
	for s in sc.render_semaphores {
		vk.DestroySemaphore(device, s, nil)
	}
	vk.DestroySwapchainKHR(device, sc.handle, nil)
}

gpu_init :: proc(dctx: ^GPU_Context) {
	app_info := &vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		pApplicationName = "Reify",
		apiVersion = vk.API_VERSION_1_3,
	}
	instance_extensions := [dynamic]cstring{}
	append(&instance_extensions, vk.KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)
	append(&instance_extensions, ..glfw.GetRequiredInstanceExtensions())
	count: u32
	vk.EnumerateInstanceLayerProperties(&count, nil)
	layers_properties := make([]vk.LayerProperties, count, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&count, raw_data(layers_properties))
	desired_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
	enabled_layers := make([dynamic]cstring, context.temp_allocator)
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
	instance_create_info := &vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = app_info,
		enabledExtensionCount   = u32(len(instance_extensions)),
		ppEnabledExtensionNames = raw_data(instance_extensions),
		enabledLayerCount       = u32(len(enabled_layers)), // Now dynamically 0 or 1
		ppEnabledLayerNames     = raw_data(enabled_layers),
	}
	vk_assert(vk.CreateInstance(instance_create_info, nil, &dctx.instance))
	vk.load_proc_addresses(dctx.instance)

	// SELECT DEVICE
	device_count: u32
	vk_assert(vk.EnumeratePhysicalDevices(dctx.instance, &device_count, nil))
	phys_devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_assert(vk.EnumeratePhysicalDevices(dctx.instance, &device_count, raw_data(phys_devices)))
	assert(len(phys_devices) > 0, "physical device required")
	dctx.physical = vk_select_phys_device(phys_devices)

	// SETUP QUEUE
	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(dctx.physical, &queue_family_count, nil)
	queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		dctx.physical,
		&queue_family_count,
		raw_data(queue_families),
	)
	for i in 0 ..< len(queue_families) {
		if .GRAPHICS in queue_families[i].queueFlags {
			dctx.queue_family = u32(i)
			break
		}
	}
	queue_familiy_priorities: f32 = 1.0
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = dctx.queue_family,
		queueCount       = 1,
		pQueuePriorities = &queue_familiy_priorities,
	}

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
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pEnabledFeatures        = &enabled_vk10_features,
	}
	vk_assert(vk.CreateDevice(dctx.physical, &device_create_info, nil, &dctx.device))
	vk.GetDeviceQueue(dctx.device, dctx.queue_family, 0, &dctx.queue)
	vk.load_proc_addresses(dctx.device)

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
	vk_assert(vma.create_allocator(allocator_create_info, &dctx.allocator))
}

gpu_destroy :: proc(gctx: ^GPU_Context) {
	vma.destroy_allocator(gctx.allocator)
	vk.DestroyDevice(gctx.device, nil)
	vk.DestroyInstance(gctx.instance, nil)
}

draw_sprite :: proc(
	r: ^Renderer,
	sh: Sprite_Handle,
	position: [2]f32,
	rotation: f32 = 0,
	scale := [2]f32{1, 1},
	color := Color{},
) {
	fctx := &r.frame_contexts[r.frame_index]
	sprite := r.resources.sprites[sh.idx]
	pixel_scale := [2]f32{scale.x * sprite.width, scale.y * sprite.height}
	fctx.shader_data.instances[fctx.num_sprites] = Sprite_Instance {
		pos           = position,
		scale         = pixel_scale,
		rotation      = rotation,
		texture_index = u32(sprite.texture.idx),
		color         = color_to_f32(color),
		type          = {u16(Sprite_Instance_Type.Sprite), 0},
	}
	fctx.num_sprites += 1
}

draw_rect :: proc(
	r: ^Renderer,
	position: [2]f32,
	color: Color,
	width, height: f32,
	rotation: f32 = 0,
) {
	fctx := &r.frame_contexts[r.frame_index]
	// TODO load a default "unknown texture" into textures slot 0
	fctx.shader_data.instances[fctx.num_sprites] = Sprite_Instance {
		pos      = position,
		scale    = {width, height},
		rotation = rotation,
		color    = color_to_f32(color),
		type     = {u16(Sprite_Instance_Type.Rect), 0},
	}
	fctx.num_sprites += 1
}

draw_circle :: proc(r: ^Renderer, position: [2]f32, color: Color, radius: f32) {
	fctx := &r.frame_contexts[r.frame_index]
	fctx.shader_data.instances[fctx.num_sprites] = Sprite_Instance {
		pos   = position,
		scale = {radius, radius},
		color = color_to_f32(color),
		type  = {u16(Sprite_Instance_Type.Circle), 0},
	}
	fctx.num_sprites += 1
}

Texture :: struct {
	alloc:   vma.Allocation,
	image:   vk.Image,
	view:    vk.ImageView,
	sampler: vk.Sampler,
}

Texture_Handle :: struct {
	idx: int,
}

Color :: [4]u8

color_to_f32 :: proc(color: Color) -> [4]f32 {
	return [4]f32 {
		f32(color[0]) / 255.0,
		f32(color[1]) / 255.0,
		f32(color[2]) / 255.0,
		f32(color[3]) / 255.0,
	}
}

// Create a Texture and upload it to the GPU and get back a handle which can be
// used later to render with that Texture.
texture_load :: proc(r: ^Renderer, pixels: []Color, width, height: int) -> Texture_Handle {
	if len(r.resources.textures) == TEX_DESCRIPTOR_POOL_COUNT {
		panic("maximum 1024 textures reached")
	}

	tex := texture_create(r, vk.Format.R8G8B8A8_SRGB, u32(width), u32(height), 1)
	idx := len(r.resources.textures)
	append(&r.resources.textures, tex)

	// copy image to the staging buffer
	tex_staging_buffer_ptr: rawptr
	vk_assert(
		vma.map_memory(r.gpu.allocator, r.resources.tex_staging_alloc, &tex_staging_buffer_ptr),
	)
	data_size := len(pixels) * size_of(Color)
	mem.copy(tex_staging_buffer_ptr, raw_data(pixels), data_size)
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
		dstSet          = r.resources.tex_desc_set,
		dstBinding      = 0,
		dstArrayElement = u32(idx),
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &{
			sampler = tex.sampler,
			imageView = tex.view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		},
	}
	vk.UpdateDescriptorSets(r.gpu.device, 1, &write_desc_set, 0, nil)
	vk_assert(vk.QueueWaitIdle(r.gpu.queue))

	return Texture_Handle{idx = idx}
}

// Create a Texture on the CPU, but don't upload it to the GPU. Generally prefer
// directly using `texture_load` to create and load to the GPU in one shot.
@(private)
texture_create :: proc(r: ^Renderer, format: vk.Format, width, height, mipLevels: u32) -> Texture {
	tex: Texture
	tex.sampler = r.resources.tex_sampler
	tex_img_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = vk.Extent3D{width = width, height = height, depth = 1},
		mipLevels = mipLevels,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.TRANSFER_DST, .SAMPLED},
		initialLayout = .UNDEFINED,
	}
	vk_assert(
		vma.create_image(
			r.gpu.allocator,
			tex_img_create_info,
			{usage = .Auto},
			&tex.image,
			&tex.alloc,
			nil,
		),
	)
	tex_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = tex_img_create_info.format,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			levelCount = mipLevels,
			layerCount = 1,
		},
	}
	vk_assert(vk.CreateImageView(r.gpu.device, &tex_view_create_info, nil, &tex.view))
	return tex
}

Sprite :: struct {
	texture: Texture_Handle,
	width:   f32,
	height:  f32,
}

Sprite_Handle :: struct {
	idx: int,
}

sprite_create :: proc(r: ^Renderer, t: Texture_Handle, width, height: f32) -> Sprite_Handle {
	s := Sprite {
		texture = t,
		width   = width,
		height  = height,
	}
	idx := len(r.resources.sprites)
	append(&r.resources.sprites, s)
	return Sprite_Handle{idx = idx}
}
