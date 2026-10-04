package reify

import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"

when RENDERER_BACKEND_TYPE == .Vulkan_1_1 {
	Test_Renderer :: Vulkan11_Renderer
	TEST_RENDERER_BACKEND :: VULKAN11_RENDERER_BACKEND
} else {
	Test_Renderer :: Vulkan13_Rendererer
	TEST_RENDERER_BACKEND :: VULKAN13_RENDERER_BACKEND
}

@(test)
renderer_nil_frame_operations :: proc(t: ^testing.T) {
	start(nil, {}, 1)
	begin_screen_mode(nil)
	end_screen_mode(nil)
	set_scissor(nil, 0, 0, 1, 1)
}

@(test)
renderer_storage_allocation_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&platform_test_dispatch_mutex)
	defer sync.mutex_unlock(&platform_test_dispatch_mutex)
	capture: Public_Error_Log
	test_logger := context.logger
	context.logger = {
		procedure = public_error_log,
		data      = &capture,
	}
	r, ok := renderer_new({}, mem.nil_allocator())
	context.logger = test_logger
	testing.expect(t, r == nil && !ok && active_renderer == nil)
	testing.expect_value(t, capture.level, log.Level.Error)
	testing.expect(
		t,
		strings.contains(
			string(capture.message[:capture.length]),
			"renderer storage allocation failed",
		),
	)
}

@(test)
renderer_allocated_storage :: proc(t: ^testing.T) {
	sync.mutex_lock(&platform_test_dispatch_mutex)
	defer sync.mutex_unlock(&platform_test_dispatch_mutex)
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	allocator := mem.tracking_allocator(&tracker)
	test_logger := context.logger
	context.logger = log.nil_logger()
	r, ok := renderer_new({}, allocator)
	context.logger = test_logger
	testing.expect(t, r == nil && !ok && active_renderer == nil)
	testing.expect_value(t, len(tracker.allocation_map), 0)
	for mode in Platform_Test_Mode {
		state := Platform_Test_State {
			mode       = mode,
			extensions = {"VK_KHR_surface", "VK_KHR_surface"},
		}
		if mode == .Missing_Extension do state.extensions[0] = "VK_REIFY_missing_extension"
		if mode == .Nil_Extension do state.extensions[0] = nil
		info := Renderer_Init_Info {
			platform            = test_platform(&state),
			resources_allocator = context.allocator,
		}
		context.logger = log.nil_logger()
		r, ok = renderer_new(info, allocator)
		context.logger = test_logger
		testing.expect(t, r == nil && !ok && active_renderer == nil)
		testing.expect_value(t, len(tracker.allocation_map), 0)
		testing.expect_value(t, len(tracker.bad_free_array), 0)
	}
	renderer_free(nil)
}

@(test)
renderer_base_subtyping :: proc(t: ^testing.T) {
	allocator := context.allocator
	r := new(Test_Renderer)
	defer free(r, allocator)
	r.backend_type = RENDERER_BACKEND_TYPE
	common: ^Renderer = r
	testing.expect(t, common == cast(^Renderer)r)
	common.window.width = 123
	r.frame_index = 2
	testing.expect_value(t, r.window.width, i32(123))
	testing.expect_value(t, r.frame_index, 2)

	state11 := new(Vulkan11_Renderer)
	defer free(state11, allocator)
	state13 := new(Vulkan13_Rendererer)
	defer free(state13, allocator)
	state11.resources_allocator = allocator
	state13.resources_allocator = allocator
	common11: ^Renderer = state11
	common13: ^Renderer = state13
	testing.expect(t, common11 == cast(^Renderer)state11)
	testing.expect(t, common13 == cast(^Renderer)state13)
	common11.window.width, common13.window.width = 11, 13
	interface: Renderer_Backend_Interface
	renderer: ^Renderer
	interface, renderer = VULKAN11_RENDERER_BACKEND, state11
	interface.window_resize(renderer, 110, 111)
	interface, renderer = VULKAN13_RENDERER_BACKEND, state13
	interface.window_resize(renderer, 130, 131)
	testing.expect_value(t, common11.window.width, i32(110))
	testing.expect_value(t, common13.window.width, i32(130))
	state11.initialized, state11.loader_owned, state11.stopped = true, true, true
	state13.initialized, state13.loader_owned, state13.stopped = true, true, true
	state11.frame_index, state13.frame_index = 2, 2
	state11.gpu.limits.instances, state13.gpu.limits.instances = 42, 42
	interface, renderer = VULKAN11_RENDERER_BACKEND, state11
	interface.destroy(renderer)
	interface, renderer = VULKAN13_RENDERER_BACKEND, state13
	interface.destroy(renderer)
	testing.expect(t, !state11.initialized && !state11.loader_owned && !state11.stopped)
	testing.expect(t, !state13.initialized && !state13.loader_owned && !state13.stopped)
	testing.expect_value(t, state11.window.width, i32(0))
	testing.expect_value(t, state13.window.width, i32(0))
	testing.expect_value(t, state11.frame_index, 0)
	testing.expect_value(t, state13.frame_index, 0)
	testing.expect_value(t, state11.gpu.limits.instances, u32(0))
	testing.expect_value(t, state13.gpu.limits.instances, u32(0))
}

@(test)
renderer_init_preflight_preserves_state :: proc(t: ^testing.T) {
	sync.mutex_lock(&platform_test_dispatch_mutex)
	defer sync.mutex_unlock(&platform_test_dispatch_mutex)
	testing.expect(t, active_renderer == nil)
	r := new(Test_Renderer)
	defer free(r)
	r.backend_type = RENDERER_BACKEND_TYPE
	r.window.width, r.window.height = 123, 456
	r.frame_index = 2
	state: Platform_Test_State
	info := Renderer_Init_Info {
		platform     = test_platform(&state),
		logical_size = {800, 600},
	}

	err := renderer_init(nil, RENDERER_BACKEND_TYPE, info)
	testing.expect_value(t, err.category, Renderer_Error_Category.Invalid_State)
	invalid_dimensions := [?][2]int {
		{-1, 600},
		{800, -1},
		{int(max(i32)) + 1, 600},
		{800, int(max(i32)) + 1},
	}
	for dimensions in invalid_dimensions {
		bad := info
		bad.logical_size = dimensions
		err = renderer_init(r, RENDERER_BACKEND_TYPE, bad)
		testing.expect_value(t, err.category, Renderer_Error_Category.Invalid_State)
		testing.expect_value(t, r.window.width, i32(123))
		testing.expect_value(t, r.window.height, i32(456))
		testing.expect_value(t, r.frame_index, 2)
		testing.expect(t, active_renderer == nil && !r.loader_owned)
	}
}

@(test)
public_failure_results_and_logging :: proc(t: ^testing.T) {
	capture: Public_Error_Log
	test_logger := context.logger
	capture_logger := log.Logger {
		procedure = public_error_log,
		data      = &capture,
	}
	context.logger = capture_logger
	r, initialized := renderer_new({})
	logger_after_init := context.logger
	context.logger = test_logger
	testing.expect(t, r == nil && !initialized)
	testing.expect(
		t,
		strings.contains(string(capture.message[:capture.length]), "callbacks are required"),
	)
	testing.expect_value(t, capture.level, log.Level.Error)
	context.logger = capture_logger
	calls_before_present := capture.calls
	presented := present(nil)
	context.logger = test_logger
	testing.expect(t, !presented)
	testing.expect_value(t, capture.calls, calls_before_present)
	context.logger = capture_logger
	uninitialized: Renderer
	presented = present(&uninitialized)
	context.logger = test_logger
	testing.expect(t, !presented)
	testing.expect_value(t, uninitialized.last_error.category, Renderer_Error_Category.Invalid_State)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "renderer is not initialized"))
	context.logger = capture_logger
	texture, texture_ok := texture_load(nil, nil, 1, 1)
	context.logger = test_logger
	testing.expect(t, !texture_ok && texture.idx == -1)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "texture_load"))
	context.logger = capture_logger
	font, font_err := font_load(nil, nil, nil)
	context.logger = test_logger
	testing.expect(t, font_err != nil && font.idx == -1)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "font_load"))
	testing.expect_value(t, capture.calls, 5)
	testing.expect(t, logger_after_init.procedure == public_error_log)
	testing.expect(t, logger_after_init.data == &capture)
	loggers := [?]log.Logger{{}, log.nil_logger()}
	for logger in loggers {
		context.logger = logger
		r, initialized = renderer_new({})
		logger_after_init = context.logger
		context.logger = test_logger
		testing.expect(t, r == nil && !initialized)
		testing.expect(t, logger_after_init.procedure == logger.procedure)
		testing.expect(t, logger_after_init.data == logger.data)
	}
}

@(test)
public_rejected_frame_logging_and_reset :: proc(t: ^testing.T) {
	capture: Public_Error_Log
	context.logger = {
		procedure = public_error_log,
		data      = &capture,
	}
	r := new(Test_Renderer)
	defer free(r)
	r.backend_type = RENDERER_BACKEND_TYPE
	r.resources_allocator = context.allocator
	r.initialized = true
	r.gpu.limits.instances = 1
	defer for &frame in r.frame_contexts do delete(frame.draw_batches)
	start(r, {}, 1)
	draw_rect(r, {}, 1, 1, {})
	draw_rect(r, {}, 1, 1, {})
	draw_rect(r, {}, 1, 1, {})
	testing.expect_value(t, capture.calls, 1)
	testing.expect(
		t,
		strings.contains(string(capture.message[:capture.length]), "instance capacity"),
	)
	testing.expect(t, !present(r) && !r.stopped && !r.frame_started)
	testing.expect_value(t, capture.calls, 1)
	start(r, {}, 1)
	testing.expect(t, !r.frame_failed && r.frame_started)
	draw_image(r, {idx = -1}, {})
	testing.expect(t, !present(r) && !r.stopped)
	testing.expect_value(t, capture.calls, 2)
	testing.expect(
		t,
		strings.contains(string(capture.message[:capture.length]), "invalid texture handle"),
	)
}

@(private)
Public_Error_Log :: struct {
	message:       [1024]u8,
	length, calls: int,
	level:         log.Level,
}

@(private)
public_error_log :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	capture := cast(^Public_Error_Log)data
	capture.length = copy(capture.message[:], transmute([]u8)text)
	capture.calls += 1
	capture.level = level
}

@(test)
draw_fps_nil_renderer :: proc(t: ^testing.T) {
	draw_fps(nil, {}, {}, 12)
}

@(test)
draw_rect_forwards_options :: proc(t: ^testing.T) {
	r := new(Test_Renderer)
	defer free(r)
	r.backend_type = RENDERER_BACKEND_TYPE
	r.resources_allocator = context.allocator
	r.initialized = true
	r.perf.enabled = true
	r.gpu.limits.instances = 2
	defer for &frame in r.frame_contexts do delete(frame.draw_batches)
	start(r, {}, 1)
	color := Color{255, 0, 0, 128}
	draw_rect(r, {1, 2}, 3, 4, color, .Center, 0.5, true)
	draw_rect(r, {1, 2}, 3, 4, color)
	frame := &r.frame_contexts[r.frame_index]
	testing.expect_value(t, frame.total_instances, 2)
	centered := frame.shader_data.instances[0]
	testing.expect_value(t, centered.pos, [2]f32{1, 2})
	testing.expect_value(t, centered.scale, [2]f32{3, 4})
	testing.expect_value(t, centered.rotation, f32(0.5))
	testing.expect_value(t, centered.color, [4]f32{f32(128) / 255, 0, 0, 0})
	testing.expect_value(t, frame.shader_data.instances[1].pos, [2]f32{2.5, 4})
	testing.expect_value(t, frame.shader_data.instances[1].color.a, f32(128) / 255)
	testing.expect_value(t, r.perf.draw_rects, 2)
}

@(test)
draw_line_forwards_options :: proc(t: ^testing.T) {
	r := new(Test_Renderer)
	defer free(r)
	r.backend_type = RENDERER_BACKEND_TYPE
	r.resources_allocator = context.allocator
	r.initialized = true
	r.gpu.limits.instances = 3
	defer for &frame in r.frame_contexts do delete(frame.draw_batches)
	start(r, {}, 1)
	draw_line(r, {0, 0}, {10, 0}, 3, {255, 0, 0, 128}, rounded = true, is_additive = true)
	frame := &r.frame_contexts[r.frame_index]
	testing.expect_value(t, frame.total_instances, 3)
	testing.expect_value(t, frame.shader_data.instances[0].type, u32(Quad_Instance_Type.Circle))
	testing.expect_value(t, frame.shader_data.instances[1].type, u32(Quad_Instance_Type.Circle))
	testing.expect_value(t, frame.shader_data.instances[2].type, u32(Quad_Instance_Type.Rect))
	testing.expect_value(t, frame.shader_data.instances[2].scale, [2]f32{10, 3})
	for instance in frame.shader_data.instances[:frame.total_instances] {
		testing.expect_value(t, instance.color, [4]f32{f32(128) / 255, 0, 0, 0})
	}
}

@(test)
font_failure_returns_invalid_handle :: proc(t: ^testing.T) {
	r := new(Test_Renderer)
	defer free(r)
	r.backend_type = RENDERER_BACKEND_TYPE
	r.resources_allocator = context.allocator
	r.initialized = true
	r.gpu.limits.fonts = 1
	defer delete(r.resources.font_faces)
	defer delete(r.resources.quad_fonts)
	handle, err := font_load(r, []byte{'{'}, nil)
	_, json_error := err.(json.Unmarshal_Error)
	testing.expect(t, err != nil && json_error && handle.idx == -1)
	// A one-pixel RGBA16 PNG exercises unsupported atlas depth.
	rgba16_png := []byte{
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
		0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x10, 0x06, 0x00, 0x00, 0x00, 0x4f, 0x85, 0x18, 0xca, 0x00, 0x00, 0x00,
		0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0x0f, 0x05, 0x00,
		0x23, 0xe5, 0x07, 0xf9, 0x8a, 0x34, 0x78, 0xb3, 0x00, 0x00, 0x00, 0x00,
		0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
	}
	for failure in Font_Atlas_Load_Error {
		image_bytes: []byte
		atlas := Font_Atlas {
			pages = []string{"atlas.png"},
			info = {size = 10},
			common = {pages = 1, scale_w = 10, scale_h = 10, line_height = 10},
			distance_field = {distance_range = 2},
			chars = []Font_Atlas_Char{{id = 65}},
		}
		switch failure {
		case .Invalid_Page_Count:
			atlas.pages = nil
		case .Invalid_Dimensions:
			atlas.common.scale_w = 0
		case .Empty_Glyphs:
			atlas.chars = nil
		case .Packed_Channels_Not_Supported:
			atlas.common.packed = 1
		case .Invalid_Pixel_Format:
			atlas.common.scale_w, atlas.common.scale_h = 1, 1
			image_bytes = rgba16_png
		}
		bytes, marshal_err := json.marshal(atlas)
		defer delete(bytes)
		if !testing.expect(t, marshal_err == nil) do continue
		handle, err = font_load(r, bytes, image_bytes)
		atlas_error, is_atlas_error := err.(Font_Atlas_Load_Error)
		testing.expect(t, is_atlas_error)
		testing.expect_value(t, atlas_error, failure)
		testing.expect_value(t, handle.idx, -1)
	}
	valid_json :: `{"pages":["atlas.png"],"info":{"size":10},"common":{"pages":1,"scaleW":10,"scaleH":10,"lineHeight":10},"distanceField":{"distanceRange":2},"chars":[{"id":65}]}`
	handle, err = font_load(r, transmute([]byte)string(valid_json), []byte{0})
	testing.expect(t, err != nil && handle.idx == -1)
	testing.expect_value(t, len(r.resources.font_faces), 0)
	testing.expect_value(t, len(r.resources.textures), 0)
	testing.expect(t, !r.stopped)
}

@(test)
font_layout_consumes_face_data :: proc(t: ^testing.T) {
	face := Font_Face {
		size        = 10,
		line_height = 14,
		y_base      = 10,
		tex_size    = {100, 100},
	}
	face.glyphs = make([dynamic]Font_Face_Glyph)
	face.glyph_lookup = make(map[rune]int)
	defer font_face_destroy(&face)
	append(
		&face.glyphs,
		Font_Face_Glyph {
			r = 'A',
			width = 5,
			height = 8,
			x_offset = 1,
			y_offset = 2,
			x_advance = 6,
			uv_rect = {0, 0, 0.05, 0.08},
		},
		Font_Face_Glyph{r = ' ', x_advance = 4},
	)
	face.glyph_lookup['A'], face.glyph_lookup[' '] = 0, 1
	layout := layout_text(face, "A A\n\tA", 20, {20, 30})
	defer delete(layout.quads)
	testing.expect_value(t, len(layout.quads), 3)
	testing.expect_value(t, layout.quads[0].pos, [2]f32{27, 42})
	testing.expect_value(t, layout.quads[1].pos, [2]f32{47, 42})
	testing.expect_value(t, layout.quads[2].pos, [2]f32{59, 70})
	testing.expect_value(t, layout.quads[0].scale, [2]f32{10, 16})
	testing.expect_value(t, layout.bounds, Rect{20, 30, 44, 56})
	invalid := layout_text(face, "A", 0)
	defer delete(invalid.quads)
	testing.expect_value(t, len(invalid.quads), 0)
	empty := layout_text(face, "", 20)
	defer delete(empty.quads)
	testing.expect_value(t, len(empty.quads), 0)
}
