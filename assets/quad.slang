
Sampler2D textures[];

struct Instance {
  float2 pos;
  float2 scale;
  float rotation;
  uint32_t texture_index;
  vector<uint16_t, 2> type;
  uint32_t _pad0;
  float4 color_tint;

  // When type is Instance_Type.Triangle we need to smuggle the three points
  // inside other quad instance fields to preserve a single shader & pipeline
  property float2 p0 {
    get { return pos; }
  }
  property float2 p1 {
    get { return scale; }
  }
  property float2 p2 {
    get { return float2(rotation, asfloat(_pad0)); }
  }

  Instance_Type getType() { return Instance_Type(type[0]); }
  uint16_t getTypeArg() { return type[1]; }
};

// Remember to update shader_types_gen since it can't get enums automatically
enum Instance_Type : uint16_t {
  Sprite = 0,
  Rect = 1,
  Circle = 2,
  Triangle = 3,
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

// This is using a vertex-pulling strategy using a structured buffer where
// each sprite has one entry. Then we use the SV_VertexID and indexed drawing
// to expand each sprite into 4 vertices. The div and modulo below converts
// the indexed vertex ID to the single sprite index.
[shader("vertex")]
VertexOutput vertMain(uint vID: SV_VertexID) {
  VertexOutput output;

  uint instanceIndex = vID / 4;
  uint cornerIndex = vID % 4;
  Instance instance = pc.data->instances[instanceIndex];

  float2 finalWorldPos;
  float2 finalUV;

  if (instance.getType() == Instance_Type::Triangle) {
    float2 p0 = instance.pos;
    float2 p1 = instance.scale;
    float2 p2 = float2(instance.rotation, asfloat(instance._pad0));

    float2 triPoints[4] = { p0, p1, p2, p0 };
    float2 triUVs[4] = { float2(0.5, 0.0), float2(1.0, 1.0), float2(0.0, 1.0),
                         float2(0.5, 0.0) };

    finalWorldPos = triPoints[cornerIndex];
    finalUV = triUVs[cornerIndex];
  } else {
    // Standard Quad Logic
    float2 quadCorners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5),
                              float2(0.5, 0.5), float2(-0.5, 0.5) };
    float2 quadUVs[4] = { float2(0, 1), float2(1, 1), float2(1, 0),
                          float2(0, 0) };
    float2 localPos = quadCorners[cornerIndex] * instance.scale;

    float s, c;
    sincos(instance.rotation, s, c);
    float2 rotated = float2(localPos.x * c - localPos.y * s,
                            localPos.x * s + localPos.y * c);
    finalWorldPos = rotated + instance.pos;
    finalUV = quadUVs[cornerIndex];
  }

  output.pos = mul(pc.data->projection_view, float4(finalWorldPos, 0.0, 1.0));
  output.uv = finalUV;
  output.texture_index = instance.texture_index;
  output.instance_index = instanceIndex;

  return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput input) {
  Instance instance = pc.data->instances[input.instance_index];
  Instance_Type instance_type = instance.getType();
  if (instance_type == Instance_Type.Sprite) {
    return textures[input.texture_index].Sample(input.uv);
  } else if (instance_type == Instance_Type.Circle) {
    float d = distance(input.uv, float2(0.5, 0.5));
    float alpha = 1.0 - smoothstep(0.48, 0.5, d);
    if (alpha <= 0.0)
      discard;
    return float4(instance.color_tint.rgb, instance.color_tint.a * alpha);
  }
  // applies to Instance_Type.Rect
  return instance.color_tint;
}
