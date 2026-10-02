package sdl_vulkan

import re "../.."
import "core:c"
import "core:time"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

main :: proc() {
	if !sdl.Init({.VIDEO}) do panic(string(sdl.GetError()))
	defer sdl.Quit()
	window := sdl.CreateWindow(
		"Reify SDL Vulkan",
		800,
		600,
		{.VULKAN, .RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	if window == nil do panic(string(sdl.GetError()))
	defer sdl.DestroyWindow(window)
	r := new(re.Renderer)
	defer free(r)
	err := re.init(
		r,
		{platform = sdl_platform(window), logical_size = {800, 600}, config = {vsync = true}},
	)
	if err.category != .None do panic(re.error_message(&err))
	defer re.destroy(r)
	frame_limit :: int(#config(Example_Frames, 0))
	frames := 0
	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if event.type == .QUIT do running = false
		}
		w, h: c.int
		if !sdl.GetWindowSize(window, &w, &h) do panic(string(sdl.GetError()))
		re.window_resize(r, i32(w), i32(h))
		re.start(r, {0, 0}, 1)
		re.begin_screen_mode(r)
		re.draw_rect(r, {40, 40}, 120, 80, {80, 180, 255, 255})
		re.end_screen_mode(r)
		if err := re.present(r); err.category != .None do panic(re.error_message(&err))
		frames += 1
		if frame_limit > 0 && frames >= frame_limit do break
		time.sleep(10 * time.Millisecond)
		free_all(context.temp_allocator)
	}
}

sdl_platform :: proc(window: ^sdl.Window) -> re.Platform_Interface {
	return {
		user_data = window,
		get_framebuffer_size = sdl_framebuffer_size,
		vulkan = {
			required_instance_extensions = sdl_extensions,
			create_surface = sdl_surface_create,
			destroy_surface = sdl_surface_destroy,
		},
	}
}

sdl_extensions :: proc(data: rawptr) -> ([]cstring, re.Platform_Error) {
	count: u32
	names := sdl.Vulkan_GetInstanceExtensions(&count)
	if names == nil do return nil, {message = string(sdl.GetError())}
	return names[:count], {}
}

sdl_framebuffer_size :: proc(data: rawptr) -> ([2]int, re.Platform_Error) {
	w, h: c.int
	if !sdl.GetWindowSizeInPixels(cast(^sdl.Window)data, &w, &h) do return {}, {message = string(sdl.GetError())}
	return {int(w), int(h)}, {}
}

sdl_surface_create :: proc(
	data: rawptr,
	instance: vk.Instance,
) -> (
	vk.SurfaceKHR,
	re.Platform_Error,
) {
	surface: vk.SurfaceKHR
	if !sdl.Vulkan_CreateSurface(cast(^sdl.Window)data, instance, nil, &surface) do return {}, {message = string(sdl.GetError())}
	return surface, {}
}

sdl_surface_destroy :: proc(data: rawptr, instance: vk.Instance, surface: vk.SurfaceKHR) {
	sdl.Vulkan_DestroySurface(instance, surface, nil)
}
