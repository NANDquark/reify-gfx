// Source: https://gist.github.com/Tekkitslime/c9dff12cabf6339a27876b9b57c5ba43
// Modified by NANDquark

package obj

// Implemented from this wikipedia article:
// https://en.wikipedia.org/wiki/Wavefront_.obj_file
// this obj loader does not support relative indices (-1 to reference last vertex.)
// no free-form geometry support.
// limited transparency support.
// moderate mtl file support

// TODO better transparency support.
// TODO better mtl file support.
// TODO free-form geometry support.
// TODO relative vertex support.

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import stbi "vendor:stb/image"

Vertex_Position :: distinct [4]f32
Vertex_UV :: distinct [3]f32
Vertex_Normal :: distinct [3]f32
Face_Element :: struct {
	position, uv, normal: [3]uint,
	smoothing:            bool,
	material:             ^Material `fmt:"p"`,
}

Group :: struct {
	name:            string,
	vertex_position: []Vertex_Position,
	vertex_normal:   []Vertex_Normal,
	vertex_uv:       []Vertex_UV,
	face_element:    []Face_Element,
}

Image :: struct {
	width, height, depth: i32,
	data:                 []u8 `fmt:"p"`,
}

Material :: struct {
	name:                   string, // newmtl name
	ambient_color:          [3]f32, // Ka 0.0 0.0 0.0
	diffuse_color:          [3]f32, // Kd 0.0 0.0 0.0
	specular_color:         [3]f32, // Ks 0.0 0.0 0.0
	emissive_color:         [3]f32, // Ke 0.0 0.0 0.0
	specular_exponent:      f32, // Ns 0.0
	transparency:           f32, // `d 0.1` or `Tr 0.9`
	optical_density:        f32, // Ni 1.45

	// 0. Color on and Ambient off
	// 1. Color on and Ambient on
	// 2. Highlight on
	// 3. Reflection on and Ray trace on
	// 4. Transparency: Glass on, Reflection: Ray trace on
	// 5. Reflection: Fresnel on and Ray trace on
	// 6. Transparency: Refraction on, Reflection: Fresnel off and Ray trace on
	// 7. Transparency: Refraction on, Reflection: Fresnel on and Ray trace on
	// 8. Reflection on and Ray trace off
	// 9. Transparency: Glass on, Reflection: Ray trace off
	// 10. Casts shadows onto invisible surfaces
	illumination_model:     uint,
	ambient_map:            Image, // map_Ka ambient.png
	diffuse_map:            Image, // map_Kd diffuse.png
	specular_map:           Image, // map_Ks specular.png
	specular_highlight_map: Image, // map_Ns specular_highlight.png
	alpha_map:              Image, // map_d alpha.png
	bump_map:               Image, // `map_bump bump.png` or `bump bump.png`
	displacement_map:       Image, // disp displacement.png
	decal_texture:          Image, // decal decal.png
}

Object :: struct {
	name:   string,
	groups: []Group,
}

OBJ_File :: struct {
	objects:   []Object,
	materials: []Material,
}

@(export)
load_obj_file_from_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	obj_file: OBJ_File,
	ok: bool,
) {
	code, ok_code := os.read_entire_file(path, allocator)
	if !ok_code {return}
	defer delete(code)

	directory := filepath.dir(path)
	defer delete(directory)
	obj_file, ok = parse_obj(string(code), directory)
	if !ok {
		delete_obj_file(obj_file)
		return
	}

	return obj_file, true
}

delete_group :: proc(g: Group) {
	delete(g.vertex_position)
	delete(g.vertex_uv)
	delete(g.vertex_normal)
	delete(g.face_element)
	delete(g.name)
}

delete_object :: proc(object: Object) {
	delete(object.name)
	for g in object.groups {
		delete_group(g)
	}
	delete(object.groups)
}

delete_obj_file :: proc(obj_file: OBJ_File) {
	for o in obj_file.objects {delete_object(o)}
	delete(obj_file.objects)
	delete_mtllib(obj_file.materials)
}

load_image_from_file :: proc(
	filename, directory: string,
	flip: bool = true,
	allocator := context.allocator,
) -> (
	image: Image,
	ok: bool,
) {
	buf: [1024]u8
	full_path := fmt.bprint(buf[:], ".", directory, filename, sep = "/")

	data, ok_data := os.read_entire_file(full_path, allocator)
	if !ok_data {return}
	defer delete(data)

	bytes := stbi.load_from_memory(
		raw_data(data),
		i32(len(data)),
		&image.width,
		&image.height,
		&image.depth,
		0,
	)

	if bytes == nil {return}
	image.data = slice.bytes_from_ptr(bytes, int(image.width * image.height * image.depth))

	return image, true
}

delete_image :: proc(image: Image) {
	stbi.image_free(raw_data(image.data))
}

load_mtllib_from_file :: proc(
	filename, directory: string,
	allocator := context.allocator,
) -> (
	mtllib: []Material,
	ok: bool,
) {
	buf: [1024]u8
	full_path := fmt.bprint(buf[:], ".", directory, filename, sep = "/")

	code, ok_code := os.read_entire_file(full_path, allocator)
	if !ok_code {return}
	defer delete(code)

	mtllib, ok = parse_mtllib(string(code), directory)
	if !ok {
		delete_mtllib(mtllib)
		return
	}

	return mtllib, true
}

delete_mtllib :: proc(mtllib: []Material) {
	for m in mtllib {
		delete(m.name)
		delete_image(m.ambient_map)
		delete_image(m.diffuse_map)
		delete_image(m.specular_map)
		delete_image(m.specular_highlight_map)
		delete_image(m.alpha_map)
		delete_image(m.bump_map)
		delete_image(m.displacement_map)
		delete_image(m.decal_texture)
	}
	delete(mtllib)
}

parse_uint :: proc(line: string) -> (res: uint, ok: bool) {
	nr: int
	num, _ := strconv.parse_uint(line, 0, &nr)

	return num, nr > 0
}

parse_vec3f32_strict :: proc(line: string) -> (res: [3]f32, ok: bool) {
	num1, nr1, ok1 := strconv.parse_f32_prefix(line)
	if !ok1 || nr1 + 1 >= len(line) || line[nr1] != ' ' {return}

	num2, nr2, ok2 := strconv.parse_f32_prefix(line[nr1 + 1:])
	if !ok2 || nr1 + nr2 + 2 >= len(line) || line[nr1 + nr2 + 1] != ' ' {return}

	num3, nr3, ok3 := strconv.parse_f32_prefix(line[nr1 + nr2 + 2:])
	if !ok3 {return}

	return {num1, num2, num3}, true
}

parse_vec3f32 :: proc(line: string, last_default: f32) -> (res: [3]f32, ok: bool) {
	num1, nr1, ok1 := strconv.parse_f32_prefix(line)
	if !ok1 || nr1 + 1 >= len(line) {return}

	num2, nr2, ok2 := strconv.parse_f32_prefix(line[nr1 + 1:])
	if !ok2 {return}

	if nr1 + nr2 + 2 >= len(line) {
		return {num1, num2, last_default}, true
	}

	num3, nr3, ok3 := strconv.parse_f32_prefix(line[nr1 + nr2 + 2:])
	if !ok3 {return}

	return {num1, num2, num3}, true
}

parse_vec4f32 :: proc(line: string, last_default: f32) -> (res: [4]f32, ok: bool) {
	num1, nr1, ok1 := strconv.parse_f32_prefix(line)
	if !ok1 || nr1 + 1 >= len(line) {return}

	num2, nr2, ok2 := strconv.parse_f32_prefix(line[nr1 + 1:])
	if !ok2 || nr1 + nr2 + 2 >= len(line) {return}

	num3, nr3, ok3 := strconv.parse_f32_prefix(line[nr1 + nr2 + 2:])
	if !ok3 {return}

	if nr1 + nr2 + nr3 + 3 >= len(line) {
		return {num1, num2, num3, last_default}, true
	}

	num4, nr4, ok4 := strconv.parse_f32_prefix(line[nr1 + nr2 + nr3 + 3:])
	if !ok4 {return}

	return {num1, num2, num3, num4}, true
}


// f1: uint
// f2: uint/uint
// f3: uint//uint
// f4: uint/uint/uint
parse_face_triplet :: proc(line: string) -> (elem: [3]uint, n: int, ok: bool) {
	pos, nr: int
	if len(line) == 0 {return}

	num1, _ := strconv.parse_uint(line, 0, &nr)
	if nr == 0 {return}
	pos += nr
	if len(line) - pos == 0 || line[pos] == ' ' {return {num1, 0, 0}, pos, true}
	if line[pos] == '/' {pos += 1}

	if len(line) - pos == 0 {return}

	num2, _ := strconv.parse_uint(line[pos:], 0, &nr)
	if nr == 0 {num2 = 0}
	pos += nr
	if len(line) - pos == 0 || (line[pos] == ' ') {return {num1, num2, 0}, pos, true}
	if line[pos] == '/' {pos += 1}

	num3, _ := strconv.parse_uint(line[pos:], 0, &nr)
	if nr == 0 {return}
	pos += nr
	if len(line) - pos == 0 || (line[pos] == ' ') {return {num1, num2, num3}, pos, true}

	return
}

parse_face_elements :: proc(
	line: string,
	b: ^OBJ_Builder,
	allocator := context.allocator,
) -> (
	ok: bool,
) {
	context.allocator = allocator

	pos: int
	if len(line) == 0 {return}

	// Temporary storage for indices on this line
	temp_triplets: [dynamic][3]uint
	defer delete(temp_triplets)

	remaining := line
	for len(remaining) > 0 {
		remaining = strings.trim_left(remaining, " ")
		if len(remaining) == 0 {break}

		elem, nr, ok_triplet := parse_face_triplet(remaining)
		if !ok_triplet || nr == 0 {break}

		append(&temp_triplets, elem)
		remaining = remaining[nr:]
	}

	if len(temp_triplets) < 3 {return false}

	// Fan Triangulation:
	// This turns a quad (0, 1, 2, 3) into two tris: (0, 1, 2) and (0, 2, 3)
	for i in 1 ..< len(temp_triplets) - 1 {
		face: Face_Element

		// Vertex 0 (Anchor)
		face.position[0] = temp_triplets[0][0]
		face.uv[0] = temp_triplets[0][1]
		face.normal[0] = temp_triplets[0][2]

		// Vertex i
		face.position[1] = temp_triplets[i][0]
		face.uv[1] = temp_triplets[i][1]
		face.normal[1] = temp_triplets[i][2]

		// Vertex i+1
		face.position[2] = temp_triplets[i + 1][0]
		face.uv[2] = temp_triplets[i + 1][1]
		face.normal[2] = temp_triplets[i + 1][2]

		builder_write_face_element(b, face)
	}

	return true
}

parse_name :: proc(line: string) -> (str: string, ok: bool) {
	if strings.contains_space(line) {return}
	return line, true
}

OBJ_Builder :: struct {
	smoothing:               bool,
	cur_material:            ^Material,
	object_name, group_name: string,
	object:                  [dynamic]Object,
	group:                   [dynamic]Group,
	vertex_position:         [dynamic]Vertex_Position,
	vertex_normal:           [dynamic]Vertex_Normal,
	vertex_uv:               [dynamic]Vertex_UV,
	face_element:            [dynamic]Face_Element,
	material:                [dynamic]Material,
}

init_builder :: proc(b: ^OBJ_Builder) {
	b.object = make([dynamic]Object)
	b.group = make([dynamic]Group)
	b.vertex_position = make([dynamic]Vertex_Position)
	b.vertex_normal = make([dynamic]Vertex_Normal)
	b.vertex_uv = make([dynamic]Vertex_UV)
	b.face_element = make([dynamic]Face_Element)
	b.material = make([dynamic]Material)
}

delete_builder :: proc(b: ^OBJ_Builder) {
	delete(b.object)
	delete(b.group)
	delete(b.vertex_position)
	delete(b.vertex_normal)
	delete(b.vertex_uv)
	delete(b.face_element)
	delete(b.material)
}

builder_write_object :: proc(b: ^OBJ_Builder, o: Object) {
	builder_flush_object(b)
	append(&b.object, o)
}

builder_write_group :: proc(b: ^OBJ_Builder, g: Group) {
	builder_flush_group(b)
	append(&b.group, g)
}

builder_flush_object :: proc(b: ^OBJ_Builder) {
	if len(b.object) > 0 {
		cur_object := &b.object[len(b.object) - 1]
		cur_object.name = strings.clone(b.object_name)
		cur_object.groups = slice.clone(b.group[:])
		clear(&b.group)
	}
}

builder_flush_group :: proc(b: ^OBJ_Builder) {
	if len(b.group) > 0 {
		cur_group := &b.group[len(b.group) - 1]
		cur_group.name = strings.clone(b.group_name)
		cur_group.vertex_position = slice.clone(b.vertex_position[:])
		cur_group.vertex_normal = slice.clone(b.vertex_normal[:])
		cur_group.vertex_uv = slice.clone(b.vertex_uv[:])
		cur_group.face_element = slice.clone(b.face_element[:])
		clear(&b.vertex_position)
		clear(&b.vertex_normal)
		clear(&b.vertex_uv)
		clear(&b.face_element)
	}
}

builder_flush :: proc(b: ^OBJ_Builder) {
	builder_flush_group(b)
	builder_flush_object(b)
}

builder_write_vertex_position :: proc(b: ^OBJ_Builder, vp: Vertex_Position) {
	if len(b.object) == 0 {append(&b.object, Object{})}
	if len(b.group) == 0 {append(&b.group, Group{})}
	append(&b.vertex_position, vp)
}

builder_write_vertex_uv :: proc(b: ^OBJ_Builder, vt: Vertex_UV) {
	if len(b.object) == 0 {append(&b.object, Object{})}
	if len(b.group) == 0 {append(&b.group, Group{})}
	append(&b.vertex_uv, vt)
}

builder_write_vertex_normal :: proc(b: ^OBJ_Builder, vn: Vertex_Normal) {
	if len(b.object) == 0 {append(&b.object, Object{})}
	if len(b.group) == 0 {append(&b.group, Group{})}
	append(&b.vertex_normal, vn)
}

builder_write_face_element :: proc(b: ^OBJ_Builder, f: Face_Element) {
	if len(b.object) == 0 {append(&b.object, Object{})}
	if len(b.group) == 0 {append(&b.group, Group{})}
	f := f
	f.smoothing = b.smoothing
	f.material = b.cur_material
	append(&b.face_element, f)
}

builder_write_material :: proc(b: ^OBJ_Builder, material: ..Material) {
	for m in material {
		append(&b.material, m)
	}
}

builder_write :: proc {
	builder_write_object,
	builder_write_group,
	builder_write_vertex_position,
	builder_write_vertex_uv,
	builder_write_vertex_normal,
	builder_write_face_element,
	builder_write_material,
}

builder_set_smoothing :: proc(b: ^OBJ_Builder, smoothing: bool) {
	b.smoothing = smoothing
}

builder_set_material :: proc(b: ^OBJ_Builder, material_name: string) {
	if material, ok := builder_check_for_material(b, material_name); ok {
		b.cur_material = material
	}
}

builder_check_for_material :: proc(b: ^OBJ_Builder, material_name: string) -> (^Material, bool) {
	for &m in b.material {
		if m.name == material_name {return &m, true}
	}
	return nil, false
}

builder_to_object_file :: proc(b: ^OBJ_Builder) -> OBJ_File {
	builder_flush(b)
	file: OBJ_File
	file.objects = slice.clone(b.object[:])
	file.materials = slice.clone(b.material[:])
	return file
}

parse_mtllib :: proc(
	mtllib_data, directory: string,
	allocator := context.allocator,
) -> (
	mtllib: []Material,
	ok: bool,
) {
	mtllib_data := mtllib_data

	ok = true
	index: int
	mtllib_builder: [dynamic]Material
	cur_material: ^Material

	for _line in strings.split_lines_iterator(&mtllib_data) {
		index += 1
		line := strings.trim(_line, "\r\t\v ")

		if len(line) == 0 || line[0] == '#' {continue}

		switch {
		case strings.starts_with(line, "newmtl "):
			{
				if name, ok_name := parse_name(line[7:]); ok_name {
					append(&mtllib_builder, Material{name = strings.clone(name)})
					cur_material = &mtllib_builder[len(mtllib_builder) - 1]
				} else {ok = false}
			}

		case strings.starts_with(line, "Ka "):
			{
				if color, ok_color := parse_vec3f32_strict(line[3:]); ok_color {
					if cur_material != nil {
						cur_material.ambient_color = color
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "Kd "):
			{
				if color, ok_color := parse_vec3f32_strict(line[3:]); ok_color {
					if cur_material != nil {
						cur_material.diffuse_color = color
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "Ks "):
			{
				if color, ok_color := parse_vec3f32_strict(line[3:]); ok_color {
					if cur_material != nil {
						cur_material.specular_color = color
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "Ke "):
			{
				if color, ok_color := parse_vec3f32_strict(line[3:]); ok_color {
					if cur_material != nil {
						cur_material.emissive_color = color
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "Ns "):
			{
				if value, _, ok_value := strconv.parse_f32_prefix(line[3:]); ok_value {
					if cur_material != nil && (value >= 0.0) && (value <= 1000.0) {
						cur_material.specular_exponent = value
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "Tr "):
			{
				if value, _, ok_value := strconv.parse_f32_prefix(line[3:]); ok_value {
					if cur_material != nil && (value >= 0.0) && (value <= 1.0) {
						cur_material.transparency = 1.0 - value
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "d "):
			{
				if value, _, ok_value := strconv.parse_f32_prefix(line[2:]); ok_value {
					if cur_material != nil && (value >= 0.0) && (value <= 1.0) {
						cur_material.transparency = value
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "Ni "):
			{
				if value, _, ok_value := strconv.parse_f32_prefix(line[3:]); ok_value {
					if cur_material != nil && (value >= 0.001) && (value <= 10.0) {
						cur_material.transparency = value
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "illum "):
			{
				if value, ok_value := parse_uint(line[6:]); ok_value {
					if cur_material != nil && (value >= 0) && (value <= 10) {
						cur_material.illumination_model = value
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "map_Ka "):
			{
				if file_name, ok_file_name := parse_name(line[7:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.ambient_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "map_Kd "):
			{
				if file_name, ok_file_name := parse_name(line[7:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.diffuse_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "map_Ks "):
			{
				if file_name, ok_file_name := parse_name(line[7:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.specular_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "map_Ns "):
			{
				if file_name, ok_file_name := parse_name(line[7:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.specular_highlight_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "map_d "):
			{
				if file_name, ok_file_name := parse_name(line[6:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.alpha_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "map_bump "):
			{
				if file_name, ok_file_name := parse_name(line[9:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.bump_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "bump "):
			{
				if file_name, ok_file_name := parse_name(line[5:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.bump_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "disp "):
			{
				if file_name, ok_file_name := parse_name(line[5:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.displacement_map = image
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "decal "):
			{
				if file_name, ok_file_name := parse_name(line[6:]); ok_file_name {
					if image, ok_image := load_image_from_file(file_name, directory); ok_image {
						cur_material.decal_texture = image
					} else {ok = false}
				} else {ok = false}
			}

		case:
			ok = false
		}

		if !ok {
			log.errorf("Invalid line[%v]: %v", index, line)
			delete_mtllib(mtllib_builder[:])
			return
		}
	}

	mtllib = slice.clone(mtllib_builder[:])
	delete(mtllib_builder)
	return mtllib, true
}

@(export)
parse_obj :: proc(
	obj_data, directory: string,
	allocator := context.allocator,
) -> (
	obj: OBJ_File,
	ok: bool,
) {
	obj_data := obj_data
	ok = true

	index: int
	builder: OBJ_Builder
	init_builder(&builder)
	defer delete_builder(&builder)
	for _line in strings.split_lines_iterator(&obj_data) {
		index += 1
		line := strings.trim(_line, "\r\t\v ")

		if len(line) == 0 || line[0] == '#' {continue}

		switch {
		case strings.starts_with(line, "v "):
			{
				if pos, ok_pos := parse_vec4f32(line[2:], 1); ok_pos {
					builder_write(&builder, cast(Vertex_Position)pos)
				} else {ok = false}
			}

		case strings.starts_with(line, "f "):
			{
				ok_elems := parse_face_elements(line[2:], &builder)
				if !ok_elems {
					ok = false
				}
			}

		case strings.starts_with(line, "s "):
			{
				if value, ok_value := strconv.parse_uint(line[2:]); ok_value {
					builder_set_smoothing(&builder, bool(value))
				} else {ok = false}
			}

		case strings.starts_with(line, "g "):
			{
				if name, ok_name := parse_name(line[2:]); ok_name {
					builder.group_name = name
					builder_write(&builder, Group{name = name})
				} else {ok = false}
			}

		case strings.starts_with(line, "o "):
			{
				if name, ok_name := parse_name(line[2:]); ok_name {
					builder.object_name = name
					builder_write(&builder, Object{})
				} else {ok = false}
			}

		case strings.starts_with(line, "vt "):
			{
				if uv, ok_uv := parse_vec3f32(line[3:], 0); ok_uv {
					builder_write(&builder, cast(Vertex_UV)uv)
				} else {ok = false}
			}

		case strings.starts_with(line, "vn "):
			{
				if normal, ok_normal := parse_vec3f32_strict(line[3:]); ok_normal {
					builder_write(&builder, cast(Vertex_Normal)normal)
				} else {ok = false}
			}

		case strings.starts_with(line, "mtllib "):
			{
				if file_name, ok_file_name := parse_name(line[7:]); ok_file_name {
					if mtllib, ok_mtllib := load_mtllib_from_file(file_name, directory);
					   ok_mtllib {
						builder_write(&builder, ..mtllib)
						delete(mtllib)
					} else {ok = false}
				} else {ok = false}
			}

		case strings.starts_with(line, "usemtl "):
			{
				if name, ok_name := parse_name(line[7:]); ok_name {
					if material, ok_material := builder_check_for_material(&builder, name);
					   ok_material {
						builder.cur_material = material
					} else {ok = false}
				} else {ok = false}
			}
		case:
			ok = false
		}

		if !ok {
			log.errorf("Invalid line[%v]: %v", index, line)
			return
		}
	}

	obj = builder_to_object_file(&builder)
	return obj, true
}
