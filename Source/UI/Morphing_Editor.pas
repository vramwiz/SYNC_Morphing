
unit Morphing_Editor;

// SPDX-License-Identifier: GPL-3.0-only
interface

function EditMorphing(const PathA, PathB: string; var JSON: string): Boolean;

implementation

uses System.SysUtils, System.Classes, System.Types, System.Math, System.IOUtils,
  System.UITypes, System.Actions, System.Generics.Collections, Winapi.Windows, Winapi.Messages, Vcl.Controls,
  Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls, Vcl.Graphics, Vcl.Dialogs, Vcl.Themes,
  Vcl.ActnList, Vcl.Menus,
  Morphing_Model, Morphing_Images, Morphing_Mesh, Morphing_Renderer,
  Morphing_Viewport, Morphing_Dialogs, Morphing_Analysis, Morphing_Window, Morphing_AutoDetect;

type
  TEditorPopupMenu = class(TPopupMenu)
  public
    procedure Popup(X, Y: Integer); override;
  end;

  TEditor = class(TMorphWindow)
  private
    FModel: TMorphModel;
    FImages: TSourceImages;
    FRenderer: TMorphRenderer;
    FAnalysis: TMorphAnalysisTask;
    FAnalysisStarted: UInt64;
    FResumeRegion: Integer;
    FOriginalCandidate: string;
    FStatus, FSubjects, FPercent, FRegionsHeading: TLabel;
    FAnalysisActivity: TPaintBox;
    FLeft, FSourceHost, FA, FB, FMain, FPreviewHost, FPreviewBar: TPanel;
    FRegions: TListBox;
    FSlider: TTrackBar;
    FTimer: TTimer;
    FKeyMenu: TMenuItem;
    FViewportMenu, FRegionMenu: TPopupMenu;
    FLocalAnalyze, FAnalyze, FApply, FDiscard, FUndoAction, FRedoAction, FMeshAction: TAction;
    FPointMode, FOutlineMode, FDeleteAction: TAction;
    FView: array[TImageSide] of TMorphViewport;
    FPreview: TMorphViewport;
    FUndo, FRedo: TList<string>;
    FVertex, FContour, FDrag: Integer;
    FDragView, FActiveView: TMorphViewport;
    FDragStart: TPoint;
    FDirty, FMasksDirty, FPreviewDirty, FDragging, FRelink, FSyncing, FRepairNeeded: Boolean;
    FContourMode, FInitialAuto, FInitialAnalysis, FDiscardChanges: Boolean;
    function Region: Integer;
    function Editable: Boolean;
    procedure Layout(Sender: TObject);
    procedure BuildMenus;
    procedure LocalAnalysisClick(Sender: TObject);
    procedure BeginAnalysis(const Exe: string; LocalPreview: Boolean);
    procedure StopAnalysis;
    procedure UpdateAnalysis;
    procedure PaintAnalysisActivity(Sender: TObject);
    procedure RegionMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure UpdateDeleteAction(Sender: TObject);
    procedure WMGetMinMaxInfo(var Message: TWMGetMinMaxInfo); message WM_GETMINMAXINFO;
    procedure Status(const Text: string);
    procedure Remember;
    procedure Capture(const JSON: string);
    procedure RefreshLists(Selected: Integer);
    procedure ChangeGeometry(Masks: Boolean);
    procedure Prepare;
    function SaveJSON: string;
    procedure SetProgress(Progress: Integer);
    procedure ShowProgress;
    procedure TimerTick(Sender: TObject);
    procedure ToggleMesh(Sender: TObject);
    procedure AnalysisClick(Sender: TObject);
    procedure AcceptCandidate(Sender: TObject);
    procedure RejectCandidate(Sender: TObject);
    procedure StartCandidate(const M: TMorphModel; const Source: string);
    procedure UndoClick(Sender: TObject);
    procedure RedoClick(Sender: TObject);
    procedure RegionClick(Sender: TObject);
    procedure AddRegion(Sender: TObject);
    procedure DeleteRegion(Sender: TObject);
    procedure RegionSettings(Sender: TObject);
    procedure SwapB(Sender: TObject);
    procedure QualityClick(Sender: TObject);
    procedure AlignClick(Sender: TObject);
    procedure ResetView(Sender: TObject);
    procedure ModeChange(Sender: TObject);
    procedure RebuildClick(Sender: TObject);
    procedure RelinkClick(Sender: TObject);
    procedure ImportClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure ProgressChange(Sender: TObject);
    procedure PercentClick(Sender: TObject);
    procedure KeySelect(Sender: TObject);
    procedure AddKeyClick(Sender: TObject);
    procedure RemoveKeyClick(Sender: TObject);
    function HitVertex(View: TMorphViewport; X, Y: Integer): Integer;
    function HitContour(View: TMorphViewport; X, Y: Integer): Integer;
    procedure EditPoint(View: TMorphViewport; Hit: Integer; const UV: TPointF);
    procedure EditContour(View: TMorphViewport; const UV: TPointF);
    procedure DeleteSelection(Sender: TObject);
    procedure ViewDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ViewMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ViewUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure DrawOverlay(View: TMorphViewport; Target: TCanvas);
  protected
    procedure DoAfterMonitorDpiChanged(OldDPI, NewDPI: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    function CloseQuery: Boolean; override;
    constructor Create(const PathA, PathB, JSON: string); reintroduce;
    destructor Destroy; override;
  end;

procedure TEditorPopupMenu.Popup(X, Y: Integer);
var
  Command: UINT;
begin
  SetPopupPoint(Point(X, Y));
  DoPopup(Self);
  // Track the menu on the visible modal editor, not VCL's hidden popup-list window.
  Command := UINT(TrackPopupMenuEx(Handle, TPM_RIGHTBUTTON or TPM_RETURNCMD or TPM_NONOTIFY,
    X, Y, TCustomForm(Owner).Handle, nil));
  if Command <> 0 then DispatchCommand(Command);
  DoClose;
end;

function Panel(Owner: TComponent; Parent: TWinControl; Align: TAlign): TPanel;
begin
  Result := TPanel.Create(Owner);
  Result.Parent := Parent;
  Result.Align := Align;
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
end;


procedure TEditor.BuildMenus;
var
  Actions: TActionList;
  Bar: TToolBar;
  Headings: TMainMenu;
  Popups: TArray<TEditorPopupMenu>;
  I: Integer;
  M: TMenuItem;
  Quality, Relink, AddRegionAction, DeleteRegionAction, RegionAction,
    AddKeyAction, RemoveKeyAction, ProgressAction, ResetAction, SwapAction: TAction;

  function Command(const Caption: string; Handler: TNotifyEvent; Key: Word = 0;
    Modifiers: TShiftState = []): TAction;
  begin
    Result := TAction.Create(Actions);
    Result.ActionList := Actions;
    Result.Caption := Caption;
    Result.OnExecute := Handler;
    if Key <> 0 then Result.ShortCut := ShortCut(Key, Modifiers);
  end;

  procedure AddCommands(Parent: TMenuItem; const Commands: array of TAction);
  var
    A: TAction;
    Item: TMenuItem;
  begin
    for A in Commands do
    begin
      Item := TMenuItem.Create(Self);
      if A = nil then Item.Caption := '-' else Item.Action := A;
      Parent.Add(Item);
    end;
  end;

  function Heading(const Caption: string): TMenuItem;
  var
    Item: TMenuItem;
    Popup: TEditorPopupMenu;
  begin
    Item := TMenuItem.Create(Headings);
    Item.Caption := Caption;
    Headings.Items.Add(Item);
    Popup := TEditorPopupMenu.Create(Self);
    Popups := Popups + [Popup];
    Result := Popup.Items;
  end;

begin
  Actions := TActionList.Create(Self);
  Headings := TMainMenu.Create(Self);
  // VCL attaches the first form-owned TMainMenu automatically. The toolbar owns presentation.
  Menu := nil;
  FViewportMenu := TEditorPopupMenu.Create(Self);
  FRegionMenu := TEditorPopupMenu.Create(Self);
  M := Heading('ファイル(&F)');
  AddCommands(M, [Command('JSONを開く…', ImportClick, Ord('O'), [ssCtrl]),
    Command('JSONを保存…', ExportClick, Ord('S'), [ssCtrl])]);

  FLocalAnalyze := Command('自動判定', LocalAnalysisClick, Ord('D'), [ssCtrl]);
  FAnalyze := Command('Codexで詳細判定…', AnalysisClick, Ord('D'), [ssCtrl, ssShift]);
  FApply := Command('判定結果を適用', AcceptCandidate, VK_RETURN, [ssCtrl, ssShift]);
  FDiscard := Command('判定結果を破棄', RejectCandidate);
  FApply.Enabled := False;
  FDiscard.Enabled := False;
  AddCommands(Heading('判定(&A)'), [FLocalAnalyze, FAnalyze, nil, FApply, FDiscard]);

  FUndoAction := Command('元に戻す', UndoClick, Ord('Z'), [ssCtrl]);
  FRedoAction := Command('やり直す', RedoClick, Ord('Y'), [ssCtrl]);
  FPointMode := Command('対応点を編集', ModeChange, Ord('1'), [ssCtrl]);
  FOutlineMode := Command('輪郭を編集', ModeChange, Ord('2'), [ssCtrl]);
  Relink := Command('対応先を変更', RelinkClick, Ord('L'), [ssCtrl]);
  FDeleteAction := Command('選択点を削除', DeleteSelection, VK_DELETE);
  FDeleteAction.OnUpdate := UpdateDeleteAction;
  AddRegionAction := Command('領域を追加…', AddRegion, Ord('N'), [ssCtrl]);
  DeleteRegionAction := Command('領域を削除…', DeleteRegion);
  RegionAction := Command('領域設定…', RegionSettings);
  SwapAction := Command('画像Bの領域を入れ替え…', SwapB);
  AddCommands(Heading('編集(&E)'), [FUndoAction, FRedoAction, nil, FPointMode, FOutlineMode,
    Relink, FDeleteAction, nil, AddRegionAction, RegionAction, DeleteRegionAction, SwapAction]);

  FMeshAction := Command('メッシュを表示', ToggleMesh, Ord('M'), [ssCtrl]);
  ResetAction := Command('表示位置を戻す', ResetView, Ord('0'), [ssCtrl]);
  Quality := Command('画質設定…', QualityClick);
  M := Heading('表示(&V)');
  AddCommands(M, [FMeshAction, ResetAction, Command('メッシュ再生成', RebuildClick,
    Ord('M'), [ssCtrl, ssShift]), nil, Quality]);
  AddCommands(M, [Command('画像Aの位置合わせ…', AlignClick), Command('画像Bの位置合わせ…', AlignClick)]);
  M.Items[M.Count - 1].Action.Tag := Ord(isB);

  M := Heading('プレビュー(&P)');
  ProgressAction := Command('変形率を指定…', PercentClick, Ord('G'), [ssCtrl]);
  AddKeyAction := Command('補正キーを追加', AddKeyClick, Ord('K'), [ssCtrl]);
  RemoveKeyAction := Command('現在の補正キーを削除', RemoveKeyClick, Ord('K'), [ssCtrl, ssShift]);
  AddCommands(M, [ProgressAction, AddKeyAction, RemoveKeyAction]);
  FKeyMenu := TMenuItem.Create(Self);
  FKeyMenu.Caption := '補正キーに移動';
  M.Add(FKeyMenu);

  AddCommands(FViewportMenu.Items, [FLocalAnalyze, FAnalyze, FApply, FDiscard, nil, FPointMode,
    FOutlineMode, Relink, FDeleteAction, nil, FMeshAction, ResetAction, ProgressAction,
    AddKeyAction, RemoveKeyAction, Quality]);
  AddCommands(FRegionMenu.Items, [FLocalAnalyze, FAnalyze, FApply, FDiscard, nil, AddRegionAction,
    RegionAction, DeleteRegionAction, SwapAction]);
  // Keep the bar in the client area so the theme cannot change the system frame's hit tests.
  Bar := TToolBar.Create(Self);
  Bar.Name := 'EditorMenuBar';
  Bar.Parent := Self;
  Bar.Align := alTop;
  Bar.Flat := True;
  Bar.AutoSize := True;
  Bar.Wrapable := False;
  Bar.Menu := Headings;
  for I := 0 to High(Popups) do Bar.Buttons[I].DropdownMenu := Popups[I];
end;

constructor TEditor.Create(const PathA, PathB, JSON: string);
var
  StatusBar, SourcePanel, RegionsBar: TPanel;
  L: TLabel;
  Side: TImageSide;
  Paths: array[TImageSide] of string;
  Failures: string;
begin
  inherited CreateNew(nil);
  Caption := 'モーフィング設定';
  // Keep caption and resize hit-testing in Windows at each monitor DPI.
  StyleElements := StyleElements - [seBorder];
  Name := 'MorphingEditor';
  KeyPreview := True;
  Font.Name := 'Yu Gothic UI';
  Font.PixelsPerInch := USER_DEFAULT_SCREEN_DPI;
  Font.Size := 10;
  ClientWidth := 1250;
  ClientHeight := 840;
  FVertex := -1;
  FContour := -1;
  FDrag := -1;
  FUndo := TList<string>.Create;
  FRedo := TList<string>.Create;
  FRenderer := TMorphRenderer.Create;
  Failures := '';
  try
    FModel := ReadModel(JSON);
    FModel.Mesh.Layers := nil;
  except
    on E: EConvertError do
    begin
      FModel := DefaultModel;
      FRepairNeeded := True;
      Failures := E.Message + ' 設定画面を閉じると新しい設定に置き換わります。';
    end;
  end;
  Paths[isA] := PathA;
  Paths[isB] := PathB;
  for Side := Low(Side) to High(Side) do
    try
      FImages[Side] := LoadImage(Paths[Side]);
    except
      on E: Exception do
        Failures := Trim(Failures + ' 画像' + Char(Ord('A') + Ord(Side)) +
          'を読み込めません（' + E.Message + '）。');
    end;

  BuildMenus;

  StatusBar := Panel(Self, Self, alBottom);
  StatusBar.Height := 28;
  FStatus := TLabel.Create(Self);
  FStatus.Name := 'AnalysisStatus';
  FStatus.Parent := StatusBar;
  FStatus.AlignWithMargins := True;
  FStatus.Margins.Left := 10;
  FStatus.Align := alClient;
  FStatus.AutoSize := False;
  FStatus.Layout := tlCenter;
  FStatus.EllipsisPosition := epEndEllipsis;

  FLeft := Panel(Self, Self, alLeft);
  FLeft.Width := 230;
  RegionsBar := Panel(Self, FLeft, alTop);
  RegionsBar.Height := 25;
  FAnalysisActivity := TPaintBox.Create(Self);
  FAnalysisActivity.Name := 'AnalysisActivity';
  FAnalysisActivity.Parent := RegionsBar;
  FAnalysisActivity.Align := alBottom;
  FAnalysisActivity.AlignWithMargins := True;
  FAnalysisActivity.Margins.SetBounds(8, 0, 8, 0);
  FAnalysisActivity.Height := 3;
  FAnalysisActivity.OnPaint := PaintAnalysisActivity;
  FAnalysisActivity.Visible := False;
  FRegionsHeading := TLabel.Create(Self);
  FRegionsHeading.Parent := RegionsBar;
  FRegionsHeading.Align := alClient;
  FRegionsHeading.AutoSize := False;
  FRegionsHeading.Layout := tlCenter;
  FRegionsHeading.Caption := 'パーツ・領域';
  FRegionsHeading.AlignWithMargins := True;
  FRegionsHeading.Margins.Left := 8;
  FSubjects := TLabel.Create(Self);
  FSubjects.Parent := FLeft;
  FSubjects.Align := alBottom;
  FSubjects.AutoSize := False;
  FSubjects.Height := 43;
  FSubjects.WordWrap := True;
  FSubjects.EllipsisPosition := epEndEllipsis;
  FSubjects.AlignWithMargins := True;
  FSubjects.Margins.SetBounds(8, 3, 8, 3);
  FRegions := TListBox.Create(Self);
  FRegions.Name := 'AnalysisRegionList';
  FRegions.Parent := FLeft;
  FRegions.Align := alClient;
  FRegions.AlignWithMargins := True;
  FRegions.Margins.SetBounds(8, 4, 8, 4);
  FRegions.OnClick := RegionClick;
  FRegions.OnDblClick := RegionSettings;
  FRegions.OnMouseDown := RegionMouseDown;
  FRegions.PopupMenu := FRegionMenu;

  FMain := Panel(Self, Self, alClient);
  FSourceHost := Panel(Self, FMain, alTop);
  FA := Panel(Self, FSourceHost, alNone);
  FB := Panel(Self, FSourceHost, alNone);
  for Side := Low(Side) to High(Side) do
  begin
    if Side = isA then SourcePanel := FA else SourcePanel := FB;
    L := TLabel.Create(Self);
    L.Parent := SourcePanel;
    L.Align := alTop;
    L.AutoSize := False;
    L.Height := 25;
    L.Layout := tlCenter;
    L.EllipsisPosition := epEndEllipsis;
    L.Caption := '画像' + Char(Ord('A') + Ord(Side)) + '  ' + ExtractFileName(Paths[Side]);
    L.AlignWithMargins := True;
    L.Margins.Left := 6;
    L.Hint := Paths[Side];
    L.ShowHint := True;
    FView[Side] := TMorphViewport.Create(Self);
    FView[Side].Parent := SourcePanel;
    FView[Side].Align := alClient;
    FView[Side].Tag := Ord(Side);
    FView[Side].SetImage(FImages[Side], 1280);
  end;

  FPreviewHost := Panel(Self, FMain, alClient);
  FPreviewBar := Panel(Self, FPreviewHost, alTop);
  FPreviewBar.Height := 36;
  L := TLabel.Create(Self);
  L.Parent := FPreviewBar;
  L.Align := alLeft;
  L.Caption := ' プレビュー ';
  L.Layout := tlCenter;
  FPercent := TLabel.Create(Self);
  FPercent.Parent := FPreviewBar;
  FPercent.Align := alRight;
  FPercent.AutoSize := False;
  FPercent.Width := 72;
  FPercent.Alignment := taCenter;
  FPercent.Layout := tlCenter;
  FSlider := TTrackBar.Create(Self);
  FSlider.Parent := FPreviewBar;
  FSlider.Align := alClient;
  FSlider.Min := 0;
  FSlider.Max := 10000;
  FSlider.Frequency := 1000;
  FSlider.PageSize := 100;
  FSlider.Position := 5000;
  FSlider.OnChange := ProgressChange;
  FPreview := TMorphViewport.Create(Self);
  FPreview.Parent := FPreviewHost;
  FPreview.Align := alClient;
  FPreview.Tag := 2;
  for Side := Low(Side) to High(Side) do
  begin
    FView[Side].PopupMenu := FViewportMenu;
    FView[Side].OnOverlay := DrawOverlay;
    FView[Side].OnMouseDown := ViewDown;
    FView[Side].OnMouseMove := ViewMove;
    FView[Side].OnMouseUp := ViewUp;
  end;
  FPreview.PopupMenu := FViewportMenu;
  FPreview.OnOverlay := DrawOverlay;
  FPreview.OnMouseDown := ViewDown;
  FPreview.OnMouseMove := ViewMove;
  FPreview.OnMouseUp := ViewUp;
  CenterOnMonitor(1250, 840);
  FMain.OnResize := Layout;
  OnResize := Layout;
  Layout(Self);
  RefreshLists(-1);
  if Failures <> '' then Status(Failures)
  else if (JSON = '') and (FImages[isA].Width > 0) and (FImages[isB].Width > 0) then
  begin
    FInitialAnalysis := True;
    BeginAnalysis('', True);
  end
  else Status('画像や領域を右クリックして操作。閉じると採用、Escで変更を破棄。');
  ChangeGeometry(True);
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 60;
  FTimer.OnTimer := TimerTick;
  TimerTick(FTimer);
end;

destructor TEditor.Destroy;
begin
  if FTimer <> nil then FTimer.Enabled := False;
  FAnalysis.Free;
  FRenderer.Free;
  FUndo.Free;
  FRedo.Free;
  inherited;
end;

procedure TEditor.Layout(Sender: TObject);
var
  Half, Gap, PaneHeight, Sidebar: Integer;
begin
  if (FPreviewBar = nil) or (FPreview = nil) then Exit;
  Gap := Pixels(6);
  Sidebar := EnsureRange(ClientWidth div 4, Pixels(158), Pixels(230));
  if FLeft.Width <> Sidebar then FLeft.Width := Sidebar;
  FSourceHost.Height := Max(Pixels(55), (FMain.ClientHeight - FPreviewBar.Height + Pixels(30)) div 2);
  Half := Max(1, (FSourceHost.ClientWidth - Gap * 2) div 2);
  PaneHeight := Max(1, FSourceHost.ClientHeight - Gap);
  FA.SetBounds(0, 0, Half, PaneHeight);
  FB.SetBounds(Half + Gap, 0, Max(1, FSourceHost.ClientWidth - Half - Gap * 2), PaneHeight);
end;

procedure TEditor.WMGetMinMaxInfo(var Message: TWMGetMinMaxInfo);
var
  Work: TRect;
begin
  inherited;
  if not HandleAllocated then Exit;
  Work := Monitor.WorkareaRect;
  Message.MinMaxInfo^.ptMinTrackSize.X := Min(Pixels(650), Work.Width);
  Message.MinMaxInfo^.ptMinTrackSize.Y := Min(Pixels(520), Work.Height);
end;

procedure TEditor.DoAfterMonitorDpiChanged(OldDPI, NewDPI: Integer);
begin
  inherited;
  Layout(Self);
end;

function TEditor.Region: Integer;
begin
  if FAnalysis <> nil then Exit(-1);
  Result := Max(-1, FRegions.ItemIndex - 1);
end;

function TEditor.Editable: Boolean;
begin
  Result := (FAnalysis = nil) and (FOriginalCandidate = '');
  if not Result and (FAnalysis = nil) then Status('判定結果を表示中です。閉じると採用されます。');
end;

procedure TEditor.Status(const Text: string);
begin
  FStatus.Caption := Text;
  FStatus.Hint := Text;
  FStatus.ShowHint := True;
end;

procedure TEditor.Capture(const JSON: string);
begin
  if FUndo.Count = 32 then FUndo.Delete(0);
  FUndo.Add(JSON);
  FRedo.Clear;
  FUndoAction.Enabled := True;
  FRedoAction.Enabled := False;
end;

procedure TEditor.Remember;
begin
  Capture(ModelJSON(FModel));
end;

procedure TEditor.ShowProgress;
begin
  FPercent.Caption := FormatFloat('0.00', FSlider.Position / 100) + '%';
  for var I := 0 to FKeyMenu.Count - 1 do
    FKeyMenu.Items[I].Checked := FKeyMenu.Items[I].Tag = FSlider.Position;
end;

function RegionDescription(const R: TMorphRegion): string;
var
  A, B, S: string;
begin
  A := R.Name[isA];
  B := R.Name[isB];
  if A = '' then A := '—';
  if B = '' then B := '—';
  S := RegionLabels[R.State];
  if not R.Enabled then S := '無効';
  if A = B then Result := Format('%s  [%s]', [A, S])
  else Result := Format('%s / %s  [%s]', [A, B, S]);
end;

procedure TEditor.RefreshLists(Selected: Integer);
var
  R: TMorphRegion;
  K: TShapeKey;
  KeyItem: TMenuItem;
begin
  FSyncing := True;
  try
    if FAnalysis = nil then
    begin
      FRegions.Items.BeginUpdate;
      try
        FRegions.Items.Clear;
        FRegions.Items.Add('全体メッシュ');
        for R in FModel.Regions do FRegions.Items.Add(RegionDescription(R));
        FRegions.ItemIndex := EnsureRange(Selected + 1, 0, FRegions.Items.Count - 1);
      finally
        FRegions.Items.EndUpdate;
      end;
      FSubjects.Caption := 'A  ' + FModel.Subject[isA] + sLineBreak + 'B  ' + FModel.Subject[isB];
    end;
    FKeyMenu.Clear;
    for K in FModel.Keys do
    begin
      KeyItem := TMenuItem.Create(Self);
      KeyItem.Caption := FormatFloat('0.00', K.At / 100) + '%';
      KeyItem.Tag := K.At;
      KeyItem.OnClick := KeySelect;
      FKeyMenu.Add(KeyItem);
    end;
    FKeyMenu.Enabled := FKeyMenu.Count <> 0;
    ShowProgress;
    FUndoAction.Enabled := FUndo.Count > 0;
    FRedoAction.Enabled := FRedo.Count > 0;
    FMeshAction.Checked := FModel.ShowMesh;
    FOutlineMode.Checked := FContourMode;
    FPointMode.Checked := not FContourMode;
  finally
    FSyncing := False;
  end;
end;

procedure TEditor.ChangeGeometry(Masks: Boolean);
begin
  FDirty := True;
  FMasksDirty := FMasksDirty or Masks;
  FPreviewDirty := True;
  FView[isA].Invalidate;
  FView[isB].Invalidate;
  FPreview.Invalidate;
end;

procedure TEditor.Prepare;
begin
  if not FDirty then Exit;
  FRenderer.Prepare(FImages, FModel, FMasksDirty);
  FDirty := False;
  FMasksDirty := False;
end;

function TEditor.SaveJSON: string;
var
  M: TMorphModel;
begin
  Prepare;
  M := FModel;
  M.Mesh := FRenderer.SavedMesh;
  Result := ModelJSON(M);
  if Length(Result) > MORPH_MAX_JSON then
    raise EWriteError.Create('編集データが最大サイズを超えています。');
end;

procedure TEditor.TimerTick(Sender: TObject);
const
  PreviewLimits: array[0..2] of Integer = (256, 480, 896);
begin
  FTimer.Enabled := False;
  try
    try
      UpdateAnalysis;
      if FAnalysisActivity.Visible then FAnalysisActivity.Invalidate;
      if FPreviewDirty then
      begin
        FPreviewDirty := False;
        Prepare;
        FPreview.SetImage(FRenderer.Render(FSlider.Position, PreviewLimits[FModel.Quality]), PreviewLimits[FModel.Quality]);
        FView[isA].Invalidate;
        FView[isB].Invalidate;
      end;
    except
      on E: Exception do
      begin
        StopAnalysis;
        Status(E.Message);
      end;
    end;
  finally
    FTimer.Enabled := True;
  end;
end;


procedure TEditor.ToggleMesh(Sender: TObject);
begin
  if not Editable then Exit;
  Remember;
  FModel.ShowMesh := not FModel.ShowMesh;
  RefreshLists(Region);
  FView[isA].Invalidate;
  FView[isB].Invalidate;
  FPreview.Invalidate;
end;

function TEditor.CloseQuery: Boolean;
begin
  Result := inherited CloseQuery;
  // VCL normally assigns mrCancel on a window-manager close of a modal form.
  // Convert that result here, after both system and themed title bar close paths converge.
  if Result and (ModalResult <> mrNone) and not FDiscardChanges then
    ModalResult := mrOk;
end;

procedure TEditor.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) and (Shift = []) then
  begin
    FDiscardChanges := True;
    Key := 0;
    ModalResult := mrCancel;
  end
  else
    inherited;
end;

procedure TEditor.PaintAnalysisActivity(Sender: TObject);
const
  FillDuration = 1500;
  CycleDuration = FillDuration + 150;
  FillColor = TColor($00D77800);
var
  Track: TRect;
  Elapsed: Integer;
begin
  Track := FAnalysisActivity.ClientRect;
  FAnalysisActivity.Canvas.Brush.Color := StyleServices(FAnalysisActivity).GetSystemColor(clBtnShadow);
  FAnalysisActivity.Canvas.FillRect(Track);
  // Codex cannot report a completion fraction. Repeat a left-anchored fill while waiting.
  Elapsed := Integer((GetTickCount64 - FAnalysisStarted) mod CycleDuration);
  Track.Right := Track.Left + MulDiv(Track.Width, Min(Elapsed, FillDuration), FillDuration);
  FAnalysisActivity.Canvas.Brush.Color := FillColor;
  FAnalysisActivity.Canvas.FillRect(Track);
end;

procedure TEditor.BeginAnalysis(const Exe: string; LocalPreview: Boolean);
begin
  FResumeRegion := Region;
  FAnalysisStarted := GetTickCount64;
  FAnalysis := TMorphAnalysisTask.Create(FImages, Exe, LocalPreview);
  FRegions.Items.Clear;
  FSubjects.Caption := '';
  FRegionsHeading.Caption := '解析中';
  FAnalysisActivity.Visible := True;
  RegionClick(Self);
  if Exe = '' then FLocalAnalyze.Caption := '自動判定を中止'
  else FAnalyze.Caption := 'Codexの判定を中止';
  Status('輪郭とパーツを判定中…');
end;

procedure TEditor.StopAnalysis;
begin
  if FAnalysis = nil then Exit;
  FreeAndNil(FAnalysis);
  FAnalysisActivity.Visible := False;
  FRegionsHeading.Caption := 'パーツ・領域';
  FLocalAnalyze.Caption := '自動判定';
  FAnalyze.Caption := 'Codexで詳細判定…';
  FInitialAnalysis := False;
  RefreshLists(FResumeRegion);
  RegionClick(Self);
end;

procedure TEditor.UpdateAnalysis;
const
  Stages: array[asDetecting..asCodex] of string =
    ('輪郭とパーツを判定中', '対応点を細かく調整中', 'Codexに渡す画像を準備中', 'Codexで詳細判定中');
var
  Update: TAnalysisUpdate;
  Source, PreviewText, CountLabel: string;
  R: TMorphRegion;
  Initial: Boolean;
begin
  if FAnalysis = nil then Exit;
  FAnalysis.ReadUpdate(Update);
  for R in Update.CompletedRegions do FRegions.Items.Add(RegionDescription(R));
  Initial := FInitialAnalysis;
  if Update.HasCandidate then
  begin
    if Update.CodexCandidate then Source := 'Codex詳細判定'
    else Source := '自動判定';
    StartCandidate(Update.Candidate, Source);
    if Initial then FInitialAuto := True;
  end;
  if Update.Stage = asFinished then
  begin
    StopAnalysis;
    if Update.Error <> '' then Status(Update.Error)
    else if Initial and (FOriginalCandidate <> '') then
    begin
      AcceptCandidate(Self);
      Status(Format('自動判定完了　領域 %d・特徴点 %d。', [Length(FModel.Regions), Length(FModel.Points)]));
    end
    else if not Update.HasCandidate and (FOriginalCandidate <> '') then
      Status('判定完了。閉じると表示中の結果を採用します。');
    Exit;
  end;
  if FOriginalCandidate <> '' then PreviewText := '。表示中の結果は閉じると採用されます。'
  else if Length(FModel.Points) > 0 then PreviewText := '。現在の結果を表示しています。'
  else PreviewText := '…';
  if FAnalysis.Exe = '' then CountLabel := '判定済み'
  else CountLabel := '予備判定';
  Status(Format('%s %d秒　%s %d件%s', [Stages[Update.Stage], (GetTickCount64 - FAnalysisStarted) div 1000,
    CountLabel, FRegions.Items.Count, PreviewText]));
end;

procedure TEditor.LocalAnalysisClick(Sender: TObject);
begin
  if FAnalysis <> nil then
  begin
    if FAnalysis.Exe = '' then
    begin
      StopAnalysis;
      Status('自動判定を中止しました。');
      Exit;
    end;
    StopAnalysis;
  end;
  if (FImages[isA].Width = 0) or (FImages[isB].Width = 0) then
  begin
    Status('AviUtl2側で画像Aと画像Bを指定してください。');
    Exit;
  end;
  BeginAnalysis('', True);
end;

procedure TEditor.AnalysisClick(Sender: TObject);
var
  Exe: string;
  Dialog: TOpenDialog;
begin
  if FAnalysis <> nil then
  begin
    if FAnalysis.Exe <> '' then
    begin
      StopAnalysis;
      Status('Codexの詳細判定を中止しました。');
      Exit;
    end;
    StopAnalysis;
  end;
  if (FImages[isA].Width = 0) or (FImages[isB].Width = 0) then
  begin
    Status('AviUtl2側で画像Aと画像Bを指定してください。');
    Exit;
  end;
  Exe := FindCodex;
  if Exe = '' then
  begin
    Dialog := TOpenDialog.Create(Self);
    try
      Dialog.Title := 'ログイン済みのCodex CLIを選択';
      Dialog.Filter := 'Codex CLI (codex.exe)|codex.exe';
      Dialog.Options := Dialog.Options + [ofFileMustExist, ofNoChangeDir];
      if not Dialog.Execute then Exit;
      Exe := Dialog.FileName;
    finally
      Dialog.Free;
    end;
  end;
  try
    BeginAnalysis(Exe, Length(FModel.Points) = 0);
  except
    on E: Exception do Status(E.Message);
  end;
end;

procedure TEditor.StartCandidate(const M: TMorphModel; const Source: string);
begin
  if FOriginalCandidate = '' then FOriginalCandidate := ModelJSON(FModel);
  if FAnalysis <> nil then FResumeRegion := -1;
  FDrag := -1;
  FDragging := False;
  FModel.Subject := M.Subject;
  FModel.Regions := M.Regions;
  FModel.Points := M.Points;
  FModel.Refinement := M.Refinement;
  FModel.FabricY := M.FabricY;
  FModel.Keys := nil;
  FVertex := -1;
  FContour := -1;
  FRelink := False;
  FApply.Enabled := True;
  FDiscard.Enabled := True;
  RefreshLists(-1);
  ChangeGeometry(True);
  Status(Format('%s結果　領域 %d・特徴点 %d。閉じると採用されます。',
    [Source, Length(M.Regions), Length(M.Points)]));
end;

procedure TEditor.AcceptCandidate(Sender: TObject);
begin
  if FOriginalCandidate = '' then Exit;
  if FAnalysis <> nil then StopAnalysis;
  Capture(FOriginalCandidate);
  FOriginalCandidate := '';
  FApply.Enabled := False;
  FDiscard.Enabled := False;
  Status('候補を適用しました。「元に戻す」で解析前の編集へ戻せます。');
end;

procedure TEditor.RejectCandidate(Sender: TObject);
begin
  if FOriginalCandidate = '' then Exit;
  if FAnalysis <> nil then StopAnalysis;
  FModel := ReadModel(FOriginalCandidate);
  if Length(FModel.Regions) = 0 then FInitialAuto := False;
  FOriginalCandidate := '';
  FApply.Enabled := False;
  FDiscard.Enabled := False;
  FVertex := -1;
  FContour := -1;
  RefreshLists(-1);
  ChangeGeometry(True);
  Status('解析候補を破棄しました。');
end;

procedure TEditor.UndoClick(Sender: TObject);
begin
  if not Editable or (FUndo.Count = 0) then Exit;
  FRedo.Add(ModelJSON(FModel));
  FModel := ReadModel(FUndo.Last);
  FUndo.Delete(FUndo.Count - 1);
  RegionClick(Self);
  RefreshLists(Region);
  ChangeGeometry(True);
end;

procedure TEditor.RedoClick(Sender: TObject);
begin
  if not Editable or (FRedo.Count = 0) then Exit;
  FUndo.Add(ModelJSON(FModel));
  FModel := ReadModel(FRedo.Last);
  FRedo.Delete(FRedo.Count - 1);
  RegionClick(Self);
  RefreshLists(Region);
  ChangeGeometry(True);
end;

procedure TEditor.RegionClick(Sender: TObject);
begin
  if FSyncing then Exit;
  if FAnalysis <> nil then FRegions.ItemIndex := -1;
  FDrag := -1;
  FDragging := False;
  FVertex := -1;
  FContour := -1;
  FRelink := False;
  FView[isA].Invalidate;
  FView[isB].Invalidate;
  FPreview.Invalidate;
end;

procedure TEditor.RegionMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Index: Integer;
begin
  if Button <> mbRight then Exit;
  Index := FRegions.ItemAtPos(Point(X, Y), True);
  if Index >= 0 then FRegions.ItemIndex := Index;
  RegionClick(Sender);
  FActiveView := nil;
end;

procedure TEditor.AddRegion(Sender: TObject);
var
  R: TMorphRegion;
begin
  if not Editable then Exit;
  if Length(FModel.Regions) >= MORPH_MAX_REGIONS then
  begin
    Status('領域は最大48個です。');
    Exit;
  end;
  R := Default(TMorphRegion);
  R.Enabled := True;
  R.Name[isA] := '領域 ' + IntToStr(Length(FModel.Regions) + 1);
  R.Name[isB] := R.Name[isA];
  try
    if not EditRegion(R) then Exit;
  except
    on E: Exception do
    begin
      Status(E.Message);
      Exit;
    end;
  end;
  Remember;
  FModel.Regions := FModel.Regions + [R];
  RegionClick(Self);
  RefreshLists(High(FModel.Regions));
  ChangeGeometry(True);
end;

procedure TEditor.DeleteRegion(Sender: TObject);
begin
  if not Editable or (Region < 0) then Exit;
  if MessageDlg('選択中の領域とその輪郭・対応点を削除します。', mtConfirmation, [mbOK, mbCancel], 0) <> mrOK then Exit;
  Remember;
  RemoveRegion(FModel, Region);
  RegionClick(Self);
  RefreshLists(-1);
  ChangeGeometry(True);
end;

procedure TEditor.RegionSettings(Sender: TObject);
var
  R: TMorphRegion;
begin
  if not Editable or (Region < 0) then Exit;
  R := FModel.Regions[Region];
  try
    if not EditRegion(R) then Exit;
    Remember;
    R.AutoGrid := False;
    FModel.Regions[Region] := R;
    RefreshLists(Region);
    ChangeGeometry(True);
  except
    on E: Exception do Status(E.Message);
  end;
end;

procedure TEditor.SwapB(Sender: TObject);
var
  I, First, Second, Extra, WhereTo: Integer;
  Path: TPointPath;
  S: string;
  P: TMorphPoint;
begin
  First := Region;
  if not Editable or (First < 0) or not ChooseRegion(FModel, First, Second) then Exit;
  Extra := 0;
  for P in FModel.Points do
    if ((P.Region = First) or (P.Region = Second)) and P.Has[isA] and P.Has[isB] then Inc(Extra);
  if Length(FModel.Points) + Extra > MORPH_MAX_POINTS then
  begin
    Status('対応点の上限を超えるため、入れ替えできません。');
    Exit;
  end;
  Remember;
  S := FModel.Regions[First].Name[isB];
  Path := FModel.Regions[First].Contour[isB];
  FModel.Regions[First].AutoGrid := False;
  FModel.Regions[Second].AutoGrid := False;
  FModel.Regions[First].Name[isB] := FModel.Regions[Second].Name[isB];
  FModel.Regions[First].Contour[isB] := FModel.Regions[Second].Contour[isB];
  FModel.Regions[Second].Name[isB] := S;
  FModel.Regions[Second].Contour[isB] := Path;
  for I := 0 to High(FModel.Points) do
  begin
    P := FModel.Points[I];
    if not P.Has[isB] then Continue;
    if P.Region = First then WhereTo := Second
    else if P.Region = Second then WhereTo := First
    else Continue;
    P.Region := WhereTo;
    if P.Has[isA] then
    begin
      FModel.Points[I].Has[isB] := False;
      P.Has[isA] := False;
      FModel.Points := FModel.Points + [P];
    end
    else
      FModel.Points[I] := P;
  end;
  RegionClick(Self);
  RefreshLists(First);
  ChangeGeometry(True);
  Status('画像Bの領域を入れ替えました。必要な対応点を結び直してください。');
end;

procedure TEditor.QualityClick(Sender: TObject);
var
  M: TMorphModel;
begin
  if not Editable then Exit;
  M := FModel;
  try
    if not EditQuality(M) then Exit;
    Remember;
    FModel := M;
    ChangeGeometry(True);
  except
    on E: Exception do Status(E.Message);
  end;
end;

procedure TEditor.AlignClick(Sender: TObject);
var
  Side: TImageSide;
  A: TMorphAlignment;
begin
  if not Editable then Exit;
  Side := TImageSide(TAction(Sender).Tag);
  A := FModel.Align[Side];
  try
    if not EditAlignment(A, '画像' + Char(Ord('A') + Ord(Side))) then Exit;
    Remember;
    FModel.Align[Side] := A;
    ChangeGeometry(False);
  except
    on E: Exception do Status(E.Message);
  end;
end;

procedure TEditor.ResetView(Sender: TObject);
begin
  FView[isA].ResetView;
  FView[isB].ResetView;
  FPreview.ResetView;
end;

procedure TEditor.ModeChange(Sender: TObject);
begin
  FContourMode := Sender = FOutlineMode;
  RegionClick(Sender);
  RefreshLists(Region);
  if FContourMode then
    Status('領域を選び、画像上をクリックして輪郭を追加します。輪郭は3点以上で描画に反映されます。')
  else
    Status('画像A・Bで点を1つずつ指定します。片側だけの点も保存できます。');
end;

procedure TEditor.RebuildClick(Sender: TObject);
begin
  if not Editable then Exit;
  ChangeGeometry(True);
  Status('対応点と輪郭からメッシュを再生成します。');
end;

procedure TEditor.RelinkClick(Sender: TObject);
begin
  if not Editable then Exit;
  if FVertex < 0 then
  begin
    Status('対応点を選択してから、対応先を変更してください。');
    Exit;
  end;
  FRelink := True;
  Status('新しい対応先を画像上でクリックしてください。');
end;

procedure TEditor.ImportClick(Sender: TObject);
var
  D: TOpenDialog;
  Text: string;
  M: TMorphModel;
  Source: TFileStream;
  FromAnalysis: Boolean;
begin
  if not Editable or (FAnalysis <> nil) then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'JSON|*.json';
    D.Options := D.Options + [ofFileMustExist, ofNoChangeDir];
    if not D.Execute then Exit;
    Source := TFileStream.Create(D.FileName, fmOpenRead or fmShareDenyWrite);
    try
      if Source.Size > MORPH_MAX_JSON * 4 then
        raise EReadError.Create('JSONが大きすぎます。');
      with TStringStream.Create('', TEncoding.UTF8) do
      try
        CopyFrom(Source, Source.Size);
        Text := DataString;
        if (Text <> '') and (Text[1] = #$FEFF) then Delete(Text, 1, 1);
      finally
        Free;
      end;
    finally
      Source.Free;
    end;
    M := ReadImportedModel(Text, FromAnalysis);
    if not FromAnalysis then
    begin
      M.Mesh.Layers := nil;
      Remember;
      FModel := M;
      RegionClick(Self);
      RefreshLists(-1);
      ChangeGeometry(True);
      Status('編集用JSONを読み込みました。');
    end
    else
      StartCandidate(M, 'JSON');
  except
    on E: Exception do Status(E.Message);
  end;
  D.Free;
end;

procedure TEditor.ExportClick(Sender: TObject);
var
  D: TSaveDialog;
begin
  D := TSaveDialog.Create(Self);
  try
    D.Filter := 'JSON|*.json';
    D.DefaultExt := 'json';
    D.Options := D.Options + [ofOverwritePrompt, ofNoChangeDir];
    if D.Execute then
      try
        TFile.WriteAllText(D.FileName, SaveJSON, TEncoding.UTF8);
        Status('JSONを保存しました。');
      except
        on E: Exception do Status(E.Message);
      end;
  finally
    D.Free;
  end;
end;

procedure TEditor.SetProgress(Progress: Integer);
begin
  FSlider.Position := EnsureRange(Progress, 0, 10000);
  ProgressChange(FSlider);
end;

procedure TEditor.ProgressChange(Sender: TObject);
begin
  if FPercent = nil then Exit;
  FSyncing := True;
  try
    ShowProgress;
  finally
    FSyncing := False;
  end;
  FPreviewDirty := True;
end;

procedure TEditor.PercentClick(Sender: TObject);
var
  V: Integer;
begin
  V := FSlider.Position;
  try
    if EditProgress(V) then SetProgress(V);
  except
    on E: EConvertError do Status(E.Message);
  end;
end;

procedure TEditor.KeySelect(Sender: TObject);
begin
  if not FSyncing then SetProgress(TMenuItem(Sender).Tag);
end;

procedure TEditor.AddKeyClick(Sender: TObject);
begin
  if not Editable or (FindKey(FModel, FSlider.Position) >= 0) then Exit;
  if (FSlider.Position = 0) or (FSlider.Position = FSlider.Max) or (Length(FModel.Keys) >= MORPH_MAX_KEYS) then
  begin
    Status('補正キーは0%と100%の間に追加してください（最大64個）。');
    Exit;
  end;
  Remember;
  AddKey(FModel, FSlider.Position);
  RefreshLists(Region);
  ChangeGeometry(False);
  Status('プレビューの対応点や領域メッシュの角をドラッグして中間形状を補正できます。');
end;

procedure TEditor.RemoveKeyClick(Sender: TObject);
var
  I: Integer;
begin
  if not Editable then Exit;
  I := FindKey(FModel, FSlider.Position);
  if I < 0 then Exit;
  Remember;
  Delete(FModel.Keys, I, 1);
  RefreshLists(Region);
  ChangeGeometry(False);
end;


function TEditor.HitVertex(View: TMorphViewport; X, Y: Integer): Integer;
var
  I, Radius, Distance, Nearest, Selected: Integer;
  Side: TImageSide;
  UV: TPointF;
  Positions: TPointPath;
  Layer: TMeshLayer;

  procedure Consider(Index: Integer; const Position: TPointF);
  var
    ScreenPos: TPoint;
  begin
    ScreenPos := View.ScreenPoint(Position);
    if (Abs(ScreenPos.X - X) > Radius) or (Abs(ScreenPos.Y - Y) > Radius) then Exit;
    Distance := Sqr(ScreenPos.X - X) + Sqr(ScreenPos.Y - Y);
    if Distance >= Nearest then Exit;
    Nearest := Distance;
    Result := Index;
  end;

begin
  Result := -1;
  Radius := Pixels(10);
  Nearest := Sqr(Radius);
  Side := isA;
  if View = FView[isB] then Side := isB;
  if View = FPreview then Prepare;
  Selected := Region;
  for I := 0 to High(FModel.Points) do
  begin
    if (Selected >= 0) and (FModel.Points[I].Region <> Selected) then Continue;
    if View = FPreview then
    begin
      if not FRenderer.PreviewVertex(I, FSlider.Position, UV) then Continue;
    end
    else
    begin
      if not FModel.Points[I].Has[Side] then Continue;
      UV := FModel.Points[I].UV[Side];
    end;
    Consider(I, UV);
  end;
  if (View = FPreview) and (Selected >= 0) then
  begin
    Layer := FRenderer.PreviewMesh(Selected, FSlider.Position, Positions);
    for I := 0 to High(Positions) do
      if Layer.Vertices[I].PointIndex < -1 then Consider(Layer.Vertices[I].PointIndex, Positions[I]);
  end;
end;

function TEditor.HitContour(View: TMorphViewport; X, Y: Integer): Integer;
var
  I, Radius, Distance, Nearest: Integer;
  Path: TPointPath;
  P: TPoint;
begin
  Result := -1;
  if Region < 0 then Exit;
  Path := FModel.Regions[Region].Contour[TImageSide(View.Tag)];
  Radius := Pixels(10);
  Nearest := Sqr(Radius);
  for I := 0 to High(Path) do
  begin
    P := View.ScreenPoint(Path[I]);
    if (Abs(P.X - X) > Radius) or (Abs(P.Y - Y) > Radius) then Continue;
    Distance := Sqr(P.X - X) + Sqr(P.Y - Y);
    if Distance >= Nearest then Continue;
    Nearest := Distance;
    Result := I;
  end;
end;

procedure TEditor.EditPoint(View: TMorphViewport; Hit: Integer; const UV: TPointF);
var
  P: TMorphPoint;
  Side, Other: TImageSide;
  Merge, Connect: Boolean;
begin
  Side := TImageSide(View.Tag);
  Other := TImageSide(1 - Ord(Side));
  Connect := (FVertex >= 0) and (Hit <> FVertex) and
    ((not FModel.Points[FVertex].Has[Side] and FModel.Points[FVertex].Has[Other] and
      ((Hit < 0) or not FModel.Points[Hit].Has[Other])) or (FRelink and FModel.Points[FVertex].Has[Other]));
  if Connect then
  begin
    Remember;
    FModel.Refinement := Default(TMeshRefinement);
    Merge := Hit >= 0;
    if Merge then
    begin
      FModel.Points[FVertex].UV[Side] := FModel.Points[Hit].UV[Side];
      if FModel.Points[Hit].Has[Other] then FModel.Points[Hit].Has[Side] := False
      else
      begin
        RemoveVertex(FModel, Hit);
        if Hit < FVertex then Dec(FVertex);
      end;
    end
    else
      FModel.Points[FVertex].UV[Side] := UV;
    FModel.Points[FVertex].Has[Side] := True;
    FRelink := False;
    Status('画像Aと画像Bの対応点を結びました。');
    ChangeGeometry(False);
  end
  else if Hit >= 0 then
  begin
    FVertex := Hit;
    FRelink := False;
  end
  else
  begin
    if Length(FModel.Points) >= MORPH_MAX_POINTS then
    begin
      Status('対応点は最大384個です。');
      Exit;
    end;
    Remember;
    P := Default(TMorphPoint);
    P.Region := Region;
    P.Has[Side] := True;
    P.UV[Side] := UV;
    FModel.Refinement := Default(TMeshRefinement);
    FModel.Points := FModel.Points + [P];
    FVertex := High(FModel.Points);
    FRelink := False;
    Status('反対側の画像をクリックすると対応点を結べます。');
    ChangeGeometry(False);
  end;
  FContour := -1;
  FView[isA].Invalidate;
  FView[isB].Invalidate;
end;

procedure TEditor.EditContour(View: TMorphViewport; const UV: TPointF);
var
  Side: TImageSide;
  Path: TPointPath;
  A, B, Delta, Step: TPointF;
  I, InsertAt: Integer;
  D, Nearest, T, LengthSquared: Double;
begin
  if Region < 0 then
  begin
    Status('輪郭を編集するパーツ・領域を選択してください。');
    Exit;
  end;
  Side := TImageSide(View.Tag);
  Path := Copy(FModel.Regions[Region].Contour[Side]);
  if Length(Path) >= MORPH_MAX_CONTOUR then
  begin
    Status('輪郭は片側につき最大128点です。');
    Exit;
  end;
  InsertAt := Length(Path);
  if Length(Path) >= 3 then
  begin
    Nearest := 10;
    A := Path[High(Path)];
    for I := 0 to High(Path) do
    begin
      B := Path[I];
      Step := B - A;
      Delta := UV - A;
      LengthSquared := Sqr(Step.X) + Sqr(Step.Y);
      if LengthSquared > 1E-10 then
      begin
        T := EnsureRange((Delta.X * Step.X + Delta.Y * Step.Y) / LengthSquared, 0, 1);
        Delta := Delta - PointF(T * Step.X, T * Step.Y);
      end;
      D := Sqr(Delta.X) + Sqr(Delta.Y);
      if D < Nearest then
      begin
        Nearest := D;
        InsertAt := I;
      end;
      A := B;
    end;
  end;
  Remember;
  Insert(UV, Path, InsertAt);
  FModel.Regions[Region].AutoGrid := False;
  FModel.Regions[Region].Contour[Side] := Path;
  FContour := InsertAt;
  FVertex := -1;
  ChangeGeometry(True);
end;


procedure TEditor.UpdateDeleteAction(Sender: TObject);
var
  Key: Integer;
  C: TCorrection;
begin
  FDeleteAction.Enabled := False;
  if (FActiveView = nil) or (FOriginalCandidate <> '') then Exit;
  if FActiveView = FPreview then
  begin
    if not FModel.ShowMesh or (FVertex = -1) then Exit;
    Key := FindKey(FModel, FSlider.Position);
    if Key >= 0 then
      for C in FModel.Keys[Key].Points do
        if C.Vertex = FVertex then
        begin
          FDeleteAction.Enabled := True;
          Exit;
        end;
  end
  else if FContourMode then
    FDeleteAction.Enabled := (Region >= 0) and (FContour >= 0)
  else
    FDeleteAction.Enabled := (FVertex >= 0) and (FVertex < Length(FModel.Points)) and
      FModel.Points[FVertex].Has[TImageSide(FActiveView.Tag)];
end;

procedure TEditor.DeleteSelection(Sender: TObject);
var
  K, P: Integer;
  Side: TImageSide;
begin
  UpdateDeleteAction(Sender);
  if not FDeleteAction.Enabled then Exit;
  if FActiveView = FPreview then
  begin
    K := FindKey(FModel, FSlider.Position);
    for P := 0 to High(FModel.Keys[K].Points) do
      if FModel.Keys[K].Points[P].Vertex = FVertex then
      begin
        Remember;
        Delete(FModel.Keys[K].Points, P, 1);
        ChangeGeometry(False);
        Break;
      end;
    Exit;
  end;
  Side := TImageSide(FActiveView.Tag);
  Remember;
  if FContourMode then
  begin
    FModel.Regions[Region].AutoGrid := False;
    Delete(FModel.Regions[Region].Contour[Side], FContour, 1);
    FContour := -1;
    ChangeGeometry(True);
  end
  else
  begin
    FModel.Refinement := Default(TMeshRefinement);
    if FModel.Points[FVertex].Has[TImageSide(1 - Ord(Side))] then
      FModel.Points[FVertex].Has[Side] := False
    else
      RemoveVertex(FModel, FVertex);
    FVertex := -1;
    FRelink := False;
    ChangeGeometry(False);
  end;
end;

procedure TEditor.ViewDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  View: TMorphViewport;
  UV: TPointF;
  Hit: Integer;
begin
  if not Editable then Exit;
  View := TMorphViewport(Sender);
  FActiveView := View;
  if Button = mbRight then
  begin
    FRelink := False;
    if (View = FPreview) or not FContourMode then
      FVertex := HitVertex(View, X, Y)
    else
      FContour := HitContour(View, X, Y);
    UpdateDeleteAction(Self);
    FView[isA].Invalidate;
    FView[isB].Invalidate;
    FPreview.Invalidate;
    Exit;
  end;
  if Button <> mbLeft then Exit;
  if not View.UVAt(X, Y, UV) then Exit;
  FDrag := -1;
  if View = FPreview then
  begin
    if not FModel.ShowMesh or (FSlider.Position = 0) or (FSlider.Position = 10000) then Exit;
    Hit := HitVertex(View, X, Y);
    if Hit = -1 then Exit;
    FVertex := Hit;
    FDrag := Hit;
  end
  else if FContourMode then
  begin
    Hit := HitContour(View, X, Y);
    if Hit < 0 then EditContour(View, UV)
    else
    begin
      FContour := Hit;
      FDrag := Hit;
    end;
  end
  else
  begin
    Hit := HitVertex(View, X, Y);
    EditPoint(View, Hit, UV);
    if (Hit >= 0) and (FVertex = Hit) then FDrag := Hit;
  end;
  FDragView := View;
  FDragStart := Point(X, Y);
  FDragging := False;
  View.Invalidate;
end;

procedure TEditor.ViewMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  View: TMorphViewport;
  Side: TImageSide;
  UV: TPointF;
  K: Integer;
begin
  if (FDrag = -1) or (Sender <> FDragView) or not (ssLeft in Shift) or not Editable then Exit;
  if not FDragging and (Abs(X - FDragStart.X) + Abs(Y - FDragStart.Y) < Pixels(4)) then Exit;
  View := TMorphViewport(Sender);
  if View.ImageRect.IsEmpty then Exit;
  View.UVAt(X, Y, UV);
  if (View = FPreview) and (FindKey(FModel, FSlider.Position) < 0) and
    (Length(FModel.Keys) >= MORPH_MAX_KEYS) then
  begin
    Status('補正キーは最大64個です。');
    Exit;
  end;
  if not FDragging then
  begin
    FDragging := True;
    Remember;
  end;
  if View = FPreview then
  begin
    K := AddKey(FModel, FSlider.Position);
    SetCorrection(FModel.Keys[K], FDrag, FRenderer.PreviewCorrection(UV, FSlider.Position));
    ChangeGeometry(False);
    Exit;
  end;
  Side := TImageSide(View.Tag);
  UV.X := EnsureRange(UV.X, 0, 1);
  UV.Y := EnsureRange(UV.Y, 0, 1);
  if FContourMode then
  begin
    FModel.Regions[Region].AutoGrid := False;
    FModel.Regions[Region].Contour[Side][FDrag] := UV;
    // プレビュー用マスクはマウスを離した時に再構築する。
    View.Invalidate;
  end
  else
  begin
    FModel.Points[FDrag].UV[Side] := UV;
    ChangeGeometry(False);
  end;
end;

procedure TEditor.ViewUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button <> mbLeft) or (Sender <> FDragView) then Exit;
  if FDragging then
  begin
    if Sender = FPreview then RefreshLists(Region)
    else if FContourMode then ChangeGeometry(True);
  end;
  FDrag := -1;
  FDragView := nil;
  FDragging := False;
end;

procedure TEditor.DrawOverlay(View: TMorphViewport; Target: TCanvas);
var
  I, J, Selected: Integer;
  Side: TImageSide;
  R: TMorphRegion;
  Path: TPointPath;
  P: TPoint;
  UV: TPointF;
  Layer: TMeshLayer;
  T: TTriangle;
  Positions: TArray<TPoint>;
  OutputUV: TPointPath;

  procedure Marker(const Position: TPoint; Color: TColor; Large: Boolean);
  var
    Radius: Integer;
  begin
    Radius := Pixels(3);
    if Large then Radius := Pixels(6);
    Target.Brush.Color := Color;
    Target.Pen.Color := $00212121;
    Target.Ellipse(Position.X - Radius, Position.Y - Radius,
      Position.X + Radius + 1, Position.Y + Radius + 1);
  end;

begin
  if View.ImageRect.IsEmpty then Exit;
  Selected := Region;
  Target.Pen.Width := 1;
  if View = FPreview then
  begin
    if not FModel.ShowMesh or FDirty or (FSlider.Position = 0) or (FSlider.Position = 10000) then Exit;
    Layer := FRenderer.PreviewMesh(Selected, FSlider.Position, OutputUV);
    SetLength(Positions, Length(OutputUV));
    for I := 0 to High(Positions) do Positions[I] := View.ScreenPoint(OutputUV[I]);
    Target.Pen.Color := $00967D5D;
    for T in Layer.Triangles do
      Target.Polyline([Positions[T.A], Positions[T.B], Positions[T.C], Positions[T.A]]);
    for I := 0 to High(Positions) do
      if Layer.Vertices[I].PointIndex < -1 then
        Marker(Positions[I], $005AD0FF, Layer.Vertices[I].PointIndex = FVertex);
    for I := 0 to High(FModel.Points) do
      if (FModel.Points[I].Region = Selected) and FRenderer.PreviewVertex(I, FSlider.Position, UV) then
        Marker(View.ScreenPoint(UV), $003FE8FF, I = FVertex);
    Exit;
  end;
  Side := TImageSide(View.Tag);
  if FModel.ShowMesh and not FDirty then
  begin
    Layer := FRenderer.Mesh(Selected);
    SetLength(Positions, Length(Layer.Vertices));
    for I := 0 to High(Positions) do Positions[I] := View.ScreenPoint(Layer.Vertices[I].UV[Side]);
    Target.Pen.Color := $00967D5D;
    for T in Layer.Triangles do
      Target.Polyline([Positions[T.A], Positions[T.B], Positions[T.C], Positions[T.A]]);
  end;
  for I := 0 to High(FModel.Regions) do
  begin
    if (Selected >= 0) and (I <> Selected) then Continue;
    R := FModel.Regions[I];
    Path := R.Contour[Side];
    if Length(Path) = 0 then Continue;
    if I = Selected then Target.Pen.Color := $005AD0FF else Target.Pen.Color := $009EB078;
    P := View.ScreenPoint(Path[0]);
    Target.MoveTo(P.X, P.Y);
    for J := 1 to High(Path) do
    begin
      P := View.ScreenPoint(Path[J]);
      Target.LineTo(P.X, P.Y);
    end;
    if Length(Path) >= 3 then
    begin
      P := View.ScreenPoint(Path[0]);
      Target.LineTo(P.X, P.Y);
    end;
    if (I = Selected) and (FContourMode) then
      for J := 0 to High(Path) do
        Marker(View.ScreenPoint(Path[J]), $005AD0FF, J = FContour);
  end;
  for I := 0 to High(FModel.Points) do
  begin
    if not FModel.Points[I].Has[Side] then Continue;
    if (Selected >= 0) and (FModel.Points[I].Region <> Selected) then Continue;
    if (FContourMode) and (FModel.Points[I].Region = Selected) then Continue;
    P := View.ScreenPoint(FModel.Points[I].UV[Side]);
    if FModel.Points[I].Has[TImageSide(1 - Ord(Side))] then
      Marker(P, $003FE8FF, I = FVertex)
    else
      Marker(P, $00F5BD9B, I = FVertex);
  end;
end;

function EditMorphing(const PathA, PathB: string; var JSON: string): Boolean;
var
  Form: TEditor;
  Before, PreviousStyle, PreviousDialogStyle: string;
  PreviousDefault: Boolean;
  Previous: DPI_AWARENESS_CONTEXT;
begin
  Previous := nil;
  PreviousStyle := TStyleManager.ActiveStyle.Name;
  PreviousDialogStyle := TStyleManager.DialogsStyleName;
  PreviousDefault := TStyleManager.UseSystemStyleAsDefault;
  if TOSVersion.Check(10) and (TOSVersion.Build >= 15063) then
    Previous := SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  try
    TStyleManager.UseSystemStyleAsDefault := True;
    Form := TEditor.Create(PathA, PathB, JSON);
    try
      Before := ModelJSON(Form.FModel);
      Result := Form.ShowModal = mrOK;
      if not Result then Exit;
      if not (Form.FRepairNeeded or Form.FInitialAuto) and (ModelJSON(Form.FModel) = Before) then Exit(False);
      JSON := Form.SaveJSON;
    finally
      Form.Free;
    end;
  finally
    try
      TStyleManager.DialogsStyleName := PreviousDialogStyle;
      TStyleManager.UseSystemStyleAsDefault := PreviousDefault;
      if TStyleManager.ActiveStyle.Name <> PreviousStyle then
        TStyleManager.TrySetStyle(PreviousStyle, False);
    finally
      if Previous <> nil then SetThreadDpiAwarenessContext(Previous);
    end;
  end;
end;

end.
