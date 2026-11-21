
unit SYNC_Morphing_FilterPlugin;

// SPDX-License-Identifier: GPL-3.0-only
interface

uses AviUtl2FilterTypes;

const
  MORPH_REQUIRED_VERSION = 2010200; // 2026/7/25 SDK: FLAG_USERDATA

function GetMorphFilterTable(Version: Cardinal): PFILTER_PLUGIN_TABLE;

implementation

uses System.SysUtils, System.SyncObjs, Winapi.Windows, PluginFilterTable,
  Morphing_Model, Morphing_Images, Morphing_Renderer, Morphing_Parameters, Morphing_AutoDetect,
  Morphing_HostRender;

type
  TImageKey = record
    Path: string;
    LastCheck, RetryAfter: UInt64;
    Modified: FILETIME;
    FileSize: UInt64;
    Exists: Boolean;
  end;
  TMorphSession = class
  private
    FRenderer: TMorphRenderer;
    FHostRender: TMorphHostRender;
    FImages: TSourceImages;
    FImageKeys: array[TImageSide] of TImageKey;
    FLastJSON: string;
    FModel: TMorphModel;
    FFrame: TMorphImage;
    FLastProgress: Integer;
    FLock: TCriticalSection;
    FReady: Boolean;
    function UpdateImage(Side: TImageSide; Path: PWideChar): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Video(V: PFILTER_PROC_VIDEO): Byte;
  end;

var
  RegisteredVersion: Cardinal;

function SameTextPointer(const Text: string; Value: PWideChar): Boolean;
begin
  if Value = nil then Exit(Text = '');
  Result := StrComp(PChar(Text), Value) = 0;
end;

constructor TMorphSession.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FRenderer := TMorphRenderer.Create;
  FHostRender := TMorphHostRender.Create;
  FModel := DefaultModel;
  FLastProgress := -1;
end;

destructor TMorphSession.Destroy;
begin
  FHostRender.Free;
  FRenderer.Free;
  FLock.Free;
  inherited;
end;

function TMorphSession.UpdateImage(Side: TImageSide; Path: PWideChar): Boolean;
var
  Key: TImageKey;
  Data: TWin32FileAttributeData;
  Current: UInt64;
  Changed: Boolean;
begin
  Key := FImageKeys[Side];
  Current := GetTickCount64;
  Changed := not SameTextPointer(Key.Path, Path);
  if not Changed and (Current - Key.LastCheck < 1000) then Exit(False);
  if Changed then
  begin
    Key.Path := string(Path);
    Key.RetryAfter := 0;
  end;
  Key.LastCheck := Current;
  FImageKeys[Side] := Key;
  if Key.Path = '' then
  begin
    if Changed then FImages[Side] := Default(TMorphImage);
    FImageKeys[Side].Exists := False;
    Exit(Changed);
  end;
  FImageKeys[Side].Exists := GetFileAttributesEx(PChar(Key.Path), GetFileExInfoStandard, @Data)
    and ((Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0);
  if not FImageKeys[Side].Exists then
  begin
    if Changed or Key.Exists then FImages[Side] := Default(TMorphImage);
    Exit(Changed or Key.Exists);
  end;
  FImageKeys[Side].Modified := Data.ftLastWriteTime;
  FImageKeys[Side].FileSize := (UInt64(Data.nFileSizeHigh) shl 32) or UInt64(Data.nFileSizeLow);
  Result := Changed or not Key.Exists or (CompareFileTime(Key.Modified, Data.ftLastWriteTime) <> 0)
    or (Key.FileSize <> FImageKeys[Side].FileSize) or ((Key.RetryAfter <> 0) and (Current >= Key.RetryAfter));
  if not Result then Exit;
  try
    FImages[Side] := LoadImage(Key.Path);
    FImageKeys[Side].RetryAfter := 0;
  except
    on E: Exception do
    begin
      FImages[Side] := Default(TMorphImage);
      FImageKeys[Side].RetryAfter := Current + 5000;
      OutputDebugString(PChar('SYNC_Morphing image: ' + E.Message));
    end;
  end;
end;

function TMorphSession.Video(V: PFILTER_PROC_VIDEO): Byte;
var
  Params: TMorphParameters;
  Changed, NeedsPrepare: Boolean;
  Side: TImageSide;
  Paths: THostImagePaths;
  Blank: TPIXEL_RGBA;
begin
  Result := 0;
  if not Assigned(V^.SetImageData) then Exit;
  FLock.Acquire;
  try
    Params := ReadMorphParameters;
    NeedsPrepare := not FReady;
    for Side := Low(Side) to High(Side) do
    begin
      Changed := UpdateImage(Side, Params.Path[Side]);
      NeedsPrepare := NeedsPrepare or Changed;
    end;
    if not SameTextPointer(FLastJSON, Params.JSON) then
    begin
      FLastJSON := string(Params.JSON);
      try
        FModel := ReadModel(FLastJSON);
      except
        on E: EConvertError do
        begin
          FModel := DefaultModel;
          OutputDebugString(PChar('SYNC_Morphing project: ' + E.Message));
        end;
      end;
      NeedsPrepare := True;
    end;
    if NeedsPrepare then
    begin
      FReady := False;
      FLastProgress := -1;
      if FLastJSON = '' then FModel := DetectMorphing(FImages);
      FRenderer.Prepare(FImages, FModel);
      FReady := True;
    end;
    for Side := Low(Side) to High(Side) do Paths[Side] := FImageKeys[Side].Path;
    if not FHostRender.Draw(V, FRenderer, FImages, Paths, Params.Progress) then
    begin
      if FLastProgress <> Params.Progress then
      begin
        FLastProgress := -1;
        FFrame := Default(TMorphImage);
        FFrame := FRenderer.Render(Params.Progress);
        FLastProgress := Params.Progress;
      end;
      if Length(FFrame.Pixels) <> 0 then
        V^.SetImageData(@FFrame.Pixels[0], FFrame.Width, FFrame.Height)
      else
      begin
        Blank := Default(TPIXEL_RGBA);
        V^.SetImageData(@Blank, 1, 1);
      end;
    end;
    if V^.Param <> nil then
    begin
      V^.Param^.X := V^.Param^.X + Params.X;
      V^.Param^.Y := V^.Param^.Y + Params.Y;
      V^.Param^.SX := V^.Param^.SX * Params.Scale;
      V^.Param^.SY := V^.Param^.SY * Params.Scale;
      V^.Param^.SZ := V^.Param^.SZ * Params.Scale;
      V^.Param^.RZ := V^.Param^.RZ + Params.Angle;
      V^.Param^.Alpha := V^.Param^.Alpha * (1 - Params.Transparency);
    end;
    Result := 1;
  finally
    FLock.Release;
  end;
end;

function ProcVideo(V: PFILTER_PROC_VIDEO): Byte; cdecl;
begin
  Result := 0;
  if (V = nil) or (V^.UserData = nil) then Exit;
  try
    Result := TMorphSession(V^.UserData).Video(V);
  except
    on E: Exception do OutputDebugString(PChar('SYNC_Morphing video: ' + E.Message));
  end;
end;

function CreateSession(EffectID: Int64): Pointer; cdecl;
begin
  Result := nil;
  try
    Result := TMorphSession.Create;
  except
  end;
end;

procedure DestroySession(EffectID: Int64; UserData: Pointer); cdecl;
begin
  try
    TMorphSession(UserData).Free;
  except
  end;
end;

function GetMorphFilterTable(Version: Cardinal): PFILTER_PLUGIN_TABLE;
begin
  if RegisteredVersion <> Version then
  begin
    SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_INPUT or FILTER_FLAG_USERDATA,
      MorphEffectName, 'SYNC', 'モーフィング / SYNC_Morphing v1.0.0', ProcVideo, nil);
    RegisterMorphParameters(Version);
    GetPluginTable^.Func_Create := CreateSession;
    GetPluginTable^.Func_Destroy := DestroySession;
    RegisteredVersion := Version;
  end;
  Result := GetPluginTable;
end;

end.
