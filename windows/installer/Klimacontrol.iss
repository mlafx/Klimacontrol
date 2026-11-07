; Setup fuer Klimacontrol (Inno Setup 6). Aufruf ueber tools\build_windows.ps1 -Setup:
;   ISCC.exe /DAppVersion=<tools\VERSION> /DSourceDir=<dist\windows\Klimacontrol> /DOutputDir=<dist\windows> Klimacontrol.iss
; Ohne Administratorrechte nach %LOCALAPPDATA%\Programs\Klimacontrol. Updates kommen ueber WinSparkle, das dieses
; Setup mit /SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS startet (tools/make_release.py).
; Nur ASCII: die deutschen Texte kommen aus German.isl.

#ifndef AppVersion
  #error AppVersion fehlt (/DAppVersion=...)
#endif
#ifndef SourceDir
  #error SourceDir fehlt (/DSourceDir=...)
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Feste AppId: dieselbe in Updates.cs (SetupAppId). Nie aendern, sonst erkennt das Setup die alte Installation nicht.
AppId={{1EAA2BD1-F86E-420F-A62C-4057C87B34F8}
AppName=Klimacontrol
AppVersion={#AppVersion}
AppVerName=Klimacontrol {#AppVersion}
AppPublisher=Klimacontrol
AppPublisherURL=https://github.com/mlafx/Klimacontrol
AppSupportURL=https://github.com/mlafx/Klimacontrol/issues
AppUpdatesURL=https://github.com/mlafx/Klimacontrol/releases
VersionInfoVersion={#AppVersion}
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Klimacontrol
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
UninstallDisplayName=Klimacontrol
UninstallDisplayIcon={app}\Klimacontrol.exe
SetupIconFile=..\KlimacontrolTray\Klimacontrol.ico
OutputDir={#OutputDir}
OutputBaseFilename=Klimacontrol-Windows-{#AppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"

[InstallDelete]
; Alte Laufzeitdateien einer frueheren Version nicht liegen lassen.
Type: filesandordirs; Name: "{app}\res"

[Files]
Source: "{#SourceDir}\Klimacontrol.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\res\*"; DestDir: "{app}\res"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
; Standard an. Bei Updates (still) behaelt Inno Setup die fruehere Wahl bei.
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autostart"; Description: "Mit Windows starten"; GroupDescription: "Weitere Optionen:"

[Icons]
Name: "{autoprograms}\Klimacontrol"; Filename: "{app}\Klimacontrol.exe"
Name: "{autodesktop}\Klimacontrol"; Filename: "{app}\Klimacontrol.exe"; Tasks: desktopicon

[Registry]
; Gleicher Wert und gleiches Format wie die App (SettingsWindow.General.cs). Nur bei Handinstallation: ein stilles
; Update darf einen in der App ausgeschalteten Autostart nicht wieder einschalten. Ist der Haken aus, bleibt ein
; vorhandener Eintrag unveraendert.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Klimacontrol"; ValueType: string; ValueData: """{app}\Klimacontrol.exe"" --tray"; Tasks: autostart; Flags: uninsdeletevalue; Check: not WizardSilent
; Beim Entfernen soll der Eintrag (auch wenn die App ihn angelegt hat) nicht ins Leere zeigen.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Klimacontrol"; ValueType: none; Flags: uninsdeletevalue dontcreatekey

[Run]
; Von Hand installiert: Haken "Klimacontrol starten" am Ende. Als Update (still): danach wieder starten.
Filename: "{app}\Klimacontrol.exe"; Description: "{cm:LaunchProgram,Klimacontrol}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\Klimacontrol.exe"; Flags: nowait; Check: WizardSilent

; Daten (%LOCALAPPDATA%\Klimacontrol), Einstellungen (HKCU\Software\Klimacontrol) und die Anmeldeinformationen
; bleiben beim Entfernen bewusst stehen.
