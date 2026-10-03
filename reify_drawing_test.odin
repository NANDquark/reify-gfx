package reify

import "core:testing"

@(test)
font_layout_consumes_face_data :: proc(t: ^testing.T) {
	face := Font_Face {
		size = 10, line_height = 14, y_base = 10, tex_size = {100, 100},
	}
	face.glyphs = make([dynamic]Font_Face_Glyph)
	face.glyph_lookup = make(map[rune]int)
	defer font_face_destroy(&face)
	append(&face.glyphs,
		Font_Face_Glyph{r = 'A', width = 5, height = 8, x_offset = 1, y_offset = 2, x_advance = 6, uv_rect = {0, 0, 0.05, 0.08}},
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
