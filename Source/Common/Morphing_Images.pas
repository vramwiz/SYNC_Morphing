
unit Morphing_Images;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses System.Types, Vcl.Graphics, AviUtl2FilterTypes;

type
  TPixelBuffer = TArray<TPIXEL_RGBA>;
  TMorphImage = record
    Width, Height: Integer;
    Pixels: TPixelBuffer;
  end;
  TPremul = record
    R, G, B, A: Single;
  end;
  TSurfaceDistances = record
    Outline, Skin, Stroke: Single;
    class function Create(Outline, Skin, Stroke: Single): TSurfaceDistances; static;
  end;

function LoadImage(const FileName: string): TMorphImage;
function Sample(const Image: TMorphImage; const UV: TPointF): TPremul;
function SampleAlpha(const Image: TMorphImage; const UV: TPointF): Single;
function MixColor(const A, B: TPremul; T: Single): TPremul; inline;
function IsSkinTone(const P: TPIXEL_RGBA): Boolean;
function IsFabricPigment(const P: TPIXEL_RGBA): Boolean;
function BuildSilhouetteField(const Image: TMorphImage; PaleMatte: Boolean;
  MatchSkin: Boolean = False; FabricTop: Single = 0; FabricBottom: Single = 0): TMorphImage;
// RGB encodes signed distances for the outline, skin, and distinct internal texture respectively.
function SampleSilhouetteField(const Field: TMorphImage; const UV: TPointF): TSurfaceDistances;
function MorphSilhouette(const A, B: TPremul; const DA, DB: TSurfaceDistances; ShapeTime, ColorTime,
  Strength: Single; PaleMattes: Integer): TPremul;
function Pixel(const C: TPremul): TPIXEL_RGBA; inline;
procedure DrawBitmap(const Image: TMorphImage; Bitmap: Vcl.Graphics.TBitmap; Limit: Integer);
procedure SaveAnalysisPNG(const Image: TMorphImage; const FileName: string);

implementation

uses Winapi.Windows, Winapi.ActiveX, Winapi.Wincodec, System.SysUtils,
  System.Win.ComObj, System.Math, Vcl.Imaging.pngimage, Morphing_Model;

class function TSurfaceDistances.Create(Outline, Skin, Stroke: Single): TSurfaceDistances;
begin
  Result.Outline := Outline;
  Result.Skin := Skin;
  Result.Stroke := Stroke;
end;

function LoadImage(const FileName: string): TMorphImage;
var
  Factory: IWICImagingFactory;
  Decoder: IWICBitmapDecoder;
  Frame: IWICBitmapFrameDecode;
  Converter: IWICFormatConverter;
  Width, Height: Cardinal;
  HR: HRESULT;
begin
  Result := Default(TMorphImage);
  if FileName = '' then Exit;
  HR := CoInitializeEx(nil, COINIT_MULTITHREADED);
  if HR <> RPC_E_CHANGED_MODE then OleCheck(HR);
  try
    OleCheck(CoCreateInstance(CLSID_WICImagingFactory, nil, CLSCTX_INPROC_SERVER,
      IWICImagingFactory, Factory));
    OleCheck(Factory.CreateDecoderFromFilename(PChar(FileName), GUID_NULL, GENERIC_READ,
      WICDecodeMetadataCacheOnDemand, Decoder));
    OleCheck(Decoder.GetFrame(0, Frame));
    OleCheck(Frame.GetSize(Width, Height));
    if (Width = 0) or (Height = 0) or (Width > 16384) or (Height > 16384) or
      (Int64(Width) * Height > MORPH_MAX_PIXELS) then
      raise ERangeError.Create('画像の最大サイズは16,384px／辺、16,777,216画素です。');
    OleCheck(Factory.CreateFormatConverter(Converter));
    OleCheck(Converter.Initialize(Frame, GUID_WICPixelFormat32bppRGBA,
      WICBitmapDitherTypeNone, nil, 0, WICBitmapPaletteTypeCustom));
    Result.Width := Width;
    Result.Height := Height;
    SetLength(Result.Pixels, Integer(Width * Height));
    OleCheck(Converter.CopyPixels(nil, Width * 4, Width * Height * 4, PByte(@Result.Pixels[0])));
  finally
    Converter := nil;
    Frame := nil;
    Decoder := nil;
    Factory := nil;
    if Succeeded(HR) then CoUninitialize;
  end;
end;


function MixColor(const A, B: TPremul; T: Single): TPremul;
begin
  Result.R := A.R + (B.R - A.R) * T;
  Result.G := A.G + (B.G - A.G) * T;
  Result.B := A.B + (B.B - A.B) * T;
  Result.A := A.A + (B.A - A.A) * T;
end;



function Sample(const Image: TMorphImage; const UV: TPointF): TPremul;
var
  X, Y, U, V, A, B, C, D: Single;
  X0, Y0, X1, Y1: Integer;
  P0, P1, P2, P3: TPIXEL_RGBA;
begin
  if (Image.Width = 0) or (UV.X < 0) or (UV.X > 1) or (UV.Y < 0) or (UV.Y > 1) then
    Exit(Default(TPremul));
  X := EnsureRange(UV.X * Image.Width - 0.5, 0, Image.Width - 1);
  Y := EnsureRange(UV.Y * Image.Height - 0.5, 0, Image.Height - 1);
  X0 := Trunc(X);
  Y0 := Trunc(Y);
  X1 := Min(X0 + 1, Image.Width - 1);
  Y1 := Min(Y0 + 1, Image.Height - 1);
  U := X - X0;
  V := Y - Y0;
  Y0 := Y0 * Image.Width;
  Y1 := Y1 * Image.Width;
  P0 := Image.Pixels[Y0 + X0];
  P1 := Image.Pixels[Y0 + X1];
  P2 := Image.Pixels[Y1 + X0];
  P3 := Image.Pixels[Y1 + X1];
  A := (1 - U) * (1 - V);
  B := U * (1 - V);
  C := (1 - U) * V;
  D := U * V;
  if (P0.A and P1.A and P2.A and P3.A) = 255 then Result.A := 1
  else
  begin
    A := A * P0.A * (1 / 255);
    B := B * P1.A * (1 / 255);
    C := C * P2.A * (1 / 255);
    D := D * P3.A * (1 / 255);
    Result.A := A + B + C + D;
  end;
  Result.R := A * P0.R + B * P1.R + C * P2.R + D * P3.R;
  Result.G := A * P0.G + B * P1.G + C * P2.G + D * P3.G;
  Result.B := A * P0.B + B * P1.B + C * P2.B + D * P3.B;
end;

function SampleAlpha(const Image: TMorphImage; const UV: TPointF): Single;
var
  X, Y, U, V, Top, Bottom: Single;
  X0, X1, Y0, Y1: Integer;
  A, B, C, D: Byte;
begin
  if (Image.Width = 0) or (UV.X < 0) or (UV.X > 1) or (UV.Y < 0) or (UV.Y > 1) then Exit(0);
  X := EnsureRange(UV.X * Image.Width - 0.5, 0, Image.Width - 1);
  Y := EnsureRange(UV.Y * Image.Height - 0.5, 0, Image.Height - 1);
  X0 := Trunc(X);
  X1 := Min(X0 + 1, Image.Width - 1);
  Y0 := Trunc(Y);
  Y1 := Min(Y0 + 1, Image.Height - 1) * Image.Width;
  U := X - X0;
  V := Y - Y0;
  Y0 := Y0 * Image.Width;
  A := Image.Pixels[Y0 + X0].A;
  B := Image.Pixels[Y0 + X1].A;
  C := Image.Pixels[Y1 + X0].A;
  D := Image.Pixels[Y1 + X1].A;
  if (A = B) and (A = C) and (A = D) then Exit(A * (1 / 255));
  Top := A + (B - A) * U;
  Bottom := C + (D - C) * U;
  Result := (Top + (Bottom - Top) * V) * (1 / 255);
end;

function IsSkinTone(const P: TPIXEL_RGBA): Boolean;
begin
  Result := (P.A >= 175) and (P.R >= 145) and (P.G >= 95) and (P.R >= P.G + 9) and
    (P.G >= P.B + 4) and (P.R <= P.B + 95);
end;

function IsFabricPigment(const P: TPIXEL_RGBA): Boolean;
var
  Chroma, Luma: Single;
begin
  Chroma := Max(P.R, Max(P.G, P.B)) - Min(P.R, Min(P.G, P.B));
  Luma := 0.299 * P.R + 0.587 * P.G + 0.114 * P.B;
  Result := (P.A >= 176) and (Chroma >= 28) and (Luma >= 28) and (Luma <= 214) and not IsSkinTone(P);
end;

function BuildSilhouetteField(const Image: TMorphImage; PaleMatte, MatchSkin: Boolean;
  FabricTop, FabricBottom: Single): TMorphImage;
const
  Limit = 512;
  Radius = 20;
  Diagonal = 1.41421356;
type
  TColorFeatures = record
    Luma, Chroma1, Chroma2: Single;
  end;
var
  Width, Height, Count, X, Y, I, Head, Tail, ForegroundCount: Integer;
  Scale, InvAlpha: Single;
  Foreground, Pale, Skin, Strokes, Outside, Fabric: TArray<Boolean>;
  Queue: TArray<Integer>;
  Distances: TArray<Single>;
  Colors: TArray<TColorFeatures>;
  C: TPremul;

  procedure Enqueue(Index: Integer);
  begin
    if not Pale[Index] or not Foreground[Index] then Exit;
    Foreground[Index] := False;
    Queue[Tail] := Index;
    Inc(Tail);
  end;

  procedure Propagate(Row, Col, Step: Integer);
  var
    Here, Previous: Integer;
    Distance: Single;
  begin
    Here := Row * Width + Col;
    Distance := Distances[Here];
    if (Col - Step >= 0) and (Col - Step < Width) then
      Distance := Min(Distance, Distances[Here - Step] + 1);
    if (Row - Step >= 0) and (Row - Step < Height) then
    begin
      Previous := Here - Step * Width;
      Distance := Min(Distance, Distances[Previous] + 1);
      if Col > 0 then Distance := Min(Distance, Distances[Previous - 1] + Diagonal);
      if Col + 1 < Width then Distance := Min(Distance, Distances[Previous + 1] + Diagonal);
    end;
    Distances[Here] := Distance;
  end;



  function HasStroke(At, Offset: Integer): Boolean;
  var
    Center, Before, After: TColorFeatures;
    D0, D1, D2, E0, E1, E2, Len1, Len2, Dot: Single;
  begin
    Result := False;
    if not (Foreground[At - Offset] and Foreground[At + Offset]) then Exit;
    Center := Colors[At];
    Before := Colors[At - Offset];
    After := Colors[At + Offset];
    D0 := Center.Luma - Before.Luma;
    D1 := Center.Chroma1 - Before.Chroma1;
    D2 := Center.Chroma2 - Before.Chroma2;
    E0 := Center.Luma - After.Luma;
    E1 := Center.Chroma1 - After.Chroma1;
    E2 := Center.Chroma2 - After.Chroma2;
    Len1 := Sqr(D0) + Sqr(D1) + Sqr(D2);
    Len2 := Sqr(E0) + Sqr(E1) + Sqr(E2);
    if (Min(Len1, Len2) < 950) or (Max(Len1, Len2) > 4 * Min(Len1, Len2)) then Exit;
    Dot := D0 * E0 + D1 * E1 + D2 * E2;
    // A ridge has the same sign on both sides. A normal material boundary does not.
    Result := (Dot > 0) and (Sqr(Dot) >= 0.65 * Len1 * Len2);
  end;

  function HasStrokeAtScale(At, Distance: Integer): Boolean;
  begin
    Result := HasStroke(At, Distance) or HasStroke(At, Distance * Width) or
      HasStroke(At, Distance * (Width - 1)) or HasStroke(At, Distance * (Width + 1));
  end;

  procedure RemoveNoise(var Mask: TArray<Boolean>; MinimumPixels, MinimumSpan: Integer);
  var
    Visited: TArray<Boolean>;
    Seed, Index, Row, Col, DX, DY, Left, Right, Top, Bottom, K: Integer;

    procedure Visit(At: Integer);
    begin
      if not Mask[At] or Visited[At] then Exit;
      Visited[At] := True;
      Queue[Tail] := At;
      Inc(Tail);
    end;

  begin
    SetLength(Visited, Count);
    SetLength(Queue, Count);
    for Seed := 0 to Count - 1 do
    begin
      if Visited[Seed] or not Mask[Seed] then Continue;
      Head := 0;
      Tail := 0;
      Left := Width;
      Right := 0;
      Top := Height;
      Bottom := 0;
      Visit(Seed);
      while Head < Tail do
      begin
        Index := Queue[Head];
        Inc(Head);
        Row := Index div Width;
        Col := Index mod Width;
        Left := Min(Left, Col);
        Right := Max(Right, Col);
        Top := Min(Top, Row);
        Bottom := Max(Bottom, Row);
        for DY := Max(-1, -Row) to Min(1, Height - 1 - Row) do
          for DX := Max(-1, -Col) to Min(1, Width - 1 - Col) do
            Visit(Index + DY * Width + DX);
      end;
      if (Tail < MinimumPixels) or (Max(Right - Left, Bottom - Top) < MinimumSpan) then
        for K := 0 to Tail - 1 do Mask[Queue[K]] := False;
    end;
  end;

  procedure SmoothFabric;
  var
    Summed: TArray<Integer>;
    Pitch, Radius, Col, Row, Left, Right, Top, Bottom, Total, LineSum: Integer;
  begin
    // Suppress stitches, narrow gaps, and highlights before measuring the shape of a fabric panel.
    Pitch := Width + 1;
    Radius := Max(2, Max(Width, Height) div 76);
    SetLength(Summed, Pitch * (Height + 1));
    for Row := 1 to Height do
    begin
      LineSum := 0;
      for Col := 1 to Width do
      begin
        Inc(LineSum, Ord(Fabric[(Row - 1) * Width + Col - 1]));
        Summed[Row * Pitch + Col] := LineSum + Summed[(Row - 1) * Pitch + Col];
      end;
    end;
    for Row := 0 to Height - 1 do
    begin
      Top := Max(0, Row - Radius);
      Bottom := Min(Height, Row + Radius + 1);
      for Col := 0 to Width - 1 do
      begin
        Left := Max(0, Col - Radius);
        Right := Min(Width, Col + Radius + 1);
        Total := Summed[Bottom * Pitch + Right] - Summed[Bottom * Pitch + Left] -
          Summed[Top * Pitch + Right] + Summed[Top * Pitch + Left];
        Fabric[Row * Width + Col] := Foreground[Row * Width + Col] and
          (Total * 2 >= (Right - Left) * (Bottom - Top));
      end;
    end;
  end;

  procedure EncodeDistance(const Mask: TArray<Boolean>; Channel: Integer);
  var
    Col, Row, Index, DistanceLimit: Integer;
    Encoded: Byte;
  begin
    DistanceLimit := Radius;
    if Channel = 2 then DistanceLimit := 2 * Radius;
    SetLength(Distances, Count);
    for Row := 0 to Height - 1 do
      for Col := 0 to Width - 1 do
      begin
        Index := Row * Width + Col;
        Distances[Index] := DistanceLimit;
        if ((Col > 0) and (Mask[Index] <> Mask[Index - 1])) or
          ((Col + 1 < Width) and (Mask[Index] <> Mask[Index + 1])) or
          ((Row > 0) and (Mask[Index] <> Mask[Index - Width])) or
          ((Row + 1 < Height) and (Mask[Index] <> Mask[Index + Width])) then
          Distances[Index] := 0.5;
      end;
    for Row := 0 to Height - 1 do
      for Col := 0 to Width - 1 do Propagate(Row, Col, 1);
    for Row := Height - 1 downto 0 do
      for Col := Width - 1 downto 0 do Propagate(Row, Col, -1);
    for Index := 0 to Count - 1 do
    begin
      if not Mask[Index] then Distances[Index] := -Distances[Index];
      Encoded := Round(127.5 + Distances[Index] * (127.5 / DistanceLimit));
      case Channel of
        0:
          begin
            Result.Pixels[Index].R := Encoded;
            Result.Pixels[Index].A := 255;
          end;
        1: Result.Pixels[Index].G := Encoded;
        2: Result.Pixels[Index].B := Encoded;
      end;
    end;
  end;

  procedure FillSkinHoles;
  var
    Col, Row, Index, PreviousSkin, I: Integer;

    procedure Visit(Index: Integer);
    begin
      if Outside[Index] or Skin[Index] then Exit;
      Outside[Index] := True;
      Queue[Tail] := Index;
      Inc(Tail);
    end;

  begin
    // Bridge short gaps from eyelids or facial outlines within a skin scanline.
    for Row := 0 to Height - 1 do
    begin
      PreviousSkin := -1;
      for Col := 0 to Width - 1 do
      begin
        Index := Row * Width + Col;
        if not Skin[Index] or not Foreground[Index] then Continue;
        if (PreviousSkin >= 0) and (Col - PreviousSkin <= Max(2, Width div 10)) then
          for I := Row * Width + PreviousSkin + 1 to Index - 1 do Skin[I] := Foreground[I];
        PreviousSkin := Col;
      end;
    end;

    SetLength(Outside, Count);
    SetLength(Queue, Count);
    Head := 0;
    Tail := 0;
    for Index := 0 to Count - 1 do
      if not Foreground[Index] then
      begin
        Skin[Index] := False;
        Visit(Index);
      end;
    for Col := 0 to Width - 1 do
    begin
      Visit(Col);
      Visit(Count - Width + Col);
    end;
    for Row := 1 to Height - 2 do
    begin
      Visit(Row * Width);
      Visit((Row + 1) * Width - 1);
    end;
    while Head < Tail do
    begin
      Index := Queue[Head];
      Inc(Head);
      Col := Index mod Width;
      Row := Index div Width;
      if Col > 0 then Visit(Index - 1);
      if Col + 1 < Width then Visit(Index + 1);
      if Row > 0 then Visit(Index - Width);
      if Row + 1 < Height then Visit(Index + Width);
    end;
    // Eyes and mouth enclosed by the face belong to the same surface as the skin.
    for Index := 0 to Count - 1 do Skin[Index] := not Outside[Index];
  end;

begin
  Result := Default(TMorphImage);
  if (Image.Width < 3) or (Image.Height < 3) then Exit;
  Scale := Min(1, Limit / Max(Image.Width, Image.Height));
  Width := Max(3, Round(Image.Width * Scale));
  Height := Max(3, Round(Image.Height * Scale));
  Count := Width * Height;
  SetLength(Foreground, Count);
  SetLength(Strokes, Count);
  SetLength(Colors, Count);
  if PaleMatte then SetLength(Pale, Count);
  if MatchSkin then SetLength(Skin, Count);
  if FabricBottom > FabricTop then SetLength(Fabric, Count);
  for Y := 0 to Height - 1 do
    for X := 0 to Width - 1 do
    begin
      I := Y * Width + X;
      C := Sample(Image, PointF((X + 0.5) / Width, (Y + 0.5) / Height));
      Foreground[I] := C.A >= 0.5;
      if Foreground[I] then
      begin
        InvAlpha := 1 / C.A;
        Colors[I].Luma := (C.R * 0.299 + C.G * 0.587 + C.B * 0.114) * InvAlpha;
        Colors[I].Chroma1 := (C.R - C.B) * (0.5 * InvAlpha);
        Colors[I].Chroma2 := ((C.R + C.B) * 0.5 - C.G) * (0.55 * InvAlpha);
      end;
      if MatchSkin then Skin[I] := IsSkinTone(Pixel(C));
      if (Length(Fabric) > 0) and ((Y + 0.5) / Height >= FabricTop) and ((Y + 0.5) / Height <= FabricBottom) then
        Fabric[I] := IsFabricPigment(Pixel(C));
      if PaleMatte then
        Pale[I] := Min(C.R, Min(C.G, C.B)) >= 230 * C.A;
    end;
  if PaleMatte then
  begin
    SetLength(Queue, Count);
    Head := 0;
    Tail := 0;
    for X := 0 to Width - 1 do
    begin
      Enqueue(X);
      Enqueue(Count - Width + X);
    end;
    for Y := 1 to Height - 2 do
    begin
      Enqueue(Y * Width);
      Enqueue((Y + 1) * Width - 1);
    end;
    while Head < Tail do
    begin
      I := Queue[Head];
      Inc(Head);
      X := I mod Width;
      Y := I div Width;
      if X > 0 then Enqueue(I - 1);
      if X + 1 < Width then Enqueue(I + 1);
      if Y > 0 then Enqueue(I - Width);
      if Y + 1 < Height then Enqueue(I + Width);
    end;
  end;
  ForegroundCount := 0;
  for I := 0 to Count - 1 do Inc(ForegroundCount, Ord(Foreground[I]));
  // Evaluate narrow lines and slightly wider trim at the same bounded analysis resolution.
  for Y := 3 to Height - 4 do
    for X := 3 to Width - 4 do
    begin
      I := Y * Width + X;
      if not Foreground[I] then Continue;
      Strokes[I] := HasStrokeAtScale(I, 3);
      if not Strokes[I] and (X >= 6) and (X < Width - 6) and (Y >= 6) and (Y < Height - 6) then
        Strokes[I] := HasStrokeAtScale(I, 6);
    end;
  if (ForegroundCount < Max(1, Count div 40)) or (ForegroundCount > Count * 19 div 20) then Exit;

  Result.Width := Width;
  Result.Height := Height;
  SetLength(Result.Pixels, Count);
  EncodeDistance(Foreground, 0);
  if MatchSkin then
  begin
    RemoveNoise(Skin, Max(5, Count div 11000), 1);
    FillSkinHoles;
    EncodeDistance(Skin, 1);
  end;
  RemoveNoise(Strokes, Max(5, Max(Width, Height) div 24), Max(2, Max(Width, Height) div 76));
  if Length(Fabric) > 0 then
  begin
    SmoothFabric;
    RemoveNoise(Fabric, Max(22, Count div 1040), Max(4, Max(Width, Height) div 22));
    for I := 0 to Count - 1 do Strokes[I] := Strokes[I] or Fabric[I];
  end;
  EncodeDistance(Strokes, 2);
end;

function SampleSilhouetteField(const Field: TMorphImage; const UV: TPointF): TSurfaceDistances;
var
  X, Y, U, V, Top, Bottom: Single;
  X0, X1, Y0, Y1: Integer;
  P00, P10, P01, P11: TPIXEL_RGBA;
begin
  if (UV.X < 0) or (UV.X > 1) or (UV.Y < 0) or (UV.Y > 1) then Exit(TSurfaceDistances.Create(-0.5, -0.5, -0.5));
  X := EnsureRange(UV.X * Field.Width - 0.5, 0, Field.Width - 1);
  Y := EnsureRange(UV.Y * Field.Height - 0.5, 0, Field.Height - 1);
  X0 := Trunc(X);
  Y0 := Trunc(Y);
  X1 := Min(X0 + 1, Field.Width - 1);
  Y1 := Min(Y0 + 1, Field.Height - 1);
  U := X - X0;
  V := Y - Y0;
  Y0 := Y0 * Field.Width;
  Y1 := Y1 * Field.Width;
  P00 := Field.Pixels[Y0 + X0];
  P10 := Field.Pixels[Y0 + X1];
  P01 := Field.Pixels[Y1 + X0];
  P11 := Field.Pixels[Y1 + X1];
  if (Cardinal(P00) = Cardinal(P10)) and (Cardinal(P00) = Cardinal(P01)) and
    (Cardinal(P00) = Cardinal(P11)) then
    Exit(TSurfaceDistances.Create(P00.R * (1 / 255) - 0.5,
      P00.G * (1 / 255) - 0.5, P00.B * (2 / 255) - 1));
  Top := P00.R + (P10.R - P00.R) * U;
  Bottom := P01.R + (P11.R - P01.R) * U;
  Result.Outline := (Top + (Bottom - Top) * V) * (1 / 255) - 0.5;
  Top := P00.G + (P10.G - P00.G) * U;
  Bottom := P01.G + (P11.G - P01.G) * U;
  Result.Skin := (Top + (Bottom - Top) * V) * (1 / 255) - 0.5;
  Top := P00.B + (P10.B - P00.B) * U;
  Bottom := P01.B + (P11.B - P01.B) * U;
  Result.Stroke := (Top + (Bottom - Top) * V) * (2 / 255) - 1;
end;

function MorphSilhouette(const A, B: TPremul; const DA, DB: TSurfaceDistances; ShapeTime, ColorTime,
  Strength: Single; PaleMattes: Integer): TPremul;
var
  Coverage, AvailableA, AvailableB, Weight, Amount, Behind, InverseAlpha: Single;
  CA, CB, Foreground, Background, Endpoint: TPremul;

  function Edge(D: Single): Single; inline;
  begin
    Result := SmoothStep(EnsureRange(0.5 + 12 * D, 0, 1));
  end;

  function SameSurface(DistanceA, DistanceB: Single): Boolean; inline;
  begin
    Result := ((DistanceA <= -1 / 24) and (DistanceB <= -1 / 24)) or
      ((DistanceA >= 1 / 24) and (DistanceB >= 1 / 24));
  end;

  procedure MatchSurface(DistanceA, DistanceB: Single);
  var
    Surface, PartA, PartB, HitA, HitB: Single;
  begin
    if SameSurface(DistanceA, DistanceB) then Exit;
    Surface := Edge(DistanceA + (DistanceB - DistanceA) * ShapeTime);
    PartA := Edge(DistanceA);
    PartB := Edge(DistanceB);
    HitA := AvailableA * ((1 - Surface) * (1 - PartA) + Surface * PartA);
    HitB := AvailableB * ((1 - Surface) * (1 - PartB) + Surface * PartB);
    // A missing surface falls back to the nearest available warped texture.
    if HitA + HitB > 1E-5 then
    begin
      AvailableA := HitA;
      AvailableB := HitB;
    end;
  end;

begin
  if (Strength = 1) and (ShapeTime >= 1 / 16) and (ShapeTime <= 15 / 16) and
    (A.A >= 1) and (B.A >= 1) and (DA.Outline >= 1 / 24) and (DB.Outline >= 1 / 24) and
    SameSurface(DA.Skin, DB.Skin) and SameSurface(DA.Stroke, DB.Stroke) then
    Exit(MixColor(A, B, EnsureRange(ColorTime, 0.001, 0.999)));
  Coverage := Edge(DA.Outline + (DB.Outline - DA.Outline) * ShapeTime);
  AvailableA := A.A * Edge(DA.Outline);
  AvailableB := B.A * Edge(DB.Outline);
  Background.A := 0;
  if (PaleMattes and 1) <> 0 then Background.A := Background.A + A.A * (1 - ColorTime);
  if (PaleMattes and 2) <> 0 then Background.A := Background.A + B.A * ColorTime;
  Background.R := 253 * Background.A;
  Background.G := Background.R;
  Background.B := Background.R;
  Foreground := Background;
  if (Coverage > 0) and (AvailableA + AvailableB > 1E-5) then
  begin
    CA := A;
    CB := B;
    if (AvailableA > 0) and (A.A < 1) then
    begin
      InverseAlpha := 1 / A.A;
      CA.R := A.R * InverseAlpha;
      CA.G := A.G * InverseAlpha;
      CA.B := A.B * InverseAlpha;
    end;
    if (AvailableB > 0) and (B.A < 1) then
    begin
      InverseAlpha := 1 / B.A;
      CB.R := B.R * InverseAlpha;
      CB.G := B.G * InverseAlpha;
      CB.B := B.B * InverseAlpha;
    end;
    Amount := EnsureRange(ColorTime, 0.001, 0.999);
    MatchSurface(DA.Skin, DB.Skin);
    // The interpolated contour limits the texture that can paint this surface.
    // A displaced outline should not leave a second copy in the other surface's color.
    MatchSurface(DA.Stroke, DB.Stroke);
    Weight := AvailableB * Amount / (AvailableA * (1 - Amount) + AvailableB * Amount);
    if (A.A < 1) or (B.A < 1) then
    begin
      CA.A := Max(A.A, 1 - Edge(DA.Outline - 0.06));
      CB.A := Max(B.A, 1 - Edge(DB.Outline - 0.06));
      Coverage := Coverage * (CA.A + (CB.A - CA.A) * Weight);
    end;
    Foreground := MixColor(CA, CB, Weight);
    Behind := 1 - Coverage;
    Foreground.R := Foreground.R * Coverage + Background.R * Behind;
    Foreground.G := Foreground.G * Coverage + Background.G * Behind;
    Foreground.B := Foreground.B * Coverage + Background.B * Behind;
    Foreground.A := Coverage + Background.A * Behind;
  end;
  Result := Foreground;
  // Match the original matte near the endpoints without drawing the opposite texture there.
  if (ShapeTime < 1 / 16) or (ShapeTime > 15 / 16) then
  begin
    if ShapeTime < 0.5 then Endpoint := A else Endpoint := B;
    Result := MixColor(Endpoint, Foreground, SmoothStep(16 * Min(ShapeTime, 1 - ShapeTime)));
  end;
  if Strength < 1 then Result := MixColor(MixColor(A, B, ColorTime), Result, Strength);
end;

function Pixel(const C: TPremul): TPIXEL_RGBA;
var
  Inverse: Single;
begin
  Result := Default(TPIXEL_RGBA);
  Result.A := EnsureRange(Round(C.A * 255), 0, 255);
  if Result.A = 0 then Exit;
  if C.A >= 1 then Inverse := 1 else Inverse := 1 / C.A;
  Result.R := EnsureRange(Round(C.R * Inverse), 0, 255);
  Result.G := EnsureRange(Round(C.G * Inverse), 0, 255);
  Result.B := EnsureRange(Round(C.B * Inverse), 0, 255);
end;

procedure LimitSize(const Image: TMorphImage; Limit: Integer; out W, H: Integer);
var
  Factor: Double;
begin
  Factor := Min(1, Limit / Max(Image.Width, Image.Height));
  W := Max(1, Round(Image.Width * Factor));
  H := Max(1, Round(Image.Height * Factor));
end;

procedure DrawBitmap(const Image: TMorphImage; Bitmap: Vcl.Graphics.TBitmap; Limit: Integer);
var
  X, Y, W, H, Bg: Integer;
  Row: PByte;
  C: TPremul;
  U, V: Single;
begin
  if Image.Width = 0 then
  begin
    Bitmap.SetSize(0, 0);
    Exit;
  end;
  LimitSize(Image, Limit, W, H);
  Bitmap.PixelFormat := pf24bit;
  Bitmap.SetSize(W, H);
  for Y := 0 to H - 1 do
  begin
    // VCL の ScanLine[0] は表示上の先頭行。
    Row := Bitmap.ScanLine[Y];
    V := (Y + 0.5) / H;
    for X := 0 to W - 1 do
    begin
      U := (X + 0.5) / W;
      C := Sample(Image, PointF(U, V));
      Bg := 45 + ((X div 12 + Y div 12) and 1) * 18;
      Row^ := Round(C.B + Bg * (1 - C.A)); Inc(Row);
      Row^ := Round(C.G + Bg * (1 - C.A)); Inc(Row);
      Row^ := Round(C.R + Bg * (1 - C.A)); Inc(Row);
    end;
  end;
end;

procedure SaveAnalysisPNG(const Image: TMorphImage; const FileName: string);
var
  X, Y, W, H: Integer;
  Row, Alpha: PByte;
  P: TPIXEL_RGBA;
  PNG: TPngImage;
begin
  if Image.Width = 0 then raise EArgumentException.Create('画像Aと画像Bを指定してください。');
  LimitSize(Image, 1280, W, H);
  PNG := TPngImage.CreateBlank(COLOR_RGBALPHA, 8, W, H);
  try
    for Y := 0 to H - 1 do
    begin
      Row := PNG.Scanline[Y];
      Alpha := PByte(PNG.AlphaScanline[Y]);
      for X := 0 to W - 1 do
      begin
        P := Pixel(Sample(Image, PointF((X + 0.5) / W, (Y + 0.5) / H)));
        Row^ := P.B; Inc(Row);
        Row^ := P.G; Inc(Row);
        Row^ := P.R; Inc(Row);
        Alpha^ := P.A; Inc(Alpha);
      end;
    end;
    PNG.SaveToFile(FileName);
  finally
    PNG.Free;
  end;
end;

end.
