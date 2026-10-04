package reify

import "core:dynlib"
import "core:encoding/json"
import "core:fmt"
import "core:image"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:sync"
import "core:time"
import vk "vendor:vulkan"

// RENDERER_BACKEND_STR_DEFAULT :: "vulkan11"
RENDERER_BACKEND_STR_DEFAULT :: "vulkan13"
RENDERER_BACKEND_STR :: string(#config(Renderer_Backend, RENDERER_BACKEND_STR_DEFAULT))

Renderer_Backend_Type :: enum {
	Unknown,
	Vulkan_1_1,
	Vulkan_1_3,
}

when RENDERER_BACKEND_STR == "vulkan11" {
	RENDERER_BACKEND_TYPE :: Renderer_Backend_Type.Vulkan_1_1
} else when RENDERER_BACKEND_STR == "vulkan13" {
	RENDERER_BACKEND_TYPE :: Renderer_Backend_Type.Vulkan_1_3
} else {
	#panic("unsupported Renderer_Backend")
}

Renderer :: struct {
	allocator:           mem.Allocator,
	backend_type:        Renderer_Backend_Type,
	resources_allocator: mem.Allocator,
	platform:            Platform_Interface,
	initialized:         bool,
	loader_owned:        bool,
	stopped:             bool,
	frame_failed:        bool,
	frame_started:       bool,
	last_error:          Renderer_Error,
	framebuffer_size:    [2]int,
	window:              struct {
		width:      i32,
		height:     i32,
		projection: Mat4f,
	},
	perf:                Renderer_Perf_Stats,
}

Renderer_Backend_Interface :: struct {
	init:                proc(r: ^Renderer, info: Renderer_Init_Info) -> Renderer_Error,
	destroy:             proc(r: ^Renderer),
	set_vsync:           type_of(set_vsync),
	start:               type_of(start),
	begin_screen_mode:   type_of(begin_screen_mode),
	end_screen_mode:     type_of(end_screen_mode),
	present:             type_of(present),
	window_resize:       type_of(window_resize),
	font_load:           type_of(font_load),
	texture_load:        type_of(texture_load),
	texture_get_metrics: type_of(texture_get_metrics),
	measure_text:        type_of(measure_text),
	set_scissor:         type_of(set_scissor),
	clear_scissor:       type_of(clear_scissor),
	draw_rect:           type_of(draw_rect),
	draw_triangle:       type_of(draw_triangle),
	draw_circle:         type_of(draw_circle),
	draw_line:           type_of(draw_line),
	draw_text:           type_of(draw_text),
	draw_fps:            type_of(draw_fps),
	draw_image:          type_of(draw_image),
	effective_limits:    type_of(effective_limits),
	memory_summary:      type_of(memory_summary),
	debug_capture_ppm:   type_of(debug_capture_ppm),
}

Mat4f :: matrix[4, 4]f32

Color :: [4]u8

Rect :: struct {
	x, y, w, h: f32,
}

renderer_new :: proc(
	info: Renderer_Init_Info,
	allocator: mem.Allocator = context.allocator,
) -> (
	^Renderer,
	bool,
) {
	if context.logger.procedure == nil || context.logger.procedure == log.nil_logger_proc {
		fmt.println(
			"reify: no active context.logger is configured; this library uses the context logger for diagnostics. Set context.logger to receive logs.",
		)
	}

	r: ^Renderer
	log.infof("Renderer_Backend: %v", RENDERER_BACKEND_TYPE)
	when RENDERER_BACKEND_TYPE == .Vulkan_1_1 {
		r = new(Vulkan11_Renderer, allocator)
	} else when RENDERER_BACKEND_TYPE == .Vulkan_1_3 {
		r = new(Vulkan13_Rendererer, allocator)
	} else {
		#panic("invalid Renderer_Backend")
	}
	if r == nil {
		log.error("reify: renderer storage allocation failed")
		return nil, false
	}
	r.allocator = allocator

	r.last_error = renderer_init(r, RENDERER_BACKEND_TYPE, info)
	if r.last_error.category != .None {
		renderer_log_error(r)
		renderer_free(r)
		return nil, false
	}
	return r, true
}

renderer_get_backend :: #force_inline proc(r: ^Renderer) -> Renderer_Backend_Interface {
	switch r.backend_type {
	case .Unknown:
		panic("unknown Renderer_Backend")
	case .Vulkan_1_1:
		return VULKAN11_RENDERER_BACKEND
	case .Vulkan_1_3:
		return VULKAN13_RENDERER_BACKEND
	}
	unreachable()
}

renderer_free :: proc(r: ^Renderer) {
	if r == nil do return
	context.allocator = r.allocator
	renderer_destroy(r)
	free(r)
}

@(private)
renderer_init :: proc(
	r: ^Renderer,
	type: Renderer_Backend_Type,
	info: Renderer_Init_Info,
) -> Renderer_Error {
	if r == nil {
		return renderer_error(.Platform, .Invalid_State, "renderer pointer is nil")
	}
	r.backend_type = type
	backend := renderer_get_backend(r)
	if backend.init == nil || backend.destroy == nil {
		return renderer_error(
			.Platform,
			.Invalid_State,
			"renderer storage must be allocated with renderer_new",
		)
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
	defer if !success {
		renderer_cleanup(r)
	}

	r.resources_allocator = info.resources_allocator
	if r.resources_allocator.procedure == nil do r.resources_allocator = context.allocator
	context.allocator = r.resources_allocator
	if info.temp_allocator.procedure != nil do context.temp_allocator = info.temp_allocator

	r.platform = p
	r.platform.vulkan.required_instance_extensions = nil

	if !loader_init() {
		return renderer_error(.Loader, .Vulkan_Failure, "Vulkan loader unavailable")
	}
	r.loader_owned = true

	r.window.width, r.window.height = i32(info.logical_size.x), i32(info.logical_size.y)

	backend_error := backend.init(r, info)
	if backend_error.category != .None do return backend_error

	r.initialized = true
	now := time.now()
	r.perf.last_log_time, r.perf.fps_last_log = now, now
	success = true

	return {}
}

@(private)
renderer_destroy :: proc(r: ^Renderer) {
	if r == nil do return
	r.stopped = true
	if !r.loader_owned do return
	renderer_cleanup(r)
}

@(private)
renderer_cleanup :: proc(r: ^Renderer) {
	allocator := r.allocator
	backend := renderer_get_backend(r)
	if r.loader_owned {
		backend.destroy(r)
		loader_shutdown()
	}
	r^ = {
		allocator = allocator,
	}
	sync.atomic_store(&active_renderer, cast(^Renderer)nil)
}

@(private)
// Non-owning reservation: the caller manages the renderer_new/renderer_free lifetime. Global Vulkan dispatch
// and loader state permit only one active renderer per process.
active_renderer: ^Renderer

@(private)
vulkan_lib: dynlib.Library

@(private)
loader_init :: proc() -> bool {
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

@(private)
loader_shutdown :: proc() {
	dynlib.unload_library(vulkan_lib)
	vulkan_lib = {}
}

set_vsync :: proc(r: ^Renderer, enabled: bool) {
	renderer_get_backend(r).set_vsync(r, enabled)
}

set_perf_logging :: proc(r: ^Renderer, enabled: bool) {
	r.perf.enabled = enabled
}

start :: proc(r: ^Renderer, cam_pos: [2]f32, cam_zoom: f32) {
	if r == nil do return
	backend := renderer_get_backend(r)
	backend.start(r, cam_pos, cam_zoom)
}

begin_screen_mode :: proc(r: ^Renderer) {
	if r == nil do return
	backend := renderer_get_backend(r)
	backend.begin_screen_mode(r)
}

end_screen_mode :: proc(r: ^Renderer) {
	if r == nil do return
	backend := renderer_get_backend(r)
	backend.end_screen_mode(r)
}

@(require_results)
present :: proc(r: ^Renderer, clear := Color{0, 0, 0, 255}) -> bool {
	if r == nil do return false
	if !r.initialized {
		r.last_error = renderer_error(.Presentation, .Invalid_State, "renderer is not initialized")
		renderer_log_error(r)
		return false
	}
	if r != nil && r.initialized && r.frame_failed && !r.stopped {
		r.frame_started = false
		return false
	}
	present_start := time.now()
	backend := renderer_get_backend(r)
	if !backend.present(r, clear) {
		renderer_log_error(r)
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
			renderer_get_backend(r),
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

Font_Face_Handle :: struct {
	idx: int,
}

@(require_results)
font_load :: proc(
	r: ^Renderer,
	font_json: []byte,
	font_msdf: []byte,
) -> (
	Font_Face_Handle,
	Font_Atlas_Error,
) {
	if r == nil || !r.initialized {
		log.error("reify font_load: renderer is not initialized")
		return {
			idx = -1,
		}, renderer_error(.Platform, .Platform_Failure, "Renderer not initialized", .Initialization_Failed)
	}

	backend := renderer_get_backend(r)
	return backend.font_load(r, font_json, font_msdf)
}

window_size :: proc(r: ^Renderer) -> (w, h: f32) {
	return f32(r.window.width), f32(r.window.height)
}

window_resize :: proc(r: ^Renderer, width, height: i32) {
	backend := renderer_get_backend(r)
	backend.window_resize(r, width, height)
}

measure_text :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	text: string,
	font_size: int,
	spaces_per_tab := 4,
	allocator := context.allocator,
) -> Font_Metrics {
	backend := renderer_get_backend(r)
	return backend.measure_text(r, font, text, font_size, spaces_per_tab, allocator)
}

set_scissor :: proc(r: ^Renderer, x, y: i32, w, h: u32) {
	if r == nil do return
	backend := renderer_get_backend(r)
	backend.set_scissor(r, x, y, w, h)
}

clear_scissor :: proc(r: ^Renderer) {
	backend := renderer_get_backend(r)
	backend.clear_scissor(r)
}

Texture_Handle :: struct {
	idx: int,
}

Texture_Metrics :: struct {
	width, height: int,
}

@(require_results)
texture_load :: proc(
	r: ^Renderer,
	pixels: []Color,
	width, height: int,
	color_space: Texture_Color_Space = .SRGB,
) -> (
	Texture_Handle,
	bool,
) {
	if r == nil || !r.initialized {
		log.error("reify texture_load: renderer is not initialized")
		return {idx = -1}, false
	}

	backend := renderer_get_backend(r)
	return backend.texture_load(r, pixels, width, height, color_space)
}

texture_get_metrics :: proc(r: ^Renderer, handle: Texture_Handle) -> (Texture_Metrics, bool) {
	if r == nil || !r.initialized do return {}, false
	backend := renderer_get_backend(r)
	return backend.texture_get_metrics(r, handle)
}

draw_rect :: proc(
	r: ^Renderer,
	position: [2]f32,
	width, height: f32,
	color: Color,
	pivot: Pivot = .Topleft,
	rotation: f32 = 0,
	is_additive: bool = false,
) {
	if r.perf.enabled do r.perf.draw_rects += 1
	backend := renderer_get_backend(r)
	backend.draw_rect(r, position, width, height, color, pivot, rotation, is_additive)
}
Draw_Rect_Proc :: #type type_of(draw_rect)

draw_triangle :: proc(r: ^Renderer, p1, p2, p3: [2]f32, color: Color, is_additive: bool = false) {
	if r.perf.enabled do r.perf.draw_rects += 1
	backend := renderer_get_backend(r)
	backend.draw_triangle(r, p1, p2, p3, color, is_additive)
}

draw_circle :: proc(
	r: ^Renderer,
	position: [2]f32,
	radius: f32,
	color: Color,
	is_additive: bool = false,
) {
	if r.perf.enabled do r.perf.draw_rects += 1
	backend := renderer_get_backend(r)
	backend.draw_circle(r, position, radius, color, is_additive)
}

draw_line :: proc(
	r: ^Renderer,
	p0, p1: [2]f32,
	thickness: int,
	color: Color,
	rounded: bool = false,
	is_additive: bool = false,
) {
	if r.perf.enabled do r.perf.draw_lines += 1
	backend := renderer_get_backend(r)
	backend.draw_line(r, p0, p1, thickness, color, rounded, is_additive)
}

draw_lines :: proc(
	r: ^Renderer,
	thickness: int,
	color: Color,
	closed, rounded: bool,
	points: [][2]f32,
) {
	if r.perf.enabled do r.perf.draw_linesets += 1
	if len(points) < 2 || thickness <= 0 do return
	for i in 0 ..< len(points) - 1 {
		drawing_line_segment(r, points[i], points[i + 1], thickness, color, rounded)
	}
	if closed {
		drawing_line_segment(r, points[len(points) - 1], points[0], thickness, color, rounded)
	}
}

draw_text :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	text: string,
	pos: [2]f32,
	font_size: int,
	color: Color = {255, 255, 255, 255},
	spaces_per_tab: int = 4,
	allocator := context.temp_allocator,
) {
	if r.perf.enabled do r.perf.draw_texts += 1
	backend := renderer_get_backend(r)
	backend.draw_text(r, font, text, pos, font_size, color, spaces_per_tab, allocator)
}

draw_fps :: proc(
	r: ^Renderer,
	font: Font_Face_Handle,
	position: [2]f32,
	font_size: int,
	color: Color = {255, 255, 255, 255},
	allocator := context.temp_allocator,
) {
	if r == nil do return
	backend := renderer_get_backend(r)
	backend.draw_fps(r, font, position, font_size, color, allocator)
}

FULL_UV :: Rect {
	x = 0,
	y = 0,
	w = 1,
	h = 1,
}

draw_image :: proc(
	r: ^Renderer,
	tex: Texture_Handle,
	position: [2]f32,
	rotation: f32 = 0,
	scale: [2]f32 = {1, 1},
	rgb_tint: [3]u8 = {255, 255, 255},
	alpha: f32 = 1,
	uv_rect: Rect = FULL_UV,
	is_additive: bool = false,
) {
	if r.perf.enabled do r.perf.draw_images += 1
	backend := renderer_get_backend(r)
	backend.draw_image(
		r,
		tex,
		position,
		rotation = rotation,
		scale = scale,
		uv_rect = uv_rect,
		rgb_tint = rgb_tint,
		alpha = alpha,
		is_additive = is_additive,
	)
}

@(private)
drawing_line_segment :: proc(
	r: ^Renderer,
	from, to: [2]f32,
	thickness: int,
	color: Color,
	rounded: bool,
) {
	backend := renderer_get_backend(r)
	backend.draw_line(r, from, to, thickness, color, rounded)
}

Projection_Type :: enum {
	World, // Default
	Screen,
}

Pivot :: enum {
	Center,
	Topleft,
}

Font_Metrics :: struct {
	text_rect:        Rect,
	font_y_base:      f32,
	font_line_height: f32,
}

Text_Layout_Quad :: struct {
	pos:     [2]f32,
	scale:   [2]f32,
	uv_rect: Rect,
}

Text_Layout :: struct {
	quads:  [dynamic]Text_Layout_Quad,
	bounds: Rect,
}

layout_text :: proc(
	face: Font_Face,
	text: string,
	font_size: int,
	pos := [2]f32{0, 0},
	spaces_per_tab := 4,
	allocator := context.allocator,
) -> Text_Layout {
	context.allocator = allocator

	layout := Text_Layout {
		bounds = Rect{x = pos.x, y = pos.y, w = 0, h = 0},
	}

	if font_size <= 0 || len(text) == 0 {
		return layout
	}
	glyph_scale := f32(font_size) / f32(face.size)
	layout.quads = make([dynamic]Text_Layout_Quad, 0, len(text))

	space_glyph, space_exists := font_face_get_glyph(face, ' ')
	space_advance := 0.25 * face.line_height * glyph_scale // fallback
	if space_exists {
		space_advance = space_glyph.x_advance * glyph_scale
	}
	tab_advance := f32(spaces_per_tab) * space_advance

	start_x := pos.x
	pen_x := pos.x
	// Text layout position is top-left; convert to baseline for glyph placement.
	pen_y := pos.y + face.y_base * glyph_scale

	min_x := start_x
	max_x := start_x
	line_top := pen_y - face.y_base * glyph_scale
	line_bottom := line_top + face.line_height * glyph_scale
	min_y := line_top
	max_y := line_bottom
	has_content := false

	for rr in text {
		switch rr {
		case '\n':
			has_content = true
			if pen_x > max_x do max_x = pen_x
			pen_x = start_x
			pen_y += face.line_height * glyph_scale
			line_top = pen_y - face.y_base * glyph_scale
			line_bottom = line_top + face.line_height * glyph_scale
			if line_top < min_y do min_y = line_top
			if line_bottom > max_y do max_y = line_bottom
			continue
		case '\t':
			pen_x += tab_advance
			has_content = true
			if pen_x > max_x do max_x = pen_x
			continue
		case ' ':
			pen_x += space_advance
			has_content = true
			if pen_x > max_x do max_x = pen_x
			continue
		}

		glyph, glyph_exists := font_face_get_glyph(face, rr)
		if !glyph_exists {
			continue
		}

		x := pen_x + glyph.x_offset * glyph_scale
		y := pen_y - face.y_base * glyph_scale + glyph.y_offset * glyph_scale

		if glyph.width > 0 && glyph.height > 0 {
			glyph_center := [2]f32 {
				x + glyph.width * glyph_scale * 0.5,
				y + glyph.height * glyph_scale * 0.5,
			}
			uv_scale := [2]f32{glyph.uv_rect.w, glyph.uv_rect.h}
			if uv_scale.x < 0 do uv_scale.x = -uv_scale.x
			if uv_scale.y < 0 do uv_scale.y = -uv_scale.y
			pixel_scale := [2]f32 {
				glyph_scale * f32(face.tex_size.x) * uv_scale.x,
				glyph_scale * f32(face.tex_size.y) * uv_scale.y,
			}
			append(
				&layout.quads,
				Text_Layout_Quad{pos = glyph_center, scale = pixel_scale, uv_rect = glyph.uv_rect},
			)

			glyph_min_x := x
			glyph_min_y := y
			glyph_max_x := x + glyph.width * glyph_scale
			glyph_max_y := y + glyph.height * glyph_scale
			if glyph_min_x < min_x do min_x = glyph_min_x
			if glyph_min_y < min_y do min_y = glyph_min_y
			if glyph_max_x > max_x do max_x = glyph_max_x
			if glyph_max_y > max_y do max_y = glyph_max_y
		}

		pen_x += glyph.x_advance * glyph_scale
		has_content = true
		if pen_x > max_x do max_x = pen_x
	}

	if !has_content {
		return layout
	}

	layout.bounds = Rect {
		x = min_x,
		y = min_y,
		w = max_x - min_x,
		h = max_y - min_y,
	}
	return layout
}

convert_color_f32 :: proc(color: Color) -> [4]f32 {
	return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
}

// Convert color to the pre-multiplied alpha form necessary for shaders
@(private)
convert_color_pma :: proc(color: Color, is_additive := false) -> [4]f32 {
	color_srgb := convert_color_f32(color)
	alpha := color_srgb.a

	// Instance colors are authored in sRGB bytes, but rendering occurs in
	// linear space (sRGB swapchain attachment). Convert to linear first.
	linear_rgb := linalg.vector3_srgb_to_linear([3]f32{color_srgb.r, color_srgb.g, color_srgb.b})

	// pre-multiply alpha
	linear_rgb *= alpha

	if is_additive {
		return {linear_rgb.r, linear_rgb.g, linear_rgb.b, 0}
	} else {
		return {linear_rgb.r, linear_rgb.g, linear_rgb.b, alpha}
	}
}

Texture_Color_Space :: enum {
	SRGB,
	Linear,
}

Font_Atlas :: struct {
	pages:          []string `json:"pages"`,
	chars:          []Font_Atlas_Char `json:"chars"`,
	info:           Font_Atlas_Info `json:"info"`,
	common:         Font_Atlas_Common `json:"common"`,
	distance_field: Font_Atlas_Distance_Field `json:"distanceField"`,
	kernings:       []Font_Atlas_Kerning `json:"kernings"`,
}

Font_Atlas_Info :: struct {
	face:      string `json:"face"`,
	size:      int `json:"size"`,
	bold:      int `json:"bold"`,
	italic:    int `json:"italic"`,
	charset:   []string `json:"charset"`,
	unicode:   int `json:"unicode"`,
	stretch_h: int `json:"stretchH"`,
	smooth:    int `json:"smooth"`,
	aa:        int `json:"aa"`,
	padding:   [4]int `json:"padding"`,
	spacing:   [2]int `json:"spacing"`,
}

Font_Atlas_Common :: struct {
	line_height:   f32 `json:"lineHeight"`,
	base:          f32 `json:"base"`,
	scale_w:       int `json:"scaleW"`,
	scale_h:       int `json:"scaleH"`,
	pages:         int `json:"pages"`,
	packed:        int `json:"packed"`,
	alpha_channel: int `json:"alphaChnl"`,
	red_channel:   int `json:"redChnl"`,
	green_channel: int `json:"greenChnl"`,
	blue_channel:  int `json:"blueChnl"`,
}

Font_Atlas_Distance_Field :: struct {
	field_type:     string `json:"fieldType"`,
	distance_range: f32 `json:"distanceRange"`,
}

Font_Atlas_Char :: struct {
	id:         int `json:"id"`, // unicode codepoint
	index:      int `json:"index"`,
	glyph_char: string `json:"char"`,
	width:      int `json:"width"`,
	height:     int `json:"height"`,
	xoffset:    int `json:"xoffset"`,
	yoffset:    int `json:"yoffset"`,
	xadvance:   int `json:"xadvance"`,
	channel:    int `json:"chnl"`,
	x:          int `json:"x"`,
	y:          int `json:"y"`,
	page:       int `json:"page"`,
}

Font_Atlas_Kerning :: struct {
	first:  int `json:"first"`,
	second: int `json:"second"`,
	amount: int `json:"amount"`,
}

Font_Atlas_Load_Error :: enum {
	Invalid_Page_Count,
	Invalid_Dimensions,
	Invalid_Pixel_Format,
	Empty_Glyphs,
	Packed_Channels_Not_Supported,
}

Font_Atlas_Error :: union {
	json.Unmarshal_Error,
	image.Error,
	Font_Atlas_Load_Error,
	Renderer_Error,
}

Font_Face :: struct {
	texture:        Texture_Handle,
	size:           int, // default size of glyphs
	line_height:    f32,
	y_base:         f32, // y offset (from top of line) where chars sit
	distance_range: f32,
	tex_size:       [2]int,
	glyph_lookup:   map[rune]int,
	glyphs:         [dynamic]Font_Face_Glyph,
	missing_glyph:  Font_Face_Glyph,
}

// TODO may need a Font_Face_Metrics to provide user code details like y_base,
// line_height, etc for layouting.

Font_Face_Glyph :: struct {
	r:         rune,
	uv_rect:   Rect,
	width:     f32,
	height:    f32,
	x_offset:  f32,
	y_offset:  f32,
	x_advance: f32,
}

font_face_get_glyph :: proc(face: Font_Face, char: rune) -> (Font_Face_Glyph, bool) {
	gid, exists := face.glyph_lookup[char]
	if !exists || gid > len(face.glyphs) - 1 {
		return face.missing_glyph, true
	}

	return face.glyphs[gid], true
}

font_face_destroy :: proc(face: ^Font_Face, allocator := context.allocator) {
	context.allocator = allocator
	delete(face.glyph_lookup)
	delete(face.glyphs)
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
