package demo

import re ".."
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:math/linalg"
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

	grass_img := load_tile_img()
	defer image.destroy(grass_img)
	grass_pixels := slice.reinterpret([]re.Color, grass_img.pixels.buf[:])
	grass_tex := re.texture_load(&renderer, grass_pixels, grass_img.width, grass_img.height)
	grass_sprite := re.sprite_create(&renderer, grass_tex, 16, 16)

	cam_pos := [3]f32{0, 0, 0}
	last_mouse_pos: [2]f64
	frame_delta_time: time.Duration
	last_frame_time := time.now()
	for !glfw.WindowShouldClose(window) {
		frame_start_time := time.now()
		frame_delta_time = time.diff(last_frame_time, frame_start_time)
		dt := f32(time.duration_seconds(frame_delta_time))
		last_frame_time = frame_start_time

		glfw.PollEvents()
		// Zoom with mouse wheel
		if scroll_offset != {} {
			cam_pos.z += f32(scroll_offset.y) * 0.025 * dt
		}

		// Update shader data
		// TODO: move projection inside Renderer
		window_ratio := f32(window_width) / f32(window_height)
		projection := linalg.matrix_ortho3d(0, f32(window_width), 0, f32(window_height), -1, 1)
			// odinfmt: disable
		vk_correction := re.Mat4f{
			1, 0, 0,   0,
			0, 1, 0,   0,
			0, 0, 0.5, 0.5,
			0, 0, 0,   1,
		}
		projection = vk_correction * projection
		// odinfmt: enable

		// TODO: convert into camera movement procs on renderer with cam_pos
		// stored internally
		view := linalg.matrix4_translate(cam_pos)

		// Draw!
		fctx := re.start(&renderer, projection, view)
		instance_pos := [2]f32{f32(window_width) / 2, f32(window_height) / 2}
		re.draw_sprite(&renderer, grass_sprite, instance_pos)
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

GRASS_TILE_BYTES :: #load("../assets/sprites/kenney_tiny-town/Tiles/tile_0003.png")

load_tile_img :: proc() -> ^image.Image {
	img, err := png.load_from_bytes(GRASS_TILE_BYTES)
	assert(err == nil, fmt.tprintf("failed to load grass, err=%v", err))
	assert(img.channels == 4 && img.depth == 8, "RGBA8 is the only supported format so far")
	return img
}
