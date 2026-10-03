#define VERTEX_ID_SEMANTIC SV_VulkanVertexID
#define get_instance(index) instances[index]
#define sample_texture(index, uv) texture.Sample(uv)
#include "quad_common.slang"

struct Push_Constants {
  column_major float4x4 projection_view;
};

[[vk::push_constant]] Push_Constants pc;
[[vk::binding(0, 0)]] StructuredBuffer<Instance> instances;
[[vk::binding(1, 0)]] StructuredBuffer<Font> fonts;
[[vk::binding(0, 1)]] Sampler2D texture;
