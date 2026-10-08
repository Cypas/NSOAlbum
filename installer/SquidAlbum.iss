#define AppPublisher "Cypas"
#define AppExeName "NSOAlbum.exe"

#ifndef AppVersion
  #define AppVersion "0.1.17"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\NSOAlbum-Windows-x64-" + AppVersion
#endif
#ifndef OutputDir
  #define OutputDir "..\dist\installers"
#endif
#ifndef IconFile
  #define IconFile "..\flutter_app\windows\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{E9E4A9A1-7D1F-4F4D-9E8A-5F8F6A6A1F10}
AppName={cm:AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\NSOAlbum
UsePreviousAppDir=yes
DefaultGroupName={cm:AppName}
OutputDir={#OutputDir}
OutputBaseFilename=NSOAlbum-{#AppVersion}-Setup
SetupIconFile={#IconFile}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#AppExeName}
ChangesAssociations=no
LanguageDetectionMethod=uilanguage
ShowLanguageDialog=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{app}\FreshAlbum.exe"

[Icons]
Name: "{autoprograms}\{cm:AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{cm:AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{cm:AppName}}"; Flags: nowait postinstall skipifsilent

[CustomMessages]
chinesesimplified.AppName=鱿型相册
english.AppName=NSOAlbum
