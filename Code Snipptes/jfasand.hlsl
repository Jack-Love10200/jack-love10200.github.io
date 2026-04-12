// Each #kernel tells which function to compile; you can have many kernels
#pragma kernel CSMain
#pragma kernel Seed
#pragma kernel JFAPass
#pragma kernel DistancePass
// Create a RenderTexture with enableRandomWrite flag and set it
// with cs.SetTexture
Texture2D<uint> _StencilBuffer;

RWTexture2D<float4> _SeedRead;
RWTexture2D<float4> _SeedWrite;

RWTexture2D<float4> _DistanceOutput;

int2 _TextureSize;
int _StepSize;

bool IsOnStencilEdge(uint2 coord);


static const float4 BAD_SEED = float4(-1, -1, -1, -1);
static const int2 NEIGHBOR_OFFSETS[8] =
{
    int2(-1, -1), int2(0, -1), int2(1, -1),
    int2(-1,  0),              int2(1,  0),
    int2(-1,  1), int2(0,  1), int2(1,  1),
};

bool IsOnStencilEdge(uint2 coord)
{
  uint center = _StencilBuffer[coord].r;

  //loop thru neighors
  //if any neighor has a different stencil value then this is an edge
  for (int i = 0; i < 8; i++)
  {
    int2 neighborCoord = int2(coord) + NEIGHBOR_OFFSETS[i];
    if (neighborCoord.x < 0 || neighborCoord.y < 0 || 
      neighborCoord.x >= _TextureSize.x || neighborCoord.y >= _TextureSize.y)
      continue;

    uint neighborValue = _StencilBuffer[uint2(neighborCoord)].r;
    if (neighborValue > center)
      return true;
  }
  return false;
}

[numthreads(8,8,1)]
void Seed(uint3 id : SV_DispatchThreadID)
{
  if (any(id.xy >= (uint2)_TextureSize))
    return;

  _SeedWrite[id.xy] = IsOnStencilEdge(id.xy) ? float4(id.xy, 0, 1) : BAD_SEED;
}

// Checks if the seed is valid (not BAD_SEED)
bool IsValidSeed(float4 seed)
{
    return seed.x >= 0.0;
}

[numthreads(8,8,1)]
void JFAPass(uint3 id : SV_DispatchThreadID)
{
  if (any(id.xy >= (uint2)_TextureSize)) return;

  float4 bestSeed = _SeedRead[id.xy];
  float  bestDist = IsValidSeed(bestSeed)
      ? distance(float2(id.xy), bestSeed.xy)
      : 1e38;

  //for each pixel step size away in each direction
  [unroll]
  for (int i = 0; i < 8; i++)
  {
    //sample the seed texture at that location
    int2 sampleCoord = (int2)id.xy + NEIGHBOR_OFFSETS[i] * _StepSize;
    sampleCoord = clamp(sampleCoord, int2(0, 0), _TextureSize - 1);
    float4 candidate = _SeedRead[sampleCoord];

    //we dont care about it if it hasnt found a seed yets
    if (!IsValidSeed(candidate)) continue;

    //if it's better than the our current best, update our best
    float d = distance(float2(id.xy), candidate.xy);
    if (d < bestDist)
    {
      bestDist = d;
      bestSeed = candidate;
    }
  }
  _SeedWrite[id.xy] = bestSeed;
}

[numthreads(8, 8, 1)]
void DistancePass(uint3 id : SV_DispatchThreadID)
{
  if (any(id.xy >= (uint2)_TextureSize)) return;

  //get distance between this pixel and its seed
  float4 seed = _SeedRead[id.xy];
  float dist = distance(float2(id.xy), seed.xy);

  //adjust the distacne for sharper falloff near edge, 
  //better for drop shadows
  float adjustedDistance = dist / 1000;
  if (adjustedDistance < 0.02)
    adjustedDistance = 4 * adjustedDistance;
  else
    adjustedDistance = sqrt(sqrt(adjustedDistance - 0.02)) + 0.15;    
  adjustedDistance = saturate(adjustedDistance);

  float output = IsValidSeed(seed) ? adjustedDistance : 0.0;

  //don't put drop shadow on pixels that are above us in the diorama
  uint selfStencilVal = _StencilBuffer[id.xy].r;
  uint seedStencilVal = _StencilBuffer[uint2(seed.xy)].r;
  if (selfStencilVal == seedStencilVal)
    output = 1.0f;

  _DistanceOutput[id.xy] = output;
}







vert2frag vert (Attributes IN)
{
  //...

  //calculate clip space positions for all lights
  for (int i = 0; i < MAX_LIGHTS; i++)
  {
    float4 shadowViewPos = mul(_ShadowView[i], float4(output.worldPos, 1));
    output.shadowClipPos[i] = mul(_ShadowProj[i], shadowViewPos);
  }
  //...
}

outputFrag frag (Varyings IN)
{
  //...

  [unroll(MAX_LIGHTS)]
  for (int i = 0; i < MAX_LIGHTS; i++)
  {
    if (_TrashLightBuffer[i].type == NO_LIGHT) // No light
        continue;

    //get whether this fragment is in shadow for the current light
    float shadow = GetShadowValue(IN.shadowClipPos[i], i, (fragUV * _MainTex_ST.xy + _MainTex_ST.zw), _TrashLightBuffer[i].bias);

    //skip negative, they indicate unused lights/shadow maps
    if (shadow < 0.0)
      continue;

    //get cel shaded lighting value for this light
    float4 lightingColor = ToonShading(i, IN.normalWS, IN.worldPos, _WorldSpaceCamPos, _Glossiness);    
    float shadowTexSample = SAMPLE_TEXTURE2D(_ShadowTex, sampler_ShadowTex, fragUV * _ShadowTex_ST.xy + _ShadowTex_ST.zw).r;

    //only darken the pixel if its in shadow and the texture says so
    shadow = max(shadow, shadowTexSample);

    //binarize for sharper edges
    shadow = step(0.5, shadow); 

    //apply stylized shadow and light
    lightingColor *= shadow;
    finalColor += lightingColor;
  }

  //...
}


float GetShadowValue(float4 shadowClipPos, int lightIndex, float2 uv, float bias)
{
  float3 shadowNDC = shadowClipPos.xyz / shadowClipPos.w;
  float2 shadowUV = shadowNDC.xy * 0.5 + 0.5;
  shadowUV.y = 1.0 - shadowUV.y;

  if (shadowUV.x < 0 || shadowUV.x > 1 || shadowUV.y < 0 || shadowUV.y > 1)
      return -1.0; // Outside shadow map bounds

  if (shadowNDC.z < 0.0 || shadowNDC.z > 1.0)
      return -1.0; 
  
  float currentDepth = shadowNDC.z;
  
  //make sure z is the right way around
  #if UNITY_REVERSED_Z
  float biasedDepth = currentDepth + bias;
  #else
  float biasedDepth = currentDepth - bias;
  #endif

  shadow = SAMPLE_TEXTURE2D_ARRAY_SHADOW(_ShadowMaps, sampler_linear_clamp_compare, float3(shadowUV, biasedDepth), lightIndex);

  return shadow;
}