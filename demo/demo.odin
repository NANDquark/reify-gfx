package demo

import re ".."
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:slice"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 800
HEIGHT :: 600

scroll_offset: [2]f64
renderer: re.Renderer = {}

main :: proc() {
	context.logger = log.create_console_logger()

	// SETUP WINDOW
	glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_X11) // RenderDoc can only handle X11
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
	glfw.SetWindowSizeCallback(window, window_size)
	glfw.SetScrollCallback(window, scroll)
	window_width, window_height := glfw.GetWindowSize(window)
	re.init(&renderer, window)

	tree_img := load_tile_img()
	defer image.destroy(tree_img)
	tree_pixels := slice.reinterpret([]re.Color, tree_img.pixels.buf[:])
	tree_tex := re.texture_load(&renderer, tree_pixels, tree_img.width, tree_img.height)
	tree_sprite := re.sprite_create(&renderer, tree_tex, 16, 16)

	cam_pos := [2]f32{120, 120}
	cam_zoom: f32 = 1
	last_mouse_pos: [2]f64
	frame_delta_time: time.Duration
	last_frame_time := time.now()
	for !glfw.WindowShouldClose(window) {
		frame_start_time := time.now()
		frame_delta_time = time.diff(last_frame_time, frame_start_time)
		dt := f32(time.duration_seconds(frame_delta_time))
		last_frame_time = frame_start_time

		glfw.PollEvents()

		// Draw!
		fctx := re.start(&renderer, cam_pos, cam_zoom)

		// batch 1 - draw shapes in the world, affected by camera
		re.draw_sprite(&renderer, tree_sprite, {0, 0}, color = re.Color{255, 0, 0, 128}) // tint it red and half-transparent for fun
		re.draw_rect(&renderer, {-50, -50}, 50, 50, re.Color{255, 0, 0, 255})
		re.draw_circle(&renderer, {50, 50}, 50, re.Color{0, 255, 0, 255})
		re.draw_triangle(&renderer, {40, -40}, {70, -40}, {55, -60}, re.Color{255, 0, 255, 255})
		re.draw_line(&renderer, {-30, 30}, {-70, 60}, 3, re.Color{200, 64, 0, 255})

		// batch 2 - draw on the screen, not the world!
		re.begin_screen_mode(&renderer)
		re.draw_circle(
			&renderer,
			{f32(window_width) / 2, f32(window_height) / 2},
			100,
			re.Color{0, 0, 0, 255},
		)
		re.end_screen_mode(&renderer)

		re.present(&renderer)
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
