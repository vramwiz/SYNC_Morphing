
library SYNC_Morphing;

// SPDX-License-Identifier: GPL-3.0-only
{$ALIGN 8}

uses
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  PluginFilterTable in 'Source\Lib\FilterTable\PluginFilterTable.pas',
  Morphing_Model in 'Source\Common\Morphing_Model.pas',
  Morphing_Images in 'Source\Common\Morphing_Images.pas',
  Morphing_Mesh in 'Source\Common\Morphing_Mesh.pas',
  Morphing_Renderer in 'Source\Common\Morphing_Renderer.pas',
  Morphing_Registration in 'Source\Common\Morphing_Registration.pas',
  Morphing_AutoDetect in 'Source\Common\Morphing_AutoDetect.pas',
  Morphing_HostRender in 'Source\Plugin\Filter\Morphing_HostRender.pas',
  Morphing_Analysis in 'Source\Common\Morphing_Analysis.pas',
  Morphing_Window in 'Source\UI\Morphing_Window.pas',
  Morphing_Dialogs in 'Source\UI\Morphing_Dialogs.pas',
  Morphing_Viewport in 'Source\UI\Morphing_Viewport.pas',
  Morphing_Editor in 'Source\UI\Morphing_Editor.pas',
  Morphing_Parameters in 'Source\Plugin\Filter\Morphing_Parameters.pas',
  SYNC_Morphing_FilterPlugin in 'Source\Plugin\Filter\SYNC_Morphing_FilterPlugin.pas';

{$R *.res}

var
  HostVersion: Cardinal = MORPH_REQUIRED_VERSION;

function RequiredVersion: Cardinal; cdecl;
begin
  Result := MORPH_REQUIRED_VERSION;
end;

function InitializePlugin(Version: Cardinal): Byte; cdecl;
begin
  Result := 0;
  try
    if Version < MORPH_REQUIRED_VERSION then Exit;
    GetMorphFilterTable(Version);
    HostVersion := Version;
    Result := 1;
  except
  end;
end;

procedure UninitializePlugin; cdecl;
begin
end;

function GetFilterPluginTable: PFILTER_PLUGIN_TABLE; cdecl;
begin
  Result := nil;
  try
    Result := GetMorphFilterTable(HostVersion);
  except
  end;
end;

exports
  RequiredVersion name 'RequiredVersion',
  InitializePlugin name 'InitializePlugin',
  UninitializePlugin name 'UninitializePlugin',
  GetFilterPluginTable name 'GetFilterPluginTable';

begin
  System.IsMultiThread := True;
end.
