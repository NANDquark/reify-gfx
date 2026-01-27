#+private
package reify

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "lib/vma"
import vk "vendor:vulkan"

// Assert that the vulkan result is success
vk_chk :: proc(res: vk.Result, loc := #caller_location) {
	if res != .SUCCESS do panic(fmt.tprintf("chk failed: %v, loc=%v,%v", res, loc.file_path, loc.line))
}

// Assert that the vulkan result is success, with some special handling for swapchain
vk_chk_swapchain :: proc(result: vk.Result) {
	if result < .SUCCESS {
		if result == .ERROR_OUT_OF_DATE_KHR {
			swapchain.needs_update = true
			return
		}
		fmt.printf("Vulkan call returned an error (%v)\n", result)
		os.exit(int(result))
	}
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

One_Time_Command_Buffer :: struct {
	fence: vk.Fence,
	cmd:   vk.CommandBuffer,
}

vk_one_time_cmd_buffer_begin :: proc() -> One_Time_Command_Buffer {
	ctx: One_Time_Command_Buffer

	fence_one_time_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	vk_chk(vk.CreateFence(device.handle, &fence_one_time_create_info, nil, &ctx.fence))
	cb_one_time_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		commandBufferCount = 1,
	}

	vk_chk(vk.AllocateCommandBuffers(device.handle, &cb_one_time_alloc_info, &ctx.cmd))
	cb_one_time_buf_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	vk_chk(vk.BeginCommandBuffer(ctx.cmd, &cb_one_time_buf_begin_info))

	return ctx
}

vk_one_time_cmd_buffer_end :: proc(ctx: ^One_Time_Command_Buffer) {
	vk_chk(vk.EndCommandBuffer(ctx.cmd))

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &ctx.cmd,
	}
	vk_chk(vk.QueueSubmit(device.queue, 1, &submit_info, ctx.fence))
	vk_chk(vk.WaitForFences(device.handle, 1, &ctx.fence, true, max(u64)))

	vk.DestroyFence(device.handle, ctx.fence, nil)
	vma.unmap_memory(device.allocator, tex_staging_alloc)
	vk.FreeCommandBuffers(device.handle, command_pool, 1, &ctx.cmd)
}
