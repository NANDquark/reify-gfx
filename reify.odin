package reify

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "lib/ktx"
import "lib/vma"
import "vendor:glfw"
import vk "vendor:vulkan"

SHADER_BYTES :: #load("assets/shader.spv")
MESH_BUFFER_SIZE :: 10 * mem.Megabyte
MAX_FRAME_IN_FLIGHT :: 3
IMAGE_FORMAT := vk.Format.B8G8R8A8_SRGB

Device_Context :: struct {
	instance:     vk.Instance,
	physical:     vk.PhysicalDevice,
	handle:       vk.Device,
	queue:        vk.Queue,
	queue_family: u32,
	allocator:    vma.Allocator,
}
device: Device_Context

surface: vk.SurfaceKHR

Swapchain_Context :: struct {
	create_info:       vk.SwapchainCreateInfoKHR,
	handle:            vk.SwapchainKHR,
	images:            [dynamic]vk.Image,
	views:             [dynamic]vk.ImageView,
	render_semaphores: [dynamic]vk.Semaphore,
	depth_create_info: vk.ImageCreateInfo,
	depth_image:       vk.Image,
	depth_view:        vk.ImageView,
	depth_alloc:       vma.Allocation,
	needs_update:      bool,
}
swapchain: Swapchain_Context

mesh_buffer: vk.Buffer
mesh_alloc: vma.Allocation
meshes: [dynamic]Mesh

TEX_STAGING_BUFFER_SIZE :: 128 * mem.Megabyte
tex_staging_buffer: vk.Buffer
tex_staging_alloc: vma.Allocation
TEX_DESCRIPTOR_POOL_COUNT :: 1024
tex_desc_pool: vk.DescriptorPool
tex_desc_set: vk.DescriptorSet
tex_desc_set_layout: vk.DescriptorSetLayout
tex_sampler: vk.Sampler
textures: [dynamic]Texture

Frame_Context :: struct {
	fence:              vk.Fence,
	present_semaphore:  vk.Semaphore,
	shader_data_buffer: Shader_Data_Buffer,
	command_buffer:     vk.CommandBuffer,
	draw_meshes:        map[Mesh_Handle][dynamic]Instance_Data,
}
frame_contexts := [MAX_FRAME_IN_FLIGHT]Frame_Context{}
frame_index := 0

pipeline: vk.Pipeline
pipeline_layout: vk.PipelineLayout
command_pool: vk.CommandPool
shader_module: vk.ShaderModule
shader_data := Shader_Data{}

window_width, window_height: c.int

init :: proc(window: glfw.WindowHandle) {
	defer free_all(context.temp_allocator)

	device_context_init(&device)

	// SETUP SURFACE
	vk_chk(glfw.CreateWindowSurface(device.instance, window, nil, &surface))
	window_width, window_height = glfw.GetWindowSize(window)
	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, surface, &surface_caps))
	swapchain_context_init(&swapchain, surface, surface_caps)

	// Setup Mesh Buffer
	buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(MESH_BUFFER_SIZE),
		usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
	}
	buffer_alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}
	vk_chk(
		vma.create_buffer(
			device.allocator,
			buffer_create_info,
			buffer_alloc_create_info,
			&mesh_buffer,
			&mesh_alloc,
			nil,
		),
	)

	// Setup texture staging buffer
	tex_staging_buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(TEX_STAGING_BUFFER_SIZE),
		usage = {.TRANSFER_SRC},
	}
	tex_staging_alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Host_Access_Sequential_Write, .Mapped},
		usage = .Auto,
	}
	vk_chk(
		vma.create_buffer(
			device.allocator,
			tex_staging_buffer_create_info,
			tex_staging_alloc_create_info,
			&tex_staging_buffer,
			&tex_staging_alloc,
			nil,
		),
	)

	// Init global sampler
	sampler_create_info := vk.SamplerCreateInfo {
		sType            = .SAMPLER_CREATE_INFO,
		magFilter        = .LINEAR,
		minFilter        = .LINEAR,
		mipmapMode       = .LINEAR,
		anisotropyEnable = true,
		maxAnisotropy    = 8, // widely used
		maxLod           = vk.LOD_CLAMP_NONE,
	}
	vk_chk(vk.CreateSampler(device.handle, &sampler_create_info, nil, &tex_sampler))

	// CPU & GPU Sync
	// TODO: separate this somewhere with some abstraction around creating a uniform
	// buffer then later referencing and using it from `frame` via some kind of handle
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		u_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size  = size_of(Shader_Data),
			usage = {.SHADER_DEVICE_ADDRESS},
		}
		u_buffer_alloc_create_info := vma.Allocation_Create_Info {
			flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
			usage = .Auto,
		}
		vk_chk(
			vma.create_buffer(
				device.allocator,
				u_buffer_create_info,
				u_buffer_alloc_create_info,
				&frame_contexts[i].shader_data_buffer.buffer,
				&frame_contexts[i].shader_data_buffer.alloc,
				nil,
			),
		)
		vk_chk(
			vma.map_memory(
				device.allocator,
				frame_contexts[i].shader_data_buffer.alloc,
				&frame_contexts[i].shader_data_buffer.mapped,
			),
		)
		u_buffer_bda_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = frame_contexts[i].shader_data_buffer.buffer,
		}
		frame_contexts[i].shader_data_buffer.device_addr = vk.GetBufferDeviceAddress(
			device.handle,
			&u_buffer_bda_info,
		)
	}
	resize(&swapchain.render_semaphores, len(swapchain.images))
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		vk_chk(vk.CreateFence(device.handle, &fence_create_info, nil, &frame_contexts[i].fence))
		vk_chk(
			vk.CreateSemaphore(
				device.handle,
				&semaphore_create_info,
				nil,
				&frame_contexts[i].present_semaphore,
			),
		)
	}
	for &s in swapchain.render_semaphores {
		vk_chk(vk.CreateSemaphore(device.handle, &semaphore_create_info, nil, &s))
	}

	// COMMAND BUFFERS
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = device.queue_family,
	}
	vk_chk(vk.CreateCommandPool(device.handle, &command_pool_create_info, nil, &command_pool))
	command_buffer_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		commandBufferCount = 1,
	}
	// TODO: This is awkward because by keeping command buffer in the Frame_Context
	// we cannot allocator an array of command buffers so we do it as two separate
	// allocations
	for &fctx in frame_contexts {
		vk_chk(
			vk.AllocateCommandBuffers(
				device.handle,
				&command_buffer_alloc_info,
				&fctx.command_buffer,
			),
		)
	}

	// Textures globals
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
	vk_chk(
		vk.CreateDescriptorSetLayout(
			device.handle,
			&tex_desc_layout_create_info,
			nil,
			&tex_desc_set_layout,
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
	vk_chk(vk.CreateDescriptorPool(device.handle, &tex_desc_pool_create_info, nil, &tex_desc_pool))
	tex_desc_pool_count := u32(TEX_DESCRIPTOR_POOL_COUNT)
	tex_desc_set_alloc_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts  = &tex_desc_pool_count,
	}
	tex_desc_set_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &tex_desc_set_alloc_info,
		descriptorPool     = tex_desc_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &tex_desc_set_layout,
	}
	vk_chk(vk.AllocateDescriptorSets(device.handle, &tex_desc_set_alloc, &tex_desc_set))

	// LOADING SHADERS
	// TODO: extract loading a shader and creating a pipeline into its own thing
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(SHADER_BYTES),
		pCode    = cast(^u32)raw_data(SHADER_BYTES),
	}
	vk_chk(vk.CreateShaderModule(device.handle, &shader_module_create_info, nil, &shader_module))

	// GRAPHICS PIPELINE
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(Push_Constants),
	}
	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &tex_desc_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	vk_chk(
		vk.CreatePipelineLayout(
			device.handle,
			&pipeline_layout_create_info,
			nil,
			&pipeline_layout,
		),
	)
	vertex_binding := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(Vertex),
		inputRate = .VERTEX,
	}
	vertex_attributes := []vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT},
		{location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv))},
	}
	vertex_input_state := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &vertex_binding,
		vertexAttributeDescriptionCount = u32(len(vertex_attributes)),
		pVertexAttributeDescriptions    = raw_data(vertex_attributes),
	}
	input_assembly_state := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	shader_stages := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = shader_module,
			pName = "vertMain",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader_module,
			pName = "fragMain",
		},
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}
	depth_stencil_state := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS_OR_EQUAL,
	}
	rendering_create_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &IMAGE_FORMAT,
		depthAttachmentFormat   = swapchain.depth_create_info.format,
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blend_state := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}
	rasterization_state := vk.PipelineRasterizationStateCreateInfo {
		sType     = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		lineWidth = 1,
	}
	multisample_state := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_create_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_state,
		pInputAssemblyState = &input_assembly_state,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterization_state,
		pMultisampleState   = &multisample_state,
		pDepthStencilState  = &depth_stencil_state,
		pColorBlendState    = &color_blend_state,
		pDynamicState       = &dynamic_state,
		layout              = pipeline_layout,
	}
	vk_chk(vk.CreateGraphicsPipelines(device.handle, 0, 1, &pipeline_create_info, nil, &pipeline))
}

start :: proc(projection: Mat4f, view: Mat4f) -> ^Frame_Context {
	frame_index = (frame_index + 1) % MAX_FRAME_IN_FLIGHT

	fctx := &frame_contexts[frame_index]
	for mh, &instances in fctx.draw_meshes {
		clear(&instances)
	}

	shader_data.projection = projection
	shader_data.view = view

	return fctx
}

present :: proc(fctx: ^Frame_Context) {
	vk_chk(vk.WaitForFences(device.handle, 1, &fctx.fence, true, max(u64)))
	vk_chk(vk.ResetFences(device.handle, 1, &fctx.fence))
	// Next image
	image_index: u32
	vk_chk_swapchain(
		vk.AcquireNextImageKHR(
			device.handle,
			swapchain.handle,
			max(u64),
			fctx.present_semaphore,
			0,
			&image_index,
		),
	)

	// Store updated shader data
	instance_offset := 0
	for mh, mesh_instances in fctx.draw_meshes {
		// copy all the meshes of a specific type as a contiguous block so we
		// can draw indexed
		for instance, i in mesh_instances {
			shader_data.instances[instance_offset + i] = instance
		}
	}
	mem.copy(fctx.shader_data_buffer.mapped, &shader_data, size_of(Shader_Data))
	vma.flush_allocation(device.allocator, fctx.shader_data_buffer.alloc, 0, size_of(Shader_Data))

	// Record command buffer
	cb := fctx.command_buffer
	vk_chk(vk.ResetCommandBuffer(cb, {}))
	cb_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_chk(vk.BeginCommandBuffer(cb, &cb_begin_info))
	output_barriers := []vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = swapchain.images[image_index],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .ATTACHMENT_OPTIMAL,
			image = swapchain.depth_image,
			subresourceRange = {aspectMask = {.DEPTH, .STENCIL}, levelCount = 1, layerCount = 1},
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
		imageView = swapchain.views[image_index],
		imageLayout = .ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = {color = {float32 = {0, 0, 0.2, 1}}},
	}
	depth_attachment_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = swapchain.depth_view,
		imageLayout = .ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 1, stencil = 0}},
	}
	// dynamic rendering
	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {extent = {width = u32(window_width), height = u32(window_height)}},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment_info,
		pDepthAttachment = &depth_attachment_info,
	}
	vk.CmdBeginRendering(cb, &rendering_info)
	// here we swap the y-axis since vulkan y-axis point down
	vp := vk.Viewport {
		x        = 0,
		y        = f32(window_height),
		width    = f32(window_width),
		height   = -f32(window_height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cb, 0, 1, &vp)
	scissor := vk.Rect2D {
		extent = {width = u32(window_width), height = u32(window_height)},
	}
	vk.CmdSetScissor(cb, 0, 1, &scissor)
	vk.CmdBindPipeline(cb, .GRAPHICS, pipeline)
	vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline_layout, 0, 1, &tex_desc_set, 0, nil)

	next_instance_index := 0
	for mh, mesh_instances in fctx.draw_meshes {
		first_instance_index := next_instance_index
		next_instance_index += len(mesh_instances)
		m := meshes[mh.idx]

		vk.CmdBindVertexBuffers(cb, 0, 1, &mesh_buffer, &m.vertex_offset)
		vk.CmdBindIndexBuffer(cb, mesh_buffer, m.index_offset, .UINT16)
		sd := &shader_data
		push_constants := Push_Constants {
			shader_data = fctx.shader_data_buffer.device_addr,
		}
		vk.CmdPushConstants(
			cb,
			pipeline_layout,
			{.VERTEX, .FRAGMENT},
			0,
			size_of(Push_Constants),
			&push_constants,
		)
		vk.CmdDrawIndexed(
			cb,
			u32(m.index_count),
			u32(len(mesh_instances)),
			0,
			0,
			u32(first_instance_index),
		)
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
		image = swapchain.images[image_index],
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
		pSignalSemaphores    = &swapchain.render_semaphores[image_index],
	}
	vk_chk(vk.QueueSubmit(device.queue, 1, &submit_info, fctx.fence))
	// present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain.render_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.handle,
		pImageIndices      = &image_index,
	}
	vk_chk_swapchain(vk.QueuePresentKHR(device.queue, &present_info))

	// window resize or something like that
	if swapchain.needs_update {
		vk.DeviceWaitIdle(device.handle)
		surface_caps: vk.SurfaceCapabilitiesKHR
		vk_chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, surface, &surface_caps))
		swapchain_context_init(&swapchain, surface, surface_caps, recreate = true)
	}
}

cleanup :: proc() {
	vk_chk(vk.DeviceWaitIdle(device.handle))

	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		fctx := frame_contexts[i]
		vk.DestroyFence(device.handle, fctx.fence, nil)
		vk.DestroySemaphore(device.handle, fctx.present_semaphore, nil)
		vma.unmap_memory(device.allocator, fctx.shader_data_buffer.alloc)
		vma.destroy_buffer(
			device.allocator,
			fctx.shader_data_buffer.buffer,
			fctx.shader_data_buffer.alloc,
		)
	}

	swapchain_context_destroy(&swapchain)

	vma.destroy_buffer(device.allocator, mesh_buffer, mesh_alloc)

	for t in textures {
		vk.DestroyImageView(device.handle, t.view, nil)
		vma.destroy_image(device.allocator, t.image, t.alloc)
		// t.sampler is shared in tex_sampler
	}
	vk.DestroySampler(device.handle, tex_sampler, nil)
	vk.DestroyDescriptorSetLayout(device.handle, tex_desc_set_layout, nil)
	vk.DestroyDescriptorPool(device.handle, tex_desc_pool, nil)
	vma.destroy_buffer(device.allocator, tex_staging_buffer, tex_staging_alloc)

	vk.DestroyPipelineLayout(device.handle, pipeline_layout, nil)
	vk.DestroyPipeline(device.handle, pipeline, nil)
	vk.DestroyCommandPool(device.handle, command_pool, nil)
	vk.DestroyShaderModule(device.handle, shader_module, nil)

	vk.DestroySurfaceKHR(device.instance, surface, nil)

	context_destroy(&device)
}

Shader_Data_Buffer :: struct {
	alloc:       vma.Allocation,
	buffer:      vk.Buffer,
	device_addr: vk.DeviceAddress,
	mapped:      rawptr,
}

Mat4f :: matrix[4, 4]f32

MAX_INSTANCES :: 3

window_resize :: proc(width, height: i32) {
	window_width = width
	window_height = height
	swapchain.needs_update = true
}

swapchain_context_init :: proc(
	sc: ^Swapchain_Context,
	surface: vk.SurfaceKHR,
	surface_caps: vk.SurfaceCapabilitiesKHR,
	recreate := false,
) {
	if recreate {
		for swi in sc.views {
			vk.DestroyImageView(device.handle, swi, nil)
		}
		vma.destroy_image(device.allocator, sc.depth_image, sc.depth_alloc)
		vk.DestroyImageView(device.handle, sc.depth_view, nil)
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
	vk_chk(vk.CreateSwapchainKHR(device.handle, &sc.create_info, nil, &sc.handle))


	swapchain_image_count: u32
	vk_chk(vk.GetSwapchainImagesKHR(device.handle, sc.handle, &swapchain_image_count, nil))
	resize(&sc.images, swapchain_image_count)
	vk_chk(
		vk.GetSwapchainImagesKHR(
			device.handle,
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
		vk_chk(vk.CreateImageView(device.handle, &view_create_info, nil, &sc.views[i]))
	}

	if recreate {
		// must be destroyed after the new swapchain is created w/ the oldSwapchain passed in so the drivers can be clever and reuse internal resources to reduce the cost of a new swapchain
		vk.DestroySwapchainKHR(device.handle, sc.create_info.oldSwapchain, nil)
	}

	depth_format_list := [2]vk.Format{.D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}
	for format in depth_format_list {
		format_properties := vk.FormatProperties2 {
			sType = .FORMAT_PROPERTIES_2,
		}
		vk.GetPhysicalDeviceFormatProperties2(device.physical, format, &format_properties)
		if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
			sc.depth_create_info.format = format
			break
		}
	}
	sc.depth_create_info = vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = sc.depth_create_info.format,
		extent = vk.Extent3D{width = u32(window_width), height = u32(window_height), depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
		initialLayout = .UNDEFINED,
	}
	alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Dedicated_Memory},
		usage = .Auto,
	}
	vk_chk(
		vma.create_image(
			device.allocator,
			sc.depth_create_info,
			alloc_create_info,
			&sc.depth_image,
			&sc.depth_alloc,
			nil,
		),
	)
	depth_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = sc.depth_image,
		viewType = .D2,
		format = sc.depth_create_info.format,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.DEPTH},
			levelCount = 1,
			layerCount = 1,
		},
	}
	vk_chk(vk.CreateImageView(device.handle, &depth_view_create_info, nil, &sc.depth_view))
}

swapchain_context_destroy :: proc(sc: ^Swapchain_Context) {
	vma.destroy_image(device.allocator, sc.depth_image, sc.depth_alloc)
	vk.DestroyImageView(device.handle, sc.depth_view, nil)
	for iv in sc.views {
		vk.DestroyImageView(device.handle, iv, nil)
	}
	for s in sc.render_semaphores {
		vk.DestroySemaphore(device.handle, s, nil)
	}
	vk.DestroySwapchainKHR(device.handle, sc.handle, nil)
}

device_context_init :: proc(dctx: ^Device_Context) {
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
	vk_chk(vk.CreateInstance(instance_create_info, nil, &dctx.instance))
	vk.load_proc_addresses(dctx.instance)

	// SELECT DEVICE
	device_count: u32
	vk_chk(vk.EnumeratePhysicalDevices(dctx.instance, &device_count, nil))
	phys_devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_chk(vk.EnumeratePhysicalDevices(dctx.instance, &device_count, raw_data(phys_devices)))
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
	enabled_vk12_features := vk.PhysicalDeviceVulkan12Features {
		sType                                    = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		descriptorIndexing                       = true,
		descriptorBindingVariableDescriptorCount = true,
		runtimeDescriptorArray                   = true,
		bufferDeviceAddress                      = true,
	}
	enabled_vk13_featues := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &enabled_vk12_features,
		synchronization2 = true,
		dynamicRendering = true,
	}
	enabled_vk10_features := vk.PhysicalDeviceFeatures {
		samplerAnisotropy = true,
	}
	device_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &enabled_vk13_featues,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pEnabledFeatures        = &enabled_vk10_features,
	}
	vk_chk(vk.CreateDevice(dctx.physical, &device_create_info, nil, &dctx.handle))
	vk.GetDeviceQueue(dctx.handle, dctx.queue_family, 0, &dctx.queue)
	vk.load_proc_addresses(dctx.handle)

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
		device           = dctx.handle,
		vulkan_functions = &vk_functions,
		instance         = dctx.instance,
	}
	vk_chk(vma.create_allocator(allocator_create_info, &dctx.allocator))
}

context_destroy :: proc(gctx: ^Device_Context) {
	vma.destroy_allocator(gctx.allocator)
	vk.DestroyDevice(gctx.handle, nil)
	vk.DestroyInstance(gctx.instance, nil)
}

Mesh :: struct {
	vertex_offset: vk.DeviceSize, // location within the global buffer
	index_offset:  vk.DeviceSize, // location within the global buffer
	index_count:   int,
}

Mesh_Handle :: struct {
	idx: int,
}

mesh_load :: proc(vertices: []Vertex, indices: []u16) -> Mesh_Handle {
	@(static) buffer_offset: uintptr = 0
	MESH_ALIGNMENT :: 16

	v_bytes := len(vertices) * size_of(Vertex)
	i_bytes := len(indices) * size_of(u16)
	v_offset := mem.align_forward_uintptr(buffer_offset, MESH_ALIGNMENT)
	i_offset := mem.align_forward_uintptr(v_offset + uintptr(v_bytes), MESH_ALIGNMENT)
	end_offset := i_offset + uintptr(i_bytes)

	if end_offset > MESH_BUFFER_SIZE {
		panic("mesh_buffer is too full")
	}

	base_ptr: rawptr
	vk_chk(vma.map_memory(device.allocator, mesh_alloc, &base_ptr))

	// copy vertices
	v_write_ptr := rawptr(uintptr(base_ptr) + v_offset)
	mem.copy(v_write_ptr, raw_data(vertices), v_bytes)

	// copy indices
	i_write_ptr := rawptr(uintptr(base_ptr) + uintptr(i_offset))
	mem.copy(i_write_ptr, raw_data(indices), i_bytes)

	// cleanup
	vma.flush_allocation(
		device.allocator,
		mesh_alloc,
		vk.DeviceSize(v_offset),
		vk.DeviceSize(end_offset - v_offset),
	)
	vma.unmap_memory(device.allocator, mesh_alloc)
	buffer_offset = end_offset

	handle := Mesh_Handle {
		idx = len(meshes),
	}
	m := Mesh {
		index_count   = len(indices),
		vertex_offset = vk.DeviceSize(v_offset),
		index_offset  = vk.DeviceSize(i_offset),
	}
	append(&meshes, m)
	return handle
}

draw_mesh :: proc(fctx: ^Frame_Context, m: Mesh_Handle, t: Texture_Handle, transform: Mat4f) {
	// TODO: logging or something when MAX_INSTANCES is reached
	if len(meshes) <= m.idx do return
	if len(fctx.draw_meshes) >= MAX_INSTANCES do return

	mesh_instances, ok := &fctx.draw_meshes[m]
	if !ok {
		fctx.draw_meshes[m] = [dynamic]Instance_Data{}
		mesh_instances = &fctx.draw_meshes[m]
	}
	append(mesh_instances, Instance_Data{model = transform, texture_index = u32(t.idx)})
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

texture_load :: proc(pixels: []Color, width, height: int) -> Texture_Handle {
	if len(textures) == TEX_DESCRIPTOR_POOL_COUNT {
		panic("maximum 1024 textures reached")
	}

	tex := texture_create(vk.Format.R8G8B8A8_SRGB, u32(width), u32(height), 1)
	idx := len(textures)
	append(&textures, tex)

	// copy image to the staging buffer
	tex_staging_buffer_ptr: rawptr
	a := tex_staging_alloc
	vk_chk(vma.map_memory(device.allocator, tex_staging_alloc, &tex_staging_buffer_ptr))
	data_size := len(pixels) * size_of(Color)
	mem.copy(tex_staging_buffer_ptr, raw_data(pixels), data_size)
	vma.flush_allocation(device.allocator, tex_staging_alloc, 0, vk.DeviceSize(data_size))

	one_time_cb := vk_one_time_cmd_buffer_begin()
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
			tex_staging_buffer,
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

	// Append the texture descriptor to the descriptor set and upload that
	// to the GPU so it's available to the shaders
	write_desc_set := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = tex_desc_set,
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
	vk.UpdateDescriptorSets(device.handle, 1, &write_desc_set, 0, nil)
	vk_chk(vk.QueueWaitIdle(device.queue))

	return Texture_Handle{idx = idx}
}

@(private)
texture_create :: proc(format: vk.Format, width, height, mipLevels: u32) -> Texture {
	tex: Texture
	tex.sampler = tex_sampler
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
	vk_chk(
		vma.create_image(
			device.allocator,
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
	vk_chk(vk.CreateImageView(device.handle, &tex_view_create_info, nil, &tex.view))
	return tex
}
