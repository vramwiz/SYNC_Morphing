
program Morphing_Tests;

// SPDX-License-Identifier: GPL-3.0-only
{$APPTYPE CONSOLE}
{$RANGECHECKS ON}

uses
  Winapi.Windows, Winapi.Messages, Winapi.CommCtrl, System.SysUtils, System.Types, System.Math, System.IOUtils,
  System.Classes, System.Win.Registry,
  Vcl.Forms, Vcl.Controls, Vcl.Imaging.pngimage, Vcl.Graphics, Vcl.StdCtrls, Vcl.Themes, Vcl.Menus, Vcl.ComCtrls, Vcl.ExtCtrls,
  AviUtl2FilterTypes, Morphing_Model, Morphing_Images, Morphing_Mesh,
  Morphing_Renderer, Morphing_Analysis, Morphing_AutoDetect, Morphing_Registration, Morphing_Window, Morphing_Viewport;

type
  TGetTable = function: PFILTER_PLUGIN_TABLE; cdecl;
  TRequired = function: Cardinal; cdecl;
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TUninitialize = procedure; cdecl;
  TAnalysisTest = (atNone, atLocal, atCodex, atCodexCancel);
  TControlAccess = class(TWinControl);
  TFontFixture = class(TMorphWindow)
  public
    procedure Verify;
  end;
  TItem = ^THeader;
  THeader = record
    Kind, Name: PWideChar;
  end;

function PrintWindow(Window: HWND; DC: HDC; Flags: UINT): BOOL; stdcall; external 'user32.dll';

var
  Captured: TMorphImage;
  Saved: UTF8String;
  Timer: UINT_PTR;
  ChangeMesh, ConfirmEditor, CloseViaTitle, EditorSeen, CommandFound, DragPartPoint: Boolean;
  AnalysisTest: TAnalysisTest;
  AwaitAnalysis: TAnalysisTest;
  AwaitDeadline: UInt64;
  NativeResources, NativeTriangles, NativeMixes, NativeUploads: Integer;
  NativeContourUploads: Integer;
  NativeContours: TArray<string>;
  SaveCalls: Integer;
  Snapshot, LayoutError: string;
  LayoutChecks, ContextMenuCount, Checks: Integer;

function HasSwitch(const Name: string): Boolean;
begin
  Result := FindCmdLineSwitch(Name) or FindCmdLineSwitch('-' + Name);
end;

procedure Check(Condition: Boolean; const Test: string);
begin
  if not Condition then raise Exception.Create('FAILED ' + Test);
  Inc(Checks);
end;

procedure TFontFixture.Verify;
var
  CaptionLabel: TLabel;
  Button: TButton;
begin
  Font.Name := 'Yu Gothic UI';
  Font.PixelsPerInch := USER_DEFAULT_SCREEN_DPI;
  Font.Size := 10;
  CaptionLabel := TLabel.Create(Self);
  CaptionLabel.Parent := Self;
  CaptionLabel.Caption := '画像A  日本語の見出し';
  Button := TButton.Create(Self);
  Button.Parent := Self;
  CenterOnMonitor(440, 250);
  for var DPI in [96, 120, 144, 192] do
  begin
    ScaleForPPI(DPI);
    Check(CaptionLabel.ParentFont and (CaptionLabel.Font.Height = Button.Font.Height),
      'captions inherit the button font size during DPI changes');
  end;
end;

procedure TestInheritedFont(Plugin: HMODULE);
var
  Fixture: TFontFixture;
begin
  if TStyleManager.Style['Windows Modern Dark'] = nil then
    TStyleManager.LoadFromResource(Plugin, 'WINDOWSMODERNDARK', 'VCLSTYLE');
  Fixture := TFontFixture.CreateNew(nil);
  try
    Fixture.Verify;
  finally
    Fixture.Free;
  end;
end;

procedure CaptureImage(P: PPIXEL_RGBA; W, H: Integer); cdecl;
begin
  Captured.Width := W;
  Captured.Height := H;
  if P = nil then
  begin
    Inc(NativeUploads);
    Exit;
  end;
  SetLength(Captured.Pixels, W * H);
  Move(P^, Captured.Pixels[0], W * H * SizeOf(TPIXEL_RGBA));
end;

procedure SetNativeSampler(Mode: Integer); cdecl;
begin
end;

procedure SetNativeCulling(Enabled: Byte); cdecl;
begin
end;

procedure CreateNativeResource(Name: PWideChar; Pixels: PPIXEL_RGBA; Width, Height: Integer); cdecl;
begin
  if (Width <> 96) or (Height <> 96) then Exit;
  if Pixels = nil then Inc(NativeResources)
  else if string(Name).StartsWith('cache:SYNC_Morphing_contour_') then
  begin
    Inc(NativeContourUploads);
    NativeContours := NativeContours + [string(Name)];
  end;
end;

function ClearNativeResource(Name: PWideChar; Color: TPIXEL_RGBA): Byte; cdecl;
begin
  Result := Ord(Color.A = 0);
end;

function NativeImageSize(Name: PWideChar; out Width, Height: Integer): Byte; cdecl;
begin
  Width := 96;
  Height := 96;
  Result := Ord(string(Name).StartsWith('image:'));
  for var Contour in NativeContours do
    if string(Name) = Contour then Exit(1);
end;

function DrawNativeMesh(Destination: PWideChar; Kind: Integer; Vertices: Pointer;
  Count: Integer; Source: PWideChar): Byte; cdecl;
var
  V: ^THostVertex;
  I: Integer;
begin
  Result := Ord((Kind = 3) and (Count > 6) and (Count mod 3 = 0));
  if Result = 0 then Exit;
  V := Vertices;
  for I := 0 to Count - 1 do
  begin
    if Abs((V^.X + 48) / 96 - V^.U) > 0.05 then
    begin
      Inc(NativeTriangles);
      Exit;
    end;
    Inc(V);
  end;
end;

function MixNativeShader(Data: Pointer; DataSize: Integer; Target: PWideChar;
  ResourceList: Pointer; ResourceCount: Integer; Constants: Pointer; ConstantSize: Integer;
  Blend, Sampler: Pointer): Byte; cdecl;
begin
  Result := Ord((DataSize > 32) and (PCardinal(Data)^ = $43425844) and (string(Target) = 'object') and
    (ResourceCount = 4) and (ConstantSize = 32) and SameValue(PSingle(Constants)^, 0.5) and
    SameValue(PSingle(PByte(Constants) + 16)^, 0.5) and SameValue(PSingle(PByte(Constants) + 20)^, 1));
  if Result <> 0 then Inc(NativeMixes);
end;

function ReadItem(Obj: OBJECT_HANDLE; Effect, Item: PWideChar): PAnsiChar; cdecl;
begin
  Result := PAnsiChar(Saved);
end;

function SaveItem(Obj: OBJECT_HANDLE; Effect, Item: PWideChar; Value: PAnsiChar): Boolean; cdecl;
begin
  Saved := UTF8String(Value);
  Inc(SaveCalls);
  Result := True;
end;

function FocusObject: OBJECT_HANDLE; cdecl;
begin
  Result := Pointer(1);
end;

function CountMorphEffects(Obj: OBJECT_HANDLE; Effect: PWideChar): Integer; cdecl;
begin
  Result := Ord((Obj = Pointer(1)) and (string(Effect) = 'モーフィング'));
end;

function HasItemKind(Table: PFILTER_PLUGIN_TABLE; const Kind: string): Boolean;
var
  Entry: PPointer;
begin
  Entry := PPointer(Table^.Items);
  while Entry^ <> nil do
  begin
    if string(TItem(Entry^)^.Kind) = Kind then Exit(True);
    Inc(Entry);
  end;
  Result := False;
end;

function FindItem(Table: PFILTER_PLUGIN_TABLE; const Name: string): Pointer;
var
  Entry: PPointer;
begin
  Entry := PPointer(Table^.Items);
  while Entry^ <> nil do
  begin
    if string(TItem(Entry^)^.Name) = Name then Exit(Entry^);
    Inc(Entry);
  end;
  raise Exception.Create('Missing SDK item ' + Name);
end;

procedure MakeImage(const Path: string; W, H: Integer; CX, CY: Single; IsB: Boolean);
var
  X, Y: Integer;
  D: Single;
  Row, Alpha: PByte;
  PNG: TPngImage;
begin
  PNG := TPngImage.CreateBlank(COLOR_RGBALPHA, 8, W, H);
  try
    for Y := 0 to H - 1 do
    begin
      Row := PNG.Scanline[Y];
      Alpha := PByte(PNG.AlphaScanline[Y]);
      for X := 0 to W - 1 do
      begin
        D := Sqr((X + 0.5) / W - CX) + Sqr((Y + 0.5) / H - CY);
        if D < 0.0144 then
        begin
          Row^ := 25;
          Inc(Row);
          if IsB then Row^ := 205 else Row^ := 45;
          Inc(Row);
          Row^ := 240;
          Inc(Row);
          Alpha^ := 255;
        end
        else
        begin
          Row^ := 255;
          Inc(Row);
          Row^ := 0;
          Inc(Row);
          Row^ := 255;
          Inc(Row);
          Alpha^ := 0;
        end;
        Inc(Alpha);
      end;
    end;
    PNG.SaveToFile(Path);
  finally
    PNG.Free;
  end;
end;

function SetupModel: TMorphModel;
var
  Region: TMorphRegion;
  P: TMorphPoint;
  I, J: Integer;
  Offset: TPointF;
begin
  Result := DefaultModel;
  Result.Subject[isA] := 'テストA';
  Result.Subject[isB] := 'テストB';
  Region := Default(TMorphRegion);
  Region.Enabled := True;
  Region.Name[isA] := '円A';
  Region.Name[isB] := '円B';
  for I := 0 to 11 do
  begin
    Offset := PointF(0.13 * Cos(I * Pi / 6), 0.13 * Sin(I * Pi / 6));
    Region.Contour[isA] := Region.Contour[isA] + [PointF(0.28, 0.48) + Offset];
    Region.Contour[isB] := Region.Contour[isB] + [PointF(0.72, 0.52) + Offset];
  end;
  Result.Regions := [Region];
  P.Region := 0;
  P.Has[isA] := True;
  P.Has[isB] := True;
  for I := -1 to 1 do
    for J := -1 to 1 do
    begin
      Offset := PointF(I * 0.115, J * 0.115);
      P.UV[isA] := PointF(0.28, 0.48) + Offset;
      P.UV[isB] := PointF(0.72, 0.52) + Offset;
      Result.Points := Result.Points + [P];
    end;
end;

function AtPixel(const Image: TMorphImage; U, V: Single): TPIXEL_RGBA;
begin
  Result := Image.Pixels[Trunc(V * Image.Height) * Image.Width + Trunc(U * Image.Width)];
end;

procedure CheckSame(const A, B: TMorphImage; const Caption: string);
begin
  Check((A.Width = B.Width) and (A.Height = B.Height) and
    CompareMem(@A.Pixels[0], @B.Pixels[0], Length(A.Pixels) * SizeOf(TPIXEL_RGBA)), Caption);
end;

procedure TestIntermediateSilhouette(const Images: TSourceImages);
var
  A, B, C: TPremul;
  Field: TMorphImage;
begin
  Field := BuildSilhouetteField(Images[isA], False);
  Check((Field.Width = 96) and (SampleSilhouetteField(Field, PointF(0.28, 0.48)).Outline > 0.2) and
    (SampleSilhouetteField(Field, PointF(0.7, 0.48)).Outline < -0.2), 'source contour has distinct inside and outside');
  A := Default(TPremul);
  A.R := 240;
  A.A := 1;
  B := Default(TPremul);
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, -0.5),
    TSurfaceDistances.Create(-0.1, -0.5, -0.5), 0.5, 0.5, 1, 0);
  Check((C.A >= 0.99) and (C.R > 239), 'inside the moving contour only the present texture is sampled');
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.1, -0.5, -0.5),
    TSurfaceDistances.Create(-0.3, -0.5, -0.5), 0.5, 0.5, 1, 0);
  Check(C.A = 0, 'outside the moving contour no semitransparent copy remains');
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, -0.5),
    TSurfaceDistances.Create(-0.3, -0.5, -0.5), 0.5, 0.5, 1, 0);
  Check(SameValue(C.A, 0.5), 'interpolated boundary is antialiased');
  B.A := 1;
  B.G := 240;
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, -0.5),
    TSurfaceDistances.Create(0.3, -0.5, -0.5), 0.5, 0.45, 1, 0);
  Check(SameValue(C.R, 132, 0.01) and SameValue(C.G, 108, 0.01) and (C.A = 1),
    'already aligned colors use only the timeline progress');
  A.R := 0;
  B.R := 255;
  B.G := 255;
  B.B := 255;
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, 0.3),
    TSurfaceDistances.Create(0.3, -0.5, -0.1), 0.5, 0.5, 1, 0);
  Check((C.R < 1) and (C.G < 1) and (C.A = 1), 'the interpolated stroke stays dark and opaque');
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, 0.1),
    TSurfaceDistances.Create(0.3, -0.5, -0.3), 0.5, 0.5, 1, 0);
  Check((C.R > 254) and (C.G > 254) and (C.A = 1), 'the moved stroke leaves no gray copy behind');
  A.R := 220; A.G := 32; A.B := 40;
  B.R := 28; B.G := 186; B.B := 176;
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, 0.24),
    TSurfaceDistances.Create(0.3, -0.5, -0.10), 0.5, 0.5, 1, 0);
  Check((C.A = 1) and (C.R = A.R) and (C.G = A.G) and (C.B = A.B),
    'the inside of a moving colored shape carries only its own texture');
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, 0.1),
    TSurfaceDistances.Create(0.3, -0.5, -0.24), 0.5, 0.5, 1, 0);
  Check((C.A = 1) and (C.R = B.R) and (C.G = B.G) and (C.B = B.B),
    'the old position of a colored boundary does not leave a colored copy');
  A.R := 240; A.G := 0; A.B := 0;
  B.R := 0;
  B.G := 240;
  B.B := 0;
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, 0.3, -0.5),
    TSurfaceDistances.Create(0.3, -0.1, -0.5), 0.5, 0.5, 1, 0);
  Check((C.R > 239) and (C.G < 1), 'hair does not overlay the interior of the morphed skin surface');
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, 0.1, -0.5),
    TSurfaceDistances.Create(0.3, -0.3, -0.5), 0.5, 0.5, 1, 0);
  Check((C.G > 239) and (C.R < 1), 'hair outside the morphed skin surface receives only hair color');
  A.R := 120;
  A.A := 0.5;
  B.G := 120;
  B.A := 0.5;
  C := MorphSilhouette(A, B, TSurfaceDistances.Create(0.3, -0.5, -0.5),
    TSurfaceDistances.Create(0.3, -0.5, -0.5), 0.5, 0.5, 1, 0);
  Check(SameValue(C.A, 0.5), 'interior translucency is preserved independently of the outline');
end;

procedure TestIndependentPartMotion;
const
  Size = 192;
  YRows: array[0..6] of Single = (0.18, 0.25, 0.32, 0.5, 0.63, 0.71, 0.79);
  MovingX: array[TImageSide, Boolean] of Single = ((0.22, 0.75), (0.73, 0.24));
var
  Pair: TSourceImages;
  Model: TMorphModel;
  Region: TMorphRegion;
  P: TMorphPoint;
  Side: TImageSide;
  X, Y, Row, Col, Progress: Integer;
  Center, V, T: Single;
  Lower: Boolean;
  Renderer: TMorphRenderer;
  Image: TMorphImage;
  Pixel, Expected: TPIXEL_RGBA;
begin
  for Side := Low(Side) to High(Side) do
  begin
    Pair[Side].Width := Size;
    Pair[Side].Height := Size;
    SetLength(Pair[Side].Pixels, Size * Size);
    for Y := 0 to Size - 1 do
    begin
      V := (Y + 0.5) / Size;
      Lower := V >= 0.5;
      Center := YRows[1 + 4 * Ord(Lower)];
      for X := 0 to Size - 1 do
        if Sqr((X + 0.5) / Size - MovingX[Side, Lower]) + Sqr(V - Center) < Sqr(0.055) then
        begin
          Pair[Side].Pixels[Y * Size + X].R := 240 * Ord(Side = isA);
          Pair[Side].Pixels[Y * Size + X].G := 120 + 120 * Ord(Side = isB);
          Pair[Side].Pixels[Y * Size + X].A := 255;
        end;
    end;
  end;
  Model := DefaultModel;
  Region := Default(TMorphRegion);
  Region.Enabled := True;
  Region.State := rsMatch;
  Region.AutoGrid := True;
  Model.Regions := [Region, Region];
  P := Default(TMorphPoint);
  P.Has[isA] := True;
  P.Has[isB] := True;
  for Row := Low(YRows) to High(YRows) do
    for Col := -2 to 2 do
    begin
      P.Region := Ord(Row > 3);
      for Side := Low(Side) to High(Side) do
      begin
        Center := 0.5;
        if Row <> 3 then Center := MovingX[Side, Row > 3];
        if Col = -2 then P.UV[Side] := PointF(0.05, YRows[Row])
        else if Col = 2 then P.UV[Side] := PointF(0.95, YRows[Row])
        else P.UV[Side] := PointF(Center + Col * 0.07, YRows[Row]);
      end;
      Model.Points := Model.Points + [P];
    end;

  Renderer := TMorphRenderer.Create;
  try
    Renderer.Prepare(Pair, ReadModel(ModelJSON(Model)));
    Check((Length(Renderer.Mesh(0).Triangles) > 0) and (Length(Renderer.Mesh(1).Triangles) > 0) and
      (Length(Renderer.SavedMesh.Layers) = 1), 'parts keep their individual mesh controls in a single continuous warp');
    for Progress in [2500, 5000, 7500] do
    begin
      T := Progress / 10000;
      Image := Renderer.Render(Progress);
      Expected.R := Round(240 * (1 - T));
      Expected.G := Round(120 + 120 * T);
      for Lower := False to True do
      begin
        V := YRows[1 + 4 * Ord(Lower)];
        Center := MovingX[isA, Lower] + (MovingX[isB, Lower] - MovingX[isA, Lower]) * T;
        Pixel := AtPixel(Image, Center, V);
        Check((Pixel.A > 248) and (Abs(Integer(Pixel.R) - Expected.R) <= 1) and
          (Abs(Integer(Pixel.G) - Expected.G) <= 1),
          'each part moves in its own direction at the same timeline progress');
        for Side := Low(Side) to High(Side) do
          Check(AtPixel(Image, MovingX[Side, Lower], V).A < 15,
            'no stationary copy of either input part');
      end;
    end;
  finally
    Renderer.Free;
  end;
end;

procedure TestOneSidedRegionMotion;
const
  W = 128;
  Left: array[TImageSide] of Integer = (16, 80);
  Top = 24;
  Span = 32;
var
  Images: TSourceImages;
  Model: TMorphModel;
  Base, Part: TMorphRegion;
  Control: TMorphPoint;
  Side: TImageSide;
  Backing, Color: TPIXEL_RGBA;
  Frame: TMorphImage;
  Renderer: TMorphRenderer;
  Progress, X, Y, Start, SpanA, SpanB, Corner, Key: Integer;
  Target, Position: TPointF;

  function Outline(X: Integer): TPointPath;
  begin
    Result := [PointF(X / W, Top / W), PointF((X + Span) / W, Top / W),
      PointF((X + Span) / W, (Top + Span) / W), PointF(X / W, (Top + Span) / W)];
  end;

  procedure Paint(Side: TImageSide; Start: Integer);
  var
    X, Y: Integer;
    P: TPIXEL_RGBA;
  begin
    for Y := 0 to W - 1 do
      for X := 0 to W - 1 do
      begin
        P := Backing;
        if (X >= Start) and (X < Start + Span) and (Y >= Top) and (Y < Top + Span) then
          if Side = isA then P.R := 255 else P.G := 255;
        Images[Side].Pixels[Y * W + X] := P;
      end;
  end;

begin
  Backing.R := 32; Backing.G := 56; Backing.B := 78; Backing.A := 255;
  Model := DefaultModel;
  Model.Feather := 0;
  Base := Default(TMorphRegion);
  Base.Enabled := True;
  Base.Contour[isA] := [PointF(0, 0), PointF(1, 0), PointF(1, 1), PointF(0, 1)];
  Base.Contour[isB] := Base.Contour[isA];
  Model.Regions := [Base];
  for Side := Low(Side) to High(Side) do
  begin
    Images[Side].Width := W;
    Images[Side].Height := W;
    SetLength(Images[Side].Pixels, W * W);
    Paint(Side, Left[Side]);
    Part := Default(TMorphRegion);
    Part.Enabled := True;
    Part.State := rsDisappear;
    if Side = isB then Part.State := rsAppear;
    Part.Z := 1;
    Part.Contour[Side] := Outline(Left[Side]);
    Model.Regions := Model.Regions + [Part];
  end;

  Renderer := TMorphRenderer.Create;
  try
    Renderer.Prepare(Images, ReadModel(ModelJSON(Model)));
    CheckSame(Images[isA], Renderer.Render(0), 'disappearing region retains the exact A endpoint');
    CheckSame(Images[isB], Renderer.Render(10000), 'appearing region retains the exact B endpoint');
    Y := Top + Span div 2;
    for Progress in [2500, 5000, 7500] do
    begin
      Frame := Renderer.Render(Progress);
      SpanA := 0;
      SpanB := 0;
      for X := 0 to W - 1 do
      begin
        Color := Frame.Pixels[Y * W + X];
        Inc(SpanA, Ord(Color.R >= 245));
        Inc(SpanB, Ord(Color.G >= 245));
      end;
      Check(Abs(SpanA - Round(Span * (1 - Progress / 10000))) <= 1,
        'the disappearing part contracts at full color');
      Check(Abs(SpanB - Round(Span * Progress / 10000)) <= 1,
        'the appearing part expands at full color');
      for Side := Low(Side) to High(Side) do
      begin
        Start := Left[Side];
        Color := Frame.Pixels[Y * W + Start + 1];
        Check(Cardinal(Color) = Cardinal(Backing), 'the old contour leaves no tint in the paired backing');
      end;
    end;

    Paint(isB, Left[isA]);
    Model.Regions[2].Contour[isB] := Outline(Left[isA]);
    Renderer.Prepare(Images, Model);
    Frame := Renderer.Render(5000);
    Check(Cardinal(Frame.Pixels[Y * W + Left[isA] + 1]) = Cardinal(Backing),
      'overlapping cutouts use nearby visible backing instead of either original part');
    Color := Frame.Pixels[Y * W + Left[isA] + Span div 2];
    Check((Color.G = 255) and (Color.R = Backing.R), 'overlapping animated parts preserve layer order');

    Control := Default(TMorphPoint);
    Control.Region := -1;
    Control.Has[isA] := True;
    Control.Has[isB] := True;
    Control.UV[isA] := PointF(0.1, 0.3125);
    Control.UV[isB] := PointF(0.16, 0.3125);
    Model.Points := [Control];
    Renderer.Prepare(Images, Model);
    Corner := RegionCornerID(1, 0);
    Check(Renderer.PreviewVertex(Corner, 5000, Position) and
      SameValue(Position.X, (Renderer.Mesh(1).Masks[isA].Bounds.Left + 0.185) * 0.5, 1E-4),
      'a disappearing part contracts toward the moving paired attachment');
    Target := PointF(0.18, 0.26);
    Key := AddKey(Model, 5000);
    SetCorrection(Model.Keys[Key], Corner, Target);
    Renderer.Prepare(Images, Model, False);
    Check(Renderer.PreviewVertex(Corner, 5000, Position) and
      SameValue(Position.X, Target.X, 1E-5) and SameValue(Position.Y, Target.Y, 1E-5),
      'a correction key can place the contracted part at the edited position');
  finally
    Renderer.Free;
  end;
end;

procedure TestHeadwearMotion;
const
  Size = 128;
var
  Images: TSourceImages;
  Model: TMorphModel;
  Face, Hat, Detail: TMorphRegion;
  Renderer: TMorphRenderer;
  HatMesh, DetailMesh: TMeshLayer;
  HatPositions, DetailPositions: TPointPath;
  Side: TImageSide;
  Frame: TMorphImage;
  Color: TPIXEL_RGBA;
  I, X, Y: Integer;
  UV, Expected: TPointF;

  function Outline(L, T, R, B: Single): TPointPath;
  begin
    Result := [PointF(L, T), PointF(R, T), PointF(R, B), PointF(L, B)];
  end;

begin
  Model := DefaultModel;
  Model.Feather := 0;
  Face := Default(TMorphRegion);
  Face.Enabled := True;
  Face.Name[isA] := '顔の輪郭';
  Face.Name[isB] := 'face outline';
  Face.Contour[isA] := Outline(0.30, 0.45, 0.68, 0.74);
  Face.Contour[isB] := Outline(0.40, 0.56, 0.69, 0.81);
  Hat := Default(TMorphRegion);
  Hat.Enabled := True;
  Hat.State := rsUnknown;
  Hat.Name[isA] := 'とさか';
  Hat.Name[isB] := '紫色の帽子';
  Hat.Contour[isA] := Outline(0.43, 0.26, 0.58, 0.46);
  Hat.Contour[isB] := Outline(0.20, 0.14, 0.85, 0.59);
  Hat.Z := 1;
  Detail := Default(TMorphRegion);
  Detail.Enabled := True;
  Detail.State := rsAppear;
  Detail.Name[isB] := '帽子の星飾り';
  Detail.Contour[isB] := Outline(0.58, 0.29, 0.65, 0.37);
  Detail.Z := 2;
  Model.Regions := [Face, Hat, Detail];

  for Side := Low(Side) to High(Side) do
  begin
    Images[Side].Width := Size;
    Images[Side].Height := Size;
    SetLength(Images[Side].Pixels, Size * Size);
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
      begin
        UV := PointF((X + 0.5) / Size, (Y + 0.5) / Size);
        Color.R := 32; Color.G := 40; Color.B := 48; Color.A := 255;
        if ContainsPoint(Hat.Contour[Side], UV) then
          if Side = isA then Color.R := 230 else Color.G := 230;
        if (Side = isB) and ContainsPoint(Detail.Contour[isB], UV) then Color.B := 248;
        Images[Side].Pixels[Y * Size + X] := Color;
      end;
  end;

  Renderer := TMorphRenderer.Create;
  try
    Renderer.Prepare(Images, ReadModel(ModelJSON(Model)));
    HatMesh := Renderer.PreviewMesh(1, 0, HatPositions);
    Check(HatMesh.UseSide[isB] and not HatMesh.UseSide[isA], 'uncertain headwear retains the editable hat side');
    Check((HatPositions[1].X - HatPositions[0].X > 0.3) and
      SameValue(HatPositions[2].Y, HatPositions[0].Y, 1E-5) and
      (Abs(HatPositions[0].Y - 0.45) < 0.03), 'hat starts on a line across the original head');
    Check(Length(Renderer.SavedMesh.Layers) = 4, 'inferred counterpart adds no duplicate saved topology');

    HatMesh := Renderer.PreviewMesh(1, 2500, HatPositions);
    DetailMesh := Renderer.PreviewMesh(2, 2500, DetailPositions);
    for I := 0 to 3 do
    begin
      UV := DetailMesh.Vertices[I].UV[isB];
      Expected := PointF(
        HatPositions[0].X + (HatPositions[1].X - HatPositions[0].X) *
          (UV.X - HatMesh.Masks[isB].Bounds.Left) / HatMesh.Masks[isB].Bounds.Width,
        HatPositions[0].Y + (HatPositions[2].Y - HatPositions[0].Y) *
          (UV.Y - HatMesh.Masks[isB].Bounds.Top) / HatMesh.Masks[isB].Bounds.Height);
      Check(SameValue(Expected.X, DetailPositions[I].X, 1E-5) and
        SameValue(Expected.Y, DetailPositions[I].Y, 1E-5), 'hat decoration follows the same cloth coordinates');
    end;
    Frame := Renderer.Render(2500);
    Check(AtPixel(Frame, 0.37, 0.43).G = 230, 'opaque hat rises from the contact line');
    Check(AtPixel(Frame, 0.5, 0.18).G = 40, 'hat leaves no ghost at the final tip location');
    CheckSame(Images[isA], Renderer.Render(0), 'crest endpoint remains exact');
    CheckSame(Images[isB], Renderer.Render(10000), 'hat endpoint remains exact');

    for Side := Low(Side) to High(Side) do
      for Y := 0 to Size - 1 do
        for X := 0 to Size - 1 do
        begin
          UV := PointF((X + 0.5) / Size, (Y + 0.5) / Size);
          if not ContainsPoint(Hat.Contour[Side], UV) and not ContainsPoint(Face.Contour[Side], UV) then
            Images[Side].Pixels[Y * Size + X].A := Ord((Y = 28) and (X > 53) and (X < 74)) * 255;
        end;
    Renderer.Prepare(Images, Model);
    Frame := Renderer.Render(2500);
    Check(AtPixel(Frame, 0.5, 0.28).A = 0, 'overlapping old hat and crest expose the transparent backdrop');

    Model.Regions[1].Name[isA] := 'crown';
    Model.Regions[1].Name[isB] := 'とさか';
    Renderer.Prepare(Images, Model);
    HatMesh := Renderer.PreviewMesh(1, 10000, HatPositions);
    Check(HatMesh.UseSide[isA] and (HatPositions[1].X - HatPositions[0].X > 0.12) and
      SameValue(HatPositions[2].Y, HatPositions[0].Y, 1E-5) and
      (Abs(HatPositions[0].Y - 0.56) < 0.05), 'a disappearing crown contracts along the destination head');

    Model.Regions[1].Enabled := False;
    Renderer.Prepare(Images, Model);
    HatMesh := Renderer.PreviewMesh(1, 2500, HatPositions);
    Check(Length(HatPositions) = 0, 'disabled headwear does not create an overlay or companion');
  finally
    Renderer.Free;
  end;
end;

procedure TestLocalRegistration;
const
  Size = 240;
  ShiftX = 6;
  ShiftY = -4;
var
  Images: TSourceImages;
  Model, Restored, Blank: TMorphModel;
  Region: TMorphRegion;
  Side: TImageSide;
  P: TMorphPoint;
  Pixel: TPIXEL_RGBA;
  Renderer: TMorphRenderer;
  Mesh: TMeshLayer;
  Positions: TPointPath;
  Pair: TMeshDetail;
  T: TTriangle;
  DetailA, DetailB, Expected: TPointF;
  Host: THostVertices;
  Canvas: TSize;
  Frame: TMorphImage;
  MarkX, MarkY, Blend: Single;
  Mark: TPIXEL_RGBA;
  X, Y, Index, Col, Row, Key, Progress: Integer;
  Found: Boolean;
begin
  Model := DefaultModel;
  Region := Default(TMorphRegion);
  Region.Name[isA] := 'Test shape';
  Region.Name[isB] := Region.Name[isA];
  Region.State := rsMatch;
  Region.Enabled := True;
  Region.AutoGrid := True;
  Model.Regions := [Region];
  P := Default(TMorphPoint);
  P.Has[isA] := True;
  P.Has[isB] := True;
  for Row := 0 to 4 do
    for Col := 0 to 4 do
    begin
      P.UV[isA] := PointF(0.12 + Col * 0.19, 0.14 + Row * 0.18);
      P.UV[isB] := P.UV[isA];
      Model.Points := Model.Points + [P];
    end;

  for Side := Low(Side) to High(Side) do
  begin
    Images[Side].Width := Size;
    Images[Side].Height := Size;
    SetLength(Images[Side].Pixels, Size * Size);
    for Y := 30 to 209 do
      for X := 30 to 209 do
      begin
        Index := Y * Size + X;
        Pixel.A := 255;
        Pixel.R := 205;
        Pixel.G := 190;
        Pixel.B := 173;
        // The asymmetric mark moves inside the same triangle, with the coarse mesh held still.
        Col := X - 104 - ShiftX * Ord(Side);
        Row := Y - 91 - ShiftY * Ord(Side);
        if ((Col >= -1) and (Col <= 1) and (Row >= -6) and (Row <= 4)) or
          ((Row >= -1) and (Row <= 1) and (Col >= -4) and (Col <= 7)) or
          ((Col >= 3) and (Col <= 5) and (Row >= 2) and (Row <= 5)) then
        begin
          Pixel.R := 24;
          Pixel.G := 27;
          Pixel.B := 30;
        end;
        Images[Side].Pixels[Index] := Pixel;
      end;
  end;

  RefineAutomaticMesh(Images, Model);
  Check(Length(Model.Refinement.Details) > 0, 'two images with a displaced internal mark produce a detail match');

  Renderer := TMorphRenderer.Create;
  try
    Renderer.Prepare(Images, Model);
    Mesh := Renderer.Mesh(-1);
    Found := False;
    for Pair in Model.Refinement.Details do
    begin
      T := Mesh.CoarseTriangles[Pair.TriangleIndex];
      DetailA := BarycentricPoint(Mesh.Vertices[T.A].UV[isA], Mesh.Vertices[T.B].UV[isA],
        Mesh.Vertices[T.C].UV[isA], Pair.Weights[isA]);
      DetailB := BarycentricPoint(Mesh.Vertices[T.A].UV[isB], Mesh.Vertices[T.B].UV[isB],
        Mesh.Vertices[T.C].UV[isB], Pair.Weights[isB]);
      Found := Found or (Abs((DetailB.X - DetailA.X) * Size - ShiftX) < 1.1) and
        (Abs((DetailB.Y - DetailA.Y) * Size - ShiftY) < 1.1);
    end;
    Check(Found, 'registration measures the true horizontal and vertical shift');
    Check(Length(Mesh.Triangles) = Model.Refinement.TriangleCount + 2 * Length(Model.Refinement.Details),
      'matched triangles are subdivided without changing the coarse mesh');
    Check(Length(Renderer.Mesh(0).Triangles) > 0, 'selected part exposes the subdivided mesh');

    MarkX := (104 + ShiftX * 0.5 + 0.5) / Size;
    MarkY := (91 + ShiftY * 0.5 + 0.5) / Size;
    Frame := Renderer.Render(5000);
    Mark := AtPixel(Frame, MarkX, MarkY);
    Check((Mark.A = 255) and (Mark.R < 70), 'the internal mark travels to its halfway position as an opaque detail');

    Model.Mesh := Renderer.SavedMesh;
    Restored := ReadModel(ModelJSON(Model));
    Check((Length(Restored.Refinement.Details) = Length(Model.Refinement.Details)) and
      (Restored.Mesh.Layers[0].VertexCount = Model.Refinement.VertexCount), 'details and coarse topology round-trip');
    Blank := Restored;
    Blank.Refinement := Default(TMeshRefinement);
    Renderer.Prepare(Images, Blank);
    Check(Length(Renderer.Mesh(-1).Triangles) = Model.Refinement.TriangleCount, 'legacy data loads without refinement');

    // Bending one control row or editing a correction key should preserve the attached detail.
    Restored.Points[7].UV[isA].Y := Restored.Points[7].UV[isA].Y + 0.005;
    Key := AddKey(Restored, 5500);
    SetCorrection(Restored.Keys[Key], 7, Restored.Points[7].UV[isA] + PointF(0.005, 0.005));
    Renderer.Prepare(Images, Restored);
    Mesh := Renderer.PreviewMesh(-1, 5500, Positions);
    Index := Restored.Refinement.VertexCount;
    Check((Index < Length(Mesh.Vertices)) and Mesh.Vertices[Index].HasParents,
      'safe manual point edits keep the refined mesh');
    T := Mesh.Vertices[Index].Parents;
    Expected := BarycentricPoint(Positions[T.A], Positions[T.B], Positions[T.C],
      MixPoint(Mesh.Vertices[Index].ParentWeights[isA], Mesh.Vertices[Index].ParentWeights[isB], 0.55));
    Check(SameValue(Positions[Index].X, Expected.X, 1E-6) and SameValue(Positions[Index].Y, Expected.Y, 1E-6),
      'the detail follows interpolation inside its moving parent triangle');
    for Progress in [100, 2500, 5000, 5500, 7500, 9900] do
      Check(Renderer.HostFrame(Progress, Canvas, Host, Blend), 'refined mesh stays valid throughout the morph');
    RemoveVertex(Restored, 7);
    Check(Length(Restored.Refinement.Details) = 0, 'removing a coarse point drops its outdated local topology');
  finally
    Renderer.Free;
  end;
end;

procedure TestColoredStrokeField;
const
  W = 96;
var
  Image, Field: TMorphImage;
  X, Y: Integer;
  P: TPIXEL_RGBA;
  Model, Restored: TMorphModel;
  FieldPoint: TPointF;
  JSON: string;
  Rejected: Boolean;
begin
  Image.Width := W;
  Image.Height := W;
  SetLength(Image.Pixels, W * W);
  for Y := 8 to W - 9 do
    for X := 8 to W - 9 do
    begin
      P.A := 255;
      P.R := 120; P.G := 50; P.B := 55;
      if X in [39..41] then
      begin
        P.R := 244; P.G := 219; P.B := 140;
      end;
      Image.Pixels[Y * W + X] := P;
    end;
  Field := BuildSilhouetteField(Image, False);
  Check(SampleSilhouetteField(Field, PointF(40.5 / W, 0.5)).Stroke > 0,
    'a bright colored stripe is recognized as a stroke');
  Check(SampleSilhouetteField(Field, PointF(27.5 / W, 0.5)).Stroke < -0.05,
    'a broad plain color is not treated as a thin stroke');

  Field := BuildSilhouetteField(Image, False, False, 0.26, 0.73);
  FieldPoint := PointF(27.5 / W, 0.5);
  Check(SampleSilhouetteField(Field, FieldPoint).Stroke > 0.2,
    'a broad fabric panel is recognized inside the measured garment');
  Check(SampleSilhouetteField(Field, PointF(FieldPoint.X, 0.19)).Stroke < 0,
    'the same pigment outside the garment does not create a broad fabric panel');

  Model := DefaultModel;
  Model.FabricY[isA] := PointF(0.26, 0.73);
  Model.FabricY[isB] := PointF(0.31, 0.72);
  Restored := ReadModel(ModelJSON(Model));
  Check((Model.FabricY[isA] = Restored.FabricY[isA]) and (Model.FabricY[isB] = Restored.FabricY[isB]),
    'garment limits persist on both sides');
  JSON := ModelJSON(DefaultModel);
  JSON := Copy(JSON, 1, Length(JSON) - 1) + ',"fabricY":[[0.8,0.2],[0.3,0.8]]}';
  Rejected := False;
  try
    Restored := ReadModel(JSON);
  except
    on EConvertError do Rejected := True;
  end;
  Check(Rejected, 'saved models reject reversed garment limits');
end;

procedure TestVerticalOrientation(const Directory: string);
var
  Image: TMorphImage;
  Bitmap: Vcl.Graphics.TBitmap;
  Path: string;
begin
  Image.Width := 4;
  Image.Height := 4;
  SetLength(Image.Pixels, 16);
  for var I := 0 to High(Image.Pixels) do
  begin
    Image.Pixels[I].A := 255;
    if I < 8 then Image.Pixels[I].R := 255
    else Image.Pixels[I].B := 255;
  end;
  Bitmap := Vcl.Graphics.TBitmap.Create;
  try
    DrawBitmap(Image, Bitmap, 2);
    Check(Bitmap.Canvas.Pixels[0, 0] = clRed, 'editor displays the source top row at the top');
    Check(Bitmap.Canvas.Pixels[0, 1] = clBlue, 'editor displays the source bottom row at the bottom');
  finally
    Bitmap.Free;
  end;
  Path := TPath.Combine(Directory, 'orientation-analysis.png');
  SaveAnalysisPNG(Image, Path);
  CheckSame(Image, LoadImage(Path), 'Codex analysis attachment uses the same vertical coordinates');
end;

procedure TestAutoDetect(const Images: TSourceImages);
const
  White: TPIXEL_RGBA = (R: 255; G: 255; B: 255; A: 255);
var
  Samples: TSourceImages;
  M: TMorphModel;
  I: Integer;
begin
  Samples := Images;
  Samples[isB].Pixels := Copy(Images[isB].Pixels);
  for I := 0 to High(Samples[isB].Pixels) do
    if Samples[isB].Pixels[I].A = 0 then
      Samples[isB].Pixels[I] := White;
  M := DetectMorphing(Samples);
  Check((Length(M.Regions) = 1) and (M.Regions[0].State = rsMatch), 'transparent and opaque backgrounds are detected');
  Check((Length(M.Points) > 0) and M.Points[0].Has[isA] and M.Points[0].Has[isB],
    'local detection pairs foreground landmarks');
  for I := 0 to High(Samples[isB].Pixels) do
    Samples[isB].Pixels[I] := White;
  M := DetectMorphing(Samples);
  Check((Length(M.Points) = 0) and (Length(M.Regions) = 1) and (M.Regions[0].State = rsUnknown),
    'local detection does not invent landmarks for a missing foreground');
end;

procedure TestRenderer(const Images: TSourceImages; const M: TMorphModel);
var
  R: TMorphRenderer;
  Edited, Parsed, Fallback: TMorphModel;
  I, K: Integer;
  P: TPIXEL_RGBA;
  UV: TPointF;
  Frame: TMorphImage;
  Started: UInt64;
begin
  R := TMorphRenderer.Create;
  try
    R.Prepare(Images, M);
    Check(not M.Regions[0].AutoGrid and (R.ContourField(isA).Width > 0),
      'manually paired regions use the moving contour as well as automatic grids');
    Parsed := M;
    Parsed.Mesh := R.SavedMesh;
    Parsed := ReadModel(ModelJSON(Parsed));
    Check((Length(Parsed.Mesh.Layers) = 2) and (Length(Parsed.Mesh.Layers[0].Triangles) > 4),
      'stored triangle topology roundtrip');
    R.Prepare(Images, Parsed);
    CheckSame(Images[isA], R.Render(0), '0% renderer endpoint');
    CheckSame(Images[isB], R.Render(10000), '100% renderer endpoint');
    Frame := R.Render(5000);
    P := AtPixel(Frame, 0.5, 0.5);
    Check((P.A > 235) and (P.R > 230) and (P.G in [115..135]) and (P.B < 28),
      'aligned midpoint warp and mixed color');
    P := AtPixel(Frame, 0.16, 0.12);
    Check((P.A = 0) and (P.R = 0) and (P.G = 0) and (P.B = 0), 'transparent RGB');
    for P in Frame.Pixels do
      if P.A in [1..254] then Check(P.B <= 25, 'premultiplied edge avoids transparent RGB bleed');
    Fallback := DefaultModel;
    R.Prepare(Images, Fallback);
    Check(AtPixel(R.Render(5000), 0.5, 0.5).A < 20, 'no invented match when landmarks absent');

    Edited := ReadModel(ModelJSON(M));
    K := AddKey(Edited, 3500);
    SetCorrection(Edited.Keys[K], 4, PointF(0.31, 0.74));
    SetCorrection(Edited.Keys[K], RegionCornerID(0, 1), PointF(0.62, 0.21));
    K := AddKey(Edited, 7300);
    SetCorrection(Edited.Keys[K], 4, PointF(0.66, 0.26));
    Parsed := ReadModel(ModelJSON(Edited));
    Check(Length(Parsed.Keys) = 2, 'roundtrip multiple keys');
    Check(Parsed.Keys[0].Points[1].Vertex = RegionCornerID(0, 1), 'roundtrip contour key');
    R.Prepare(Images, Parsed);
    Check(R.PreviewVertex(4, 3500, UV) and SameValue(UV.X, 0.31, 0.001) and SameValue(UV.Y, 0.74, 0.001),
      'corrected landmark equals key position');
    Check(R.PreviewVertex(RegionCornerID(0, 1), 3500, UV) and SameValue(UV.Y, 0.21, 0.001), 'corrected region shape handle');
    Check(R.PreviewVertex(4, 5400, UV) and (UV.Y > 0.26) and (UV.Y < 0.74), 'interpolated correction');
    for I := 0 to 32 do
    begin
      Frame := R.Render(Round(I / 32 * 10000));
      Check(Length(Frame.Pixels) = Frame.Width * Frame.Height, 'mesh folds retain a complete frame');
    end;
    RemoveRegion(Parsed, 0);
    Check((Length(Parsed.Points) = 0) and (Length(Parsed.Keys[0].Points) = 0),
      'delete region removes point and contour key references');
    Started := GetTickCount64;
    for I := 250 to 300 do Frame := R.Render(I * 31);
    Writeln('51 frames at ', Frame.Width, 'x', Frame.Height, ' in ', GetTickCount64 - Started, ' ms');
  finally
    R.Free;
  end;
end;

procedure TestImages(const Images: TSourceImages; const Path: string);
var
  R: TMorphRenderer;
  Mixed, SingleSource: TSourceImages;
  Frame: TMorphImage;
begin
  Mixed := Images;
  Mixed[isB] := LoadImage(Path);
  R := TMorphRenderer.Create;
  try
    R.Prepare(Mixed, DefaultModel);
    CheckSame(Mixed[isA], R.Render(0), 'mixed resolutions A endpoint');
    CheckSame(Mixed[isB], R.Render(10000), 'mixed resolutions B endpoint');
    Frame := R.Render(5000);
    Check((Frame.Width = 142) and (Frame.Height = 96), 'center canvas fits both source aspect ratios');
    SingleSource := Default(TSourceImages);
    SingleSource[isA] := Images[isA];
    R.Prepare(SingleSource, DefaultModel);
    CheckSame(Images[isA], R.Render(5500), 'one-source fallback');
    Frame := R.Render(10000);
    Check(Length(Frame.Pixels) = 0, 'absent endpoint is empty');
  finally
    R.Free;
  end;
end;


function EditorControl(Window: HWND): TControlAccess;
begin
  // The harness only inspects its own plugin windows, which use the same VCL ABI.
  Result := Pointer(SendMessage(Window, RegisterWindowMessage('DelphiRM_GetObjectInstance'),
    GetCurrentProcessId, 0));
end;

function CheckContextMenu(Window: HWND; Data: LPARAM): BOOL; stdcall;
var
  Control: TControlAccess;
  Popup: TPopupMenu;
  I: Integer;
begin
  Result := True;
  Control := EditorControl(Window);
  if (Control = nil) or ((Control.ClassName <> 'TMorphViewport') and (Control.ClassName <> 'TListBox')) then Exit;
  Popup := Control.PopupMenu;
  if Popup = nil then Exit;
  for I := 0 to Popup.Items.Count - 1 do
    if (Popup.Items[I].Caption = '自動判定') and
      (Popup.Items[I].ShortCut = ShortCut(Ord('D'), [ssCtrl])) then
    begin
      Inc(ContextMenuCount);
      Exit;
    end;
end;

function DragPointInSourceA(Window: HWND; Data: LPARAM): BOOL; stdcall;
var
  Control: TControlAccess;
  View: TMorphViewport;
  Model: TMorphModel;
  FromPos, ToPos: TPoint;
begin
  Result := True;
  Control := EditorControl(Window);
  if (Control = nil) or (Control.ClassName <> 'TMorphViewport') or (Control.Tag <> 0) then Exit;
  View := TMorphViewport(Pointer(Control));
  Model := ReadModel(string(Saved));
  FromPos := View.ScreenPoint(Model.Points[4].UV[isA]);
  ToPos := View.ScreenPoint(Model.Points[4].UV[isA] + PointF(0.047, 0));
  SendMessage(Window, WM_LBUTTONDOWN, MK_LBUTTON, PointToLParam(FromPos));
  SendMessage(Window, WM_MOUSEMOVE, MK_LBUTTON, PointToLParam(ToPos));
  SendMessage(Window, WM_LBUTTONUP, 0, PointToLParam(ToPos));
  Result := False;
end;

function RunShortcut(Window: HWND; Key: Word): Boolean;
var
  Prior, Pressed: TKeyboardState;
  Message: TWMKey;
  Control: TControlAccess;
begin
  Result := False;
  Control := EditorControl(Window);
  if (Control = nil) or not GetKeyboardState(Prior) then Exit;
  Pressed := Prior;
  Pressed[VK_CONTROL] := Pressed[VK_CONTROL] or $80;
  if not SetKeyboardState(Pressed) then Exit;
  try
    Message := Default(TWMKey);
    Message.Msg := WM_KEYDOWN;
    Message.CharCode := Key;
    Result := TForm(Control).IsShortCut(Message);
  finally
    SetKeyboardState(Prior);
  end;
end;

function EditorMenuBar(Window: HWND): TToolBar;
var
  Editor: TControlAccess;
begin
  Result := nil;
  Editor := EditorControl(Window);
  if Editor <> nil then Result := TToolBar(Editor.FindComponent('EditorMenuBar'));
end;

function InvokeMenu(Window: HWND; const Caption: string; const Shortcut: string = ''): Boolean;

  function FindCommand(Menu: HMENU): UINT;
  var
    I, Separator: Integer;
    Text: array[0..255] of Char;
    LabelText: string;
    Sub: HMENU;
  begin
    Result := 0;
    for I := 0 to GetMenuItemCount(Menu) - 1 do
    begin
      Sub := GetSubMenu(Menu, I);
      if Sub <> 0 then
      begin
        Result := FindCommand(Sub);
        if Result <> 0 then Exit;
        Continue;
      end;
      GetMenuString(Menu, I, @Text[0], Length(Text), MF_BYPOSITION);
      LabelText := string(PChar(@Text[0]));
      if Shortcut <> '' then
      begin
        Separator := Pos(#9, LabelText);
        if (Separator = 0) or not SameText(Copy(LabelText, Separator + 1, MaxInt), Shortcut) then Continue;
      end;
      if (LabelText = Caption) or LabelText.StartsWith(Caption + #9) then Exit(GetMenuItemID(Menu, I));
    end;
  end;

var
  ID: UINT;
  I: Integer;
  Bar: TToolBar;
  Popup: TPopupMenu;
begin
  Result := False;
  Bar := EditorMenuBar(Window);
  if Bar = nil then Exit;
  for I := 0 to Bar.ButtonCount - 1 do
  begin
    Popup := Bar.Buttons[I].DropdownMenu;
    ID := FindCommand(Popup.Handle);
    if ID <> 0 then Exit(Popup.DispatchCommand(ID));
  end;
end;

function CheckChildBounds(Window: HWND; Data: LPARAM): BOOL; stdcall;
var
  Bounds, Limits: TRect;
  Parent: HWND;
  Title: array[0..127] of Char;
begin
  Result := True;
  if not IsWindowVisible(Window) then Exit;
  Parent := GetParent(Window);
  GetWindowRect(Window, Bounds);
  MapWindowPoints(0, Parent, Bounds, 2);
  GetClientRect(Parent, Limits);
  if (Bounds.Left >= Limits.Left - 2) and (Bounds.Top >= Limits.Top - 2) and
    (Bounds.Right <= Limits.Right + 2) and (Bounds.Bottom <= Limits.Bottom + 2) then Exit;
  GetWindowText(Window, @Title[0], Length(Title));
  LayoutError := Format('control "%s" is outside its parent at %d DPI (%d,%d,%d,%d within %dx%d)',
    [string(PChar(@Title[0])), Data, Bounds.Left, Bounds.Top, Bounds.Right, Bounds.Bottom,
    Limits.Width, Limits.Height]);
  Result := False;
end;

procedure CaptureLayout(Window: HWND; const Path: string; DPI: Integer);
var
  Bounds: TRect;
  Bitmap: Vcl.Graphics.TBitmap;
  Theme: TRegistry;
  Background: Cardinal;
  Dark: Boolean;
  Bar: TToolBar;
  Position: TPoint;
  I: Integer;
  BarBackground: Cardinal;
begin
  Bar := EditorMenuBar(Window);
  BarBackground := 0;
  if Bar <> nil then
  begin
    if (GetMenu(Window) <> 0) or (Bar.ButtonCount <> 5) then
    begin
      LayoutError := 'editor menu is not in the client area';
      Exit;
    end;
    for I := 0 to Bar.ButtonCount - 1 do
    begin
      Position := Bar.Buttons[I].BoundsRect.CenterPoint;
      if (Bar.Buttons[I].DropdownMenu = nil) or
        (Bar.Perform(TB_HITTEST, 0, LPARAM(@Position)) <> I) or
        (SendMessage(Window, WM_NCHITTEST, 0, PointToLParam(Bar.ClientToScreen(Position))) <> HTCLIENT) then
      begin
        LayoutError := Format('menu heading %d cannot be clicked at %d DPI', [I + 1, DPI]);
        Exit;
      end;
    end;
  end;
  GetWindowRect(Window, Bounds);
  EnumChildWindows(Window, @CheckChildBounds, DPI);
  if LayoutError <> '' then Exit;
  Inc(LayoutChecks);
  Bitmap := Vcl.Graphics.TBitmap.Create;
  try
    Bitmap.SetSize(Bounds.Width, Bounds.Height);
    if not PrintWindow(Window, Bitmap.Canvas.Handle, 0) then
      raise Exception.Create('could not capture editor window');
    Bitmap.SaveToFile(Path);
    Background := Bitmap.Canvas.Pixels[Bitmap.Width - 26, Bitmap.Height - 25];
    if Bar <> nil then
    begin
      Position := Bar.ClientToScreen(Point(Bar.ClientWidth - 20, Bar.ClientHeight div 2));
      BarBackground := Bitmap.Canvas.Pixels[Position.X - Bounds.Left, Position.Y - Bounds.Top];
    end;
  finally
    Bitmap.Free;
  end;
  Theme := TRegistry.Create(KEY_READ);
  try
    if not Theme.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') or
      (Theme.GetDataType('AppsUseLightTheme') <> rdInteger) then Exit;
    Dark := Theme.ReadInteger('AppsUseLightTheme') = 0;
  finally
    Theme.Free;
  end;
  if Dark <> (GetRValue(Background) < 96) then
    LayoutError := 'editor footer does not match the Windows app theme'
  else if (Bar <> nil) and (Dark <> (GetRValue(BarBackground) < 96)) then
    LayoutError := 'editor menu bar does not match the Windows app theme';
end;

procedure VerifyLayout(Window: HWND);
var
  Original, Suggested: TRect;
  DPI: Integer;
begin
  GetWindowRect(Window, Original);
  CaptureLayout(Window, Snapshot, GetDpiForWindow(Window));
  EnumChildWindows(Window, @CheckContextMenu, 0);
  if not HasSwitch('dpi-ui') then Exit;
  Writeln('Editor monitor DPI: ', GetDpiForWindow(Window));
  for DPI in [96, 120, 144, 192] do
  begin
    if LayoutError <> '' then Break;
    Suggested := Rect(Original.Left, Original.Top, Original.Left + Min(Original.Width, MulDiv(780, DPI, 96)),
      Original.Top + Min(Original.Height, MulDiv(600, DPI, 96)));
    SendMessage(Window, WM_DPICHANGED, MakeWParam(DPI, DPI), LPARAM(@Suggested));
    RedrawWindow(Window, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW or RDW_ALLCHILDREN);
    CaptureLayout(Window, ChangeFileExt(Snapshot, '-' + IntToStr(DPI) + 'dpi.bmp'), DPI);
  end;
end;

function CaptureQualityDialog(Window: HWND; Data: LPARAM): BOOL; stdcall;
var
  Title: array[0..127] of Char;
begin
  Result := True;
  GetWindowText(Window, @Title[0], Length(Title));
  if string(PChar(@Title[0])) <> '画質設定' then Exit;
  KillTimer(0, Timer);
  try
    CaptureLayout(Window, ChangeFileExt(Snapshot, '-quality.bmp'), GetDpiForWindow(Window));
  except
    on E: Exception do LayoutError := E.Message;
  end;
  PostMessage(Window, WM_CLOSE, 0, 0);
  Result := False;
end;

procedure QualityTimer(Wnd: HWND; Msg: UINT; IdEvent: UINT_PTR; Time: DWORD); stdcall;
begin
  EnumThreadWindows(GetCurrentThreadId, @CaptureQualityDialog, 0);
end;

procedure CodexTestTimeout(Window: HWND; Msg: UINT; ID: UINT_PTR; Time: DWORD); stdcall;
begin
  KillTimer(Window, ID);
  LayoutError := 'Codex menu test did not close in time';
  PostMessage(Window, WM_SYSCOMMAND, SC_CLOSE, 0);
end;

procedure EditorTimer(Wnd: HWND; Msg: UINT; IdEvent: UINT_PTR; Time: DWORD); stdcall; forward;

function AnalysisLineVisible(Activity: TPaintBox; Regions: TListBox): Boolean;
var
  LineStart, ListStart: TPoint;
begin
  LineStart := Activity.Parent.ClientToScreen(Activity.BoundsRect.TopLeft);
  ListStart := Regions.Parent.ClientToScreen(Regions.BoundsRect.TopLeft);
  Result := Activity.Visible and (Activity.Width = Regions.Width) and
    (LineStart.X = ListStart.X) and (LineStart.Y + Activity.Height <= ListStart.Y);
end;

procedure CheckAnalysisLineGrowth(Activity: TPaintBox);
const
  Blue = TColor($00D77800);
var
  Bitmap: Vcl.Graphics.TBitmap;
  Previous, Current, Attempt: Integer;

  function FillWidth: Integer;
  var
    X: Integer;
  begin
    Activity.Perform(WM_PAINT, Bitmap.Canvas.Handle, 0);
    Result := 0;
    for X := 0 to Bitmap.Width - 1 do
      if Bitmap.Canvas.Pixels[X, Bitmap.Height div 2] = Blue then
      begin
        if X <> Result then Exit(-1);
        Inc(Result);
      end;
  end;

begin
  Bitmap := Vcl.Graphics.TBitmap.Create;
  try
    Bitmap.SetSize(Activity.Width, Activity.Height);
    Previous := FillWidth;
    for Attempt := 1 to 3 do
    begin
      Sleep(120);
      Current := FillWidth;
      Check((Previous >= 0) and (Current >= 0), 'the blue line fills from the left edge without gaps');
      if Current > Previous then Exit;
      Previous := Current;
    end;
    Check(False, 'the blue line grows rightward while analysis is waiting');
  finally
    Bitmap.Free;
  end;
end;

function CloseWindow(Window: HWND; Data: LPARAM): BOOL; stdcall;
var
  Title: array[0..127] of Char;
  Started: Boolean;
  Focused: HWND;
  StatusLabel: TLabel;
  RegionList: TListBox;
  Activity: TPaintBox;
  Editor: TControlAccess;
  Ready: Boolean;
begin
  Result := True;
  GetWindowText(Window, @Title[0], Length(Title));
  if string(PChar(@Title[0])) <> 'モーフィング設定' then Exit;
  EditorSeen := True;
  KillTimer(0, Timer);
  Editor := EditorControl(Window);
  StatusLabel := TLabel(Editor.FindComponent('AnalysisStatus'));
  RegionList := TListBox(Editor.FindComponent('AnalysisRegionList'));
  Activity := TPaintBox(Editor.FindComponent('AnalysisActivity'));
  if AwaitAnalysis <> atNone then
  begin
    if AwaitAnalysis = atLocal then
      Ready := string(StatusLabel.Caption).StartsWith('自動判定結果')
    else
      Ready := string(StatusLabel.Caption).StartsWith('Codexで詳細判定中') and (RegionList.Items.Count > 0);
    if not Ready then
    begin
      if GetTickCount64 < AwaitDeadline then
        Timer := SetTimer(0, 0, 60, @EditorTimer)
      else
        PostMessage(Window, WM_CLOSE, 0, 0);
      Exit(False);
    end;
    if AwaitAnalysis = atLocal then
      Check(not Activity.Visible and (RegionList.Items.Count > 1) and
        (RegionList.Items[0] = '全体メッシュ'), 'the completed list replaces the running indicator')
    else
    begin
      Check(AnalysisLineVisible(Activity, RegionList) and
        (RegionList.Items[0] <> '全体メッシュ') and (Pos('円A', RegionList.Items.Text) = 0),
        'the preliminary results arrive without old region names while Codex is running');
      CheckAnalysisLineGrowth(Activity);
      if AwaitAnalysis = atCodexCancel then
      begin
        Check(InvokeMenu(Window, 'Codexの判定を中止', 'Ctrl+Shift+D'), 'the running analysis can be cancelled');
        Check(not Activity.Visible and (RegionList.Items.Count >= 2) and
          (RegionList.Items[0] = '全体メッシュ') and (Pos('円A', RegionList.Items.Text) > 0),
          'cancelling without a new result restores the previous region list');
      end;
    end;
    AwaitAnalysis := atNone;
  end;
  if Snapshot <> '' then
    try
      VerifyLayout(Window);
      if HasSwitch('dpi-ui') and (LayoutError = '') then
      begin
        Timer := SetTimer(0, 0, 350, @QualityTimer);
        try
          InvokeMenu(Window, '画質設定…');
        finally
          KillTimer(0, Timer);
        end;
      end;
    except
      on E: Exception do LayoutError := E.Message;
    end;
  if ChangeMesh then
  begin
    ChangeMesh := False;
    if ((Data = 1) and not InvokeMenu(Window, 'メッシュを表示', 'Ctrl+M')) or
      ((Data = 0) and not RunShortcut(Window, Ord('M'))) then
    begin
      PostMessage(Window, WM_CLOSE, 0, 0);
      Exit(False);
    end;
  end;
  if DragPartPoint then EnumChildWindows(Window, @DragPointInSourceA, 0);
  Started := True;
  case AnalysisTest of
    atLocal: Started := InvokeMenu(Window, '自動判定', 'Ctrl+D');
    atCodex, atCodexCancel:
      begin
        SetTimer(Window, 100, 90000, @CodexTestTimeout);
        Started := InvokeMenu(Window, 'Codexで詳細判定…', 'Ctrl+Shift+D');
      end;
  end;
  if Started and (AnalysisTest <> atNone) then
  begin
    Check(string(StatusLabel.Caption).StartsWith('輪郭とパーツを判定中') and (RegionList.Items.Count = 0) and
      AnalysisLineVisible(Activity, RegionList), 'analysis clears the old list and shows a line spanning the list');
    AwaitAnalysis := AnalysisTest;
    AnalysisTest := atNone;
    AwaitDeadline := GetTickCount64 + 7000;
    Timer := SetTimer(0, 0, 60, @EditorTimer);
    Exit(False);
  end;
  if not Started then
  begin
    PostMessage(Window, WM_CLOSE, 0, 0);
    Exit(False);
  end;
  if CloseViaTitle then CommandFound := PostMessage(Window, WM_SYSCOMMAND, SC_CLOSE, 0)
  else if Data = 1 then CommandFound := PostMessage(Window, WM_CLOSE, 0, 0)
  else
  begin
    Focused := GetFocus;
    if (Focused = 0) or ((Focused <> Window) and not IsChild(Window, Focused)) then Focused := Window;
    CommandFound := PostMessage(Focused, WM_KEYDOWN, VK_ESCAPE, 0);
  end;
  if not CommandFound then PostMessage(Window, WM_CLOSE, 0, 0);
  Result := False;
end;

procedure EditorTimer(Wnd: HWND; Msg: UINT; IdEvent: UINT_PTR; Time: DWORD); stdcall;
begin
  EnumThreadWindows(GetCurrentThreadId, @CloseWindow, Ord(ConfirmEditor));
end;

procedure RunEditor(Button: PFILTER_ITEM_BUTTON; var Edit: TEDIT_SECTION; Toggle, Confirm: Boolean;
  Candidate: TAnalysisTest = atNone; TitleClose: Boolean = False; MovePoint: Boolean = False);
begin
  EditorSeen := False;
  CommandFound := False;
  ChangeMesh := Toggle;
  ConfirmEditor := Confirm;
  AnalysisTest := Candidate;
  AwaitAnalysis := atNone;
  CloseViaTitle := TitleClose;
  DragPartPoint := MovePoint;
  Timer := SetTimer(0, 0, 350, @EditorTimer);
  try
    if Assigned(Button^.Callback2) then Button^.Callback2(@Edit, Pointer(1), 'モーフィング', '設定')
    else Button^.Callback(@Edit);
  finally
    KillTimer(0, Timer);
  end;
  Check(EditorSeen and CommandFound, 'modal editor and requested window action');
end;

procedure TestPlugin(const DLL, PathA, PathB: string; const Images: TSourceImages; const M: TMorphModel);
var
  H: HMODULE;
  Required: TRequired;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
  Table: PFILTER_PLUGIN_TABLE;
  A, B: PFILTER_ITEM_FILE;
  Item: PFILTER_ITEM_STRING;
  Morph: PFILTER_ITEM_TRACK2;
  Settings: PFILTER_ITEM_BUTTON;
  Video, CPUVideo: TFILTER_PROC_VIDEO;
  Param: TOBJECT_IMAGE_PARAM;
  Edit: TEDIT_SECTION;
  ProgressAt: Integer;
  HostVersion, Version: Cardinal;
  JSON, Invalid: string;
  Before: UTF8String;
  Edited: TMorphModel;
begin
  H := LoadLibrary(PChar(DLL));
  if H = 0 then RaiseLastOSError;
  try
    Required := GetProcAddress(H, 'RequiredVersion');
    Initialize := GetProcAddress(H, 'InitializePlugin');
    Uninitialize := GetProcAddress(H, 'UninitializePlugin');
    GetTable := GetProcAddress(H, 'GetFilterPluginTable');
    Check(Assigned(Required) and Assigned(Initialize) and Assigned(GetTable) and Assigned(Uninitialize), 'AUF2 exports');
    Check((Required() = 2010200) and (Initialize(2010100) = 0), 'SDK requirement starts with per-effect userdata');
    for Version in [2010200, 2010301, 2010601, 2010700, 2010900, 2011000, 2011700] do
    begin
      Check(Initialize(Version) = 1, 'accept supported host ' + IntToStr(Version));
      Table := GetTable();
      Settings := FindItem(Table, '設定');
      Check((Assigned(Settings^.Callback) = (Version < 2011000)) and
        (Assigned(Settings^.Callback2) = (Version >= 2011000)), 'settings button matches the host ABI');
      Check((HasItemKind(Table, 'hiderule') = (Version >= 2010700)) and
        (HasItemKind(Table, 'group') = (Version < 2010700)), 'settings storage uses a supported display item');
      Check(FindItem(Table, 'モーフィング設定データ') <> nil, 'settings data keeps its project key');
    end;
    HostVersion := 2011700;
    if HasSwitch('legacy-host') then HostVersion := 2010200;
    Check(Initialize(HostVersion) = 1, 'initialize the host under test');
    Table := GetTable();
    Check((Table <> nil) and (string(Table^.Name) = 'モーフィング') and (string(Table^.Label_) = 'SYNC'), 'registration');
    Check(Table^.Flag = FILTER_FLAG_VIDEO or FILTER_FLAG_INPUT or FILTER_FLAG_USERDATA, 'media object flags');
    A := FindItem(Table, '画像A');
    B := FindItem(Table, '画像B');
    Item := FindItem(Table, 'モーフィング設定データ');
    Morph := FindItem(Table, 'モーフィング');
    Check((Morph^.Value = 0) and (Morph^.S = 0) and (Morph^.E = 100) and
      SameValue(Morph^.Step, 0.01), 'timeline track range and step');
    A^.Value := PChar(PathA);
    B^.Value := PChar(PathB);
    JSON := ModelJSON(M);
    Item^.Value := PChar(JSON);
    Video := Default(TFILTER_PROC_VIDEO);
    Video.SetImageData := CaptureImage;
    Video.Param := @Param;
    Video.UserData := Table^.Func_Create(1);
    Check(Video.UserData <> nil, 'session allocation');
    try
      Item^.Value := nil;
      Morph^.Value := 50;
      Check(Table^.Func_Proc_Video(@Video) = 1, 'offline detection is used with two images and no settings');
      Check(AtPixel(Captured, 0.5, 0.5).A > 200, 'automatic mesh moves the foreground at the midpoint');
      Check((AtPixel(Captured, 0.28, 0.48).A < 25) and (AtPixel(Captured, 0.72, 0.52).A < 25),
        'automatic midpoint leaves no copies at either original position');
      for ProgressAt in [25, 75] do
      begin
        Morph^.Value := ProgressAt;
        Check(Table^.Func_Proc_Video(@Video) = 1, 'automatic intermediate video callback');
        Check(AtPixel(Captured, 0.28 + 0.44 * ProgressAt / 100, 0.48 + 0.04 * ProgressAt / 100).A > 200,
          'automatic foreground follows the interpolated geometry between endpoints');
      end;
      Morph^.Value := 50;
      CPUVideo := Video;
      Video.CreateImageResource := CreateNativeResource;
      Video.ClearImageResource := ClearNativeResource;
      Video.DrawPolyToResource := DrawNativeMesh;
      Video.ExecPixelshaderData := MixNativeShader;
      Video.GetImageResourceSize := NativeImageSize;
      Video.SetSamplerMode := SetNativeSampler;
      Video.SetCullingState := SetNativeCulling;
      Check(Table^.Func_Proc_Video(@Video) = 1, 'native warp callback');
      Check((NativeResources = 4) and (NativeTriangles = 4) and (NativeMixes = 1) and
        (NativeUploads = 1) and (NativeContourUploads = 2),
        'GPU uses both warped contours and both warped textures without a full-frame CPU transfer');
      Check(Table^.Func_Proc_Video(@Video) = 1, 'repeat GPU contour callback');
      Check((NativeContourUploads = 2) and (NativeMixes = 2), 'GPU retains both contour fields in its cache');
      Video := CPUVideo;
      Item^.Value := PChar(JSON);
      for ProgressAt in [0, 50, 100, 50, 0] do
      begin
        Morph^.Value := ProgressAt;
        Param := Default(TOBJECT_IMAGE_PARAM);
        Param.SX := 1;
        Param.SY := 1;
        Param.SZ := 1;
        Param.Alpha := 1;
        Check(Table^.Func_Proc_Video(@Video) = 1, 'video callback');
        case ProgressAt of
          0: CheckSame(Captured, Images[isA], 'AUF2 A endpoint');
          50: Check(AtPixel(Captured, 0.5, 0.5).A > 235, 'AUF2 midpoint');
          100: CheckSame(Captured, Images[isB], 'AUF2 B endpoint');
        end;
      end;
      PFILTER_ITEM_TRACK(FindItem(Table, 'X'))^.Value := 23.25;
      PFILTER_ITEM_TRACK(FindItem(Table, 'Y'))^.Value := -9;
      PFILTER_ITEM_TRACK(FindItem(Table, '拡大率'))^.Value := 125;
      PFILTER_ITEM_TRACK(FindItem(Table, '回転'))^.Value := 90;
      PFILTER_ITEM_TRACK(FindItem(Table, '透明度'))^.Value := 20;
      Check(Table^.Func_Proc_Video(@Video) = 1, 'output transform callback');
      Check(SameValue(Param.X, 23.25) and SameValue(Param.Y, -9) and SameValue(Param.SX, 1.25) and
        SameValue(Param.RZ, 90) and SameValue(Param.Alpha, 0.8, 0.0001), 'relative host transforms');
      Invalid := '{"v":9}';
      Item^.Value := PChar(Invalid);
      Morph^.Value := 50;
      Check(Table^.Func_Proc_Video(@Video) = 1, 'invalid project data fallback callback');
      Check(AtPixel(Captured, 0.5, 0.5).A < 20, 'invalid JSON clears old mesh');
      Item^.Value := PChar(JSON);
      Check(Table^.Func_Proc_Video(@Video) = 1, 'restored project callback');
      Check(AtPixel(Captured, 0.5, 0.5).A > 235, 'restored project uses saved mesh');
    finally
      Table^.Func_Destroy(1, Video.UserData);
    end;
    if HasSwitch('ui') then
    begin
      Settings := FindItem(Table, '設定');
      Edit := Default(TEDIT_SECTION);
      Edit.GetObjectItemValue := ReadItem;
      Edit.SetObjectItemValue := SaveItem;
      Edit.GetFocusObject := FocusObject;
      Edit.CountObjectEffect := CountMorphEffects;
      Saved := UTF8String(JSON);
      Before := Saved;
      Snapshot := TPath.Combine(TPath.GetDirectoryName(ExpandFileName(ParamStr(2))), 'MorphingEditor.bmp');
      RunEditor(Settings, Edit, True, False);
      Check(LayoutError = '', LayoutError);
      Check(ContextMenuCount = 4, 'both source images, preview and regions share the automatic detection shortcut in their context menus');
      if HasSwitch('dpi-ui') then
        Check(LayoutChecks = 6, 'initial layout, four DPI layouts and quality dialog captured');
      Check((Before = Saved) and (SaveCalls = 0), 'cancel discards a change');
      Snapshot := '';
      RunEditor(Settings, Edit, True, True);
      Check((SaveCalls = 1) and not ReadModel(string(Saved)).ShowMesh and
        (Length(ReadModel(string(Saved)).Mesh.Layers) > 0), 'OK saves settings and triangle topology');
      RunEditor(Settings, Edit, False, True);
      Check(SaveCalls = 1, 'unchanged OK avoids overwriting the project item');
      Saved := '';
      RunEditor(Settings, Edit, False, True);
      Check((SaveCalls = 2) and (Length(ReadModel(string(Saved)).Points) > 0),
        'confirming initial local detection stores it in the project');
      Saved := UTF8String(JSON);
      RunEditor(Settings, Edit, False, False, atLocal);
      Check((SaveCalls = 2) and (Saved = UTF8String(JSON)), 'cancel discards the candidate');
      RunEditor(Settings, Edit, False, True, atLocal);
      Check((SaveCalls = 3) and ReadModel(string(Saved)).Regions[0].AutoGrid, 'WM_CLOSE adopts the candidate');
      Saved := UTF8String(JSON);
      RunEditor(Settings, Edit, False, False, atLocal, True);
      Check((SaveCalls = 4) and ReadModel(string(Saved)).Regions[0].AutoGrid, 'system window close adopts the candidate');
      if HasSwitch('codex-ui') then
      begin
        Saved := UTF8String(JSON);
        RunEditor(Settings, Edit, False, False, atCodex, True);
        Check(LayoutError = '', LayoutError);
        Check((SaveCalls = 4) and (Saved = UTF8String(JSON)),
          'closing during a pending Codex inference keeps the last available settings');
        RunEditor(Settings, Edit, False, True, atCodexCancel);
        Check((SaveCalls = 4) and (Saved = UTF8String(JSON)),
          'cancelling a pending Codex inference keeps the last available settings');
      end;
      Saved := UTF8String(JSON);
      RunEditor(Settings, Edit, False, True, atNone, False, True);
      Edited := ReadModel(string(Saved));
      Check((Length(Edited.Points) = Length(M.Points)) and (Edited.Points[4].Region = M.Points[4].Region) and
        SameValue(Edited.Points[4].UV[isA].X, M.Points[4].UV[isA].X + 0.047, 0.008),
        'dragging a visible regional point from the whole-mesh view moves that point');
      TestInheritedFont(H);
    end;
    Uninitialize;
  finally
    FreeLibrary(H);
  end;
end;

procedure TestCodex(const Images: TSourceImages);
var
  Analysis: TCodexAnalysis;
  Candidate: TMorphModel;
  Exe: string;
begin
  Exe := FindCodex;
  Check(Exe <> '', 'locate Codex CLI');
  Writeln('Submitting the two generated circle fixtures to Codex CLI.');
  Analysis := TCodexAnalysis.Create(Images, Exe);
  try
    while not Analysis.Poll(Candidate) do Sleep(250);
    Check((Candidate.Subject[isA] <> '') and (Candidate.Subject[isB] <> ''), 'actual Codex structured response');
    Writeln('Codex returned ', Length(Candidate.Regions), ' region(s) and ', Length(Candidate.Points), ' landmark(s).');
  finally
    Analysis.Free;
  end;
end;

var
  Directory, A, B, C: string;
  Images: TSourceImages;
  Model: TMorphModel;
begin
  try
    if ParamCount < 2 then
      raise EArgumentException.Create('Usage: Morphing_Tests <AUF2> <fixture-directory> [--ui] [--dpi-ui] [--legacy-host] [--codex] [--codex-ui]');
    Directory := ExpandFileName(ParamStr(2));
    TDirectory.CreateDirectory(Directory);
    A := TPath.Combine(Directory, 'morphing-a.png');
    B := TPath.Combine(Directory, 'morphing-b.png');
    C := TPath.Combine(Directory, 'morphing-different-size.png');
    MakeImage(A, 96, 96, 0.28, 0.48, False);
    MakeImage(B, 96, 96, 0.72, 0.52, True);
    MakeImage(C, 142, 58, 0.72, 0.52, True);
    Images[isA] := LoadImage(A);
    Images[isB] := LoadImage(B);
    Model := SetupModel;
    Check(ModelJSON(ReadModel(ModelJSON(Model))) = ModelJSON(Model), 'JSON roundtrip');
    TestVerticalOrientation(Directory);
    TestAutoDetect(Images);
    TestIntermediateSilhouette(Images);
    TestIndependentPartMotion;
    TestOneSidedRegionMotion;
    TestHeadwearMotion;
    TestLocalRegistration;
    TestColoredStrokeField;
    TestRenderer(Images, Model);
    TestImages(Images, C);
    TestPlugin(ExpandFileName(ParamStr(1)), A, B, Images, Model);
    if HasSwitch('codex') then TestCodex(Images);
    Writeln(Checks, ' checks passed.');
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
