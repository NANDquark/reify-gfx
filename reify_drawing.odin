package reify

import "core:encoding/json"
import "core:image"
import "core:math/linalg"

draw_rect :: proc(r: ^Renderer, pos: [2]f32, w, h: f32, color: Color) {
	if r.perf.enabled do r.perf.draw_rects += 1
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_rect(r, pos, w, h, color)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_rect(r, pos, w, h, color)
	}
}

draw_triangle :: proc(r: ^Renderer, p1, p2, p3: [2]f32, color: Color) {
	if r.perf.enabled do r.perf.draw_rects += 1
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_triangle(r, p1, p2, p3, color)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_triangle(r, p1, p2, p3, color)
	}
}

draw_circle :: proc(r: ^Renderer, position: [2]f32, radius: f32, color: Color) {
	if r.perf.enabled do r.perf.draw_rects += 1
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_circle(r, position, radius, color)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_circle(r, position, radius, color)
	}
}

draw_line :: proc(r: ^Renderer, from, to: [2]f32, thickness: int, color: Color) {
	if r.perf.enabled do r.perf.draw_lines += 1
	drawing_line_segment(r, from, to, thickness, color, false)
}

draw_lines :: proc(r: ^Renderer, thickness: int, color: Color, closed, rounded: bool, points: [][2]f32) {
	if r.perf.enabled do r.perf.draw_linesets += 1
	if len(points) < 2 || thickness <= 0 do return
	for i in 0 ..< len(points) - 1 {
		drawing_line_segment(r, points[i], points[i + 1], thickness, color, rounded)
	}
	if closed {
		drawing_line_segment(r, points[len(points) - 1], points[0], thickness, color, rounded)
	}
}

draw_text :: proc(r: ^Renderer, font: Font_Face_Handle, text: string, pos: [2]f32, size: int, color: Color) {
	if r.perf.enabled do r.perf.draw_texts += 1
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_text(r, font, text, pos, size, color)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_text(r, font, text, pos, size, color)
	}
}

draw_fps :: proc(r: ^Renderer, font: Font_Face_Handle, pos: [2]f32, size: int) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_fps(r, font, pos, size)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_fps(r, font, pos, size)
	}
}

draw_image :: proc(
	r: ^Renderer,
	texture: Texture_Handle,
	position: [2]f32,
	scale: [2]f32 = {1, 1},
	rotation: f32 = 0,
	uv_rect: Rect = FULL_UV,
	rgb_tint: [3]u8 = {255, 255, 255},
	alpha: f32 = 1,
	is_additive: bool = false,
) {
	if r.perf.enabled do r.perf.draw_images += 1
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_image(
			r, texture, position,
			rotation = rotation, scale = scale, uv_rect = uv_rect,
			rgb_tint = rgb_tint, alpha = alpha, is_additive = is_additive,
		)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_image(
			r, texture, position,
			rotation = rotation, scale = scale, uv_rect = uv_rect,
			rgb_tint = rgb_tint, alpha = alpha, is_additive = is_additive,
		)
	}
}

@(private)
drawing_line_segment :: proc(r: ^Renderer, from, to: [2]f32, thickness: int, color: Color, rounded: bool) {
	when RENDERER_BACKEND == "vulkan13" {
		vulkan13_draw_line(r, from, to, thickness, color, rounded)
	} else when RENDERER_BACKEND == "vulkan11" {
		vulkan11_draw_line(r, from, to, thickness, color, rounded)
	}
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
