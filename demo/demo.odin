package demo

import re ".."
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:math"
import "core:slice"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 800
HEIGHT :: 600

FONT_ATLAS_JSON_BYTES :: #load("../assets/fonts/noto-sans-latin-400-normal-msdf.json")
FONT_ATLAS_IMG_BYTES :: #load("../assets/fonts/noto-sans-latin-400-normal.png")

scroll_offset: [2]f64
renderer: re.Renderer = {}

main :: proc() {
	context.logger = log.create_console_logger()

	// SETUP WINDOW
	when ODIN_OS == .Linux {
		glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11) // RenderDoc can only handle X11
	}
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
	if !re.vulkan_init() {
		panic("failed to initialize Vulkan loader (missing Vulkan runtime/loader?)")
	}
	defer re.vulkan_shutdown()
	glfw.SetWindowSizeCallback(window, window_size)
	glfw.SetScrollCallback(window, scroll)
	window_width, window_height := glfw.GetWindowSize(window)

	re.init(&renderer, {WIDTH, HEIGHT}, glfw.GetRequiredInstanceExtensions())
	surface: vk.SurfaceKHR
	glfw.CreateWindowSurface(renderer.gpu.instance, window, nil, &surface)
	re.set_surface(&renderer, surface)

	// ASSET LOADING
	tree_img := load_tile_img()
	defer image.destroy(tree_img)
	tree_pixels := slice.reinterpret([]re.Color, tree_img.pixels.buf[:])
	tree_tex := re.texture_load(&renderer, tree_pixels, tree_img.width, tree_img.height)

	tilemap_img := load_tilemap()
	defer image.destroy(tilemap_img)
	tilemap_pixels := slice.reinterpret([]re.Color, tilemap_img.pixels.buf[:])
	tilemap_tex := re.texture_load(
		&renderer,
		tilemap_pixels,
		tilemap_img.width,
		tilemap_img.height,
	)
	mushroom_uv_rect := re.Rect {
		x = f32(85) / f32(tilemap_img.width),
		y = f32(34) / f32(tilemap_img.height),
		w = f32(16) / f32(tilemap_img.width),
		h = f32(16) / f32(tilemap_img.height),
	}

	font, font_err := re.font_load(&renderer, FONT_ATLAS_JSON_BYTES, FONT_ATLAS_IMG_BYTES)
	if font_err != nil {
		panic(fmt.tprintf("failed to load font, err=%v", font_err))
	}

	// MAIN LOOP
	cam_pos := [2]f32{100, 100}
	cam_zoom: f32 = 1
	frame_delta_time: time.Duration
	last_frame_time := time.now()
	for !glfw.WindowShouldClose(window) {
		frame_start_time := time.now()
		frame_delta_time = time.diff(last_frame_time, frame_start_time)
		last_frame_time = frame_start_time

		glfw.PollEvents()

		// Draw!
		re.start(&renderer, cam_pos, cam_zoom)

		// batch 1 - draw shapes in the world, affected by camera (default projection)
		re.draw_image(&renderer, tree_tex, {0, 0})
		pulse := f32(math.sin(glfw.GetTime() * 2.0) + 1.0) * 0.5
		// little fake glow effect
		re.draw_image(
			&renderer,
			tree_tex,
			{0, -2},
			scale = {1 + pulse * 0.25, 1 + pulse * 0.25},
			alpha = pulse,
			rgb_tint = {100, 200, 255},
			is_additive = true,
		)
		re.draw_rect(&renderer, {-50, -50}, 50, 50, re.Color{255, 0, 0, 255})
		re.draw_triangle(&renderer, {40, -40}, {70, -40}, {55, -60}, re.Color{255, 0, 255, 255})
		re.draw_line(&renderer, {-30, 30}, {-70, 60}, 3, re.Color{200, 64, 0, 255})
		re.draw_circle(&renderer, {50, 50}, 50, re.Color{0, 255, 0, 128})
		re.draw_image(&renderer, tilemap_tex, {-50, 0}, uv_rect = mushroom_uv_rect) // example using tilemap and sub uv rect

		// batch 2 - draw on the screen, not the world!
		re.begin_screen_mode(&renderer)
		re.draw_circle(
			&renderer,
			{f32(window_width) / 2, f32(window_height) / 2},
			100,
			re.Color{0, 0, 0, 255},
		)
		p0 := [2]f32{f32(window_width) / 2 - 300, f32(window_height) / 2 + 200}
		re.draw_text(
			&renderer,
			font,
			"gbc DEi	1`2~3	!-@=#\nabcdefghijklmnopqrstuvwxyz",
			p0,
			42,
			allocator = context.temp_allocator,
		)
		re.end_screen_mode(&renderer)

		re.present(&renderer)
		free_all(context.temp_allocator)
	}
}

window_size :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	context = runtime.default_context()
	re.window_resize(&renderer, width, height)
}

scroll :: proc "c" (window: glfw.WindowHandle, x_offset, y_offset: f64) {
	context = runtime.default_context()
	scroll_offset = [2]f64{x_offset, y_offset}
}

tree_TILE_BYTES :: #load("../assets/sprites/kenney_tiny-town/Tiles/tile_0003.png")

load_tile_img :: proc() -> ^image.Image {
	img, err := png.load_from_bytes(tree_TILE_BYTES)
	assert(err == nil, fmt.tprintf("failed to load tree, err=%v", err))
	assert(img.channels == 4 && img.depth == 8, "RGBA8 is the only supported format so far")
	return img
}

TILEMAP_BYTES :: #load("../assets/sprites/kenney_tiny-town/tilemap.png")

load_tilemap :: proc() -> ^image.Image {
	img, err := png.load_from_bytes(TILEMAP_BYTES)
	assert(err == nil, fmt.tprintf("failed to load tilemap", err))
	assert(img.channels == 4 && img.depth == 8, "RGBA8 is the only supported format so far")
	return img
}
