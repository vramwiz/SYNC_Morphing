
unit Morphing_Parameters;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses AviUtl2FilterTypes, Morphing_Model;

type
  TMorphParameters = record
    Path: array[TImageSide] of PWideChar;
    JSON: PWideChar;
    Progress: Integer;
    X, Y, Scale, Transparency, Angle: Single;
  end;

const
  MorphEffectName = 'モーフィング';

procedure RegisterMorphParameters(HostVersion: Cardinal);
function ReadMorphParameters: TMorphParameters;

implementation

uses System.SysUtils, System.Classes, System.Math, System.UITypes, Vcl.Dialogs, Winapi.Windows,
  PluginFilterTable, Morphing_Editor;

const
  HideRulesVersion = 2010700; // 2026/8/29 SDK
  TargetedButtonVersion = 2011000; // 2026/9/19 SDK
  SettingsName = 'モーフィング設定データ';
  FilePattern = '画像 (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp)'#0 +
    '*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp'#0 +
    'すべてのファイル (*.*)'#0'*.*'#0#0;

var
  FileA, FileB: TFILTER_ITEM_FILE;
  SettingsButton: TFILTER_ITEM_BUTTON;
  SettingsItem: TFILTER_ITEM_STRING;
  SettingsGroup: TFILTER_ITEM_GROUP;
  HideSettings: TFILTER_ITEM_HIDE_RULE;
  Progress: TFILTER_ITEM_TRACK2;
  X, Y, Scale, Transparency, Angle: TFILTER_ITEM_TRACK;

function SafeValue(Value, DefaultValue, MinValue, MaxValue: Double): Double;
begin
  if IsNan(Value) or IsInfinite(Value) then Exit(DefaultValue);
  Result := EnsureRange(Value, MinValue, MaxValue);
end;

function ReadMorphParameters: TMorphParameters;
begin
  Result.Path[isA] := FileA.Value;
  Result.Path[isB] := FileB.Value;
  Result.JSON := SettingsItem.Value;
  Result.Progress := Round(SafeValue(Progress.Value, 0, 0, 100) * 100);
  Result.X := SafeValue(X.Value, 0, -16384, 16384);
  Result.Y := SafeValue(Y.Value, 0, -16384, 16384);
  Result.Scale := SafeValue(Scale.Value, 100, 0, 2000) / 100;
  Result.Transparency := SafeValue(Transparency.Value, 0, 0, 100) / 100;
  Result.Angle := SafeValue(Angle.Value, 0, -3600, 3600);
end;

procedure OpenSettings(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect, Item: PWideChar); cdecl;
var
  Target, PathA, PathB, JSON: string;
  Value: PAnsiChar;
  Saved: UTF8String;
begin
  if (Edit = nil) or (Obj = nil) or (Effect = nil) or not Assigned(Edit^.SetObjectItemValue) then Exit;
  try
    Target := string(Effect);
    PathA := string(FileA.Value);
    PathB := string(FileB.Value);
    JSON := string(SettingsItem.Value);
    if Assigned(Edit^.GetObjectItemValue) then
    begin
      Value := Edit^.GetObjectItemValue(Obj, PChar(Target), SettingsName);
      if Value <> nil then JSON := string(UTF8String(Value));
    end;
    if not EditMorphing(PathA, PathB, JSON) then Exit;
    Saved := UTF8String(JSON);
    if not Edit^.SetObjectItemValue(Obj, PChar(Target), SettingsName, PAnsiChar(Saved)) then
      raise EWriteError.Create('AviUtl2へモーフィング設定を保存できません。');
  except
    on E: Exception do
    begin
      OutputDebugString(PChar('SYNC_Morphing editor: ' + E.Message));
      try
        MessageDlg(E.Message, mtError, [mbOK], 0);
      except
      end;
    end;
  end;
end;

procedure OpenLegacySettings(Edit: PEDIT_SECTION); cdecl;
var
  Obj: OBJECT_HANDLE;
begin
  if (Edit = nil) or not Assigned(Edit^.GetFocusObject) or not Assigned(Edit^.CountObjectEffect) then Exit;
  Obj := Edit^.GetFocusObject();
  // The older callback supplies no effect index. Only write to an unambiguous object.
  if (Obj = nil) or (Edit^.CountObjectEffect(Obj, MorphEffectName) <> 1) then Exit;
  OpenSettings(Edit, Obj, MorphEffectName, '設定');
end;

procedure RegisterMorphParameters(HostVersion: Cardinal);
begin
  AddFile(FileA, '画像A', '', FilePattern);
  AddFile(FileB, '画像B', '', FilePattern);
  if HostVersion >= TargetedButtonVersion then AddButton(SettingsButton, '設定', OpenSettings)
  else AddButton(SettingsButton, '設定', OpenLegacySettings);
  AddTrack2(Progress, MorphEffectName, 0, 0, 100, 0.01, 1);
  AddTrack(X, 'X', 0, -16384, 16384, 0.1);
  AddTrack(Y, 'Y', 0, -16384, 16384, 0.1);
  AddTrack(Scale, '拡大率', 100, 0, 2000, 0.1);
  AddTrack(Transparency, '透明度', 0, 0, 100, 0.01);
  AddTrack(Angle, '回転', 0, -3600, 3600, 0.1);
  if HostVersion < HideRulesVersion then AddGroup(SettingsGroup, '詳細データ', 0);
  AddString(SettingsItem, SettingsName, '');
  if HostVersion >= HideRulesVersion then AddAlwaysHideRule(HideSettings, SettingsName);
end;

end.
