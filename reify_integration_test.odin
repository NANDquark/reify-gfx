package reify

import "base:runtime"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

when bool(#config(Reify_Integration_Test, false)) {
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
