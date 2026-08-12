; oc-usage Flutter 版安装脚本（Inno Setup 7）
#define MyAppName "oc-usage"
#define MyAppVersion "1.0.1"
#define MyAppExeName "oc_usage.exe"
#define MyAppPublisher "GrounzerLiu"
#define MyAppURL "https://github.com/GrounzerLiu/oc-usage"

[Setup]
AppId={{8F2B6C3A-5D4E-4A9B-9C1D-2E3F4A5B6C7E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\oc-usage
DefaultGroupName=oc-usage
DisableProgramGroupPage=yes
OutputDir=installer
OutputBaseFilename=oc-usage-flutter-setup-{#MyAppVersion}
SetupIconFile=assets_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\oc-usage"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\oc-usage"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,oc-usage}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\oc-usage"
