
Sampler2D textures[];

struct Instance {
  float2 pos;
  float2 scale;
  float rotation; // Rotation in radians
  uint32_t texture_index;
  vector<uint16_t, 2> type;
  uint32_t _pad0[1];
  float4 color;

  Instance_Type getType() { return Instance_Type(type[0]); }
  uint16_t getTypeArg() { return type[1]; }
};

// Remember to update shader_types_gen since it can't get enums automatically
enum Instance_Type : uint16_t {
  Sprite = 0,
  Rect = 1,
  Circle = 2,
}

struct VertexOutput {
  float4 pos : SV_POSITION;
  float2 uv;
  nointerpolation uint32_t texture_index;
  nointerpolation uint32_t instance_index;
};

const static uint MAX_INSTANCES = 100 * 1024;

struct Shader_Data {
  column_major float4x4 projection_view; // combined once on CPU
  Instance instances[MAX_INSTANCES];
};

struct Push_Constants {
  Shader_Data *data;
};

// This exposes the Shader_Data to the reflection_types JSON output
StructuredBuffer<Shader_Data> _ReflectionAnchor;

[[vk::push_constant]]
Push_Constants pc;

[shader("vertex")]
VertexOutput vertMain(uint vID: SV_VertexID) {
  VertexOutput output;

  // This is using a vertex-pulling strategy using a structured buffer where
  // each sprite has one entry. Then we use the SV_VertexID and indexed drawing
  // to expand each sprite into 4 vertices. The div and modulo below converts
  // the indexed vertex ID to the single sprite index.

  uint instanceIndex = vID / 4;
  uint cornerIndex = vID % 4;
  Instance instance = pc.data->instances[instanceIndex];
  output.texture_index = instance.texture_index;
  output.instance_index = instanceIndex;

  // Create a unit quad and transform it
  float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5),
                        float2(-0.5, 0.5) };
  float2 localPos = corners[cornerIndex];
  float2 scaled = localPos * instance.scale;
  float s, c;
  sincos(instance.rotation, s, c);
  float2 rotated =
      float2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
  float2 worldPos = rotated + instance.pos;

  // Output the results for this sprite but only for the current vertex
  output.pos = mul(pc.data->projection_view, float4(worldPos, 0.0, 1.0));
  float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(1, 0), float2(0, 0) };
  output.uv = uvs[cornerIndex];

  return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput input) {
  Instance instance = pc.data->instances[input.instance_index];
  Instance_Type instance_type = instance.getType();
  if (instance_type == Instance_Type.Sprite) {
    return textures[input.texture_index].Sample(input.uv);
  } else if (instance_type == Instance_Type.Rect) {
    return instance.color;
  } else if (instance_type == Instance_Type.Circle) {
    float d = distance(input.uv, float2(0.5, 0.5));
    float alpha = 1.0 - smoothstep(0.48, 0.5, d);
    if (alpha <= 0.0)
      discard;
    return float4(instance.color.rgb, instance.color.a * alpha);
  }
  return instance.color;
}
