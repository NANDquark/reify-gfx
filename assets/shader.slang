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

struct PushConstants {
  ShaderData *shaderData;
  uint32_t texture_index;
  float32_t offset_x;
};

struct ShaderData {
  float4x4 projection;
  float4x4 view;
  float4x4 model[3];
  float4 lightPos;
  uint32_t selected;
};

struct VSOutput {
  float4 Pos : SV_POSITION;
  float3 Normal;
  float2 UV;
  float3 LightVec;
  float3 ViewVec;
  uint32_t InstanceIndex;
};

[[vk::push_constant]]
PushConstants pc;

[shader("vertex")]
VSOutput vertMain(VSInput input, uint instanceIndex: SV_VulkanInstanceID) {
  VSOutput output;
  float4x4 modelMat = pc.shaderData->model[0];
  output.Normal =
      mul((float3x3)mul(pc.shaderData->view, modelMat), input.Normal);
  output.UV = input.UV;
  float3 localPos = input.Pos.xyz;
  localPos.x += pc.offset_x;
  output.Pos =
      mul(pc.shaderData->projection,
          mul(pc.shaderData->view, mul(modelMat, float4(localPos, 1.0))));
  output.InstanceIndex = instanceIndex;

  // Calculate view vectors required for lighting
  float4 fragPos =
      mul(mul(pc.shaderData->view, modelMat), float4(input.Pos.xyz, 1.0));
  output.LightVec = pc.shaderData->lightPos.xyz - fragPos.xyz;
  output.ViewVec = -fragPos.xyz;
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
  float3 color = textures[pc.texture_index].Sample(input.UV).rgb;
  // float3 color = textures[pc.texture_index].Sample(input.UV).rgb *
  // input.Factor;
  return float4(diffuse * color.rgb + specular, 1.0);
}
