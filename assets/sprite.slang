
Sampler2D textures[];

struct Instance {
  float2 pos;
  float2 scale;
  float rotation; // Rotation in radians
  uint32_t texture_index;
  uint32_t _pad0[2];
  float4 color;
};

struct VertexOutput {
  float4 pos : SV_POSITION;
  float2 uv;
  uint32_t texture_index;
};

const static uint MAX_SPRITES = 100 * 1024;

struct Shader_Data {
  column_major float4x4 projection_view; // combined once on CPU
  Instance sprites[MAX_SPRITES];
};

struct Push_Constants {
  Shader_Data *data;
};

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

  uint spriteIndex = vID / 4;
  uint cornerIndex = vID % 4;
  Instance spriteData = pc.data->sprites[spriteIndex];
  output.texture_index = spriteData.texture_index;

  // Create a unit quad and transform it
  float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5),
                        float2(-0.5, 0.5) };
  float2 localPos = corners[cornerIndex];
  float2 scaled = localPos * spriteData.scale;
  float s, c;
  sincos(spriteData.rotation, s, c);
  float2 rotated =
      float2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
  float2 worldPos = rotated + spriteData.pos;

  // Output the results for this sprite but only for the current vertex
  output.pos = mul(pc.data->projection_view, float4(worldPos, 0.0, 1.0));
  float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(1, 0), float2(0, 0) };
  output.uv = uvs[cornerIndex];

  return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput input) {
  return textures[input.texture_index].Sample(input.uv);
}
