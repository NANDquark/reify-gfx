#+feature dynamic-literals
package shader_types_gen

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
SHADER_TYPES_BYTES :: #load("../../assets/shader_types.json")

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
}

TARGET_NAMES := []string{"Instance_Data", "Shader_Data", "Push_Constants"}

run :: proc() -> Error {
	json_data := json.parse(SHADER_TYPES_BYTES) or_return
	root, root_ok := json_data.(json.Object)
	if !root_ok do return Tool_Error.JSON_Invalid
	params, params_ok := root["parameters"]
	if !params_ok do return Tool_Error.JSON_Missing_Params

	sb: strings.Builder
	strings.builder_init(&sb)
	fmt.sbprintln(&sb, "package reify\n")
	fmt.sbprintln(&sb, "import vk \"vendor:vulkan\"\n")
	fmt.sbprintln(&sb, "// TODO: automatic padding based on slang offsets & sizes!\n")

	for name in TARGET_NAMES {
		value, found := json_search_by_name(params, name)
		if found {
			st := convert_struct(value)
			fmt.sbprintfln(&sb, "%s :: struct #align (16) {{", name)
			for i in 0 ..< len(st.field_names) {
				field_name := st.field_names[i]
				field_type := st.field_types[i]
				odin_type := build_odin_type(field_type)
				defer delete(odin_type)
				fmt.sbprintfln(&sb, "    %s: %s,", field_name, odin_type)
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
Scalar_Type_UINT32: Scalar_Type : "uint32"
Scalar_Type_FLOAT32: Scalar_Type : "float32"

SCALAR_TO_ODIN := map[Scalar_Type]string {
	Scalar_Type_UINT32  = "u32",
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

convert_struct :: proc(obj: json.Object) -> (s: Shader_Struct) {
	s.name = obj["name"].(string)
	fields := obj["fields"].(json.Array)

	field_names := [dynamic]string{}
	field_types := [dynamic]^Shader_Field{}
	for f in fields {
		field_name, field_type := convert_field(f.(json.Object))
		append(&field_names, field_name)
		append(&field_types, field_type)
	}
	s.field_names = field_names[:]
	s.field_types = field_types[:]
	return s
}

convert_field :: proc(obj: json.Object) -> (string, ^Shader_Field) {
	field_name := obj["name"].(json.String)
	type_obj := obj["type"].(json.Object)
	field_type := convert_field_type(type_obj)
	return field_name, field_type
}

convert_field_type :: proc(type_obj: json.Object) -> ^Shader_Field {
	field: ^Shader_Field
	type_kind := type_obj["kind"].(json.String)
	switch type_kind {
	case "array":
		element_count := type_obj["elementCount"].(json.Float)
		element_type := type_obj["elementType"].(json.Object)
		arr := new(Shader_Array)
		arr.kind = .Array
		arr.len = int(element_count)
		arr.element_type = convert_field_type(element_type)
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
		struc.name = name
		struc.reference = true
		field = struc
	}
	return field
}

build_odin_type :: proc(field_def: ^Shader_Field) -> string {
	sb: strings.Builder

	switch field_def.kind {
	case .Array:
		fd := cast(^Shader_Array)field_def
		element_type := build_odin_type(fd.element_type)
		fmt.sbprintf(&sb, "[%d]%s", fd.len, element_type)
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
		scalar_type := "f32" if fd.element_type.type == Scalar_Type_FLOAT32 else "i32"
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
