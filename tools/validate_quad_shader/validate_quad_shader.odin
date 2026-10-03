package validate_quad_shader

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

main :: proc() {
	if err := run(); err != nil {
		panic(fmt.tprintf("validate_quad_shader failed, err=%v", err))
	}
}

run :: proc() -> Error {
	shader := filepath.join([]string{#directory, "../../assets/quad.spv"}) or_return
	defer delete(shader)
	validated, validation_err := run_command(
		[]string{"spirv-val", "--target-env", "vulkan1.3", shader},
	)
	defer delete(validated)
	if validation_err != nil do return validation_err
	assembly, disassembly_err := run_command([]string{"spirv-dis", shader})
	defer delete(assembly)
	if disassembly_err != nil do return disassembly_err
	if message := audit_assembly(string(assembly)); message != "" do return Tool_Error{message}
	fmt.println("Vulkan 1.3 shader capability, non-uniform indexing, and layout audit passed")
	return nil
}

Error :: union {
	os.Error,
	mem.Allocator_Error,
	Tool_Error,
}

Tool_Error :: struct {
	message: string,
}

run_command :: proc(command: []string) -> ([]byte, Error) {
	state, stdout, stderr, err := os.process_exec({command = command}, context.allocator)
	defer delete(stderr)
	if err != nil {
		delete(stdout)
		return nil, err
	}
	if !state.exited || state.exit_code != 0 {
		delete(stdout)
		return nil, Tool_Error {
			fmt.tprintf("%s failed (exit %d): %s", command[0], state.exit_code, string(stderr)),
		}
	}
	return stdout, nil
}

audit_assembly :: proc(assembly: string) -> string {
	instructions: [dynamic][]string
	defer {
		for fields in instructions do delete(fields)
		delete(instructions)
	}
	remaining := assembly
	for line in strings.split_lines_iterator(&remaining) {
		fields, err := strings.fields(line)
		if err != nil {
			return "shader instruction allocation failed"
		}
		if len(fields) == 0 {
			delete(fields)
			continue
		}
		if _, append_err := append(&instructions, fields); append_err != nil {
			delete(fields)
			return "shader instruction table allocation failed"
		}
	}
	return audit_instructions(instructions[:])
}

audit_instructions :: proc(instructions: [][]string) -> string {
	expected := [?]string {
		"Shader",
		"DrawParameters",
		"PhysicalStorageBufferAddresses",
		"RuntimeDescriptorArray",
		"ShaderNonUniform",
		"SampledImageArrayNonUniformIndexing",
	}
	found: [len(expected)]bool
	for fields in instructions {
		if fields[0] != "OpCapability" do continue
		if len(fields) != 2 {
			return "malformed shader capability declaration"
		}
		matched := false
		for capability, i in expected {
			if fields[1] == capability {
				found[i], matched = true, true
				break
			}
		}
		if !matched {
			return fmt.tprintf(
				"shader capabilities require a requirement audit: unexpected %s",
				fields[1],
			)
		}
	}
	for present, i in found {
		if !present {
			return fmt.tprintf(
				"shader capabilities require a requirement audit: missing %s",
				expected[i],
			)
		}
	}
	access_count := 0
	for fields in instructions {
		if len(fields) < 5 || fields[1] != "=" || fields[2] != "OpAccessChain" || fields[4] != "%textures" do continue
		if len(fields) != 6 {
			return "unexpected texture access-chain layout"
		}
		access_count += 1
		if !is_non_uniform(instructions, fields[0]) || !is_non_uniform(instructions, fields[5]) {
			return "texture access lacks non-uniform index/pointer/image decorations"
		}
		loads := 0
		for load in instructions {
			if len(load) < 5 || load[1] != "=" || load[2] != "OpLoad" || load[4] != fields[0] do continue
			loads += 1
			if !is_non_uniform(instructions, load[0]) {
				return "texture access lacks non-uniform index/pointer/image decorations"
			}
		}
		if loads == 0 {
			return "texture access lacks non-uniform index/pointer/image decorations"
		}
	}
	if access_count != 2 {
		return "expected sprite and MSDF texture accesses"
	}

	required_layouts := [?]string {
		"OpDecorate %textures Binding 0",
		"OpDecorate %textures DescriptorSet 0",
		"OpDecorate %fonts Binding 1",
		"OpDecorate %fonts DescriptorSet 0",
		"OpMemberDecorate %Push_Constants_std430 0 Offset 0",
		"OpMemberDecorate %Push_Constants_std430 1 Offset 64",
	}
	for declaration in required_layouts {
		if !has_instruction(instructions, declaration) {
			return fmt.tprintf("shader layout requires a CPU contract audit: %s", declaration)
		}
	}
	offsets := [?]int{0, 8, 16, 20, 24, 28, 32, 48}
	for offset, member in offsets {
		if !has_instruction(
			instructions,
			fmt.tprintf("OpMemberDecorate %%Instance_natural %d Offset %d", member, offset),
		) {
			return "instance member layout differs from Quad_Instance"
		}
	}
	strides := [?]int{16, 64}
	for stride in strides {
		present := false
		for fields in instructions {
			if len(fields) == 4 &&
			   fields[0] == "OpDecorate" &&
			   strings.has_prefix(fields[1], "%") &&
			   fields[2] == "ArrayStride" &&
			   fields[3] == fmt.tprintf("%d", stride) {
				present = true
				break
			}
		}
		if !present {
			return fmt.tprintf("missing font/instance array stride %d", stride)
		}
	}
	return ""
}

is_non_uniform :: proc(instructions: [][]string, id: string) -> bool {
	for fields in instructions {
		if len(fields) == 3 && fields[0] == "OpDecorate" && fields[1] == id && fields[2] == "NonUniform" do return true
	}
	return false
}

has_instruction :: proc(instructions: [][]string, declaration: string) -> bool {
	expected, err := strings.fields(declaration, context.temp_allocator)
	if err != nil do return false
	defer delete(expected, context.temp_allocator)
	for fields in instructions {
		if len(fields) != len(expected) do continue
		matches := true
		for field, i in fields {
			if field != expected[i] {
				matches = false
				break
			}
		}
		if matches do return true
	}
	return false
}
