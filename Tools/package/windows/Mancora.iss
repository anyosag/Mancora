; Inno Setup script for the Mancora installer.
;
; package.ps1 stages the files and calls:
;   ISCC.exe /DVersion=<x.y.z> /DStage=<staged files> /DRepo=<repo root> /DOutput=<dir> Mancora.iss
;
; The installer is per-user (no administrator rights needed): it installs to
; %LOCALAPPDATA%\Programs\Mancora, adds Start menu and optional desktop
; shortcuts, registers Mancora under "Open with" for TIFF files, and can add
; the mancora command-line tool to the user's PATH.

#ifndef Version
  #error Pass /DVersion=x.y.z
#endif

[Setup]
AppId={{6E7C2B54-1F1A-4C5E-9F0B-6A3D2E8C9B71}
AppName=Mancora
AppVersion={#Version}
AppVerName=Mancora {#Version}
AppPublisher=Mancora contributors
AppPublisherURL=https://github.com/anyosag/Mancora
AppSupportURL=https://github.com/anyosag/Mancora/issues
VersionInfoVersion={#Version}
DefaultDirName={autopf}\Mancora
DefaultGroupName=Mancora
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
LicenseFile={#Repo}\LICENSE.txt
SetupIconFile={#Repo}\Resources\Branding\Windows\mancora.ico
UninstallDisplayIcon={app}\MancoraViewer.exe
UninstallDisplayName=Mancora {#Version}
OutputDir={#Output}
OutputBaseFilename=Mancora-{#Version}-Windows-x64-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
ChangesAssociations=yes
; An update closes the running viewer instead of asking for a reboot.
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked
Name: "addtopath"; Description: "Add the &mancora command-line tool to PATH"

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Mancora"; Filename: "{app}\MancoraViewer.exe"
Name: "{autodesktop}\Mancora"; Filename: "{app}\MancoraViewer.exe"; Tasks: desktopicon

[Registry]
; "Open with > Mancora" for .tif and .tiff, without taking over the default app.
Root: HKCU; Subkey: "Software\Classes\Mancora.TIFF"; ValueType: string; ValueData: "TIFF image"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Mancora.TIFF\DefaultIcon"; ValueType: string; ValueData: "{app}\MancoraViewer.exe,0"
Root: HKCU; Subkey: "Software\Classes\Mancora.TIFF\shell\open\command"; ValueType: string; ValueData: """{app}\MancoraViewer.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\.tif\OpenWithProgids"; ValueType: string; ValueName: "Mancora.TIFF"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\.tiff\OpenWithProgids"; ValueType: string; ValueName: "Mancora.TIFF"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\MancoraViewer.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Mancora"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\MancoraViewer.exe\shell\open\command"; ValueType: string; ValueData: """{app}\MancoraViewer.exe"" ""%1"""
; PATH entry for the command-line tool (removed again on uninstall, below).
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Tasks: addtopath; Check: NeedsAddPath(ExpandConstant('{app}'))

[Run]
Filename: "{app}\MancoraViewer.exe"; Description: "Launch Mancora"; Flags: nowait postinstall skipifsilent
; Updates started from the viewer run silently with /relaunch=1 and reopen it.
Filename: "{app}\MancoraViewer.exe"; Flags: nowait; Check: ShouldRelaunch

[Code]
function ShouldRelaunch: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:relaunch|0}') = '1');
end;

function PathContains(Paths, Dir: string): Integer;
begin
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Paths) + ';');
end;

function NeedsAddPath(Dir: string): Boolean;
var
  Paths: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Paths) then
    Result := True
  else
    Result := PathContains(Paths, Dir) = 0;
end;

procedure RemoveFromPath(Dir: string);
var
  Paths: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Paths) then
    exit;
  P := PathContains(Paths, Dir);
  if P = 0 then
    exit;
  { P indexes the padded string. If Dir is the first entry, remove "Dir;",
    otherwise remove ";Dir". }
  if P = 1 then
    Delete(Paths, 1, Length(Dir) + 1)
  else
    Delete(Paths, P - 1, Length(Dir) + 1);
  RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Paths);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveFromPath(ExpandConstant('{app}'));
end;
