package reify

import "base:runtime"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"
import "lib/vma"

when bool(#config(Reify_Integration_Test, false)) {
	@(test)
	integration_texture_batch_cost :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		r := &f.renderer
		a, a_ok := texture_load(r, f.white[:], 1, 1)
		b, b_ok := texture_load(r, []Color{{255, 0, 0, 128}}, 1, 1)
		assert(a_ok && b_ok)
		set_perf_logging(r, true)
		modes := [?]bool{false, true}
		for alternating in modes {
			build_ms, present_ms: f64
			draws: int
			for frame in 0 ..< 10 {
				start(r, {}, 1)
				begin_screen_mode(r)
				build_start := time.now()
				for i in 0 ..< 10000 {
					texture := b if alternating && i % 2 != 0 else a
					draw_image(r, texture, {f32(i % 800), f32(i / 800)}, scale = {1, 1})
				}
				build_end := time.now()
				r.perf.draw_calls = 0
				r.perf.last_log_time = time.now()
				assert(present(r))
				present_end := time.now()
				assert(vk.DeviceWaitIdle(r.gpu.device) == .SUCCESS)
				if frame >= 2 {
					build_ms += f64(time.duration_milliseconds(time.diff(build_start, build_end)))
					present_ms += f64(time.duration_milliseconds(time.diff(build_end, present_end)))
					draws += r.perf.draw_calls
				}
			}
			fmt.printf("Batch cost %s alternating=%v: 10000 sprites, %.0f draws/frame, CPU build %.3fms/frame, present %.3fms/frame (8 samples after warmup)\n", RENDERER_BACKEND, alternating, f64(draws) / 8, build_ms / 8, present_ms / 8)
		}
	}

	@(test)
	integration_backend_parity :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		f.zero_framebuffer = true
		assert(integration_renderer_init(f))
		r := &f.renderer
		caps: vk.SurfaceCapabilitiesKHR
		assert(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(r.gpu.physical, r.surface, &caps) == .SUCCESS)
		if !testing.expect(t, .TRANSFER_SRC in caps.supportedUsageFlags, "Parity readback requires optional surface transfer-source support") do return
		parity_saved_swapchain = vk.CreateSwapchainKHR
		vk.CreateSwapchainKHR = integration_parity_swapchain
		defer vk.CreateSwapchainKHR = parity_saved_swapchain
		f.zero_framebuffer = false
		start(r, {}, 1)
		assert(present(r))
		defer {
			assert(vk.DeviceWaitIdle(r.gpu.device) == .SUCCESS)
			vma.destroy_buffer(r.gpu.allocator, parity_buffer, parity_allocation)
			parity_buffer, parity_allocation = {}, nil
			parity_width, parity_height, parity_mapped = 0, 0, nil
		}
		red, red_ok := texture_load(r, []Color{{255, 0, 0, 180}, {0, 0, 255, 255}, {0, 255, 0, 150}, {255, 255, 255, 255}}, 2, 2)
		green, green_ok := texture_load(r, []Color{{0, 255, 0, 160}}, 1, 1)
		assert(red_ok && green_ok)
		font := integration_font_load(f)
		parity_saved_submit = vk.QueueSubmit
		vk.QueueSubmit = integration_parity_submit
		defer vk.QueueSubmit = parity_saved_submit
		for _ in 0 ..< 6 {
			start(r, {15, 20}, 1.2)
			draw_rect(r, {-70, -50}, 100, 80, {240, 80, 120, 190})
			draw_circle(r, {40, 0}, 30, {30, 220, 160, 170})
			begin_screen_mode(r)
			draw_image(r, red, {30, 30}, scale = {90, 90})
			draw_image(r, green, {110, 50}, scale = {140, 120}, alpha = 0.7)
			draw_image(r, red, {140, 70}, scale = {70, 70}, rotation = 0.4, uv_rect = {0.5, 0, 0.5, 1}, is_additive = true)
			draw_triangle(r, {270, 30}, {380, 110}, {250, 150}, {255, 150, 30, 180})
			draw_line(r, {300, 150}, {440, 40}, 9, {80, 200, 255, 220})
			points := [][2]f32{{400, 220}, {440, 140}, {500, 200}, {520, 130}}
			draw_lines(r, 7, {240, 100, 220, 150}, true, true, points)
			set_scissor(r, 40, 280, 460, 55)
			draw_text(r, font, "Parity: MSDF / textures", {20, 270}, 42, {220, 240, 255, 200})
			draw_image(r, green, {420, 260}, scale = {140, 100})
			clear_scissor(r)
			end_screen_mode(r)
			draw_triangle(r, {-20, 80}, {90, 50}, {60, 150}, {255, 160, 90, 200})
			assert(present(r))
			assert(vk.DeviceWaitIdle(r.gpu.device) == .SUCCESS)
			vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &parity_command)
			parity_command = {}
		}
		assert(vma.invalidate_allocation(r.gpu.allocator, parity_allocation, 0, vk.DeviceSize(vk.WHOLE_SIZE)) == .SUCCESS)
		width, height := parity_width, parity_height
		pixels := ([^]u8)(parity_mapped)[:width * height * 4]
		nonblack := 0
		for i in 0 ..< width * height {
			if pixels[i * 4] != 0 || pixels[i * 4 + 1] != 0 || pixels[i * 4 + 2] != 0 do nonblack += 1
		}
		assert(nonblack > 1000)
		output := os.get_env("REIFY_PARITY_OUTPUT", context.allocator)
		defer delete(output)
		if output != "" {
			assert(renderer_capture_write_ppm(output, pixels, width, height, r.gpu.surface_format.format == .B8G8R8A8_SRGB, false))
		}
	}

	parity_saved_swapchain: vk.ProcCreateSwapchainKHR
	parity_saved_submit: vk.ProcQueueSubmit
	parity_buffer: vk.Buffer
	parity_allocation: vma.Allocation
	parity_command: vk.CommandBuffer
	parity_width, parity_height: int
	parity_mapped: rawptr

	integration_parity_swapchain :: proc "system" (device: vk.Device, info: ^vk.SwapchainCreateInfoKHR, allocator: ^vk.AllocationCallbacks, swapchain: ^vk.SwapchainKHR) -> vk.Result {
		info.imageUsage += {.TRANSFER_SRC}
		return parity_saved_swapchain(device, info, allocator, swapchain)
	}

	integration_parity_submit :: proc "system" (queue: vk.Queue, count: u32, submits: [^]vk.SubmitInfo, fence: vk.Fence) -> vk.Result {
		context = integration_fixture_context(integration_active_fixture)
		if count != 1 || submits[0].signalSemaphoreCount != 1 do return parity_saved_submit(queue, count, submits, fence)
		r := &integration_active_fixture.renderer
		image_index := -1
		for semaphore, i in r.swapchain.render_semaphores {
			if semaphore == submits[0].pSignalSemaphores[0] do image_index = i
		}
		assert(image_index >= 0 && parity_command == {})
		extent := r.swapchain.create_info.imageExtent
		if parity_width != int(extent.width) || parity_height != int(extent.height) {
			assert(vk.DeviceWaitIdle(r.gpu.device) == .SUCCESS)
			if parity_buffer != {} do vma.destroy_buffer(r.gpu.allocator, parity_buffer, parity_allocation)
			parity_width, parity_height = int(extent.width), int(extent.height)
			buffer_info := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = vk.DeviceSize(parity_width * parity_height * 4), usage = {.TRANSFER_DST}}
			allocation_info := vma.Allocation_Create_Info{usage = .Auto, flags = {.Host_Access_Random, .Mapped}, required_flags = {.HOST_VISIBLE}}
			mapped: vma.Allocation_Info
			assert(vma.create_buffer(r.gpu.allocator, buffer_info, allocation_info, &parity_buffer, &parity_allocation, &mapped) == .SUCCESS)
			assert(mapped.mapped_data != nil)
			parity_mapped = mapped.mapped_data
		}
		allocation := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = r.command_pool, commandBufferCount = 1}
		assert(vk.AllocateCommandBuffers(r.gpu.device, &allocation, &parity_command) == .SUCCESS)
		begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
		assert(vk.BeginCommandBuffer(parity_command, &begin) == .SUCCESS)
		barrier := vk.ImageMemoryBarrier {
			sType = .IMAGE_MEMORY_BARRIER, srcAccessMask = {.COLOR_ATTACHMENT_WRITE}, dstAccessMask = {.TRANSFER_READ},
			oldLayout = .PRESENT_SRC_KHR, newLayout = .TRANSFER_SRC_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = r.swapchain.images[image_index], subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk.CmdPipelineBarrier(parity_command, {.COLOR_ATTACHMENT_OUTPUT}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &barrier)
		region := vk.BufferImageCopy{imageSubresource = {aspectMask = {.COLOR}, layerCount = 1}, imageExtent = {extent.width, extent.height, 1}}
		vk.CmdCopyImageToBuffer(parity_command, barrier.image, .TRANSFER_SRC_OPTIMAL, parity_buffer, 1, &region)
		barrier.srcAccessMask, barrier.dstAccessMask = {.TRANSFER_READ}, {}
		barrier.oldLayout, barrier.newLayout = .TRANSFER_SRC_OPTIMAL, .PRESENT_SRC_KHR
		vk.CmdPipelineBarrier(parity_command, {.TRANSFER}, {.BOTTOM_OF_PIPE}, {}, 0, nil, 0, nil, 1, &barrier)
		assert(vk.EndCommandBuffer(parity_command) == .SUCCESS)
		commands := [2]vk.CommandBuffer{submits[0].pCommandBuffers[0], parity_command}
		submit := submits[0]
		submit.commandBufferCount, submit.pCommandBuffers = 2, &commands[0]
		return parity_saved_submit(queue, 1, &submit, fence)
	}

	@(test)
	integration_renderer_lifetimes :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)

		for _ in 0 ..< 3 {
			assert(integration_renderer_init(f))
			assert(len(f.renderer.platform.vulkan.required_instance_extensions) == 0)
			font := integration_font_load(f)
			integration_present_platform_frames(f, font)
			integration_renderer_destroy(f)
			assert(!f.renderer.initialized)
			assert(f.surfaces_created == f.surfaces_destroyed)
		}
	}

	@(test)
	integration_window_resize :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		font := integration_font_load(f)
		integration_present_platform_frames(f, font)

		// Window managers may constrain native sizes; verify callback routing directly.
		integration_window_size(f.window, 960, 720)
		assert(f.renderer.window.width == 960 && f.renderer.window.height == 720)
		glfw.SetWindowSize(f.window, 960, 720)
		integration_present_platform_frames(f, font)
		width, height := glfw.GetFramebufferSize(f.window)
		assert(f.renderer.framebuffer_size == [2]int{int(width), int(height)})
		assert(f.renderer.swapchain.handle != {})
	}

	@(test)
	integration_vsync_transitions :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		font := integration_font_load(f)
		integration_present_platform_frames(f, font)

		vsync_modes := [2]bool{false, true}
		for enabled in vsync_modes {
			set_vsync(&f.renderer, enabled)
			assert(f.renderer.swapchain.vsync_enabled == enabled)
			assert(f.renderer.swapchain.needs_update)
			integration_present_platform_frames(f, font)
			assert(f.renderer.swapchain.handle != {})
		}
	}

	@(test)
	integration_minimize_restore :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		font := integration_font_load(f)
		integration_present_platform_frames(f, font)

		glfw.IconifyWindow(f.window)
		// The callback forces zero pixels even when no window manager is present.
		f.zero_framebuffer = true
		integration_present_platform_frames(f, font)
		assert(f.renderer.framebuffer_size == {})
		assert(!f.renderer.stopped)

		glfw.RestoreWindow(f.window)
		f.zero_framebuffer = false
		integration_present_platform_frames(f, font)
		assert(f.renderer.framebuffer_size.x > 0 && f.renderer.framebuffer_size.y > 0)
		assert(f.renderer.swapchain.handle != {})
	}

	@(test)
	integration_zero_framebuffer_init :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)

		f.zero_framebuffer = true
		assert(integration_renderer_init(f))
		assert(f.renderer.framebuffer_size == {} && f.renderer.swapchain.handle == {})
		_, texture_ok := texture_load(&f.renderer, f.white[:], 1, 1)
		assert(texture_ok)
		font := integration_font_load(f)
		integration_present_platform_frames(f, font)
		assert(f.renderer.swapchain.handle == {} && !f.renderer.stopped)

		f.zero_framebuffer = false
		integration_present_platform_frames(f, font)
		assert(f.renderer.framebuffer_size.x > 0 && f.renderer.framebuffer_size.y > 0)
		assert(f.renderer.swapchain.handle != {})
	}

	@(test)
	integration_init_rollback :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)

		failures := [?]Integration_Failure{.Allocate, .Map, .Image}
		for failure in failures {
			integration_inject(f, failure)
			assert(!integration_renderer_init(f))
			assert(!f.renderer.initialized && !f.renderer.loader_owned)
			assert(f.surfaces_created == f.surfaces_destroyed)
		}
	}

	@(test)
	integration_staging_fallback :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)

		integration_inject(f, .Staging_Fallback)
		assert(integration_renderer_init(f))
		limits := effective_limits(&f.renderer)
		assert(limits.textures > 1 && limits.fonts > 0)
		assert(limits.staging_bytes == INTEGRATION_STAGING_BYTES)
	}

	@(test)
	integration_chunked_upload_and_publication :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)

		integration_inject(f, .Staging_Fallback)
		assert(integration_renderer_init(f))
		assert(effective_limits(&f.renderer).staging_bytes == INTEGRATION_STAGING_BYTES)
		integration_inject(f, .None)
		integration_draw_mixed_resources(f)
	}

	@(test)
	integration_resource_rollback :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		r := &f.renderer
		initial_textures := len(r.resources.textures)

		failures := [?]Integration_Failure{.Image, .View, .Upload}
		for failure in failures {
			integration_inject(f, failure)
			handle, ok := texture_load(r, f.white[:], 1, 1)
			assert(handle.idx == -1 && !ok)
			assert(len(r.resources.textures) == initial_textures && !r.stopped)
		}
		integration_inject(f, .Font_Upload)
		handle, ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
		assert(handle.idx == -1 && !ok)
		assert(len(r.resources.font_faces) == 0)
		assert(len(r.resources.textures) == initial_textures && !r.stopped)

		integration_inject(f, .None)
		_, texture_ok := texture_load(r, f.white[:], 1, 1)
		_, font_ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
		assert(texture_ok && font_ok)
	}

	@(test)
	integration_texture_dimensions :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		initial_textures := len(f.renderer.resources.textures)

		invalid_dimensions := [][2]int{{0, 1}, {-1, 1}, {2, 1}}
		for dimensions in invalid_dimensions {
			handle, ok := texture_load(&f.renderer, f.white[:], dimensions.x, dimensions.y)
			assert(handle.idx == -1 && !ok)
			assert(len(f.renderer.resources.textures) == initial_textures)
			assert(!f.renderer.stopped)
		}
	}

	@(test)
	integration_instance_capacity :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		r := &f.renderer
		capacity := int(effective_limits(r).instances)

		start(r, {}, 1)
		for _ in 0 ..< capacity {
			draw_rect(r, {}, 1, 1, {255, 255, 255, 255})
		}
		assert(present(r))
		start(r, {}, 1)
		for _ in 0 ..< capacity + 1 {
			draw_rect(r, {}, 1, 1, {255, 255, 255, 255})
		}
		assert(!present(r) && !r.stopped)
		start(r, {}, 1)
		assert(present(r))
	}

	@(test)
	integration_resource_capacity :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		r := &f.renderer
		limits := effective_limits(r)

		for len(r.resources.font_faces) < int(limits.fonts) {
			_, ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
			assert(ok)
		}
		font, font_ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
		assert(!font_ok && font.idx == -1)
		assert(len(r.resources.font_faces) == int(limits.fonts))
		for len(r.resources.textures) < int(limits.textures) {
			_, ok := texture_load(r, f.white[:], 1, 1)
			assert(ok)
		}
		texture, texture_ok := texture_load(r, f.white[:], 1, 1)
		assert(!texture_ok && texture.idx == -1)
		assert(len(r.resources.textures) == int(limits.textures))
		assert(!r.stopped)
	}

	@(test)
	integration_submission_failure :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))

		integration_inject(f, .Submit)
		start(&f.renderer, {}, 1)
		assert(!present(&f.renderer) && f.renderer.stopped)
		assert(!present(&f.renderer))
		integration_renderer_destroy(f)
		assert(integration_renderer_init(f))
		start(&f.renderer, {}, 1)
		assert(present(&f.renderer))
	}

	@(test)
	integration_pending_upload_cleanup :: proc(t: ^testing.T) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		r := &f.renderer

		integration_inject(f, .Upload_Wait)
		handle, ok := texture_load(r, f.white[:], 1, 1)
		assert(!ok && handle.idx == -1)
		assert(r.stopped && r.pending_upload.cmd != {})
		assert(len(r.resources.textures) == 1)
		integration_renderer_destroy(f)
		assert(r.pending_upload.cmd == {})
	}

	@(test)
	integration_texture_device_loss :: proc(t: ^testing.T) {
		integration_device_loss_scenario(t, .Shared_Readers_Device_Lost)
	}

	@(test)
	integration_font_device_loss :: proc(t: ^testing.T) {
		integration_device_loss_scenario(t, .Font_Device_Lost)
	}

	integration_font_load :: proc(f: ^Integration_Fixture) -> Font_Face_Handle {
		font, ok := font_load(&f.renderer, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
		assert(ok)
		return font
	}

	integration_present_platform_frames :: proc(f: ^Integration_Fixture, font: Font_Face_Handle) {
		r := &f.renderer
		for _ in 0 ..< 8 {
			glfw.PollEvents()
			start(r, {}, 1)
			begin_screen_mode(r)
			set_scissor(r, -10, 10, 300, 200)
			draw_rect(r, {}, 400, 400, {50, 100, 200, 255})
			clear_scissor(r)
			draw_text(r, font, "Reify platform integration", {40, 40}, 24, {255, 255, 255, 255})
			end_screen_mode(r)
			assert(present(r) && !r.stopped)
			time.sleep(10 * time.Millisecond)
		}
	}

	integration_device_loss_scenario :: proc(t: ^testing.T, failure: Integration_Failure) {
		f := integration_fixture_make(t)
		if f == nil do return
		context = integration_fixture_context(f)
		assert(integration_renderer_init(f))
		r := &f.renderer

		integration_inject(f, failure)
		if failure == .Shared_Readers_Device_Lost {
			handle, ok := texture_load(r, f.white[:], 1, 1)
			assert(!ok && handle.idx == -1)
		} else {
			handle, ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
			assert(!ok && handle.idx == -1)
		}
		assert(r.stopped)
		assert(len(r.resources.textures) == 1 && len(r.resources.font_faces) == 0)
		_, texture_ok := texture_load(r, f.white[:], 1, 1)
		_, font_ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
		assert(!texture_ok && !font_ok)
		start(r, {}, 1)
		draw_rect(r, {}, 1, 1, {})
		assert(!present(r))
	}

	integration_draw_mixed_resources :: proc(f: ^Integration_Fixture) {
		r := &f.renderer
		// Odd row widths and multiple staging chunks exercise copy boundaries.
		width, height := 1025, 1025
		pixels := make([]Color, width * height)
		defer delete(pixels)
		for &pixel, i in pixels {
			pixel = {u8(i % 256), 100, 200, 128}
		}
		large, large_ok := texture_load(r, pixels, width, height)
		assert(large_ok)
		red, red_ok := texture_load(r, []Color{{255, 0, 0, 255}}, 1, 1)
		assert(red_ok)
		green, green_ok := texture_load(r, []Color{{0, 255, 0, 255}}, 1, 1)
		assert(green_ok)
		font, font_ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
		assert(font_ok)

		for _ in 0 ..< 6 {
			glfw.PollEvents()
			start(r, {}, 1)
			begin_screen_mode(r)
			draw_image(r, large, {0, 0}, scale = {0.2, 0.2})
			draw_image(r, red, {220, 0}, scale = {50, 50})
			draw_image(r, green, {280, 0}, scale = {50, 50})
			draw_image(r, red, {280, 0}, scale = {50, 50}, is_additive = true)
			draw_text(r, font, "Mixed textures / MSDF", {40, 240}, 32, {255, 255, 255, 255})
			assert(present(r))
			// Publication waits for the preceding frame's shared-resource readers.
			_, texture_ok := texture_load(r, f.white[:], 1, 1)
			_, next_font_ok := font_load(r, INTEGRATION_FONT_JSON, INTEGRATION_FONT_IMAGE)
			assert(texture_ok && next_font_ok)
		}
	}

	Integration_Fixture :: struct {
		test:                                 ^testing.T,
		white:                                [1]Color,
		renderer:                             Renderer,
		window:                               glfw.WindowHandle,
		glfw_initialized:                     bool,
		zero_framebuffer:                     bool,
		tracker:                              mem.Tracking_Allocator,
		logger:                               log.Logger,
		failure:                              Integration_Failure,
		uploads:                              int,
		wait_pending:                         bool,
		surfaces_created, surfaces_destroyed: int,
		saved_proc:                           vk.ProcGetDeviceProcAddr,
		allocate:                             vk.ProcAllocateMemory,
		map_memory:                           vk.ProcMapMemory,
		image:                                vk.ProcCreateImage,
		buffer:                               vk.ProcCreateBuffer,
		view:                                 vk.ProcCreateImageView,
		end_command:                          vk.ProcEndCommandBuffer,
		submit:                               vk.ProcQueueSubmit,
		wait:                                 vk.ProcWaitForFences,
		idle:                                 vk.ProcDeviceWaitIdle,
	}

	Integration_Failure :: enum {
		None,
		Allocate,
		Map,
		Image,
		View,
		Upload,
		Font_Upload,
		Submit,
		Staging_Fallback,
		Upload_Wait,
		Shared_Readers_Device_Lost,
		Font_Device_Lost,
	}

	INTEGRATION_STAGING_BYTES :: 64 * 1024
	INTEGRATION_FONT_JSON :: #load("assets/fonts/noto-sans-latin-400-normal-msdf.json")
	INTEGRATION_FONT_IMAGE :: #load("assets/fonts/noto-sans-latin-400-normal.png")
	// Vulkan's system-call callbacks have no user-data parameter.
	integration_active_fixture: ^Integration_Fixture

	integration_fixture_make :: proc(t: ^testing.T) -> ^Integration_Fixture {
		// All tests that mutate Vulkan dispatch share this lock.
		sync.mutex_lock(&platform_test_dispatch_mutex)
		assert(integration_active_fixture == nil)
		f := new(Integration_Fixture)
		f.test = t
		f.white = {{255, 255, 255, 255}}
		integration_active_fixture = f
		mem.tracking_allocator_init(&f.tracker, context.allocator)
		testing.cleanup(t, integration_fixture_cleanup, f)
		f.logger = log.create_console_logger(allocator = mem.tracking_allocator(&f.tracker))
		when ODIN_OS == .Linux {
			glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11)
		}
		f.glfw_initialized = bool(glfw.Init())
		if !testing.expect(
			t,
			f.glfw_initialized,
			"Integration tests require a working GLFW display",
		) {
			return nil
		}
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		f.window = glfw.CreateWindow(800, 600, "Reify integration test", nil, nil)
		if !testing.expect(t, f.window != nil, "Integration test window creation failed") {
			return nil
		}
		glfw.SetWindowUserPointer(f.window, f)
		glfw.SetWindowSizeCallback(f.window, integration_window_size)
		return f
	}

	integration_fixture_cleanup :: proc(data: rawptr) {
		f := cast(^Integration_Fixture)data
		defer free(f)
		integration_renderer_destroy(f)
		if f.window != nil {
			glfw.DestroyWindow(f.window)
		}
		if f.glfw_initialized {
			glfw.Terminate()
		}
		integration_active_fixture = nil
		sync.mutex_unlock(&platform_test_dispatch_mutex)
		log.destroy_console_logger(f.logger, mem.tracking_allocator(&f.tracker))
		defer mem.tracking_allocator_destroy(&f.tracker)
		for address, entry in f.tracker.allocation_map {
			fmt.printf("Leaked allocation %p: %v\n", address, entry)
		}
		testing.expect(
			f.test,
			len(f.tracker.allocation_map) == 0,
			"Fixture leaked host allocations",
		)
		testing.expect(
			f.test,
			len(f.tracker.bad_free_array) == 0,
			"Fixture freed invalid allocations",
		)
		testing.expect_value(f.test, f.surfaces_created, f.surfaces_destroyed)
	}

	integration_fixture_context :: proc(f: ^Integration_Fixture) -> runtime.Context {
		ctx := context
		ctx.allocator = mem.tracking_allocator(&f.tracker)
		// Injected failures emit expected error logs, not test-runner failures.
		ctx.logger = f.logger
		return ctx
	}

	integration_renderer_init :: proc(f: ^Integration_Fixture) -> bool {
		context.allocator = mem.tracking_allocator(&f.tracker)
		extensions := glfw.GetRequiredInstanceExtensions()
		assert(len(extensions) > 0)
		return init(
			&f.renderer,
			{
				platform = {
					user_data = f,
					get_framebuffer_size = integration_framebuffer_size,
					vulkan = {
						required_instance_extensions = extensions,
						create_surface = integration_surface_create,
						destroy_surface = integration_surface_destroy,
					},
				},
				logical_size = {800, 600},
				config = {vsync = true},
			},
		)
	}

	integration_renderer_destroy :: proc(f: ^Integration_Fixture) {
		context.allocator = mem.tracking_allocator(&f.tracker)
		// Cleanup uses real waits to conclusively retire submitted GPU work.
		integration_inject(f, .None)
		destroy(&f.renderer)
		testing.expect(
			f.test,
			!f.renderer.loader_owned,
			"Renderer retained Vulkan loader ownership",
		)
	}

	integration_inject :: proc(f: ^Integration_Fixture, failure: Integration_Failure) {
		f.failure = failure
		f.uploads = 0
		f.wait_pending = false
	}

	integration_framebuffer_size :: proc(data: rawptr) -> ([2]int, Platform_Error) {
		f := cast(^Integration_Fixture)data
		if f.zero_framebuffer do return {}, {}
		width, height := glfw.GetFramebufferSize(f.window)
		return {int(width), int(height)}, {}
	}

	integration_window_size :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
		context = runtime.default_context()
		f := cast(^Integration_Fixture)glfw.GetWindowUserPointer(window)
		if !f.renderer.initialized do return
		context = integration_fixture_context(f)
		window_resize(&f.renderer, width, height)
	}

	integration_surface_create :: proc(
		data: rawptr,
		instance: vk.Instance,
	) -> (
		vk.SurfaceKHR,
		Platform_Error,
	) {
		f := cast(^Integration_Fixture)data
		surface: vk.SurfaceKHR
		result := glfw.CreateWindowSurface(instance, f.window, nil, &surface)
		if result != .SUCCESS {
			return {}, {message = "GLFW surface creation failed", result = result}
		}
		f.surfaces_created += 1
		f.saved_proc = vk.GetDeviceProcAddr
		vk.GetDeviceProcAddr = integration_device_proc
		return surface, {}
	}

	integration_surface_destroy :: proc(
		data: rawptr,
		instance: vk.Instance,
		surface: vk.SurfaceKHR,
	) {
		f := cast(^Integration_Fixture)data
		f.surfaces_destroyed += 1
		vk.GetDeviceProcAddr = f.saved_proc
		vk.DestroySurfaceKHR(instance, surface, nil)
	}

	integration_device_proc :: proc "system" (
		device: vk.Device,
		name: cstring,
	) -> vk.ProcVoidFunction {
		context = runtime.default_context()
		f := integration_active_fixture
		p := f.saved_proc(device, name)
		switch string(name) {
		case "vkGetDeviceProcAddr":
			return auto_cast integration_device_proc
		case "vkAllocateMemory":
			f.allocate = auto_cast p
			return auto_cast integration_allocate_memory
		case "vkMapMemory":
			f.map_memory = auto_cast p
			return auto_cast integration_map_memory
		case "vkCreateImage":
			f.image = auto_cast p
			return auto_cast integration_create_image
		case "vkCreateBuffer":
			f.buffer = auto_cast p
			return auto_cast integration_create_buffer
		case "vkCreateImageView":
			f.view = auto_cast p
			return auto_cast integration_create_view
		case "vkEndCommandBuffer":
			f.end_command = auto_cast p
			return auto_cast integration_end_command
		case "vkQueueSubmit":
			f.submit = auto_cast p
			return auto_cast integration_queue_submit
		case "vkWaitForFences":
			f.wait = auto_cast p
			return auto_cast integration_wait_for_fences
		case "vkDeviceWaitIdle":
			f.idle = auto_cast p
			return auto_cast integration_device_wait_idle
		}
		return p
	}

	integration_allocate_memory :: proc "system" (
		device: vk.Device,
		info: ^vk.MemoryAllocateInfo,
		callbacks: ^vk.AllocationCallbacks,
		memory: ^vk.DeviceMemory,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Allocate do return .ERROR_OUT_OF_DEVICE_MEMORY
		return f.allocate(device, info, callbacks, memory)
	}

	integration_map_memory :: proc "system" (
		device: vk.Device,
		memory: vk.DeviceMemory,
		offset, size: vk.DeviceSize,
		flags: vk.MemoryMapFlags,
		data: ^rawptr,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Map do return .ERROR_MEMORY_MAP_FAILED
		return f.map_memory(device, memory, offset, size, flags, data)
	}

	integration_create_image :: proc "system" (
		device: vk.Device,
		info: ^vk.ImageCreateInfo,
		callbacks: ^vk.AllocationCallbacks,
		image: ^vk.Image,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Image do return .ERROR_OUT_OF_DEVICE_MEMORY
		return f.image(device, info, callbacks, image)
	}

	integration_create_view :: proc "system" (
		device: vk.Device,
		info: ^vk.ImageViewCreateInfo,
		callbacks: ^vk.AllocationCallbacks,
		view: ^vk.ImageView,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .View do return .ERROR_OUT_OF_DEVICE_MEMORY
		return f.view(device, info, callbacks, view)
	}

	integration_create_buffer :: proc "system" (
		device: vk.Device,
		info: ^vk.BufferCreateInfo,
		callbacks: ^vk.AllocationCallbacks,
		buffer: ^vk.Buffer,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Staging_Fallback &&
		   .TRANSFER_SRC in info.usage &&
		   info.size > INTEGRATION_STAGING_BYTES {
			return .ERROR_OUT_OF_DEVICE_MEMORY
		}
		return f.buffer(device, info, callbacks, buffer)
	}

	integration_end_command :: proc "system" (cmd: vk.CommandBuffer) -> vk.Result {
		f := integration_active_fixture
		f.uploads += 1
		// Font loading uploads its atlas first, then its font records.
		if f.failure == .Font_Device_Lost && f.uploads == 2 {
			return .ERROR_DEVICE_LOST
		}
		if f.failure == .Upload || (f.failure == .Font_Upload && f.uploads == 2) {
			return .ERROR_OUT_OF_HOST_MEMORY
		}
		return f.end_command(cmd)
	}

	integration_queue_submit :: proc "system" (
		queue: vk.Queue,
		count: u32,
		submits: [^]vk.SubmitInfo,
		fence: vk.Fence,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Submit do return .ERROR_OUT_OF_DEVICE_MEMORY
		result := f.submit(queue, count, submits, fence)
		if result == .SUCCESS && f.failure == .Upload_Wait {
			f.wait_pending = true
		}
		return result
	}

	integration_wait_for_fences :: proc "system" (
		device: vk.Device,
		count: u32,
		fences: [^]vk.Fence,
		wait_all: b32,
		timeout: u64,
	) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Upload_Wait && f.wait_pending {
			return .ERROR_OUT_OF_HOST_MEMORY
		}
		return f.wait(device, count, fences, wait_all, timeout)
	}

	integration_device_wait_idle :: proc "system" (device: vk.Device) -> vk.Result {
		f := integration_active_fixture
		if f.failure == .Shared_Readers_Device_Lost do return .ERROR_DEVICE_LOST
		if f.failure == .Upload_Wait && f.wait_pending {
			return .ERROR_OUT_OF_HOST_MEMORY
		}
		return f.idle(device)
	}
}
