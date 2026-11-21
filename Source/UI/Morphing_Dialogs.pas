
unit Morphing_Dialogs;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses Morphing_Model;

function EditProgress(var Value: Integer): Boolean;
function EditRegion(var R: TMorphRegion): Boolean;
function EditQuality(var M: TMorphModel): Boolean;
function EditAlignment(var A: TMorphAlignment; const LabelText: string): Boolean;
function ChooseRegion(const M: TMorphModel; ExceptIndex: Integer; out Index: Integer): Boolean;

implementation

uses System.SysUtils, System.Classes, System.Math, System.UITypes, Winapi.Windows, Vcl.Controls,
  Vcl.Forms, Vcl.StdCtrls, Morphing_Window;

type
  TFields = class(TMorphWindow)
  private
    FRow: Integer;
    FOK, FCancel: TButton;
    procedure Layout(Sender: TObject);
    procedure AddLabel(const Text: string);
  protected
    procedure DoAfterMonitorDpiChanged(OldDPI, NewDPI: Integer); override;
  public
    constructor Create(const Title: string); reintroduce;
    function Edit(const LabelText, Text: string): TEdit;
    function Choice(const LabelText: string; const Options: array of string; Selected: Integer): TComboBox;
    function Confirm: Boolean;
  end;

constructor TFields.Create(const Title: string);
begin
  inherited CreateNew(nil);
  Caption := Title;
  BorderStyle := bsDialog;
  Font.Name := 'Yu Gothic UI';
  Font.PixelsPerInch := USER_DEFAULT_SCREEN_DPI;
  Font.Size := 10;
  ClientWidth := 490;
  FRow := 14;
end;

procedure TFields.AddLabel(const Text: string);
var
  L: TLabel;
begin
  L := TLabel.Create(Self);
  L.Parent := Self;
  L.Caption := Text;
  L.SetBounds(16, FRow + 4, 230, 25);
end;

function TFields.Edit(const LabelText, Text: string): TEdit;
begin
  AddLabel(LabelText);
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(245, FRow, 228, 28);
  Result.Text := Text;
  Inc(FRow, 35);
end;

function TFields.Choice(const LabelText: string; const Options: array of string; Selected: Integer): TComboBox;
var
  Option: string;
begin
  AddLabel(LabelText);
  Result := TComboBox.Create(Self);
  Result.Parent := Self;
  Result.Style := csDropDownList;
  Result.SetBounds(245, FRow, 228, 28);
  for Option in Options do Result.Items.Add(Option);
  Result.ItemIndex := Selected;
  Inc(FRow, 35);
end;

procedure TFields.Layout(Sender: TObject);
var
  I, InputLeft, InputWidth: Integer;
begin
  if FCancel = nil then Exit;
  InputLeft := Min(Pixels(245), ClientWidth div 2);
  InputWidth := Max(1, ClientWidth - InputLeft - Pixels(17));
  for I := 0 to ControlCount - 1 do
    if (Controls[I] is TEdit) or (Controls[I] is TComboBox) then
    begin
      Controls[I].Left := InputLeft;
      Controls[I].Width := InputWidth;
    end;
  FCancel.Left := ClientWidth - Pixels(17) - FCancel.Width;
  FOK.Left := FCancel.Left - Pixels(8) - FOK.Width;
end;

procedure TFields.DoAfterMonitorDpiChanged(OldDPI, NewDPI: Integer);
begin
  inherited;
  Layout(Self);
end;

function TFields.Confirm: Boolean;
begin
  FOK := TButton.Create(Self);
  FOK.Parent := Self;
  FOK.Caption := 'OK';
  FOK.Default := True;
  FOK.ModalResult := mrOk;
  FOK.SetBounds(277, FRow + 8, 92, 30);
  FCancel := TButton.Create(Self);
  FCancel.Parent := Self;
  FCancel.Caption := 'キャンセル';
  FCancel.Cancel := True;
  FCancel.ModalResult := mrCancel;
  FCancel.SetBounds(377, FRow + 8, 96, 30);
  CenterOnMonitor(490, FRow + 52);
  OnResize := Layout;
  Layout(Self);
  Result := ShowModal = mrOk;
end;

function ReadNumber(const S: string; Low, High: Double): Double;
begin
  if not TryStrToFloat(Trim(S), Result) or IsNan(Result) or IsInfinite(Result) or
    (Result < Low) or (Result > High) then
    raise EConvertError.CreateFmt('%s～%sの数値を入力してください。', [FloatToStr(Low), FloatToStr(High)]);
end;

function EditProgress(var Value: Integer): Boolean;
var
  F: TFields;
  Field: TEdit;
begin
  F := TFields.Create('モーフィング');
  try
    Field := F.Edit('プレビューの変形率（0～100%）', FormatFloat('0.00', Value / 100));
    Result := F.Confirm;
    if Result then Value := Round(ReadNumber(Field.Text, 0, 100) * 100);
  finally
    F.Free;
  end;
end;

function EditRegion(var R: TMorphRegion): Boolean;
var
  F: TFields;
  State, Enabled: TComboBox;
  NameA, NameB, Z: TEdit;
  Order: Integer;
begin
  F := TFields.Create('領域設定');
  try
    NameA := F.Edit('画像Aの領域名', R.Name[isA]);
    NameB := F.Edit('画像Bの領域名', R.Name[isB]);
    NameA.MaxLength := 128;
    NameB.MaxLength := 128;
    State := F.Choice('状態', RegionLabels, Ord(R.State));
    Enabled := F.Choice('領域を描画に使用', ['無効', '有効'], Ord(R.Enabled));
    Z := F.Edit('重なり順（大きいほど手前）', IntToStr(R.Z));
    Result := F.Confirm;
    if not Result then Exit;
    if not TryStrToInt(Trim(Z.Text), Order) or (Order < -10000) or (Order > 10000) then
      raise EConvertError.Create('重なり順は-10000～10000の整数を入力してください。');
    R.Name[isA] := Trim(NameA.Text);
    R.Name[isB] := Trim(NameB.Text);
    R.State := TRegionState(State.ItemIndex);
    R.Enabled := Enabled.ItemIndex = 1;
    R.Z := Order;
  finally
    F.Free;
  end;
end;

function EditQuality(var M: TMorphModel): Boolean;
var
  F: TFields;
  Shape, Mix, Feather: TEdit;
  Smooth, Quality: TComboBox;
  S, B, Boundary: Single;
begin
  F := TFields.Create('画質設定');
  try
    Shape := F.Edit('形状変形の強さ（%）', FloatToStr(M.Shape * 100));
    Mix := F.Edit('画像混合の強さ（%）', FloatToStr(M.Mix * 100));
    Feather := F.Edit('境界ぼかし（px）', FloatToStr(M.Feather));
    Smooth := F.Choice('形状の補間方式', ['線形', '滑らか'], Ord(M.Smooth));
    Quality := F.Choice('プレビュー品質', ['軽量', '標準', '高画質'], M.Quality);
    Result := F.Confirm;
    if not Result then Exit;
    S := ReadNumber(Shape.Text, 0, 100) / 100;
    B := ReadNumber(Mix.Text, 0, 100) / 100;
    Boundary := ReadNumber(Feather.Text, 0, 32);
    M.Shape := S;
    M.Mix := B;
    M.Feather := Boundary;
    M.Smooth := Smooth.ItemIndex = 1;
    M.Quality := Quality.ItemIndex;
  finally
    F.Free;
  end;
end;

function EditAlignment(var A: TMorphAlignment; const LabelText: string): Boolean;
var
  F: TFields;
  X, Y, Scale, Angle: TEdit;
  NewAlign: TMorphAlignment;
begin
  F := TFields.Create(LabelText + 'の位置合わせ');
  try
    X := F.Edit('X（元画像の最大幅を100%とする）', FloatToStr(A.X * 100));
    Y := F.Edit('Y（元画像の最大高を100%とする）', FloatToStr(A.Y * 100));
    Scale := F.Edit('拡大率（%）', FloatToStr(A.Scale * 100));
    Angle := F.Edit('回転（°）', FloatToStr(A.Angle));
    Result := F.Confirm;
    if not Result then Exit;
    NewAlign.X := ReadNumber(X.Text, -200, 200) / 100;
    NewAlign.Y := ReadNumber(Y.Text, -200, 200) / 100;
    NewAlign.Scale := ReadNumber(Scale.Text, 5, 800) / 100;
    NewAlign.Angle := ReadNumber(Angle.Text, -360, 360);
    A := NewAlign;
  finally
    F.Free;
  end;
end;

function ChooseRegion(const M: TMorphModel; ExceptIndex: Integer; out Index: Integer): Boolean;
var
  F: TFields;
  Menu: TComboBox;
  Indices: TArray<Integer>;
  Labels: TArray<string>;
  I: Integer;
begin
  Result := False;
  Labels := nil;
  Indices := nil;
  for I := 0 to High(M.Regions) do
    if I <> ExceptIndex then
    begin
      Labels := Labels + [Format('%d. %s / %s', [I + 1, M.Regions[I].Name[isA], M.Regions[I].Name[isB]])];
      Indices := Indices + [I];
    end;
  if Length(Indices) = 0 then Exit;
  F := TFields.Create('画像Bの領域を入れ替え');
  try
    Menu := F.Choice('入れ替え先の領域', Labels, 0);
    Result := F.Confirm;
    if Result then Index := Indices[Menu.ItemIndex];
  finally
    F.Free;
  end;
end;

end.
