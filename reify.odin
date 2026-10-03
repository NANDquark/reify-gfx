package reify

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"
import vk "vendor:vulkan"

RENDERER_BACKEND :: string(#config(Renderer_Backend, "vulkan13"))

when RENDERER_BACKEND != "vulkan13" && RENDERER_BACKEND != "vulkan11" {
	#panic("unsupported Renderer_Backend: use `vulkan13` or `vulkan11`")
}

renderer_backend :: proc() -> string {
	return RENDERER_BACKEND
}

Renderer :: struct {
	allocator:        mem.Allocator,
	platform:         Platform_Interface,
	initialized:      bool,
	loader_owned:     bool,
	stopped:          bool,
	frame_failed:     bool,
	frame_started:    bool,
	framebuffer_size: [2]int,
	window:           struct {
		width:      i32,
		height:     i32,
		projection: Mat4f,
	},
	perf:             Renderer_Perf_Stats,
	using backend:    Renderer_Backend_State,
}

when RENDERER_BACKEND == "vulkan13" {
	@(private)
	Renderer_Backend_State :: Vulkan13_Renderer_State
} else when RENDERER_BACKEND == "vulkan11" {
	@(private)
	Renderer_Backend_State :: Vulkan11_Renderer_State
}

Mat4f :: matrix[4, 4]f32

Color :: [4]u8

Rect :: struct {
	x, y, w, h: f32,
}

FULL_UV :: Rect {
	x = 0,
	y = 0,
	w = 1,
	h = 1,
}

Texture_Handle :: struct {
	idx: int,
}

Texture_Metrics :: struct {
	width, height: int,
}

Font_Face_Handle :: struct {
	idx: int,
}

@(require_results)
init :: proc(r: ^Renderer, info: Renderer_Init_Info) -> bool {
	init_error := renderer_init(r, info)
	if init_error.category != .None {
		renderer_log_error(init_error)
		return false
	}
	return true
}

@(private)
renderer_init :: proc(r: ^Renderer, info: Renderer_Init_Info) -> Renderer_Error {
	if r == nil {
		return renderer_error(.Platform, .Invalid_State, "renderer pointer is nil")
	}
	p := info.platform
	if p.get_framebuffer_size == nil ||
	   p.vulkan.create_surface == nil ||
	   p.vulkan.destroy_surface == nil {
		return renderer_error(
			.Platform,
			.Missing_Capability,
			"framebuffer size and all Vulkan surface callbacks are required",
		)
	}
	if info.logical_size.x < 0 ||
	   info.logical_size.y < 0 ||
	   info.logical_size.x > int(max(i32)) ||
	   info.logical_size.y > int(max(i32)) {
		return renderer_error(
			.Platform,
			.Invalid_State,
			"logical dimensions must fit nonnegative i32",
		)
	}
	_, reserved := sync.atomic_compare_exchange_strong(&active_renderer, cast(^Renderer)nil, r)
	if !reserved {
		return renderer_error(.Platform, .Invalid_State, "only one active renderer is supported")
	}
	success := false
	defer {
		if !success {
			renderer_cleanup(r)
		}
	}
	r^ = {}
	r.allocator = info.allocator
	if r.allocator.procedure == nil do r.allocator = context.allocator
	context.allocator = r.allocator
	if info.temp_allocator.procedure != nil do context.temp_allocator = info.temp_allocator
	r.platform = p
	r.platform.vulkan.required_instance_extensions = nil
	if !renderer_loader_init() {
		return renderer_error(.Loader, .Vulkan_Failure, "Vulkan loader unavailable")
	}
	r.loader_owned = true
	r.window.width, r.window.height = i32(info.logical_size.x), i32(info.logical_size.y)
	backend_error: Renderer_Error
	when RENDERER_BACKEND == "vulkan13" {
		backend_error = vulkan13_init(r, info)
	} else when RENDERER_BACKEND == "vulkan11" {
		backend_error = vulkan11_init(r, info)
	}
	if backend_error.category != .None do return backend_error
	r.initialized = true
	now := time.now()
	r.perf.last_log_time, r.perf.fps_last_log = now, now
	success = true
	return {}
}

set_vsync :: proc(r: ^Renderer, enabled: bool) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_set_vsync(r, enabled)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_set_vsync(r, enabled)
	}
}

set_perf_logging :: proc(r: ^Renderer, enabled: bool) {
	r.perf.enabled = enabled
}

@(require_results)
font_load :: proc(r: ^Renderer, font_json: []byte, font_msdf: []byte) -> (Font_Face_Handle, bool) {
	if r == nil || !r.initialized {
		log.error("reify font_load: renderer is not initialized")
		return {idx = -1}, false
	}

	font: Font_Face_Handle
	err: Font_Atlas_Error
	when RENDERER_BACKEND == "vulkan13" {
		font, err = vulkan13_font_load(r, font_json, font_msdf)
	} else when RENDERER_BACKEND == "vulkan11" {
		font, err = vulkan11_font_load(r, font_json, font_msdf)
	}
	if err != nil {
		gpu_err, ok := err.(Renderer_Error)
		if ok {
			renderer_log_error(gpu_err)
		} else {
			log.errorf("reify font_load: %v", err)
		}
		return {idx = -1}, false
	}
	return font, true
}

start :: proc(r: ^Renderer, cam_pos: [2]f32, cam_zoom: f32) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_start(r, cam_pos, cam_zoom)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_start(r, cam_pos, cam_zoom)
	}
}

begin_screen_mode :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_begin_screen_mode(r)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_begin_screen_mode(r)
	}
}

end_screen_mode :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_end_screen_mode(r)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_end_screen_mode(r)
	}
}

@(require_results)
present :: proc(r: ^Renderer) -> bool {
	if r != nil && r.initialized && r.frame_failed && !r.stopped {
		r.frame_started = false
		return false
	}
	present_start := time.now()
	err: Renderer_Error
	when RENDERER_BACKEND == "vulkan13" {
		err = vulkan13_present(r, {0, 0, 0, 255})
	} else when RENDERER_BACKEND == "vulkan11" {
		err = vulkan11_present(r, {0, 0, 0, 255})
	}
	if err.category != .None {
		renderer_log_error(err)
		return false
	}
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

	if !r.perf.enabled do return true
	r.perf.frames += 1
	r.perf.present_ms += f64(time.duration_milliseconds(time.diff(present_start, present_end)))
	elapsed := time.diff(r.perf.last_log_time, present_end)
	if elapsed >= time.Second {
		frames := max(1, r.perf.frames)
		log.infof(
			"%s perf: imgs/frame=%.1f rects/frame=%.1f lines/frame=%.1f linesets/frame=%.1f texts/frame=%.1f draws/frame=%.1f present=%.2fms",
			RENDERER_BACKEND,
			f64(r.perf.draw_images) / f64(frames),
			f64(r.perf.draw_rects) / f64(frames),
			f64(r.perf.draw_lines) / f64(frames),
			f64(r.perf.draw_linesets) / f64(frames),
			f64(r.perf.draw_texts) / f64(frames),
			f64(r.perf.draw_calls) / f64(frames),
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
		r.perf.draw_calls = 0
	}
	return true
}

destroy :: proc(r: ^Renderer) {
	if r == nil do return
	r.stopped = true
	if !r.loader_owned do return
	renderer_cleanup(r)
}

@(private)
renderer_cleanup :: proc(r: ^Renderer) {
	if r.loader_owned {
		when RENDERER_BACKEND == "vulkan13" {
			vulkan13_destroy(r)
		} else when RENDERER_BACKEND == "vulkan11" {
			vulkan11_destroy(r)
		}
		renderer_loader_shutdown()
	}
	r^ = {}
	sync.atomic_store(&active_renderer, cast(^Renderer)nil)
}

@(private)
// Non-owning reservation: the caller owns Renderer storage. Global Vulkan dispatch
// and loader state permit only one active renderer per process.
active_renderer: ^Renderer

@(private)
vulkan_lib: dynlib.Library

renderer_loader_init :: proc() -> bool {
	libs: []string
	when ODIN_OS == .Windows {
		libs = []string{"vulkan-1.dll"}
	} else when ODIN_OS == .Linux {
		libs = []string{"libvulkan.so.1", "libvulkan.so"}
	} else {
		return false
	}

	for name in libs {
		lib, ok := dynlib.load_library(name)
		if !ok do continue
		sym, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
		if !found {
			dynlib.unload_library(lib)
			continue
		}
		vulkan_lib = lib
		get_instance_proc_address: vk.ProcGetInstanceProcAddr = auto_cast sym
		vk.load_proc_addresses((rawptr)(get_instance_proc_address))
		if vk.CreateInstance == nil ||
		   vk.EnumerateInstanceExtensionProperties == nil ||
		   vk.EnumerateInstanceLayerProperties == nil {
			dynlib.unload_library(lib)
			vulkan_lib = {}
			continue
		}
		return true
	}
	return false
}

renderer_loader_shutdown :: proc() {
	dynlib.unload_library(vulkan_lib)
	vulkan_lib = {}
}

window_size :: proc(r: ^Renderer) -> (w, h: f32) {
	return f32(r.window.width), f32(r.window.height)
}

window_resize :: proc(r: ^Renderer, width, height: i32) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_window_resize(r, width, height)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_window_resize(r, width, height)
	}
}

measure_text_width :: proc(r: ^Renderer, font: Font_Face_Handle, text: string, size: int) -> f32 {
	metrics: Font_Metrics
	when RENDERER_BACKEND == "vulkan13" {
		metrics = vulkan13_measure_text(r, font, text, size)
	} else when RENDERER_BACKEND == "vulkan11" {
		metrics = vulkan11_measure_text(r, font, text, size)
	}
	return metrics.text_rect.w
}

set_scissor :: proc(r: ^Renderer, x, y: i32, w, h: u32) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_set_scissor(r, x, y, w, h)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_set_scissor(r, x, y, w, h)
	}
}

clear_scissor :: proc(r: ^Renderer) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_clear_scissor(r)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_clear_scissor(r)
	}
}

@(require_results)
texture_load :: proc(r: ^Renderer, pixels: []Color, width, height: int) -> (Texture_Handle, bool) {
	if r == nil || !r.initialized {
		log.error("reify texture_load: renderer is not initialized")
		return {idx = -1}, false
	}

	handle: Texture_Handle
	err: Renderer_Error
	when RENDERER_BACKEND == "vulkan13" {
		handle, err = vulkan13_texture_load(r, pixels, width, height)
	} else when RENDERER_BACKEND == "vulkan11" {
		handle, err = vulkan11_texture_load(r, pixels, width, height)
	}
	if err.category != .None {
		renderer_log_error(err)
		return handle, false
	}
	return handle, true
}

texture_get_metrics :: proc(r: ^Renderer, handle: Texture_Handle) -> (Texture_Metrics, bool) {
	if r == nil || !r.initialized do return {}, false
	when RENDERER_BACKEND == "vulkan13" {
		return vulkan13_texture_get_metrics(r, handle)
	} else when RENDERER_BACKEND == "vulkan11" {
		return vulkan11_texture_get_metrics(r, handle)
	}
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

renderer_capture_ensure_parent_dir :: proc(path: string) -> bool {
	dir, _ := os.split_path(path)
	if len(dir) == 0 {
		return true
	}
	directory_error := os.make_directory_all(dir)
	if directory_error != nil && directory_error != os.General_Error.Exist {
		log.errorf("failed to create capture dir `%s`: %v", dir, directory_error)
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
	defer delete(out)
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
	write_error := os.write_entire_file(path, out)
	if write_error != nil {
		log.errorf("failed to write capture `%s`: %v", path, write_error)
		return false
	}
	return true
}
