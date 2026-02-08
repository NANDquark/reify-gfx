package font_msdf_gen

import msdf "../../lib/msdfgen"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

FIRST_CODEPOINT :: 32
LAST_CODEPOINT :: 255

FONT_SIZE_PX :: 42.0
PX_RANGE :: 4.0
EDGE_ANGLE_THRESHOLD :: 3.0

ATLAS_WIDTH_PX :: 512
ATLAS_MIN_HEIGHT_PX :: 64
ATLAS_PADDING_PX :: 2 // Extra spacing between glyph quads to reduce texture bleed on GPU sampling.

MAX_ATLAS_DIMENSION_PX :: 4096
MISSING_GLYPH_ID :: 0
MISSING_GLYPH_CHAR :: ""

FONT_TTF_FILENAMES :: [2]string{
	"noto-sans-latin-400-normal.ttf",
	"noto-sans-latin-ext-400-normal.ttf",
}
ATLAS_PNG_FILENAME :: "noto-sans-latin-400-normal.png"
ATLAS_JSON_FILENAME :: "noto-sans-latin-400-normal-msdf.json"
FONT_FACE_NAME :: "noto-sans-latin-400-normal"

main :: proc() {
	if err := run(); err != nil {
		panic(fmt.tprintf("font_msdf_gen failed, err=%v", err))
	}
}

Error :: union #shared_nil {
	Tool_Error,
	json.Marshal_Error,
	os.Error,
}

Tool_Error :: enum {
	FreeType_Init_Failed,
	Font_Load_Failed,
	Glyph_Load_Failed,
	Invalid_Glyph_Shape,
	No_Valid_Glyphs,
	Glyph_Too_Wide,
	Atlas_Too_Tall,
	PNG_Write_Failed,
	JSON_Write_Failed,
}

BMFont_JSON :: struct {
	pages:          []string `json:"pages"`,
	chars:          []BMFont_Char `json:"chars"`,
	info:           BMFont_Info `json:"info"`,
	common:         BMFont_Common `json:"common"`,
	distance_field: BMFont_Distance_Field `json:"distanceField"`,
	kernings:       []BMFont_Kerning `json:"kernings"`,
}

BMFont_Info :: struct {
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

BMFont_Common :: struct {
	line_height: int `json:"lineHeight"`,
	base:        int `json:"base"`,
	scale_w:     int `json:"scaleW"`,
	scale_h:     int `json:"scaleH"`,
	pages:       int `json:"pages"`,
	packed:      int `json:"packed"`,
	alpha_chnl:  int `json:"alphaChnl"`,
	red_chnl:    int `json:"redChnl"`,
	green_chnl:  int `json:"greenChnl"`,
	blue_chnl:   int `json:"blueChnl"`,
}

BMFont_Distance_Field :: struct {
	field_type:     string `json:"fieldType"`,
	distance_range: int `json:"distanceRange"`,
}

BMFont_Char :: struct {
	id:       int `json:"id"`,
	index:    int `json:"index"`,
	char:     string `json:"char"`,
	width:    int `json:"width"`,
	height:   int `json:"height"`,
	xoffset:  int `json:"xoffset"`,
	yoffset:  int `json:"yoffset"`,
	xadvance: int `json:"xadvance"`,
	chnl:     int `json:"chnl"`,
	x:        int `json:"x"`,
	y:        int `json:"y"`,
	page:     int `json:"page"`,
}

BMFont_Kerning :: struct {
	first:  int `json:"first"`,
	second: int `json:"second"`,
	amount: int `json:"amount"`,
}

Glyph_Record :: struct {
	id:                int,
	index:             int,
	char:              string,
	source_font_index: int,
	source_glyph_index: u32,
	advance:           f64,
	bounds:            msdf.Bounds,
	has_shape:         bool,
	width:             int,
	height:            int,
	xoffset:           int,
	yoffset:           int,
	xadvance:          int,
	x:                 int,
	y:                 int,
}

run :: proc() -> Error {
	tool_dir := #directory
	font_dir := filepath.join([]string{tool_dir, "../../assets/fonts"})
	png_path := filepath.join([]string{font_dir, ATLAS_PNG_FILENAME})
	json_path := filepath.join([]string{font_dir, ATLAS_JSON_FILENAME})

	ft := msdf.freetype_initialize()
	if ft == nil {
		return .FreeType_Init_Failed
	}
	defer msdf.freetype_deinitialize(ft)

	loaded_fonts := make([dynamic]^msdf.FontHandle, 0, len(FONT_TTF_FILENAMES))
	defer delete(loaded_fonts)

	loaded_font_files := make([dynamic]string, 0, len(FONT_TTF_FILENAMES))
	defer delete(loaded_font_files)

	font_ttf_filenames := FONT_TTF_FILENAMES
	for i in 0 ..< len(font_ttf_filenames) {
		filename := font_ttf_filenames[i]
		ttf_path := filepath.join([]string{font_dir, filename})
		ttf_path_c, _ := strings.clone_to_cstring(ttf_path, context.temp_allocator)
		font := msdf.font_load(ft, ttf_path_c)
		if font == nil {
			fmt.printfln("Warning: failed to load font: %s", ttf_path)
			continue
		}
		append(&loaded_fonts, font)
		append(&loaded_font_files, filename)
	}
	defer for font in loaded_fonts {
		msdf.font_destroy(font)
	}

	if len(loaded_fonts) == 0 {
		return .Font_Load_Failed
	}

	glyphs, line_height, base, missing_codepoints, layout_err := collect_glyph_layout(loaded_fonts[:])
	if layout_err != nil {
		return layout_err
	}
	defer delete(glyphs)
	defer delete(missing_codepoints)
	if !append_missing_placeholder_glyph(&glyphs, loaded_fonts[:], base) {
		return .No_Valid_Glyphs
	}

	atlas_w, atlas_h, pack_err := pack_glyphs(&glyphs)
	if pack_err != nil {
		return pack_err
	}

	atlas_pixels := make([]f32, atlas_w * atlas_h * 3)
	defer delete(atlas_pixels)

	config := msdf.make_msdf_generator_config(
		overlap_support = true,
		error_correction_mode = .EDGE_PRIORITY,
	)

	degraded_codepoints := make([dynamic]int, 0, 16)
	defer delete(degraded_codepoints)

	scale := FONT_SIZE_PX
	unit_range := PX_RANGE / scale

	for i in 0 ..< len(glyphs) {
		g := &glyphs[i]
		if g.width <= 0 || g.height <= 0 || !g.has_shape {
			continue
		}
		if g.source_font_index < 0 || g.source_font_index >= len(loaded_fonts) {
			append(&degraded_codepoints, g.id)
			continue
		}
		if g.source_glyph_index == 0 && g.id != MISSING_GLYPH_ID {
			append(&degraded_codepoints, g.id)
			continue
		}
		if g.id != MISSING_GLYPH_ID {
			render_glyph_index: u32
			if !msdf.font_get_glyph_index(loaded_fonts[g.source_font_index], rune(g.id), &render_glyph_index) || render_glyph_index != g.source_glyph_index {
				append(&degraded_codepoints, g.id)
				continue
			}
		}

		shape := msdf.Shape_create()
		if shape == nil {
			append(&degraded_codepoints, g.id)
			continue
		}

		advance: f64
		ok := msdf.font_load_glyph_by_index(
			shape,
			loaded_fonts[g.source_font_index],
			g.source_glyph_index,
			.FONT_SCALING_EM_NORMALIZED,
			&advance,
		)
		if !ok {
			msdf.Shape_destroy(shape)
			append(&degraded_codepoints, g.id)
			continue
		}

		msdf.Shape_normalize(shape)
		msdf.Shape_orientContours(shape)
		if !msdf.Shape_validate(shape) {
			msdf.Shape_destroy(shape)
			append(&degraded_codepoints, g.id)
			continue
		}

		shape_w := g.bounds.r - g.bounds.l
		shape_h := g.bounds.t - g.bounds.b
		if shape_w <= 0 || shape_h <= 0 {
			msdf.Shape_destroy(shape)
			append(&degraded_codepoints, g.id)
			continue
		}

		msdf.edgeColoringSimple(shape, EDGE_ANGLE_THRESHOLD, u64(g.id))

		glyph_pixels := make([]f32, g.width * g.height * 3)
		bitmap := msdf.make_bitmap_section_f32_3(
			raw_data(glyph_pixels),
			c.int(g.width),
			c.int(g.height),
			.TOP_DOWN,
		)

		transform := msdf.make_sdf_transformation(
			scale = msdf.Vector2{scale, scale},
			translate = msdf.Vector2 {
				-g.bounds.l + f64(ATLAS_PADDING_PX) / scale,
				-g.bounds.b + f64(ATLAS_PADDING_PX) / scale,
			},
			range = msdf.Range{lower = -0.5 * unit_range, upper = 0.5 * unit_range},
		)
		msdf.generateMSDF(&bitmap, shape, &transform, &config)

		for row in 0 ..< g.height {
			dst_start := ((g.y + row) * atlas_w + g.x) * 3
			src_start := row * g.width * 3
			copy(
				atlas_pixels[dst_start:dst_start + g.width * 3],
				glyph_pixels[src_start:src_start + g.width * 3],
			)
		}

		delete(glyph_pixels)
		msdf.Shape_destroy(shape)
	}

	atlas_bitmap := msdf.make_bitmap_section_f32_3(
		raw_data(atlas_pixels),
		c.int(atlas_w),
		c.int(atlas_h),
		.TOP_DOWN,
	)
	png_path_c, _ := strings.clone_to_cstring(png_path, context.temp_allocator)
	if !msdf.save_png_f32_3(&atlas_bitmap, png_path_c) {
		return .PNG_Write_Failed
	}

	charset := make([dynamic]string, 0, len(glyphs))
	defer delete(charset)
	json_chars := make([dynamic]BMFont_Char, 0, len(glyphs))
	defer delete(json_chars)
	for g in glyphs {
		append(&charset, g.char)
		append(
			&json_chars,
			BMFont_Char {
				id = g.id,
				index = g.index,
				char = g.char,
				width = g.width,
				height = g.height,
				xoffset = g.xoffset,
				yoffset = g.yoffset,
				xadvance = g.xadvance,
				chnl = 15,
				x = g.x,
				y = g.y,
				page = 0,
			},
		)
	}

	output := BMFont_JSON {
		pages = []string{ATLAS_PNG_FILENAME},
		chars = json_chars[:],
		info = BMFont_Info {
			face = FONT_FACE_NAME,
			size = int(FONT_SIZE_PX),
			bold = 0,
			italic = 0,
			charset = charset[:],
			unicode = 1,
			stretch_h = 100,
			smooth = 1,
			aa = 1,
			padding = [4]int {
				ATLAS_PADDING_PX,
				ATLAS_PADDING_PX,
				ATLAS_PADDING_PX,
				ATLAS_PADDING_PX,
			},
			spacing = [2]int{0, 0},
		},
		common = BMFont_Common {
			line_height = line_height,
			base = base,
			scale_w = atlas_w,
			scale_h = atlas_h,
			pages = 1,
			packed = 0,
			alpha_chnl = 0,
			red_chnl = 0,
			green_chnl = 0,
			blue_chnl = 0,
		},
		distance_field = BMFont_Distance_Field {
			field_type = "msdf",
			distance_range = int(PX_RANGE),
		},
		kernings = []BMFont_Kerning{},
	}

	json_bytes, err := json.marshal(output, {pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		return err
	}
	defer delete(json_bytes)

	ok := os.write_entire_file(json_path, json_bytes)
	if !ok {
		return .JSON_Write_Failed
	}

	fmt.printfln("Generated atlas PNG:  %s", png_path)
	fmt.printfln("Generated atlas JSON: %s", json_path)
	fmt.printfln("Glyphs: %d (U+%04X..U+%04X)", len(glyphs), FIRST_CODEPOINT, LAST_CODEPOINT)
	fmt.printfln("Atlas: %dx%d", atlas_w, atlas_h)
	fmt.printfln("Loaded fonts: %d/%d", len(loaded_fonts), len(font_ttf_filenames))
	for i in 0 ..< len(loaded_font_files) {
		fmt.printfln("  [%d] %s", i, loaded_font_files[i])
	}
	if len(missing_codepoints) > 0 {
		print_codepoint_summary("Warning: missing glyphs in all fonts", missing_codepoints[:])
	}
	if len(degraded_codepoints) > 0 {
		print_codepoint_summary("Warning: glyph render degraded", degraded_codepoints[:])
	}

	return nil
}

collect_glyph_layout :: proc(
	fonts: []^msdf.FontHandle,
) -> (
	glyphs: [dynamic]Glyph_Record,
	line_height: int,
	base: int,
	missing_codepoints: [dynamic]int,
	err: Tool_Error,
) {
	glyphs = make([dynamic]Glyph_Record, 0, LAST_CODEPOINT - FIRST_CODEPOINT + 1)
	missing_codepoints = make([dynamic]int, 0, 8)

	max_top: f64 = -1e30
	min_bottom: f64 = 1e30
	has_any_valid_shape := false

	for codepoint := FIRST_CODEPOINT; codepoint <= LAST_CODEPOINT; codepoint += 1 {
		glyph_runes: [1]rune
		glyph_runes[0] = rune(codepoint)

		glyph := Glyph_Record {
			id = codepoint,
			index = codepoint - FIRST_CODEPOINT,
			char = utf8.runes_to_string(glyph_runes[:]),
			source_font_index = -1,
			source_glyph_index = 0,
			x = 0,
			y = 0,
		}

		has_any_load := false
		has_shape := false
		metric_advance: f64 = 0

		for font_index in 0 ..< len(fonts) {
			glyph_index: u32
			if !msdf.font_get_glyph_index(fonts[font_index], rune(codepoint), &glyph_index) {
				continue
			}
			if glyph_index == 0 {
				continue
			}

			shape := msdf.Shape_create()
			if shape == nil {
				delete(glyphs)
				delete(missing_codepoints)
				return nil, 0, 0, nil, .Glyph_Load_Failed
			}

			advance: f64
			ok := msdf.font_load_glyph(
				shape,
				fonts[font_index],
				rune(codepoint),
				.FONT_SCALING_EM_NORMALIZED,
				&advance,
			)
			if !ok {
				msdf.Shape_destroy(shape)
				continue
			}

				if !has_any_load {
					has_any_load = true
					metric_advance = advance
					glyph.source_font_index = font_index
					glyph.source_glyph_index = glyph_index
				}

			msdf.Shape_normalize(shape)
			msdf.Shape_orientContours(shape)

			bounds := msdf.shape_get_bounds(shape)
			is_valid_shape := msdf.Shape_validate(shape) && (bounds.r > bounds.l) && (bounds.t > bounds.b)
				if is_valid_shape {
					has_shape = true
					glyph.source_font_index = font_index
					glyph.source_glyph_index = glyph_index
					glyph.advance = advance
					glyph.bounds = bounds
				msdf.Shape_destroy(shape)
				break
			}

			msdf.Shape_destroy(shape)
		}

		if has_shape {
			glyph.has_shape = true
			has_any_valid_shape = true
			max_top = max(max_top, glyph.bounds.t)
			min_bottom = min(min_bottom, glyph.bounds.b)

			ink_w := int(math.ceil((glyph.bounds.r - glyph.bounds.l) * FONT_SIZE_PX))
			ink_h := int(math.ceil((glyph.bounds.t - glyph.bounds.b) * FONT_SIZE_PX))
			glyph.width = max(1, ink_w + 2 * ATLAS_PADDING_PX)
			glyph.height = max(1, ink_h + 2 * ATLAS_PADDING_PX)
			glyph.xoffset = int(math.floor(glyph.bounds.l * FONT_SIZE_PX)) - ATLAS_PADDING_PX
			glyph.xadvance = int(math.round(glyph.advance * FONT_SIZE_PX))
		} else {
			glyph.has_shape = false
			glyph.width = 0
			glyph.height = 0
			glyph.xoffset = 0
			glyph.yoffset = 0

			if has_any_load {
				glyph.advance = metric_advance
				glyph.xadvance = int(math.round(metric_advance * FONT_SIZE_PX))
			} else {
				glyph.advance = 0
				glyph.xadvance = 0
				if unicode.is_print(rune(codepoint)) {
					append(&missing_codepoints, codepoint)
				}
			}
		}

		append(&glyphs, glyph)
	}

	if !has_any_valid_shape {
		delete(glyphs)
		delete(missing_codepoints)
		return nil, 0, 0, nil, .No_Valid_Glyphs
	}

	line_height = int(math.ceil((max_top - min_bottom) * FONT_SIZE_PX)) + 2 * ATLAS_PADDING_PX
	base = int(math.ceil(max_top * FONT_SIZE_PX)) + ATLAS_PADDING_PX

	for i in 0 ..< len(glyphs) {
		g := &glyphs[i]
		if g.has_shape {
			glyph_top := int(math.ceil(g.bounds.t * FONT_SIZE_PX)) + ATLAS_PADDING_PX
			g.yoffset = base - glyph_top
		} else {
			g.yoffset = 0
		}
	}

	return glyphs, line_height, base, missing_codepoints, nil
}

append_missing_placeholder_glyph :: proc(
	glyphs: ^[dynamic]Glyph_Record,
	fonts: []^msdf.FontHandle,
	base: int,
) -> bool {
	for font_index in 0 ..< len(fonts) {
		shape := msdf.Shape_create()
		if shape == nil {
			return false
		}

		advance: f64
		ok := msdf.font_load_glyph_by_index(
			shape,
			fonts[font_index],
			0,
			.FONT_SCALING_EM_NORMALIZED,
			&advance,
		)
		if !ok {
			msdf.Shape_destroy(shape)
			continue
		}

		msdf.Shape_normalize(shape)
		msdf.Shape_orientContours(shape)

		bounds := msdf.shape_get_bounds(shape)
		if !msdf.Shape_validate(shape) || bounds.r <= bounds.l || bounds.t <= bounds.b {
			msdf.Shape_destroy(shape)
			continue
		}

		ink_w := int(math.ceil((bounds.r - bounds.l) * FONT_SIZE_PX))
		ink_h := int(math.ceil((bounds.t - bounds.b) * FONT_SIZE_PX))
		glyph_top := int(math.ceil(bounds.t * FONT_SIZE_PX)) + ATLAS_PADDING_PX

		append(
			glyphs,
			Glyph_Record{
				id = MISSING_GLYPH_ID,
				index = len(glyphs^),
				char = MISSING_GLYPH_CHAR,
				source_font_index = font_index,
				source_glyph_index = 0,
				advance = advance,
				bounds = bounds,
				has_shape = true,
				width = max(1, ink_w + 2 * ATLAS_PADDING_PX),
				height = max(1, ink_h + 2 * ATLAS_PADDING_PX),
				xoffset = int(math.floor(bounds.l * FONT_SIZE_PX)) - ATLAS_PADDING_PX,
				yoffset = base - glyph_top,
				xadvance = int(math.round(advance * FONT_SIZE_PX)),
				x = 0,
				y = 0,
			},
		)
		msdf.Shape_destroy(shape)
		return true
	}

	return false
}

pack_glyphs :: proc(
	glyphs: ^[dynamic]Glyph_Record,
) -> (
	atlas_w: int,
	atlas_h: int,
	err: Tool_Error,
) {
	atlas_w = ATLAS_WIDTH_PX

	place_order := make([dynamic]int, 0, len(glyphs^))
	defer delete(place_order)

	for i in 0 ..< len(glyphs^) {
		g := glyphs^[i]
		if g.width > atlas_w {
			return 0, 0, .Glyph_Too_Wide
		}
		if g.width > 0 && g.height > 0 && g.has_shape {
			append(&place_order, i)
		}
	}

	for i in 0 ..< len(place_order) {
		max_idx := i
		for j in i + 1 ..< len(place_order) {
			lhs := glyphs^[place_order[j]].height
			rhs := glyphs^[place_order[max_idx]].height
			if lhs > rhs {
				max_idx = j
			}
		}
		if max_idx != i {
			place_order[i], place_order[max_idx] = place_order[max_idx], place_order[i]
		}
	}

	x, y, row_h := 0, 0, 0
	for glyph_index in place_order {
		g := &glyphs^[glyph_index]
		if x + g.width > atlas_w {
			y += row_h + ATLAS_PADDING_PX
			x = 0
			row_h = 0
		}

		g.x = x
		g.y = y

		x += g.width + ATLAS_PADDING_PX
		row_h = max(row_h, g.height)
	}

	used_h := y + row_h
	if used_h <= 0 {
		used_h = ATLAS_MIN_HEIGHT_PX
	}
	atlas_h = max(ATLAS_MIN_HEIGHT_PX, next_pow2(used_h))
	if atlas_h > MAX_ATLAS_DIMENSION_PX {
		return 0, 0, .Atlas_Too_Tall
	}

	return atlas_w, atlas_h, nil
}

print_codepoint_summary :: proc(label: string, codepoints: []int) {
	fmt.printfln("%s (%d)", label, len(codepoints))
	for cp in codepoints {
		fmt.printfln("  - '%s'", visible_rune_for_log(rune(cp)))
	}
}

visible_rune_for_log :: proc(r: rune) -> string {
	display_rune := r

	// Render control characters and space as visible glyphs in logs.
	if r == ' ' {
		display_rune = '␠'
	} else if r >= 0x00 && r <= 0x1f {
		display_rune = rune(0x2400 + r)
	} else if r == 0x7f {
		display_rune = '␡'
	}

	runes: [1]rune
	runes[0] = display_rune
	return utf8.runes_to_string(runes[:])
}

next_pow2 :: proc(v: int) -> int {
	if v <= 1 {
		return 1
	}

	p := 1
	for p < v {
		p *= 2
	}
	return p
}
