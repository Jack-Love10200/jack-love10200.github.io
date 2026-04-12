/**
 * File: TrashRenderPipelineInstance.cs
 * Author: Jack Love
**/

using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using System.Collections.Generic;
using UnityEditor;
using UnityEditor.Rendering;
using JetBrains.Annotations;
using UnityEngine.Rendering.RenderGraphModule.Util;
using Unity.VisualScripting;
using UnityEngine.Rendering.Universal;
using UnityEngine.UI;
using UnityEditor.Rendering.Canvas.ShaderGraph;
using NUnit.Framework.Internal;

public class TrashRenderPipelineInstance : RenderPipeline
{
  #region Constants
  public static readonly int ShadowMapResolution = 2048;
  public static readonly int MAX_SHADOW_MAPS = 16;
  #endregion

  public Camera currentCamera;
  public TrashRenderPipelineAsset _asset;

  [SerializeReference]
  List<ITrashRenderPass> renderPasses = new List<ITrashRenderPass>();
  RenderGraph renderGraph;
  RTHandle m_CameraColor;

  int frameCount = 0;


  public ShadowInfo[] shadowInfos = new ShadowInfo[MAX_SHADOW_MAPS];

  public struct ShadowInfo
  {
    public RendererList rendererList;
    public Matrix4x4 view;
    public Matrix4x4 proj;
    public Matrix4x4 projGPU;
    public bool IsUsed;
  }

#region RenderTextures
  public RTHandle finalRT;

  public RTHandle stencilRT;
  public TextureHandle StencilBufferHandle;

  public RTHandle cameraColorRT;
  public TextureHandle cameraColorHandle;

  public RTHandle cameraDepthRT;
  public TextureHandle cameraDepthHandle;

  public RTHandle sceneColorRT;
  public TextureHandle SceneTexHandle;

  public RTHandle distanceFieldRT;
  public TextureHandle  distanceFieldHandle;

  public RTHandle JFASeed1RT;
  public TextureHandle JFASeed1Handle;

  public RTHandle JFASeed2RT;
  public TextureHandle JFASeed2Handle;


  public RenderTexture shadowMapArray;
  public RTHandle shadowMapArrayRT;
  public TextureHandle shadowMapArrayHandle;

  public RenderTexture shadowCubeArray;
  public RTHandle shadowCubeArrayRT;
  public TextureHandle shadowCubeArrayHandle;
  #endregion


  public CullingResults cullingResults;

  public RendererList rl;
  public RendererList sky;

  public List<RendererList> stencilRendererLists;
  public Material stencilMaterial;
  public List<Material> stencilMats;

  static readonly int _ShadowMapID = Shader.PropertyToID("_ShadowMap");

  public TrashRenderPipelineInstance(TrashRenderPipelineAsset asset)
  {
    _asset = asset;
  }

  public void AddRenderPass([PublicAPI] ITrashRenderPass pass)
  {
    pass.Init();
    renderPasses.Add(pass);
  }

  private void AllocateShadowMapArray()
  {
    if (shadowMapArray == null)
    {
      shadowMapArray = new RenderTexture(ShadowMapResolution, ShadowMapResolution, 32, RenderTextureFormat.Shadowmap);
      shadowMapArray.dimension = UnityEngine.Rendering.TextureDimension.Tex2DArray;
      shadowMapArray.volumeDepth = MAX_SHADOW_MAPS;
      shadowMapArray.filterMode = FilterMode.Bilinear;
      shadowMapArray.useMipMap = false;
      shadowMapArray.name = "Shadow Maps";
      shadowMapArray.Create();
    }

    shadowMapArrayRT = RTHandles.Alloc(shadowMapArray);
    shadowMapArrayHandle = renderGraph.ImportTexture(shadowMapArrayRT);

    if (shadowCubeArray == null)
    {
      shadowCubeArray = new RenderTexture(ShadowMapResolution, ShadowMapResolution, 32, RenderTextureFormat.Shadowmap);
      shadowCubeArray.dimension = UnityEngine.Rendering.TextureDimension.CubeArray;
      shadowCubeArray.volumeDepth = MAX_SHADOW_MAPS * 6;
      shadowCubeArray.filterMode = FilterMode.Bilinear;
      shadowCubeArray.useMipMap = false;
      shadowCubeArray.Create();
    }

    shadowCubeArrayRT = RTHandles.Alloc(shadowCubeArray);
    shadowCubeArrayHandle = renderGraph.ImportTexture(shadowCubeArrayRT);
  }

private void SetUpRendererLists(ScriptableRenderContext context)
{
  //Only one light mode tag for everything for now
  ShaderTagId shaderTagId = new ShaderTagId("ExampleLightModeTag");

  //Set up settings for drawing all of the geometry in the scene
  //with the simple built-in sorting and no filtering
  var sortingSettings = new SortingSettings(currentCamera);
  DrawingSettings drawingSettings = new DrawingSettings(shaderTagId, sortingSettings);
  FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.all);

  // UI + unlit objects
  var uiTag = new ShaderTagId("UI_Unlit");
  drawingSettings.SetShaderPassName(1, uiTag);

  //let unity do camera culling.
  currentCamera.TryGetCullingParameters(out var cullingParameters);
  cullingParameters.shadowDistance = _PipelineAsset.shadowDistance;
  cullingResults = context.Cull(ref cullingParameters);

  //get the final list of all 
  RendererListParams param = new RendererListParams(cullingResults, drawingSettings, filteringSettings);
  rendererListAllGeometry = context.CreateRendererList(ref param);
}

  private void SetupShadowRendererList(ScriptableRenderContext context)
  {
    for (int i = 0; i < MAX_SHADOW_MAPS; i++)
      shadowInfos[i].IsUsed = false;

    int realMaxLights = Mathf.Min(cullingResults.visibleLights.Length, MAX_SHADOW_MAPS);

    ShadowCastersCullingInfos shadowCastersCullingInfos = new ShadowCastersCullingInfos();
    shadowCastersCullingInfos.splitBuffer = new Unity.Collections.NativeArray<ShadowSplitData>(realMaxLights, Unity.Collections.Allocator.Temp);
    shadowCastersCullingInfos.perLightInfos = new Unity.Collections.NativeArray<LightShadowCasterCullingInfo>(realMaxLights, Unity.Collections.Allocator.Temp);

    int shadowMapIndex = 0;

    for (int i = 0; i < realMaxLights; i++)
    {
      if (!cullingResults.GetShadowCasterBounds(i, out Bounds bounds))
      {
        if (_asset.VerboseLogging)
          Debug.LogWarning("No shadow casters visible for light " + i);
        continue;
      }

      // Use Unity's matrices for rendering (they handle culling correctly)
      // cascadeRatios must be (1,0,0) for single cascade to cover full shadow distance
      Matrix4x4 unityView = new Matrix4x4();
      Matrix4x4 unityProj = new Matrix4x4();
      ShadowSplitData splitData = new ShadowSplitData();



      switch (cullingResults.visibleLights[i].lightType)
      {
        case LightType.Directional:
          cullingResults.ComputeDirectionalShadowMatricesAndCullingPrimitives(i, 0, 1, new Vector3(1f, 0f, 0f), ShadowMapResolution, 0.1f, out unityView, out unityProj, out splitData);
          FillOutFlatShadowInfo(shadowMapIndex, ref unityView, ref unityProj, LightType.Directional, ref shadowCastersCullingInfos, ref splitData, context, i);
          shadowMapIndex++;
          break;
        case LightType.Spot:
          cullingResults.ComputeSpotShadowMatricesAndCullingPrimitives(i, out unityView, out unityProj, out splitData);
          FillOutFlatShadowInfo(shadowMapIndex, ref unityView, ref unityProj, LightType.Spot, ref shadowCastersCullingInfos, ref splitData, context, i);
          shadowMapIndex++;
          break;
        case LightType.Point:
          for (int j = 0; j < 6; j++)
          {
            cullingResults.ComputePointShadowMatricesAndCullingPrimitives(i, (CubemapFace)j, 0.1f, out unityView, out unityProj, out splitData);
            FillOutFlatShadowInfo(shadowMapIndex, ref unityView, ref unityProj, LightType.Point, ref shadowCastersCullingInfos, ref splitData, context, i);
            shadowMapIndex++;
          }
          break;
      }
    }

    shadowCastersCullingInfos.perLightInfos.Dispose();
    shadowCastersCullingInfos.splitBuffer.Dispose();
  }



  private void FillOutFlatShadowInfo(int shadowMapIndex, ref Matrix4x4 unityView, ref Matrix4x4 unityProj, LightType lightType,
  ref ShadowCastersCullingInfos shadowCastersCullingInfos, ref ShadowSplitData splitData, ScriptableRenderContext context, int i)
  {
    if (shadowMapIndex < 0 || shadowMapIndex >= MAX_SHADOW_MAPS)
    {
      if (_asset.VerboseLogging) Debug.LogError("Shadow map index out of bounds: " + shadowMapIndex);
      return;
    }

    ref ShadowInfo shadowInfo = ref shadowInfos[shadowMapIndex];
    shadowInfo.view = unityView;
    shadowInfo.proj = unityProj;
    shadowInfo.IsUsed = true;

    shadowInfo.projGPU = GL.GetGPUProjectionMatrix(unityProj, true);
    shadowCastersCullingInfos.splitBuffer[i] = splitData;

    var perLightInfo = new LightShadowCasterCullingInfo();
    perLightInfo.splitRange = new RangeInt(0, 1);
    perLightInfo.projectionType = lightType == LightType.Directional ? BatchCullingProjectionType.Orthographic : BatchCullingProjectionType.Perspective;

    shadowCastersCullingInfos.perLightInfos[i] = perLightInfo;

    ShadowDrawingSettings shadowDrawingSettings = new ShadowDrawingSettings(cullingResults, i);
    shadowDrawingSettings.lightIndex = i;

    shadowInfo.rendererList = context.CreateShadowRendererList(ref shadowDrawingSettings);
  }

  private void AllocateRenderTextures()
  {
    cameraColorRT = RTHandles.Alloc(
        currentCamera.pixelWidth,
        currentCamera.pixelHeight,
        colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.R8G8B8A8_UNorm,
        name: "CameraColor");

    cameraDepthRT = RTHandles.Alloc(
      currentCamera.pixelWidth,
      currentCamera.pixelHeight,
      depthBufferBits: DepthBits.Depth24, // Use Depth24 for Depth24_Stencil8 format
      colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.None,
      name: "CameraDepth");

    sceneColorRT = RTHandles.Alloc(
      currentCamera.pixelWidth,
      currentCamera.pixelHeight,
      colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.R8G8B8A8_UNorm,
      name: "SceneColor");

    stencilRT = RTHandles.Alloc(
      currentCamera.pixelWidth,
      currentCamera.pixelHeight,
      colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.R8_UInt,
      name: "StencilBuffer");

    distanceFieldRT = RTHandles.Alloc(
      currentCamera.pixelWidth,
      currentCamera.pixelHeight,
      colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.R16G16B16A16_SFloat,
      enableRandomWrite: true,
      name: "DistanceField");

    JFASeed1RT = RTHandles.Alloc(
      currentCamera.pixelWidth,
      currentCamera.pixelHeight,
      colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.R32G32B32A32_SFloat,
      enableRandomWrite: true,
      name: "JFASeed1");

    JFASeed2RT = RTHandles.Alloc(
      currentCamera.pixelWidth,
      currentCamera.pixelHeight,
      colorFormat: UnityEngine.Experimental.Rendering.GraphicsFormat.R32G32B32A32_SFloat,
      enableRandomWrite: true,
      name: "JFASeed2");

    cameraColorHandle = renderGraph.ImportTexture(cameraColorRT);
    cameraDepthHandle = renderGraph.ImportTexture(cameraDepthRT);
    SceneTexHandle = renderGraph.ImportTexture(sceneColorRT); 
    StencilBufferHandle = renderGraph.ImportTexture(stencilRT);
    distanceFieldHandle = renderGraph.ImportTexture(distanceFieldRT);
    JFASeed1Handle = renderGraph.ImportTexture(JFASeed1RT);
    JFASeed2Handle = renderGraph.ImportTexture(JFASeed2RT);

    AllocateShadowMapArray();
  }

  protected override void Render(ScriptableRenderContext context, Camera[] cameras)
  {
    QualitySettings.shadowDistance = 200.0f;

    if (renderGraph == null)
    {
      renderGraph = new RenderGraph("Trash Render Graph");
      renderGraph.nativeRenderPassesEnabled = true;
    }

    frameCount++;

    // Iterate over all Cameras
    foreach (Camera camera in cameras)
    {
      currentCamera = camera;

      //unity boilerplate
      if (camera.cameraType != CameraType.Game &&
#if UNITY_EDITOR
    camera.cameraType != CameraType.SceneView
#else
            true
#endif
   )
        continue;
#if UNITY_EDITOR
      if (camera.cameraType == CameraType.SceneView)
      {
        ScriptableRenderContext.EmitWorldGeometryForSceneView(camera);
      }
#endif
      context.SetupCameraProperties(camera);
      camera.clearFlags = CameraClearFlags.Skybox;

      //culling
      camera.TryGetCullingParameters(out var cullingParameters);
      cullingParameters.shadowDistance = _asset.shadowDistance; // Use consistent shadow distance
      cullingResults = context.Cull(ref cullingParameters);

      //ShadowCastersCullingInfos shadowCasterCullingInfos = new ShadowCastersCullingInfos();
      // shadowCasterCullingInfos.perLightInfos
      // context.CullShadowCasters(cullingResults)

      SetUpRendererLists(context);
      SetupShadowRendererList(context);

      //context.CullShadowCasters(cullingResults, shadowCasterCullingInfos);

      //start up command buffer and render graph
      var cmd = new CommandBuffer();
      RenderGraphParameters parameters = new RenderGraphParameters();
      parameters.commandBuffer = cmd;
      parameters.scriptableRenderContext = context;
      parameters.currentFrameIndex = frameCount;
      parameters.executionName = camera.name;
      renderGraph.BeginRecording(parameters);

      AllocateRenderTextures();
      cmd.GetTemporaryRT(_ShadowMapID, ShadowMapResolution, ShadowMapResolution, 32, FilterMode.Bilinear, RenderTextureFormat.Shadowmap);

      //render pre-process gizmos
#if UNITY_EDITOR
      cmd.SetViewProjectionMatrices(camera.worldToCameraMatrix, camera.projectionMatrix);
      if (camera.cameraType == CameraType.SceneView && Handles.ShouldRenderGizmos())
        context.DrawGizmos(camera, GizmoSubset.PreImageEffects);
#endif

      //add all of the main render code to the graph and execute
      foreach (ITrashRenderPass pass in renderPasses)
        pass.AddToGraph(renderGraph, this);
      renderGraph.EndRecordingAndExecute();

      //blit final texture to backbuffer, let unity overlay postprocess gizmos
      cmd.Blit(finalRT, BuiltinRenderTextureType.CameraTarget);
      //cmd.Blit(distanceFieldHandle, BuiltinRenderTextureType.CameraTarget);
      cmd.SetViewProjectionMatrices(camera.worldToCameraMatrix, camera.projectionMatrix);
      cmd.ReleaseTemporaryRT(_ShadowMapID);
      context.ExecuteCommandBuffer(cmd);
      cmd.Clear();
#if UNITY_EDITOR
      if (camera.cameraType == CameraType.SceneView && Handles.ShouldRenderGizmos())
        context.DrawGizmos(camera, GizmoSubset.PostImageEffects);
#endif

      //cleanup
      context.Submit();
      cmd.Release();
      cameraColorRT.Release();
      cameraDepthRT.Release();
      sceneColorRT.Release();
      stencilRT.Release();
      distanceFieldRT.Release();
      JFASeed1RT.Release();
      JFASeed2RT.Release();

      shadowMapArrayRT.Release();
      shadowCubeArrayRT.Release();

      // for (int i = 0; i < MAX_SHADOW_MAPS; i++)
      // {
      //   if (!shadowInfos[i].IsUsed)
      //     continue;
      //   shadowInfos[i].shadowMapRT.Release();
      // }

      //ShadowMapRT.Release();

#if UNITY_EDITOR
      if (camera.cameraType == CameraType.Game)
#else
      if (camera.cameraType == CameraType.Game || camera.cameraType == CameraType.SceneView)
#endif
        context.DrawUIOverlay(camera);

    }
    renderGraph.EndFrame();
  }


  protected override void Dispose(bool disposing)
  {
    base.Dispose(disposing);

    foreach (var pass in renderPasses)
    {
      if (pass is System.IDisposable disposable)
        disposable.Dispose();
    }
    renderPasses.Clear();
  }
}