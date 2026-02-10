struct Instance {
  float2 pos;
  float2 scale;
  float rotation;
  uint32_t texture_index;
  uint32_t type;
  uint32_t data1;
  float4 color; // pre-multiplied alpha
  float4 uv_rect;

  // When type is Instance_Type.Triangle we need to smuggle the three points
  // inside other quad instance fields to preserve a single shader & pipeline
  property float2 tri_p0 {
    get { return pos; }
  }
  property float2 tri_p1 {
    get { return scale; }
  }
  property float2 tri_p2 {
    get { return float2(rotation, asfloat(data1)); }
  }

  property uint32_t font_index {
    get { return data1; }
  }
};

// Remember to update shader_types_gen since it can't get enums automatically
enum Instance_Type : uint32_t {
  Sprite = 0,
  Rect = 1,
  Circle = 2,
  Triangle = 3,
  MSDF = 4,
}

struct Font {
  float px_range;
  uint32_t _pad0;
  uint32_t2 tex_size;
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

// Expose to the reflection_types JSON output since this type is not actually
// directly used anywhere
StructuredBuffer<Shader_Data> _ReflectionAnchor;

[[vk::push_constant]]
Push_Constants pc;

[[vk::binding(0, 0)]]
Sampler2D textures[];

[[vk::binding(1, 0)]]
StructuredBuffer<Font> fonts;

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
    float2 triPoints[4] = { instance.tri_p0, instance.tri_p1, instance.tri_p2,
                            instance.tri_p0 };
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

  if (instance_type == Instance_Type.MSDF) {
    Font font = fonts[instance.font_index];
    float3 msdf = textures[instance.texture_index].Sample(input.uv).rgb;
    float a = msdf_coverage(msdf, input.uv, font.tex_size, font.px_range);
    return instance.color * a;
  }

  return instance.color;
}

float msdf_coverage(float3 msdf, float2 uv, float2 texSizePx, float pxRange) {
  float sd = median3(msdf.r, msdf.g, msdf.b) - 0.5;
  float2 dx = ddx(uv * texSizePx);
  float2 dy = ddy(uv * texSizePx);
  float texelsPerPixel = rsqrt(max(dot(dx, dx), dot(dy, dy)));
  float screenPxRange = max(0.5 * pxRange * texelsPerPixel, 1.0);
  return saturate((sd + 0.01) * (screenPxRange * 1.15) + 0.5);
}
