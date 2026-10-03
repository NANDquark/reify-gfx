#+private
package reify

import "core:fmt"
import "core:math/linalg"
import "core:reflect"
import "lib/vma"
import vk "vendor:vulkan"

// Assert that the vulkan result is success
vk_assert :: proc(res: vk.Result, loc := #caller_location) {
	if res != .SUCCESS {
		panic(fmt.tprintf("vk_chk failed: %v, loc=%v,%v", res, loc.file_path, loc.line))
	}
}

Chk_Swapchain_Result :: enum {
	Success,
	Swapchain_Must_Update,
}

// Check whether the vulkan result is success, with some special handling for swapchain
vk_chk_swapchain :: proc(result: vk.Result, loc := #caller_location) -> Chk_Swapchain_Result {
	if result == .ERROR_OUT_OF_DATE_KHR do return .Swapchain_Must_Update
	if result >= .SUCCESS do return .Success
	panic(fmt.tprintf("vk_chk_swapchain failed: %v, loc=%v,%v\n", result, loc.file_path, loc.line))
}

One_Time_Cmd_Buffer :: struct {
	device:       vk.Device,
	queue:        vk.Queue,
	command_pool: vk.CommandPool,
	fence:        vk.Fence,
	cmd:          vk.CommandBuffer,
}

vk_one_time_cmd_buffer_begin :: proc(
	device: vk.Device,
	queue: vk.Queue,
	command_pool: vk.CommandPool,
) -> (
	One_Time_Cmd_Buffer,
	vk.Result,
) {
	ctx := One_Time_Cmd_Buffer {
		device       = device,
		queue        = queue,
		command_pool = command_pool,
	}

	fence_one_time_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	create_fence_result := vk.CreateFence(ctx.device, &fence_one_time_create_info, nil, &ctx.fence)
	if create_fence_result != .SUCCESS do return {}, create_fence_result
	success := false
	defer if !success do vk_one_time_cmd_buffer_destroy(&ctx)
	cb_one_time_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		commandBufferCount = 1,
	}

	allocate_command_buffers_result := vk.AllocateCommandBuffers(ctx.device, &cb_one_time_alloc_info, &ctx.cmd)
	if allocate_command_buffers_result != .SUCCESS do return {}, allocate_command_buffers_result
	cb_one_time_buf_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	begin_command_buffer_result := vk.BeginCommandBuffer(ctx.cmd, &cb_one_time_buf_begin_info)
	if begin_command_buffer_result != .SUCCESS do return {}, begin_command_buffer_result

	success = true
	return ctx, .SUCCESS
}

vk_one_time_cmd_buffer_end :: proc(ctx: ^One_Time_Cmd_Buffer) -> vk.Result {
	release := true
	defer if release do vk_one_time_cmd_buffer_destroy(ctx)
	end_command_buffer_result := vk.EndCommandBuffer(ctx.cmd)
	if end_command_buffer_result != .SUCCESS do return end_command_buffer_result

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &ctx.cmd,
	}
	queue_submit_result := vk.QueueSubmit(ctx.queue, 1, &submit_info, ctx.fence)
	if queue_submit_result != .SUCCESS do return queue_submit_result
	wait_for_fences_result := vk.WaitForFences(ctx.device, 1, &ctx.fence, true, max(u64))
	if wait_for_fences_result != .SUCCESS {
		idle_res := vk.DeviceWaitIdle(ctx.device)
		if idle_res != .SUCCESS && idle_res != .ERROR_DEVICE_LOST do release = false
		return wait_for_fences_result
	}
	return .SUCCESS
}

vk_one_time_cmd_buffer_destroy :: proc(ctx: ^One_Time_Cmd_Buffer) {
	vk.DestroyFence(ctx.device, ctx.fence, nil)
	if ctx.cmd != {} do vk.FreeCommandBuffers(ctx.device, ctx.command_pool, 1, &ctx.cmd)
	ctx^ = {}
}

vk_shader_module_init :: proc(
	device: vk.Device,
	shader_module: ^vk.ShaderModule,
	shader_bytes: []byte,
) -> vk.Result {
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_bytes),
		pCode    = cast(^u32)raw_data(shader_bytes),
	}
	create_shader_module_result := vk.CreateShaderModule(device, &shader_module_create_info, nil, shader_module)
	if create_shader_module_result != .SUCCESS do return create_shader_module_result
	return .SUCCESS
}

vk_pipeline_init :: proc(
	device: vk.Device,
	$Push_Constants_Type: typeid,
	$Vertex_Type: typeid,
	desc_set_layout: ^vk.DescriptorSetLayout,
	shader_module: vk.ShaderModule,
	out_pipeline_layout: ^vk.PipelineLayout,
	out_pipeline: ^vk.Pipeline,
	attachment_format: vk.Format,
) -> vk.Result {
	attachment_format := attachment_format
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(Push_Constants_Type),
	}
	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = desc_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	create_pipeline_layout_result := vk.CreatePipelineLayout(device, &pipeline_layout_create_info, nil, out_pipeline_layout)
	if create_pipeline_layout_result != .SUCCESS do return create_pipeline_layout_result
	vertex_input_state := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
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
	rendering_create_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &attachment_format,
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
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
		pColorBlendState    = &color_blend_state,
		pDynamicState       = &dynamic_state,
		layout              = out_pipeline_layout^,
	}
	create_graphics_pipelines_result := vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_create_info, nil, out_pipeline)
	if create_graphics_pipelines_result != .SUCCESS do return create_graphics_pipelines_result
	return .SUCCESS
}

@(private = "file")
get_vertex_attributes :: proc($T: typeid) -> []vk.VertexInputAttributeDescription {
	info := reflect.type_info_base(type_info_of(T))
	struct_info, ok := info.variant.(reflect.Type_Info_Struct)
	if !ok {
		panic("must only supply structs")
	}
	attribs := make([]vk.VertexInputAttributeDescription, struct_info.field_count)

	for i in 0 ..< struct_info.field_count {
		offset := struct_info.offsets[i]
		ti := struct_info.types[i]

		attribs[i] = vk.VertexInputAttributeDescription {
			location = u32(i),
			binding  = 0,
			format   = type_to_vk_format(ti),
			offset   = u32(offset),
		}
	}
	return attribs
}

@(private = "file")
type_to_vk_format :: proc(info: ^reflect.Type_Info) -> vk.Format {
	#partial switch variant in info.variant {
	case reflect.Type_Info_Array:
		if variant.elem.id == f32 {
			switch variant.count {
			case 2:
				return .R32G32_SFLOAT
			case 3:
				return .R32G32B32_SFLOAT
			case 4:
				return .R32G32B32A32_SFLOAT
			}
		}
		if variant.elem.id == f64 {
			switch variant.count {
			case 2:
				return .R64G64_SFLOAT
			case 3:
				return .R64G64B64_SFLOAT
			case 4:
				return .R64G64B64A64_SFLOAT
			}
		}
		if variant.elem.id == u32 {
			switch variant.count {
			case 2:
				return .R32G32_UINT
			case 3:
				return .R32G32B32_UINT
			case 4:
				return .R32G32B32A32_UINT
			}
		}
		if variant.elem.id == u64 {
			switch variant.count {
			case 2:
				return .R64G64_UINT
			case 3:
				return .R64G64B64_UINT
			case 4:
				return .R64G64B64A64_UINT
			}
		}
		if variant.elem.id == i32 {
			switch variant.count {
			case 2:
				return .R32G32_SINT
			case 3:
				return .R32G32B32_SINT
			case 4:
				return .R32G32B32A32_SINT
			}
		}
		if variant.elem.id == i64 {
			switch variant.count {
			case 2:
				return .R64G64_SINT
			case 3:
				return .R64G64B64_SINT
			case 4:
				return .R64G64B64A64_SINT
			}
		}
	case reflect.Type_Info_Integer:
		if variant.signed {
			switch info.size {
			case 4:
				return .R32_SINT
			case 8:
				return .R64_SINT
			}
		} else {
			switch info.size {
			case 4:
				return .R32_UINT
			case 8:
				return .R64_UINT
			}
		}
	case reflect.Type_Info_Float:
		switch info.size {
		case 4:
			return .R32_SFLOAT
		case 8:
			return .R64_SFLOAT
		}
	case:
		panic("unimplemented type conversion in Vertex")
	}
	return .UNDEFINED
}

// Create an orthographic projection in the Vulkan style
vk_ortho_projection :: proc(left, right, bottom, top, near, far: f32) -> Mat4f {
	gl_projection := linalg.matrix_ortho3d(left, right, bottom, top, near, far)
	// odinfmt: disable
	vk_correction := Mat4f{
		1, 0, 0,   0,
		0, 1, 0,   0,
	 	0, 0, 0.5, 0.5,
		0, 0, 0,   1,
	}
	// odinfmt: enable
	// OpenGL NDC are from -1.0 to 1.0 but Vulkan NDC are 0 to 1. So here we scale
	// the clipping plane by x0.5 to shrink the value to the correct number of
	// units then translate it +0.5 so it sits from 0 - 1.
	vk_projection := vk_correction * gl_projection
	return vk_projection
}

vk_create_texture :: proc(
	device: vk.Device,
	allocator: vma.Allocator,
	format: vk.Format,
	width, height, mipLevels: u32,
	max_allocation_size: vk.DeviceSize,
) -> (
	Texture,
	vk.Result,
) {
	tex := Texture {
		width  = int(width),
		height = int(height),
	}
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
	res := vk.CreateImage(device, &tex_img_create_info, nil, &tex.image)
	if res != .SUCCESS do return {}, res
	success := false
	defer if !success {
		vk.DestroyImage(device, tex.image, nil)
		if tex.alloc != nil do vma.free_memory(allocator, tex.alloc)
	}
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, tex.image, &requirements)
	if requirements.size > max_allocation_size {
		return {}, .ERROR_OUT_OF_DEVICE_MEMORY
	}
	allocate_memory_for_image_result := vma.allocate_memory_for_image(allocator, tex.image, {preferred_flags = {.DEVICE_LOCAL}}, &tex.alloc, nil)
	if allocate_memory_for_image_result != .SUCCESS do return {}, allocate_memory_for_image_result
	bind_image_memory_result := vma.bind_image_memory(allocator, tex.alloc, tex.image)
	if bind_image_memory_result != .SUCCESS do return {}, bind_image_memory_result
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
	create_image_view_result := vk.CreateImageView(device, &tex_view_create_info, nil, &tex.view)
	if create_image_view_result != .SUCCESS {
		return {}, create_image_view_result
	}
	success = true
	return tex, .SUCCESS
}
