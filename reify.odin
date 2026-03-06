package reify

import "core:fmt"
import "core:log"
import "core:os"
import "core:time"
import pf "../substrate"
import "lib/vma"
import vk "vendor:vulkan"

RENDERER_BACKEND :: string(#config(Renderer_Backend, "vulkan13"))

when RENDERER_BACKEND != "vulkan13" && RENDERER_BACKEND != "sdlgpu" {
	#panic("unsupported Renderer_Backend: expected `vulkan13` or `sdlgpu`")
}

when RENDERER_BACKEND == "sdlgpu" && pf.Current_Platform_Type != .SDL {
	#panic("Renderer_Backend=sdlgpu requires Current_Platform_Type=SDL")
}

Renderer_Perf_Stats :: struct {
	enabled:       bool,
	last_log_time: time.Time,
	frames:        int,
	draw_images:   int,
	draw_rects:    int,
	draw_lines:    int,
	draw_linesets: int,
	draw_texts:    int,
	vertices:      int,
	draw_calls:    int,
	acquire_ms:    f64,
	build_ms:      f64,
	upload_ms:     f64,
	render_ms:     f64,
	submit_ms:     f64,
	present_ms:    f64,
	fps_last_log:  time.Time,
	fps_frames:    int,
	fps_value:     f32,
}

renderer_backend :: proc() -> string {
	return RENDERER_BACKEND
}

vulkan_init :: proc() -> bool {
	when RENDERER_BACKEND == "vulkan13" {
		return vulkan13_vulkan_init()
	}
	return true
}

vulkan_shutdown :: proc() {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_vulkan_shutdown()
	}
}

init :: proc(
	r: ^Renderer,
	platform: ^pf.Platform,
	window_size: [2]int,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) {
	when RENDERER_BACKEND == "vulkan13" {
		required_extensions := pf.vulkan_required_extensions()
		vulkan13_init(
			r,
			window_size,
			required_extensions,
			allocator = allocator,
			temp_allocator = temp_allocator,
		)
		now := time.now()
		r.perf.last_log_time = now
		r.perf.fps_last_log = now
		log.infof(
			"vulkan13 init: renderer initialized window=%dx%d vk_exts=%d",
			window_size[0],
			window_size[1],
			len(required_extensions),
		)
	} else {
		sdlgpu_init(&r.sdlgpu, platform, window_size)
	}
}

set_vsync :: proc(r: ^Renderer, enabled: bool) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_set_vsync(r, enabled)
	} else {
		sdlgpu_set_vsync(&r.sdlgpu, enabled)
	}
}

set_perf_logging :: proc(r: ^Renderer, enabled: bool) {
	when RENDERER_BACKEND == "vulkan13" {
		r.perf.enabled = enabled
	} else {
		sdlgpu_set_perf_logging(&r.sdlgpu, enabled)
	}
}

vk_instance :: proc(r: ^Renderer) -> vk.Instance {
	when RENDERER_BACKEND == "vulkan13" {
		return r.gpu.instance
	}
	return sdlgpu_vk_instance(&r.sdlgpu)
}

set_surface :: proc(r: ^Renderer, surface: vk.SurfaceKHR) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_set_surface(r, surface)
	} else {
		sdlgpu_set_vk_surface(&r.sdlgpu, surface)
	}
}

font_load :: proc(
	r: ^Renderer,
	font_json: []byte,
	font_msdf: []byte,
) -> (
	Font_Face_Handle,
	bool,
) {
	when RENDERER_BACKEND == "vulkan13" {
		font, err := vulkan13_font_load(r, font_json, font_msdf)
		if err != nil {
			log.errorf("vulkan13 font_load failed: %v", err)
			return {}, false
		}
		return font, true
	}
	return sdlgpu_font_load(&r.sdlgpu, font_json, font_msdf)
}

start :: proc(r: ^Renderer, cam_pos: [2]f32, cam_zoom: f32) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_start(r, cam_pos, cam_zoom)
	} else {
		sdlgpu_start(&r.sdlgpu, cam_pos, cam_zoom)
	}
}

begin_screen_mode :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_begin_screen_mode(r)
	} else {
		sdlgpu_begin_screen_mode(&r.sdlgpu)
	}
}

end_screen_mode :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_end_screen_mode(r)
	} else {
		sdlgpu_end_screen_mode(&r.sdlgpu)
	}
}

draw_fps :: proc(r: ^Renderer, font: Font_Face_Handle, pos: [2]f32, size: int) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_fps(r, font, pos, size)
	} else {
		sdlgpu_draw_fps(&r.sdlgpu, font, pos, size)
	}
}

present :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		present_start := time.now()
		vulkan13_present(r, {0, 0, 0, 255})
		present_end := time.now()

		r.perf.fps_frames += 1
		fps_elapsed := time.diff(r.perf.fps_last_log, present_end)
		if fps_elapsed >= time.Second {
			secs := f32(fps_elapsed) / f32(time.Second)
			if secs > 0 {
				r.perf.fps_value = f32(r.perf.fps_frames) / secs
			}
			if r.perf.enabled {
				log.infof("fps: %.1f", r.perf.fps_value)
			}
			r.perf.fps_frames = 0
			r.perf.fps_last_log = present_end
		}

		if !r.perf.enabled {
			return
		}

		r.perf.frames += 1
		r.perf.present_ms += f64(time.duration_milliseconds(time.diff(present_start, present_end)))
		elapsed := time.diff(r.perf.last_log_time, present_end)
		if elapsed >= time.Second {
			frames := r.perf.frames
			if frames <= 0 {
				frames = 1
			}
			log.infof(
				"vulkan13 perf: imgs/frame=%.1f rects/frame=%.1f lines/frame=%.1f linesets/frame=%.1f texts/frame=%.1f present=%.2fms",
				f64(r.perf.draw_images) / f64(frames),
				f64(r.perf.draw_rects) / f64(frames),
				f64(r.perf.draw_lines) / f64(frames),
				f64(r.perf.draw_linesets) / f64(frames),
				f64(r.perf.draw_texts) / f64(frames),
				r.perf.present_ms / f64(frames),
			)
			r.perf.last_log_time = present_end
			r.perf.frames = 0
			r.perf.draw_images = 0
			r.perf.draw_rects = 0
			r.perf.draw_lines = 0
			r.perf.draw_linesets = 0
			r.perf.draw_texts = 0
			r.perf.present_ms = 0
		}
	} else {
		sdlgpu_present(&r.sdlgpu)
	}
}

destroy :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_destroy(r)
	} else {
		sdlgpu_destroy(&r.sdlgpu)
	}
}

window_size :: proc(r: ^Renderer) -> (w, h: f32) {
	when RENDERER_BACKEND == "vulkan13" {
		return f32(r.window.width), f32(r.window.height)
	}
	return sdlgpu_window_size(&r.sdlgpu)
}

measure_text_width :: proc(r: ^Renderer, font: Font_Face_Handle, text: string, size: int) -> f32 {
	when RENDERER_BACKEND == "vulkan13" {
		metrics := vulkan13_measure_text(r, font, text, size)
		return metrics.text_rect.w
	}
	return sdlgpu_measure_text_width(&r.sdlgpu, font, text, size)
}

set_scissor :: proc(r: ^Renderer, x, y: i32, w, h: u32) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_set_scissor(r, x, y, w, h)
	} else {
		sdlgpu_set_scissor(&r.sdlgpu, x, y, w, h)
	}
}

clear_scissor :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_clear_scissor(r)
	} else {
		sdlgpu_clear_scissor(&r.sdlgpu)
	}
}

draw_rect :: proc(r: ^Renderer, pos: [2]f32, w, h: f32, color: Color) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_rects += 1
		}
		vulkan13_draw_rect(r, pos, w, h, color)
	} else {
		sdlgpu_draw_rect(&r.sdlgpu, pos, w, h, color)
	}
}

draw_triangle :: proc(r: ^Renderer, p1, p2, p3: [2]f32, color: Color) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_rects += 1
		}
		vulkan13_draw_triangle(r, p1, p2, p3, color)
	} else {
		sdlgpu_draw_triangle(&r.sdlgpu, p1, p2, p3, color)
	}
}

draw_circle :: proc(r: ^Renderer, position: [2]f32, radius: f32, color: Color) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_rects += 1
		}
		vulkan13_draw_circle(r, position, radius, color)
	} else {
		sdlgpu_draw_circle(&r.sdlgpu, position, radius, color)
	}
}

draw_line :: proc(r: ^Renderer, from, to: [2]f32, thickness: int, color: Color) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_lines += 1
		}
		vulkan13_draw_line(r, from, to, thickness, color)
	} else {
		sdlgpu_draw_line(&r.sdlgpu, from, to, thickness, color)
	}
}

draw_lines :: proc(
	r: ^Renderer,
	thickness: int,
	color: Color,
	closed: bool,
	rounded: bool,
	points: [][2]f32,
) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_linesets += 1
		}
		if len(points) < 2 || thickness <= 0 {
			return
		}
		for i in 0 ..< len(points) - 1 {
			vulkan13_draw_line(r, points[i], points[i + 1], thickness, color, rounded)
		}
		if closed {
			vulkan13_draw_line(r, points[len(points) - 1], points[0], thickness, color, rounded)
		}
	} else {
		sdlgpu_draw_lines(&r.sdlgpu, thickness, color, closed, rounded, points)
	}
}

draw_text :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	text: string,
	pos: [2]f32,
	size: int,
	color: Color,
) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_texts += 1
		}
		vulkan13_draw_text(r, font, text, pos, size, color)
	} else {
		sdlgpu_draw_text(&r.sdlgpu, font, text, pos, size, color)
	}
}

draw_image :: proc(
	r: ^Renderer,
	texture: Texture_Handle,
	position: [2]f32,
	scale: [2]f32 = {1, 1},
	rotation: f32 = 0,
	uv_rect: Rect = FULL_UV,
) {
	when RENDERER_BACKEND == "vulkan13" {
		if r.perf.enabled {
			r.perf.draw_images += 1
		}
		vulkan13_draw_image(r, texture, position, rotation = rotation, scale = scale, uv_rect = uv_rect)
	} else {
		sdlgpu_draw_image(&r.sdlgpu, texture, position, scale, rotation, uv_rect)
	}
}

texture_load :: proc(
	r: ^Renderer,
	pixels: []Color,
	width, height: int,
) -> (
	Texture_Handle,
	bool,
) {
	when RENDERER_BACKEND == "vulkan13" {
		return vulkan13_texture_load(r, pixels, width, height), true
	}
	return sdlgpu_texture_load(&r.sdlgpu, pixels, width, height)
}

texture_get_metrics :: proc(
	r: ^Renderer,
	handle: Texture_Handle,
) -> (
	Texture_Metrics,
	bool,
) {
	when RENDERER_BACKEND == "vulkan13" {
		return vulkan13_texture_get_metrics(r, handle)
	}
	return sdlgpu_texture_get_metrics(&r.sdlgpu, handle)
}

vulkan13_debug_capture_ppm :: proc(r: ^Renderer, path: string) -> bool {
	if r == nil {
		return false
	}
	image_count := len(r.swapchain.images)
	if image_count <= 0 {
		log.error("vulkan13 debug capture failed: no swapchain images")
		return false
	}
	width := int(r.swapchain.create_info.imageExtent.width)
	height := int(r.swapchain.create_info.imageExtent.height)
	if width <= 0 || height <= 0 {
		log.errorf("vulkan13 debug capture invalid extent: %dx%d", width, height)
		return false
	}
	bytes_needed := width * height * 4

	if vk.DeviceWaitIdle(r.gpu.device) != .SUCCESS {
		log.error("vulkan13 debug capture: vkDeviceWaitIdle failed")
		return false
	}

	staging_buf_info := vk.BufferCreateInfo{
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(bytes_needed),
		usage       = {.TRANSFER_DST},
		sharingMode = .EXCLUSIVE,
	}
	staging_alloc_info := vma.Allocation_Create_Info{
		usage = .Gpu_To_Cpu,
		flags = {.Host_Access_Sequential_Write, .Mapped},
	}
	staging_buf: vk.Buffer
	staging_alloc: vma.Allocation
	vma_info: vma.Allocation_Info
	if vma.create_buffer(
		r.gpu.allocator,
		staging_buf_info,
		staging_alloc_info,
		&staging_buf,
		&staging_alloc,
		&vma_info,
	) != .SUCCESS {
		log.error("vulkan13 debug capture failed: could not create staging buffer")
		return false
	}
	defer vma.destroy_buffer(r.gpu.allocator, staging_buf, staging_alloc)

	if vma_info.mapped_data == nil {
		log.error("vulkan13 debug capture failed: staging buffer not mapped")
		return false
	}
	mapped_rgba := ([^]u8)(vma_info.mapped_data)[:bytes_needed]
	best_rgba := make([]u8, bytes_needed)
	best_score := -1

	vk_assert_local := proc(res: vk.Result) -> bool {
		if res == .SUCCESS {
			return true
		}
		log.errorf("vulkan13 debug capture vk call failed: %v", res)
		return false
	}

	for i in 0 ..< image_count {
		cmd: vk.CommandBuffer
		cmd_alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = r.command_pool, commandBufferCount = 1}
		if !vk_assert_local(vk.AllocateCommandBuffers(r.gpu.device, &cmd_alloc, &cmd)) {
			return false
		}
		fence: vk.Fence
		fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO}
		if !vk_assert_local(vk.CreateFence(r.gpu.device, &fence_info, nil, &fence)) {
			vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &cmd)
			return false
		}
		begin_info := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
		if !vk_assert_local(vk.BeginCommandBuffer(cmd, &begin_info)) {
			vk.DestroyFence(r.gpu.device, fence, nil)
			vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &cmd)
			return false
		}
		to_transfer := vk.ImageMemoryBarrier2{
			sType = .IMAGE_MEMORY_BARRIER_2, srcStageMask = {.TOP_OF_PIPE}, dstStageMask = {.TRANSFER}, dstAccessMask = {.TRANSFER_READ},
			oldLayout = .PRESENT_SRC_KHR, newLayout = .TRANSFER_SRC_OPTIMAL, image = r.swapchain.images[i],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		dep_a := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &to_transfer}
		vk.CmdPipelineBarrier2(cmd, &dep_a)
		copy_region := vk.BufferImageCopy{
			imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
			imageExtent      = {width = u32(width), height = u32(height), depth = 1},
		}
		vk.CmdCopyImageToBuffer(cmd, r.swapchain.images[i], .TRANSFER_SRC_OPTIMAL, staging_buf, 1, &copy_region)
		to_present := vk.ImageMemoryBarrier2{
			sType = .IMAGE_MEMORY_BARRIER_2, srcStageMask = {.TRANSFER}, srcAccessMask = {.TRANSFER_READ},
			dstStageMask = {.TOP_OF_PIPE}, oldLayout = .TRANSFER_SRC_OPTIMAL, newLayout = .PRESENT_SRC_KHR,
			image = r.swapchain.images[i], subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		dep_b := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &to_present}
		vk.CmdPipelineBarrier2(cmd, &dep_b)
		if !vk_assert_local(vk.EndCommandBuffer(cmd)) {
			vk.DestroyFence(r.gpu.device, fence, nil)
			vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &cmd)
			return false
		}
		submit := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &cmd}
		if !vk_assert_local(vk.QueueSubmit(r.gpu.queue, 1, &submit, fence)) {
			vk.DestroyFence(r.gpu.device, fence, nil)
			vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &cmd)
			return false
		}
		if !vk_assert_local(vk.WaitForFences(r.gpu.device, 1, &fence, true, max(u64))) {
			vk.DestroyFence(r.gpu.device, fence, nil)
			vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &cmd)
			return false
		}
		vk.DestroyFence(r.gpu.device, fence, nil)
		vk.FreeCommandBuffers(r.gpu.device, r.command_pool, 1, &cmd)

		score := 0
		for pi in 0 ..< bytes_needed {
			if pi % 4 != 0 {
				continue
			}
			if mapped_rgba[pi + 0] != 0 || mapped_rgba[pi + 1] != 0 || mapped_rgba[pi + 2] != 0 {
				score += 1
			}
		}
		if score > best_score {
			best_score = score
			copy(best_rgba, mapped_rgba)
		}
	}

	bgra :=
		r.swapchain.create_info.imageFormat == .B8G8R8A8_UNORM ||
		r.swapchain.create_info.imageFormat == .B8G8R8A8_SRGB
	return renderer_capture_write_ppm(path, best_rgba, width, height, bgra_order = bgra, flip_y = false)
}

renderer_capture_ensure_parent_dir :: proc(path: string) -> bool {
	dir, _ := os.split_path(path)
	if len(dir) == 0 {
		return true
	}
	if err := os.make_directory_all(dir); err != nil && err != os.General_Error.Exist {
		log.errorf("failed to create capture dir `%s`: %v", dir, err)
		return false
	}
	return true
}

renderer_capture_write_ppm :: proc(
	path: string,
	raw_rgba: []u8,
	width, height: int,
	bgra_order: bool,
	flip_y: bool,
) -> bool {
	if width <= 0 || height <= 0 {
		log.errorf("invalid capture dimensions: %dx%d", width, height)
		return false
	}
	expected := width * height * 4
	if len(raw_rgba) < expected {
		log.errorf("capture buffer too small: got=%d expected=%d", len(raw_rgba), expected)
		return false
	}
	if !renderer_capture_ensure_parent_dir(path) {
		return false
	}

	header := fmt.tprintf("P6\n%d %d\n255\n", width, height)
	out := make([]u8, len(header) + width * height * 3)
	copy(out[:len(header)], transmute([]u8)header)
	dst_idx := len(header)
	for y in 0 ..< height {
		src_y := y
		if flip_y {
			src_y = height - 1 - y
		}
		row_base := src_y * width * 4
		for x in 0 ..< width {
			si := row_base + x * 4
			r := raw_rgba[si + 0]
			g := raw_rgba[si + 1]
			b := raw_rgba[si + 2]
			if bgra_order {
				r = raw_rgba[si + 2]
				g = raw_rgba[si + 1]
				b = raw_rgba[si + 0]
			}
			out[dst_idx + 0] = r
			out[dst_idx + 1] = g
			out[dst_idx + 2] = b
			dst_idx += 3
		}
	}
	if err := os.write_entire_file(path, out); err != nil {
		log.errorf("failed to write capture `%s`: %v", path, err)
		return false
	}
	return true
}
