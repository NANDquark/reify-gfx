package reify

import "core:encoding/json"
import "core:fmt"
import "core:image"
import _ "core:image/png"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:time"
import pf "../substrate"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

SDLGPU_VERT_SPV_BYTES :: #load("../../assets/shaders/quad_sdlgpu.vert.spv")
SDLGPU_FRAG_SPV_BYTES :: #load("../../assets/shaders/quad_sdlgpu.frag.spv")

Sdlgpu_Renderer_State :: struct {
	window:                ^sdl.Window,
	device:                ^sdl.GPUDevice,
	window_width:          f32,
	window_height:         f32,
	vsync_enabled:         bool,
	perf:                  Renderer_Perf_Stats,
	swapchain_composition: sdl.GPUSwapchainComposition,
	present_mode:          sdl.GPUPresentMode,
	textures:              [dynamic]Sdlgpu_Texture,
	fonts:                 [dynamic]Sdlgpu_Font_Face,
	draw_images:           [dynamic]Sdlgpu_Draw_Image_Cmd,
	cam_pos:               [2]f32,
	cam_zoom:              f32,
	is_screen_mode:        bool,
	white_texture:         Texture_Handle,
	white_texture_ok:      bool,
	scissor_enabled:       bool,
	scissor_x:             i32,
	scissor_y:             i32,
	scissor_w:             u32,
	scissor_h:             u32,
	sampler_nearest:       ^sdl.GPUSampler,
	sampler_linear:        ^sdl.GPUSampler,
	vert_shader:           ^sdl.GPUShader,
	frag_shader:           ^sdl.GPUShader,
	pipeline:              ^sdl.GPUGraphicsPipeline,
	vertex_buffer:         ^sdl.GPUBuffer,
	vertex_transfer:       ^sdl.GPUTransferBuffer,
	vertex_capacity:       int,
	swapchain_format:      sdl.GPUTextureFormat,
	debug_capture_pending: bool,
	debug_capture_done:    bool,
	debug_capture_ok:      bool,
	debug_capture_path:    string,
}

Sdlgpu_Texture :: struct {
	handle: ^sdl.GPUTexture,
	width:  int,
	height: int,
}

Sdlgpu_Font_Glyph :: struct {
	uv_rect:    Rect,
	width:      f32,
	height:     f32,
	x_offset:   f32,
	y_offset:   f32,
	x_advance: f32,
}

Sdlgpu_Font_Face :: struct {
	texture:         Texture_Handle,
	base_size:       int,
	line_height:     f32,
	y_base:          f32,
	distance_range:  f32,
	tex_size:        [2]f32,
	glyphs:          map[rune]Sdlgpu_Font_Glyph,
	missing_advance: f32,
}

Sdlgpu_Font_Atlas_JSON :: struct {
	chars:  []Sdlgpu_Font_Char_JSON `json:"chars"`,
	info:   struct {
		size: int `json:"size"`,
	} `json:"info"`,
	common: struct {
		line_height: f32 `json:"lineHeight"`,
		base:        f32 `json:"base"`,
		scale_w:     int `json:"scaleW"`,
		scale_h:     int `json:"scaleH"`,
	} `json:"common"`,
	distance_field: struct {
		distance_range: f32 `json:"distanceRange"`,
	} `json:"distanceField"`,
}

Sdlgpu_Font_Char_JSON :: struct {
	id:       int `json:"id"`,
	x:        int `json:"x"`,
	y:        int `json:"y"`,
	width:    int `json:"width"`,
	height:   int `json:"height"`,
	xoffset:  int `json:"xoffset"`,
	yoffset:  int `json:"yoffset"`,
	xadvance: int `json:"xadvance"`,
}

Sdlgpu_Draw_Image_Cmd :: struct {
	texture:     Texture_Handle,
	position:    [2]f32,
	scale:       [2]f32,
	rotation:    f32,
	uv_rect:     Rect,
	color:       [4]f32,
	params:      [4]f32,
	tri_points:  [3][2]f32,
	screen_mode: bool,
	scissor_enabled: bool,
	scissor_x:       i32,
	scissor_y:       i32,
	scissor_w:       u32,
	scissor_h:       u32,
}

SDLGPU_DRAW_MODE_SPRITE :: f32(0.0)
SDLGPU_DRAW_MODE_MSDF :: f32(1.0)
SDLGPU_DRAW_MODE_CIRCLE :: f32(2.0)
SDLGPU_DRAW_MODE_TRIANGLE :: f32(3.0)

Sdlgpu_Vertex :: struct {
	position: [2]f32,
	uv:       [2]f32,
	color:    [4]f32,
	params:   [4]f32,
}

sdlgpu_debug_capture_request :: proc(state: ^Sdlgpu_Renderer_State, path: string) {
	if state == nil {
		return
	}
	state.debug_capture_pending = true
	state.debug_capture_done = false
	state.debug_capture_ok = false
	state.debug_capture_path = path
}

sdlgpu_debug_capture_status :: proc(state: ^Sdlgpu_Renderer_State) -> (done, ok: bool) {
	if state == nil {
		return false, false
	}
	return state.debug_capture_done, state.debug_capture_ok
}

@(private)
sdlgpu_vulkan_init :: proc(state: ^Sdlgpu_Renderer_State) {}

@(private)
sdlgpu_vulkan_shutdown :: proc(state: ^Sdlgpu_Renderer_State) {}

@(private)
sdlgpu_init :: proc(state: ^Sdlgpu_Renderer_State, platform: ^pf.Platform, size: [2]int) {
	state.window_width = f32(size[0])
	state.window_height = f32(size[1])
	state.vsync_enabled = true
	state.swapchain_composition = .SDR_LINEAR
	state.present_mode = .VSYNC

	window, window_ok := pf.get_sdl_window(platform)
	if !window_ok || window == nil {
		log.error("SDL_GPU renderer requires substrate SDL platform with a valid window")
		return
	}
	state.window = window

	format_flags := sdl.GPUShaderFormat{.SPIRV}
	state.device = sdl.CreateGPUDevice(format_flags, false, nil)
	if state.device == nil {
		log.errorf("SDL_CreateGPUDevice failed: %s", string(sdl.GetError()))
		return
	}
	driver := sdl.GetGPUDeviceDriver(state.device)
	shader_formats := sdl.GetGPUShaderFormats(state.device)
	log.infof(
		"sdlgpu init: driver=%s shader_formats=%v swapchain_composition=%v",
		string(driver),
		shader_formats,
		state.swapchain_composition,
	)
	if !sdl.ClaimWindowForGPUDevice(state.device, state.window) {
		log.errorf("SDL_ClaimWindowForGPUDevice failed: %s", string(sdl.GetError()))
		sdl.DestroyGPUDevice(state.device)
		state.device = nil
		return
	}
	_apply_swapchain_params(state)
	white_px := [1]Color{{255, 255, 255, 255}}
	white_tex, white_ok := _sdlgpu_texture_upload(state, white_px[:], 1, 1, apply_pma_srgb = false)
	if !white_ok {
		log.error("failed to initialize SDL_GPU white texture")
	} else {
		state.white_texture = white_tex
		state.white_texture_ok = true
	}
	if !_sdlgpu_init_pipeline(state) {
		log.error("failed to initialize SDL_GPU quad pipeline")
	}
	now := time.now()
	state.perf.last_log_time = now
	state.perf.fps_last_log = now
	log.info("sdlgpu init: renderer initialized")
}

@(private)
sdlgpu_set_vsync :: proc(state: ^Sdlgpu_Renderer_State, enabled: bool) {
	state.vsync_enabled = enabled
	if enabled {
		state.present_mode = .VSYNC
	} else {
		state.present_mode = .IMMEDIATE
	}
	_apply_swapchain_params(state)
}

@(private)
sdlgpu_set_perf_logging :: proc(state: ^Sdlgpu_Renderer_State, enabled: bool) {
	state.perf.enabled = enabled
}

@(private)
sdlgpu_vk_instance :: proc(state: ^Sdlgpu_Renderer_State) -> vk.Instance {
	_ = state
	return {}
}

@(private)
sdlgpu_set_vk_surface :: proc(state: ^Sdlgpu_Renderer_State, surface: vk.SurfaceKHR) {
	_ = state
	_ = surface
}

@(private)
sdlgpu_font_load :: proc(
	state: ^Sdlgpu_Renderer_State,
	font_json: []byte,
	font_msdf: []byte,
) -> (
	Font_Face_Handle,
	bool,
) {
	if state.device == nil {
		log.error("SDL_GPU font_load called before renderer device init")
		return {}, false
	}

	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)
	temp_alloc := mem.dynamic_arena_allocator(&temp_arena)

	atlas := Sdlgpu_Font_Atlas_JSON{}
	if err := json.unmarshal(font_json, &atlas, allocator = temp_alloc); err != nil {
		log.errorf("SDL_GPU font json parse failed: %v", err)
		return {}, false
	}
	if len(atlas.chars) == 0 {
		log.error("SDL_GPU font json has no chars")
		return {}, false
	}

	atlas_img, img_err := image.load_from_bytes(font_msdf, allocator = temp_alloc)
	if img_err != nil {
		log.errorf("SDL_GPU font image parse failed: %v", img_err)
		return {}, false
	}

	pixel_count := atlas_img.width * atlas_img.height
	rgba_pixels := make([]Color, pixel_count, allocator = temp_alloc)
	switch atlas_img.channels {
	case 3:
		src := atlas_img.pixels.buf[:]
		for i in 0 ..< pixel_count {
			si := i * 3
			rgba_pixels[i] = {src[si], src[si + 1], src[si + 2], 255}
		}
	case 4:
		src := slice.reinterpret([]Color, atlas_img.pixels.buf[:])
		copy(rgba_pixels, src)
	case:
		log.errorf("unsupported font atlas channel count: %d", atlas_img.channels)
		return {}, false
	}

	atlas_tex, tex_ok := _sdlgpu_texture_upload(
		state,
		rgba_pixels,
		atlas_img.width,
		atlas_img.height,
		apply_pma_srgb = false,
	)
	if !tex_ok {
		return {}, false
	}

	face := Sdlgpu_Font_Face{
		texture = atlas_tex,
		base_size = atlas.info.size,
		line_height = atlas.common.line_height,
		y_base = atlas.common.base,
		distance_range = atlas.distance_field.distance_range,
		tex_size = {f32(atlas_img.width), f32(atlas_img.height)},
		missing_advance = f32(math.max(1, atlas.info.size)) * 0.5,
	}
	if face.line_height <= 0 {
		face.line_height = f32(math.max(1, face.base_size))
	}
	if face.y_base <= 0 {
		face.y_base = face.line_height
	}
	if face.distance_range <= 0 {
		face.distance_range = 4.0
	}
	for ch in atlas.chars {
		g := Sdlgpu_Font_Glyph{
			uv_rect = {
				x = f32(ch.x) / f32(math.max(1, atlas.common.scale_w)),
				y = f32(ch.y) / f32(math.max(1, atlas.common.scale_h)),
				w = f32(ch.width) / f32(math.max(1, atlas.common.scale_w)),
				h = f32(ch.height) / f32(math.max(1, atlas.common.scale_h)),
			},
			width = f32(ch.width),
			height = f32(ch.height),
			x_offset = f32(ch.xoffset),
			y_offset = f32(ch.yoffset),
			x_advance = f32(ch.xadvance),
		}
		if ch.id == 0 {
			face.missing_advance = g.x_advance
			continue
		}
		face.glyphs[rune(ch.id)] = g
	}

	idx := len(state.fonts)
	append(&state.fonts, face)
	return Font_Face_Handle{idx = idx}, true
}

@(private)
sdlgpu_start :: proc(state: ^Sdlgpu_Renderer_State, cam_pos: [2]f32, cam_zoom: f32) {
	state.cam_pos = cam_pos
	state.cam_zoom = cam_zoom
	state.is_screen_mode = false
	clear(&state.draw_images)
}

@(private)
sdlgpu_begin_screen_mode :: proc(state: ^Sdlgpu_Renderer_State) {
	state.is_screen_mode = true
}

@(private)
sdlgpu_end_screen_mode :: proc(state: ^Sdlgpu_Renderer_State) {
	state.is_screen_mode = false
}

@(private)
sdlgpu_draw_fps :: proc(state: ^Sdlgpu_Renderer_State, font: Font_Face_Handle, pos: [2]f32, size: int) {
	fps_text := fmt.tprintf("%.0f FPS", state.perf.fps_value)
	sdlgpu_draw_text(state, font, fps_text, pos, size, {255, 255, 255, 255})
}

@(private)
sdlgpu_present :: proc(state: ^Sdlgpu_Renderer_State) {
	if state.device == nil || state.window == nil {
		return
	}

	acquire_start := time.now()
	cmd := sdl.AcquireGPUCommandBuffer(state.device)
	if cmd == nil {
		log.errorf("SDL_AcquireGPUCommandBuffer failed: %s", string(sdl.GetError()))
		return
	}

	swap_texture: ^sdl.GPUTexture
	swap_w, swap_h: sdl.Uint32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, state.window, &swap_texture, &swap_w, &swap_h) {
		log.errorf("SDL_WaitAndAcquireGPUSwapchainTexture failed: %s", string(sdl.GetError()))
		_ = sdl.CancelGPUCommandBuffer(cmd)
		return
	}
	if swap_texture == nil {
		_ = sdl.CancelGPUCommandBuffer(cmd)
		return
	}

	state.window_width = f32(swap_w)
	state.window_height = f32(swap_h)
	acquire_end := time.now()

	color_target := sdl.GPUColorTargetInfo {
		texture = swap_texture,
		clear_color = sdl.FColor{0, 0, 0, 1},
		load_op = .CLEAR,
		store_op = .STORE,
	}
	draw_image_count := len(state.draw_images)
	vertex_count := 0
	draw_call_count := 0

	build_start := time.now()
	if len(state.draw_images) == 0 || state.pipeline == nil || state.sampler_nearest == nil || state.sampler_linear == nil {
		pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, nil)
		if pass != nil {
			sdl.EndGPURenderPass(pass)
		}
	} else {
		verts := make([dynamic]Sdlgpu_Vertex, 0, len(state.draw_images) * 6, context.temp_allocator)
		emitted_draws := make([dynamic]Sdlgpu_Draw_Image_Cmd, 0, len(state.draw_images), context.temp_allocator)
		for draw in state.draw_images {
			if _sdlgpu_append_draw_vertices(state, &verts, draw) {
				append(&emitted_draws, draw)
			}
		}
		vertex_count = len(verts)
		build_end := time.now()

		if len(verts) == 0 {
			pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, nil)
			if pass != nil {
				sdl.EndGPURenderPass(pass)
			}
		} else {
			upload_start := time.now()
			uploaded := _sdlgpu_upload_vertices(state, cmd, verts[:])
			upload_end := time.now()
			render_start := upload_end
			if uploaded {
			pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, nil)
			if pass != nil {
				sdl.BindGPUGraphicsPipeline(pass, state.pipeline)
				binding := sdl.GPUBufferBinding{buffer = state.vertex_buffer, offset = 0}
				sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)

				base_vertex: u32 = 0
				run_texture_idx := -1
				run_sampler: ^sdl.GPUSampler = nil
				run_scissor_enabled := false
				run_scissor_x: i32
				run_scissor_y: i32
				run_scissor_w: u32
				run_scissor_h: u32
				run_start_vertex: u32 = 0
				run_vertex_count: u32 = 0

				flush_run := proc "contextless" (
					state: ^Sdlgpu_Renderer_State,
					pass: ^sdl.GPURenderPass,
					run_texture_idx: int,
					run_sampler: ^sdl.GPUSampler,
					run_scissor_enabled: bool,
					run_scissor_x: i32,
					run_scissor_y: i32,
					run_scissor_w: u32,
					run_scissor_h: u32,
					run_start_vertex: u32,
					run_vertex_count: u32,
					draw_call_count: ^int,
				) {
					if run_texture_idx < 0 || run_vertex_count == 0 || run_sampler == nil {
						return
					}
					sc := sdl.Rect{
						x = 0,
						y = 0,
						w = i32(math.max(1, int(state.window_width))),
						h = i32(math.max(1, int(state.window_height))),
					}
					if run_scissor_enabled {
						sc = sdl.Rect{
							x = run_scissor_x,
							y = run_scissor_y,
							w = i32(run_scissor_w),
							h = i32(run_scissor_h),
						}
					}
					sdl.SetGPUScissor(pass, sc)

					src_tex := state.textures[run_texture_idx]
					ts := sdl.GPUTextureSamplerBinding{
						texture = src_tex.handle,
						sampler = run_sampler,
					}
					sdl.BindGPUFragmentSamplers(pass, 0, &ts, 1)
					sdl.DrawGPUPrimitives(pass, run_vertex_count, 1, run_start_vertex, 0)
					draw_call_count^ += 1
				}

				for draw in emitted_draws {
					tex_idx := draw.texture.idx
					if tex_idx < 0 || tex_idx >= len(state.textures) {
						continue
					}
					src_tex := state.textures[tex_idx]
					if src_tex.handle == nil {
						continue
					}

					draw_sampler := state.sampler_nearest
					if draw.params[0] == SDLGPU_DRAW_MODE_MSDF {
						draw_sampler = state.sampler_linear
					}

					if run_texture_idx == tex_idx &&
						run_sampler == draw_sampler &&
						run_scissor_enabled == draw.scissor_enabled &&
						run_scissor_x == draw.scissor_x &&
						run_scissor_y == draw.scissor_y &&
						run_scissor_w == draw.scissor_w &&
						run_scissor_h == draw.scissor_h {
						run_vertex_count += 6
					} else {
						flush_run(
							state,
							pass,
							run_texture_idx,
							run_sampler,
							run_scissor_enabled,
							run_scissor_x,
							run_scissor_y,
							run_scissor_w,
							run_scissor_h,
							run_start_vertex,
							run_vertex_count,
							&draw_call_count,
						)
						run_texture_idx = tex_idx
						run_sampler = draw_sampler
						run_scissor_enabled = draw.scissor_enabled
						run_scissor_x = draw.scissor_x
						run_scissor_y = draw.scissor_y
						run_scissor_w = draw.scissor_w
						run_scissor_h = draw.scissor_h
						run_start_vertex = base_vertex
						run_vertex_count = 6
					}
					base_vertex += 6
				}
				flush_run(
					state,
					pass,
					run_texture_idx,
					run_sampler,
					run_scissor_enabled,
					run_scissor_x,
					run_scissor_y,
					run_scissor_w,
					run_scissor_h,
					run_start_vertex,
					run_vertex_count,
					&draw_call_count,
				)
				sdl.EndGPURenderPass(pass)
			}
			}
			render_end := time.now()
			if state.perf.enabled {
				state.perf.upload_ms += f64(time.duration_milliseconds(time.diff(upload_start, upload_end)))
				state.perf.render_ms += f64(time.duration_milliseconds(time.diff(render_start, render_end)))
			}
		}
		if state.perf.enabled {
			state.perf.build_ms += f64(time.duration_milliseconds(time.diff(build_start, build_end)))
		}
	}
	if len(state.draw_images) == 0 || state.pipeline == nil || state.sampler_nearest == nil || state.sampler_linear == nil {
		build_end := time.now()
		if state.perf.enabled {
			state.perf.build_ms += f64(time.duration_milliseconds(time.diff(build_start, build_end)))
		}
	}

	capture_requested := state.debug_capture_pending
	capture_transfer: ^sdl.GPUTransferBuffer
	if capture_requested {
		capture_size := int(swap_w) * int(swap_h) * 4
		tb_create := sdl.GPUTransferBufferCreateInfo{
			usage = .DOWNLOAD,
			size = u32(capture_size),
		}
		capture_transfer = sdl.CreateGPUTransferBuffer(state.device, tb_create)
		if capture_transfer == nil {
			log.errorf("SDL_CreateGPUTransferBuffer(capture) failed: %s", string(sdl.GetError()))
			state.debug_capture_ok = false
		} else {
			copy_pass := sdl.BeginGPUCopyPass(cmd)
			if copy_pass == nil {
				log.errorf("SDL_BeginGPUCopyPass(capture) failed: %s", string(sdl.GetError()))
				state.debug_capture_ok = false
				sdl.ReleaseGPUTransferBuffer(state.device, capture_transfer)
				capture_transfer = nil
			} else {
				src := sdl.GPUTextureRegion{
					texture = swap_texture,
					mip_level = 0,
					layer = 0,
					x = 0,
					y = 0,
					z = 0,
					w = swap_w,
					h = swap_h,
					d = 1,
				}
				dst := sdl.GPUTextureTransferInfo{
					transfer_buffer = capture_transfer,
					offset = 0,
					pixels_per_row = swap_w,
					rows_per_layer = swap_h,
				}
				sdl.DownloadFromGPUTexture(copy_pass, src, dst)
				sdl.EndGPUCopyPass(copy_pass)
			}
		}
	}

	submit_start := time.now()
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		log.errorf("SDL_SubmitGPUCommandBuffer failed: %s", string(sdl.GetError()))
	}
	submit_end := time.now()
	if capture_requested {
		_ = sdl.WaitForGPUIdle(state.device)
		if capture_transfer != nil {
			mapped := sdl.MapGPUTransferBuffer(state.device, capture_transfer, false)
			if mapped == nil {
				log.errorf("SDL_MapGPUTransferBuffer(capture) failed: %s", string(sdl.GetError()))
				state.debug_capture_ok = false
			} else {
				capture_size := int(swap_w) * int(swap_h) * 4
				raw := ([^]u8)(mapped)[:capture_size]
				bgra := state.swapchain_format == .B8G8R8A8_UNORM || state.swapchain_format == .B8G8R8A8_UNORM_SRGB
				state.debug_capture_ok = renderer_capture_write_ppm(
					state.debug_capture_path,
					raw,
					int(swap_w),
					int(swap_h),
					bgra_order = bgra,
					flip_y = false,
				)
				sdl.UnmapGPUTransferBuffer(state.device, capture_transfer)
			}
			sdl.ReleaseGPUTransferBuffer(state.device, capture_transfer)
		}
		state.debug_capture_done = true
		state.debug_capture_pending = false
	}
	now := time.now()
	state.perf.fps_frames += 1
	elapsed := time.diff(state.perf.fps_last_log, now)
	if elapsed >= time.Second {
		secs := f32(elapsed) / f32(time.Second)
		if secs > 0 {
			state.perf.fps_value = f32(state.perf.fps_frames) / secs
		}
		if state.perf.enabled {
			log.infof("fps: %.1f", state.perf.fps_value)
		}
		state.perf.fps_frames = 0
		state.perf.fps_last_log = now
	}
	if state.perf.enabled {
		state.perf.frames += 1
		state.perf.draw_images += draw_image_count
		state.perf.vertices += vertex_count
		state.perf.draw_calls += draw_call_count
		state.perf.acquire_ms += f64(time.duration_milliseconds(time.diff(acquire_start, acquire_end)))
		state.perf.submit_ms += f64(time.duration_milliseconds(time.diff(submit_start, submit_end)))
		perf_elapsed := time.diff(state.perf.last_log_time, now)
		if perf_elapsed >= time.Second {
			frames := math.max(1, state.perf.frames)
		log.infof(
			"sdlgpu perf: imgs/frame=%.1f verts/frame=%.1f draws/frame=%.1f acquire=%.2fms build=%.2fms upload=%.2fms render=%.2fms submit=%.2fms",
			f64(state.perf.draw_images) / f64(frames),
			f64(state.perf.vertices) / f64(frames),
			f64(state.perf.draw_calls) / f64(frames),
				state.perf.acquire_ms / f64(frames),
				state.perf.build_ms / f64(frames),
				state.perf.upload_ms / f64(frames),
				state.perf.render_ms / f64(frames),
				state.perf.submit_ms / f64(frames),
			)
			state.perf.last_log_time = now
			state.perf.frames = 0
			state.perf.draw_images = 0
			state.perf.vertices = 0
			state.perf.draw_calls = 0
			state.perf.acquire_ms = 0
			state.perf.build_ms = 0
			state.perf.upload_ms = 0
			state.perf.render_ms = 0
			state.perf.submit_ms = 0
		}
	}
}

@(private)
sdlgpu_destroy :: proc(state: ^Sdlgpu_Renderer_State) {
	if state.device != nil {
		_ = sdl.WaitForGPUIdle(state.device)
		if state.pipeline != nil {
			sdl.ReleaseGPUGraphicsPipeline(state.device, state.pipeline)
		}
		if state.vert_shader != nil {
			sdl.ReleaseGPUShader(state.device, state.vert_shader)
		}
		if state.frag_shader != nil {
			sdl.ReleaseGPUShader(state.device, state.frag_shader)
		}
		if state.sampler_nearest != nil {
			sdl.ReleaseGPUSampler(state.device, state.sampler_nearest)
		}
		if state.sampler_linear != nil {
			sdl.ReleaseGPUSampler(state.device, state.sampler_linear)
		}
		if state.vertex_buffer != nil {
			sdl.ReleaseGPUBuffer(state.device, state.vertex_buffer)
		}
		if state.vertex_transfer != nil {
			sdl.ReleaseGPUTransferBuffer(state.device, state.vertex_transfer)
		}
		for face in state.fonts {
			delete(face.glyphs)
		}
		delete(state.fonts)
		for tex in state.textures {
			if tex.handle != nil {
				sdl.ReleaseGPUTexture(state.device, tex.handle)
			}
		}
		delete(state.textures)
		if state.window != nil {
			sdl.ReleaseWindowFromGPUDevice(state.device, state.window)
		}
		sdl.DestroyGPUDevice(state.device)
	}
	state^ = {}
}

@(private)
sdlgpu_window_size :: proc(state: ^Sdlgpu_Renderer_State) -> (w, h: f32) {
	return state.window_width, state.window_height
}

@(private)
sdlgpu_measure_text_width :: proc(
	state: ^Sdlgpu_Renderer_State,
	font: Font_Face_Handle,
	text: string,
	size: int,
) -> f32 {
	if font.idx < 0 || font.idx >= len(state.fonts) {
		return f32(len(text)) * f32(size) * 0.5
	}
	face := state.fonts[font.idx]
	scale := f32(size) / f32(math.max(1, face.base_size))
	space_advance := face.missing_advance * scale
	if space_glyph, ok := face.glyphs[' ']; ok {
		space_advance = space_glyph.x_advance * scale
	}
	tab_advance := 4.0 * space_advance
	width: f32
	for r in text {
		if r == '\t' {
			width += tab_advance
			continue
		}
		if g, ok := face.glyphs[r]; ok {
			width += g.x_advance * scale
		} else {
			width += face.missing_advance * scale
		}
	}
	return width
}

@(private)
sdlgpu_set_scissor :: proc(state: ^Sdlgpu_Renderer_State, x, y: i32, w, h: u32) {
	state.scissor_enabled = true
	state.scissor_x = x
	state.scissor_y = y
	state.scissor_w = w
	state.scissor_h = h
}

@(private)
sdlgpu_clear_scissor :: proc(state: ^Sdlgpu_Renderer_State) {
	state.scissor_enabled = false
}

@(private)
sdlgpu_draw_rect :: proc(state: ^Sdlgpu_Renderer_State, pos: [2]f32, w, h: f32, color: Color) {
	if w <= 0 || h <= 0 || color[3] == 0 || !state.white_texture_ok {
		return
	}
	_sdlgpu_enqueue_image(
		state,
		state.white_texture,
		pos,
		{w, h},
		0,
		FULL_UV,
		_sdlgpu_color_to_f32(color),
		{SDLGPU_DRAW_MODE_SPRITE, 0, 0, 0},
	)
}

@(private)
sdlgpu_draw_triangle :: proc(state: ^Sdlgpu_Renderer_State, p1, p2, p3: [2]f32, color: Color) {
	if color[3] == 0 || !state.white_texture_ok {
		return
	}
	_sdlgpu_enqueue_image(
		state,
		state.white_texture,
		{},
		{},
		0,
		FULL_UV,
		_sdlgpu_color_to_f32(color),
		{SDLGPU_DRAW_MODE_TRIANGLE, 0, 0, 0},
		[3][2]f32{p1, p2, p3},
	)
}

@(private)
sdlgpu_draw_circle :: proc(state: ^Sdlgpu_Renderer_State, position: [2]f32, radius: f32, color: Color) {
	if radius <= 0 || color[3] == 0 || !state.white_texture_ok {
		return
	}
	diameter := radius
	_sdlgpu_enqueue_image(
		state,
		state.white_texture,
		position - [2]f32{diameter * 0.5, diameter * 0.5},
		{diameter, diameter},
		0,
		FULL_UV,
		_sdlgpu_color_to_f32(color),
		{SDLGPU_DRAW_MODE_CIRCLE, 0, 0, 0},
	)
}

@(private)
sdlgpu_draw_line :: proc(state: ^Sdlgpu_Renderer_State, from, to: [2]f32, thickness: int, color: Color) {
	if thickness <= 0 || color[3] == 0 || !state.white_texture_ok {
		return
	}
	thick := f32(math.max(1, thickness))
	delta := to - from
	dist := math.sqrt(delta.x * delta.x + delta.y * delta.y)
	if dist <= 0 {
		sdlgpu_draw_rect(state, from - {thick * 0.5, thick * 0.5}, thick, thick, color)
		return
	}
	angle := math.atan2(delta.y, delta.x)
	center := (from + to) * 0.5
	_sdlgpu_enqueue_image(
		state,
		state.white_texture,
		center - [2]f32{dist * 0.5, thick * 0.5},
		{dist, thick},
		angle,
		FULL_UV,
		_sdlgpu_color_to_f32(color),
		{SDLGPU_DRAW_MODE_SPRITE, 0, 0, 0},
	)
}

@(private)
sdlgpu_draw_lines :: proc(
	state: ^Sdlgpu_Renderer_State,
	thickness: int,
	color: Color,
	closed: bool,
	rounded: bool,
	points: [][2]f32,
) {
	if len(points) < 2 || thickness <= 0 {
		return
	}
	cap_diameter := f32(math.max(1, thickness))
	if rounded {
		for i in 0 ..< len(points) - 1 {
			sdlgpu_draw_circle(state, points[i], cap_diameter, color)
			sdlgpu_draw_circle(state, points[i + 1], cap_diameter, color)
		}
		if closed {
			sdlgpu_draw_circle(state, points[len(points) - 1], cap_diameter, color)
			sdlgpu_draw_circle(state, points[0], cap_diameter, color)
		}
	}
	for i in 0 ..< len(points) - 1 {
		sdlgpu_draw_line(state, points[i], points[i + 1], thickness, color)
	}
	if closed {
		sdlgpu_draw_line(state, points[len(points) - 1], points[0], thickness, color)
	}
}

@(private)
_apply_swapchain_params :: proc(state: ^Sdlgpu_Renderer_State) {
	if state == nil || state.device == nil || state.window == nil {
		return
	}
	if !sdl.SetGPUSwapchainParameters(
		state.device,
		state.window,
		state.swapchain_composition,
		state.present_mode,
	) {
		if state.swapchain_composition == .SDR_LINEAR {
			log.warnf(
				"SDL_SetGPUSwapchainParameters(.SDR_LINEAR) failed, falling back to .SDR: %s",
				string(sdl.GetError()),
			)
			state.swapchain_composition = .SDR
			if !sdl.SetGPUSwapchainParameters(
				state.device,
				state.window,
				state.swapchain_composition,
				state.present_mode,
			) {
				log.errorf("SDL_SetGPUSwapchainParameters fallback failed: %s", string(sdl.GetError()))
			}
		} else {
			log.errorf("SDL_SetGPUSwapchainParameters failed: %s", string(sdl.GetError()))
		}
	}
}

@(private)
sdlgpu_draw_text :: proc(
	state: ^Sdlgpu_Renderer_State,
	font: Font_Face_Handle,
	text: string,
	pos: [2]f32,
	size: int,
	color: Color,
) {
	if color[3] == 0 {
		return
	}
	if font.idx < 0 || font.idx >= len(state.fonts) {
		return
	}
	face := state.fonts[font.idx]
	if face.texture.idx < 0 || face.texture.idx >= len(state.textures) {
		return
	}
	glyph_scale := f32(size) / f32(math.max(1, face.base_size))
	space_advance := face.missing_advance * glyph_scale
	if space_glyph, ok := face.glyphs[' ']; ok {
		space_advance = space_glyph.x_advance * glyph_scale
	}
	tab_advance := 4.0 * space_advance
	baseline_y := pos.y + face.y_base * glyph_scale
	cursor := [2]f32{pos.x, baseline_y}
	for r in text {
		if r == '\n' {
			cursor.x = pos.x
			cursor.y += face.line_height * glyph_scale
			continue
		}
		if r == '\t' {
			cursor.x += tab_advance
			continue
		}

		if glyph, ok := face.glyphs[r]; ok {
			glyph_pos := [2]f32{
				cursor.x + glyph.x_offset * glyph_scale,
				cursor.y - face.y_base * glyph_scale + glyph.y_offset * glyph_scale,
			}
			_sdlgpu_enqueue_image(
				state,
				face.texture,
				glyph_pos,
				{glyph_scale, glyph_scale},
				0,
				glyph.uv_rect,
				_sdlgpu_color_to_f32(color),
				{SDLGPU_DRAW_MODE_MSDF, face.tex_size[0], face.tex_size[1], face.distance_range},
			)
			cursor.x += glyph.x_advance * glyph_scale
		} else {
			cursor.x += face.missing_advance * glyph_scale
		}
	}
}

@(private)
sdlgpu_draw_image :: proc(
	state: ^Sdlgpu_Renderer_State,
	texture: Texture_Handle,
	position: [2]f32,
	scale: [2]f32,
	rotation: f32,
	uv_rect: Rect,
) {
	_sdlgpu_enqueue_image(
		state,
		texture,
		position,
		scale,
		rotation,
		uv_rect,
		{1, 1, 1, 1},
		{SDLGPU_DRAW_MODE_SPRITE, 0, 0, 0},
	)
}

@(private)
sdlgpu_texture_load :: proc(
	state: ^Sdlgpu_Renderer_State,
	pixels: []Color,
	width, height: int,
) -> (
	Texture_Handle,
	bool,
) {
	return _sdlgpu_texture_upload(state, pixels, width, height)
}

@(private)
sdlgpu_texture_get_metrics :: proc(
	state: ^Sdlgpu_Renderer_State,
	handle: Texture_Handle,
) -> (
	Texture_Metrics,
	bool,
) {
	if handle.idx < 0 || handle.idx >= len(state.textures) {
		return {}, false
	}
	tex := state.textures[handle.idx]
	return Texture_Metrics{width = tex.width, height = tex.height}, true
}

@(private)
_sdlgpu_texture_upload :: proc(
	state: ^Sdlgpu_Renderer_State,
	pixels: []Color,
	width, height: int,
	apply_pma_srgb := true,
) -> (
	Texture_Handle,
	bool,
) {
	if state == nil || state.device == nil {
		log.error("SDL_GPU texture upload called before renderer device init")
		return {}, false
	}
	if width <= 0 || height <= 0 || len(pixels) == 0 {
		log.errorf("invalid texture upload dimensions/pixels: %dx%d len=%d", width, height, len(pixels))
		return {}, false
	}

	texture_format := sdl.GPUTextureFormat.R8G8B8A8_UNORM
	if apply_pma_srgb {
		texture_format = .R8G8B8A8_UNORM_SRGB
	}

	tex_create := sdl.GPUTextureCreateInfo{
		type = .D2,
		format = texture_format,
		usage = sdl.GPUTextureUsageFlags{.SAMPLER},
		width = sdl.Uint32(width),
		height = sdl.Uint32(height),
		layer_count_or_depth = 1,
		num_levels = 1,
		sample_count = ._1,
	}
	tex := sdl.CreateGPUTexture(state.device, tex_create)
	if tex == nil {
		log.errorf("SDL_CreateGPUTexture failed: %s", string(sdl.GetError()))
		return {}, false
	}

	upload_size := len(pixels) * size_of(Color)
	tb_create := sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size = sdl.Uint32(upload_size),
	}
	transfer := sdl.CreateGPUTransferBuffer(state.device, tb_create)
	if transfer == nil {
		log.errorf("SDL_CreateGPUTransferBuffer failed: %s", string(sdl.GetError()))
		sdl.ReleaseGPUTexture(state.device, tex)
		return {}, false
	}
	defer sdl.ReleaseGPUTransferBuffer(state.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(state.device, transfer, false)
	if mapped == nil {
		log.errorf("SDL_MapGPUTransferBuffer failed: %s", string(sdl.GetError()))
		sdl.ReleaseGPUTexture(state.device, tex)
		return {}, false
	}
	mem.copy(mapped, raw_data(pixels), upload_size)
	if apply_pma_srgb {
		mapped_pixels := ([^]Color)(mapped)[:len(pixels)]
		for &p in mapped_pixels {
			a := f32(p.a) / 255.0
			if a == 1 do continue
			if a == 0 {
				p.r, p.g, p.b = 0, 0, 0
				continue
			}

			srgb_color := [3]f32{f32(p.r) / 255, f32(p.g) / 255, f32(p.b) / 255}
			linear_color := linalg.vector3_srgb_to_linear(srgb_color)
			linear_color *= a
			srgb_color = linalg.vector3_linear_to_srgb(linear_color)

			p.r = u8(srgb_color.x * 255 + 0.5)
			p.g = u8(srgb_color.y * 255 + 0.5)
			p.b = u8(srgb_color.z * 255 + 0.5)
		}
	}
	sdl.UnmapGPUTransferBuffer(state.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(state.device)
	if cmd == nil {
		log.errorf("SDL_AcquireGPUCommandBuffer failed: %s", string(sdl.GetError()))
		sdl.ReleaseGPUTexture(state.device, tex)
		return {}, false
	}

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	if copy_pass == nil {
		log.errorf("SDL_BeginGPUCopyPass failed: %s", string(sdl.GetError()))
		_ = sdl.CancelGPUCommandBuffer(cmd)
		sdl.ReleaseGPUTexture(state.device, tex)
		return {}, false
	}

	src := sdl.GPUTextureTransferInfo{
		transfer_buffer = transfer,
		offset = 0,
		pixels_per_row = sdl.Uint32(width),
		rows_per_layer = sdl.Uint32(height),
	}
	dst := sdl.GPUTextureRegion{
		texture = tex,
		mip_level = 0,
		layer = 0,
		x = 0,
		y = 0,
		z = 0,
		w = sdl.Uint32(width),
		h = sdl.Uint32(height),
		d = 1,
	}
	sdl.UploadToGPUTexture(copy_pass, src, dst, false)
	sdl.EndGPUCopyPass(copy_pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) {
		log.errorf("SDL_SubmitGPUCommandBuffer failed: %s", string(sdl.GetError()))
		sdl.ReleaseGPUTexture(state.device, tex)
		return {}, false
	}
	_ = sdl.WaitForGPUIdle(state.device)

	idx := len(state.textures)
	append(&state.textures, Sdlgpu_Texture{handle = tex, width = width, height = height})
	return Texture_Handle{idx = idx}, true
}

@(private)
_sdlgpu_enqueue_image :: proc(
	state: ^Sdlgpu_Renderer_State,
	texture: Texture_Handle,
	position: [2]f32,
	scale: [2]f32,
	rotation: f32,
	uv_rect: Rect,
	color: [4]f32,
	params: [4]f32,
	tri_points := [3][2]f32{},
) {
	if state == nil {
		return
	}
	append(
		&state.draw_images,
		Sdlgpu_Draw_Image_Cmd{
			texture = texture,
			position = position,
			scale = scale,
			rotation = rotation,
			uv_rect = uv_rect,
			color = color,
			params = params,
			tri_points = tri_points,
			screen_mode = state.is_screen_mode,
			scissor_enabled = state.scissor_enabled,
			scissor_x = state.scissor_x,
			scissor_y = state.scissor_y,
			scissor_w = state.scissor_w,
			scissor_h = state.scissor_h,
		},
	)
}

@(private)
_sdlgpu_color_to_f32 :: proc(color: Color) -> [4]f32 {
	color_srgb := [4]f32{
		f32(color[0]) / 255.0,
		f32(color[1]) / 255.0,
		f32(color[2]) / 255.0,
		f32(color[3]) / 255.0,
	}
	alpha := color_srgb.w
	linear_rgb := linalg.vector3_srgb_to_linear([3]f32{color_srgb.x, color_srgb.y, color_srgb.z})
	linear_rgb *= alpha
	return {linear_rgb.x, linear_rgb.y, linear_rgb.z, alpha}
}

@(private)
_sdlgpu_world_to_screen :: proc(state: ^Sdlgpu_Renderer_State, pos: [2]f32, screen_mode: bool) -> [2]f32 {
	if screen_mode {
		return pos
	}
	return {
		(pos.x - state.cam_pos.x) * state.cam_zoom + state.window_width * 0.5,
		(pos.y - state.cam_pos.y) * state.cam_zoom + state.window_height * 0.5,
	}
}

@(private)
_sdlgpu_to_ndc :: proc(state: ^Sdlgpu_Renderer_State, pos: [2]f32) -> [2]f32 {
	w := f32(math.max(1, int(state.window_width)))
	h := f32(math.max(1, int(state.window_height)))
	return {
		(pos.x / w) * 2.0 - 1.0,
		1.0 - (pos.y / h) * 2.0,
	}
}

@(private)
_sdlgpu_append_draw_vertices :: proc(
	state: ^Sdlgpu_Renderer_State,
	verts: ^[dynamic]Sdlgpu_Vertex,
	draw: Sdlgpu_Draw_Image_Cmd,
) -> bool {
	if draw.texture.idx < 0 || draw.texture.idx >= len(state.textures) {
		return false
	}
	src_tex := state.textures[draw.texture.idx]
	if src_tex.handle == nil {
		return false
	}

	screen_pts: [4][2]f32
	uvs := [4][2]f32{
		{0, 0},
		{1, 0},
		{1, 1},
		{0, 1},
	}

	if draw.params[0] == SDLGPU_DRAW_MODE_TRIANGLE {
		screen_pts[0] = _sdlgpu_world_to_screen(state, draw.tri_points[0], draw.screen_mode)
		screen_pts[1] = _sdlgpu_world_to_screen(state, draw.tri_points[1], draw.screen_mode)
		screen_pts[2] = _sdlgpu_world_to_screen(state, draw.tri_points[2], draw.screen_mode)
		screen_pts[3] = screen_pts[0]
		uvs = [4][2]f32{
			{0, 0},
			{1, 0},
			{0.5, 1},
			{0, 0},
		}
	} else {
		uv := draw.uv_rect
		uv_w := math.abs(uv.w)
		uv_h := math.abs(uv.h)
		quad_w := f32(src_tex.width) * uv_w * draw.scale.x
		quad_h := f32(src_tex.height) * uv_h * draw.scale.y
		if !draw.screen_mode {
			quad_w *= state.cam_zoom
			quad_h *= state.cam_zoom
		}
		if quad_w <= 0 || quad_h <= 0 {
			return false
		}

		top_left := _sdlgpu_world_to_screen(state, draw.position, draw.screen_mode)
		center := top_left + [2]f32{quad_w * 0.5, quad_h * 0.5}
		c := math.cos(draw.rotation)
		s := math.sin(draw.rotation)

		corners := [4][2]f32{
			{-quad_w * 0.5, -quad_h * 0.5},
			{quad_w * 0.5, -quad_h * 0.5},
			{quad_w * 0.5, quad_h * 0.5},
			{-quad_w * 0.5, quad_h * 0.5},
		}
		for i in 0 ..< 4 {
			local := corners[i]
			screen_pts[i] = {
				center.x + local.x * c - local.y * s,
				center.y + local.x * s + local.y * c,
			}
		}
		uvs = [4][2]f32{
			{uv.x, uv.y},
			{uv.x + uv.w, uv.y},
			{uv.x + uv.w, uv.y + uv.h},
			{uv.x, uv.y + uv.h},
		}
	}

	ndc_pts: [4][2]f32
	for i in 0 ..< 4 {
		ndc_pts[i] = _sdlgpu_to_ndc(state, screen_pts[i])
	}

	indices := [6]int{0, 1, 2, 2, 3, 0}
	for ii in indices {
		append(
			verts,
			Sdlgpu_Vertex{
				position = ndc_pts[ii],
				uv = uvs[ii],
				color = draw.color,
				params = draw.params,
			},
		)
	}
	return true
}

@(private)
_sdlgpu_upload_vertices :: proc(
	state: ^Sdlgpu_Renderer_State,
	cmd: ^sdl.GPUCommandBuffer,
	verts: []Sdlgpu_Vertex,
) -> bool {
	if len(verts) == 0 {
		return true
	}
	byte_count := len(verts) * size_of(Sdlgpu_Vertex)
	if !_sdlgpu_ensure_vertex_capacity(state, byte_count) {
		return false
	}

	mapped := sdl.MapGPUTransferBuffer(state.device, state.vertex_transfer, true)
	if mapped == nil {
		log.errorf("SDL_MapGPUTransferBuffer(vertex) failed: %s", string(sdl.GetError()))
		return false
	}
	mem.copy(mapped, raw_data(verts), byte_count)
	sdl.UnmapGPUTransferBuffer(state.device, state.vertex_transfer)

	copy_pass := sdl.BeginGPUCopyPass(cmd)
	if copy_pass == nil {
		log.errorf("SDL_BeginGPUCopyPass(vertex) failed: %s", string(sdl.GetError()))
		return false
	}
	src := sdl.GPUTransferBufferLocation{
		transfer_buffer = state.vertex_transfer,
		offset = 0,
	}
	dst := sdl.GPUBufferRegion{
		buffer = state.vertex_buffer,
		offset = 0,
		size = u32(byte_count),
	}
	sdl.UploadToGPUBuffer(copy_pass, src, dst, true)
	sdl.EndGPUCopyPass(copy_pass)
	return true
}

@(private)
_sdlgpu_ensure_vertex_capacity :: proc(state: ^Sdlgpu_Renderer_State, bytes_needed: int) -> bool {
	if state.vertex_buffer != nil && state.vertex_transfer != nil && state.vertex_capacity >= bytes_needed {
		return true
	}

	new_capacity := bytes_needed
	if new_capacity < 64 * 1024 {
		new_capacity = 64 * 1024
	}
	if state.vertex_capacity > 0 && new_capacity < state.vertex_capacity * 2 {
		new_capacity = state.vertex_capacity * 2
	}

	if state.vertex_buffer != nil {
		sdl.ReleaseGPUBuffer(state.device, state.vertex_buffer)
		state.vertex_buffer = nil
	}
	if state.vertex_transfer != nil {
		sdl.ReleaseGPUTransferBuffer(state.device, state.vertex_transfer)
		state.vertex_transfer = nil
	}

	buf_create := sdl.GPUBufferCreateInfo{
		usage = sdl.GPUBufferUsageFlags{.VERTEX},
		size = u32(new_capacity),
	}
	state.vertex_buffer = sdl.CreateGPUBuffer(state.device, buf_create)
	if state.vertex_buffer == nil {
		log.errorf("SDL_CreateGPUBuffer(vertex) failed: %s", string(sdl.GetError()))
		return false
	}

	transfer_create := sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size = u32(new_capacity),
	}
	state.vertex_transfer = sdl.CreateGPUTransferBuffer(state.device, transfer_create)
	if state.vertex_transfer == nil {
		log.errorf("SDL_CreateGPUTransferBuffer(vertex) failed: %s", string(sdl.GetError()))
		sdl.ReleaseGPUBuffer(state.device, state.vertex_buffer)
		state.vertex_buffer = nil
		return false
	}

	state.vertex_capacity = new_capacity
	return true
}

@(private)
_sdlgpu_init_pipeline :: proc(state: ^Sdlgpu_Renderer_State) -> bool {
	if state == nil || state.device == nil || state.window == nil {
		return false
	}

	nearest_sampler_create := sdl.GPUSamplerCreateInfo{
		min_filter = .NEAREST,
		mag_filter = .NEAREST,
		mipmap_mode = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	}
	state.sampler_nearest = sdl.CreateGPUSampler(state.device, nearest_sampler_create)
	if state.sampler_nearest == nil {
		log.errorf("SDL_CreateGPUSampler(nearest) failed: %s", string(sdl.GetError()))
		return false
	}

	linear_sampler_create := sdl.GPUSamplerCreateInfo{
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		mipmap_mode = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	}
	state.sampler_linear = sdl.CreateGPUSampler(state.device, linear_sampler_create)
	if state.sampler_linear == nil {
		log.errorf("SDL_CreateGPUSampler(linear) failed: %s", string(sdl.GetError()))
		return false
	}

	vs_create := sdl.GPUShaderCreateInfo{
		code_size = len(SDLGPU_VERT_SPV_BYTES),
		code = raw_data(SDLGPU_VERT_SPV_BYTES),
		entrypoint = "main",
		format = sdl.GPUShaderFormat{.SPIRV},
		stage = .VERTEX,
		num_uniform_buffers = 0,
	}
	state.vert_shader = sdl.CreateGPUShader(state.device, vs_create)
	if state.vert_shader == nil {
		log.errorf("SDL_CreateGPUShader(vert) failed: %s", string(sdl.GetError()))
		return false
	}

	fs_create := sdl.GPUShaderCreateInfo{
		code_size = len(SDLGPU_FRAG_SPV_BYTES),
		code = raw_data(SDLGPU_FRAG_SPV_BYTES),
		entrypoint = "main",
		format = sdl.GPUShaderFormat{.SPIRV},
		stage = .FRAGMENT,
		num_samplers = 1,
		num_uniform_buffers = 0,
	}
	state.frag_shader = sdl.CreateGPUShader(state.device, fs_create)
	if state.frag_shader == nil {
		log.errorf("SDL_CreateGPUShader(frag) failed: %s", string(sdl.GetError()))
		return false
	}

	vb_desc := sdl.GPUVertexBufferDescription{
		slot = 0,
		pitch = u32(size_of(Sdlgpu_Vertex)),
		input_rate = .VERTEX,
	}
	v_attrs := [4]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = 0},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = u32(size_of([2]f32))},
		{
			location = 2,
			buffer_slot = 0,
			format = .FLOAT4,
			offset = u32(size_of([2]f32) + size_of([2]f32)),
		},
		{
			location = 3,
			buffer_slot = 0,
			format = .FLOAT4,
			offset = u32(size_of([2]f32) + size_of([2]f32) + size_of([4]f32)),
		},
	}

	color_blend := sdl.GPUColorTargetBlendState{
		src_color_blendfactor = .ONE,
		dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
		color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE,
		dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
		alpha_blend_op = .ADD,
		color_write_mask = sdl.GPUColorComponentFlags{.R, .G, .B, .A},
		enable_blend = true,
		enable_color_write_mask = true,
	}
	swap_format := sdl.GetGPUSwapchainTextureFormat(state.device, state.window)
	state.swapchain_format = swap_format
	log.infof("sdlgpu init: swapchain_format=%v", swap_format)
	color_target_desc := sdl.GPUColorTargetDescription{
		format = swap_format,
		blend_state = color_blend,
	}

	gp_create := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = state.vert_shader,
		fragment_shader = state.frag_shader,
		vertex_input_state = sdl.GPUVertexInputState{
			vertex_buffer_descriptions = &vb_desc,
			num_vertex_buffers = 1,
			vertex_attributes = raw_data(v_attrs[:]),
			num_vertex_attributes = len(v_attrs),
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = sdl.GPURasterizerState{
			fill_mode = .FILL,
			cull_mode = .NONE,
			front_face = .COUNTER_CLOCKWISE,
			enable_depth_clip = true,
		},
		multisample_state = sdl.GPUMultisampleState{
			sample_count = ._1,
		},
		depth_stencil_state = sdl.GPUDepthStencilState{
			compare_op = .ALWAYS,
		},
		target_info = sdl.GPUGraphicsPipelineTargetInfo{
			color_target_descriptions = &color_target_desc,
			num_color_targets = 1,
		},
	}
	state.pipeline = sdl.CreateGPUGraphicsPipeline(state.device, gp_create)
	if state.pipeline == nil {
		log.errorf("SDL_CreateGPUGraphicsPipeline failed: %s", string(sdl.GetError()))
		return false
	}

	return true
}
