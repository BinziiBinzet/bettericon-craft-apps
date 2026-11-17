; Compile locally with Build-AppInstaller.ps1. No hosted build is needed.
#ifndef PayloadRoot
  #error PayloadRoot must name an extracted Windows package.
#endif
#ifndef AppVersion
  #error AppVersion is required.
#endif
#ifndef OutputDir
  #error OutputDir is required.
#endif
#if Defined(TestAppId) || Defined(TestInstallDir) || Defined(TestShortcutName) || Defined(TestFixturePath)
  #if !Defined(TestAppId) || !Defined(TestInstallDir) || !Defined(TestShortcutName) || !Defined(TestFixturePath)
    #error All four test isolation defines are required together.
  #endif
  #define InstallerId TestAppId
  #define InstallDir TestInstallDir
  #define ShortcutName TestShortcutName
  #define DesktopShortcutName TestShortcutName
  #define ProductName "BetterIcon TEST"
  #define OutputName "BetterIcon-TEST-Setup-" + AppVersion
  #define FixtureArgs ' --config "' + TestFixturePath + '"'
#else
  #define InstallerId "BetterIcon.ArtCraft.Windows"
  #define InstallDir "{localappdata}\Programs\BetterIcon"
  #define ShortcutName "BetterIcon"
  #define DesktopShortcutName "BetterIcon"
  #define ProductName "BetterIcon for ArtCraft"
  #define OutputName "BetterIcon-Setup-" + AppVersion
  #define FixtureArgs ""
#endif
; Section parameters and Pascal literals have different quote escaping rules.
#define FixtureSectionArgs StringChange(FixtureArgs, '"', '""')
#define FixtureCodeArgs StringChange(FixtureArgs, "'", "''")
#define PayloadDir "{app}\versions\" + AppVersion
#define AppExe PayloadDir + "\Windows\BetterIcon-Tray.exe"

[Setup]
AppId={#InstallerId}
AppName={#ProductName}
AppVersion={#AppVersion}
AppPublisher=BetterIcon contributors
AppPublisherURL=https://github.com/BinziiBinzet/bettericon-craft-apps
AppSupportURL=https://github.com/BinziiBinzet/bettericon-craft-apps/issues
DefaultDirName={#InstallDir}
DefaultGroupName=BetterIcon
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
#ifdef SetupIcon
SetupIconFile={#SetupIcon}
#endif
UninstallDisplayIcon={#AppExe}
UninstallDisplayName={#ProductName}
LicenseFile={#PayloadRoot}\LICENSE
WizardStyle=modern
Compression=lzma2/normal
SolidCompression=yes
CloseApplications=no
RestartApplications=no
SetupMutex=BetterIcon.Setup.{#InstallerId}
UsePreviousAppDir=yes
UsePreviousTasks=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; Each version has its own catalog root, so retired bundled packs cannot reappear.
; Inno's uninstall log removes only files installed by Setup, across upgrades.
Source: "{#PayloadRoot}\*"; DestDir: "{#PayloadDir}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\Windows\BetterIcon-Tray.exe"; DestName: "BetterIcon-InstallerHelper.exe"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{#ShortcutName}"; Filename: "{#AppExe}"; Parameters: "--source-folder ""{#PayloadDir}\Windows""{#FixtureSectionArgs}"; WorkingDir: "{#PayloadDir}\Windows"; IconFilename: "{#AppExe}"; Comment: "Launch BetterIcon for ArtCraft"
Name: "{autodesktop}\{#DesktopShortcutName}"; Filename: "{#AppExe}"; Parameters: "--source-folder ""{#PayloadDir}\Windows""{#FixtureSectionArgs}"; WorkingDir: "{#PayloadDir}\Windows"; IconFilename: "{#AppExe}"; Comment: "Launch BetterIcon for ArtCraft"; Tasks: desktopicon

[Run]
Filename: "{#AppExe}"; Parameters: "--source-folder ""{#PayloadDir}\Windows""{#FixtureSectionArgs}"; Description: "Open BetterIcon"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup(): Boolean;
begin
  Result := IsDotNetInstalled(net48, 0);
  if not Result then
    SuppressibleMsgBox('BetterIcon needs Microsoft .NET Framework 4.8 or later.' + #13#10 +
      'Install it from https://dotnet.microsoft.com/download/dotnet-framework/net48 and run Setup again.',
      mbError, MB_OK, IDOK);
end;

function StopBetterIcon(const Helper: String): Boolean;
var
  ExitCode: Integer;
begin
  Result := Exec(Helper, '--stop-and-wait{#FixtureCodeArgs}', '', SW_HIDE,
    ewWaitUntilTerminated, ExitCode);
  if Result then Result := ExitCode = 0;
end;

function CanReplaceShortcut(const Path: String): Boolean;
var
  Shell, Link: Variant;
  Description, Target, Arguments, SourceArgument: String;
begin
  Result := False;
  if DirExists(Path) then Exit;
  if not FileExists(Path) then begin
    Result := True;
    Exit;
  end;
  try
    // Loading an existing link does not modify it. Never call Save here.
    Shell := CreateOleObject('WScript.Shell');
    Link := Shell.CreateShortcut(Path);
    Description := Link.Description;
    Target := Link.TargetPath;
    Arguments := Link.Arguments;
    SourceArgument := '--source-folder "';
    Result := (Description = 'Launch BetterIcon for ArtCraft') and
      (CompareText(ExtractFileName(Target), 'BetterIcon-Tray.exe') = 0) and
      (Pos(SourceArgument, Arguments) = 1) and
      (Pos('"', Copy(Arguments, Length(SourceArgument) + 1, Length(Arguments))) > 1);
  except
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Shortcut: String;
begin
  Result := '';
  Shortcut := ExpandConstant('{autoprograms}\{#ShortcutName}.lnk');
  if not CanReplaceShortcut(Shortcut) then begin
    Result := 'An unrelated shortcut already exists at ' + Shortcut + '. ' +
      'Rename or move it before installing BetterIcon.';
    Exit;
  end;
  if WizardIsTaskSelected('desktopicon') then begin
    Shortcut := ExpandConstant('{autodesktop}\{#DesktopShortcutName}.lnk');
    if not CanReplaceShortcut(Shortcut) then begin
      Result := 'An unrelated shortcut already exists at ' + Shortcut + '. ' +
        'Rename or move it, or turn off the desktop shortcut option.';
      Exit;
    end;
  end;
  ExtractTemporaryFile('BetterIcon-InstallerHelper.exe');
  if not StopBetterIcon(ExpandConstant('{tmp}\BetterIcon-InstallerHelper.exe')) then
    Result := 'BetterIcon is still running. Finish any icon operation, close its dialogs, ' +
      'and choose Exit BetterIcon from its tray menu. Then try Setup again.';
end;

function InitializeUninstall(): Boolean;
var
  Helper: String;
begin
  Helper := ExpandConstant('{#AppExe}');
  Result := True;
  if FileExists(Helper) then Result := StopBetterIcon(Helper);
  if not Result then
    SuppressibleMsgBox('BetterIcon is still running. Finish any icon operation, close its dialogs, ' +
      'and choose Exit BetterIcon from its tray menu. Then try uninstalling again.', mbError, MB_OK, IDOK);
end;

// No UninstallDelete wildcard: preferences, personal packs, cached shortcut icons,
// and backups in LocalAppData/ProgramData are deliberately preserved.
