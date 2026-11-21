unit Morphing_Registration;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses System.SysUtils, Morphing_Model, Morphing_Renderer;

procedure RefineAutomaticMesh(const Images: TSourceImages; var Model: TMorphModel;
  const Cancelled: TFunc<Boolean> = nil; const RegionReady: TProc<Integer> = nil);

implementation

uses System.Math, System.Types, System.Generics.Collections, System.Generics.Defaults,
  Morphing_Mesh, Morphing_Images;

const
  DomainLimit = 512;
  PatchRadius = 3;
  SearchLimit = 12;
  MinInterior = 0.08;
  Probes: array[0..3] of TPointF =
    ((X: 0.3333; Y: 0.3333), (X: 0.23; Y: 0.23), (X: 0.54; Y: 0.23), (X: 0.23; Y: 0.54));

type
  TTexturePixel = record
    Luma, GX, GY: Single;
    InSubject: Boolean;
  end;
  TMidpointTexture = record
    Width, Height: Integer;
    Pixels: TArray<TTexturePixel>;
  end;
  TMidpointPair = array[TImageSide] of TMidpointTexture;
  TScreenTriangle = record
    A, B, C: TPointF;
    Area: Double;
    function Coordinates(const P: TPointF): TPointF;
    function Inside(const Weights: TPointF; Margin: Single): Boolean;
  end;
  TDetailCandidate = record
    Detail: TMeshDetail;
    Score: Single;
  end;

function TScreenTriangle.Coordinates(const P: TPointF): TPointF;
begin
  Result := PointF(Cross(A, P, C) / Area, Cross(A, B, P) / Area);
end;

function TScreenTriangle.Inside(const Weights: TPointF; Margin: Single): Boolean;
begin
  Result := (Weights.X >= Margin) and (Weights.Y >= Margin) and (Weights.X + Weights.Y <= 1 - Margin);
end;

function ScreenTriangle(const Vertices: TArray<THostVertex>; Index: Integer;
  const Size: TSize; Width, Height: Integer): TScreenTriangle;

  function ScreenPoint(Vertex: Integer): TPointF;
  var
    P: THostVertex;
  begin
    P := Vertices[3 * Index + Vertex];
    Result := PointF((0.5 + P.X / Size.cx) * Width - 0.5, (0.5 + P.Y / Size.cy) * Height - 0.5);
  end;

begin
  Result.A := ScreenPoint(0);
  Result.B := ScreenPoint(1);
  Result.C := ScreenPoint(2);
  Result.Area := Cross(Result.A, Result.B, Result.C);
end;

procedure BuildMidpointTextures(const Vertices: THostVertices; const Size: TSize;
  const Images, Fields: TSourceImages; out Textures: TMidpointPair);
var
  Index, I, X, Y, X0, X1, Y0, Y1, Width, Height: Integer;
  Scale: Single;
  Triangle: TScreenTriangle;
  W, UV, A, B, C: TPointF;
  Side: TImageSide;
  Color: TPremul;
  F: TSurfaceDistances;
begin
  Scale := Min(1, DomainLimit / Max(Size.cx, Size.cy));
  Width := Max(1, Round(Size.cx * Scale));
  Height := Max(1, Round(Size.cy * Scale));
  for Side := Low(Side) to High(Side) do
  begin
    Textures[Side].Width := Width;
    Textures[Side].Height := Height;
    SetLength(Textures[Side].Pixels, Width * Height);
    for Index := 0 to Length(Vertices[Side]) div 3 - 1 do
    begin
      Triangle := ScreenTriangle(Vertices[Side], Index, Size, Width, Height);
      if Triangle.Area < 1E-5 then Continue;
      X0 := Max(0, Ceil(Min(Triangle.A.X, Min(Triangle.B.X, Triangle.C.X))));
      Y0 := Max(0, Ceil(Min(Triangle.A.Y, Min(Triangle.B.Y, Triangle.C.Y))));
      X1 := Min(Width - 1, Floor(Max(Triangle.A.X, Max(Triangle.B.X, Triangle.C.X))));
      Y1 := Min(Height - 1, Floor(Max(Triangle.A.Y, Max(Triangle.B.Y, Triangle.C.Y))));
      A := PointF(Vertices[Side][3 * Index].U, Vertices[Side][3 * Index].V);
      B := PointF(Vertices[Side][3 * Index + 1].U, Vertices[Side][3 * Index + 1].V);
      C := PointF(Vertices[Side][3 * Index + 2].U, Vertices[Side][3 * Index + 2].V);
      for Y := Y0 to Y1 do
        for X := X0 to X1 do
        begin
          W := Triangle.Coordinates(PointF(X, Y));
          if not Triangle.Inside(W, -1E-6) then Continue;
          UV := BarycentricPoint(A, B, C, W);
          F := SampleSilhouetteField(Fields[Side], UV);
          if F.Outline < 0 then Continue;
          Color := Sample(Images[Side], UV);
          if Color.A < 0.85 then Continue;
          I := Y * Width + X;
          Textures[Side].Pixels[I].Luma := (0.299 * Color.R + 0.587 * Color.G + 0.114 * Color.B) / Color.A;
          Textures[Side].Pixels[I].InSubject := True;
        end;
    end;
    for Y := 1 to Height - 2 do
      for X := 1 to Width - 2 do
      begin
        I := Y * Width + X;
        if Textures[Side].Pixels[I - 1].InSubject and Textures[Side].Pixels[I + 1].InSubject then
          Textures[Side].Pixels[I].GX := Textures[Side].Pixels[I + 1].Luma - Textures[Side].Pixels[I - 1].Luma;
        if Textures[Side].Pixels[I - Width].InSubject and Textures[Side].Pixels[I + Width].InSubject then
          Textures[Side].Pixels[I].GY := Textures[Side].Pixels[I + Width].Luma - Textures[Side].Pixels[I - Width].Luma;
      end;
  end;
end;

function PatchScore(const A, B: TMidpointTexture; const P, Q: TPoint): Single;
var
  X, Y, Count, RowA, RowB: Integer;
  L, R: TTexturePixel;
  SumA, SumB, SumAA, SumBB, SumAB, GradAA, GradBB, GradAB, VarA, VarB: Double;
begin
  Result := -1;
  if (P.X < PatchRadius) or (P.X >= A.Width - PatchRadius) or
    (P.Y < PatchRadius) or (P.Y >= A.Height - PatchRadius) or
    (Q.X < PatchRadius) or (Q.X >= B.Width - PatchRadius) or
    (Q.Y < PatchRadius) or (Q.Y >= B.Height - PatchRadius) then Exit;
  Count := 0;
  SumA := 0;
  SumB := 0;
  SumAA := 0;
  SumBB := 0;
  SumAB := 0;
  GradAA := 0;
  GradBB := 0;
  GradAB := 0;
  for Y := -PatchRadius to PatchRadius do
  begin
    RowA := (P.Y + Y) * A.Width + P.X;
    RowB := (Q.Y + Y) * B.Width + Q.X;
    for X := -PatchRadius to PatchRadius do
    begin
      L := A.Pixels[RowA + X];
      R := B.Pixels[RowB + X];
      if not (L.InSubject and R.InSubject) then Continue;
      Inc(Count);
      SumA := SumA + L.Luma;
      SumB := SumB + R.Luma;
      SumAA := SumAA + Sqr(L.Luma);
      SumBB := SumBB + Sqr(R.Luma);
      SumAB := SumAB + L.Luma * R.Luma;
      GradAA := GradAA + Sqr(L.GX) + Sqr(L.GY);
      GradBB := GradBB + Sqr(R.GX) + Sqr(R.GY);
      GradAB := GradAB + L.GX * R.GX + L.GY * R.GY;
    end;
  end;
  if Count < 42 then Exit;
  VarA := SumAA - Sqr(SumA) / Count;
  VarB := SumBB - Sqr(SumB) / Count;
  if (Min(VarA, VarB) < Count * 90) or (Min(GradAA, GradBB) < Count * 110) then Exit;

  // Normalize the colors separately. Both the shape and direction of the nearby edges must agree.
  Result := 0.62 * (SumAB - SumA * SumB / Count) / Sqrt(VarA * VarB) +
    0.38 * GradAB / Sqrt(GradAA * GradBB);
end;

function MatchPatch(const A, B: TMidpointTexture; const Triangle: TScreenTriangle;
  const P: TPoint; Radius: Integer; out Q: TPoint; out Score, Ambiguity: Single): Boolean;
var
  DX, DY: Integer;
  S, Best, Rival: Single;
  C: TPoint;
  Scores: array[-SearchLimit..SearchLimit, -SearchLimit..SearchLimit] of Single;
begin
  Best := -1;
  Q := P;
  for DY := -Radius to Radius do
    for DX := -Radius to Radius do
    begin
      S := -1;
      if Sqr(DX) + Sqr(DY) <= Sqr(Radius) then
      begin
        C := Point(P.X + DX, P.Y + DY);
        if Triangle.Inside(Triangle.Coordinates(PointF(C.X, C.Y)), MinInterior) then
        begin
          S := PatchScore(A, B, P, C);
          if S > -0.99 then S := S - 0.055 * Sqrt(Sqr(DX) + Sqr(DY)) / Radius;
        end;
      end;
      Scores[DX, DY] := S;
      if S <= Best then Continue;
      Best := S;
      Q := Point(P.X + DX, P.Y + DY);
    end;
  Score := Best;
  Result := Best > -0.99;
  Ambiguity := 0;
  if not Result then Exit;
  Rival := -1;
  for DY := -Radius to Radius do
    for DX := -Radius to Radius do
      if Sqr(P.X + DX - Q.X) + Sqr(P.Y + DY - Q.Y) >= 9 then
        Rival := Max(Rival, Scores[DX, DY]);
  Ambiguity := Best - Rival;
end;

function RefineTriangle(const Textures: TMidpointPair; const Triangle: TScreenTriangle;
  out Detail: TDetailCandidate): Boolean;
var
  Radius: Integer;
  Probe, Center, WA, WB: TPointF;
  P, Q, Reverse: TPoint;
  Score, Ambiguity, ReverseScore, ReverseAmbiguity, Baseline, Gain, Confidence: Single;
begin
  Result := False;
  Detail := Default(TDetailCandidate);
  if Triangle.Area < 25 then Exit;
  Radius := EnsureRange(Round(Sqrt(Triangle.Area) * 0.5), 3, SearchLimit);
  for Probe in Probes do
  begin
    Center := BarycentricPoint(Triangle.A, Triangle.B, Triangle.C, Probe);
    P := Point(Round(Center.X), Round(Center.Y));
    WA := Triangle.Coordinates(PointF(P.X, P.Y));
    if not Triangle.Inside(WA, MinInterior) then Continue;
    if not MatchPatch(Textures[isA], Textures[isB], Triangle, P, Radius, Q, Score, Ambiguity) then Continue;
    if (Score < 0.70) or (Ambiguity < 0.045) or (Sqr(P.X - Q.X) + Sqr(P.Y - Q.Y) < 4) then Continue;
    Baseline := PatchScore(Textures[isA], Textures[isB], P, P);
    Gain := Score - Baseline;
    if Gain < 0.15 then Continue;
    if not MatchPatch(Textures[isB], Textures[isA], Triangle, Q, Radius, Reverse, ReverseScore, ReverseAmbiguity) then Continue;
    if (ReverseScore < 0.69) or (ReverseAmbiguity < 0.035) or
      (Sqr(P.X - Reverse.X) + Sqr(P.Y - Reverse.Y) > 2) then Continue;
    Confidence := 0.65 * Score + 0.25 * Min(0.62, Gain) + 0.1 * Min(Ambiguity, 0.35);
    if Confidence <= Detail.Score then Continue;
    WB := Triangle.Coordinates(PointF(Q.X, Q.Y));
    Detail.Detail.Weights[isA] := WA;
    Detail.Detail.Weights[isB] := WB;
    Detail.Score := Confidence;
    Result := True;
  end;
end;

procedure RefineAutomaticMesh(const Images: TSourceImages; var Model: TMorphModel;
  const Cancelled: TFunc<Boolean>; const RegionReady: TProc<Integer>);
var
  Renderer: TMorphRenderer;
  Vertices: THostVertices;
  Fields: TSourceImages;
  Layer: TMeshLayer;
  Size: TSize;
  Side: TImageSide;
  Textures: TMidpointPair;
  Blend: Single;
  T: TTriangle;
  Index, A, B, C, Count, Group: Integer;
  TrianglesByRegion: TArray<TArray<Integer>>;
  Triangle: TScreenTriangle;
  Candidate: TDetailCandidate;
  Candidates: TList<TDetailCandidate>;
begin
  if Assigned(Cancelled) and Cancelled() then Exit;
  Model.Refinement := Default(TMeshRefinement);
  Renderer := TMorphRenderer.Create;
  try
    Renderer.Prepare(Images, Model);
    if not Renderer.HostFrame(5000, Size, Vertices, Blend) then Exit;
    Layer := Renderer.Mesh(-1);
    for Side := Low(Side) to High(Side) do
    begin
      Fields[Side] := Renderer.ContourField(Side);
      if Fields[Side].Width = 0 then Exit;
    end;
    BuildMidpointTextures(Vertices, Size, Images, Fields, Textures);

    Candidates := TList<TDetailCandidate>.Create;
    try
      // Group 0 covers whole-image points. The other groups finish in the model's region order.
      SetLength(TrianglesByRegion, Length(Model.Regions) + 1);
      for Index := 0 to High(Layer.Triangles) do
      begin
        T := Layer.Triangles[Index];
        A := Layer.Vertices[T.A].PointIndex;
        B := Layer.Vertices[T.B].PointIndex;
        C := Layer.Vertices[T.C].PointIndex;
        if (Min(A, Min(B, C)) < 0) or (Model.Points[A].Region <> Model.Points[B].Region) or
          (Model.Points[A].Region <> Model.Points[C].Region) then Continue;
        Group := Model.Points[A].Region + 1;
        TrianglesByRegion[Group] := TrianglesByRegion[Group] + [Index];
      end;
      for Group := 0 to High(TrianglesByRegion) do
      begin
        if Assigned(Cancelled) and Cancelled() then Exit;
        for Index in TrianglesByRegion[Group] do
        begin
          if Assigned(Cancelled) and Cancelled() then Exit;
          Triangle := ScreenTriangle(Vertices[isA], Index, Size, Textures[isA].Width, Textures[isA].Height);
          if RefineTriangle(Textures, Triangle, Candidate) then
          begin
            Candidate.Detail.TriangleIndex := Index;
            Candidates.Add(Candidate);
          end;
        end;
        if (Group > 0) and Assigned(RegionReady) then RegionReady(Group - 1);
      end;
      if Candidates.Count = 0 then Exit;
      Candidates.Sort(TComparer<TDetailCandidate>.Construct(
        function(const L, R: TDetailCandidate): Integer
        begin
          Result := CompareValue(R.Score, L.Score, 1E-7);
          if Result = 0 then Result := L.Detail.TriangleIndex - R.Detail.TriangleIndex;
        end));
      Count := Min(Candidates.Count, MORPH_MAX_DETAILS);
      Model.Refinement.VertexCount := Length(Layer.Vertices);
      Model.Refinement.TriangleCount := Length(Layer.Triangles);
      SetLength(Model.Refinement.Details, Count);
      for Index := 0 to Count - 1 do Model.Refinement.Details[Index] := Candidates[Index].Detail;
    finally
      Candidates.Free;
    end;
  finally
    Renderer.Free;
  end;
end;

end.
