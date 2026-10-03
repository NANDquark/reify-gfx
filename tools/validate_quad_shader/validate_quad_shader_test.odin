package validate_quad_shader

import "core:strings"
import "core:testing"

@(test)
audit_accepts_shader_contract :: proc(t: ^testing.T) {
	testing.expect_value(t, audit_assembly(VALID_ASSEMBLY), "")
	// Whitespace does not change instruction operands.
	spaced, allocated := strings.replace_all(VALID_ASSEMBLY, " ", "\t")
	defer if allocated do delete(spaced)
	testing.expect_value(t, audit_assembly(spaced), "")
}

@(test)
audit_rejects_contract_changes :: proc(t: ^testing.T) {
	cases := [?]struct {
		old, replacement: string,
	} {
		{"OpCapability Shader\n", ""},
		{"OpCapability Shader\n", "OpCapability Shader\nOpCapability Int64\n"},
		{"OpCapability Shader\n", "OpCapability Shader extra\n"},
		{"OpDecorate %index0 NonUniform", ""},
		{"OpDecorate %pointer0 NonUniform", ""},
		{"OpDecorate %image0 NonUniform", ""},
		{"%image0 = OpLoad %image_type %pointer0", ""},
		{"%pointer1 = OpAccessChain %pointer_type %textures %index1", ""},
		{
			"%pointer1 = OpAccessChain %pointer_type %textures %index1",
			"%pointer1 = OpAccessChain %pointer_type %textures %index1 extra",
		},
		{"OpDecorate %textures Binding 0", "OpDecorate %textures Binding 01"},
		{"OpDecorate %fonts DescriptorSet 0", "OpDecorate %fonts DescriptorSet 1"},
		{
			"OpMemberDecorate %Push_Constants_std430 1 Offset 64",
			"OpMemberDecorate %Push_Constants_std430 1 Offset 640",
		},
		{
			"OpMemberDecorate %Instance_natural 7 Offset 48",
			"OpMemberDecorate %Instance_natural 7 Offset 480",
		},
		{"OpDecorate %fonts_array ArrayStride 16", "OpDecorate %fonts_array ArrayStride 160"},
		{
			"OpDecorate %instances_array ArrayStride 64",
			"OpDecorate %instances_array ArrayStride 640",
		},
		{
			"%image0 = OpLoad %image_type %pointer0",
			"%image0 = OpLoad %image_type %pointer0\n%undecorated = OpLoad %image_type %pointer0",
		},
	}
	for change in cases {
		assembly, allocated := strings.replace_all(VALID_ASSEMBLY, change.old, change.replacement)
		message := audit_assembly(assembly)
		testing.expect(t, message != "", change.old)
		if allocated do delete(assembly)
	}
	testing.expect(t, audit_assembly("") != "")
}

VALID_ASSEMBLY :: `OpCapability Shader
OpCapability DrawParameters
OpCapability PhysicalStorageBufferAddresses
OpCapability RuntimeDescriptorArray
OpCapability ShaderNonUniform
OpCapability SampledImageArrayNonUniformIndexing
OpDecorate %index0 NonUniform
OpDecorate %index1 NonUniform
OpDecorate %pointer0 NonUniform
OpDecorate %pointer1 NonUniform
OpDecorate %image0 NonUniform
OpDecorate %image1 NonUniform
%pointer0 = OpAccessChain %pointer_type %textures %index0
%pointer1 = OpAccessChain %pointer_type %textures %index1
%image0 = OpLoad %image_type %pointer0
%image1 = OpLoad %image_type %pointer1
OpDecorate %textures Binding 0
OpDecorate %textures DescriptorSet 0
OpDecorate %fonts Binding 1
OpDecorate %fonts DescriptorSet 0
OpMemberDecorate %Push_Constants_std430 0 Offset 0
OpMemberDecorate %Push_Constants_std430 1 Offset 64
OpMemberDecorate %Instance_natural 0 Offset 0
OpMemberDecorate %Instance_natural 1 Offset 8
OpMemberDecorate %Instance_natural 2 Offset 16
OpMemberDecorate %Instance_natural 3 Offset 20
OpMemberDecorate %Instance_natural 4 Offset 24
OpMemberDecorate %Instance_natural 5 Offset 28
OpMemberDecorate %Instance_natural 6 Offset 32
OpMemberDecorate %Instance_natural 7 Offset 48
OpDecorate %fonts_array ArrayStride 16
OpDecorate %instances_array ArrayStride 64
`
