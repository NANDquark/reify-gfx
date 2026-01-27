/* Copyright (c) 2025-2026, Sascha Willems
 * Modified by NANDquark
 *
 * SPDX-License-Identifier: MIT
 *
 */

struct VSInput {
  float3 Pos;
  float3 Normal;
  float2 UV;
};

Sampler2D textures[];

// const static uint MAX_INSTANCES = 10 * 1024;
const static uint MAX_INSTANCES = 3;

struct ShaderData {
  float4x4 projection;
  float4x4 view;
  float4 lightPos;
  // uint32_t num_instances;
  uint32_t _pad0[4];
  InstanceData instances[MAX_INSTANCES];
};

struct InstanceData {
  uint32_t texture_index;
  uint32_t _pad0[7];
  float4x4 transform;
};

struct PushConstants {
  ShaderData *shaderData;
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
PushConstants pc;

[shader("vertex")]
VSOutput vertMain(VSInput input, uint instanceIndex: SV_VulkanInstanceID) {
  VSOutput output;
  InstanceData instance = pc.shaderData->instances[instanceIndex];
  output.Normal =
      mul((float3x3)mul(pc.shaderData->view, instance.transform), input.Normal);
  output.UV = input.UV;
  output.Pos = mul(pc.shaderData->projection,
                   mul(pc.shaderData->view,
                       mul(instance.transform, float4(input.Pos.xyz, 1.0))));
  output.InstanceIndex = instanceIndex;

  // Calculate view vectors required for lighting
  float4 fragPos = mul(mul(pc.shaderData->view, instance.transform),
                       float4(input.Pos.xyz, 1.0));
  output.LightVec = pc.shaderData->lightPos.xyz - fragPos.xyz;
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
