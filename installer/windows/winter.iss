; Inno Setup script for the Winter Windows installer.
; Build after `flutter build windows --release`:
;   iscc /DAppVersion=1.0.0 installer\windows\winter.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{6F1C2C53-6B8E-4E39-9B7E-3C1A9D3F2B11}
AppName=Winter
AppVersion={#AppVersion}
AppPublisher=uz.wick
DefaultDirName={autopf}\Winter
DefaultGroupName=Winter
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=Winter-{#AppVersion}-Windows-Setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Winter.exe
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
CloseApplications=force

[Tasks]
Name: "startup"; Description: "Start Winter when I sign in"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Winter"; Filename: "{app}\Winter.exe"
Name: "{group}\Uninstall Winter"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Winter"; Filename: "{app}\Winter.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Winter"; ValueData: """{app}\Winter.exe"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Winter.exe"; Description: "Launch Winter"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM Winter.exe /F"; Flags: runhidden; RunOnceId: "KillWinter"
