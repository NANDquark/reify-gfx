package reify

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "lib/ktx"
import "lib/vma"
import "vendor:glfw"
import vk "vendor:vulkan"


SHADER_BYTES :: #load("assets/shader.spv")
MESH_BUFFER_SIZE :: 10 * mem.Megabyte
MAX_FRAME_IN_FLIGHT :: 2
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
	depth_create_info: vk.ImageCreateInfo,
	depth_image:       vk.Image,
	depth_view:        vk.ImageView,
	depth_alloc:       vma.Allocation,
	needs_update:      bool,
}
swapchain: Swapchain_Context

meshes: [dynamic]Mesh

fences := [MAX_FRAME_IN_FLIGHT]vk.Fence{}
present_semaphores := [MAX_FRAME_IN_FLIGHT]vk.Semaphore{}
render_semaphores := [dynamic]vk.Semaphore{}
shader_data_buffers := [MAX_FRAME_IN_FLIGHT]Shader_Data_Buffer{}
command_buffers := [MAX_FRAME_IN_FLIGHT]vk.CommandBuffer{}
pipeline: vk.Pipeline
pipeline_layout: vk.PipelineLayout
descriptor_set_tex: vk.DescriptorSet
mesh_buffer: vk.Buffer
mesh_buffer_alloc: vma.Allocation
textures := [3]Texture{}
texture_descriptors := [dynamic]vk.DescriptorImageInfo{}
desc_set_layout_tex: vk.DescriptorSetLayout
descriptor_pool: vk.DescriptorPool
command_pool: vk.CommandPool
shader_module: vk.ShaderModule

frame_index := 0
window_width, window_height: c.int

init :: proc(window: glfw.WindowHandle) {
	defer free_all(context.temp_allocator)

	device_context_init(&device)

	// SETUP SURFACE
	chk(glfw.CreateWindowSurface(device.instance, window, nil, &surface))
	window_width, window_height = glfw.GetWindowSize(window)
	surface_caps: vk.SurfaceCapabilitiesKHR
	chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, surface, &surface_caps))
	swapchain_context_init(&swapchain, surface, surface_caps)

	// Setup Mesh Buffer
	// TODO: This mess must be moved out to the demo code size and an API developed
	// to pass vertices in and update the buffers

	buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(MESH_BUFFER_SIZE),
		usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
	}
	buffer_alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}
	chk(
		vma.create_buffer(
			device.allocator,
			buffer_create_info,
			buffer_alloc_create_info,
			&mesh_buffer,
			&mesh_buffer_alloc,
			nil,
		),
	)

	// CPU & GPU Sync
	// TODO separate this somewhere with some abstraction around creating a uniform
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
		chk(
			vma.create_buffer(
				device.allocator,
				u_buffer_create_info,
				u_buffer_alloc_create_info,
				&shader_data_buffers[i].buffer,
				&shader_data_buffers[i].alloc,
				nil,
			),
		)
		chk(
			vma.map_memory(
				device.allocator,
				shader_data_buffers[i].alloc,
				&shader_data_buffers[i].mapped,
			),
		)
		u_buffer_bda_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = shader_data_buffers[i].buffer,
		}
		shader_data_buffers[i].device_addr = vk.GetBufferDeviceAddress(
			device.handle,
			&u_buffer_bda_info,
		)
	}
	resize(&render_semaphores, len(swapchain.images))
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		chk(vk.CreateFence(device.handle, &fence_create_info, nil, &fences[i]))
		chk(vk.CreateSemaphore(device.handle, &semaphore_create_info, nil, &present_semaphores[i]))
	}
	for &s in render_semaphores {
		chk(vk.CreateSemaphore(device.handle, &semaphore_create_info, nil, &s))
	}

	// COMMAND BUFFERS
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = device.queue_family,
	}
	chk(vk.CreateCommandPool(device.handle, &command_pool_create_info, nil, &command_pool))
	command_buffer_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		commandBufferCount = MAX_FRAME_IN_FLIGHT,
	}
	chk(
		vk.AllocateCommandBuffers(
			device.handle,
			&command_buffer_alloc_info,
			raw_data(command_buffers[:]),
		),
	)

	// LOADING TEXTURES
	// TODO: Extract loading textures into it's own function and return a texture
	// handle to demo with the image loadig stuff moved there too
	for t, i in textures {
		ktx_texture: ^ktx.Texture
		filename := fmt.tprintf("assets/suzanne%d.ktx", i)
		cfilename := strings.clone_to_cstring(filename, context.temp_allocator)
		err := ktx.Texture_CreateFromNamedFile(
			cfilename,
			{.TEXTURE_CREATE_LOAD_IMAGE_DATA},
			&ktx_texture,
		)
		if err != .SUCCESS {
			panic(fmt.tprintf("failed to load ktx image '%s', err=%v", filename, err))
		}
		defer ktx.Texture_Destroy(ktx_texture)
		tex_img_create_info := vk.ImageCreateInfo {
			sType = .IMAGE_CREATE_INFO,
			imageType = .D2,
			format = ktx.Texture_GetVkFormat(ktx_texture),
			extent = vk.Extent3D {
				width = ktx_texture.baseWidth,
				height = ktx_texture.baseHeight,
				depth = 1,
			},
			mipLevels = ktx_texture.numLevels,
			arrayLayers = 1,
			samples = {._1},
			tiling = .OPTIMAL,
			usage = {.TRANSFER_DST, .SAMPLED},
			initialLayout = .UNDEFINED,
		}
		tex_image_alloc_create_info := vma.Allocation_Create_Info {
			usage = .Auto,
		}
		chk(
			vma.create_image(
				device.allocator,
				tex_img_create_info,
				tex_image_alloc_create_info,
				&textures[i].image,
				&textures[i].alloc,
				nil,
			),
		)
		tex_view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = textures[i].image,
			viewType = .D2,
			format = tex_img_create_info.format,
			subresourceRange = vk.ImageSubresourceRange {
				aspectMask = {.COLOR},
				levelCount = ktx_texture.numLevels,
				layerCount = 1,
			},
		}
		chk(vk.CreateImageView(device.handle, &tex_view_create_info, nil, &textures[i].view))
		img_src_buffer: vk.Buffer
		img_src_alloc: vma.Allocation
		img_src_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size  = vk.DeviceSize(ktx_texture.dataSize),
			usage = {.TRANSFER_SRC},
		}
		img_src_alloc_create_info := vma.Allocation_Create_Info {
			flags = {.Host_Access_Sequential_Write, .Mapped},
			usage = .Auto,
		}
		chk(
			vma.create_buffer(
				device.allocator,
				img_src_buffer_create_info,
				img_src_alloc_create_info,
				&img_src_buffer,
				&img_src_alloc,
				nil,
			),
		)
		img_src_buffer_ptr: rawptr
		chk(vma.map_memory(device.allocator, img_src_alloc, &img_src_buffer_ptr))
		mem.copy(img_src_buffer_ptr, ktx_texture.pData, int(ktx_texture.dataSize))
		fence_one_time_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
		}
		fence_one_time: vk.Fence
		chk(vk.CreateFence(device.handle, &fence_one_time_create_info, nil, &fence_one_time))
		cb_one_time: vk.CommandBuffer
		cb_one_time_alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = command_pool,
			commandBufferCount = 1,
		}
		chk(vk.AllocateCommandBuffers(device.handle, &cb_one_time_alloc_info, &cb_one_time))
		cb_one_time_buf_begin_info := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		chk(vk.BeginCommandBuffer(cb_one_time, &cb_one_time_buf_begin_info))
		barrier_tex_img := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {},
			srcAccessMask = {},
			dstStageMask = {.TRANSFER},
			dstAccessMask = {.TRANSFER_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .TRANSFER_DST_OPTIMAL,
			image = textures[i].image,
			subresourceRange = vk.ImageSubresourceRange {
				aspectMask = {.COLOR},
				levelCount = ktx_texture.numLevels,
				layerCount = 1,
			},
		}
		barrier_tex_info := vk.DependencyInfo {
			sType                   = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers    = &barrier_tex_img,
		}
		vk.CmdPipelineBarrier2(cb_one_time, &barrier_tex_info)
		copy_regions := [dynamic]vk.BufferImageCopy{}
		defer delete(copy_regions)
		for j in 0 ..< ktx_texture.numLevels {
			mip_offset: c.size_t = 0
			ret := ktx.Texture_GetImageOffset(ktx_texture, j, 0, 0, &mip_offset)
			append(
				&copy_regions,
				vk.BufferImageCopy {
					bufferOffset = vk.DeviceSize(mip_offset),
					imageSubresource = vk.ImageSubresourceLayers {
						aspectMask = {.COLOR},
						mipLevel = u32(j),
						layerCount = 1,
					},
					imageExtent = vk.Extent3D {
						width = ktx_texture.baseWidth >> j,
						height = ktx_texture.baseHeight >> j,
						depth = 1,
					},
				},
			)
		}
		vk.CmdCopyBufferToImage(
			cb_one_time,
			img_src_buffer,
			textures[i].image,
			.TRANSFER_DST_OPTIMAL,
			u32(len(copy_regions)),
			raw_data(copy_regions),
		)
		barrier_tex_read := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.TRANSFER},
			srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = {.FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
			oldLayout = .TRANSFER_DST_OPTIMAL,
			newLayout = .READ_ONLY_OPTIMAL,
			image = textures[i].image,
			subresourceRange = vk.ImageSubresourceRange {
				aspectMask = {.COLOR},
				levelCount = ktx_texture.numLevels,
				layerCount = 1,
			},
		}
		barrier_tex_info.pImageMemoryBarriers = &barrier_tex_read
		vk.CmdPipelineBarrier2(cb_one_time, &barrier_tex_info)
		chk(vk.EndCommandBuffer(cb_one_time))

		one_time_submit_info := vk.SubmitInfo {
			sType              = .SUBMIT_INFO,
			commandBufferCount = 1,
			pCommandBuffers    = &cb_one_time,
		}
		chk(vk.QueueSubmit(device.queue, 1, &one_time_submit_info, fence_one_time))
		chk(vk.WaitForFences(device.handle, 1, &fence_one_time, true, max(u64)))
		vk.DestroyFence(device.handle, fence_one_time, nil)
		vma.unmap_memory(device.allocator, img_src_alloc)
		vk.FreeCommandBuffers(device.handle, command_pool, 1, &cb_one_time)
		vma.destroy_buffer(device.allocator, img_src_buffer, img_src_alloc)
		// sampler
		sampler_create_info := vk.SamplerCreateInfo {
			sType            = .SAMPLER_CREATE_INFO,
			magFilter        = .LINEAR,
			minFilter        = .LINEAR,
			mipmapMode       = .LINEAR,
			anisotropyEnable = true,
			maxAnisotropy    = 8, // widely used
			maxLod           = f32(ktx_texture.numLevels),
		}
		chk(vk.CreateSampler(device.handle, &sampler_create_info, nil, &textures[i].sampler))
		append(
			&texture_descriptors,
			vk.DescriptorImageInfo {
				sampler = textures[i].sampler,
				imageView = textures[i].view,
				imageLayout = .READ_ONLY_OPTIMAL,
			},
		)
	}
	desc_var_flags := vk.DescriptorBindingFlags{.VARIABLE_DESCRIPTOR_COUNT}
	desc_binding_flags := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = 1,
		pBindingFlags = &desc_var_flags,
	}
	desc_layout_binding_tex := vk.DescriptorSetLayoutBinding {
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = u32(len(textures)),
		stageFlags      = {.FRAGMENT},
	}
	desc_layout_tex_create_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &desc_binding_flags,
		bindingCount = 1,
		pBindings    = &desc_layout_binding_tex,
	}
	chk(
		vk.CreateDescriptorSetLayout(
			device.handle,
			&desc_layout_tex_create_info,
			nil,
			&desc_set_layout_tex,
		),
	)
	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = u32(len(textures)),
	}
	desc_pool_create_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	chk(vk.CreateDescriptorPool(device.handle, &desc_pool_create_info, nil, &descriptor_pool))
	var_desc_count := u32(len(textures))
	var_desc_count_alloc_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts  = &var_desc_count,
	}
	tex_desc_set_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &var_desc_count_alloc_info,
		descriptorPool     = descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &desc_set_layout_tex,
	}
	chk(vk.AllocateDescriptorSets(device.handle, &tex_desc_set_alloc, &descriptor_set_tex))
	write_desc_set := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = descriptor_set_tex,
		dstBinding      = 0,
		descriptorCount = u32(len(texture_descriptors)),
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = raw_data(texture_descriptors),
	}
	vk.UpdateDescriptorSets(device.handle, 1, &write_desc_set, 0, nil)

	// LOADING SHADERS
	// TODO: extract loading a shader and creating a pipeline into its own thing
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(SHADER_BYTES),
		pCode    = cast(^u32)raw_data(SHADER_BYTES),
	}
	chk(vk.CreateShaderModule(device.handle, &shader_module_create_info, nil, &shader_module))

	// GRAPHICS PIPELINE
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		size       = size_of(vk.DeviceAddress),
	}
	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &desc_set_layout_tex,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	chk(
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
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, normal)),
		},
		{location = 2, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, uv))},
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
	chk(vk.CreateGraphicsPipelines(device.handle, 0, 1, &pipeline_create_info, nil, &pipeline))
}

draw :: proc(shader_data: ^Shader_Data) {
	chk(vk.WaitForFences(device.handle, 1, &fences[frame_index], true, max(u64)))
	chk(vk.ResetFences(device.handle, 1, &fences[frame_index]))
	// Next image
	image_index: u32
	chk_swapchain(
		vk.AcquireNextImageKHR(
			device.handle,
			swapchain.handle,
			max(u64),
			present_semaphores[frame_index],
			0,
			&image_index,
		),
	)

	// Store updated shader data
	mem.copy(shader_data_buffers[frame_index].mapped, shader_data, size_of(Shader_Data))

	// Record command buffer
	cb := command_buffers[frame_index]
	chk(vk.ResetCommandBuffer(cb, {}))
	cb_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	chk(vk.BeginCommandBuffer(cb, &cb_begin_info))
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
	vk.CmdBindDescriptorSets(cb, .GRAPHICS, pipeline_layout, 0, 1, &descriptor_set_tex, 0, nil)
	{
		m := meshes[0]
		vk.CmdBindVertexBuffers(cb, 0, 1, &mesh_buffer, &m.vertex_offset)
		vk.CmdBindIndexBuffer(cb, mesh_buffer, m.index_offset, .UINT32)
		vk.CmdPushConstants(
			cb,
			pipeline_layout,
			{.VERTEX},
			0,
			size_of(vk.DeviceAddress),
			&shader_data_buffers[frame_index].device_addr,
		)
		vk.CmdDrawIndexed(cb, u32(m.index_count), 3, 0, 0, 0) // draws each triangle
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
		pWaitSemaphores      = &present_semaphores[frame_index],
		pWaitDstStageMask    = &wait_stages,
		commandBufferCount   = 1,
		pCommandBuffers      = &cb,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &render_semaphores[image_index],
	}
	chk(vk.QueueSubmit(device.queue, 1, &submit_info, fences[frame_index]))
	frame_index = (frame_index + 1) % MAX_FRAME_IN_FLIGHT
	// present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &render_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.handle,
		pImageIndices      = &image_index,
	}
	chk_swapchain(vk.QueuePresentKHR(device.queue, &present_info))

	// window resize or something like that
	if swapchain.needs_update {
		vk.DeviceWaitIdle(device.handle)
		surface_caps: vk.SurfaceCapabilitiesKHR
		chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, surface, &surface_caps))
		swapchain_context_init(&swapchain, surface, surface_caps, recreate = true)
	}
}

cleanup :: proc() {
	chk(vk.DeviceWaitIdle(device.handle))
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		vk.DestroyFence(device.handle, fences[i], nil)
		vk.DestroySemaphore(device.handle, present_semaphores[i], nil)
		vma.unmap_memory(device.allocator, shader_data_buffers[i].alloc)
		vma.destroy_buffer(
			device.allocator,
			shader_data_buffers[i].buffer,
			shader_data_buffers[i].alloc,
		)
	}
	for s in render_semaphores {
		vk.DestroySemaphore(device.handle, s, nil)
	}

	swapchain_context_destroy(&swapchain)

	vma.destroy_buffer(device.allocator, mesh_buffer, mesh_buffer_alloc)
	for t in textures {
		vk.DestroyImageView(device.handle, t.view, nil)
		vk.DestroySampler(device.handle, t.sampler, nil)
		vma.destroy_image(device.allocator, t.image, t.alloc)
	}
	vk.DestroyDescriptorSetLayout(device.handle, desc_set_layout_tex, nil)
	vk.DestroyDescriptorPool(device.handle, descriptor_pool, nil)
	vk.DestroyPipelineLayout(device.handle, pipeline_layout, nil)
	vk.DestroyPipeline(device.handle, pipeline, nil)
	vk.DestroyCommandPool(device.handle, command_pool, nil)
	vk.DestroyShaderModule(device.handle, shader_module, nil)
	vk.DestroySurfaceKHR(device.instance, surface, nil)
	context_destroy(&device)
}

chk :: proc(res: vk.Result, loc := #caller_location) {
	if res != .SUCCESS do panic(fmt.tprintf("chk failed: %v, loc=%v,%v", res, loc.file_path, loc.line))
}

chk_swapchain :: proc(result: vk.Result) {
	if result < .SUCCESS {
		if result == .ERROR_OUT_OF_DATE_KHR {
			swapchain.needs_update = true
			return
		}
		fmt.printf("Vulkan call returned an error (%v)\n", result)
		os.exit(int(result))
	}
}

vk_select_phys_device :: proc(phys_devices: []vk.PhysicalDevice) -> vk.PhysicalDevice {
	best: vk.PhysicalDevice
	best_score := min(int)
	for pd in phys_devices {
		d_score := vk_rate_phys_device(pd)
		if d_score > best_score {
			best = pd
			best_score = d_score
		}
	}
	return best
}

vk_check_ext_supported :: proc(phys_device: vk.PhysicalDevice, target_ext_name: cstring) -> bool {
	ext_count: u32
	vk.EnumerateDeviceExtensionProperties(phys_device, nil, &ext_count, nil)
	available_ext := make([]vk.ExtensionProperties, ext_count)
	defer delete(available_ext)
	vk.EnumerateDeviceExtensionProperties(phys_device, nil, &ext_count, raw_data(available_ext[:]))

	for &ext in available_ext {
		ext_name := cstring(&ext.extensionName[0])
		if runtime.cstring_cmp(target_ext_name, ext_name) == 0 {
			return true
		}
	}

	return false
}

vk_rate_phys_device :: proc(phys_device: vk.PhysicalDevice) -> int {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(phys_device, &props)

	score := 0
	if props.deviceType == .DISCRETE_GPU {
		score += 1000
	}
	score += int(props.limits.maxImageDimension2D)

	// account for available vram
	if vk_check_ext_supported(
		phys_device,
		vk.KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
	) {
		budget_props := vk.PhysicalDeviceMemoryBudgetPropertiesEXT {
			sType = .PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT,
		}
		mem_props := vk.PhysicalDeviceMemoryProperties2 {
			sType = .PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
			pNext = &budget_props,
		}
		vk.GetPhysicalDeviceMemoryProperties2(phys_device, &mem_props)

		available_budget_gb := 0
		for i in 0 ..< mem_props.memoryProperties.memoryHeapCount {
			heap := mem_props.memoryProperties.memoryHeaps[i]
			if .DEVICE_LOCAL in heap.flags {
				available_budget_gb += int(budget_props.heapBudget[i]) / mem.Gigabyte
			}
		}
		score += available_budget_gb * 100
	}

	return score
}

Vertex :: struct {
	pos:    [3]f32,
	normal: [3]f32,
	uv:     [2]f32,
}

Shader_Data_Buffer :: struct {
	alloc:       vma.Allocation,
	buffer:      vk.Buffer,
	device_addr: vk.DeviceAddress,
	mapped:      rawptr,
}

Mat4 :: matrix[4, 4]f32

Shader_Data :: struct #align (16) {
	projection: Mat4,
	view:       Mat4,
	model:      [3]Mat4,
	light_pos:  [4]f32,
	selected:   u32,
	_pad:       [3]u32, // align to 16-byte chunks
}

Texture :: struct {
	alloc:   vma.Allocation,
	image:   vk.Image,
	view:    vk.ImageView,
	sampler: vk.Sampler,
}

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
	chk(vk.CreateSwapchainKHR(device.handle, &sc.create_info, nil, &sc.handle))


	swapchain_image_count: u32
	chk(vk.GetSwapchainImagesKHR(device.handle, sc.handle, &swapchain_image_count, nil))
	resize(&sc.images, swapchain_image_count)
	chk(
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
		chk(vk.CreateImageView(device.handle, &view_create_info, nil, &sc.views[i]))
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
	chk(
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
	chk(vk.CreateImageView(device.handle, &depth_view_create_info, nil, &sc.depth_view))
}

swapchain_context_destroy :: proc(sc: ^Swapchain_Context) {
	vma.destroy_image(device.allocator, sc.depth_image, sc.depth_alloc)
	vk.DestroyImageView(device.handle, sc.depth_view, nil)
	for iv in sc.views {
		vk.DestroyImageView(device.handle, iv, nil)
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
	// num_properties: u31
	// vk.EnumerateInstanceLayerProperties(&num_properties, nil)
	// properties := make([]vk.LayerProperties, num_properties)
	// vk.EnumerateInstanceLayerProperties(&num_properties, raw_data(properties))
	validation_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
	instance_create_info := &vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = app_info,
		enabledExtensionCount = u32(len(instance_extensions)),
		ppEnabledExtensionNames = raw_data(instance_extensions),
		enabledLayerCount = u32(len(validation_layers)),
		ppEnabledLayerNames = raw_data(validation_layers),
	}
	chk(vk.CreateInstance(instance_create_info, nil, &dctx.instance))
	vk.load_proc_addresses(dctx.instance)

	// SELECT DEVICE
	device_count: u32
	chk(vk.EnumeratePhysicalDevices(dctx.instance, &device_count, nil))
	phys_devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	chk(vk.EnumeratePhysicalDevices(dctx.instance, &device_count, raw_data(phys_devices)))
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
	chk(vk.CreateDevice(dctx.physical, &device_create_info, nil, &dctx.handle))
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
	chk(vma.create_allocator(allocator_create_info, &dctx.allocator))
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

MeshHandle :: struct {
	idx: int,
}

load_mesh :: proc(vertices: []Vertex, indices: []u32) -> MeshHandle {
	@(static) buffer_offset: uintptr = 0
	MESH_ALIGNMENT :: 16

	v_bytes := len(vertices) * size_of(Vertex)
	i_bytes := len(indices) * size_of(u32)
	v_offset := mem.align_forward_uintptr(buffer_offset, MESH_ALIGNMENT)
	i_offset := mem.align_forward_uintptr(v_offset + uintptr(v_bytes), MESH_ALIGNMENT)
	end_offset := i_offset + uintptr(i_bytes)

	if end_offset > MESH_BUFFER_SIZE {
		panic("mesh_buffer is too full")
	}

	base_ptr: rawptr
	chk(vma.map_memory(device.allocator, mesh_buffer_alloc, &base_ptr))

	// copy vertices
	v_write_ptr := rawptr(uintptr(base_ptr) + v_offset)
	mem.copy(v_write_ptr, raw_data(vertices), v_bytes)

	// copy indices
	i_write_ptr := rawptr(uintptr(base_ptr) + uintptr(i_offset))
	mem.copy(i_write_ptr, raw_data(indices), i_bytes)

	// cleanup
	vma.flush_allocation(
		device.allocator,
		mesh_buffer_alloc,
		vk.DeviceSize(v_offset),
		vk.DeviceSize(end_offset - v_offset),
	)
	vma.unmap_memory(device.allocator, mesh_buffer_alloc)
	buffer_offset = end_offset

	handle := MeshHandle {
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
