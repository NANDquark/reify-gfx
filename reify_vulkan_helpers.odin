#+private
package reify

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
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

// Iterate the physical graphics devices and select the best one for usage
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

// Create a rating for each physical device based on integrated vs discrete,
// available VRAM, and other GPU limits. Higher ratings are better.
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

// Check whether a physical device supports a target extension
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
) -> One_Time_Cmd_Buffer {
	ctx := One_Time_Cmd_Buffer {
		device       = device,
		queue        = queue,
		command_pool = command_pool,
	}

	fence_one_time_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	vk_assert(vk.CreateFence(ctx.device, &fence_one_time_create_info, nil, &ctx.fence))
	cb_one_time_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		commandBufferCount = 1,
	}

	vk_assert(vk.AllocateCommandBuffers(ctx.device, &cb_one_time_alloc_info, &ctx.cmd))
	cb_one_time_buf_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	vk_assert(vk.BeginCommandBuffer(ctx.cmd, &cb_one_time_buf_begin_info))

	return ctx
}

vk_one_time_cmd_buffer_end :: proc(ctx: ^One_Time_Cmd_Buffer) {
	vk_assert(vk.EndCommandBuffer(ctx.cmd))

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &ctx.cmd,
	}
	vk_assert(vk.QueueSubmit(ctx.queue, 1, &submit_info, ctx.fence))
	vk_assert(vk.WaitForFences(ctx.device, 1, &ctx.fence, true, max(u64)))

	vk.DestroyFence(ctx.device, ctx.fence, nil)
	vk.FreeCommandBuffers(ctx.device, ctx.command_pool, 1, &ctx.cmd)
}

vk_shader_module_init :: proc(
	device: vk.Device,
	shader_module: ^vk.ShaderModule,
	shader_bytes: []byte,
) {
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_bytes),
		pCode    = cast(^u32)raw_data(shader_bytes),
	}
	vk_assert(vk.CreateShaderModule(device, &shader_module_create_info, nil, shader_module))
}

vk_pipeline_init :: proc(
	device: vk.Device,
	$Push_Constants_Type: typeid,
	$Vertex_Type: typeid,
	desc_set_layout: ^vk.DescriptorSetLayout,
	shader_module: vk.ShaderModule,
	out_pipeline_layout: ^vk.PipelineLayout,
	out_pipeline: ^vk.Pipeline,
) {
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
	vk_assert(
		vk.CreatePipelineLayout(device, &pipeline_layout_create_info, nil, out_pipeline_layout),
	)
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
		pColorAttachmentFormats = &IMAGE_FORMAT,
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
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
	vk_assert(vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_create_info, nil, out_pipeline))
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

// Create an orthographic projection in the vulkan style
vk_ortho_projection :: proc(l, r, t, b, n, f: f32) -> Mat4f {
	gl_projection := linalg.matrix_ortho3d(l, r, b, t, n, f)
	// odinfmt: disable
	vk_correction := Mat4f{
		1, 0, 0,   0,
		0, 1, 0,   0,
	 	0, 0, 0.5, 0.5,
		0, 0, 0,   1,
	}
	// odinfmt: enable
	vk_projection := vk_correction * gl_projection
	return vk_projection
}
