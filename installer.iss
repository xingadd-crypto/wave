[Setup]
AppId={{B1E2F3A4-5C6D-7E8F-9A0B-1C2D3E4F5A6B}
AppName=Wave Messenger
AppVersion=1.0.0
AppPublisher=Wave
DefaultDirName={autopf}\Wave
DefaultGroupName=Wave
OutputDir=G:\wave\flutter_wave\installer
OutputBaseFilename=wave_installer
Compression=lzma2/ultra64
LZMANumBlockThreads=4
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "G:\wave\flutter_wave\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Wave Messenger"; Filename: "{app}\flutter_wave.exe"
Name: "{group}\{cm:UninstallProgram,Wave Messenger}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Wave Messenger"; Filename: "{app}\flutter_wave.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\flutter_wave.exe"; Description: "{cm:LaunchProgram,Wave Messenger}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    // Set working directory
  end;
end;
