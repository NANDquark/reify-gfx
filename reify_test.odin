package reify

import "core:log"
import "core:strings"
import "core:testing"

@(test)
public_failure_results_and_logging :: proc(t: ^testing.T) {
	capture: Public_Error_Log
	context.logger = {procedure = public_error_log, data = &capture}
	testing.expect(t, !init(nil, {}))
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "renderer pointer is nil"))
	testing.expect_value(t, capture.level, log.Level.Error)
	testing.expect(t, !present(nil))
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "renderer is not initialized"))
	texture, texture_ok := texture_load(nil, nil, 1, 1)
	testing.expect(t, !texture_ok && texture.idx == -1)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "texture_load"))
	font, font_ok := font_load(nil, nil, nil)
	testing.expect(t, !font_ok && font.idx == -1)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "font_load"))
	testing.expect_value(t, capture.calls, 4)
}

@(test)
public_rejected_frame_logging_and_reset :: proc(t: ^testing.T) {
	capture: Public_Error_Log
	context.logger = {procedure = public_error_log, data = &capture}
	r := new(Renderer)
	defer free(r)
	r.allocator = context.allocator
	r.initialized = true
	r.gpu.limits.instances = 1
	defer for &frame in r.frame_contexts do delete(frame.draw_batches)
	start(r, {}, 1)
	draw_rect(r, {}, 1, 1, {})
	draw_rect(r, {}, 1, 1, {})
	draw_rect(r, {}, 1, 1, {})
	testing.expect_value(t, capture.calls, 1)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "instance capacity"))
	testing.expect(t, !present(r) && !r.stopped && !r.frame_started)
	testing.expect_value(t, capture.calls, 1)
	start(r, {}, 1)
	testing.expect(t, !r.frame_failed && r.frame_started)
	draw_image(r, {idx = -1}, {})
	testing.expect(t, !present(r) && !r.stopped)
	testing.expect_value(t, capture.calls, 2)
	testing.expect(t, strings.contains(string(capture.message[:capture.length]), "invalid texture handle"))
}

@(private)
Public_Error_Log :: struct {
	message: [1024]u8,
	length, calls: int,
	level: log.Level,
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
