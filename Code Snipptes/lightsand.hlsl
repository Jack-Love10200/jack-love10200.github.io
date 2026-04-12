#ifndef TRASH_LIGHT_H
#define TRASH_LIGHT_H

#define MAX_LIGHTS 16
#define NO_LIGHT 0
#define DIRECTIONAL_LIGHT 1
#define POINT_LIGHT 2
#define SPOT_LIGHT 3

struct TrashLightData
{
  float4 color;
  float4 direction; // Only used for directional and spot lights, ignored for point lights
  float4 position;
  float angle;
  int type;
  float bias;
};

uniform StructuredBuffer<TrashLightData> _TrashLightBuffer;


//l = light direction (for directional and spot) or light position (for point)
//V = view direction
float4 ToonBlinnPhong(float3 V,
                      float3 l, 
                      float3 surfaceNormal, 
                      float4 lightColor,
                      float glossiness)
{
  //step to create the cel shading cutoff
  float nDotL = dot(normalize(l), surfaceNormal);
  nDotL = step(0, nDotL);

  float3 halfVector = normalize(l + V);
  float nDotH = dot(surfaceNormal, halfVector);

  //step to create the cel shading cutoff for the specular highlight
  float specular = pow(max(nDotH, 0.0), glossiness);
  specular = step(0.99, specular);

  float nDotV = dot(V, surfaceNormal);
  float rimPower = step(0.7, (1 - nDotV) * nDotL);
  float totalPower = nDotL + specular + rimPower;

  //Store whether or not there was specular highlighting in the alpha
  return float4(lightColor.rgb * totalPower, specular);
}

float4 ToonShading(int lightIndex, float3 normal, float3 worldPos, float3 camPos, float glossiness)
{
  float4 totalLight = float4(0, 0, 0, 0);

    TrashLightData light = _TrashLightBuffer[lightIndex];
    if (light.type == NO_LIGHT) return totalLight; // Skip empty slots
    
    float3 V = normalize(camPos - worldPos);
    float3 l = light.position.xyz - worldPos;// * light.position.w;

    switch (light.type)
    {
      case DIRECTIONAL_LIGHT:
        totalLight += ToonBlinnPhong(V, light.direction.xyz, normal, light.color, glossiness);
      break;
        case POINT_LIGHT:
        totalLight += ToonBlinnPhong(V, l, normal, light.color, glossiness);
        break;
      case SPOT_LIGHT:
        float3 spotDir = light.direction.xyz;
        float spotEffect = dot(normalize(l), normalize(spotDir));
        spotEffect = smoothstep(cos(radians(light.angle / 2)), cos(radians(light.angle / 2 * 0.9)), spotEffect);
        totalLight += ToonBlinnPhong(V, l, normal, light.color * spotEffect, glossiness);
        break;
    }

  return totalLight;
}

#endif


































// This defines a simple unlit Shader object that is compatible with a custom Scriptable Render Pipeline.
// It applies a hardcoded color, and demonstrates the use of the LightMode Pass tag.
// It is not compatible with SRP Batcher.

Shader "TrashRenderer/lit"
{
  Properties 
  {
    _MainColor ("Main Color", Color) = (1,1,1,1) // RGBA Color
    _MainTex ("Albedo", 2D) = "white" {}       // 2D Texture (default white)
    _DetailTex("Texture Detail", 2D) = "white" {}     // Additional texture for detail mapping
    _Glossiness ("Smoothness", Range(0,1)) = 0.5 // Slider
    _ShadowTex("Shadow Texture", 2D) = "white" {}     // Shadow map texture
    _NormalTex("Normal Map", 2D) = "bump" {}     // Normal map texture
    _NormalMapWeight("Normal Map Weight", Range(0,1)) = 1.0 // Slider for normal map influence
    _ChopSpeed("UV Chop Speed", Range(0,50)) = 1.0 // Slider for UV animation speed
    _ChopOffset("UV Chop Offset", Range(0,1)) = 0.0 // Slider for UV animation offset
    // Expose a Stencil ID property to change the reference value from the Inspector or C#
    [Toggle] _ScreenSpace("Screen Space Textures", Float) = 0 // Toggle to switch between screen-space and UV-based texture sampling for debugging
    [IntRange] _StencilID ("Stencil ID", range(0, 255)) = 1
  }
  SubShader
  {
    Pass
    {
      // The value of the LightMode Pass tag must match the ShaderTagId in ScriptableRenderContext.DrawRenderers
      Tags { "LightMode" = "ExampleLightModeTag"}

      Stencil
      {
          Ref [_StencilID] //write reference value from property to stencil buffer
          Comp Always      //always pass stencil test
          Pass Replace     //always rerplace stencil buffer value with reference value
      }

      HLSLPROGRAM
      #pragma target 4.5
      #pragma vertex vert
      #pragma fragment frag

      #pragma multi_compile _ADDITIONAL_LIGHTS
      #pragma multi_compile _ADDITIONAL_LIGHT_SHADOWS

      #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
      //#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

      #include "TrashLight.hlsl"
      #include "TrashShadow.hlsl"
 
      float4 _MainTex_ST;
      float4 _ShadowTex_ST;
      float4 _NormalTex_ST;
      float4 _DetailTex_ST;
      float4 _MainColor;

      float _ScreenSpace;

      uint _StencilID;

      CBUFFER_START(CamStuff)
        float3 _WorldSpaceCamPos;
        float3 _WorldSpaceCamDir;
      CBUFFER_END

      TEXTURE2D(_ShadowTex);
      SAMPLER(sampler_ShadowTex);

      TEXTURE2D(_MainTex);
      SAMPLER(sampler_MainTex);

      TEXTURE2D(_NormalTex);
      SAMPLER(sampler_NormalTex);

      TEXTURE2D(_DetailTex);
      SAMPLER(sampler_DetailTex);

      float _Glossiness;
      float _NormalMapWeight;
      float _ChopOffset;
      float _ChopSpeed;

      struct Attributes
      {
        float4 positionOBJECT_SPACE   : POSITION;
        float3 normalOS              : NORMAL;
        float2 uv : TEXCOORD0;
        float4 tangentOS : TANGENT;
      };


      struct vert2frag
      {
        float4 positionCLIP_SPACE : SV_POSITION;
        float2 uv : TEXCOORD0;
        float3 worldPos : TEXCOORD2;
        float3 normalWS : NORMAL;

        float3 tangentWS : TANGENT0;
        float3 bitangentWS : TANGENT1;

        float4 shadowClipPos[MAX_LIGHTS] : POSITION1;

        float4 screenPos : TEXCOORD1; // For debugging, pass screen position to fragment shader
      };

      //uniform float4 _Color

      vert2frag vert (Attributes IN)
      {
        vert2frag output;
        output.worldPos = mul(unity_ObjectToWorld, IN.positionOBJECT_SPACE).xyz;
        output.positionCLIP_SPACE = mul(unity_MatrixVP, float4(output.worldPos, 1));

        // Transform world position to shadow clip space
        
        for (int i = 0; i < MAX_LIGHTS; i++)
        {
          float4 shadowViewPos = mul(_TrashShadowView[i], float4(output.worldPos, 1));
          output.shadowClipPos[i] = mul(_TrashShadowProj[i], shadowViewPos);
        }
        //output.shadowClipPos = mul(_TrashShadowProj, shadowViewPos);

        //output.uv = TRANSFORM_TEX(IN.uv, _MainTex);
        output.uv = IN.uv;

        output.normalWS = normalize(mul(IN.normalOS, (float3x3) UNITY_MATRIX_I_M));
        output.tangentWS = normalize(mul(IN.tangentOS.xyz, (float3x3) UNITY_MATRIX_I_M));
        output.bitangentWS = cross(output.normalWS, output.tangentWS) * IN.tangentOS.w;

        output.screenPos = ComputeScreenPos(output.positionCLIP_SPACE); // For debugging, visualize clip space position in fragment shader

        // output.normalWS = normalize(mul(IN.normalOS, (float3x3) UNITY_MATRIX_I_M));
        // output.tangentWS = normalize(mul((float3x3)unity_ObjectToWorld, IN.tangentOS.xyz));

        // // Calculate bitangent in object space first, then transform
        // float3 bitangentOS = cross(IN.normalOS, IN.tangentOS.xyz) * IN.tangentOS.w;
        // output.bitangentWS = normalize(mul((float3x3)unity_ObjectToWorld, bitangentOS));

        return output;
      }

      struct outputFrag
      {
          float4 color : SV_Target0;
          uint stencil : SV_Target1;
      };

      outputFrag frag (vert2frag IN)
      {
        float choppedTime;
        float a = frac(_Time.y + _ChopOffset) * _ChopSpeed / 2.0; // Map sine wave from [-1,1] to [0,1]
        a = floor(a) / _ChopSpeed; // Quantize to discrete steps
        choppedTime = a;
        IN.uv += choppedTime; // Animate UVs for debugging

        float2 screenUVoffset = float2(5 * choppedTime, 7 * choppedTime); // Animate UVs for debugging
        float2 screenUV = IN.screenPos.xy / IN.screenPos.w; // Convert from homogeneous clip space to NDC
        screenUV += screenUVoffset; // Apply animated offset for debugging
        //screenUV = screenUV * 0.5 + 0.5; // Convert


        float3 albedo = float3(1, 1, 1);
        float3 normalMapSample = float3(0, 0, 1);
        float3 detail = float3(1, 1, 1);

        if (_ScreenSpace > 0.5)
        {
          albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, screenUV * _MainTex_ST.xy + _MainTex_ST.zw).rgb;
          normalMapSample = UnpackNormal(SAMPLE_TEXTURE2D(_NormalTex, sampler_NormalTex, screenUV * _NormalTex_ST.xy + _NormalTex_ST.zw));
          detail = SAMPLE_TEXTURE2D(_DetailTex, sampler_DetailTex, screenUV * _DetailTex_ST.xy + _DetailTex_ST.zw).rgb;
        }
        else
        {
          albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv * _MainTex_ST.xy + _MainTex_ST.zw).rgb;
          normalMapSample = UnpackNormal(SAMPLE_TEXTURE2D(_NormalTex, sampler_NormalTex, IN.uv * _NormalTex_ST.xy + _NormalTex_ST.zw));
          detail = SAMPLE_TEXTURE2D(_DetailTex, sampler_DetailTex, IN.uv * _DetailTex_ST.xy + _DetailTex_ST.zw).rgb;
        }




        //float3 normalMapSample = SAMPLE_TEXTURE2D(_NormalTex, sampler_NormalTex, IN.uv * _NormalTex_ST.xy + _NormalTex_ST.zw).rgb;
        // = normalMapSample * 2.0 - 1.0;
        //normalMapSample = normalize(normalMapSample);
        //normalMapSample = float3(0, 0, 1);

        float3 tangentSpaceNormal = normalize(lerp(float3(0, 0, 1), normalMapSample, _NormalMapWeight));

        float3 N = normalize(IN.normalWS);
        float3 T = normalize(IN.tangentWS);
        //T = normalize(T - dot(T, N) * N);
        //float3 B = cross(N, T);
        float3 B = normalize(IN.bitangentWS);

        float3x3 TBN = float3x3(T, B, N);

        // This transforms FROM tangent space TO world space
        float3 adjustedNormal = normalize(tangentSpaceNormal.x * T + tangentSpaceNormal.y * B + tangentSpaceNormal.z * N);

        adjustedNormal.x = tangentSpaceNormal.x * T.x + tangentSpaceNormal.y * B.x + tangentSpaceNormal.z * N.x;
        adjustedNormal.y = tangentSpaceNormal.x * T.y + tangentSpaceNormal.y * B.y + tangentSpaceNormal.z * N.y;
        adjustedNormal.z = tangentSpaceNormal.x * T.z + tangentSpaceNormal.y * B.z + tangentSpaceNormal.z * N.z;
        adjustedNormal = normalize(adjustedNormal);

        adjustedNormal = mul(TBN, tangentSpaceNormal);
        adjustedNormal = normalize(adjustedNormal);

        //normalMapSample = UnpackNormal(SAMPLE_TEXTURE2D(_NormalTex, sampler_NormalTex, IN.uv * _NormalTex_ST.xy + _NormalTex_ST.zw));
        //normalMapSample = UnpackNormal(SAMPLE_TEXTURE2D(_NormalTex, sampler_NormalTex, screenUV * _NormalTex_ST.xy + _NormalTex_ST.zw));

        tangentSpaceNormal = normalMapSample;
        adjustedNormal = normalize(T * tangentSpaceNormal.x + B * tangentSpaceNormal.y + N * tangentSpaceNormal.z);

        outputFrag DebugNormalOut;
        DebugNormalOut.stencil = _StencilID;
        //DebugNormalOut.color = float4(adjustedNormal * 0.5 + 0.5, 1);
        //DebugNormalOut.color = float4(normalMapSample, 1);
        //DebugNormalOut.color = float4(IN.tangentWS, 1);
        //DebugNormalOut.color = float4(IN.bitangentWS, 1);
        //DebugNormalOut.color = float4(IN.normalWS, 1); // Visualize normal map output
        DebugNormalOut.color = float4(screenUV, 0, 1); // Visualize clip space position
        //return DebugNormalOut;

        float4 AmbientLight = float4(0.05, 0.05, 0.05, 1);
        
        //float3 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, screenUV * _MainTex_ST.xy + _MainTex_ST.zw).rgb * _MainColor.rgb;
        //float3 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv * _MainTex_ST.xy + _MainTex_ST.zw).rgb * _MainColor.rgb;
        //float3 detail = SAMPLE_TEXTURE2D(_DetailTex, sampler_DetailTex, screenUV * _DetailTex_ST.xy + _DetailTex_ST.zw).rgb;
        //float3 detail = SAMPLE_TEXTURE2D(_DetailTex, sampler_DetailTex, IN.uv * _DetailTex_ST.xy + _DetailTex_ST.zw).rgb;

        albedo = lerp(albedo, detail, 0.0) * _MainColor.rgb; // Modulate base albedo with detail texture
        detail = detail * _MainColor.rgb; // Modulate detail texture with main color for debugging
        //float shadow = GetShadowValue(IN.shadowClipPos[1]);

        float3 finalColor = float3(0, 0, 0);

        int anyShadow = 0;
        int anyHighlight = 0;

        [unroll(MAX_LIGHTS)]
        for (int i = 0; i < MAX_LIGHTS; i++)
        {
          if (_TrashLightBuffer[i].type == NO_LIGHT) // No light
              continue;

          float shadow = GetShadowValue(IN.shadowClipPos[i], i, (IN.uv * _MainTex_ST.xy + _MainTex_ST.zw) + float2(_SinTime.x, _CosTime.x) * 0.1, _TrashLightBuffer[i].bias);
          
          if (shadow >= 0.0)
          { 
            float4 lightingColor = ToonShading(i, IN.normalWS, IN.worldPos, _WorldSpaceCamPos, _Glossiness);

            if (lightingColor.w > 0.1)
              anyHighlight = 1;

            float shadowTexSample = SAMPLE_TEXTURE2D(_ShadowTex, sampler_ShadowTex, IN.uv + float2((float)i / (float)MAX_LIGHTS, (float)i / (float)MAX_LIGHTS)).r;
            
            if (shadow < 0.5 && shadowTexSample < 0.5)
              anyShadow = 1;
            
            shadow = max(shadow, shadowTexSample);
            shadow = step(0.5, shadow); 
            
            lightingColor *= shadow;
            finalColor += lightingColor;
          }
        }

        // debug shadow vis
        float shadowDebug = 0.0;
        [unroll(MAX_LIGHTS)]
        for (int i = 0; i < MAX_LIGHTS; i++)
        {
          float shadowVal = GetShadowValue(IN.shadowClipPos[i], i, IN.uv * _MainTex_ST.xy + _MainTex_ST.zw, _TrashLightBuffer[i].bias);
          if (shadowVal >= 0.0)
              shadowDebug += shadowVal;
        }
        outputFrag shadowDebugOut;
        shadowDebugOut.stencil = _StencilID;
        shadowDebugOut.color = float4(shadowDebug, shadowDebug, shadowDebug, 1);
        // /return shadowDebugOut;

        //float3 finalColor = ToonShading(albedo, shadow, IN.normalWS, IN.worldPos, _WorldSpaceCamPos, _Glossiness);

        float3 outputColor = AmbientLight.rgb + finalColor;

        int stenciladdon = 0;
        
        if (anyHighlight == 1)
        {
          outputColor *= detail; // For debugging, show highlighted areas as solid color
          stenciladdon = 1;
        }
        else
        {
          outputColor *= albedo; // For debugging, show non-highlighted areas as base albedo color
        }

        if (anyShadow == 1)
            outputColor = float3(0, 0, 0); // In shadow, output black
          

        outputFrag outFrag;
        outFrag.color = float4(outputColor, 1);
        outFrag.stencil = _StencilID - stenciladdon;
        return outFrag;
      }
      ENDHLSL
    }
    Pass
    {
      Tags { "LightMode" = "ShadowCaster" }

      HLSLPROGRAM
      #pragma target 4.5
      #pragma vertex vert
      #pragma fragment frag

      #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

      struct Attributes
      {
        float4 positionOS : POSITION;
      };

      struct vert2frag
      {
        float4 positionCS : SV_POSITION;
      };

      vert2frag vert (Attributes IN)
      {
        vert2frag output;
        float3 worldPos = mul(unity_ObjectToWorld, IN.positionOS).xyz;
        output.positionCS = mul(unity_MatrixVP, float4(worldPos, 1.0));
        return output;
      }

      void frag (vert2frag IN)
      {
        // TODO: transparencty clipping
      }
      ENDHLSL
    }
  }
}


outputFrag frag (Varyings IN)
{
  //get the uv of the current pixel in screen space
  //from builtin unity uniforms
  float2 screenUV = IN.screenPos.xy / IN.screenPos.w;
  
  //Simple UV animation moving the sample around 
  //abruptly every few seconds for a choppy effect
  float choppedTime = frac(_Time.y + _ChopOffset) * _ChopSpeed / 2.0;
  choppedTime = floor(choppedTime) / _ChopSpeed;
  IN.uv += choppedTime;
  float2 screenUVoffset = float2(5 * choppedTime, 7 * choppedTime);
  screenUV += screenUVoffset;
  
  //Toggle between using screen-space UVs and regular UVs for texture sampling
  //useful for debugging issues with shadow UVs or screen-space effects
  float2 fragUV = _ScreenSpaceSampling ? screenUV : IN.uv;
  
  //Use our animated screen space UVs whenever sampling textures.
  albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, fragUV * _MainTex_ST.xy + _MainTex_ST.zw).rgb;
  
  
  //Rest of Fragment Shader...
}

if (_ScreenSpaceSampling)
  albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, screenUV * _MainTex_ST.xy + _MainTex_ST.zw).rgb;
else
  albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv * _MainTex_ST.xy + _MainTex_ST.zw).rgb;
