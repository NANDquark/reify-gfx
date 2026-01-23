package reify

import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "lib/ktx"
import "lib/obj"
import "lib/vma"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 800
HEIGHT :: 600

SHADER_BYTES :: #load("assets/shader.spv")

run :: proc() {
	context.logger = log.create_console_logger()

	defer free_all(context.temp_allocator)

	// SETUP WINDOW
	if !bool(glfw.Init()) {
		panic("failed to initialize GLFW")
	}
	defer glfw.Terminate()
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	window := glfw.CreateWindow(WIDTH, HEIGHT, "Reify", nil, nil)
	if window == nil {
		panic("failed to create GLFW window")
	}
	defer glfw.DestroyWindow(window)
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	if !glfw.VulkanSupported() {
		panic("GLFW does not detect vulkan support on this system")
	}

	// CREATE INSTANCE
	app_info := &vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		pApplicationName = "Reify",
		apiVersion = vk.API_VERSION_1_3,
	}
	instance_extensions := glfw.GetRequiredInstanceExtensions()
	instance_create_info := &vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = app_info,
		enabledExtensionCount = u32(len(instance_extensions)),
		ppEnabledExtensionNames = raw_data(instance_extensions),
	}
	instance: vk.Instance
	chk(vk.CreateInstance(instance_create_info, nil, &instance))
	vk.load_proc_addresses(instance)

	// SELECT DEVICE
	device_count: u32
	chk(vk.EnumeratePhysicalDevices(instance, &device_count, nil))
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	chk(vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices)))
	// TODO command line argument to select alternate device
	assert(len(devices) > 0, "physical device required")
	phys_device := devices[0]
	fmt.printfln("Selected device: %v", phys_device)

	// SETUP QUEUE
	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, nil)
	queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		phys_device,
		&queue_family_count,
		raw_data(queue_families),
	)
	queue_family: u32
	for i in 0 ..< len(queue_families) {
		if .GRAPHICS in queue_families[i].queueFlags {
			queue_family = u32(i)
			break
		}
	}
	queue_familiy_priorities: f32 = 1.0
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_family,
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
	device: vk.Device
	chk(vk.CreateDevice(phys_device, &device_create_info, nil, &device))
	queue: vk.Queue
	vk.GetDeviceQueue(device, queue_family, 0, &queue)

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
		physical_device  = phys_device,
		device           = device,
		vulkan_functions = &vk_functions,
		instance         = instance,
	}
	allocator: vma.Allocator
	chk(vma.create_allocator(allocator_create_info, &allocator))

	// SETUP SURFACE
	surface: vk.SurfaceKHR
	chk(glfw.CreateWindowSurface(instance, window, nil, &surface))
	surface_caps: vk.SurfaceCapabilitiesKHR
	chk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, surface, &surface_caps))
	window_width, window_height := glfw.GetWindowSize(window)
	image_format := vk.Format.B8G8R8A8_SRGB
	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = surface,
		minImageCount = surface_caps.minImageCount,
		imageFormat = image_format,
		imageColorSpace = .COLORSPACE_SRGB_NONLINEAR,
		// surface extent had max int width/height since it was uninitialized
		imageExtent = vk.Extent2D {
			// width = surface_caps.currentExtent.width,
			width  = u32(window_width),
			// height = surface_caps.currentExtent.height,
			height = u32(window_height),
		},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		preTransform = {.IDENTITY},
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
	}
	swapchain: vk.SwapchainKHR
	chk(vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain))
	swapchain_image_count: u32
	chk(vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, nil))
	swapchain_images := make([]vk.Image, swapchain_image_count)
	swapchain_image_views := make([]vk.ImageView, swapchain_image_count)

	// DEPTH ATTACHMENT
	depth_format_list := [2]vk.Format{.D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}
	depth_format := vk.Format.UNDEFINED
	for format in depth_format_list {
		format_properties := vk.FormatProperties2 {
			sType = .FORMAT_PROPERTIES_2,
		}
		vk.GetPhysicalDeviceFormatProperties2(phys_device, format, &format_properties)
		if .DEPTH_STENCIL_ATTACHMENT in format_properties.formatProperties.optimalTilingFeatures {
			depth_format = format
			break
		}
	}
	depth_image_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = depth_format,
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
	depth_image: vk.Image
	depth_image_alloc: vma.Allocation
	chk(
		vma.create_image(
			allocator,
			depth_image_create_info,
			alloc_create_info,
			&depth_image,
			&depth_image_alloc,
			nil,
		),
	)
	depth_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = depth_image,
		viewType = .D2,
		format = depth_format,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.DEPTH},
			levelCount = 1,
			layerCount = 1,
		},
	}
	depth_image_view: vk.ImageView
	chk(vk.CreateImageView(device, &depth_view_create_info, nil, &depth_image_view))

	// LOAD MESH
	suzanne_obj, ok := obj.load_obj_file_from_file("./assets/suzanne.obj")
	if !ok {
		panic("failed to load suzanne.obj asset")
	}
	vertices := [dynamic]Vertex{}
	indices := [dynamic]u32{}
	for o in suzanne_obj.objects {
		for g in o.groups {
			for f in g.face_element {
				for i in 0 ..< 3 {
					// TODO this could be improved by de-duplicating and re-using existing vertex indices
					p_ind := f.position[i] - 1
					p := g.vertex_position[p_ind]
					n_ind := f.normal[i] - 1
					n := g.vertex_normal[n_ind]
					uv_ind := f.uv[i] - 1
					uv := g.vertex_uv[uv_ind]
					v := Vertex {
						pos    = p.xyz,
						normal = n.xyz,
						uv     = uv.xy,
					}
					append(&vertices, v)
					append(&indices, u32(len(indices)))
				}
			}
		}
	}
	v_buf_size := size_of(Vertex) * len(vertices)
	i_buf_size := size_of(u32) * len(indices)
	buffer_create_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(v_buf_size + i_buf_size),
		usage = {.VERTEX_BUFFER, .INDEX_BUFFER},
	}
	buffer_alloc_create_info := vma.Allocation_Create_Info {
		flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
		usage = .Auto,
	}
	v_buffer: vk.Buffer
	v_buffer_alloc: vma.Allocation
	chk(
		vma.create_buffer(
			allocator,
			buffer_create_info,
			buffer_alloc_create_info,
			&v_buffer,
			&v_buffer_alloc,
			nil,
		),
	)
	buffer_ptr: rawptr
	chk(vma.map_memory(allocator, v_buffer_alloc, &buffer_ptr))
	mem.copy(buffer_ptr, raw_data(vertices[:]), len(vertices))
	buffer_ptr_offset := rawptr(uintptr(buffer_ptr) + uintptr(len(vertices)))
	mem.copy(buffer_ptr_offset, raw_data(indices[:]), len(indices))
	vma.unmap_memory(allocator, v_buffer_alloc)

	// CPU & GPU Sync
	max_frames_in_flight :: 2
	shader_data_buffers := [max_frames_in_flight]Shader_Data_Buffer{}
	command_buffers := [max_frames_in_flight]vk.CommandBuffer{}
	for i in 0 ..< max_frames_in_flight {
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
				allocator,
				u_buffer_create_info,
				u_buffer_alloc_create_info,
				&shader_data_buffers[i].buffer,
				&shader_data_buffers[i].alloc,
				nil,
			),
		)
		chk(
			vma.map_memory(
				allocator,
				shader_data_buffers[i].alloc,
				&shader_data_buffers[i].mapped,
			),
		)
		u_buffer_bda_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = shader_data_buffers[i].buffer,
		}
		shader_data_buffers[i].device_addr = vk.GetBufferDeviceAddress(device, &u_buffer_bda_info)
	}
	fences := [max_frames_in_flight]vk.Fence{}
	present_semaphores := [max_frames_in_flight]vk.Semaphore{}
	render_semaphores := make([]vk.Semaphore, swapchain_image_count, context.temp_allocator)
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< max_frames_in_flight {
		chk(vk.CreateFence(device, &fence_create_info, nil, &fences[i]))
		chk(vk.CreateSemaphore(device, &semaphore_create_info, nil, &present_semaphores[i]))
	}
	for &s in render_semaphores {
		chk(vk.CreateSemaphore(device, &semaphore_create_info, nil, &s))
	}

	// COMMAND BUFFERS
	command_pool_create_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = queue_family,
	}
	command_pool: vk.CommandPool
	chk(vk.CreateCommandPool(device, &command_pool_create_info, nil, &command_pool))
	command_buffer_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		commandBufferCount = max_frames_in_flight,
	}
	chk(
		vk.AllocateCommandBuffers(
			device,
			&command_buffer_alloc_info,
			raw_data(command_buffers[:]),
		),
	)

	// LOADING TEXTURES
	textures := [3]Texture{}
	texture_descriptors := [dynamic]vk.DescriptorImageInfo{}
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
				allocator,
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
		chk(vk.CreateImageView(device, &tex_view_create_info, nil, &textures[i].view))
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
				allocator,
				img_src_buffer_create_info,
				img_src_alloc_create_info,
				&img_src_buffer,
				&img_src_alloc,
				nil,
			),
		)
		img_src_buffer_ptr: rawptr
		chk(vma.map_memory(allocator, img_src_alloc, &img_src_buffer_ptr))
		mem.copy(img_src_buffer_ptr, ktx_texture.pData, int(ktx_texture.dataSize))
		fence_one_time_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
		}
		fence_one_time: vk.Fence
		chk(vk.CreateFence(device, &fence_one_time_create_info, nil, &fence_one_time))
		cb_one_time: vk.CommandBuffer
		cb_one_time_alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = command_pool,
			commandBufferCount = 1,
		}
		chk(vk.AllocateCommandBuffers(device, &cb_one_time_alloc_info, &cb_one_time))
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
		sampler_create_info := vk.SamplerCreateInfo {
			sType            = .SAMPLER_CREATE_INFO,
			magFilter        = .LINEAR,
			minFilter        = .LINEAR,
			mipmapMode       = .LINEAR,
			anisotropyEnable = true,
			maxAnisotropy    = 8, // widely used
			maxLod           = f32(ktx_texture.numLevels),
		}
		chk(vk.CreateSampler(device, &sampler_create_info, nil, &textures[i].sampler))
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
	desc_set_layout_tex: vk.DescriptorSetLayout
	chk(
		vk.CreateDescriptorSetLayout(
			device,
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
	descriptor_pool: vk.DescriptorPool
	chk(vk.CreateDescriptorPool(device, &desc_pool_create_info, nil, &descriptor_pool))
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
	descriptor_set_tex: vk.DescriptorSet
	chk(vk.AllocateDescriptorSets(device, &tex_desc_set_alloc, &descriptor_set_tex))
	write_desc_set := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = descriptor_set_tex,
		dstBinding      = 0,
		descriptorCount = u32(len(texture_descriptors)),
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = raw_data(texture_descriptors),
	}
	vk.UpdateDescriptorSets(device, 1, &write_desc_set, 0, nil)

	// TODO: LOADING SHADERS
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(SHADER_BYTES),
		pCode    = cast(^u32)raw_data(SHADER_BYTES),
	}
	shader_module: vk.ShaderModule
	chk(vk.CreateShaderModule(device, &shader_module_create_info, nil, &shader_module))

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
	pipeline_layout: vk.PipelineLayout
	chk(vk.CreatePipelineLayout(device, &pipeline_layout_create_info, nil, &pipeline_layout))
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
		pColorAttachmentFormats = &image_format,
		depthAttachmentFormat   = depth_format,
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
	pipeline: vk.Pipeline
	chk(vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_create_info, nil, &pipeline))

	// MAIN LOOP
	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
	}
}

chk :: proc(res: vk.Result) {
	if res != .SUCCESS do panic(fmt.tprintf("chk failed: %v", res))
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
