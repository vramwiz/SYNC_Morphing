unit Morphing_Window;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses Winapi.Windows, Winapi.Messages, System.Types, Vcl.Forms;

type
  TMorphWindow = class(TForm)
  private
    procedure ApplyWindowsTheme;
    procedure WMSettingChange(var Message: TMessage); message WM_SETTINGCHANGE;
    procedure FitToWorkArea(const Work: TRect; Center: Boolean);
  protected
    procedure CreateWnd; override;
    procedure DoAfterMonitorDpiChanged(OldDPI, NewDPI: Integer); override;
    function Pixels(Logical: Integer): Integer;
    procedure CenterOnMonitor(LogicalWidth, LogicalHeight: Integer);
  end;

implementation

uses System.SysUtils, System.Math, System.Win.Registry, Vcl.Controls, Vcl.Graphics,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Themes, Vcl.Styles;

type
  TPanelAccess = class(TCustomPanel);

const
  DarkStyle = 'Windows Modern Dark';
  PersonalizeKey = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';

function WindowsPrefersDark: Boolean;
var
  Contrast: THighContrast;
  Settings: TRegistry;
begin
  Contrast := Default(THighContrast);
  Contrast.cbSize := SizeOf(Contrast);
  if SystemParametersInfo(SPI_GETHIGHCONTRAST, SizeOf(Contrast), @Contrast, 0) and
    ((Contrast.dwFlags and HCF_HIGHCONTRASTON) <> 0) then Exit(False);
  Settings := TRegistry.Create(KEY_READ);
  try
    Result := Settings.OpenKeyReadOnly(PersonalizeKey) and
      (Settings.GetDataType('AppsUseLightTheme') = rdInteger) and
      (Settings.ReadInteger('AppsUseLightTheme') = 0);
  finally
    Settings.Free;
  end;
end;

procedure TMorphWindow.ApplyWindowsTheme;
var
  Desired: string;
  Background, Foreground: TColor;
  I: Integer;
begin
  Desired := TStyleManager.SystemStyle.Name;
  if WindowsPrefersDark and
    (TStyleManager.IsCustomStyleActive or TStyleManager.TrySetStyle(DarkStyle, False)) then
    Desired := DarkStyle;
  if StyleName <> Desired then StyleName := Desired;
  TStyleManager.DialogsStyleName := Desired;
  Background := clBtnFace;
  Foreground := clWindowText;
  if Desired = DarkStyle then
  begin
    Background := RGB(24, 24, 24);
    Foreground := RGB(236, 236, 236);
  end;
  StyleElements := StyleElements - [seClient];
  Color := Background;
  // ラベルには親のフォントを渡し、文字色の変更で個別のDPI倍率がかからないようにする。
  Font.Color := Foreground;
  for I := 0 to ComponentCount - 1 do
    if Components[I] is TCustomPanel then
    begin
      TPanelAccess(Components[I]).ParentBackground := False;
      TPanelAccess(Components[I]).StyleElements := TPanelAccess(Components[I]).StyleElements - [seClient];
      TPanelAccess(Components[I]).Color := Background;
    end
    else if Components[I] is TLabel then
    begin
      TLabel(Components[I]).Transparent := True;
      TLabel(Components[I]).StyleElements := TLabel(Components[I]).StyleElements - [seFont, seClient];
      TLabel(Components[I]).ParentFont := True;
    end;
end;

procedure TMorphWindow.CreateWnd;
begin
  ApplyWindowsTheme;
  inherited;
  EnableImmersiveDarkMode(StyleName = DarkStyle);
end;

procedure TMorphWindow.WMSettingChange(var Message: TMessage);
begin
  inherited;
  ApplyWindowsTheme;
  EnableImmersiveDarkMode(StyleName = DarkStyle);
end;

function TMorphWindow.Pixels(Logical: Integer): Integer;
begin
  Result := MulDiv(Logical, CurrentPPI, USER_DEFAULT_SCREEN_DPI);
end;

procedure TMorphWindow.FitToWorkArea(const Work: TRect; Center: Boolean);
var
  W, H, X, Y, Gap: Integer;
begin
  Gap := Pixels(8);
  W := Min(Width, Max(1, Work.Width - Gap * 2));
  H := Min(Height, Max(1, Work.Height - Gap * 2));
  if Center then
  begin
    X := Work.Left + (Work.Width - W) div 2;
    Y := Work.Top + (Work.Height - H) div 2;
  end
  else
  begin
    X := EnsureRange(Left, Work.Left, Work.Right - W);
    Y := EnsureRange(Top, Work.Top, Work.Bottom - H);
  end;
  if (X <> Left) or (Y <> Top) or (W <> Width) or (H <> Height) then
    SetBounds(X, Y, W, H);
end;

procedure TMorphWindow.CenterOnMonitor(LogicalWidth, LogicalHeight: Integer);
var
  Active: HWND;
  Target: TMonitor;
  Where: TRect;
  PointerPos: TPoint;
  DPI: Integer;
begin
  Active := GetActiveWindow;
  if Active <> 0 then Target := Screen.MonitorFromWindow(Active)
  else
  begin
    GetCursorPos(PointerPos);
    Target := Screen.MonitorFromPoint(PointerPos);
  end;
  if Target = nil then Exit;
  ApplyWindowsTheme;
  Where := Target.WorkareaRect;
  Position := poDesigned;
  Left := Where.Left;
  Top := Where.Top;
  HandleNeeded;
  DPI := GetDpiForWindow(Handle);
  if DPI = 0 then DPI := Target.PixelsPerInch;
  ScaleForPPI(DPI);
  ClientWidth := MulDiv(LogicalWidth, DPI, USER_DEFAULT_SCREEN_DPI);
  ClientHeight := MulDiv(LogicalHeight, DPI, USER_DEFAULT_SCREEN_DPI);
  FitToWorkArea(Where, True);
end;

procedure TMorphWindow.DoAfterMonitorDpiChanged(OldDPI, NewDPI: Integer);
var
  Where: TRect;
begin
  inherited;
  Where := Monitor.WorkareaRect;
  if (WindowState = wsNormal) and ((Width > Where.Width) or (Height > Where.Height)) then
    FitToWorkArea(Where, False);
end;

end.
