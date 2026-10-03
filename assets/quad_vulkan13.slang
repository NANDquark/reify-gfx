#define VERTEX_ID_SEMANTIC SV_VertexID
#define get_instance(index) pc.data->instances[index]
#define sample_texture(index, uv) textures[NonUniformResourceIndex(index)].Sample(uv)
#include "quad_common.slang"

const static uint MAX_INSTANCES = 100 * 1024;

struct Shader_Data {
  Instance instances[MAX_INSTANCES];
};

struct Push_Constants {
  column_major float4x4 projection_view; // combined once on CPU
  Shader_Data *data;
};

// Expose Shader_Data to reflection; rendering accesses it through a pointer.
StructuredBuffer<Shader_Data> _ReflectionAnchor;

[[vk::push_constant]]
Push_Constants pc;

[[vk::binding(0, 0)]]
Sampler2D textures[];

[[vk::binding(1, 0)]]
StructuredBuffer<Font> fonts;
