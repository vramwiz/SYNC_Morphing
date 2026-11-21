
unit Morphing_Renderer;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses System.Types, Morphing_Model, Morphing_Mesh, Morphing_Images;

type
  TSourceImages = array[TImageSide] of TMorphImage;
  THostVertex = record
    X, Y, Z, U, V, Alpha: Single;
  end;
  THostVertices = array[TImageSide] of TArray<THostVertex>;
  TMeshVertex = record
    UV: TUVPair;
    PointIndex: Integer;
    HasParents: Boolean;
    Parents: TTriangle;
    ParentWeights: TUVPair;
  end;
  TMeshVertices = TArray<TMeshVertex>;
  TContourMask = record
    Bounds: TRectF;
    Width, Height: Integer;
    ScaleX, ScaleY: Single;
    Distance: TArray<Single>;
  end;
  TMeshLayer = record
    Region: Integer;
    Vertices: TMeshVertices;
    Triangles, CoarseTriangles: TTriangles;
    CoarseVertexCount: Integer;
    Masks: array[TImageSide] of TContourMask;
    UseSide: array[TImageSide] of Boolean;
    Anchor: TPointF;
    AttachmentIndex: Integer;
    HeadMount: TRectF;
    Companion, HeadwearSilhouette: Boolean;
  end;
  TImageTransform = record
    ScaleX, ScaleY, Cosine, Sine, X, Y: Single;
  end;

  TCurveKnot = record
    At: Single;
    Delta: TPointF;
  end;

  TFrameVertex = record
    Target: TPointF;
    UV: TUVPair;
  end;
  TFrameVertices = TArray<TFrameVertex>;

  TMorphRenderer = class
  strict private type
    TPixelBlend = record
      Color: TPremul;
      Remaining: Single;
    end;
    TPartBacking = record
      Bounds: TRectF;
      Cutout, Fill: TMorphImage;
    end;
  private
    FPartBacking: array[TImageSide] of TPartBacking;
    FHasPartBacking: Boolean;
    FImages, FContourSources, FContourFields: TSourceImages;
    FContourFabric: TUVPair;
    FFieldBounds, FHeadBounds: array[TImageSide] of TRectF;
    FMatteOpaque: array[TImageSide] of Boolean;
    FUseContourFields, FContourPrepared, FMatchSkin, FFullContourBlend: Boolean;
    FModel: TMorphModel;
    FLayers: TArray<TMeshLayer>;
    FFrames: TArray<TFrameVertices>;
    FBuffer: TMorphImage;
    FOverlayBlend: TArray<TPixelBlend>;
    FCoverage: TArray<Word>;
    FReferenceW, FReferenceH: Integer;
    FFullSize: TSize;
    FTransforms: array[TImageSide] of TImageTransform;
    FAdjusted: TPointPath;
    FCurves: TArray<TArray<TCurveKnot>>;
    FUseSavedMesh, FUsesAutoGrid: Boolean;
    FTime, FEased, FColorTime, FAppearance: Single;
    FPaleMattes: Integer;
    function MapToReference(Side: TImageSide; const UV: TPointF; Weight: Single): TPointF;
    function CanvasSize(T: Single): TSize;
    function OneSidedPosition(const Layer: TMeshLayer; const UV: TPointF; Side: TImageSide;
      T, Weight: Single): TPointF;
    function AutomaticPosition(Index: Integer; T: Single): TPointF;
    function KeyedPosition(Index: Integer; T: Single): TPointF;
    procedure SetPartAnchor(var Layer: TMeshLayer; const Outline: TPointPath; const Base: TMeshLayer;
      Side: TImageSide);
    procedure FindHeadBounds;
    procedure BuildLayers;
    procedure BuildCurves;
    procedure PrepareFrameState(Progress: Integer);
    procedure BuildFrame(const Layer: TMeshLayer; Width, Height: Integer; var Frame: TFrameVertices);
    procedure FinishPixel(Offset: Integer; const Color: TPremul);
    procedure BlendOverlay(Offset: Integer; const Color: TPremul; Weight: Single);
    procedure RasterLayer(const Layer: TMeshLayer; const Frame: TFrameVertices; Stamp: Word; FirstY, LastY: Integer);
    procedure RenderRows(FirstY, LastY: Integer);
    function ToCanvas(const P: TPointF): TPointF;
    function FromCanvas(const P: TPointF): TPointF;
    function ContourDistances(Side: TImageSide; const UV: TPointF): TSurfaceDistances; inline;
    function MatteAlpha(Side: TImageSide; const UV: TPointF): Single; inline;
    function BlendFrame(const UA, UB: TPointF; ColorTime: Single): TPremul;
    procedure PrepareContourFields;
    procedure PreparePartBacking;
    function WithPartBacking(const Base: TPremul; const UA, UB: TPointF; ColorTime: Single): TPremul;
  public
    procedure Prepare(const Images: TSourceImages; const Model: TMorphModel; RebuildMasks: Boolean = True);
    function Render(Progress: Integer; PreviewLimit: Integer = 0): TMorphImage;
    function HostFrame(Progress: Integer; out Size: TSize; out Vertices: THostVertices;
      out Blend: Single): Boolean;
    function ContourField(Side: TImageSide): TMorphImage;
    function ShapeTime(Progress: Integer): Single;
    function Mesh(Region: Integer): TMeshLayer;
    function SavedMesh: TSavedMesh;
    function PreviewVertex(Index, Progress: Integer; out UV: TPointF): Boolean;
    function PreviewMesh(Region, Progress: Integer; out Positions: TPointPath): TMeshLayer;
    function PreviewCorrection(const UV: TPointF; Progress: Integer): TPointF;
    property Appearance: Single read FAppearance;
    property PaleMattes: Integer read FPaleMattes;
  end;

implementation

uses System.Math, System.SysUtils, System.Classes, System.Generics.Collections, System.Generics.Defaults,
  System.Threading, AviUtl2FilterTypes;

const
  // Each pixel stores the last layer stamp and whether its blend accumulator is initialized.
  HasOverlayBlend = $8000;
  LayerStampMask = $7FFF;
  FinishedPixel = High(Word);
  TriangleEdgeTolerance = 1E-6;
  HeadwearContourMargin = 0.012;

function Linear(A, B, T: Single): Single; inline;
begin
  Result := A + (B - A) * T;
end;

function RegistrationWeight(T: Single): Single;
begin
  Result := SmoothStep(Min(1.0, Min(T, 1 - T) * 10));
end;

function ImageTransform(const Image: TMorphImage; RefW, RefH: Integer;
  const Align: TMorphAlignment; Weight: Single): TImageTransform;
var
  A, S: Single;
begin
  A := DegToRad(Align.Angle * Weight);
  S := Linear(1, Align.Scale, Weight);
  Result.ScaleX := S * Max(1, Image.Width) / RefW;
  Result.ScaleY := S * Max(1, Image.Height) / RefH;
  Result.Cosine := Cos(A);
  Result.Sine := Sin(A);
  Result.X := 0.5 + Align.X * Weight;
  Result.Y := 0.5 + Align.Y * Weight;
end;

function MapUV(const T: TImageTransform; const P: TPointF; RefAspect: Single): TPointF; inline;
var
  X, Y: Single;
begin
  X := (P.X - 0.5) * T.ScaleX;
  Y := (P.Y - 0.5) * T.ScaleY;
  Result := PointF(T.X + T.Cosine * X - T.Sine * Y / RefAspect,
    T.Y + T.Sine * X * RefAspect + T.Cosine * Y);
end;

function UnmapUV(const T: TImageTransform; const P: TPointF; RefAspect: Single): TPointF; inline;
var
  X, Y: Single;
begin
  X := P.X - T.X;
  Y := P.Y - T.Y;
  Result := PointF(0.5 + (T.Cosine * X + T.Sine * Y / RefAspect) / T.ScaleX,
    0.5 + (-T.Sine * X * RefAspect + T.Cosine * Y) / T.ScaleY);
end;

function TMorphRenderer.MapToReference(Side: TImageSide; const UV: TPointF; Weight: Single): TPointF;
begin
  Result := MapUV(ImageTransform(FImages[Side], FReferenceW, FReferenceH, FModel.Align[Side], Weight),
    UV, FReferenceW / FReferenceH);
end;

function OutlineBounds(const Outline: TPointPath): TRectF;
var
  P: TPointF;
begin
  P := Outline[0];
  Result := RectF(P.X, P.Y, P.X, P.Y);
  for P in Outline do
  begin
    Result.Left := Min(Result.Left, P.X);
    Result.Right := Max(Result.Right, P.X);
    Result.Top := Min(Result.Top, P.Y);
    Result.Bottom := Max(Result.Bottom, P.Y);
  end;
end;

function MakeMask(const Path: TPointPath; Padding: Single): TContourMask;
var
  P: TPointF;
  X, Y: Integer;
  W, H: Single;
begin
  Result := Default(TContourMask);
  if Length(Path) < 3 then Exit;
  Result.Bounds := OutlineBounds(Path);
  Result.Bounds.Inflate(Padding, Padding);
  W := Result.Bounds.Width;
  H := Result.Bounds.Height;
  Result.Width := Max(8, Round(144 * W / Max(W, H)));
  Result.Height := Max(8, Round(144 * H / Max(W, H)));
  Result.ScaleX := (Result.Width - 1) / W;
  Result.ScaleY := (Result.Height - 1) / H;
  SetLength(Result.Distance, Result.Width * Result.Height);
  for Y := 0 to Result.Height - 1 do
  begin
    P.Y := Result.Bounds.Top + H * Y / (Result.Height - 1);
    for X := 0 to Result.Width - 1 do
    begin
      P.X := Result.Bounds.Left + W * X / (Result.Width - 1);
      Result.Distance[Y * Result.Width + X] := OutlineDistance(Path, P);
    end;
  end;
end;

function SampleMask(const Mask: TContourMask; const UV: TPointF): Single;
var
  X, Y, A, B: Single;
  I, J, I2, Top, Bottom: Integer;
begin
  if (Mask.Width = 0) or (UV.X < Mask.Bounds.Left) or (UV.X > Mask.Bounds.Right) or
    (UV.Y < Mask.Bounds.Top) or (UV.Y > Mask.Bounds.Bottom) then Exit(-1);
  X := Min((UV.X - Mask.Bounds.Left) * Mask.ScaleX, Mask.Width - 1);
  Y := Min((UV.Y - Mask.Bounds.Top) * Mask.ScaleY, Mask.Height - 1);
  I := Trunc(X);
  J := Trunc(Y);
  I2 := Min(I + 1, Mask.Width - 1);
  Top := J * Mask.Width;
  Bottom := Min(J + 1, Mask.Height - 1) * Mask.Width;
  A := Linear(Mask.Distance[Top + I], Mask.Distance[Top + I2], X - I);
  B := Linear(Mask.Distance[Bottom + I], Mask.Distance[Bottom + I2], X - I);
  Result := Linear(A, B, Y - J);
end;

function Corner(const R: TRectF; I: Integer): TPointF;
begin
  case I of
    0: Result := R.TopLeft;
    1: Result := PointF(R.Right, R.Top);
    2: Result := R.BottomRight;
  else
    Result := PointF(R.Left, R.Bottom);
  end;
end;


function BuildAutoGrid(var Layer: TMeshLayer): Boolean;
const
  EdgeMargin = 0.006;
var
  I, J, Count, Columns, Rows, NearRow, FarRow, EdgeCount, LeftCount, Stride, Next: Integer;
  Side: TImageSide;
  Edge: TMeshVertex;
  Triangle: TTriangle;
  X, Y: Single;
  GuardCanvas: Boolean;

  function ValidRows(ColumnCount: Integer): Boolean;
  var
    Row, Col, K: Integer;
    S: TImageSide;
    UV: TPointF;
  begin
    if (Count < 4 + ColumnCount * 2) or ((Count - 4) mod ColumnCount <> 0) then Exit(False);
    for Row := 0 to (Count - 4) div ColumnCount - 1 do
      for Col := 0 to ColumnCount - 1 do
      begin
        K := 4 + Row * ColumnCount + Col;
        for S := Low(S) to High(S) do
        begin
          UV := Layer.Vertices[K].UV[S];
          if (UV.X <= Layer.Vertices[0].UV[S].X) or (UV.X >= Layer.Vertices[1].UV[S].X) or
            (UV.Y <= Layer.Vertices[0].UV[S].Y) or (UV.Y >= Layer.Vertices[2].UV[S].Y) then Exit(False);
          if (Col > 0) and (UV.X <= Layer.Vertices[K - 1].UV[S].X) then Exit(False);
          if (Row > 0) and (UV.Y <= Layer.Vertices[K - ColumnCount].UV[S].Y) then Exit(False);
        end;
      end;
    Result := True;
  end;

  procedure Add(A, B, C: Integer);
  begin
    Layer.Triangles[Next].A := A;
    Layer.Triangles[Next].B := B;
    Layer.Triangles[Next].C := C;
    Inc(Next);
  end;

  function At(Row, Column: Integer): Integer;
  begin
    if Column < LeftCount then Exit(Count + Row * EdgeCount + Column);
    if Column >= LeftCount + Columns then Exit(Count + Row * EdgeCount + Column - Columns);
    Result := 4 + Row * Columns + Column - LeftCount;
  end;

begin
  Result := False;
  Count := Length(Layer.Vertices);
  if ValidRows(5) then Columns := 5
  else if ValidRows(9) then Columns := 9
  else Exit;
  Rows := (Count - 4) div Columns;
  GuardCanvas := True;
  for I := 0 to Rows - 1 do
    for Side := Low(Side) to High(Side) do
      if (Layer.Vertices[4 + I * Columns].UV[Side].X <= EdgeMargin) or
        (Layer.Vertices[3 + (I + 1) * Columns].UV[Side].X >= 1 - EdgeMargin) then GuardCanvas := False;

  // The margins are anchored to the edges of each input. Edited rows can bend.
  EdgeCount := 2 + 2 * Ord(GuardCanvas);
  LeftCount := EdgeCount div 2;
  Stride := Columns + EdgeCount;
  Edge := Default(TMeshVertex);
  Edge.PointIndex := -1;
  SetLength(Layer.Vertices, Count + Rows * EdgeCount);
  for I := 0 to Rows - 1 do
    for J := 0 to EdgeCount - 1 do
    begin
      for Side := Low(Side) to High(Side) do
      begin
        if J = 0 then X := Layer.Vertices[0].UV[Side].X
        else if J = EdgeCount - 1 then X := Layer.Vertices[1].UV[Side].X
        else if J = 1 then X := EdgeMargin
        else X := 1 - EdgeMargin;
        if J < LeftCount then Y := Layer.Vertices[4 + I * Columns].UV[Side].Y
        else Y := Layer.Vertices[3 + (I + 1) * Columns].UV[Side].Y;
        Edge.UV[Side] := PointF(X, Y);
      end;
      Layer.Vertices[Count + I * EdgeCount + J] := Edge;
    end;
  SetLength(Layer.Triangles, 2 * Rows * (Stride - 1) + 2);
  Next := 0;
  Add(0, 1, At(0, Stride - 1));
  for J := Stride - 1 downto 1 do Add(0, At(0, J), At(0, J - 1));
  for I := 1 to Rows - 1 do
    for J := 0 to Stride - 2 do
    begin
      NearRow := At(I - 1, J);
      FarRow := At(I, J + 1);
      Add(NearRow, At(I - 1, J + 1), FarRow);
      Add(NearRow, FarRow, At(I, J));
    end;
  Add(At(Rows - 1, 0), 2, 3);
  for J := 0 to Stride - 2 do Add(At(Rows - 1, J), At(Rows - 1, J + 1), 2);

  for Triangle in Layer.Triangles do
    for Side := Low(Side) to High(Side) do
      if Cross(Layer.Vertices[Triangle.A].UV[Side], Layer.Vertices[Triangle.B].UV[Side],
        Layer.Vertices[Triangle.C].UV[Side]) <= 1E-9 then
      begin
        // A folded grid is still renderable through the ordinary mesh path.
        SetLength(Layer.Vertices, Count);
        Layer.Triangles := nil;
        Exit;
      end;
  Result := True;
end;

procedure ApplyRefinement(var Layer: TMeshLayer; const Refinement: TMeshRefinement);
var
  Index, NewIndex, NextTriangle: Integer;
  Triangle: TTriangle;
  Pair: TMeshDetail;
  DetailIndices: TArray<Integer>;
  Vertex: TMeshVertex;
  Side: TImageSide;

  procedure Add(A, B, C: Integer);
  begin
    Layer.Triangles[NextTriangle].A := A;
    Layer.Triangles[NextTriangle].B := B;
    Layer.Triangles[NextTriangle].C := C;
    Inc(NextTriangle);
  end;

begin
  if (Length(Refinement.Details) = 0) or (Length(Refinement.Details) > MORPH_MAX_DETAILS) or
    (Refinement.VertexCount <> Length(Layer.Vertices)) or
    (Refinement.TriangleCount <> Length(Layer.Triangles)) then Exit;

  SetLength(DetailIndices, Length(Layer.Triangles));
  for Index := 0 to High(DetailIndices) do DetailIndices[Index] := -1;
  for Pair in Refinement.Details do
  begin
    Index := Pair.TriangleIndex;
    if (Index < 0) or (Index > High(DetailIndices)) or (DetailIndices[Index] >= 0) then Continue;
    Triangle := Layer.Triangles[Index];
    if (Layer.Vertices[Triangle.A].PointIndex < 0) or (Layer.Vertices[Triangle.B].PointIndex < 0) or
      (Layer.Vertices[Triangle.C].PointIndex < 0) then Continue;
    if Layer.CoarseVertexCount = 0 then Layer.CoarseVertexCount := Length(Layer.Vertices);
    Vertex := Default(TMeshVertex);
    Vertex.PointIndex := -1;
    Vertex.HasParents := True;
    Vertex.Parents := Triangle;
    Vertex.ParentWeights := Pair.Weights;
    for Side := Low(Side) to High(Side) do
      Vertex.UV[Side] := BarycentricPoint(Layer.Vertices[Triangle.A].UV[Side],
        Layer.Vertices[Triangle.B].UV[Side], Layer.Vertices[Triangle.C].UV[Side], Pair.Weights[Side]);
    DetailIndices[Index] := Length(Layer.Vertices);
    Layer.Vertices := Layer.Vertices + [Vertex];
  end;
  if Layer.CoarseVertexCount = 0 then Exit;

  Layer.CoarseTriangles := Layer.Triangles;
  Layer.Triangles := nil;
  SetLength(Layer.Triangles, Length(Layer.CoarseTriangles) +
    2 * (Length(Layer.Vertices) - Layer.CoarseVertexCount));
  NextTriangle := 0;
  for Index := 0 to High(Layer.CoarseTriangles) do
  begin
    Triangle := Layer.CoarseTriangles[Index];
    NewIndex := DetailIndices[Index];
    if NewIndex < 0 then Add(Triangle.A, Triangle.B, Triangle.C)
    else
    begin
      Add(Triangle.A, Triangle.B, NewIndex);
      Add(Triangle.B, Triangle.C, NewIndex);
      Add(Triangle.C, Triangle.A, NewIndex);
    end;
  end;
end;

procedure TMorphRenderer.SetPartAnchor(var Layer: TMeshLayer; const Outline: TPointPath;
  const Base: TMeshLayer; Side: TImageSide);
var
  Vertex: TMeshVertex;
  P, A, D, Q: TPointF;
  Size: TPointF;
  I: Integer;
  Limit, Distance, Fraction, LengthSquared: Single;
begin
  Size := PointF(Max(1, FImages[Side].Width), Max(1, FImages[Side].Height));
  Layer.Anchor := Layer.Masks[Side].Bounds.CenterPoint;
  Layer.AttachmentIndex := -1;
  Limit := Sqr(0.05 * Min(Size.X, Size.Y));
  // Use the closest part of the contour to a paired control as the attachment.
  for Vertex in Base.Vertices do
  begin
    if Vertex.PointIndex < 0 then Continue;
    P := PointF(Vertex.UV[Side].X * Size.X, Vertex.UV[Side].Y * Size.Y);
    for I := 0 to High(Outline) do
    begin
      A := Outline[I];
      D := Outline[(I + 1) mod Length(Outline)] - A;
      Q := P - PointF(A.X * Size.X, A.Y * Size.Y);
      D := PointF(D.X * Size.X, D.Y * Size.Y);
      LengthSquared := Sqr(D.X) + Sqr(D.Y);
      if LengthSquared <= 1E-9 then Continue;
      Fraction := EnsureRange((Q.X * D.X + Q.Y * D.Y) / LengthSquared, 0, 1);
      Distance := Sqr(Q.X - Fraction * D.X) + Sqr(Q.Y - Fraction * D.Y);
      if Distance >= Limit then Continue;
      Limit := Distance;
      Layer.AttachmentIndex := Vertex.PointIndex;
      Layer.Anchor := A + PointF(Fraction * D.X / Size.X, Fraction * D.Y / Size.Y);
    end;
  end;
end;

function TransparentBackdrop(const Image: TMorphImage): Boolean;
begin
  Result := (Image.Width > 0) and (SampleAlpha(Image, PointF(0, 0)) < 0.02) and
    (SampleAlpha(Image, PointF(1, 0)) < 0.02) and (SampleAlpha(Image, PointF(0, 1)) < 0.02) and
    (SampleAlpha(Image, PointF(1, 1)) < 0.02);
end;

function IsHeadwearDecoration(const Name: string): Boolean;
var
  LabelText: string;
begin
  LabelText := LowerCase(Name);
  Result := (Pos('飾', LabelText) > 0) or (Pos('ブローチ', LabelText) > 0) or
    (Pos('badge', LabelText) > 0) or (Pos('emblem', LabelText) > 0) or
    (Pos('ornament', LabelText) > 0) or (Pos('decoration', LabelText) > 0);
end;

function IsCrest(const Name: string): Boolean;
begin
  Result := (Pos('とさか', Name) > 0) or (Pos('鶏冠', Name) > 0) or
    (Pos('crest', LowerCase(Name)) > 0);
end;

function IsHeadwear(const Name: string): Boolean;
var
  LabelText: string;
begin
  LabelText := ' ' + LowerCase(Name) + ' ';
  Result := not IsHeadwearDecoration(Name) and
    ((Pos('帽子', LabelText) > 0) or (Pos('ヘルメット', LabelText) > 0) or
     (Pos('王冠', LabelText) > 0) or (Pos(' hat', LabelText) > 0) or
     (Pos(' cap ', LabelText) > 0) or (Pos(' helmet', LabelText) > 0) or
     (Pos(' crown', LabelText) > 0));
end;

procedure TMorphRenderer.FindHeadBounds;
var
  R: TMorphRegion;
  Side: TImageSide;
  Bounds: array[TImageSide] of TRectF;
  Measure, Best: Single;

  function IsFace(const Name: string): Boolean;
  begin
    Result := (Pos('顔', Name) > 0) or (Pos('face', LowerCase(Name)) > 0) or
      (Pos('頭部', Name) > 0);
  end;

begin
  FHeadBounds[isA] := TRectF.Empty;
  FHeadBounds[isB] := TRectF.Empty;
  Best := 0;
  for R in FModel.Regions do
  begin
    if not R.Enabled or (R.State <> rsMatch) or
      not (IsFace(R.Name[isA]) and IsFace(R.Name[isB])) or
      (Length(R.Contour[isA]) < 3) or (Length(R.Contour[isB]) < 3) then Continue;
    for Side := Low(Side) to High(Side) do Bounds[Side] := OutlineBounds(R.Contour[Side]);
    Measure := Min(Bounds[isA].Width * Bounds[isA].Height, Bounds[isB].Width * Bounds[isB].Height);
    if Measure <= Best then Continue;
    Best := Measure;
    FHeadBounds[isA] := Bounds[isA];
    FHeadBounds[isB] := Bounds[isB];
  end;
end;

procedure TMorphRenderer.BuildLayers;
var
  Layers: TList<TMeshLayer>;
  Layer, Parent: TMeshLayer;
  R: TMorphRegion;
  I, J, FirstOverlay: Integer;
  Side, Other: TImageSide;
  Grid, GridReady, HasHead: Boolean;

  procedure Build(var L: TMeshLayer);
  var
    P: TMorphPoint;
    Vertex: TMeshVertex;
    AB: TPointPath;
    K: Integer;
    Side, Other: TImageSide;
    A, B: TPointF;
    Topology: TMeshTopology;
  begin
    SetLength(L.Vertices, 4);
    for K := 0 to 3 do
    begin
      if (L.Region < 0) or L.Companion then L.Vertices[K].PointIndex := -1
      else L.Vertices[K].PointIndex := RegionCornerID(L.Region, K);
      for Side := Low(Side) to High(Side) do
        if L.Region < 0 then
          L.Vertices[K].UV[Side] := UnmapUV(
            ImageTransform(FImages[Side], FReferenceW, FReferenceH, FModel.Align[Side], 0),
            Corner(RectF(0, 0, 1, 1), K), FReferenceW / FReferenceH)
        else if L.UseSide[Side] then
          L.Vertices[K].UV[Side] := Corner(L.Masks[Side].Bounds, K);
      if not L.UseSide[isA] then L.Vertices[K].UV[isA] := L.Vertices[K].UV[isB];
      if not L.UseSide[isB] then L.Vertices[K].UV[isB] := L.Vertices[K].UV[isA];
    end;
    Vertex := Default(TMeshVertex);
    for K := 0 to High(FModel.Points) do
    begin
      if L.Companion then Break;
      P := FModel.Points[K];
      if L.Region < 0 then
      begin
        if not (P.Has[isA] and P.Has[isB]) then Continue;
        if P.Region >= 0 then
          if not FModel.Regions[P.Region].Enabled or (FModel.Regions[P.Region].State <> rsMatch) then Continue;
      end
      else
      begin
        if P.Region <> L.Region then Continue;
        if (L.UseSide[isA] and not P.Has[isA]) or (L.UseSide[isB] and not P.Has[isB]) then Continue;
      end;
      Vertex.PointIndex := K;
      Vertex.UV := P.UV;
      for Side := Low(Side) to High(Side) do
        if not L.UseSide[Side] then
        begin
          Other := TImageSide(1 - Ord(Side));
          Vertex.UV[Side] := Vertex.UV[Other];
        end;
      L.Vertices := L.Vertices + [Vertex];
    end;
    if (L.Region < 0) and Grid then
    begin
      GridReady := BuildAutoGrid(L);
      if GridReady then
      begin
        ApplyRefinement(L, FModel.Refinement);
        Exit;
      end;
    end;
    if FUseSavedMesh and not L.Companion then
      for Topology in FModel.Mesh.Layers do
        if (Topology.Region = L.Region) and (Topology.VertexCount = Length(L.Vertices)) and
          (Length(Topology.Triangles) > 0) then
        begin
          L.Triangles := Topology.Triangles;
          Exit;
        end;
    SetLength(AB, Length(L.Vertices));
    for K := 0 to High(L.Vertices) do
    begin
      Vertex := L.Vertices[K];
      A := MapToReference(isA, Vertex.UV[isA], 0);
      B := MapToReference(isB, Vertex.UV[isB], 0);
      if not L.UseSide[isA] then A := B;
      if not L.UseSide[isB] then B := A;
      AB[K] := MixPoint(A, B, 0.5);
    end;
    L.Triangles := Triangulate(AB);
  end;

  procedure AddLayer(Region: Integer; const R: TMorphRegion; OnlySide: Integer; Companion: Boolean);
  var
    L: TMeshLayer;
    Side: TImageSide;
    Pad: Single;
    Old: TMeshLayer;
    WornOnHead: array[TImageSide] of Boolean;
  begin
    L := Default(TMeshLayer);
    L.Region := Region;
    L.Companion := Companion;
    for Side := Low(Side) to High(Side) do
    begin
      WornOnHead[Side] := HasHead and (IsHeadwear(R.Name[Side]) or IsCrest(R.Name[Side]) or Companion);
      if (OnlySide >= 0) and (Ord(Side) <> OnlySide) then Continue;
      if ((Side = isA) and (R.State = rsAppear)) or ((Side = isB) and (R.State = rsDisappear)) then Continue;
      if Length(R.Contour[Side]) < 3 then Continue;
      L.UseSide[Side] := True;
      Pad := Max(0.004, (2 + FModel.Feather) / Max(1, Min(FImages[Side].Width, FImages[Side].Height)));
      if WornOnHead[Side] and TransparentBackdrop(FImages[Side]) then
        Pad := Max(Pad, 2 * HeadwearContourMargin);
      for Old in FLayers do
        if (Old.Region = Region) and (Old.Masks[Side].Width > 0) then
        begin
          L.Masks[Side] := Old.Masks[Side];
          Break;
        end;
      if L.Masks[Side].Width = 0 then L.Masks[Side] := MakeMask(R.Contour[Side], Min(Pad, 2));
    end;
    if (R.State = rsMatch) and not (L.UseSide[isA] and L.UseSide[isB]) then Exit;
    if not (L.UseSide[isA] or L.UseSide[isB]) then Exit;
    Build(L);
    if L.UseSide[isA] xor L.UseSide[isB] then
    begin
      Side := TImageSide(Ord(L.UseSide[isB]));
      if WornOnHead[Side] then
      begin
        L.HeadMount := OutlineBounds(R.Contour[Side]);
        L.HeadwearSilhouette := not L.HeadMount.IsEmpty and TransparentBackdrop(FImages[Side]);
      end;
      if L.HeadMount.IsEmpty then SetPartAnchor(L, R.Contour[Side], Layers[0], Side);
    end;
    Layers.Add(L);
  end;

begin
  FindHeadBounds;
  HasHead := not (FHeadBounds[isA].IsEmpty or FHeadBounds[isB].IsEmpty);
  Grid := Length(FModel.Regions) > 0;
  for R in FModel.Regions do Grid := Grid and R.AutoGrid and R.Enabled and (R.State = rsMatch);
  GridReady := False;
  Layers := TList<TMeshLayer>.Create;
  try
    Layer := Default(TMeshLayer);
    Layer.Region := -1;
    Layer.UseSide[isA] := True;
    Layer.UseSide[isB] := True;
    Build(Layer);
    Layers.Add(Layer);
    FirstOverlay := 0;
    if GridReady then FirstOverlay := Length(FModel.Regions);
    for I := FirstOverlay to High(FModel.Regions) do
    begin
      R := FModel.Regions[I];
      if not R.Enabled or (R.State = rsExcluded) then Continue;
      if R.State <> rsUnknown then
      begin
        AddLayer(I, R, -1, False);
        Continue;
      end;
      if not HasHead or not (IsHeadwear(R.Name[isA]) xor IsHeadwear(R.Name[isB])) then Continue;
      Side := TImageSide(Ord(IsHeadwear(R.Name[isB])));
      if Length(R.Contour[Side]) < 3 then Continue;
      AddLayer(I, R, Ord(Side), False);
      Other := TImageSide(1 - Ord(Side));
      // Only a nearby head contour can become the disappearing counterpart.
      if Length(R.Contour[Other]) >= 3 then
        if OutlineDistance(R.Contour[Other], PointF(FHeadBounds[Other].CenterPoint.X,
          FHeadBounds[Other].Top)) >= -FHeadBounds[Other].Height * 0.18 then
          AddLayer(I, R, Ord(Other), True);
    end;
    Layers.Sort(TComparer<TMeshLayer>.Construct(
      function(const Left, Right: TMeshLayer): Integer
      begin
        if (Left.Region < 0) or (Right.Region < 0) then Exit(Left.Region - Right.Region);
        Result := FModel.Regions[Left.Region].Z - FModel.Regions[Right.Region].Z;
        if Result = 0 then Result := Left.Region - Right.Region;
        if Result = 0 then Result := Ord(Right.Companion) - Ord(Left.Companion);
      end));
    FLayers := Layers.ToArray;
    for I := 1 to High(FLayers) do
    begin
      Layer := FLayers[I];
      if not (Layer.UseSide[isA] xor Layer.UseSide[isB]) then Continue;
      Side := TImageSide(Ord(Layer.UseSide[isB]));
      if not IsHeadwearDecoration(FModel.Regions[Layer.Region].Name[Side]) then Continue;
      for J := High(FLayers) downto 1 do
      begin
        Parent := FLayers[J];
        if Parent.Companion or not Parent.UseSide[Side] or Parent.HeadMount.IsEmpty or
          not IsHeadwear(FModel.Regions[Parent.Region].Name[Side]) then Continue;
        if not ContainsPoint(FModel.Regions[Parent.Region].Contour[Side],
          Layer.Masks[Side].Bounds.CenterPoint) then Continue;
        FLayers[I].HeadMount := Parent.HeadMount;
        Break;
      end;
    end;
    FUsesAutoGrid := GridReady;
    FAppearance := 0;
    // Paired mesh points define a warp regardless of how the points were entered.
    if Length(FLayers[0].Vertices) > 4 then FAppearance := FModel.Shape
    else
      for I := 1 to High(FLayers) do
        if FLayers[I].UseSide[isA] and FLayers[I].UseSide[isB] then
        begin
          FAppearance := FModel.Shape;
          Break;
        end;
  finally
    Layers.Free;
  end;
end;

function HasPaleMatte(const Image: TMorphImage): Boolean;
var
  I, X, Y, Count: Integer;

  function Pale(Col, Row: Integer): Integer;
  begin
    var P := Image.Pixels[Row * Image.Width + Col];
    Result := Ord((P.A >= 247) and (P.R >= 239) and (P.G >= 239) and (P.B >= 239));
  end;

begin
  if Length(Image.Pixels) = 0 then Exit(False);
  Count := 0;
  // A single translucent or discolored corner does not invalidate an otherwise pale matte.
  for I := 1 to 8 do
  begin
    X := I * (Image.Width - 1) div 9;
    Y := I * (Image.Height - 1) div 9;
    Inc(Count, Pale(X, 0) + Pale(X, Image.Height - 1) +
      Pale(0, Y) + Pale(Image.Width - 1, Y));
  end;
  Result := Count >= 24;
end;

procedure TMorphRenderer.PrepareContourFields;
var
  Side: TImageSide;
  MatchSkin: Boolean;
  Region: TMorphRegion;

  function Opaque(const Image: TMorphImage): Boolean;
  var
    I: Integer;
  begin
    for I := 0 to High(Image.Pixels) do
      if Image.Pixels[I].A <> 255 then Exit(False);
    Result := True;
  end;

  function FieldBounds(const Field: TMorphImage): TRectF;
  var
    X, Y, I, L, T, R, B: Integer;
  begin
    if Field.Width = 0 then Exit(TRectF.Empty);
    L := Field.Width;
    T := Field.Height;
    R := -1;
    B := -1;
    I := 0;
    for Y := 0 to Field.Height - 1 do
      for X := 0 to Field.Width - 1 do
      begin
        if Field.Pixels[I].R > 0 then
        begin
          L := Min(L, X);
          T := Min(T, Y);
          R := Max(R, X);
          B := Max(B, Y);
        end;
        Inc(I);
      end;
    // Include the support of bilinear samples taken next to the last nonzero texel.
    Result := RectF((L - 0.5) / Field.Width, (T - 0.5) / Field.Height,
      (R + 1.5) / Field.Width, (B + 1.5) / Field.Height);
  end;

begin
  MatchSkin := (Pos('目・口', FModel.Subject[isA]) > 0) and (Pos('目・口', FModel.Subject[isB]) > 0);
  if not MatchSkin then
    for Region in FModel.Regions do
      if Region.Enabled and (Region.State = rsMatch) and
        (Pos('顔', Region.Name[isA]) > 0) and (Pos('顔', Region.Name[isB]) > 0) then
      begin
        MatchSkin := True;
        Break;
      end;
  if (MatchSkin <> FMatchSkin) or (FContourFabric[isA] <> FModel.FabricY[isA]) or
    (FContourFabric[isB] <> FModel.FabricY[isB]) or
    (Pointer(FContourSources[isA].Pixels) <> Pointer(FImages[isA].Pixels)) or
    (Pointer(FContourSources[isB].Pixels) <> Pointer(FImages[isB].Pixels)) then
  begin
    FMatchSkin := MatchSkin;
    FContourSources := FImages;
    FContourFabric := FModel.FabricY;
    FContourFields := Default(TSourceImages);
    FContourPrepared := False;
  end;
  if (FAppearance > 0) and not FContourPrepared then
  begin
    FPaleMattes := 0;
    for Side := Low(Side) to High(Side) do
    begin
      var Pale := HasPaleMatte(FImages[Side]);
      if Pale then FPaleMattes := FPaleMattes or (1 shl Ord(Side));
      FMatteOpaque[Side] := Pale and Opaque(FImages[Side]);
      FContourFields[Side] := BuildSilhouetteField(FImages[Side], Pale, FMatchSkin,
        FContourFabric[Side].X, FContourFabric[Side].Y);
      FFieldBounds[Side] := FieldBounds(FContourFields[Side]);
    end;
    FContourPrepared := True;
  end;
  FUseContourFields := (FAppearance > 0) and
    (FContourFields[isA].Width > 0) and (FContourFields[isB].Width > 0);
end;

function TMorphRenderer.ContourField(Side: TImageSide): TMorphImage;
begin
  if FUseContourFields then Result := FContourFields[Side] else Result := Default(TMorphImage);
end;

function TMorphRenderer.ShapeTime(Progress: Integer): Single;
begin
  Result := EnsureRange(Progress, 0, 10000) / 10000;
  if FModel.Smooth then Result := SmoothStep(Result);
end;

procedure TMorphRenderer.PreparePartBacking;
const
  BackingLimit = 1024;
var
  Layer: TMeshLayer;
  Mark: TContourMask;
  Side: TImageSide;
  Backing: ^TPartBacking;
  Scale, EdgeScale, Weight, Exterior, MaskBias, Margin: Single;
  X, Y, X0, Y0, X1, Y1, W, H, Index, Cut: Integer;
  UV: TPointF;

  procedure FillCutout(var Data: TPartBacking; const Source: TMorphImage);
  var
    Seed, Queue: TArray<Integer>;
    W, H, Count, I, X, Y, Head, Tail: Integer;
    Background, Color: TPremul;
    HasBackground: Boolean;

    procedure Visit(At, From: Integer);
    begin
      if Seed[At] <> 0 then Exit;
      Seed[At] := From;
      Queue[Tail] := At;
      Inc(Tail);
    end;

  begin
    W := Data.Cutout.Width;
    H := Data.Cutout.Height;
    Count := W * H;
    SetLength(Seed, Count);
    SetLength(Queue, Count);
    for I := 0 to Count - 1 do
      if Data.Cutout.Pixels[I].A = 0 then Seed[I] := I + 1;
    Head := 0;
    Tail := 0;
    for I := 0 to Count - 1 do
    begin
      if Data.Cutout.Pixels[I].A <> 0 then Continue;
      X := I mod W;
      if X > 0 then Visit(I - 1, I + 1);
      if X + 1 < W then Visit(I + 1, I + 1);
      if I >= W then Visit(I - W, I + 1);
      if I + W < Count then Visit(I + W, I + 1);
    end;
    // Extend the nearest visible pixel under the removed region for doubly hidden areas.
    while Head < Tail do
    begin
      I := Queue[Head];
      Inc(Head);
      X := I mod W;
      if X > 0 then Visit(I - 1, Seed[I]);
      if X + 1 < W then Visit(I + 1, Seed[I]);
      if I >= W then Visit(I - W, Seed[I]);
      if I + W < Count then Visit(I + W, Seed[I]);
    end;
    Background := Default(TPremul);
    HasBackground := HasPaleMatte(Source);
    if HasBackground then
    begin
      Background.R := 253;
      Background.G := 253;
      Background.B := 253;
      Background.A := 1;
    end
    else HasBackground := TransparentBackdrop(Source);
    Data.Fill.Width := W;
    Data.Fill.Height := H;
    SetLength(Data.Fill.Pixels, Count);
    for I := 0 to Count - 1 do
      if Seed[I] > 0 then
      begin
        X := (Seed[I] - 1) mod W;
        Y := (Seed[I] - 1) div W;
        Color := Sample(Source, PointF((X + 0.5) / W, (Y + 0.5) / H));
        if HasBackground and (Data.Cutout.Pixels[I].R <> 0) then
          Color := MixColor(Color, Background, Data.Cutout.Pixels[I].R * (1 / 255));
        Data.Fill.Pixels[I] := Pixel(Color);
      end;
  end;

begin
  for Side := Low(Side) to High(Side) do FPartBacking[Side] := Default(TPartBacking);
  FHasPartBacking := False;
  for Layer in FLayers do
  begin
    if not (Layer.UseSide[isA] xor Layer.UseSide[isB]) or (Length(Layer.Triangles) = 0) then Continue;
    Side := TImageSide(Ord(Layer.UseSide[isB]));
    if FImages[Side].Width = 0 then Continue;
    Backing := @FPartBacking[Side];
    Mark := Layer.Masks[Side];
    if Backing.Cutout.Width = 0 then
    begin
      Scale := Min(1.0, BackingLimit / Max(FImages[Side].Width, FImages[Side].Height));
      Backing.Cutout.Width := Max(1, Round(FImages[Side].Width * Scale));
      Backing.Cutout.Height := Max(1, Round(FImages[Side].Height * Scale));
      SetLength(Backing.Cutout.Pixels, Backing.Cutout.Width * Backing.Cutout.Height);
      Backing.Bounds := Mark.Bounds;
    end
    else
    begin
      Backing.Bounds.Left := Min(Backing.Bounds.Left, Mark.Bounds.Left);
      Backing.Bounds.Top := Min(Backing.Bounds.Top, Mark.Bounds.Top);
      Backing.Bounds.Right := Max(Backing.Bounds.Right, Mark.Bounds.Right);
      Backing.Bounds.Bottom := Max(Backing.Bounds.Bottom, Mark.Bounds.Bottom);
    end;
    W := Backing.Cutout.Width;
    H := Backing.Cutout.Height;
    EdgeScale := Max(1, Min(FImages[Side].Width, FImages[Side].Height)) / 2;
    MaskBias := 1;
    if not Layer.HeadMount.IsEmpty then MaskBias := 2;
    X0 := Max(0, Floor(Mark.Bounds.Left * W));
    X1 := Min(W - 1, Ceil(Mark.Bounds.Right * W));
    Y0 := Max(0, Floor(Mark.Bounds.Top * H));
    Y1 := Min(H - 1, Ceil(Mark.Bounds.Bottom * H));
    for Y := Y0 to Y1 do
    begin
      UV.Y := (Y + 0.5) / H;
      Exterior := 0;
      // Above the head, the visible backing of a sprite is its background.
      if not Layer.HeadMount.IsEmpty then
        Exterior := SmoothStep(EnsureRange((FHeadBounds[Side].Top - UV.Y) * H / 3, 0, 1));
      Margin := 0;
      if Layer.HeadwearSilhouette then
        Margin := EnsureRange(FHeadBounds[Side].Top - UV.Y, 0, HeadwearContourMargin);
      Index := Y * W + X0;
      for X := X0 to X1 do
      begin
        UV.X := (X + 0.5) / W;
        // Include the original antialiased fringe so it cannot remain at the old position.
        Weight := SmoothStep(EnsureRange(MaskBias + (SampleMask(Mark, UV) + Margin) * EdgeScale, 0, 1));
        Cut := Round(Weight * 255);
        Backing.Cutout.Pixels[Index].A := Max(Backing.Cutout.Pixels[Index].A, Cut);
        if Exterior > 0 then
          Backing.Cutout.Pixels[Index].R := Max(Backing.Cutout.Pixels[Index].R, Round(Cut * Exterior));
        Inc(Index);
      end;
    end;
    FHasPartBacking := True;
  end;
  for Side := Low(Side) to High(Side) do
  begin
    Backing := @FPartBacking[Side];
    if Backing.Cutout.Width = 0 then Continue;
    Backing.Bounds.Inflate(1 / Backing.Cutout.Width, 1 / Backing.Cutout.Height);
    if FPartBacking[TImageSide(1 - Ord(Side))].Cutout.Width > 0 then
      FillCutout(Backing^, FImages[Side]);
  end;
end;

function TMorphRenderer.WithPartBacking(const Base: TPremul; const UA, UB: TPointF;
  ColorTime: Single): TPremul;
var
  CutA, CutB: Single;
  Visible, Hidden: TPremul;

  function Cutout(Side: TImageSide; const UV: TPointF): Single;
  begin
    if not FPartBacking[Side].Bounds.Contains(UV) then Exit(0);
    Result := SampleAlpha(FPartBacking[Side].Cutout, UV);
  end;

begin
  CutA := Cutout(isA, UA);
  CutB := Cutout(isB, UB);
  Visible := Base;
  if CutB > 0 then
    Visible := MixColor(Visible, Sample(FImages[isA], UA), CutB);
  if CutA <= 0 then Exit(Visible);
  if CutB < 1 then Hidden := Sample(FImages[isB], UB);
  if CutB > 0 then
  begin
    Result := MixColor(Sample(FPartBacking[isA].Fill, UA), Sample(FPartBacking[isB].Fill, UB), ColorTime);
    if CutB < 1 then Hidden := MixColor(Hidden, Result, CutB)
    else Hidden := Result;
  end;
  Result := MixColor(Visible, Hidden, CutA);
end;

procedure TMorphRenderer.Prepare(const Images: TSourceImages; const Model: TMorphModel; RebuildMasks: Boolean);
var
  Side: TImageSide;
  RebuildBacking: Boolean;
begin
  RebuildBacking := RebuildMasks or (Length(FLayers) = 0);
  for Side := Low(Side) to High(Side) do
    RebuildBacking := RebuildBacking or (Pointer(FImages[Side].Pixels) <> Pointer(Images[Side].Pixels));
  FImages := Images;
  FModel := Model;
  FReferenceW := Max(1, Max(Images[isA].Width, Images[isB].Width));
  FReferenceH := Max(1, Max(Images[isA].Height, Images[isB].Height));
  if RebuildMasks then FLayers := nil;
  FUseSavedMesh := Length(Model.Mesh.Layers) > 0;
  for Side := Low(Side) to High(Side) do
    FUseSavedMesh := FUseSavedMesh and (Model.Mesh.Size[Side].cx = Images[Side].Width) and
      (Model.Mesh.Size[Side].cy = Images[Side].Height);
  BuildLayers;
  BuildCurves;
  if RebuildBacking then PreparePartBacking;
  PrepareContourFields;
end;

function TMorphRenderer.CanvasSize(T: Single): TSize;
var
  Factor, Weight: Double;
  Side: TImageSide;
begin
  if FImages[isA].Width = 0 then
    Exit(TSize.Create(Max(1, FImages[isB].Width), Max(1, FImages[isB].Height)));
  if FImages[isB].Width = 0 then Exit(TSize.Create(FImages[isA].Width, FImages[isA].Height));
  if T <= 0.5 then Side := isA else Side := isB;
  Weight := SmoothStep(Min(T, 1 - T) * 2);
  Result.cx := Max(1, Round(Linear(FImages[Side].Width, FReferenceW, Weight)));
  Result.cy := Max(1, Round(Linear(FImages[Side].Height, FReferenceH, Weight)));
  if Int64(Result.cx) * Result.cy > MORPH_MAX_PIXELS then
  begin
    Factor := Sqrt(MORPH_MAX_PIXELS / (Int64(Result.cx) * Result.cy));
    Result.cx := Max(1, Trunc(Result.cx * Factor));
    Result.cy := Max(1, Trunc(Result.cy * Factor));
  end;
end;

function TMorphRenderer.OneSidedPosition(const Layer: TMeshLayer; const UV: TPointF;
  Side: TImageSide; T, Weight: Single): TPointF;
var
  Attachment: TMorphPoint;
  Other: TImageSide;
  Head, OtherHead, Mount: TRectF;
  Collapsed, Present: TPointF;
  ContactY, HeightFraction, WidthScale: Single;
begin
  Other := TImageSide(1 - Ord(Side));
  Present := MapToReference(Side, UV, Weight);
  if not Layer.HeadMount.IsEmpty then
  begin
    Head := FHeadBounds[Side];
    OtherHead := FHeadBounds[Other];
    Mount := Layer.HeadMount;
    ContactY := EnsureRange(Head.Top + 0.08 * Head.Height,
      Mount.Top + 0.30 * Mount.Height, Mount.Bottom - 0.08 * Mount.Height);
    HeightFraction := EnsureRange((ContactY - Head.Top) / Head.Height, 0, 0.15);
    WidthScale := Min(1.0, 0.9 * OtherHead.Width / Mount.Width);
    // Collapse onto a line across the other head. Related details share this same transform.
    Collapsed := MapToReference(Other, PointF(
      OtherHead.CenterPoint.X + (UV.X - Mount.CenterPoint.X) * WidthScale,
      OtherHead.Top + OtherHead.Height * HeightFraction), Weight);
  end
  else
  begin
    Collapsed := MapToReference(Side, Layer.Anchor, Weight);
    if Layer.AttachmentIndex >= 0 then
    begin
      Attachment := FModel.Points[Layer.AttachmentIndex];
      Collapsed := Collapsed + MapToReference(Other, Attachment.UV[Other], Weight) -
        MapToReference(Side, Attachment.UV[Side], Weight);
    end;
  end;
  if FModel.Smooth then T := SmoothStep(T);
  if Side = isA then T := 1 - T;
  Result := MixPoint(Collapsed, Present, T);
end;

function TMorphRenderer.AutomaticPosition(Index: Integer; T: Single): TPointF;
var
  P: TMorphPoint;
  L: TMeshLayer;
  V: TMeshVertex;
  A, B: TPointF;
  Weight: Single;
  Code: Integer;
  Side: TImageSide;
begin
  Weight := RegistrationWeight(T);
  L := Default(TMeshLayer);
  if Index < -1 then
  begin
    Code := -2 - Index;
    L := Mesh(Code div 4);
    if Length(L.Vertices) = 0 then Exit(PointF(0, 0));
    V := L.Vertices[Code mod 4];
    P := Default(TMorphPoint);
    P.Region := -1;
    P.Has[isA] := L.UseSide[isA];
    P.Has[isB] := L.UseSide[isB];
    P.UV := V.UV;
  end
  else
  begin
    P := FModel.Points[Index];
    if (P.Region >= 0) and (FModel.Regions[P.Region].State <> rsMatch) then L := Mesh(P.Region);
  end;
  if L.UseSide[isA] xor L.UseSide[isB] then
  begin
    Side := TImageSide(Ord(L.UseSide[isB]));
    Exit(OneSidedPosition(L, P.UV[Side], Side, T, Weight));
  end;
  if P.Region >= 0 then
    case FModel.Regions[P.Region].State of
      rsAppear: P.Has[isA] := False;
      rsDisappear: P.Has[isB] := False;
    end;
  A := MapToReference(isA, P.UV[isA], Weight);
  B := MapToReference(isB, P.UV[isB], Weight);
  if not P.Has[isA] then A := B;
  if not P.Has[isB] then B := A;
  if FModel.Smooth then T := SmoothStep(T);
  Result := MixPoint(A, B, T);
end;

procedure TMorphRenderer.BuildCurves;
var
  Key: TShapeKey;
  Correction: TCorrection;
  Knot: TCurveKnot;
  Index, InsertAt, Origin: Integer;
begin
  FCurves := nil;
  Origin := Length(FModel.Regions) * 4 + 1;
  SetLength(FCurves, Length(FModel.Points) + Origin);
  for Key in FModel.Keys do
    for Correction in Key.Points do
    begin
      Index := Correction.Vertex + Origin;
      Knot.At := Key.At / 10000;
      Knot.Delta := Correction.Position - AutomaticPosition(Correction.Vertex, Knot.At);
      InsertAt := Length(FCurves[Index]);
      while (InsertAt > 0) and (FCurves[Index][InsertAt - 1].At > Knot.At) do Dec(InsertAt);
      Insert(Knot, FCurves[Index], InsertAt);
    end;
end;

function TMorphRenderer.KeyedPosition(Index: Integer; T: Single): TPointF;
var
  Knot, Before, After: TCurveKnot;
begin
  Result := AutomaticPosition(Index, T);
  Index := Index + Length(FModel.Regions) * 4 + 1;
  if Length(FCurves[Index]) = 0 then Exit;
  Before := Default(TCurveKnot);
  After := Before;
  After.At := 1;
  for Knot in FCurves[Index] do
  begin
    if Knot.At >= T then
    begin
      After := Knot;
      Break;
    end;
    Before := Knot;
  end;
  Result := Result + MixPoint(Before.Delta, After.Delta, SmoothStep((T - Before.At) / (After.At - Before.At)));
end;

function TMorphRenderer.ToCanvas(const P: TPointF): TPointF;
begin
  Result := PointF(0.5 + (P.X - 0.5) * FReferenceW / FFullSize.cx,
    0.5 + (P.Y - 0.5) * FReferenceH / FFullSize.cy);
end;

function TMorphRenderer.FromCanvas(const P: TPointF): TPointF;
begin
  Result := PointF(0.5 + (P.X - 0.5) * FFullSize.cx / FReferenceW,
    0.5 + (P.Y - 0.5) * FFullSize.cy / FReferenceH);
end;

function TMorphRenderer.Mesh(Region: Integer): TMeshLayer;
var
  Layer: TMeshLayer;
  T: TTriangle;

  function InRegion(VertexIndex: Integer): Boolean;
  var
    PointIndex: Integer;
    Parents: TTriangle;
  begin
    if Layer.Vertices[VertexIndex].HasParents then
    begin
      Parents := Layer.Vertices[VertexIndex].Parents;
      Exit(InRegion(Parents.A) and InRegion(Parents.B) and InRegion(Parents.C));
    end;
    PointIndex := Layer.Vertices[VertexIndex].PointIndex;
    Result := (PointIndex >= 0) and (FModel.Points[PointIndex].Region = Region);
  end;

begin
  for Layer in FLayers do
    if (Layer.Region = Region) and not Layer.Companion then Exit(Layer);
  Result := Default(TMeshLayer);
  if FUsesAutoGrid and (Region >= 0) and (Region < Length(FModel.Regions)) then
  begin
    Layer := FLayers[0];
    Result.Region := Region;
    Result.UseSide := Layer.UseSide;
    Result.Vertices := Layer.Vertices;
    for T in Layer.Triangles do
      if InRegion(T.A) and InRegion(T.B) and InRegion(T.C) then
        Result.Triangles := Result.Triangles + [T];
  end;
end;

function TMorphRenderer.SavedMesh: TSavedMesh;
var
  Side: TImageSide;
  I, LayerCount: Integer;
begin
  Result := Default(TSavedMesh);
  if (FImages[isA].Width = 0) or (FImages[isB].Width = 0) then Exit;
  for Side := Low(Side) to High(Side) do
    Result.Size[Side] := TSize.Create(FImages[Side].Width, FImages[Side].Height);
  SetLength(Result.Layers, Length(FLayers));
  LayerCount := 0;
  for I := 0 to High(FLayers) do
  begin
    if FLayers[I].Companion then Continue;
    Result.Layers[LayerCount].Region := FLayers[I].Region;
    Result.Layers[LayerCount].VertexCount := Length(FLayers[I].Vertices);
    Result.Layers[LayerCount].Triangles := FLayers[I].Triangles;
    if FLayers[I].CoarseVertexCount > 0 then
    begin
      Result.Layers[LayerCount].VertexCount := FLayers[I].CoarseVertexCount;
      Result.Layers[LayerCount].Triangles := FLayers[I].CoarseTriangles;
    end;
    Inc(LayerCount);
  end;
  SetLength(Result.Layers, LayerCount);
end;

function TMorphRenderer.PreviewVertex(Index, Progress: Integer; out UV: TPointF): Boolean;
var
  P: TMorphPoint;
  T: Single;
  Layer: TMeshLayer;
  Vertex: TMeshVertex;
begin
  Result := False;
  if Index = -1 then Exit;
  if Index < -1 then Layer := Mesh((-2 - Index) div 4)
  else
  begin
    P := FModel.Points[Index];
    Layer := Mesh(P.Region);
    if Length(Layer.Vertices) = 0 then Layer := Mesh(-1);
  end;
  for Vertex in Layer.Vertices do
    if Vertex.PointIndex = Index then
    begin
      T := Progress / 10000;
      FFullSize := CanvasSize(T);
      UV := ToCanvas(KeyedPosition(Index, T));
      Exit(True);
    end;
  if (Index >= 0) and (P.Region >= 0) then
  begin
    Layer := Mesh(-1);
    for Vertex in Layer.Vertices do
      if Vertex.PointIndex = Index then
      begin
        T := Progress / 10000;
        FFullSize := CanvasSize(T);
        UV := ToCanvas(KeyedPosition(Index, T));
        Exit(True);
      end;
  end;
end;

function TMorphRenderer.PreviewMesh(Region, Progress: Integer; out Positions: TPointPath): TMeshLayer;
var
  I: Integer;
  Frame: TFrameVertices;
begin
  Result := Mesh(Region);
  PrepareFrameState(Progress);
  BuildFrame(Result, 1, 1, Frame);
  SetLength(Positions, Length(Frame));
  for I := 0 to High(Positions) do Positions[I] := Frame[I].Target;
end;

function TMorphRenderer.PreviewCorrection(const UV: TPointF; Progress: Integer): TPointF;
begin
  FFullSize := CanvasSize(Progress / 10000);
  Result := FromCanvas(UV);
  Result.X := EnsureRange(Result.X, -4, 5);
  Result.Y := EnsureRange(Result.Y, -4, 5);
end;

function TMorphRenderer.ContourDistances(Side: TImageSide; const UV: TPointF): TSurfaceDistances;
begin
  if (UV.X < FFieldBounds[Side].Left) or (UV.X > FFieldBounds[Side].Right) or
    (UV.Y < FFieldBounds[Side].Top) or (UV.Y > FFieldBounds[Side].Bottom) then
    Exit(TSurfaceDistances.Create(-0.5, -0.5, -1));
  Result := SampleSilhouetteField(FContourFields[Side], UV);
end;

function TMorphRenderer.MatteAlpha(Side: TImageSide; const UV: TPointF): Single;
begin
  if FMatteOpaque[Side] then
    Exit(Ord((UV.X >= 0) and (UV.X <= 1) and (UV.Y >= 0) and (UV.Y <= 1)));
  Result := SampleAlpha(FImages[Side], UV);
end;

function TMorphRenderer.BlendFrame(const UA, UB: TPointF; ColorTime: Single): TPremul;
var
  A, B: TPremul;
  FieldA, FieldB: TSurfaceDistances;
begin
  if FUseContourFields then
  begin
    FieldA := ContourDistances(isA, UA);
    FieldB := ContourDistances(isB, UB);
    if FFullContourBlend and (FieldA.Outline <= -1 / 24) and (FieldB.Outline <= -1 / 24) then
    begin
      // Neither surface can cover this pixel. Only the original flat matte contributes.
      Result.A := 0;
      if (FPaleMattes and 1) <> 0 then Result.A := MatteAlpha(isA, UA) * (1 - ColorTime);
      if (FPaleMattes and 2) <> 0 then Result.A := Result.A + MatteAlpha(isB, UB) * ColorTime;
      Result.R := 253 * Result.A;
      Result.G := Result.R;
      Result.B := Result.R;
      Exit;
    end;
    if FFullContourBlend and (FieldA.Outline <= -1 / 24) then
    begin
      A := Default(TPremul);
      if (FPaleMattes and 1) <> 0 then A.A := MatteAlpha(isA, UA);
    end
    else A := Sample(FImages[isA], UA);
    if FFullContourBlend and (FieldB.Outline <= -1 / 24) then
    begin
      B := Default(TPremul);
      if (FPaleMattes and 2) <> 0 then B.A := MatteAlpha(isB, UB);
    end
    else B := Sample(FImages[isB], UB);
    Result := MorphSilhouette(A, B, FieldA, FieldB, FEased, ColorTime, FAppearance, FPaleMattes);
    Exit;
  end;
  A := Sample(FImages[isA], UA);
  B := Sample(FImages[isB], UB);
  Result := MixColor(A, B, ColorTime);
end;

procedure TMorphRenderer.PrepareFrameState(Progress: Integer);
var
  Side: TImageSide;
  I: Integer;
  Weight: Single;
begin
  FTime := EnsureRange(Progress, 0, 10000) / 10000;
  FFullSize := CanvasSize(FTime);
  FEased := ShapeTime(Progress);
  FFullContourBlend := (FAppearance = 1) and (FEased >= 1 / 16) and (FEased <= 15 / 16);
  if FModel.Mix < 0.0001 then FColorTime := Ord(FTime >= 0.5)
  else FColorTime := EnsureRange(0.5 + (FTime - 0.5) / FModel.Mix, 0, 1);
  Weight := RegistrationWeight(FTime);
  for Side := Low(Side) to High(Side) do
    FTransforms[Side] := ImageTransform(FImages[Side], FReferenceW, FReferenceH, FModel.Align[Side], Weight);
  SetLength(FAdjusted, Length(FModel.Points));
  for I := 0 to High(FAdjusted) do FAdjusted[I] := KeyedPosition(I, FTime);
end;

procedure TMorphRenderer.BuildFrame(const Layer: TMeshLayer; Width, Height: Integer; var Frame: TFrameVertices);
var
  I: Integer;
  V: TMeshVertex;
  Side: TImageSide;
  Corner: TTriangle;
  Aspect: Single;
  P, PA, PB, UV, Weights: TPointF;
begin
  Aspect := FReferenceW / FReferenceH;
  SetLength(Frame, Length(Layer.Vertices));
  for I := 0 to High(Frame) do
  begin
    V := Layer.Vertices[I];
    if V.HasParents then
    begin
      Corner := V.Parents;
      Weights := MixPoint(V.ParentWeights[isA], V.ParentWeights[isB], FEased);
      P := BarycentricPoint(Frame[Corner.A].Target, Frame[Corner.B].Target, Frame[Corner.C].Target, Weights);
    end
    else
    begin
      if V.PointIndex >= 0 then P := FAdjusted[V.PointIndex]
      else if V.PointIndex < -1 then P := KeyedPosition(V.PointIndex, FTime)
      else if Layer.Companion then
      begin
        Side := TImageSide(Ord(Layer.UseSide[isB]));
        P := OneSidedPosition(Layer, V.UV[Side], Side, FTime, RegistrationWeight(FTime));
      end
      else
      begin
        PA := MapUV(FTransforms[isA], V.UV[isA], Aspect);
        PB := MapUV(FTransforms[isB], V.UV[isB], Aspect);
        if not Layer.UseSide[isA] then PA := PB;
        if not Layer.UseSide[isB] then PB := PA;
        P := MixPoint(PA, PB, FEased);
      end;
      P := ToCanvas(P);
      P := PointF(P.X * Width, P.Y * Height);
    end;
    Frame[I].Target := P;
    for Side := Low(Side) to High(Side) do
    begin
      UV := V.UV[Side];
      if (FModel.Shape < 1) and (Layer.UseSide[isA] and Layer.UseSide[isB]) then
        UV := MixPoint(UnmapUV(FTransforms[Side], FromCanvas(PointF(P.X / Width, P.Y / Height)), Aspect),
          UV, FModel.Shape);
      Frame[I].UV[Side] := UV;
    end;
  end;
end;

procedure TMorphRenderer.FinishPixel(Offset: Integer; const Color: TPremul);
var
  Blend: ^TPixelBlend;
  Combined: TPremul;
begin
  if (FCoverage[Offset] and HasOverlayBlend) = 0 then
    FBuffer.Pixels[Offset] := Pixel(Color)
  else
  begin
    Blend := @FOverlayBlend[Offset];
    Combined.R := Blend.Color.R + Blend.Remaining * Color.R;
    Combined.G := Blend.Color.G + Blend.Remaining * Color.G;
    Combined.B := Blend.Color.B + Blend.Remaining * Color.B;
    Combined.A := Blend.Color.A + Blend.Remaining * Color.A;
    FBuffer.Pixels[Offset] := Pixel(Combined);
  end;
  FCoverage[Offset] := FinishedPixel;
end;

procedure TMorphRenderer.BlendOverlay(Offset: Integer; const Color: TPremul; Weight: Single);
var
  Blend: ^TPixelBlend;
  Contribution: Single;
begin
  if Weight >= 1 then
  begin
    FinishPixel(Offset, Color);
    Exit;
  end;
  Blend := @FOverlayBlend[Offset];
  if (FCoverage[Offset] and HasOverlayBlend) = 0 then
  begin
    Blend.Color.R := Color.R * Weight;
    Blend.Color.G := Color.G * Weight;
    Blend.Color.B := Color.B * Weight;
    Blend.Color.A := Color.A * Weight;
    Blend.Remaining := 1 - Weight;
    FCoverage[Offset] := FCoverage[Offset] or HasOverlayBlend;
  end
  else
  begin
    Contribution := Blend.Remaining * Weight;
    Blend.Color.R := Blend.Color.R + Contribution * Color.R;
    Blend.Color.G := Blend.Color.G + Contribution * Color.G;
    Blend.Color.B := Blend.Color.B + Contribution * Color.B;
    Blend.Color.A := Blend.Color.A + Contribution * Color.A;
    Blend.Remaining := Blend.Remaining * (1 - Weight);
  end;
end;

function InverseSlope(Step: Double): Double; inline;
begin
  if Step = 0 then Exit(0);
  Result := 1 / Step;
end;

function ClipScanline(Distance, InverseStep: Double; var First, Last: Double): Boolean; inline;
const
  // Leave a margin so the exact barycentric test still decides pixels on the edge.
  EdgePadding = TriangleEdgeTolerance + 1E-9;
begin
  if InverseStep > 0 then First := Max(First, (-EdgePadding - Distance) * InverseStep)
  else if InverseStep < 0 then Last := Min(Last, (-EdgePadding - Distance) * InverseStep)
  else if Distance < -EdgePadding then Exit(False);
  Result := First <= Last;
end;

procedure TMorphRenderer.RasterLayer(const Layer: TMeshLayer; const Frame: TFrameVertices;
  Stamp: Word; FirstY, LastY: Integer);
type
  TDoubleUV = record
    X, Y: Double;
  end;
var
  T: TTriangle;
  A, B, C: TFrameVertex;
  UA, UB: TPointF;
  Color: TPremul;
  Area, Inverse, U, K, J, PX, PY, DU, DK, InverseDU, InverseDK, InverseDJ, First, Last: Double;
  DeltaA, DeltaB, UVStep, RowUV: array[TImageSide] of TDoubleUV;
  Side: TImageSide;
  Weight, DA, DB, FeatherScale, OverlayWeight, AtA, AtB, LocalTime, MixAmount, PartScale, InvAlpha: Single;
  X, Y, X0, X1, Y0, Y1, StartX, EndX, Skip, Offset, W: Integer;
  Coverage: Word;
  IsBase, UseA, UseB, Paired, MatchInternalSurfaces: Boolean;
begin
  W := FBuffer.Width;
  IsBase := Layer.Region < 0;
  OverlayWeight := Sin(Pi * FTime);
  UseA := Layer.UseSide[isA];
  UseB := Layer.UseSide[isB];
  Paired := UseA and UseB;
  PartScale := 1;
  if not Paired then
    if UseA then PartScale := 1 - FEased else PartScale := FEased;
  // Larger regions such as hair or clothing can contain distinct surfaces inside their outline.
  // Smaller regions rely on their own measured boundary and don't repeat whole-image sampling.
  MatchInternalSurfaces := FUseContourFields and not IsBase and UseA and UseB and
    (Layer.Masks[isA].Bounds.Width * Layer.Masks[isA].Bounds.Height >= 0.065) and
    (Layer.Masks[isB].Bounds.Width * Layer.Masks[isB].Bounds.Height >= 0.065);
  MixAmount := EnsureRange(FColorTime, 0.001, 0.999);
  FeatherScale := Max(1, Min(FReferenceW, FReferenceH)) * PartScale /
    (2 * (FModel.Feather * PartScale + 0.5 * FFullSize.cx / W));
  for T in Layer.Triangles do
  begin
    A := Frame[T.A];
    B := Frame[T.B];
    C := Frame[T.C];
    // 折り返した三角形は下の領域または基準画像の混合で埋める。
    Area := Cross(A.Target, B.Target, C.Target);
    if Area < 1E-5 then Continue;
    if (UseA and (Cross(A.UV[isA], B.UV[isA], C.UV[isA]) <= 1E-9)) or
       (UseB and (Cross(A.UV[isB], B.UV[isB], C.UV[isB]) <= 1E-9)) then Continue;
    X0 := Max(0, Floor(Min(A.Target.X, Min(B.Target.X, C.Target.X))));
    X1 := Min(W - 1, Ceil(Max(A.Target.X, Max(B.Target.X, C.Target.X))));
    Y0 := Max(FirstY, Floor(Min(A.Target.Y, Min(B.Target.Y, C.Target.Y))));
    Y1 := Min(LastY, Ceil(Max(A.Target.Y, Max(B.Target.Y, C.Target.Y))));
    if (Y0 > Y1) or (X0 > X1) then Continue;
    Inverse := 1 / Area;
    DU := (B.Target.Y - C.Target.Y) * Inverse;
    DK := (C.Target.Y - A.Target.Y) * Inverse;
    InverseDU := InverseSlope(DU);
    InverseDK := InverseSlope(DK);
    InverseDJ := InverseSlope(-DU - DK);
    for Side := Low(Side) to High(Side) do
    begin
      DeltaA[Side].X := Double(A.UV[Side].X) - C.UV[Side].X;
      DeltaA[Side].Y := Double(A.UV[Side].Y) - C.UV[Side].Y;
      DeltaB[Side].X := Double(B.UV[Side].X) - C.UV[Side].X;
      DeltaB[Side].Y := Double(B.UV[Side].Y) - C.UV[Side].Y;
      UVStep[Side].X := DeltaA[Side].X * DU + DeltaB[Side].X * DK;
      UVStep[Side].Y := DeltaA[Side].Y * DU + DeltaB[Side].Y * DK;
    end;
    for Y := Y0 to Y1 do
    begin
      PY := Y + 0.5;
      PX := X0 + 0.5;
      U := ((B.Target.X - PX) * (C.Target.Y - PY) - (B.Target.Y - PY) * (C.Target.X - PX)) * Inverse;
      K := ((C.Target.X - PX) * (A.Target.Y - PY) - (C.Target.Y - PY) * (A.Target.X - PX)) * Inverse;
      // Clip the scanline against the three triangle edges before stepping through its pixels.
      First := 0;
      Last := X1 - X0;
      if not ClipScanline(U, InverseDU, First, Last) or
         not ClipScanline(K, InverseDK, First, Last) or
         not ClipScanline(1 - U - K, InverseDJ, First, Last) then Continue;
      Skip := Floor(First);
      StartX := X0 + Skip;
      EndX := X0 + Ceil(Last);
      U := U + DU * Skip;
      K := K + DK * Skip;
      // Texture coordinates are affine within a triangle. Advance them with the scanline.
      for Side := Low(Side) to High(Side) do
      begin
        RowUV[Side].X := C.UV[Side].X + DeltaA[Side].X * U + DeltaB[Side].X * K;
        RowUV[Side].Y := C.UV[Side].Y + DeltaA[Side].Y * U + DeltaB[Side].Y * K;
      end;
      Offset := Y * W + StartX;
      for X := StartX to EndX do
      begin
        J := 1 - U - K;
        Coverage := FCoverage[Offset];
        if (Coverage <> FinishedPixel) and ((Coverage and LayerStampMask) <> Stamp) and
          (U >= -TriangleEdgeTolerance) and (K >= -TriangleEdgeTolerance) and
          (J >= -TriangleEdgeTolerance) then
        begin
          FCoverage[Offset] := Stamp or (Coverage and HasOverlayBlend);
          UA := PointF(RowUV[isA].X, RowUV[isA].Y);
          UB := PointF(RowUV[isB].X, RowUV[isB].Y);
          if IsBase then
          begin
            Color := BlendFrame(UA, UB, FColorTime);
            if FHasPartBacking then Color := WithPartBacking(Color, UA, UB, FColorTime);
            FinishPixel(Offset, Color);
          end
          else
          begin
            if UseA then DA := SampleMask(Layer.Masks[isA], UA) else DA := 0;
            if UseB then DB := SampleMask(Layer.Masks[isB], UB) else DB := 0;
            if Layer.HeadwearSilhouette then
            begin
              if UseA then DA := DA + EnsureRange(FHeadBounds[isA].Top - UA.Y, 0, HeadwearContourMargin)
              else DB := DB + EnsureRange(FHeadBounds[isB].Top - UB.Y, 0, HeadwearContourMargin);
            end;
            if UseA and UseB then
              Weight := SmoothStep(EnsureRange(0.5 + Linear(DA, DB, FEased) * FeatherScale, 0, 1))
            else if UseA then
              Weight := SmoothStep(EnsureRange(0.5 + DA * FeatherScale, 0, 1))
            else
              Weight := SmoothStep(EnsureRange(0.5 + DB * FeatherScale, 0, 1));
            if Weight > 0 then
            begin
              if UseA and UseB then
              begin
                AtA := SmoothStep(EnsureRange(0.5 + DA * FeatherScale, 0, 1)) * (1 - MixAmount);
                AtB := SmoothStep(EnsureRange(0.5 + DB * FeatherScale, 0, 1)) * MixAmount;
                LocalTime := FColorTime;
                if AtA + AtB > 1E-5 then LocalTime := Linear(FColorTime, AtB / (AtA + AtB), FModel.Shape);
                if MatchInternalSurfaces then Color := BlendFrame(UA, UB, LocalTime)
                else if LocalTime <= 0 then Color := Sample(FImages[isA], UA)
                else if LocalTime >= 1 then Color := Sample(FImages[isB], UB)
                else Color := MixColor(Sample(FImages[isA], UA), Sample(FImages[isB], UB), LocalTime);
                if FHasPartBacking then Color := WithPartBacking(Color, UA, UB, LocalTime);
                // A paired region owns the interior of its moving outline.
                Weight := Weight * Linear(OverlayWeight, 1, FModel.Shape);
              end
              else
              begin
                if UseA then Color := Sample(FImages[isA], UA)
                else Color := Sample(FImages[isB], UB);
                if Color.A > 0 then
                begin
                  // Preserve source translucency and reveal the backing through it.
                  Weight := Weight * Color.A;
                  InvAlpha := 1 / Color.A;
                  Color.R := Color.R * InvAlpha;
                  Color.G := Color.G * InvAlpha;
                  Color.B := Color.B * InvAlpha;
                  Color.A := 1;
                end;
              end;
              if Color.A > 0 then BlendOverlay(Offset, Color, Weight);
            end;
          end;
        end;
        Inc(Offset);
        U := U + DU;
        K := K + DK;
        RowUV[isA].X := RowUV[isA].X + UVStep[isA].X;
        RowUV[isA].Y := RowUV[isA].Y + UVStep[isA].Y;
        RowUV[isB].X := RowUV[isB].X + UVStep[isB].X;
        RowUV[isB].Y := RowUV[isB].Y + UVStep[isB].Y;
      end;
    end;
  end;
end;

function TMorphRenderer.Render(Progress: Integer; PreviewLimit: Integer): TMorphImage;
var
  Side, Other: TImageSide;
  Source: TMorphImage;
  Factor: Single;
  I, X, Y, W, H, Bands: Integer;
begin
  FTime := EnsureRange(Progress, 0, 10000) / 10000;
  FFullSize := CanvasSize(FTime);
  W := FFullSize.cx;
  H := FFullSize.cy;
  if FTime < 0.5 then Side := isA else Side := isB;
  Other := TImageSide(1 - Ord(Side));
  if (FTime = 0) or (FTime = 1) or (FImages[Side].Width = 0) or (FImages[Other].Width = 0) then
  begin
    Source := FImages[Side];
    if (Source.Width = 0) and (FTime > 0) and (FTime < 1) then Source := FImages[Other];
    if (PreviewLimit = 0) or (Max(Source.Width, Source.Height) <= PreviewLimit) then Exit(Source);
    Factor := PreviewLimit / Max(Source.Width, Source.Height);
    W := Max(1, Round(Source.Width * Factor));
    H := Max(1, Round(Source.Height * Factor));
    SetLength(FBuffer.Pixels, W * H);
    FBuffer.Width := W;
    FBuffer.Height := H;
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
        FBuffer.Pixels[Y * W + X] := Pixel(Sample(Source, PointF((X + 0.5) / W, (Y + 0.5) / H)));
    Exit(FBuffer);
  end;
  if (PreviewLimit > 0) and (Max(W, H) > PreviewLimit) then
  begin
    Factor := PreviewLimit / Max(W, H);
    W := Max(1, Round(W * Factor));
    H := Max(1, Round(H * Factor));
  end;
  FBuffer.Width := W;
  FBuffer.Height := H;
  SetLength(FBuffer.Pixels, W * H);
  if Length(FLayers) > 1 then SetLength(FOverlayBlend, W * H) else FOverlayBlend := nil;
  SetLength(FCoverage, W * H);
  FillChar(FCoverage[0], W * H * SizeOf(Word), 0);
  PrepareFrameState(Progress);
  SetLength(FFrames, Length(FLayers));
  for I := 0 to High(FLayers) do BuildFrame(FLayers[I], W, H, FFrames[I]);
  if W * H < 384 * 384 then RenderRows(0, H - 1)
  else
  begin
    Bands := Min(16, Min(TThread.ProcessorCount, Max(1, (H + 31) div 32)));
    TParallel.For(0, Bands - 1,
      procedure(Band: Integer)
      begin
        RenderRows(H * Band div Bands, H * (Band + 1) div Bands - 1);
      end);
  end;
  Result := FBuffer;
end;

function TMorphRenderer.HostFrame(Progress: Integer; out Size: TSize; out Vertices: THostVertices;
  out Blend: Single): Boolean;
var
  N: Integer;
  Frame: TFrameVertices;
  Layer: TMeshLayer;
  Triangle: TTriangle;
  Side: TImageSide;

  procedure Emit(Index: Integer);
  var
    P: THostVertex;
    S: TImageSide;
  begin
    P.X := (Frame[Index].Target.X - 0.5) * Size.cx;
    P.Y := (Frame[Index].Target.Y - 0.5) * Size.cy;
    P.Z := 0;
    P.Alpha := 1;
    for S := Low(S) to High(S) do
    begin
      P.U := Frame[Index].UV[S].X;
      P.V := Frame[Index].UV[S].Y;
      Vertices[S][N] := P;
    end;
    Inc(N);
  end;

begin
  Result := False;
  if (Progress <= 0) or (Progress >= 10000) or (Length(FLayers) <> 1) or
    (FImages[isA].Width = 0) or (FImages[isB].Width = 0) then Exit;
  PrepareFrameState(Progress);
  Size := FFullSize;
  Blend := FColorTime;
  Layer := FLayers[0];
  BuildFrame(Layer, 1, 1, Frame);
  for Triangle in Layer.Triangles do
  begin
    if Cross(Frame[Triangle.A].Target, Frame[Triangle.B].Target, Frame[Triangle.C].Target) <= 1E-9 then Exit;
    for Side := Low(Side) to High(Side) do
      if Cross(Frame[Triangle.A].UV[Side], Frame[Triangle.B].UV[Side],
        Frame[Triangle.C].UV[Side]) <= 1E-9 then Exit;
  end;
  N := 0;
  for Side := Low(Side) to High(Side) do SetLength(Vertices[Side], Length(Layer.Triangles) * 3);
  for Triangle in Layer.Triangles do
  begin
    Emit(Triangle.A);
    Emit(Triangle.B);
    Emit(Triangle.C);
  end;
  Result := N <> 0;
end;

procedure TMorphRenderer.RenderRows(FirstY, LastY: Integer);
var
  I, W, H, X, Y: Integer;
  Aspect: Single;
  RefP, UA, UB: TPointF;
  Color: TPremul;
begin
  // Accumulate front to back. Once a region has full weight, lower layers cannot affect that pixel.
  for I := High(FLayers) downto 0 do RasterLayer(FLayers[I], FFrames[I], I + 1, FirstY, LastY);
  W := FBuffer.Width;
  H := FBuffer.Height;
  Aspect := FReferenceW / FReferenceH;
  for Y := FirstY to LastY do
  begin
    for X := 0 to W - 1 do
    begin
      I := Y * W + X;
      if FCoverage[I] = FinishedPixel then Continue;
      RefP := FromCanvas(PointF((X + 0.5) / W, (Y + 0.5) / H));
      UA := UnmapUV(FTransforms[isA], RefP, Aspect);
      UB := UnmapUV(FTransforms[isB], RefP, Aspect);
      Color := BlendFrame(UA, UB, FColorTime);
      if FHasPartBacking then Color := WithPartBacking(Color, UA, UB, FColorTime);
      FinishPixel(I, Color);
    end;
  end;
end;

end.
