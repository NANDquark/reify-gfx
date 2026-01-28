/* Copyright (c) 2025-2026, Sascha Willems
 * Modified by NANDquark
 *
 * SPDX-License-Identifier: MIT
 *
 */

struct Vertex {
  float3 pos;
  float3 normal;
  float2 uv;
};

Sampler2D textures[];

// const static uint MAX_INSTANCES = 10 * 1024;
const static uint MAX_INSTANCES = 3;

struct Instance_Data {
  float4x4 transform;
  uint32_t texture_index;
  uint32_t _pad0[3];
};

struct Shader_Data {
  float4x4 projection;
  float4x4 view;
  float4 light_pos;
  Instance_Data instances[MAX_INSTANCES];
};

struct Push_Constants {
  Shader_Data *shader_data;
};

struct VSOutput {
  float4 Pos : SV_POSITION;
  float3 Normal;
  float2 UV;
  float3 LightVec;
  float3 ViewVec;
  uint32_t InstanceIndex;
  uint32_t TextureIndex;
};

[[vk::push_constant]]
Push_Constants pc;

// Reflection anchor: never bound, never accessed
StructuredBuffer<Shader_Data> _ReflectionAnchor;

[shader("vertex")]
VSOutput vertMain(Vertex input, uint instanceIndex: SV_VulkanInstanceID) {
  VSOutput output;
  Instance_Data instance = pc.shader_data->instances[instanceIndex];
  output.Normal = mul((float3x3)mul(pc.shader_data->view, instance.transform),
                      input.normal);
  output.UV = input.uv;
  output.Pos = mul(pc.shader_data->projection,
                   mul(pc.shader_data->view,
                       mul(instance.transform, float4(input.pos.xyz, 1.0))));
  output.InstanceIndex = instanceIndex;

  // Calculate view vectors required for lighting
  float4 fragPos = mul(mul(pc.shader_data->view, instance.transform),
                       float4(input.pos.xyz, 1.0));
  output.LightVec = pc.shader_data->light_pos.xyz - fragPos.xyz;
  output.ViewVec = -fragPos.xyz;
  output.TextureIndex = instance.texture_index;
  return output;
}

[shader("fragment")]
float4 fragMain(VSOutput input) {
  // Phong lighting
  float3 N = normalize(input.Normal);
  float3 L = normalize(input.LightVec);
  float3 V = normalize(input.ViewVec);
  float3 R = reflect(-L, N);
  float3 diffuse = max(dot(N, L), 0.0025);
  float3 specular = pow(max(dot(R, V), 0.0), 16.0) * 0.75;
  // Sample from texture
  float3 color = textures[input.TextureIndex].Sample(input.UV).rgb;
  // float3 color = textures[pc.texture_index].Sample(input.UV).rgb *
  // input.Factor;
  return float4(diffuse * color.rgb + specular, 1.0);
}
