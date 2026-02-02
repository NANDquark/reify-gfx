#+feature dynamic-literals
package shader_types_gen

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

SPRITE_SHADER_TYPES_BYTES :: #load("../../assets/sprite_shader_types.json")

main :: proc() {
	if err := run(); err != nil {
		panic(fmt.tprintf("shader_types_gen failed, err=%v", err))
	}
}

Error :: union #shared_nil {
	json.Error,
	os.Error,
	Tool_Error,
}

Tool_Error :: enum {
	JSON_Invalid,
	JSON_Missing_Params,
	JSON_Params_Invalid,
	Write_Failed,
	Type_Not_Found,
}

Shader_Config :: struct {
	bytes:  []byte,
	names:  []string,
	enums:  []Enum,
	prefix: string,
}

// TODO: parse slang and grab these automatically... sometime later
Enum :: struct {
	name:   string,
	type:   Scalar_Type,
	values: []Enum_Value,
}

Enum_Value :: struct {
	name:  string,
	value: int,
}

run :: proc() -> Error {
	sb: strings.Builder
	strings.builder_init(&sb)
	fmt.sbprintln(&sb, "package reify\n")
	fmt.sbprintfln(&sb, "// Generated: %v", time.now())
	fmt.sbprintln(&sb, "// TODO: automatic padding based on slang offsets & sizes!\n")
	fmt.sbprintln(&sb, "import vk \"vendor:vulkan\"\n")

	configs := []Shader_Config {
		{
			bytes = SPRITE_SHADER_TYPES_BYTES,
			names = {"Instance", "Shader_Data", "Push_Constants"},
			enums = {
				{
					name = "Instance_Type",
					type = Scalar_Type_UINT8,
					values = {{"Sprite", 0}, {"Rect", 1}, {"Circle", 2}},
				},
			},
			prefix = "Sprite_",
		},
	}

	for config in configs {
		json_data := json.parse(config.bytes) or_return
		root, root_ok := json_data.(json.Object)
		if !root_ok do return Tool_Error.JSON_Invalid

		for name in config.names {
			value, found := json_search_by_name(root, name)
			if found {
				st := convert_struct(value, config.prefix)

				// Generate constants for arrays
				for i in 0 ..< len(st.field_names) {
					field_name := st.field_names[i]
					field_type := st.field_types[i]
					if field_type.kind == .Array {
						arr := cast(^Shader_Array)field_type
						if arr.len > 0 {
							upper_name := strings.to_upper(field_name, context.temp_allocator)
							upper_prefix := strings.to_upper(config.prefix, context.temp_allocator)
							fmt.sbprintfln(
								&sb,
								"%sMAX_%s :: %d",
								upper_prefix,
								upper_name,
								arr.len,
							)
						}
					}
				}

				fmt.sbprintfln(&sb, "%s :: struct #align (16) {{", st.name)
				for i in 0 ..< len(st.field_names) {
					field_name := st.field_names[i]
					field_type := st.field_types[i]

					odin_type: string
					if field_type.kind == .Array {
						arr := cast(^Shader_Array)field_type
						if arr.len > 0 {
							upper_name := strings.to_upper(field_name, context.temp_allocator)
							upper_prefix := strings.to_upper(config.prefix, context.temp_allocator)
							const_name := fmt.tprintf("%sMAX_%s", upper_prefix, upper_name)
							odin_type = build_odin_type(field_type, const_name)
						} else {
							odin_type = build_odin_type(field_type)
						}
					} else {
						odin_type = build_odin_type(field_type)
					}

					defer delete(odin_type)
					fmt.sbprintfln(&sb, "    %s: %s,", field_name, odin_type)
				}
				fmt.sbprintln(&sb, "}\n")
			} else {
				fmt.printfln("%s type not found", name)
				return .Type_Not_Found
			}
		}

		for e in config.enums {
			fmt.sbprintfln(
				&sb,
				"%s%s :: enum %s {{",
				config.prefix,
				e.name,
				SCALAR_TO_ODIN[e.type],
			)
			for v in e.values {
				fmt.sbprintfln(&sb, "\t%s = %d,", v.name, v.value)
			}
			fmt.sbprintln(&sb, "}\n")
		}
	}

	odin_code := strings.to_string(sb)
	curr_dir := #directory
	outfile_path := filepath.join([]string{curr_dir, "../../reify_shader_types.odin"})
	write_success := os.write_entire_file(outfile_path, transmute([]byte)odin_code)
	if !write_success do return Tool_Error.Write_Failed

	fmt.printfln("Successfully wrote reify_shader_types.odin")

	return nil
}

Shader_Field_Kind :: enum {
	Unknown = 0,
	Array,
	Matrix,
	Pointer,
	Scalar,
	Struct,
	Vector,
}

Shader_Field :: struct {
	kind: Shader_Field_Kind,
}

Shader_Array :: struct {
	using _:      Shader_Field,
	len:          int,
	element_type: ^Shader_Field,
}

Shader_Matrix :: struct {
	using _:      Shader_Field,
	rows:         int,
	cols:         int,
	element_type: Shader_Scalar,
}

Shader_Pointer :: struct {
	using _:   Shader_Field,
	type_name: string,
}

Shader_Scalar :: struct {
	using _: Shader_Field,
	type:    Scalar_Type,
}

Shader_Struct :: struct {
	using _:     Shader_Field,
	name:        string,
	reference:   bool, // referencing a type defined already
	field_names: []string,
	field_types: []^Shader_Field,
}

Shader_Vector :: struct {
	using _:      Shader_Field,
	len:          int,
	element_type: Shader_Scalar,
}

Scalar_Type :: distinct string
Scalar_Type_UINT8: Scalar_Type = "uint8"
Scalar_Type_UINT16: Scalar_Type = "uint16"
Scalar_Type_UINT32: Scalar_Type : "uint32"
Scalar_Type_UINT64: Scalar_Type : "uint64"
Scalar_Type_FLOAT32: Scalar_Type : "float32"

SCALAR_TO_ODIN := map[Scalar_Type]string {
	Scalar_Type_UINT8   = "u8",
	Scalar_Type_UINT16  = "u16",
	Scalar_Type_UINT32  = "u32",
	Scalar_Type_UINT64  = "u64",
	Scalar_Type_FLOAT32 = "f32",
}

json_search_by_name :: proc(value: json.Value, target_name: string) -> (json.Object, bool) {
	#partial switch v in value {
	case json.Object:
		if name, ok := v["name"]; ok {
			name_str, name_is_str := name.(json.String)
			if name_is_str && name_str == target_name {
				return v, true
			}
		}
		for k, vv in v {
			obj, found := json_search_by_name(vv, target_name)
			if found {
				return obj, true
			}
		}
	case json.Array:
		for e in v {
			obj, found := json_search_by_name(e, target_name)
			if found {
				return obj, true
			}
		}
	}
	return nil, false
}

convert_struct :: proc(obj: json.Object, prefix: string) -> (s: Shader_Struct) {
	s.name = fmt.tprintf("%s%s", prefix, obj["name"].(string))
	fields := obj["fields"].(json.Array)

	field_names := [dynamic]string{}
	field_types := [dynamic]^Shader_Field{}
	for f in fields {
		field_name, field_type := convert_field(f.(json.Object), prefix)
		append(&field_names, field_name)
		append(&field_types, field_type)
	}
	s.field_names = field_names[:]
	s.field_types = field_types[:]
	return s
}

convert_field :: proc(obj: json.Object, prefix: string) -> (string, ^Shader_Field) {
	field_name := obj["name"].(json.String)
	type_obj := obj["type"].(json.Object)
	field_type := convert_field_type(type_obj, prefix)
	return field_name, field_type
}

convert_field_type :: proc(type_obj: json.Object, prefix: string) -> ^Shader_Field {
	field: ^Shader_Field
	type_kind := type_obj["kind"].(json.String)
	switch type_kind {
	case "array":
		element_count := type_obj["elementCount"].(json.Float)
		element_type := type_obj["elementType"].(json.Object)
		arr := new(Shader_Array)
		arr.kind = .Array
		arr.len = int(element_count)
		arr.element_type = convert_field_type(element_type, prefix)
		field = arr
	case "matrix":
		row_count := type_obj["rowCount"].(json.Float)
		col_count := type_obj["columnCount"].(json.Float)
		element_type := type_obj["elementType"].(json.Object)
		scalar_type := element_type["scalarType"].(json.String)
		mat := new(Shader_Matrix)
		mat.kind = .Matrix
		mat.rows = int(row_count)
		mat.cols = int(col_count)
		mat.element_type = Shader_Scalar {
			kind = .Scalar,
			type = Scalar_Type(scalar_type),
		}
		field = mat
	case "pointer":
		value_type := type_obj["valueType"].(json.String)
		ptr := new(Shader_Pointer)
		ptr.kind = .Pointer
		ptr.type_name = value_type
		field = ptr
	case "scalar":
		scalar_type := type_obj["scalarType"].(json.String)
		scalar := new(Shader_Scalar)
		scalar.kind = .Scalar
		scalar.type = Scalar_Type(scalar_type)
		field = scalar
	case "vector":
		element_count := type_obj["elementCount"].(json.Float)
		element_type := type_obj["elementType"].(json.Object)
		scalar_type := element_type["scalarType"].(json.String)
		vec := new(Shader_Vector)
		vec.kind = .Vector
		vec.len = int(element_count)
		vec.element_type = Shader_Scalar {
			kind = .Scalar,
			type = Scalar_Type(scalar_type),
		}
		field = vec
	case "struct":
		name := type_obj["name"].(json.String)
		struc := new(Shader_Struct)
		struc.kind = .Struct
		struc.name = fmt.tprintf("%s%s", prefix, name)
		struc.reference = true
		field = struc
	}
	return field
}

build_odin_type :: proc(field_def: ^Shader_Field, length_override: string = "") -> string {
	sb: strings.Builder

	switch field_def.kind {
	case .Array:
		fd := cast(^Shader_Array)field_def
		element_type := build_odin_type(fd.element_type)
		defer delete(element_type)
		if length_override != "" {
			fmt.sbprintf(&sb, "[%s]%s", length_override, element_type)
		} else {
			fmt.sbprintf(&sb, "[%d]%s", fd.len, element_type)
		}
	case .Matrix:
		fd := cast(^Shader_Matrix)field_def
		scalar_type := "f" if fd.element_type.type == Scalar_Type_FLOAT32 else "i"
		if fd.rows != fd.cols do panic("non-square matrixes not supported yet")
		fmt.sbprintf(&sb, "Mat%d%s", fd.rows, scalar_type)
	case .Scalar:
		fd := cast(^Shader_Scalar)field_def
		fmt.sbprint(&sb, SCALAR_TO_ODIN[fd.type])
	case .Pointer:
		fd := cast(^Shader_Pointer)field_def
		fmt.sbprint(&sb, "vk.DeviceAddress")
	case .Vector:
		fd := cast(^Shader_Vector)field_def
		scalar_type := SCALAR_TO_ODIN[fd.element_type.type]
		fmt.sbprintf(&sb, "[%d]%s", fd.len, scalar_type)
	case .Struct:
		fd := cast(^Shader_Struct)field_def
		fmt.sbprint(&sb, fd.name)
	case .Unknown:
		panic("unexpected unknown shader type")
	}

	return strings.to_string(sb)
}

convert_kind :: proc(raw_kind: string) -> Shader_Field_Kind {
	switch raw_kind {
	case "array":
		return .Array
	case "matrix":
		return .Matrix
	case "pointer":
		return .Pointer
	case "scalar":
		return .Scalar
	case "struct":
		return .Struct
	case "vector":
		return .Vector
	}
	return .Unknown
}
