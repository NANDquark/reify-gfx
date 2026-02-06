
Sampler2D textures[];

struct Instance {
  float2 pos;
  float2 scale;
  float rotation;
  uint32_t texture_index;
  uint32_t type;
  uint32_t _pad0;
  float4 color; // pre-multiplied alpha
  float4 uv_rect;

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
};

// Remember to update shader_types_gen since it can't get enums automatically
enum Instance_Type : uint32_t {
  Sprite = 0,
  Rect = 1,
  Circle = 2,
  Triangle = 3,
  Line = 4,
}

struct VertexOutput {
  float4 pos : SV_POSITION;
  float2 uv;
  nointerpolation uint32_t texture_index;
  nointerpolation uint32_t instance_index;
};

const static uint MAX_INSTANCES = 100 * 1024;

struct Shader_Data {
  Instance instances[MAX_INSTANCES];
};

struct Push_Constants {
  column_major float4x4 projection_view; // combined once on CPU
  Shader_Data *data;
};

// This exposes the Shader_Data to the reflection_types JSON output
StructuredBuffer<Shader_Data> _ReflectionAnchor;

[[vk::push_constant]]
Push_Constants pc;

// This is using a vertex-pulling strategy using a structured buffer where
// each sprite has one entry. Then we use the SV_VertexID and indexed drawing
// to expand each sprite into 4 vertices. The div and modulo below converts
// the vertex ID to find the instance data.
[shader("vertex")]
VertexOutput vertMain(uint vID: SV_VertexID) {
  VertexOutput output;

  uint instanceIndex = vID / 4;
  uint cornerIndex = vID % 4;
  Instance instance = pc.data->instances[instanceIndex];

  float2 finalWorldPos;
  float2 finalUV;

  // Special case for triangles to make them a degenerate quad with a duplicate
  // point
  if (instance.type == Instance_Type.Triangle) {
    float2 p0 = instance.pos;
    float2 p1 = instance.scale;
    float2 p2 = float2(instance.rotation, asfloat(instance._pad0));
    float2 triPoints[4] = { p0, p1, p2, p0 };
    finalWorldPos = triPoints[cornerIndex];
  } else {
    float2 quadCorners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5),
                              float2(0.5, 0.5), float2(-0.5, 0.5) };
    float uv_x = instance.uv_rect.x;
    float uv_y = instance.uv_rect.y;
    float uv_w = instance.uv_rect[2];
    float uv_h = instance.uv_rect[3];
    float2 quadUVs[4] = { float2(uv_x, uv_y), float2(uv_x + uv_w, uv_y),
                          float2(uv_x + uv_w, uv_y + uv_h),
                          float2(uv_x, uv_y + uv_h) };
    float2 localPos = quadCorners[cornerIndex] * instance.scale;
    float s, c;
    sincos(instance.rotation, s, c);
    float2 rotated = float2(localPos.x * c - localPos.y * s,
                            localPos.x * s + localPos.y * c);
    finalWorldPos = rotated + instance.pos;
    finalUV = quadUVs[cornerIndex];
  }

  output.pos = mul(pc.projection_view, float4(finalWorldPos, 0.0, 1.0));
  output.uv = finalUV;
  output.texture_index = instance.texture_index;
  output.instance_index = instanceIndex;

  return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput input) {
  // using pre-multiplied alpha so additive effects use the same pipeline
  Instance instance = pc.data->instances[input.instance_index];
  Instance_Type instance_type = Instance_Type(instance.type);

  if (instance_type == Instance_Type.Sprite) {
    float4 texColor = textures[input.texture_index].Sample(input.uv);
    return texColor * instance.color;
  }

  if (instance_type == Instance_Type.Circle) {
    float d = distance(input.uv, float2(0.5, 0.5));
    float mask = 1.0 - smoothstep(0.48, 0.5, d);
    return instance.color * mask;
  }

  return instance.color;
}
