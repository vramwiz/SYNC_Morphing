unit Morphing_AutoDetect;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses Morphing_Model, Morphing_Renderer;

function DetectMorphing(const Images: TSourceImages; Refine: Boolean = True): TMorphModel;

implementation

uses System.Types, System.Math, System.SysUtils, AviUtl2FilterTypes, Morphing_Images, Morphing_Registration;

const
  GridLimit = 160;
  ProfileRows = 25;

type
  THistogram = array[Byte] of Integer;
  TRowSpan = record
    Left, Right, FillRatio, GapLeft, GapRight: Single;
  end;
  TSilhouette = record
    Top, Bottom, Ratio: Single;
    Profile: array[0..ProfileRows - 1] of TRowSpan;
    Scanlines: TArray<TRowSpan>;
    Contour: TPointPath;
    W, H: Integer;
    Pixels: TPixelBuffer;
  end;
  TFaceFeatures = record
    LeftEye, RightEye, Mouth, Nose: TPointF;
    Eyes: array[0..1] of TRectF;
    MouthCorners: array[0..1] of TPointF;
    ChinY, FringeY: Single;
  end;

function Median(const Histogram: THistogram; Count: Integer): Byte;
var
  C: Integer;
begin
  for C := Low(Byte) to High(Byte) do
  begin
    Dec(Count, Histogram[C]);
    if Count < 0 then Exit(C);
  end;
  Result := High(Byte);
end;

function NearRGB(const A, B: TPIXEL_RGBA): Boolean; inline;
begin
  Result := (Abs(Integer(A.R) - B.R) <= 26) and (Abs(Integer(A.G) - B.G) <= 26) and
    (Abs(Integer(A.B) - B.B) <= 26);
end;

function ExtractSilhouette(const Image: TMorphImage; out Shape: TSilhouette): Boolean;
var
  W, H, X, Y, I, J, N, EdgeCount, Transparent, NearCount, Head, Tail,
  Component, Largest, NextLargest, Best, Top, Bottom, Left, Right, SampleY,
    Center, LeftEdge, RightEdge: Integer;
  Aspect: Double;
  R, G, B: THistogram;
  Pixels: TPixelBuffer;
  Queue, Tags, RowLeft, RowRight, RowFill: TArray<Integer>;
  CanBeBackground: TArray<Boolean>;
  Backdrop: TPIXEL_RGBA;
  AlphaBack: Boolean;

  function OnEdge(Col, Row: Integer): Boolean;
  begin
    Result := (Col = 0) or (Row = 0) or (Col = W - 1) or (Row = H - 1);
  end;

  procedure Enqueue(Index, Tag: Integer; OnlyBackground: Boolean);
  begin
    if (Tags[Index] <> 0) or (OnlyBackground and not CanBeBackground[Index]) then Exit;
    Tags[Index] := Tag;
    Queue[Tail] := Index;
    Inc(Tail);
  end;

  procedure Flood(Tag: Integer; OnlyBackground: Boolean);
  var
    Index, Col, Row: Integer;
  begin
    Head := 0;
    while Head < Tail do
    begin
      Index := Queue[Head];
      Inc(Head);
      Col := Index mod W;
      Row := Index div W;
      if Col > 0 then Enqueue(Index - 1, Tag, OnlyBackground);
      if Col + 1 < W then Enqueue(Index + 1, Tag, OnlyBackground);
      if Row > 0 then Enqueue(Index - W, Tag, OnlyBackground);
      if Row + 1 < H then Enqueue(Index + W, Tag, OnlyBackground);
    end;
  end;

begin
  Shape := Default(TSilhouette);
  Result := False;
  if (Image.Width < 8) or (Image.Height < 8) then Exit;
  Aspect := Min(1, GridLimit / Max(Image.Width, Image.Height));
  W := Max(1, Round(Image.Width * Aspect));
  H := Max(1, Round(Image.Height * Aspect));
  if (W < 8) or (H < 8) then Exit;
  N := W * H;
  SetLength(Pixels, N);
  R := Default(THistogram);
  G := R;
  B := R;
  EdgeCount := 0;
  Transparent := 0;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      I := Y * W + X;
      Pixels[I] := Pixel(Sample(Image, PointF((X + 0.5) / W, (Y + 0.5) / H)));
      if not OnEdge(X, Y) then Continue;
      Inc(EdgeCount);
      if Pixels[I].A < 32 then Inc(Transparent);
      Inc(R[Pixels[I].R]);
      Inc(G[Pixels[I].G]);
      Inc(B[Pixels[I].B]);
    end;
  AlphaBack := Transparent * 5 >= EdgeCount * 3;
  Backdrop.R := Median(R, EdgeCount div 2);
  Backdrop.G := Median(G, EdgeCount div 2);
  Backdrop.B := Median(B, EdgeCount div 2);
  SetLength(CanBeBackground, N);
  SetLength(Tags, N);
  SetLength(Queue, N);
  NearCount := 0;
  Tail := 0;
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
    begin
      I := Y * W + X;
      if AlphaBack then CanBeBackground[I] := Pixels[I].A < 64
      else CanBeBackground[I] := (Pixels[I].A < 32) or NearRGB(Pixels[I], Backdrop);
      if OnEdge(X, Y) and CanBeBackground[I] then
      begin
        Inc(NearCount);
        Enqueue(I, -1, True);
      end;
    end;
  if NearCount * 4 < EdgeCount * 3 then Exit;
  Flood(-1, True);
  Component := 0;
  Largest := 0;
  NextLargest := 0;
  Best := 0;
  for I := 0 to N - 1 do
    if Tags[I] = 0 then
    begin
      Inc(Component);
      Tail := 0;
      Enqueue(I, Component, False);
      Flood(Component, False);
      if Tail > Largest then
      begin
        NextLargest := Largest;
        Largest := Tail;
        Best := Component;
      end
      else
        NextLargest := Max(NextLargest, Tail);
    end;
  if (Largest < Max(25, N div 125)) or (Largest * 10 > N * 8) or (NextLargest * 2 > Largest) then Exit;
  SetLength(RowLeft, H);
  SetLength(RowRight, H);
  SetLength(RowFill, H);
  Top := H;
  Bottom := -1;
  Left := W;
  Right := -1;
  for Y := 0 to H - 1 do
  begin
    RowLeft[Y] := W;
    RowRight[Y] := -1;
    for X := 0 to W - 1 do
      if Tags[Y * W + X] = Best then
      begin
        RowLeft[Y] := Min(RowLeft[Y], X);
        RowRight[Y] := X;
        Inc(RowFill[Y]);
      end;
    if RowRight[Y] < 0 then Continue;
    Top := Min(Top, Y);
    Bottom := Y;
    Left := Min(Left, RowLeft[Y]);
    Right := Max(Right, RowRight[Y]);
  end;
  if (Bottom - Top < 8) or (Right - Left < 5) then Exit;
  Shape.Top := (Top + 0.5) / H;
  Shape.Bottom := (Bottom + 0.5) / H;
  Shape.Ratio := ((Right - Left + 1) / W * Image.Width) /
    ((Bottom - Top + 1) / H * Image.Height);
  SetLength(Shape.Scanlines, H);
  for Y := Top to Bottom do
  begin
    if RowFill[Y] = 0 then Continue;
    Shape.Scanlines[Y].Left := RowLeft[Y] / W;
    Shape.Scanlines[Y].Right := (RowRight[Y] + 1) / W;
    Shape.Scanlines[Y].FillRatio := RowFill[Y] / (RowRight[Y] - RowLeft[Y] + 1);
    // Measure the inner edges only when both sides of the central gap have foreground.
    Center := (RowLeft[Y] + RowRight[Y]) div 2;
    if Tags[Y * W + Center] = Best then Continue;
    LeftEdge := Center;
    RightEdge := Center;
    while Tags[Y * W + LeftEdge] <> Best do Dec(LeftEdge);
    while Tags[Y * W + RightEdge] <> Best do Inc(RightEdge);
    if (RightEdge - LeftEdge < 3) or
      (Min(LeftEdge - RowLeft[Y], RowRight[Y] - RightEdge) < 2) then Continue;
    Shape.Scanlines[Y].GapLeft := (LeftEdge + 1) / W;
    Shape.Scanlines[Y].GapRight := RightEdge / W;
  end;
  SetLength(Shape.Contour, ProfileRows * 2);
  for I := 0 to ProfileRows - 1 do
  begin
    SampleY := Top + Round((Bottom - Top) * I / (ProfileRows - 1));
    Shape.Profile[I] := Shape.Scanlines[SampleY];
    J := High(Shape.Contour) - I;
    Shape.Contour[I] := PointF(Shape.Profile[I].Left, (SampleY + 0.5) / H);
    Shape.Contour[J] := PointF(Shape.Profile[I].Right, (SampleY + 0.5) / H);
  end;
  Shape.W := W;
  Shape.H := H;
  Shape.Pixels := Pixels;
  Result := True;
end;

function WidthOf(const Span: TRowSpan): Single; inline;
begin
  Result := Span.Right - Span.Left;
end;

function SimilarProfile(const A, B: TSilhouette): Boolean;
var
  MaxA, MaxB, Difference: Single;
  I: Integer;
begin
  if Min(A.Ratio, B.Ratio) / Max(A.Ratio, B.Ratio) < 0.53 then Exit(False);
  MaxA := 0;
  MaxB := 0;
  for I := 0 to ProfileRows - 1 do
  begin
    MaxA := Max(MaxA, WidthOf(A.Profile[I]));
    MaxB := Max(MaxB, WidthOf(B.Profile[I]));
  end;
  Difference := 0;
  for I := 2 to ProfileRows - 3 do
    Difference := Difference + Abs(WidthOf(A.Profile[I]) / MaxA - WidthOf(B.Profile[I]) / MaxB);
  Result := Difference / (ProfileRows - 4) <= 0.23;
end;

function SpanAt(const Shape: TSilhouette; Y: Single): TRowSpan;
var
  Position, Fraction: Single;
  I, J: Integer;
begin
  Position := EnsureRange((Y - Shape.Top) / (Shape.Bottom - Shape.Top), 0, 1) * (ProfileRows - 1);
  I := Trunc(Position);
  J := Min(I + 1, ProfileRows - 1);
  Fraction := Position - I;
  Result.Left := Shape.Profile[I].Left + (Shape.Profile[J].Left - Shape.Profile[I].Left) * Fraction;
  Result.Right := Shape.Profile[I].Right + (Shape.Profile[J].Right - Shape.Profile[I].Right) * Fraction;
  Result.FillRatio := Shape.Profile[I].FillRatio +
    (Shape.Profile[J].FillRatio - Shape.Profile[I].FillRatio) * Fraction;
end;

function ScanlineAt(const Shape: TSilhouette; Y: Single): TRowSpan;
var
  Position, Fraction: Single;
  A, B: TRowSpan;
  I: Integer;
begin
  Position := EnsureRange(Y * Shape.H - 0.5, 0, Shape.H - 1);
  I := Trunc(Position);
  A := Shape.Scanlines[I];
  B := Shape.Scanlines[Min(I + 1, High(Shape.Scanlines))];
  if A.FillRatio = 0 then A := B;
  if B.FillRatio = 0 then B := A;
  if A.FillRatio = 0 then Exit(SpanAt(Shape, Y));
  Fraction := Position - I;
  Result := A;
  Result.Left := A.Left + (B.Left - A.Left) * Fraction;
  Result.Right := A.Right + (B.Right - A.Right) * Fraction;
  if (A.GapRight > A.GapLeft) and (B.GapRight > B.GapLeft) then
  begin
    Result.GapLeft := A.GapLeft + (B.GapLeft - A.GapLeft) * Fraction;
    Result.GapRight := A.GapRight + (B.GapRight - A.GapRight) * Fraction;
  end
  else if Fraction >= 0.5 then
  begin
    Result.GapLeft := B.GapLeft;
    Result.GapRight := B.GapRight;
  end;
end;

function FindHeadBranches(const Shape: TSilhouette; const Face: TFaceFeatures;
  out Branches, Crown: Single): Boolean;
var
  Row, First, Last: Integer;
  RowSpan: TRowSpan;
  FaceWidth: Single;
begin
  First := Round(Shape.Top * Shape.H - 0.5);
  Last := Min(High(Shape.Scanlines) - 1, Round((Shape.Top + Face.LeftEye.Y) * 0.5 * Shape.H));
  FaceWidth := Face.RightEye.X - Face.LeftEye.X;
  Branches := 0;
  for Row := First to Last do
  begin
    RowSpan := Shape.Scanlines[Row];
    if WidthOf(RowSpan) < FaceWidth then Continue;
    if RowSpan.GapRight - RowSpan.GapLeft >= FaceWidth * 0.35 then
    begin
      if Branches = 0 then Branches := (Row + 0.5) / Shape.H;
    end
    else if (Branches > 0) and (RowSpan.FillRatio >= 0.85) and
      (Shape.Scanlines[Row + 1].FillRatio >= 0.85) and
      ((Row + 0.5) / Shape.H - Branches >= 2 / Shape.H) then
    begin
      Crown := (Row + 0.5) / Shape.H;
      Exit(True);
    end;
  end;
  Result := False;
end;

const
  BodySamples = 32;

type
  TBodyTrajectory = array[0..BodySamples] of Single;

function AlignBody(const A, B: TSilhouette; StartA, StartB: Single): TBodyTrajectory;
const
  StepA: array[1..3] of Integer = (1, 1, 2);
  StepB: array[1..3] of Integer = (1, 2, 1);
  Unreachable = 1E6;
var
  Cost: array[0..BodySamples, 0..BodySamples] of Single;
  Prev: array[0..BodySamples, 0..BodySamples] of Byte;
  SamplesA, SamplesB: array[0..BodySamples] of TRowSpan;
  I, J, K, Di, Dj, Selection: Integer;
  WidthA, WidthB, Score, Prior, Best: Single;
begin
  WidthA := 0;
  WidthB := 0;
  for I := 0 to BodySamples do
  begin
    SamplesA[I] := SpanAt(A, StartA + (A.Bottom - StartA) * I / BodySamples);
    SamplesB[I] := SpanAt(B, StartB + (B.Bottom - StartB) * I / BodySamples);
    WidthA := Max(WidthA, WidthOf(SamplesA[I]));
    WidthB := Max(WidthB, WidthOf(SamplesB[I]));
    Result[I] := I / BodySamples;
  end;
  if (WidthA <= 0) or (WidthB <= 0) then Exit;
  for I := 0 to BodySamples do
    for J := 0 to BodySamples do
    begin
      Cost[I, J] := Unreachable;
      Prev[I, J] := 0;
    end;
  Cost[0, 0] := 0;
  // Monotone paths match changes in body width and the gap between limbs.
  for I := 1 to BodySamples do
    for J := Max(1, I - 6) to Min(BodySamples, I + 6) do
    begin
      Score := 2 * Sqr(WidthOf(SamplesA[I]) / WidthA - WidthOf(SamplesB[J]) / WidthB) +
        Sqr(SamplesA[I].FillRatio - SamplesB[J].FillRatio) + 0.0015 * Sqr(I - J);
      Best := Unreachable;
      Selection := 0;
      for K := Low(StepA) to High(StepA) do
      begin
        Di := I - StepA[K];
        Dj := J - StepB[K];
        if (Di < 0) or (Dj < 0) then Continue;
        Prior := Cost[Di, Dj] + Score + 0.022 * Ord(K <> 1);
        if Prior >= Best then Continue;
        Best := Prior;
        Selection := K;
      end;
      Cost[I, J] := Best;
      Prev[I, J] := Selection;
    end;
  if Prev[BodySamples, BodySamples] = 0 then Exit;
  I := BodySamples;
  J := BodySamples;
  while I > 0 do
  begin
    K := Prev[I, J];
    Result[I] := J / BodySamples;
    if StepA[K] = 2 then Result[I - 1] := (J - 0.5) / BodySamples;
    Dec(I, StepA[K]);
    Dec(J, StepB[K]);
  end;
end;

function BodyAt(const Trajectory: TBodyTrajectory; Fraction: Single): Single;
var
  Position: Single;
  I: Integer;
begin
  Position := Fraction * BodySamples;
  I := Min(Trunc(Position), BodySamples - 1);
  Result := Trajectory[I] + (Trajectory[I + 1] - Trajectory[I]) * (Position - I);
end;

function DetectFace(const Shape: TSilhouette; out Face: TFaceFeatures): Boolean;
var
  L, R, Top, Bottom, X, Y, I, N, W, H, StartY, EndY, Head, Tail, Best,
  Left, Right, Upper, Lower, FaceW, FaceH, Center, RX, RY, MouthX, MouthY,
  EyeY, LeftX, RightX, BestX: Integer;
  Queue: TArray<Integer>;
  Warm: TArray<Boolean>;
  Luma: TArray<Single>;
  P: TPIXEL_RGBA;
  Span: TRowSpan;
  Value, BestMouth, BestEyes, LeftScore, RightScore, Score: Single;

  procedure Add(Index: Integer);
  begin
    if not Warm[Index] then Exit;
    Warm[Index] := False;
    Queue[Tail] := Index;
    Inc(Tail);
  end;

  function RowMean(AtX, AtY, Radius: Integer): Single;
  var
    K: Integer;
  begin
    Result := 0;
    for K := AtX - Radius to AtX + Radius do
      Result := Result + Luma[AtY * W + K];
    Result := Result / (2 * Radius + 1);
  end;

  function EyeAt(Row, Expected, Range: Integer; out EyeX: Integer): Single;
  var
    Col: Integer;
    Dark, Cheek, Contrast: Single;
  begin
    Result := -1000;
    EyeX := Expected;
    for Col := Expected - Range to Expected + Range do
    begin
      Dark := (RowMean(Col, Row, RX) + RowMean(Col, Row + 1, RX)) * 0.5;
      Cheek := (RowMean(Col, Row + RY, RX) + RowMean(Col, Row + RY + 1, RX)) * 0.5;
      Contrast := Cheek - Dark - Abs(Col - Expected) * 2;
      if Contrast <= Result then Continue;
      Result := Contrast;
      EyeX := Col;
    end;
  end;

begin
  Result := False;
  Face := Default(TFaceFeatures);
  W := Shape.W;
  H := Shape.H;
  N := W * H;
  StartY := EnsureRange(Round((Shape.Top + (Shape.Bottom - Shape.Top) * 0.12) * H), 1, H - 2);
  EndY := EnsureRange(Round((Shape.Top + (Shape.Bottom - Shape.Top) * 0.52) * H), StartY, H - 2);
  SetLength(Warm, N);
  SetLength(Luma, N);
  SetLength(Queue, N);
  for Y := Max(0, StartY - 1) to Min(H - 1, EndY + 5) do
  begin
    Span := SpanAt(Shape, (Y + 0.5) / H);
    L := EnsureRange(Round((Span.Left + WidthOf(Span) * 0.14) * W), 0, W - 1);
    R := EnsureRange(Round((Span.Right - WidthOf(Span) * 0.14) * W), L, W - 1);
    for X := 0 to W - 1 do
    begin
      I := Y * W + X;
      P := Shape.Pixels[I];
      Luma[I] := (P.R * 0.299 + P.G * 0.587 + P.B * 0.114) * (P.A / 255);
      Warm[I] := (Y >= StartY) and (Y <= EndY) and (X >= L) and (X <= R) and IsSkinTone(P);
    end;
  end;
  Best := 0;
  Left := 0;
  Right := 0;
  Upper := 0;
  Lower := 0;
  for I := StartY * W to (EndY + 1) * W - 1 do
  begin
    if not Warm[I] then Continue;
    Head := 0;
    Tail := 0;
    Add(I);
    L := W;
    R := 0;
    Top := H;
    Bottom := 0;
    while Head < Tail do
    begin
      X := Queue[Head] mod W;
      Y := Queue[Head] div W;
      Inc(Head);
      L := Min(L, X);
      R := Max(R, X);
      Top := Min(Top, Y);
      Bottom := Max(Bottom, Y);
      if X > 0 then Add(Y * W + X - 1);
      if X < W - 1 then Add(Y * W + X + 1);
      if Y > StartY then Add((Y - 1) * W + X);
      if Y < EndY then Add((Y + 1) * W + X);
    end;
    if Tail <= Best then Continue;
    Best := Tail;
    Left := L;
    Right := R;
    Upper := Top;
    Lower := Bottom;
  end;
  FaceW := Right - Left;
  FaceH := Lower - Upper;
  if (Best < 35) or (FaceW < 9) or (FaceH < 9) then Exit;
  if (FaceW < FaceH * 0.6) or (FaceW > FaceH * 3.5) then Exit;
  Center := (Left + Right) div 2;
  RX := Max(1, FaceW div 14);
  BestMouth := -1000;
  MouthX := Center;
  MouthY := Lower - 2;
  for Y := Upper + Round(FaceH * 0.56) to Lower - Max(2, FaceH div 9) do
    for X := Center - Max(1, FaceW div 9) to Center + Max(1, FaceW div 9) do
    begin
      if (X - RX < 0) or (X + RX >= W) then Continue;
      Value := Min(RowMean(X, Y - 2, RX), RowMean(X, Y + 2, RX)) -
        RowMean(X, Y, RX) - Abs(X - Center) * 2;
      if Value <= BestMouth then Continue;
      BestMouth := Value;
      MouthX := X;
      MouthY := Y;
    end;
  if BestMouth < 10 then Exit;
  RX := Max(1, FaceW div 19);
  RY := Max(2, Round(FaceH * 0.20));
  BestEyes := -1000;
  EyeY := Upper;
  LeftX := Center;
  RightX := Center;
  for Y := Upper + Max(1, FaceH div 8) to MouthY - Max(3, FaceH div 7) do
  begin
    X := Center - Round(FaceW * 0.26);
    I := Center + Round(FaceW * 0.26);
    N := Max(1, FaceW div 12);
    if (X - N - RX < 0) or (I + N + RX >= W) then Exit;
    LeftScore := EyeAt(Y, X, N, L);
    RightScore := EyeAt(Y, I, N, BestX);
    if Min(LeftScore, RightScore) < 31 then Continue;
    Score := Min(LeftScore, RightScore) + (LeftScore + RightScore) * 0.4 -
      Abs((Y - MouthY) + FaceH * 0.36) * 1.3;
    if Score <= BestEyes then Continue;
    BestEyes := Score;
    LeftX := L;
    RightX := BestX;
    EyeY := Y;
  end;
  if BestEyes <= 0 then Exit;
  Face.LeftEye := PointF((LeftX + 0.5) / W, (EyeY + 0.5) / H);
  Face.RightEye := PointF((RightX + 0.5) / W, (EyeY + 0.5) / H);
  Face.Mouth := PointF((MouthX + 0.5) / W, (MouthY + 0.5) / H);
  Face.ChinY := (Lower + 0.5) / H;
  Result := True;
end;


function FindHands(const Shape: TSilhouette; Start: Single; out Left, Right: TPointF): Boolean;
var
  Y, X, MinY, MaxY, MinX, MaxX, Mid, A, B, LeftCount, RightCount, Weight, Total: Integer;
  LeftX, RightX, BestLeft, BestRight, WeightedRow: Double;
  Span: TRowSpan;
begin
  MinY := EnsureRange(Round((Start + (Shape.Bottom - Start) * 0.26) * Shape.H), 0, Shape.H - 1);
  MaxY := EnsureRange(Round((Start + (Shape.Bottom - Start) * 0.60) * Shape.H), MinY, Shape.H - 1);
  Total := 0;
  BestLeft := 0;
  BestRight := 0;
  WeightedRow := 0;
  for Y := MinY to MaxY do
  begin
    Span := Shape.Scanlines[Y];
    if Span.FillRatio = 0 then Continue;
    MinX := EnsureRange(Floor(Span.Left * Shape.W), 0, Shape.W - 1);
    MaxX := EnsureRange(Ceil(Span.Right * Shape.W) - 1, MinX, Shape.W - 1);
    Mid := (MaxX - MinX) div 4;
    A := MinX + Mid;
    B := MaxX - Mid;
    LeftCount := 0;
    RightCount := 0;
    LeftX := 0;
    RightX := 0;
    for X := MinX to A do
      if IsSkinTone(Shape.Pixels[Y * Shape.W + X]) then
      begin
        Inc(LeftCount);
        LeftX := LeftX + X + 0.5;
      end;
    for X := B to MaxX do
      if IsSkinTone(Shape.Pixels[Y * Shape.W + X]) then
      begin
        Inc(RightCount);
        RightX := RightX + X + 0.5;
      end;
    Weight := Min(LeftCount, RightCount);
    if Weight < 2 then Continue;
    // Both hands must be visible in the same band. Favor the rows that show both clearly.
    Weight := Weight * Weight;
    Inc(Total, Weight);
    WeightedRow := WeightedRow + Weight * (Y + 0.5);
    BestLeft := BestLeft + Weight * LeftX / LeftCount;
    BestRight := BestRight + Weight * RightX / RightCount;
  end;
  Result := Total >= 16;
  if Result then
  begin
    Left := PointF(BestLeft / (Total * Shape.W), WeightedRow / (Total * Shape.H));
    Right := PointF(BestRight / (Total * Shape.W), Left.Y);
  end;
end;

function FindWaistSeam(const Shape: TSilhouette; Chin, Hands: Single; out Waist: Single): Boolean;
const
  Samples = 11;
var
  Row, First, Last, I, Col, Consistent, PigmentGain, BestRow: Integer;
  Top, Bottom, After: TPIXEL_RGBA;
  Span: TRowSpan;
  Delta: array[0..Samples - 1, 0..2] of Single;
  R, G, B, Separation, Agreement, Score, Best: Single;
begin
  Result := False;
  if (Hands - Chin) * Shape.H < 16 then Exit;
  First := Max(2, Ceil((Chin + 0.34 * (Hands - Chin)) * Shape.H));
  Last := Min(Shape.H - 6, Floor((Chin + 0.84 * (Hands - Chin)) * Shape.H));
  Best := 0;
  BestRow := -1;
  for Row := First to Last do
  begin
    Span := Shape.Scanlines[Row];
    if WidthOf(Span) * Shape.W < Samples + 2 then Continue;
    R := 0;
    G := 0;
    B := 0;
    Consistent := 0;
    PigmentGain := 0;
    for I := 0 to Samples - 1 do
    begin
      Col := EnsureRange(Round((Span.Left + WidthOf(Span) * (0.25 + 0.5 * I / (Samples - 1))) * Shape.W),
        0, Shape.W - 1);
      Top := Shape.Pixels[(Row - 2) * Shape.W + Col];
      Bottom := Shape.Pixels[(Row + 2) * Shape.W + Col];
      Delta[I, 0] := 0;
      Delta[I, 1] := 0;
      Delta[I, 2] := 0;
      if (Top.A < 220) or (Bottom.A < 220) then Continue;
      After := Shape.Pixels[(Row + 5) * Shape.W + Col];
      if not IsFabricPigment(Top) and not IsSkinTone(Top) and
        IsFabricPigment(Bottom) and IsFabricPigment(After) then Inc(PigmentGain);
      Delta[I, 0] := Integer(Top.R) - Bottom.R;
      Delta[I, 1] := Integer(Top.G) - Bottom.G;
      Delta[I, 2] := Integer(Top.B) - Bottom.B;
      R := R + Delta[I, 0];
      G := G + Delta[I, 1];
      B := B + Delta[I, 2];
    end;
    Separation := Sqrt(Sqr(R) + Sqr(G) + Sqr(B)) / Samples;
    if Separation < 24 then Continue;
    for I := 0 to Samples - 1 do
    begin
      Agreement := (R * Delta[I, 0] + G * Delta[I, 1] + B * Delta[I, 2]) / (Separation * Samples);
      if Agreement >= 16 then Inc(Consistent);
    end;
    // Match the entrance to a broad panel instead of pairing its top with another panel's bottom.
    if (Consistent < 7) or (PigmentGain < 6) then Continue;
    Score := Separation * Consistent / Samples + PigmentGain * 3 -
      Abs((Row + 0.5) / Shape.H - (Chin + 0.61 * (Hands - Chin))) * 120;
    if Score <= Best then Continue;
    Best := Score;
    BestRow := Row;
  end;
  if (BestRow < 0) or (Best < 26) then Exit;
  Waist := (BestRow + 0.5) / Shape.H;
  Result := True;
end;

function FindClothingHem(const Shape: TSilhouette; AfterHands: Single; out Hem: Single): Boolean;
var
  Y, X, Left, Right, Start, Stop, Rows, Last, SkinCount: Integer;
  Span: TRowSpan;
  Fractions: array[0..1] of Single;
  Sided: Boolean;
begin
  Start := EnsureRange(Ceil((AfterHands + 0.015) * Shape.H), 0, Shape.H - 1);
  Stop := EnsureRange(Round((AfterHands + 0.55 * (Shape.Bottom - AfterHands)) * Shape.H), Start, Shape.H - 1);
  Fractions[0] := 0.26;
  Fractions[1] := 0.74;
  Rows := 0;
  for Y := Start to Stop do
  begin
    Span := Shape.Scanlines[Y];
    Sided := (Span.Right > Span.Left);
    for var Inside in Fractions do
    begin
      Left := EnsureRange(Round((Span.Left + (Inside - 0.12) * WidthOf(Span)) * Shape.W), 0, Shape.W - 1);
      Right := EnsureRange(Round((Span.Left + (Inside + 0.12) * WidthOf(Span)) * Shape.W), Left, Shape.W - 1);
      SkinCount := 0;
      for X := Left to Right do Inc(SkinCount, Ord(IsSkinTone(Shape.Pixels[Y * Shape.W + X])));
      Sided := Sided and (SkinCount * 2 > Right - Left + 1);
    end;
    if Sided then Inc(Rows) else Rows := 0;
    if Rows < 3 then Continue;
    Last := Y - Rows + 1;
    if Last <= Start then Exit(False); // sleeves or legs are already exposed at both sides
    Hem := (Last + 0.5) / Shape.H;
    Exit(True);
  end;
  Result := False;
end;

function FindFootwearTop(const Shape: TSilhouette; Hem: Single; out Footwear: Single): Boolean;
var
  Row, First, Last, Left, Right, X, Side, Pass, Skin, Samples: Integer;
  Span: TRowSpan;
  Interval: array[0..1] of TPointF;
  Valid: Boolean;
begin
  First := Max(3, Ceil((Hem + 0.27 * (Shape.Bottom - Hem)) * Shape.H));
  Last := Min(Shape.H - 4, Floor((Shape.Bottom - 0.08 * (Shape.Bottom - Hem)) * Shape.H));
  for Row := First to Last do
  begin
    Span := Shape.Scanlines[Row];
    if Span.GapRight <= Span.GapLeft then Continue;
    Interval[0] := PointF(Span.Left, Span.GapLeft);
    Interval[1] := PointF(Span.GapRight, Span.Right);
    Valid := True;
    for Side := 0 to 1 do
    begin
      // Keep the samples inside each leg so its outside line doesn't count as footwear.
      Left := Ceil((Interval[Side].X * 0.78 + Interval[Side].Y * 0.22) * Shape.W);
      Right := Floor((Interval[Side].X * 0.22 + Interval[Side].Y * 0.78) * Shape.W);
      if (Right - Left < 2) or (Left < 0) or (Right >= Shape.W) then
      begin
        Valid := False;
        Break;
      end;
      Skin := 0;
      Samples := (Right - Left + 1) * 2;
      for Pass in [-3, -2] do
        for X := Left to Right do Inc(Skin, Ord(IsSkinTone(Shape.Pixels[(Row + Pass) * Shape.W + X])));
      Valid := Valid and (Skin * 4 >= Samples * 3);
      Skin := 0;
      for Pass in [2, 3] do
        for X := Left to Right do
        begin
          Valid := Valid and (Shape.Pixels[(Row + Pass) * Shape.W + X].A >= 176);
          Inc(Skin, Ord(IsSkinTone(Shape.Pixels[(Row + Pass) * Shape.W + X])));
        end;
      Valid := Valid and (Skin * 4 <= Samples);
    end;
    if not Valid then Continue;
    Footwear := (Row + 0.5) / Shape.H;
    Exit(True);
  end;
  Result := False;
end;

function HasFabricContrast(const Shape: TSilhouette; const Band: TPointF): Boolean;
var
  X, Y, Pigment, Plain, Left, Right: Integer;
  Span: TRowSpan;
  P: TPIXEL_RGBA;
begin
  Pigment := 0;
  Plain := 0;
  for Y := Max(0, Ceil(Band.X * Shape.H)) to Min(Shape.H - 1, Floor(Band.Y * Shape.H)) do
  begin
    Span := Shape.Scanlines[Y];
    Left := EnsureRange(Round((Span.Left + WidthOf(Span) * 0.1) * Shape.W), 0, Shape.W - 1);
    Right := EnsureRange(Round((Span.Right - WidthOf(Span) * 0.1) * Shape.W), Left, Shape.W - 1);
    for X := Left to Right do
    begin
      P := Shape.Pixels[Y * Shape.W + X];
      if (P.A < 176) or IsSkinTone(P) then Continue;
      if IsFabricPigment(P) then Inc(Pigment)
      else if (P.R >= 132) and (P.G >= 132) and (P.B >= 132) then Inc(Plain);
    end;
  end;
  Result := (Min(Pigment, Plain) >= 24) and (4 * Min(Pigment, Plain) > Max(Pigment, Plain));
end;

function RefineEyes(const Image: TMorphImage; var Face: TFaceFeatures): Boolean;
var
  Distance, FaceHeight: Single;
  Left, Right: TRectF;

  function FindEye(const Center: TPointF; out Bounds: TRectF): Boolean;
  const
    Steps = 32;
  var
    X, Y, I: Integer;
    HalfWidth, Top, Height, Tone, Weight, Total, NX, NY, Width, SearchY, Rim, Contrast, Best: Single;
    Horizontal, Vertical: array[0..Steps - 1] of Single;
    View: TPremul;

    function Quantile(const Profile: array of Single; Fraction: Single): Single;
    var
      I: Integer;
      Remaining: Single;
    begin
      Remaining := Total * Fraction;
      for I := 0 to High(Profile) do
      begin
        if (Profile[I] > 0) and (Remaining < Profile[I]) then
          Exit((I + Remaining / Profile[I]) / Steps);
        Remaining := Remaining - Profile[I];
      end;
      Result := 1;
    end;

    function EyeLuma(V: Single): Single;
    var
      Col: Integer;
      SampleAt: TPremul;
    begin
      Result := 0;
      for Col := -2 to 2 do
      begin
        SampleAt := Sample(Image, PointF(Bounds.CenterPoint.X + Col * Bounds.Width * 0.13, V));
        if SampleAt.A < 0.8 then Exit(-255);
        Result := Result + (SampleAt.R * 0.299 + SampleAt.G * 0.587 + SampleAt.B * 0.114) / SampleAt.A;
      end;
      Result := Result / 5;
    end;

  begin
    HalfWidth := Distance * 0.39;
    Width := 2 * HalfWidth;
    Top := Center.Y - 0.55 * FaceHeight;
    Height := 1.23 * FaceHeight;
    Total := 0;
    FillChar(Horizontal, SizeOf(Horizontal), 0);
    FillChar(Vertical, SizeOf(Vertical), 0);
    for Y := 0 to Steps - 1 do
    begin
      NY := (Y + 0.5) / Steps;
      for X := 0 to Steps - 1 do
      begin
        NX := (X + 0.5) / Steps;
        View := Sample(Image, PointF(Center.X - HalfWidth + Width * NX, Top + Height * NY));
        if View.A < 0.7 then Continue;
        Tone := (View.R * 0.299 + View.G * 0.587 + View.B * 0.114) / View.A;
        Weight := Max(0, 156 - Tone) * (1 - 0.55 * Sqr(2 * NX - 1)) *
          (1 - 0.65 * Sqr(2 * NY - 1));
        Horizontal[X] := Horizontal[X] + Weight;
        Vertical[Y] := Vertical[Y] + Weight;
        Total := Total + Weight;
      end;
    end;
    if Total < Steps * Steps * 3 then Exit(False);
    Bounds := RectF(Center.X - HalfWidth + Width * Quantile(Horizontal, 0.08),
      Top + Height * Quantile(Vertical, 0.08),
      Center.X - HalfWidth + Width * Quantile(Horizontal, 0.92),
      Top + Height * Quantile(Vertical, 0.92));
    Result := (Bounds.Width >= Distance * 0.18) and (Bounds.Height >= FaceHeight * 0.28);
    if not Result then Exit;
    // Dark-pixel quantiles favor the upper lash. Search below it for the iris-to-cheek edge.
    Best := 18;
    Rim := Bounds.Bottom;
    for I := 0 to 19 do
    begin
      SearchY := Bounds.Bottom + I * FaceHeight * 0.018;
      if SearchY >= Face.Mouth.Y - 0.14 * FaceHeight then Break;
      Tone := EyeLuma(SearchY + 0.027 * FaceHeight);
      if Tone < 170 then Continue;
      Contrast := Tone - EyeLuma(SearchY - 0.027 * FaceHeight) - 0.4 * I;
      if Contrast <= Best then Continue;
      Best := Contrast;
      Rim := SearchY;
    end;
    Bounds.Bottom := Rim;
  end;

begin
  Distance := Face.RightEye.X - Face.LeftEye.X;
  FaceHeight := Face.Mouth.Y - Face.LeftEye.Y;
  Result := (Distance > 0.025) and (FaceHeight > 0.025) and
    FindEye(Face.LeftEye, Left) and FindEye(Face.RightEye, Right) and
    (Left.Right + 0.008 < Right.Left) and
    (Abs(Left.CenterPoint.Y - Right.CenterPoint.Y) < FaceHeight * 0.25) and
    (Max(Left.Bottom, Right.Bottom) + 0.005 < Face.Mouth.Y);
  if Result then
  begin
    Face.Eyes[0] := Left;
    Face.Eyes[1] := Right;
    Face.LeftEye := Left.CenterPoint;
    Face.RightEye := Right.CenterPoint;
  end;
end;

function FindFringe(const Image: TMorphImage; var Face: TFaceFeatures): Boolean;
const
  Steps = 32;
var
  I, X, K, Above, Below: Integer;
  Start, Step, Center, Span, At, EyeTop: Single;

  function SkinAt(V: Single): Boolean;
  begin
    Result := IsSkinTone(Pixel(Sample(Image, PointF(Center + X * Span, V))));
  end;

begin
  Result := False;
  EyeTop := (Face.Eyes[0].Top + Face.Eyes[1].Top) * 0.5;
  Center := (Face.Eyes[0].Right + Face.Eyes[1].Left) * 0.5;
  Span := (Face.Eyes[1].Left - Face.Eyes[0].Right) * 0.09;
  Start := EyeTop - (Face.Mouth.Y - EyeTop) * 0.42;
  Step := (Min(Face.LeftEye.Y, Face.RightEye.Y) - Start) / Steps;
  if (Span <= 0) or (Step <= 0) or (Start < 0) then Exit;
  // Follow the fringe into the space between the eyes when it gives way to continuous skin.
  for I := Steps downto 4 do
  begin
    Above := 0;
    Below := 0;
    At := Start + I * Step;
    for X := -2 to 2 do
      for K := 1 to 4 do
      begin
        Inc(Above, Ord(SkinAt(At - K * Step)));
        Inc(Below, Ord(SkinAt(At + K * Step)));
      end;
    if (Above > 5) or (Below < 17) then Continue;
    Face.FringeY := At;
    Exit(True);
  end;
end;

function FindCheekSpan(const Image: TMorphImage; const Face: TFaceFeatures; Y: Single; out Edges: TPointF): Boolean;
const
  Steps = 30;
var
  Center, PitchX, PitchY, Distance: Single;

  function SkinSamples(Col: Integer): Integer;
  var
    Row: Integer;
  begin
    Result := 0;
    for Row := -1 to 1 do
      Inc(Result, Ord(IsSkinTone(Pixel(Sample(Image,
        PointF(Center + Col * PitchX, Y + Row * PitchY))))));
  end;

  function Search(Direction: Integer; out Edge: Single): Boolean;
  var
    Col, K, Inside, Outside: Integer;
  begin
    for K := 11 to Steps - 3 do
    begin
      Col := Direction * K;
      Inside := SkinSamples(Col - Direction) + SkinSamples(Col - 2 * Direction);
      Outside := SkinSamples(Col + Direction) + SkinSamples(Col + 2 * Direction);
      if (Inside < 5) or (Outside > 1) then Continue;
      Edge := Center + Col * PitchX;
      Exit(True);
    end;
    Result := False;
  end;

begin
  Center := (Face.LeftEye.X + Face.RightEye.X) * 0.5;
  Distance := Face.RightEye.X - Face.LeftEye.X;
  PitchX := 1.3 * Distance / Steps;
  PitchY := Max(1 / Image.Height, (Face.Mouth.Y - Face.LeftEye.Y) * 0.025);
  Result := Search(-1, Edges.X) and Search(1, Edges.Y) and
    (Edges.Y - Edges.X >= 1.12 * Distance);
end;

function FindNose(const Image: TMorphImage; var Face: TFaceFeatures): Boolean;
const
  Steps = 16;
var
  X, Y, I: Integer;
  FromY, ToY, CenterX, Span, RadiusX, RadiusY, Gap, Best, Contrast, Tone, Light, Dark: Single;
  At: TPointF;
  P: TPremul;
  Ring: array[0..3] of TPointF;

  function Luma(const C: TPremul): Single; inline;
  begin
    Result := (C.R * 0.299 + C.G * 0.587 + C.B * 0.114) / C.A;
  end;

begin
  Result := False;
  CenterX := (Face.LeftEye.X + Face.RightEye.X) * 0.5;
  Gap := Face.Mouth.Y - (Face.LeftEye.Y + Face.RightEye.Y) * 0.5;
  Span := (Face.RightEye.X - Face.LeftEye.X) * 0.12;
  RadiusX := Max(2 / Image.Width, Span * 0.55);
  RadiusY := Max(2 / Image.Height, Gap * 0.09);
  FromY := Max((Face.LeftEye.Y + Face.RightEye.Y) * 0.5 + Gap * 0.24,
    (Face.Eyes[0].Bottom + Face.Eyes[1].Bottom) * 0.5 - Gap * 0.16);
  ToY := Face.Mouth.Y - Gap * 0.24;
  if (FromY >= ToY) or (Span <= 0) then Exit;
  Ring[0] := PointF(-RadiusX, 0);
  Ring[1] := PointF(RadiusX, 0);
  Ring[2] := PointF(0, -RadiusY);
  Ring[3] := PointF(0, RadiusY);
  Best := 0;
  for Y := 0 to Steps do
    for X := -Steps div 2 to Steps div 2 do
    begin
      At := PointF(CenterX + X * Span * 2 / Steps, FromY + (ToY - FromY) * Y / Steps);
      P := Sample(Image, At);
      if P.A < 0.9 then Continue;
      Tone := Luma(P);
      Light := 255;
      Dark := 255;
      for I := 0 to High(Ring) do
      begin
        P := Sample(Image, At + Ring[I]);
        if not IsSkinTone(Pixel(P)) then
        begin
          Light := 0;
          Dark := 0;
          Break;
        end;
        Contrast := Tone - Luma(P);
        Light := Min(Light, Contrast);
        Dark := Min(Dark, -Contrast);
      end;
      // A bright highlight and a dark nose mark can identify the same part in different artwork.
      Contrast := Max(Light - 11, Dark - 22) - Abs(X) * 0.28;
      if Contrast <= Best then Continue;
      Best := Contrast;
      Face.Nose := At;
    end;
  Result := Best > 0;
end;

function FindMouthCorners(const Image: TMorphImage; var Face: TFaceFeatures): Boolean;
const
  HalfWidthSamples = 24;
var
  Col, Row, First, Last, Center, I: Integer;
  Distance, Gap, StepX, StepY, X, Y, Best, Score: Single;
  Above, Below, Middle: TPremul;
  Trace: array[-HalfWidthSamples..HalfWidthSamples] of TPointF;

  function Luma(const C: TPremul): Single; inline;
  begin
    Result := (C.R * 0.299 + C.G * 0.587 + C.B * 0.114) / C.A;
  end;

begin
  Result := False;
  Distance := Face.RightEye.X - Face.LeftEye.X;
  Gap := Face.Mouth.Y - (Face.LeftEye.Y + Face.RightEye.Y) * 0.5;
  StepX := Distance * 0.43 / HalfWidthSamples;
  StepY := Gap / 60;
  if (StepX <= 0) or (StepY <= 0) then Exit;
  for Col := -HalfWidthSamples to HalfWidthSamples do
  begin
    Best := 18;
    Trace[Col] := TPointF.Zero;
    X := Face.Mouth.X + Col * StepX;
    for Row := -20 to 8 do
    begin
      Y := Face.Mouth.Y + Row * StepY;
      Above := Sample(Image, PointF(X, Y - 5 * StepY));
      Below := Sample(Image, PointF(X, Y + 5 * StepY));
      Middle := Sample(Image, PointF(X, Y));
      if Middle.A < 0.9 then Continue;
      if not (IsSkinTone(Pixel(Above)) and IsSkinTone(Pixel(Below))) then Continue;
      Score := Min(Luma(Above), Luma(Below)) - Luma(Middle) - Abs(Row) * 0.28;
      if Score <= Best then Continue;
      Best := Score;
      Trace[Col] := PointF(X, Y);
    end;
  end;
  Center := -4;
  while (Center <= 4) and (Trace[Center].Y = 0) do Inc(Center);
  if Center > 4 then Exit;
  First := Center;
  Last := Center;
  for I := Center - 1 downto Low(Trace) do
  begin
    if First - I > 3 then Break;
    if Trace[I].Y > 0 then First := I;
  end;
  for I := Center + 1 to High(Trace) do
  begin
    if I - Last > 3 then Break;
    if Trace[I].Y > 0 then Last := I;
  end;
  if (First > -4) or (Last < 4) or (Last - First < 11) or
    (First = Low(Trace)) or (Last = High(Trace)) then Exit;
  Face.MouthCorners[0] := Trace[First];
  Face.MouthCorners[1] := Trace[Last];
  Result := True;
end;

function DetectMorphing(const Images: TSourceImages; Refine: Boolean): TMorphModel;
const
  HeadPart = 0;
  LeftEyePart = 1;
  RightEyePart = 2;
  CheekPart = 3;
  BodyPart = 4;
  MouthPart = 5;
  NosePart = 6;
  ChinRow = 18;
  RowFractions: array[0..17] of Single = (0.10, 0.36, 0.64, 0.86, 1, 0.52,
    1, 0.08, 0.16, 0.24, 0.32, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 0.97);
var
  Silhouette: array[TImageSide] of TSilhouette;
  Faces, RefinedFaces: array[TImageSide] of TFaceFeatures;
  Y, Branches, Crown, EyeTop, EyeBottom, BodyStart: array[TImageSide] of Single;
  Found: array[TImageSide] of Boolean;
  R: TMorphRegion;
  Parts: TArray<TMorphRegion>;
  P: TMorphPoint;
  Side: TImageSide;
  Row, ColumnCount, MidColumn, WaistRow, HandRow, HemRow, FootwearRow, CandidateRow: Integer;
  FaceMatch, PairedBranches, Refined, HasChin, PairedFringe, PairedMouth, PairedNose: Boolean;
  Trajectory: TBodyTrajectory;
  LeftHand, RightHand: array[TImageSide] of TPointF;
  WaistPoint, HandPoint, HemPoint, FootwearPoint: array[TImageSide] of Single;
  Fabric: TUVPair;
  BodyAnchors: TPointPath;
  Fraction, RawWaistB, RawHandB, RawHemB, RawFootwearB: Single;

  function ClosestBodyRow(Value: Single; First: Integer): Integer;
  var
    I: Integer;
  begin
    Result := First;
    for I := First + 1 to High(RowFractions) do
      if Abs(RowFractions[I] - Value) < Abs(RowFractions[Result] - Value) then Result := I;
  end;

  function BodyFraction(Side: TImageSide; Fraction: Single): Single;
  var
    I: Integer;
    FromAnchor, ToAnchor: TPointF;
    At: Single;
  begin
    if Side = isA then Exit(Fraction);
    At := BodyAt(Trajectory, Fraction);
    for I := 1 to High(BodyAnchors) do
    begin
      ToAnchor := BodyAnchors[I];
      if At > ToAnchor.X then Continue;
      FromAnchor := BodyAnchors[I - 1];
      Exit(FromAnchor.Y + (At - FromAnchor.X) / (ToAnchor.X - FromAnchor.X) * (ToAnchor.Y - FromAnchor.Y));
    end;
    Result := 1;
  end;

  procedure AddRow(Anchor: Integer; EyeRow: Boolean = False);
  var
    S, Other: TImageSide;
    Col, EyeSide: Integer;
    Spans: array[TImageSide] of TRowSpan;
    Cheeks: TUVPair;
    Span: TRowSpan;
    X, Width, Padding, AnchorWeight, RowAbove, RowBelow, Margin, EyeFraction: Single;
    MatchGap, MatchCheeks: Boolean;
  begin
    for S := Low(S) to High(S) do
    begin
      Spans[S] := ScanlineAt(Silhouette[S], Y[S]);
      if not PairedBranches and (Anchor >= 0) and (Anchor <= 2) then
      begin
        // Disconnected ears and hair tips do not define full-width face anchors.
        Span := SpanAt(Silhouette[S], Faces[S].LeftEye.Y);
        AnchorWeight := (3 - Anchor) * 0.24;
        Spans[S].Left := Spans[S].Left + (Span.Left - Spans[S].Left) * AnchorWeight;
        Spans[S].Right := Spans[S].Right + (Span.Right - Spans[S].Right) * AnchorWeight;
      end;
    end;
    MatchCheeks := Refined and (Anchor in [5, 6]) and
      FindCheekSpan(Images[isA], Faces[isA], Y[isA], Cheeks[isA]) and
      FindCheekSpan(Images[isB], Faces[isB], Y[isB], Cheeks[isB]);
    MatchGap := (Anchor <> 4) and (Anchor <> 6) and
      (Spans[isA].GapRight > Spans[isA].GapLeft) and
      (Spans[isB].GapRight > Spans[isB].GapLeft);
    // 耳や髪など、一方の細い突起を他方の幅いっぱいに引き伸ばさない。
    for S := Low(S) to High(S) do
    begin
      Other := TImageSide(1 - Ord(S));
      Width := WidthOf(Spans[Other]) * Images[Other].Width / Images[S].Width * 0.55;
      Padding := Max(0, (Width - WidthOf(Spans[S])) * 0.5);
      Spans[S].Left := Max(0, Spans[S].Left - Padding);
      Spans[S].Right := Min(1, Spans[S].Right + Padding);
    end;
    for Col := 0 to ColumnCount - 1 do
    begin
      EyeSide := -1;
      if Refined then
      begin
        if (Anchor < 4) or (EyeRow and (Col in [0, 8])) then P.Region := HeadPart
        else if EyeRow and (Col in [1..3]) then
        begin
          P.Region := LeftEyePart;
          EyeSide := 0;
        end
        else if EyeRow and (Col in [5..7]) then
        begin
          P.Region := RightEyePart;
          EyeSide := 1;
        end
        else if (Anchor = 6) and ((Col = MidColumn) or (PairedMouth and (Abs(Col - MidColumn) = 1))) then
          P.Region := MouthPart
        else if PairedNose and (Anchor = 5) and (Col = MidColumn) then P.Region := NosePart
        else if EyeRow or (Anchor in [5, 6, ChinRow]) then P.Region := CheekPart
        else P.Region := BodyPart;
      end;
      for S := Low(S) to High(S) do
      begin
        Span := Spans[S];
        X := Span.Left + WidthOf(Span) * (0.03 + 0.94 * Col / (ColumnCount - 1));
        if MatchGap and not EyeRow then
        begin
          if Col < MidColumn then
            X := Span.Left + (Span.GapLeft - Span.Left) * Col / (MidColumn - 1)
          else if Col > MidColumn then
            X := Span.GapRight + (Span.Right - Span.GapRight) * (Col - MidColumn - 1) / (MidColumn - 1)
          else X := (Span.GapLeft + Span.GapRight) * 0.5;
        end;
        if EyeRow and Refined then
          case Col of
            1: X := Faces[S].Eyes[0].Left;
            2: X := Faces[S].LeftEye.X;
            3: X := Faces[S].Eyes[0].Right;
            4: X := (Faces[S].Eyes[0].Right + Faces[S].Eyes[1].Left) * 0.5;
            5: X := Faces[S].Eyes[1].Left;
            6: X := Faces[S].RightEye.X;
            7: X := Faces[S].Eyes[1].Right;
          end
        else if Anchor = 4 then
          case Col of
            1: X := Faces[S].LeftEye.X;
            2: X := (Faces[S].LeftEye.X + Faces[S].RightEye.X) * 0.5;
            3: X := Faces[S].RightEye.X;
          end;
        if MatchCheeks and (Col >= 1) and (Col < ColumnCount - 1) then
        begin
          RowAbove := (Cheeks[S].X + Cheeks[S].Y) * 0.5;
          if Anchor = 6 then RowAbove := Faces[S].Mouth.X;
          if Col <= MidColumn then
            X := Cheeks[S].X + (RowAbove - Cheeks[S].X) * (Col - 1) / (MidColumn - 1)
          else
            X := RowAbove + (Cheeks[S].Y - RowAbove) * (Col - MidColumn) / (MidColumn - 1);
        end;
        if (Anchor in [6, ChinRow]) and (Col = MidColumn) then X := Faces[S].Mouth.X;
        if PairedNose and (Anchor = 5) and (Col = MidColumn) then X := Faces[S].Nose.X;
        if (Anchor = 6) and PairedMouth then
        begin
          if Col = MidColumn - 1 then
            X := EnsureRange(Faces[S].MouthCorners[0].X, Result.Points[High(Result.Points)].UV[S].X + 0.001,
              Faces[S].Mouth.X - 0.001);
          if Col = MidColumn + 1 then
            X := Min(Faces[S].MouthCorners[1].X, X + 0.008);
        end;
        if (Anchor >= 0) and (Anchor = HandRow) then
        begin
          if Col = 1 then X := LeftHand[S].X;
          if Col = ColumnCount - 2 then X := RightHand[S].X;
        end;
        if Col > 0 then
          X := Max(X, Result.Points[High(Result.Points)].UV[S].X + 0.0001);
        P.UV[S] := PointF(EnsureRange(X, 0.001, 0.999 - (ColumnCount - 1 - Col) * 0.0001), Y[S]);
        if EyeSide >= 0 then
        begin
          EyeFraction := (Y[S] - EyeTop[S]) / (EyeBottom[S] - EyeTop[S]);
          P.UV[S].Y := Faces[S].Eyes[EyeSide].Top + EyeFraction * Faces[S].Eyes[EyeSide].Height;
        end;
        if PairedNose and (Col = MidColumn) then
        begin
          if (Anchor = 5) then P.UV[S].Y := Faces[S].Nose.Y;
          if EyeRow and (Y[S] = EyeBottom[S]) then P.UV[S].Y := Min(Y[S], Faces[S].Nose.Y - 0.003);
        end;
        if (Anchor = 6) and PairedMouth and (Abs(Col - MidColumn) = 1) then
        begin
          RowAbove := Result.Points[Length(Result.Points) - ColumnCount].UV[S].Y;
          Margin := Min(0.002, (Y[S] - RowAbove) * 0.25);
          P.UV[S].Y := EnsureRange(Faces[S].MouthCorners[Ord(Col > MidColumn)].Y,
            RowAbove + Margin, Y[S] + 0.003);
        end;
        if PairedFringe and EyeRow and (Col = MidColumn) and (Y[S] = EyeTop[S]) then
        begin
          RowAbove := Max(Result.Points[Length(Result.Points) - ColumnCount].UV[S].Y, EyeTop[S] - 0.025);
          RowBelow := (EyeTop[S] + EyeBottom[S]) * 0.5;
          Margin := Min(0.005, 0.24 * (RowBelow - RowAbove));
          P.UV[S].Y := EnsureRange(Faces[S].FringeY, RowAbove + Margin, RowBelow - Margin);
        end;
      end;
      Result.Points := Result.Points + [P];
    end;
  end;

  procedure CreatePortraitRegions;
  const
    Names: array[0..6] of string = ('髪・頭部', '画面左の目', '画面右の目', '頬・あご', '胴・服', '口', '鼻');
  var
    Index, K, At, LeftPoint, RightPoint, Rows: Integer;
    S: TImageSide;
    LeftEdge, RightEdge, Path: TPointPath;
    Bounds: TRectF;
  begin
    SetLength(Parts, NosePart + Ord(PairedNose));
    for Index := 0 to High(Parts) do
    begin
      Parts[Index].State := rsMatch;
      Parts[Index].Enabled := True;
      Parts[Index].AutoGrid := True;
      for S := Low(S) to High(S) do
      begin
        Parts[Index].Name[S] := Names[Index];
        if Index = MouthPart then
        begin
          if PairedMouth then
          begin
            Bounds := RectF(Faces[S].MouthCorners[0].X, Min(Faces[S].MouthCorners[0].Y, Faces[S].MouthCorners[1].Y),
              Faces[S].MouthCorners[1].X, Max(Faces[S].Mouth.Y,
              Max(Faces[S].MouthCorners[0].Y, Faces[S].MouthCorners[1].Y)));
            Bounds.Inflate(0.004, 0.003);
            Parts[Index].Contour[S] := [Bounds.TopLeft, PointF(Bounds.Right, Bounds.Top),
              Bounds.BottomRight, PointF(Bounds.Left, Bounds.Bottom)];
          end;
          Continue;
        end;

        LeftEdge := nil;
        RightEdge := nil;
        for K := 0 to Length(Result.Points) div ColumnCount - 1 do
        begin
          LeftPoint := -1;
          RightPoint := -1;
          for At := K * ColumnCount to (K + 1) * ColumnCount - 1 do
            if Result.Points[At].Region = Index then
            begin
              if LeftPoint < 0 then LeftPoint := At;
              RightPoint := At;
            end;
          if LeftPoint < 0 then Continue;
          LeftEdge := LeftEdge + [Result.Points[LeftPoint].UV[S]];
          RightEdge := RightEdge + [Result.Points[RightPoint].UV[S]];
        end;
        Rows := Length(LeftEdge);
        if Rows < 2 then Continue;
        Path := nil;
        SetLength(Path, 2 * Rows);
        for K := 0 to Rows - 1 do
        begin
          Path[K] := LeftEdge[K];
          Path[High(Path) - K] := RightEdge[K];
        end;
        Parts[Index].Contour[S] := Path;
      end;
    end;
  end;

begin
  Result := DefaultModel;
  if (Images[isA].Width = 0) or (Images[isB].Width = 0) then Exit;
  R := Default(TMorphRegion);
  R.State := rsUnknown;
  R.Enabled := True;
  for Side := Low(Side) to High(Side) do
  begin
    Found[Side] := ExtractSilhouette(Images[Side], Silhouette[Side]);
    if Found[Side] then
    begin
      Result.Subject[Side] := '輪郭を検出';
      R.Name[Side] := '輪郭';
      R.Contour[Side] := Silhouette[Side].Contour;
    end
    else
      Result.Subject[Side] := '輪郭を判定できません';
  end;
  if not (Found[isA] or Found[isB]) then Exit;
  PairedBranches := False;
  PairedFringe := False;
  PairedMouth := False;
  PairedNose := False;
  Refined := False;
  WaistRow := -1;
  HandRow := -1;
  HemRow := -1;
  FootwearRow := -1;
  RawFootwearB := 0;
  RawWaistB := 0;
  RawHandB := 0;
  RawHemB := 0;
  ColumnCount := 5;
  MidColumn := 2;
  if Found[isA] and Found[isB] then
  begin
    FaceMatch := DetectFace(Silhouette[isA], Faces[isA]) and DetectFace(Silhouette[isB], Faces[isB]);
    if FaceMatch or SimilarProfile(Silhouette[isA], Silhouette[isB]) then
    begin
      R.State := rsMatch;
      R.AutoGrid := True;
      P := Default(TMorphPoint);
      P.Region := 0;
      P.Has[isA] := True;
      P.Has[isB] := True;
      if FaceMatch then
      begin
        for Side := Low(Side) to High(Side) do
        begin
          Result.Subject[Side] := '輪郭・目・口を検出';
          R.Name[Side] := '輪郭・顔';
        end;
        RefinedFaces := Faces;
        Refined := RefineEyes(Images[isA], RefinedFaces[isA]) and RefineEyes(Images[isB], RefinedFaces[isB]);
        if Refined then
        begin
          Faces := RefinedFaces;
          ColumnCount := 9;
          MidColumn := 4;
        end;
        HasChin := True;
        for Side := Low(Side) to High(Side) do
        begin
          EyeTop[Side] := (Faces[Side].LeftEye.Y + Faces[Side].RightEye.Y) * 0.5;
          EyeBottom[Side] := EyeTop[Side];
          if Refined then
          begin
            EyeTop[Side] := (Faces[Side].Eyes[0].Top + Faces[Side].Eyes[1].Top) * 0.5;
            EyeBottom[Side] := (Faces[Side].Eyes[0].Bottom + Faces[Side].Eyes[1].Bottom) * 0.5;
          end;
          HasChin := HasChin and (Faces[Side].ChinY > Faces[Side].Mouth.Y + 0.015) and
            (Faces[Side].ChinY < Faces[Side].Mouth.Y + 0.09);
        end;
        for Side := Low(Side) to High(Side) do
        begin
          BodyStart[Side] := Faces[Side].Mouth.Y;
          if HasChin then BodyStart[Side] := Faces[Side].ChinY;
        end;
        // The fringe marker is optional per pair. Both images must have a distinct central boundary.
        PairedFringe := Refined and FindFringe(Images[isA], Faces[isA]) and FindFringe(Images[isB], Faces[isB]);
        PairedMouth := Refined and FindMouthCorners(Images[isA], Faces[isA]) and
          FindMouthCorners(Images[isB], Faces[isB]);
        PairedNose := Refined and FindNose(Images[isA], Faces[isA]) and FindNose(Images[isB], Faces[isB]);
        PairedBranches := FindHeadBranches(Silhouette[isA], Faces[isA], Branches[isA], Crown[isA]) and
          FindHeadBranches(Silhouette[isB], Faces[isB], Branches[isB], Crown[isB]) and
          (Crown[isA] < EyeTop[isA] - 0.01) and (Crown[isB] < EyeTop[isB] - 0.01);
        Trajectory := AlignBody(Silhouette[isA], Silhouette[isB], BodyStart[isA], BodyStart[isB]);
        if FindHands(Silhouette[isA], BodyStart[isA], LeftHand[isA], RightHand[isA]) and
          FindHands(Silhouette[isB], BodyStart[isB], LeftHand[isB], RightHand[isB]) then
        begin
          for Side := Low(Side) to High(Side) do
            HandPoint[Side] := (LeftHand[Side].Y - BodyStart[Side]) /
              (Silhouette[Side].Bottom - BodyStart[Side]);
          RawHandB := BodyAt(Trajectory, HandPoint[isA]);
          if (RawHandB > 0.1) and (RawHandB < 0.9) then
          begin
            HandRow := ClosestBodyRow(HandPoint[isA], 7);
            for Side := Low(Side) to High(Side) do Result.Subject[Side] := '輪郭・目・口・手を検出';
            if FindWaistSeam(Silhouette[isA], BodyStart[isA], LeftHand[isA].Y, WaistPoint[isA]) and
              FindWaistSeam(Silhouette[isB], BodyStart[isB], LeftHand[isB].Y, WaistPoint[isB]) then
            begin
              for Side := Low(Side) to High(Side) do
                WaistPoint[Side] := (WaistPoint[Side] - BodyStart[Side]) /
                  (Silhouette[Side].Bottom - BodyStart[Side]);
              RawWaistB := BodyAt(Trajectory, WaistPoint[isA]);
              CandidateRow := ClosestBodyRow(WaistPoint[isA], 7);
              if (CandidateRow < HandRow) and (RawWaistB > 0.05) and (RawWaistB < RawHandB - 0.04) then
                WaistRow := CandidateRow;
            end;
            if FindClothingHem(Silhouette[isA], LeftHand[isA].Y, HemPoint[isA]) and
              FindClothingHem(Silhouette[isB], LeftHand[isB].Y, HemPoint[isB]) then
            begin
              for Side := Low(Side) to High(Side) do
                HemPoint[Side] := (HemPoint[Side] - BodyStart[Side]) /
                  (Silhouette[Side].Bottom - BodyStart[Side]);
              RawHemB := BodyAt(Trajectory, HemPoint[isA]);
              CandidateRow := ClosestBodyRow(HemPoint[isA], 7);
              if (CandidateRow > HandRow) and (RawHemB > RawHandB + 0.04) and
                (RawHemB < 0.95) and (HemPoint[isB] > HandPoint[isB] + 0.025) then
              begin
                HemRow := CandidateRow;
                for Side := Low(Side) to High(Side) do Result.Subject[Side] := '輪郭・目・口・手・裾を検出';
              end;
            end;
          end;
        end;
        if (HemRow >= 0) and
          FindFootwearTop(Silhouette[isA], BodyStart[isA] + (Silhouette[isA].Bottom - BodyStart[isA]) *
            HemPoint[isA], FootwearPoint[isA]) and
          FindFootwearTop(Silhouette[isB], BodyStart[isB] + (Silhouette[isB].Bottom - BodyStart[isB]) *
            HemPoint[isB], FootwearPoint[isB]) then
        begin
          for Side := Low(Side) to High(Side) do
            FootwearPoint[Side] := (FootwearPoint[Side] - BodyStart[Side]) /
              (Silhouette[Side].Bottom - BodyStart[Side]);
          CandidateRow := ClosestBodyRow(FootwearPoint[isA], 7);
          RawFootwearB := BodyAt(Trajectory, FootwearPoint[isA]);
          if (CandidateRow > HemRow) and (RawFootwearB > RawHemB + 0.04) and (RawFootwearB < 0.97) then
            FootwearRow := CandidateRow;
        end;
        BodyAnchors := [PointF(0, 0)];
        if WaistRow >= 0 then BodyAnchors := BodyAnchors + [PointF(RawWaistB, WaistPoint[isB])];
        if HandRow >= 0 then BodyAnchors := BodyAnchors + [PointF(RawHandB, HandPoint[isB])];
        if HemRow >= 0 then BodyAnchors := BodyAnchors + [PointF(RawHemB, HemPoint[isB])];
        if FootwearRow >= 0 then BodyAnchors := BodyAnchors + [PointF(RawFootwearB, FootwearPoint[isB])];
        BodyAnchors := BodyAnchors + [PointF(1, 1)];
        if WaistRow >= 0 then
          for Side := Low(Side) to High(Side) do Result.Subject[Side] :=
            StringReplace(Result.Subject[Side], 'を検出', '・衣装の境界を検出', []);
        if FootwearRow >= 0 then
          for Side := Low(Side) to High(Side) do Result.Subject[Side] :=
            StringReplace(Result.Subject[Side], 'を検出', '・履き口を検出', []);
        if PairedMouth then
          for Side := Low(Side) to High(Side) do Result.Subject[Side] :=
            StringReplace(Result.Subject[Side], 'を検出', '・口角を検出', []);
        if PairedNose then
          for Side := Low(Side) to High(Side) do Result.Subject[Side] :=
            StringReplace(Result.Subject[Side], 'を検出', '・鼻を検出', []);
        for Row := Low(RowFractions) to High(RowFractions) do
        begin
          for Side := Low(Side) to High(Side) do
            if PairedBranches and (Row < 4) then
              case Row of
                0: Y[Side] := Branches[Side];
                1: Y[Side] := (Branches[Side] + Crown[Side]) * 0.5;
                2: Y[Side] := Crown[Side];
                3: Y[Side] := (Crown[Side] + EyeTop[Side]) * 0.5;
              end
            else if Row < 5 then
              Y[Side] := Silhouette[Side].Top + (EyeTop[Side] - Silhouette[Side].Top) * RowFractions[Row]
            else if Row < 7 then
              Y[Side] := EyeBottom[Side] + (Faces[Side].Mouth.Y - EyeBottom[Side]) * RowFractions[Row]
            else
            begin
              Fraction := RowFractions[Row];
              if Row = WaistRow then Fraction := WaistPoint[isA];
              if Row = HandRow then Fraction := HandPoint[isA];
              if Row = HemRow then Fraction := HemPoint[isA];
              if Row = FootwearRow then Fraction := FootwearPoint[isA];
              Fraction := BodyFraction(Side, Fraction);
              Y[Side] := BodyStart[Side] + (Silhouette[Side].Bottom - BodyStart[Side]) * Fraction;
            end;
          AddRow(Row, Refined and (Row = 4));
          if Refined and (Row = 4) then
          begin
            for Side := Low(Side) to High(Side) do Y[Side] := (EyeTop[Side] + EyeBottom[Side]) * 0.5;
            AddRow(Row, True);
            Y := EyeBottom;
            AddRow(Row, True);
          end;
          if HasChin and (Row = 6) then
          begin
            Y := BodyStart;
            AddRow(ChinRow);
          end;
        end;
      end
      else
        for Row in [2, 5, 8, 12, 16, 19, 22] do
        begin
          for Side := Low(Side) to High(Side) do
            Y[Side] := Silhouette[Side].Top + (Silhouette[Side].Bottom - Silhouette[Side].Top) *
              Row / (ProfileRows - 1);
          AddRow(-1);
        end;
    end;
  end;
  if Refined then
  begin
    CreatePortraitRegions;
    Result.Regions := Parts;
    if (WaistRow >= 0) and (HemRow >= 0) then
    begin
      for Side := Low(Side) to High(Side) do
        Fabric[Side] := PointF(BodyStart[Side] + 0.02,
          BodyStart[Side] + (Silhouette[Side].Bottom - BodyStart[Side]) * HemPoint[Side]);
      if HasFabricContrast(Silhouette[isA], Fabric[isA]) and HasFabricContrast(Silhouette[isB], Fabric[isB]) then
        Result.FabricY := Fabric;
    end;
    if Refine then RefineAutomaticMesh(Images, Result);
  end
  else Result.Regions := [R];
end;

end.
