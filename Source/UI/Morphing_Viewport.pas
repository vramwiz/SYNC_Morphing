
unit Morphing_Viewport;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses System.Classes, System.Types, Vcl.Controls, Vcl.Graphics, Morphing_Images;

type
  TMorphViewport = class;
  TOverlayEvent = procedure(View: TMorphViewport; Target: TCanvas) of object;
  TMorphViewport = class(TCustomControl)
  private
    FBitmap: TBitmap;
    FZoom: Single;
    FPan, FLast: TPoint;
    FMoving: Boolean;
    FOnOverlay: TOverlayEvent;
  protected
    procedure Paint; override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetImage(const Image: TMorphImage; Limit: Integer);
    procedure ResetView;
    function ImageRect: TRect;
    function UVAt(X, Y: Integer; out UV: TPointF): Boolean;
    function ScreenPoint(const UV: TPointF): TPoint;
    property PopupMenu;
    property OnOverlay: TOverlayEvent read FOnOverlay write FOnOverlay;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
  end;

implementation

uses Winapi.Windows, System.Math, Vcl.Forms;

constructor TMorphViewport.Create(AOwner: TComponent);
begin
  inherited;
  FBitmap := Vcl.Graphics.TBitmap.Create;
  FZoom := 1;
  DoubleBuffered := True;
  ParentBackground := False;
  TabStop := True;
end;

destructor TMorphViewport.Destroy;
begin
  FBitmap.Free;
  inherited;
end;

procedure TMorphViewport.SetImage(const Image: TMorphImage; Limit: Integer);
begin
  DrawBitmap(Image, FBitmap, Limit);
  Invalidate;
end;

procedure TMorphViewport.ResetView;
begin
  FZoom := 1;
  FPan := Point(0, 0);
  Invalidate;
end;

function TMorphViewport.ImageRect: TRect;
var
  W, H, Inset: Integer;
  Scale: Single;
begin
  if FBitmap.Empty then Exit(TRect.Empty);
  Inset := MulDiv(12, CurrentPPI, USER_DEFAULT_SCREEN_DPI);
  Scale := Min(Max(1, ClientWidth - Inset) / FBitmap.Width,
    Max(1, ClientHeight - Inset) / FBitmap.Height) * FZoom;
  W := Max(1, Round(FBitmap.Width * Scale));
  H := Max(1, Round(FBitmap.Height * Scale));
  Result.Left := (ClientWidth - W) div 2 + FPan.X;
  Result.Top := (ClientHeight - H) div 2 + FPan.Y;
  Result.Right := Result.Left + W;
  Result.Bottom := Result.Top + H;
end;

function TMorphViewport.UVAt(X, Y: Integer; out UV: TPointF): Boolean;
var
  R: TRect;
begin
  R := ImageRect;
  if R.IsEmpty then Exit(False);
  UV := PointF((X - R.Left) / R.Width, (Y - R.Top) / R.Height);
  Result := (UV.X >= 0) and (UV.X <= 1) and (UV.Y >= 0) and (UV.Y <= 1);
end;

function TMorphViewport.ScreenPoint(const UV: TPointF): TPoint;
var
  R: TRect;
begin
  R := ImageRect;
  Result := Point(R.Left + Round(UV.X * R.Width), R.Top + Round(UV.Y * R.Height));
end;

procedure TMorphViewport.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  FPan := Point(MulDiv(FPan.X, M, D), MulDiv(FPan.Y, M, D));
  inherited;
end;

procedure TMorphViewport.Paint;
var
  R: TRect;
  OldMode, Saved: Integer;
  S: string;
begin
  Canvas.Brush.Color := $00252120;
  Canvas.FillRect(ClientRect);
  R := ImageRect;
  if R.IsEmpty then
  begin
    S := '画像がありません';
    Canvas.Font.Assign(Font);
    Canvas.Font.Color := $00B9B9B9;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut((ClientWidth - Canvas.TextWidth(S)) div 2,
      (ClientHeight - Canvas.TextHeight(S)) div 2, S);
    Canvas.Brush.Style := bsSolid;
    Exit;
  end;
  OldMode := SetStretchBltMode(Canvas.Handle, HALFTONE);
  Canvas.StretchDraw(R, FBitmap);
  SetStretchBltMode(Canvas.Handle, OldMode);
  if Assigned(FOnOverlay) then
  begin
    Saved := SaveDC(Canvas.Handle);
    try
      IntersectClipRect(Canvas.Handle, 0, 0, Width, Height);
      FOnOverlay(Self, Canvas);
    finally
      RestoreDC(Canvas.Handle, Saved);
    end;
  end;
end;

procedure TMorphViewport.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if CanFocus then SetFocus;
  FMoving := (Button = mbMiddle) or ((Button = mbLeft) and (ssShift in Shift));
  if FMoving then
  begin
    FLast := Point(X, Y);
    MouseCapture := True;
    Screen.Cursor := crSizeAll;
  end
  else inherited;
end;

procedure TMorphViewport.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  if FMoving and not ([ssLeft, ssMiddle] * Shift <> []) then
  begin
    FMoving := False;
    Screen.Cursor := crDefault;
    MouseCapture := False;
  end;
  if FMoving then
  begin
    FPan.Offset(X - FLast.X, Y - FLast.Y);
    FLast := Point(X, Y);
    Invalidate;
  end
  else inherited;
end;

procedure TMorphViewport.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if FMoving then
  begin
    FMoving := False;
    MouseCapture := False;
    Screen.Cursor := crDefault;
  end
  else inherited;
end;

function TMorphViewport.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  Pos, NewPoint: TPoint;
  UV: TPointF;
begin
  if FBitmap.Empty then Exit(inherited);
  Pos := ScreenToClient(MousePos);
  if not UVAt(Pos.X, Pos.Y, UV) then UV := PointF(0.5, 0.5);
  FZoom := EnsureRange(FZoom * Power(1.18, WheelDelta / 120), 0.15, 12);
  NewPoint := ScreenPoint(UV);
  FPan.Offset(Pos.X - NewPoint.X, Pos.Y - NewPoint.Y);
  Invalidate;
  Result := True;
end;

end.
