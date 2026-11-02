#define AppName "ANVUREL Annotation Assistant"
#define AppVersion "2.4.0"
#define AppExe "ANVUREL.exe"

[Setup]
AppId={{B742D66A-621A-48DC-BE6A-5AD70DCE44DA}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\ANVUREL
DefaultGroupName=ANVUREL
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
OutputDir=output
OutputBaseFilename=ANVUREL-Setup-{#AppVersion}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "..\dist\ANVUREL\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "QUICK_START.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "..\docs\images\*"; DestDir: "{app}\docs\images"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ANVUREL"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\ANVUREL"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Start ANVUREL"; Flags: postinstall nowait skipifsilent
