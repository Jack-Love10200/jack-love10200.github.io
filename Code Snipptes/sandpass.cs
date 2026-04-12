/**
 * File: MainPass.cs
 * Author: Jack Love
**/

using Unity.VisualScripting;
using UnityEditor.Rendering.Canvas.ShaderGraph;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule; 
[CreateAssetMenu(fileName = "GeometryPass", menuName = "TrashPasses/GeometryPass")]
public class GeometryPass : TrashRasterPass<GeometryPass.GeometryPassData>
{
  public override bool IsPostProcessPass => false;

  public class GeometryPassData : PassData
  {
    public RendererList rendererList;
    public TrashRenderPipelineInstance.ShadowInfo[] shadowInfos;
  }

  public override void RequestData(
  RenderGraph renderGraph, 
  GeometryPassData data, 
  TrashRenderPipelineInstance instance, 
  IRasterRenderGraphBuilder builder)
  {
    //settings
    builder.AllowPassCulling(false);
    builder.AllowGlobalStateModification(true);

    data.rendererList = instance.rendererListAllGeometry;
    data.shadowInfos = instance.shadowInfos;

    //render to scene texture and stencil buffer
    builder.SetRenderAttachment(instance.SceneTexHandle, 0, AccessFlags.Write);
    builder.SetRenderAttachment(instance.StencilBufferHandle, 1, AccessFlags.Write);

    //read from shadow maps rendered in previous passs
    builder.UseTexture(instance.shadowMapArrayHandle, AccessFlags.Read);
  }

  public override void Execute(GeometryPassData data, RasterGraphContext RGcontext) 
  {
    RasterCommandBuffer cmd = RGcontext.cmd;
    cmd.SetViewProjectionMatrices(data.camera.worldToCameraMatrix,
                                  data.camera.projectionMatrix);
    cmd.DrawRendererList(data.rendererList);
  }
}