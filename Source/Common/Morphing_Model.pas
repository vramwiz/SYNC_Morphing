
unit Morphing_Model;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses System.Types;

const
  MORPH_MAX_REGIONS = 48;
  MORPH_MAX_POINTS = 384;
  MORPH_MAX_CONTOUR = 128;
  MORPH_MAX_KEYS = 64;
  MORPH_MAX_DETAILS = 64;
  MORPH_MAX_JSON = 1048576;
  MORPH_MAX_PIXELS = 16777216;

type
  TImageSide = (isA, isB);
  TRegionState = (rsMatch, rsAppear, rsDisappear, rsHidden, rsUnknown, rsExcluded);
  TPointPath = TArray<TPointF>;
  TUVPair = array[TImageSide] of TPointF;
  TTriangle = record
    A, B, C: Integer;
  end;
  TTriangles = TArray<TTriangle>;
  TMeshDetail = record
    TriangleIndex: Integer;
    Weights: TUVPair; // Barycentric weights of the second and third vertices.
  end;
  TMeshRefinement = record
    VertexCount, TriangleCount: Integer;
    Details: TArray<TMeshDetail>;
  end;
  TMeshTopology = record
    Region, VertexCount: Integer;
    Triangles: TTriangles;
  end;
  TSavedMesh = record
    Size: array[TImageSide] of TSize;
    Layers: TArray<TMeshTopology>;
  end;
  TMorphAlignment = record
    X, Y, Scale, Angle: Single;
  end;
  TMorphRegion = record
    Name: array[TImageSide] of string;
    State: TRegionState;
    Enabled, AutoGrid: Boolean;
    Z: Integer;
    Contour: array[TImageSide] of TPointPath;
  end;
  TMorphPoint = record
    Region: Integer; // -1: 全体メッシュ
    Has: array[TImageSide] of Boolean;
    UV: TUVPair;
  end;
  TCorrection = record
    Vertex: Integer;
    Position: TPointF;
  end;
  TShapeKey = record
    At: Integer; // 0.01%単位。端点は補正対象外。
    Points: TArray<TCorrection>;
  end;
  TMorphModel = record
    Subject: array[TImageSide] of string;
    Align: array[TImageSide] of TMorphAlignment;
    Shape, Mix, Feather: Single;
    Smooth, ShowMesh: Boolean;
    Quality: Integer;
    Regions: TArray<TMorphRegion>;
    Points: TArray<TMorphPoint>;
    Keys: TArray<TShapeKey>;
    Mesh: TSavedMesh;
    Refinement: TMeshRefinement;
    FabricY: TUVPair; // [top, bottom] of measured clothing in each input.
  end;

const
  RegionLabels: array[TRegionState] of string =
    ('対応', '出現', '消滅', '非表示', '不明', '対象外');

function DefaultModel: TMorphModel;
function ModelJSON(const M: TMorphModel): string;
function ReadModel(const JSON: string): TMorphModel;
function ReadAnalysis(const JSON: string): TMorphModel;
function ReadImportedModel(const JSON: string; out FromAnalysis: Boolean): TMorphModel;
procedure RemoveVertex(var M: TMorphModel; Vertex: Integer);
procedure RemoveRegion(var M: TMorphModel; Region: Integer);
function RegionCornerID(Region, Corner: Integer): Integer;
function FindKey(const M: TMorphModel; At: Integer): Integer;
function AddKey(var M: TMorphModel; At: Integer): Integer;
procedure SetCorrection(var K: TShapeKey; Vertex: Integer; const Position: TPointF);
function MixPoint(const A, B: TPointF; T: Single): TPointF;
function SmoothStep(T: Single): Single;

implementation

uses System.SysUtils, System.JSON, System.Math, System.Generics.Collections;

function DefaultModel: TMorphModel;
begin
  Result := Default(TMorphModel);
  Result.Shape := 1;
  Result.Mix := 1;
  Result.Feather := 2;
  Result.ShowMesh := True;
  Result.Quality := 1;
  Result.Align[isA].Scale := 1;
  Result.Align[isB].Scale := 1;
end;

function MixPoint(const A, B: TPointF; T: Single): TPointF;
begin
  Result := PointF(A.X + (B.X - A.X) * T, A.Y + (B.Y - A.Y) * T);
end;

function SmoothStep(T: Single): Single;
begin
  Result := T * T * (3 - 2 * T);
end;

function PointJSON(const P: TPointF): TJSONArray;
begin
  Result := TJSONArray.Create;
  Result.Add(Double(P.X));
  Result.Add(Double(P.Y));
end;

function PathJSON(const P: TPointPath): TJSONArray;
var
  V: TPointF;
begin
  Result := TJSONArray.Create;
  for V in P do
    Result.AddElement(PointJSON(V));
end;

function ModelJSON(const M: TMorphModel): string;
var
  Root, Obj: TJSONObject;
  Aligns, Regions, Points, Keys, Entries, Layers, A: TJSONArray;
  Side: TImageSide;
  R: TMorphRegion;
  P: TMorphPoint;
  K: TShapeKey;
  C: TCorrection;
  Layer: TMeshTopology;
  Triangle: TTriangle;
  Detail: TMeshDetail;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('v', 1);
    Root.AddPair('subjectA', M.Subject[isA]);
    Root.AddPair('subjectB', M.Subject[isB]);
    Root.AddPair('shape', Double(M.Shape));
    Root.AddPair('mix', Double(M.Mix));
    Root.AddPair('feather', Double(M.Feather));
    Root.AddPair('smooth', M.Smooth);
    Root.AddPair('quality', M.Quality);
    Root.AddPair('showMesh', M.ShowMesh);
    Aligns := TJSONArray.Create;
    Root.AddPair('align', Aligns);
    for Side := Low(Side) to High(Side) do
    begin
      A := TJSONArray.Create;
      Aligns.AddElement(A);
      A.Add(Double(M.Align[Side].X));
      A.Add(Double(M.Align[Side].Y));
      A.Add(Double(M.Align[Side].Scale));
      A.Add(Double(M.Align[Side].Angle));
    end;
    Regions := TJSONArray.Create;
    Root.AddPair('regions', Regions);
    for R in M.Regions do
    begin
      Obj := TJSONObject.Create;
      Regions.AddElement(Obj);
      Obj.AddPair('nameA', R.Name[isA]);
      Obj.AddPair('nameB', R.Name[isB]);
      Obj.AddPair('state', Ord(R.State));
      Obj.AddPair('enabled', R.Enabled);
      if R.AutoGrid then Obj.AddPair('autoGrid', True);
      Obj.AddPair('z', R.Z);
      Obj.AddPair('a', PathJSON(R.Contour[isA]));
      Obj.AddPair('b', PathJSON(R.Contour[isB]));
    end;
    Points := TJSONArray.Create;
    Root.AddPair('points', Points);
    for P in M.Points do
    begin
      Obj := TJSONObject.Create;
      Points.AddElement(Obj);
      Obj.AddPair('region', P.Region);
      if P.Has[isA] then Obj.AddPair('a', PointJSON(P.UV[isA]))
      else Obj.AddPair('a', TJSONNull.Create);
      if P.Has[isB] then Obj.AddPair('b', PointJSON(P.UV[isB]))
      else Obj.AddPair('b', TJSONNull.Create);
    end;
    Keys := TJSONArray.Create;
    Root.AddPair('keys', Keys);
    for K in M.Keys do
    begin
      Obj := TJSONObject.Create;
      Keys.AddElement(Obj);
      Obj.AddPair('at', K.At);
      Entries := TJSONArray.Create;
      Obj.AddPair('points', Entries);
      for C in K.Points do
      begin
        A := PointJSON(C.Position);
        A.Add(C.Vertex);
        Entries.AddElement(A);
      end;
    end;
    if (M.FabricY[isA].X < M.FabricY[isA].Y) and (M.FabricY[isB].X < M.FabricY[isB].Y) then
    begin
      A := TJSONArray.Create;
      Root.AddPair('fabricY', A);
      for Side := Low(Side) to High(Side) do A.AddElement(PointJSON(M.FabricY[Side]));
    end;
    if Length(M.Refinement.Details) > 0 then
    begin
      Obj := TJSONObject.Create;
      Root.AddPair('refinement', Obj);
      Obj.AddPair('vertices', M.Refinement.VertexCount);
      Obj.AddPair('triangles', M.Refinement.TriangleCount);
      Entries := TJSONArray.Create;
      Obj.AddPair('details', Entries);
      for Detail in M.Refinement.Details do
      begin
        A := TJSONArray.Create;
        Entries.AddElement(A);
        A.Add(Detail.TriangleIndex);
        A.AddElement(PointJSON(Detail.Weights[isA]));
        A.AddElement(PointJSON(Detail.Weights[isB]));
      end;
    end;
    if Length(M.Mesh.Layers) > 0 then
    begin
      A := TJSONArray.Create;
      Root.AddPair('meshSize', A);
      for Side := Low(Side) to High(Side) do
      begin
        A.Add(M.Mesh.Size[Side].cx);
        A.Add(M.Mesh.Size[Side].cy);
      end;
      Layers := TJSONArray.Create;
      Root.AddPair('mesh', Layers);
      for Layer in M.Mesh.Layers do
      begin
        Obj := TJSONObject.Create;
        Layers.AddElement(Obj);
        Obj.AddPair('region', Layer.Region);
        Obj.AddPair('vertices', Layer.VertexCount);
        Entries := TJSONArray.Create;
        Obj.AddPair('triangles', Entries);
        for Triangle in Layer.Triangles do
        begin
          A := TJSONArray.Create;
          Entries.AddElement(A);
          A.Add(Triangle.A);
          A.Add(Triangle.B);
          A.Add(Triangle.C);
        end;
      end;
    end;
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure BadData(const Field: string);
begin
  raise EConvertError.Create('モーフィングJSONの項目が無効です（' + Field + '）。');
end;

function RequireObject(V: TJSONValue; const Field: string): TJSONObject;
begin
  if not (V is TJSONObject) then BadData(Field);
  Result := TJSONObject(V);
end;

function RequireArray(V: TJSONValue; Limit: Integer; const Field: string): TJSONArray;
begin
  if not (V is TJSONArray) then BadData(Field);
  Result := TJSONArray(V);
  if Result.Count > Limit then BadData(Field);
end;

function Number(V: TJSONValue; MinValue, MaxValue: Double; const Field: string): Double;
begin
  if not (V is TJSONNumber) then BadData(Field);
  Result := TJSONNumber(V).AsDouble;
  if IsNan(Result) or IsInfinite(Result) or (Result < MinValue) or (Result > MaxValue) then BadData(Field);
end;

function IntegerValue(V: TJSONValue; MinValue, MaxValue: Integer; const Field: string): Integer;
var
  N: Double;
begin
  N := Number(V, MinValue, MaxValue, Field);
  Result := Trunc(N);
  if N <> Result then BadData(Field);
end;

function TextValue(V: TJSONValue; const Field: string): string;
begin
  if not (V is TJSONString) then BadData(Field);
  Result := Trim(V.Value);
  if Length(Result) > 128 then BadData(Field);
end;

function BoolValue(V: TJSONValue; const Field: string): Boolean;
begin
  if not (V is TJSONBool) then BadData(Field);
  Result := TJSONBool(V).AsBoolean;
end;

function ReadPoint(V: TJSONValue; const Field: string): TPointF;
var
  A: TJSONArray;
begin
  A := RequireArray(V, 2, Field);
  if A.Count <> 2 then BadData(Field);
  Result := PointF(Number(A.Items[0], 0, 1, Field), Number(A.Items[1], 0, 1, Field));
end;

function ReadPath(V: TJSONValue; const Field: string): TPointPath;
var
  A: TJSONArray;
  I: Integer;
begin
  A := RequireArray(V, MORPH_MAX_CONTOUR, Field);
  SetLength(Result, A.Count);
  for I := 0 to A.Count - 1 do
    Result[I] := ReadPoint(A.Items[I], Field);
end;

function RegionCornerID(Region, Corner: Integer): Integer;
begin
  Result := -2 - (Region * 4 + Corner);
end;

function FindKey(const M: TMorphModel; At: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(M.Keys) do
    if M.Keys[I].At = At then Exit(I);
  Result := -1;
end;

function AddKey(var M: TMorphModel; At: Integer): Integer;
var
  K: TShapeKey;
begin
  Result := FindKey(M, At);
  if Result >= 0 then Exit;
  if (At <= 0) or (At >= 10000) or (Length(M.Keys) >= MORPH_MAX_KEYS) then
    raise EArgumentException.Create('補正キーは0%と100%の間に追加してください（最大64個）。');
  K := Default(TShapeKey);
  K.At := At;
  Result := Length(M.Keys);
  M.Keys := M.Keys + [K];
end;

procedure SetCorrection(var K: TShapeKey; Vertex: Integer; const Position: TPointF);
var
  I: Integer;
  C: TCorrection;
begin
  for I := 0 to High(K.Points) do
    if K.Points[I].Vertex = Vertex then
    begin
      K.Points[I].Position := Position;
      Exit;
    end;
  C.Vertex := Vertex;
  C.Position := Position;
  K.Points := K.Points + [C];
end;

procedure RemoveVertex(var M: TMorphModel; Vertex: Integer);
var
  K, I: Integer;
begin
  if (Vertex < 0) or (Vertex > High(M.Points)) then Exit;
  Delete(M.Points, Vertex, 1);
  M.Mesh.Layers := nil;
  M.Refinement := Default(TMeshRefinement);
  for K := 0 to High(M.Keys) do
    for I := High(M.Keys[K].Points) downto 0 do
      if M.Keys[K].Points[I].Vertex = Vertex then Delete(M.Keys[K].Points, I, 1)
      else if M.Keys[K].Points[I].Vertex > Vertex then Dec(M.Keys[K].Points[I].Vertex);
end;

procedure RemoveRegion(var M: TMorphModel; Region: Integer);
var
  I, K, Vertex, CornerRegion: Integer;
begin
  if (Region < 0) or (Region > High(M.Regions)) then Exit;
  Delete(M.Regions, Region, 1);
  M.Mesh.Layers := nil;
  M.Refinement := Default(TMeshRefinement);
  for I := High(M.Points) downto 0 do
    if M.Points[I].Region = Region then RemoveVertex(M, I)
    else if M.Points[I].Region > Region then Dec(M.Points[I].Region);
  for K := 0 to High(M.Keys) do
    for I := High(M.Keys[K].Points) downto 0 do
    begin
      Vertex := M.Keys[K].Points[I].Vertex;
      if Vertex >= -1 then Continue;
      CornerRegion := (-2 - Vertex) div 4;
      if CornerRegion = Region then Delete(M.Keys[K].Points, I, 1)
      else if CornerRegion > Region then Inc(M.Keys[K].Points[I].Vertex, 4);
    end;
end;

procedure CheckJSONDepth(const Text: string);
var
  C: Char;
  Nesting: Integer;
  InString, Escaped: Boolean;
begin
  Nesting := 0;
  InString := False;
  Escaped := False;
  for C in Text do
    if InString then
    begin
      if Escaped then Escaped := False
      else if C = '\' then Escaped := True
      else if C = '"' then InString := False;
    end
    else
      case C of
        '"': InString := True;
        '{', '[':
          begin
            Inc(Nesting);
            if Nesting > 24 then BadData('階層');
          end;
        '}', ']': Dec(Nesting);
      end;
end;

type
  TJSONMode = (jmSettings, jmAnalysis, jmImport);

function DecodeModel(const JSON: string; Mode: TJSONMode; out IsAnalysis: Boolean): TMorphModel;
const
  SideNames: array[TImageSide] of string = ('a', 'b');
  NameFields: array[TImageSide] of string = ('nameA', 'nameB');
var
  Root, Obj: TJSONObject;
  Parsed, V: TJSONValue;
  A, Entries, E: TJSONArray;
  Side: TImageSide;
  I, J, N, Key, MinVertex, VertexCount: Integer;
  Seen: TArray<Boolean>;
  Pos: TPointF;
  Field: string;
  Layer: TMeshTopology;
  Triangle: TTriangle;
begin
  Result := DefaultModel;
  IsAnalysis := Mode = jmAnalysis;
  if (JSON = '') and (Mode = jmSettings) then Exit;
  if Length(JSON) > MORPH_MAX_JSON then BadData('サイズ');
  CheckJSONDepth(JSON);
  Parsed := TJSONObject.ParseJSONValue(JSON, True, False);
  try
    Root := RequireObject(Parsed, 'root');
    if Mode = jmImport then IsAnalysis := Root.Values['shape'] = nil;
    IntegerValue(Root.Values['v'], 1, 1, 'v');
    Result.Subject[isA] := TextValue(Root.Values['subjectA'], 'subjectA');
    Result.Subject[isB] := TextValue(Root.Values['subjectB'], 'subjectB');
    A := RequireArray(Root.Values['regions'], MORPH_MAX_REGIONS, 'regions');
    SetLength(Result.Regions, A.Count);
    for I := 0 to A.Count - 1 do
    begin
      Obj := RequireObject(A.Items[I], 'region');
      for Side := Low(Side) to High(Side) do
      begin
        Result.Regions[I].Name[Side] := TextValue(Obj.Values[NameFields[Side]], NameFields[Side]);
        Result.Regions[I].Contour[Side] := ReadPath(Obj.Values[SideNames[Side]], SideNames[Side]);
      end;
      Result.Regions[I].State := TRegionState(IntegerValue(Obj.Values['state'], 0, Ord(High(TRegionState)), 'state'));
      Result.Regions[I].Enabled := BoolValue(Obj.Values['enabled'], 'enabled');
      if Obj.Values['autoGrid'] <> nil then
        Result.Regions[I].AutoGrid := BoolValue(Obj.Values['autoGrid'], 'autoGrid');
      Result.Regions[I].Z := IntegerValue(Obj.Values['z'], -10000, 10000, 'z');
    end;
    A := RequireArray(Root.Values['points'], MORPH_MAX_POINTS, 'points');
    SetLength(Result.Points, A.Count);
    for I := 0 to A.Count - 1 do
    begin
      Obj := RequireObject(A.Items[I], 'point');
      Result.Points[I].Region := IntegerValue(Obj.Values['region'], -1, High(Result.Regions), 'region');
      for Side := Low(Side) to High(Side) do
      begin
        Field := SideNames[Side];
        V := Obj.Values[Field];
        if V is TJSONNull then Continue;
        Result.Points[I].UV[Side] := ReadPoint(V, Field);
        Result.Points[I].Has[Side] := True;
      end;
      if not (Result.Points[I].Has[isA] or Result.Points[I].Has[isB]) then BadData('point');
    end;
    if IsAnalysis then Exit;
    Result.Shape := Number(Root.Values['shape'], 0, 1, 'shape');
    Result.Mix := Number(Root.Values['mix'], 0, 1, 'mix');
    Result.Feather := Number(Root.Values['feather'], 0, 32, 'feather');
    Result.Smooth := BoolValue(Root.Values['smooth'], 'smooth');
    Result.ShowMesh := BoolValue(Root.Values['showMesh'], 'showMesh');
    Result.Quality := IntegerValue(Root.Values['quality'], 0, 2, 'quality');
    A := RequireArray(Root.Values['align'], 2, 'align');
    if A.Count <> 2 then BadData('align');
    for Side := Low(Side) to High(Side) do
    begin
      E := RequireArray(A.Items[Ord(Side)], 4, 'align');
      if E.Count <> 4 then BadData('align');
      Result.Align[Side].X := Number(E.Items[0], -2, 2, 'align X');
      Result.Align[Side].Y := Number(E.Items[1], -2, 2, 'align Y');
      Result.Align[Side].Scale := Number(E.Items[2], 0.05, 8, 'align Scale');
      Result.Align[Side].Angle := Number(E.Items[3], -360, 360, 'align Angle');
    end;
    MinVertex := RegionCornerID(Length(Result.Regions), 0) + 1;
    VertexCount := Length(Result.Points) - MinVertex;
    A := RequireArray(Root.Values['keys'], MORPH_MAX_KEYS, 'keys');
    for I := 0 to A.Count - 1 do
    begin
      Obj := RequireObject(A.Items[I], 'key');
      N := IntegerValue(Obj.Values['at'], 1, 9999, 'at');
      if FindKey(Result, N) >= 0 then BadData('at');
      Key := AddKey(Result, N);
      Entries := RequireArray(Obj.Values['points'], VertexCount - 1, 'corrections');
      Seen := nil;
      SetLength(Seen, VertexCount);
      for J := 0 to Entries.Count - 1 do
      begin
        E := RequireArray(Entries.Items[J], 3, 'correction');
        if E.Count <> 3 then BadData('correction');
        Pos := PointF(Number(E.Items[0], -4, 5, 'key x'), Number(E.Items[1], -4, 5, 'key y'));
        N := IntegerValue(E.Items[2], MinVertex, High(Result.Points), 'vertex');
        if (N = -1) or Seen[N - MinVertex] then BadData('vertex');
        Seen[N - MinVertex] := True;
        SetCorrection(Result.Keys[Key], N, Pos);
      end;
    end;
    if Root.Values['fabricY'] <> nil then
    begin
      A := RequireArray(Root.Values['fabricY'], 2, 'fabricY');
      if A.Count <> 2 then BadData('fabricY');
      for Side := Low(Side) to High(Side) do
      begin
        Pos := ReadPoint(A.Items[Ord(Side)], 'fabricY');
        if (Pos.X < 0) or (Pos.Y > 1) or (Pos.X >= Pos.Y) then BadData('fabricY');
        Result.FabricY[Side] := Pos;
      end;
    end;
    if Root.Values['refinement'] <> nil then
    begin
      Obj := RequireObject(Root.Values['refinement'], 'refinement');
      Result.Refinement.VertexCount := IntegerValue(Obj.Values['vertices'], 4,
        Length(Result.Points) * 2 + 4, 'refinement vertices');
      Result.Refinement.TriangleCount := IntegerValue(Obj.Values['triangles'], 1,
        Result.Refinement.VertexCount * 2, 'refinement triangles');
      Entries := RequireArray(Obj.Values['details'], MORPH_MAX_DETAILS, 'refinement details');
      SetLength(Result.Refinement.Details, Entries.Count);
      Seen := nil;
      SetLength(Seen, Result.Refinement.TriangleCount);
      for I := 0 to Entries.Count - 1 do
      begin
        E := RequireArray(Entries.Items[I], 3, 'refinement detail');
        if E.Count <> 3 then BadData('refinement detail');
        N := IntegerValue(E.Items[0], 0, High(Seen), 'refinement triangle');
        if Seen[N] then BadData('refinement triangle');
        Seen[N] := True;
        Result.Refinement.Details[I].TriangleIndex := N;
        for Side := Low(Side) to High(Side) do
        begin
          Pos := ReadPoint(E.Items[Ord(Side) + 1], 'refinement weights');
          if (Pos.X < 0.02) or (Pos.Y < 0.02) or (Pos.X + Pos.Y > 0.98) then
            BadData('refinement weights');
          Result.Refinement.Details[I].Weights[Side] := Pos;
        end;
      end;
    end;
    if Root.Values['mesh'] <> nil then
    begin
      A := RequireArray(Root.Values['meshSize'], 4, 'meshSize');
      if A.Count <> 4 then BadData('meshSize');
      for Side := Low(Side) to High(Side) do
      begin
        Result.Mesh.Size[Side].cx := IntegerValue(A.Items[Ord(Side) * 2], 0, 16384, 'mesh width');
        Result.Mesh.Size[Side].cy := IntegerValue(A.Items[Ord(Side) * 2 + 1], 0, 16384, 'mesh height');
      end;
      A := RequireArray(Root.Values['mesh'], Length(Result.Regions) + 1, 'mesh');
      SetLength(Result.Mesh.Layers, A.Count);
      Seen := nil;
      SetLength(Seen, Length(Result.Regions) + 1);
      for I := 0 to A.Count - 1 do
      begin
        Layer := Default(TMeshTopology);
        Obj := RequireObject(A.Items[I], 'mesh layer');
        Layer.Region := IntegerValue(Obj.Values['region'], -1, High(Result.Regions), 'mesh region');
        if Seen[Layer.Region + 1] then BadData('mesh region');
        Seen[Layer.Region + 1] := True;
        Layer.VertexCount := IntegerValue(Obj.Values['vertices'], 4, Length(Result.Points) * 2 + 4, 'mesh vertices');
        Entries := RequireArray(Obj.Values['triangles'], Layer.VertexCount * 2, 'mesh triangles');
        SetLength(Layer.Triangles, Entries.Count);
        for J := 0 to Entries.Count - 1 do
        begin
          E := RequireArray(Entries.Items[J], 3, 'mesh triangle');
          if E.Count <> 3 then BadData('mesh triangle');
          Triangle.A := IntegerValue(E.Items[0], 0, Layer.VertexCount - 1, 'triangle index');
          Triangle.B := IntegerValue(E.Items[1], 0, Layer.VertexCount - 1, 'triangle index');
          Triangle.C := IntegerValue(E.Items[2], 0, Layer.VertexCount - 1, 'triangle index');
          if (Triangle.A = Triangle.B) or (Triangle.B = Triangle.C) or (Triangle.C = Triangle.A) then BadData('mesh triangle');
          Layer.Triangles[J] := Triangle;
        end;
        Result.Mesh.Layers[I] := Layer;
      end;
    end;
  finally
    Parsed.Free;
  end;
end;

function ReadModel(const JSON: string): TMorphModel;
var
  IsAnalysis: Boolean;
begin
  Result := DecodeModel(JSON, jmSettings, IsAnalysis);
end;

function ReadAnalysis(const JSON: string): TMorphModel;
var
  IsAnalysis: Boolean;
begin
  Result := DecodeModel(JSON, jmAnalysis, IsAnalysis);
end;

function ReadImportedModel(const JSON: string; out FromAnalysis: Boolean): TMorphModel;
begin
  Result := DecodeModel(JSON, jmImport, FromAnalysis);
end;

end.
