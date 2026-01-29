/* Copyright (c) 2025-2026, Sascha Willems
 * Modified by NANDquark
 * SPDX-License-Identifier: MIT
 */

struct Vertex {
  float3 pos;
  float2 uv;
};

Sampler2D textures[];

const static uint MAX_INSTANCES = 10 * 128;

struct Instance_Data {
  column_major float4x4 model; // aka the transform
  uint32_t texture_index;
  // color/tint?
  uint32_t _pad0[3];
};

struct Shader_Data {
  column_major float4x4 projection;
  column_major float4x4 view;
  Instance_Data instances[MAX_INSTANCES];
};

struct Push_Constants {
  Shader_Data *shader_data;
};

struct VSOutput {
  float4 pos : SV_POSITION;
  float2 uv;
  uint32_t instance_index;
  uint32_t texture_index;
  float4x4 model;
};

[[vk::push_constant]]
Push_Constants pc;

// Reflection anchor used only to expose Shader_Data in shader_types.json
StructuredBuffer<Shader_Data> _ReflectionAnchor;

[shader("vertex")]
VSOutput vertMain(Vertex input, uint instance_index: SV_VulkanInstanceID) {
  VSOutput output;
  Instance_Data instance = pc.shader_data->instances[instance_index];
  output.uv = input.uv;
  // output.pos = mul(pc.shader_data->projection,
  //                  mul(pc.shader_data->view,
  //                      mul(instance.model, float4(input.pos.xyz, 1.0))));
  // float4 debug = float4(input.pos.x / 100.0, input.pos.y / 100, 0, 1);
  // float4x4 mvp = pc.shader_data.projection;
  float4x4 scale = float4x4(10, 0, 0, 0, 0, 10, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
  float4x4 mvp = mul(pc.shader_data.projection, mul(instance.model, scale));
  output.model = instance.model;
  output.pos = mul(mvp, float4(input.pos.xyz, 1.0));
  // output.pos.x = debug.x;
  // output.pos.y = debug.y;
  // output.pos.z = debug.z;
  // output.pos.w = 1;
  output.instance_index = instance_index;
  output.texture_index = instance.texture_index;
  return output;
}

[shader("fragment")]
// float4 fragMain(VSOutput input) {
//   float3 color = textures[input.texture_index].Sample(input.uv).rgb;
//   return float4(color.rgb, 1.0);
// }
float4 fragMain(VSOutput input) { return float4(1.0, 0.0, 0.0, 1.0); }
