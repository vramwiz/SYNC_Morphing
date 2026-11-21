unit Morphing_HostRender;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses Winapi.D3DCommon, AviUtl2FilterTypes, Morphing_Model, Morphing_Renderer, Morphing_Images;

type
  THostImagePaths = array[TImageSide] of string;
  TMorphHostRender = class
  private
    FShader: ID3DBlob;
    FCompileAttempted: Boolean;
    FContourCache: TSourceImages;
    FContourNames: THostImagePaths;
    function LoadShader: Boolean;
    function CacheContour(Video: PFILTER_PROC_VIDEO; Side: TImageSide; const Field: TMorphImage): Boolean;
  public
    function Draw(Video: PFILTER_PROC_VIDEO; Renderer: TMorphRenderer;
      const Images: TSourceImages; const Paths: THostImagePaths; Progress: Integer): Boolean;
  end;

implementation

uses System.Types, System.SysUtils, Winapi.Windows, Winapi.D3DCompiler;

const
  TriangleTexture = 3;
  SamplerClip = 0;
  BlendSource: AnsiString =
    'Texture2D<float4> imageA : register(t0);' +
    'Texture2D<float4> imageB : register(t1);' +
    'Texture2D<float4> fieldA : register(t2);' +
    'Texture2D<float4> fieldB : register(t3);' +
    'cbuffer parameters : register(b0) {' +
    '  float amount; float strength; float reserved; float paleMattes;' +
    '  float shapeTime; float useFields; float2 padding;' +
    '};' +
    'float edge(float d) { return smoothstep(0, 1, 0.5 + 12 * d); }' +
    'float2 matchSurface(float2 avail, float da, float db) {' +
    '  if (max(da, db) <= -1.0 / 24.0 || min(da, db) >= 1.0 / 24.0) return avail;' +
    '  float coverage = edge(lerp(da, db, shapeTime));' +
    '  float2 part = float2(edge(da), edge(db));' +
    '  float2 hit = avail * lerp(1 - part, part, coverage);' +
    '  return hit.x + hit.y > 0.00001 ? hit : avail;' +
    '}' +
    'float4 morphSilhouette(float4 a, float4 b, float3 da, float3 db, uint matte) {' +
    '  da.z *= 2; db.z *= 2;' +
    '  float coverage = edge(lerp(da.x, db.x, shapeTime));' +
    '  float availA = a.a * edge(da.x), availB = b.a * edge(db.x);' +
    '  float matteAlpha = ((matte & 1u) != 0 ? a.a * (1 - amount) : 0) +' +
    '                     ((matte & 2u) != 0 ? b.a * amount : 0);' +
    '  float4 bg = matteAlpha * float4(253.0 / 255, 253.0 / 255, 253.0 / 255, 1);' +
    '  float4 fg = bg;' +
    '  if (coverage > 0 && availA + availB > 0.00001) {' +
    '    float3 ca = a.rgb / max(0.00001, a.a), cb = b.rgb / max(0.00001, b.a);' +
    '    float blend = clamp(amount, 0.001, 0.999);' +
    '    float2 avail = matchSurface(float2(availA, availB), da.y, db.y);' +
    '    avail = matchSurface(avail, da.z, db.z);' +
    '    float weight = avail.y * blend / (avail.x * (1 - blend) + avail.y * blend);' +
    '    coverage *= lerp(max(a.a, 1 - edge(da.x - 0.06)), max(b.a, 1 - edge(db.x - 0.06)), weight);' +
    '    fg = float4(lerp(ca, cb, weight), 1) * coverage + bg * (1 - coverage);' +
    '  }' +
    '  float influence = smoothstep(0, 1, 16 * min(shapeTime, 1 - shapeTime));' +
    '  float4 endpoint = shapeTime < 0.5 ? a : b;' +
    '  return lerp(lerp(a, b, amount), lerp(endpoint, fg, influence), strength);' +
    '}' +
    'float4 psmain(float4 pos : SV_Position) : SV_Target {' +
    '  int3 p = int3(int2(pos.xy), 0);' +
    '  float4 a = imageA.Load(p), b = imageB.Load(p);' +
    '  if (useFields > 0)' +
    '    return morphSilhouette(a, b, fieldA.Load(p).rgb - 0.5, fieldB.Load(p).rgb - 0.5, (uint)paleMattes);' +
    '  return lerp(a, b, amount);' +
    '}';

function TMorphHostRender.LoadShader: Boolean;
var
  Errors: ID3DBlob;
begin
  if not FCompileAttempted then
  begin
    FCompileAttempted := True;
    try
      if Failed(D3DCompile(PAnsiChar(BlendSource), Length(BlendSource), nil, nil, nil,
        'psmain', 'ps_5_0', D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, FShader, Errors)) then
        FShader := nil;
    except
      FShader := nil;
    end;
  end;
  Result := FShader <> nil;
end;

function TMorphHostRender.CacheContour(Video: PFILTER_PROC_VIDEO; Side: TImageSide;
  const Field: TMorphImage): Boolean;
var
  W, H: Integer;
begin
  if FContourNames[Side] = '' then
    FContourNames[Side] := Format('cache:SYNC_Morphing_contour_%x_%d', [NativeUInt(Self), Ord(Side)]);
  if (Pointer(FContourCache[Side].Pixels) = Pointer(Field.Pixels)) and
    (Video^.GetImageResourceSize(PChar(FContourNames[Side]), W, H) <> 0) and
    (W = Field.Width) and (H = Field.Height) then Exit(True);
  Video^.CreateImageResource(PChar(FContourNames[Side]), @Field.Pixels[0], Field.Width, Field.Height);
  Result := (Video^.GetImageResourceSize(PChar(FContourNames[Side]), W, H) <> 0) and
    (W = Field.Width) and (H = Field.Height);
  if Result then FContourCache[Side] := Field;
end;

function TMorphHostRender.Draw(Video: PFILTER_PROC_VIDEO; Renderer: TMorphRenderer;
  const Images: TSourceImages; const Paths: THostImagePaths; Progress: Integer): Boolean;
const
  Resources: array[0..3] of PWideChar = ('resource:SYNC_Morphing_A', 'resource:SYNC_Morphing_B',
    'resource:SYNC_Morphing_contour_A', 'resource:SYNC_Morphing_contour_B');
var
  Source: THostImagePaths;
  Fields: TSourceImages;
  Vertices: THostVertices;
  Side: TImageSide;
  Size: TSize;
  W, H, ResourceCount: Integer;
  UseFields: Boolean;
  Constants: array[0..7] of Single;
  Transparent: TPIXEL_RGBA;

  function WarpResource(Destination, Input: PWideChar; ImageSide: TImageSide): Boolean;
  begin
    Video^.CreateImageResource(Destination, nil, Size.cx, Size.cy);
    Result := (Video^.ClearImageResource(Destination, Transparent) <> 0) and
      (Video^.DrawPolyToResource(Destination, TriangleTexture, @Vertices[ImageSide][0],
        Length(Vertices[ImageSide]), Input) <> 0);
  end;
begin
  Result := False;
  if (Progress <= 0) or (Progress >= 10000) then Exit;
  if not Assigned(Video^.CreateImageResource) or not Assigned(Video^.ClearImageResource) or
    not Assigned(Video^.DrawPolyToResource) or not Assigned(Video^.ExecPixelshaderData) or
    not Assigned(Video^.GetImageResourceSize) or not Assigned(Video^.SetSamplerMode) or
    not Assigned(Video^.SetCullingState) then Exit;
  FillChar(Constants, SizeOf(Constants), 0);
  if not Renderer.HostFrame(Progress, Size, Vertices, Constants[0]) or not LoadShader then Exit;
  Constants[1] := Renderer.Appearance;
  Constants[3] := Renderer.PaleMattes;
  Constants[4] := Renderer.ShapeTime(Progress);
  for Side := Low(Side) to High(Side) do Fields[Side] := Renderer.ContourField(Side);
  UseFields := (Fields[isA].Width > 0) and (Fields[isB].Width > 0);
  Constants[5] := Ord(UseFields);
  ResourceCount := 2 + 2 * Ord(UseFields);
  for Side := Low(Side) to High(Side) do
  begin
    if UseFields and not CacheContour(Video, Side, Fields[Side]) then Exit;
    Source[Side] := 'image:' + Paths[Side];
    if (Video^.GetImageResourceSize(PChar(Source[Side]), W, H) = 0) or
      (W <> Images[Side].Width) or (H <> Images[Side].Height) then Exit;
  end;

  Transparent := Default(TPIXEL_RGBA);
  Video^.SetSamplerMode(SamplerClip);
  Video^.SetCullingState(0);
  for Side := Low(Side) to High(Side) do
  begin
    if not WarpResource(Resources[Ord(Side)], PChar(Source[Side]), Side) then Exit;
    if UseFields and not WarpResource(Resources[2 + Ord(Side)], PChar(FContourNames[Side]), Side) then Exit;
  end;
  Video^.SetImageData(nil, Size.cx, Size.cy);
  Result := Video^.ExecPixelshaderData(FShader.GetBufferPointer, Integer(FShader.GetBufferSize),
    'object', @Resources[0], ResourceCount, @Constants[0], SizeOf(Constants), nil, nil) <> 0;
end;

end.
