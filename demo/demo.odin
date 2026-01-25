package demo

import re ".."
import "base:runtime"
import "core:c"
import "core:log"
import "core:math/linalg"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

WIDTH :: 800
HEIGHT :: 600

scroll_offset: [2]f64

main :: proc() {
	context.logger = log.create_console_logger()

	// SETUP WINDOW
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
	window_height, window_width := glfw.GetWindowSize(window)
	re.init(window)

	shader_data := re.Shader_Data {
		light_pos = [4]f32{0, -10, 10, 0},
		selected  = 1,
	}
	cam_pos := [3]f32{0.0, 0.0, -6.0}
	object_rotations := [3][3]f32{}
	last_mouse_pos: [2]f64
	frame_delta_time: time.Duration
	last_frame_time := time.now()
	for !glfw.WindowShouldClose(window) {
		frame_start_time := time.now()
		frame_delta_time = time.diff(last_frame_time, frame_start_time)
		last_frame_time = frame_start_time

		glfw.PollEvents()
		// Rotate with mouse drag
		mouse_x, mouse_y := glfw.GetCursorPos(window)
		mouse_pos := [2]f64{mouse_x, mouse_y}
		if glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
			delta := last_mouse_pos - mouse_pos
			sensitivity :: 0.005
			object_rotations[shader_data.selected].x += f32(-delta.y) * sensitivity // -y to account for y-axis flip
			object_rotations[shader_data.selected].y -= f32(delta.x) * sensitivity
		}
		last_mouse_pos = mouse_pos
		// Zoom with mouse wheel
		if scroll_offset != {} {
			cam_pos.z += f32(scroll_offset.y) * 0.025 * f32(frame_delta_time)
		}
		//
		// Update shader data
		window_ratio := f32(window_width) / f32(window_height)
		shader_data.projection = linalg.matrix4_perspective(linalg.PI / 4, window_ratio, 0.1, 32)
		shader_data.view = linalg.matrix4_translate(cam_pos)
		for i in 0 ..< 3 {
			instance_pos := [3]f32{f32(i - 1) * 3, 0, 0}
			rotation_quat := linalg.quaternion_from_euler_angles(
				object_rotations[i].x,
				object_rotations[i].y,
				object_rotations[i].z,
				.XYZ,
			)
			rotation_mat := linalg.matrix4_from_quaternion(rotation_quat)
			translation_mat := linalg.matrix4_translate(instance_pos)
			shader_data.model[i] = translation_mat * rotation_mat
		}
		re.draw(&shader_data)
	}
}

window_size :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	context = runtime.default_context()
	re.window_resize(width, height)
}

scroll :: proc "c" (window: glfw.WindowHandle, x_offset, y_offset: f64) {
	context = runtime.default_context()
	scroll_offset = [2]f64{x_offset, y_offset}
}
