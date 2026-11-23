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
#if Defined(TestAppId) || Defined(TestInstallDir) || Defined(TestShortcutName) || Defined(TestFixturePath) || Defined(TestRunKey)
  #if !Defined(TestAppId) || !Defined(TestInstallDir) || !Defined(TestShortcutName) || !Defined(TestFixturePath) || !Defined(TestRunKey)
    #error All five test isolation defines are required together.
  #endif
  #define InstallerId TestAppId
  #define InstallDir TestInstallDir
  #define ShortcutName TestShortcutName
  #define DesktopShortcutName TestShortcutName
  #define ProductName "BetterIcon TEST"
  #define OutputName "BetterIcon-TEST-Setup-" + AppVersion
  #define FixtureArgs ' --config "' + TestFixturePath + '"'
  #define RunKey TestRunKey
#else
  #define InstallerId "BetterIcon.ArtCraft.Windows"
  #define InstallDir "{localappdata}\Programs\BetterIcon"
  #define ShortcutName "BetterIcon"
  #define DesktopShortcutName "BetterIcon"
  #define ProductName "BetterIcon for ArtCraft"
  #define OutputName "BetterIcon-Setup-" + AppVersion
  #define FixtureArgs ""
  #define RunKey "Software\Microsoft\Windows\CurrentVersion\Run"
#endif
; The app adds this per-user login entry itself at its first start. Setup only keeps it current and removes it.
#define RunValue "BetterIcon"
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

[InstallDelete]
; Earlier builds of this version could carry every pack. Their artwork must not stay beside the new catalog.
Type: filesandordirs; Name: "{#PayloadDir}\Craft-Icons-*"
Type: files; Name: "{#PayloadDir}\Windows\Included.tsv"

[Files]
; Each version has its own catalog root. Setup removes the folders of superseded versions once it has installed.
; Inno's uninstall log removes only files installed by Setup, across upgrades.
Source: "{#PayloadRoot}\*"; DestDir: "{#PayloadDir}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadRoot}\Windows\BetterIcon-Tray.exe"; DestName: "BetterIcon-InstallerHelper.exe"; Flags: dontcopy

[Icons]
Name: "{autoprograms}\{#ShortcutName}"; Filename: "{#AppExe}"; Parameters: "--source-folder ""{#PayloadDir}\Windows""{#FixtureSectionArgs}"; WorkingDir: "{#PayloadDir}\Windows"; IconFilename: "{#AppExe}"; Comment: "Launch BetterIcon for ArtCraft"
Name: "{autodesktop}\{#DesktopShortcutName}"; Filename: "{#AppExe}"; Parameters: "--source-folder ""{#PayloadDir}\Windows""{#FixtureSectionArgs}"; WorkingDir: "{#PayloadDir}\Windows"; IconFilename: "{#AppExe}"; Comment: "Launch BetterIcon for ArtCraft"; Tasks: desktopicon

[Run]
; The optional downloads chosen in Setup go to the app, which fetches them in the background (see SetupDownloadArgs).
Filename: "{#AppExe}"; Parameters: "--source-folder ""{#PayloadDir}\Windows""{#FixtureSectionArgs}{code:SetupDownloadArgs}"; Description: "Open BetterIcon"; Flags: nowait postinstall skipifsilent

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

// An earlier version's folder is hundreds of megabytes when it carried every pack. Nothing reads it once this
// version is installed: preferences, personal packs, applied icons and backups live outside the versions folder.
procedure RemoveSupersededVersions();
var
  Find: TFindRec;
  Versions, Current: String;
begin
  Versions := ExpandConstant('{app}\versions');
  Current := ExtractFileName(ExpandConstant('{#PayloadDir}'));
  if FindFirst(Versions + '\*', Find) then
  try
    repeat
      if (Find.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0) and (Find.Name <> '.') and (Find.Name <> '..') and
         (CompareText(Find.Name, Current) <> 0) and (Length(Find.Name) > 0) and (Find.Name[1] >= '0') and (Find.Name[1] <= '9') then
        DelTree(Versions + '\' + Find.Name, True, True, True);
    until not FindNext(Find);
  finally
    FindClose(Find);
  end;
end;

// The login entry names the program of one version. After an upgrade, point an existing entry of this
// installation at the new version. Setup never creates the entry: the app adds it once, and keeps the user's choice.
procedure UpdateLoginEntry();
var
  Data: String;
begin
  if not RegQueryStringValue(HKCU, '{#RunKey}', '{#RunValue}', Data) then Exit;
  if (Pos(Lowercase(ExpandConstant('{app}') + '\versions\'), Lowercase(Data)) > 0) and
     (Pos('\bettericon-tray.exe', Lowercase(Data)) > 0) then
    RegWriteStringValue(HKCU, '{#RunKey}', '{#RunValue}',
      '"' + ExpandConstant('{#AppExe}') + '" --tray --source-folder "' + ExpandConstant('{#PayloadDir}\Windows') + '"{#FixtureCodeArgs}');
end;

// ---- Optional downloads ---------------------------------------------------------------------------------------------
// After the files are installed, a page offers up to three downloads, each with its size: WebP support (Google's
// libwebp, only where Windows cannot decode WebP), all app icon packs and all file type icon packs, never what this
// computer already has. The installed program answers what to offer: --probe-webp decodes a tiny WebP through Windows'
// own decoder and reports by exit code, and --setup-status reports the packs still to download and their sizes.
// Setup downloads nothing itself. It hands the choices to the installed app (--setup-downloads), which downloads them in
// the background, checks each against its pinned checksum or the pack catalog, and offers again what fails, so a failed
// or cancelled download never stops Setup. A silent install downloads only what /DOWNLOADS=webp,app-packs,file-packs asks.
var
  DownloadsPage: TInputOptionWizardPage;
  WebPIndex, AppPacksIndex, FilePacksIndex: Integer;
  ChosenDownloads: String;

function SizeText(Bytes: Int64): String;
var
  Tenths: Int64;
begin
  if Bytes < 1048576 then
    Result := IntToStr((Bytes + 512) div 1024) + ' KB'
  else begin
    Tenths := (Bytes * 10 + 524288) div 1048576;
    Result := IntToStr(Tenths div 10) + '.' + IntToStr(Tenths mod 10) + ' MB';
  end;
end;

function InstalledHelperArgs(): String;
begin
  Result := '--source-folder "' + ExpandConstant('{#PayloadDir}\Windows') + '"{#FixtureCodeArgs}';
end;

procedure AddDownloadChoice(var Index: Integer; const Text: String);
begin
  Index := DownloadsPage.Add(Text);
  DownloadsPage.Values[Index] := False;
end;

function DownloadRequested(const List, Name: String): Boolean;
begin
  Result := Pos(',' + Name + ',', ',' + Lowercase(List) + ',') > 0;
end;

procedure AddChosen(const Name: String);
begin
  if ChosenDownloads <> '' then ChosenDownloads := ChosenDownloads + ',';
  ChosenDownloads := ChosenDownloads + Name;
end;

// A pack choice as the page shows it. The installed program words it (--setup-status, Text=): one pack in the singular,
// and a size that is a lower bound, or unknown, when it could not size every pack. This is only its fallback.
function PackChoiceText(const Section, Caption: String; Count: Integer; Bytes: Int64; const StatusFile: String): String;
begin
  Result := GetIniString(Section, 'Text', '', StatusFile);
  if Result = '' then Result := Caption + ' (' + IntToStr(Count) + ' packs, ' + SizeText(Bytes) + ')';
end;

procedure CheckOptionalDownloads();
var
  Exe, StatusFile, Requested, ChoiceText: String;
  Probe, Code, AppCount, FileCount: Integer;
  WebPBytes, AppBytes, FileBytes: Int64;
begin
  WebPIndex := -1; AppPacksIndex := -1; FilePacksIndex := -1; ChosenDownloads := '';
  Requested := Trim(ExpandConstant('{param:DOWNLOADS|}'));
  if WizardSilent and (Requested = '') then begin
    Log('Optional downloads: none requested (silent install without /DOWNLOADS).');
    Exit;
  end;
  Exe := ExpandConstant('{#AppExe}');
  WizardForm.StatusLabel.Caption := 'Checking optional downloads...';
  if not Exec(Exe, '--probe-webp ' + InstalledHelperArgs(), '', SW_HIDE, ewWaitUntilTerminated, Probe) then Probe := -1;
  StatusFile := ExpandConstant('{tmp}\optional-downloads.ini');
  if not Exec(Exe, '--setup-status "' + StatusFile + '" ' + InstalledHelperArgs(), '', SW_HIDE, ewWaitUntilTerminated, Code) then Code := -1;
  if Code <> 0 then Log('Optional downloads: the pack check reported ' + IntToStr(Code) + ': ' + GetIniString('Error', 'Message', '', StatusFile));
  WebPBytes := StrToInt64Def(GetIniString('WebP', 'Bytes', '0', StatusFile), 0);
  AppCount := StrToIntDef(GetIniString('AppPacks', 'Count', '0', StatusFile), 0);
  AppBytes := StrToInt64Def(GetIniString('AppPacks', 'Bytes', '0', StatusFile), 0);
  FileCount := StrToIntDef(GetIniString('FilePacks', 'Count', '0', StatusFile), 0);
  FileBytes := StrToInt64Def(GetIniString('FilePacks', 'Bytes', '0', StatusFile), 0);
  case Probe of
    0: Log('Optional downloads: WebP support not offered: Windows decodes WebP.');
    1: begin
         Log('Optional downloads: WebP support offered (Windows can''t decode WebP), ' + IntToStr(WebPBytes) + ' bytes.');
         AddDownloadChoice(WebPIndex, 'WebP support (Google''s libwebp, ' + SizeText(WebPBytes) + '): for icons drawn in WebP. Microsoft''s free WebP Image Extensions work too.');
       end;
    2: Log('Optional downloads: WebP support not offered: already installed.');
    3: Log('Optional downloads: WebP support not offered: no build for this PC.');
  else
    Log('Optional downloads: WebP support not offered: the check failed (' + IntToStr(Probe) + ').');
  end;
  if AppCount > 0 then begin
    Log('Optional downloads: all app icon packs offered: ' + IntToStr(AppCount) + ' packs, ' + IntToStr(AppBytes) + ' bytes.');
    ChoiceText := PackChoiceText('AppPacks', 'All app icon packs', AppCount, AppBytes, StatusFile);
    Log('Optional downloads: choice shown: ' + ChoiceText);
    AddDownloadChoice(AppPacksIndex, ChoiceText);
  end else
    Log('Optional downloads: all app icon packs not offered: none left to download.');
  if FileCount > 0 then begin
    Log('Optional downloads: all file type icon packs offered: ' + IntToStr(FileCount) + ' packs, ' + IntToStr(FileBytes) + ' bytes.');
    ChoiceText := PackChoiceText('FilePacks', 'All file type icon packs', FileCount, FileBytes, StatusFile);
    Log('Optional downloads: choice shown: ' + ChoiceText);
    AddDownloadChoice(FilePacksIndex, ChoiceText);
  end else
    Log('Optional downloads: all file type icon packs not offered: none left to download.');
  if WizardSilent then begin
    if (WebPIndex >= 0) and DownloadRequested(Requested, 'webp') then AddChosen('webp');
    if (AppPacksIndex >= 0) and DownloadRequested(Requested, 'app-packs') then AddChosen('app-packs');
    if (FilePacksIndex >= 0) and DownloadRequested(Requested, 'file-packs') then AddChosen('file-packs');
    if ChosenDownloads = '' then Log('Optional downloads: none requested (/DOWNLOADS=' + Requested + ' asks for nothing that is offered).')
    else Log('Optional downloads: requested: ' + ChosenDownloads + '.');
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := (DownloadsPage <> nil) and (PageID = DownloadsPage.ID) and (WizardSilent or (DownloadsPage.CheckListBox.Items.Count = 0));
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (DownloadsPage <> nil) and (CurPageID = DownloadsPage.ID) then begin
    ChosenDownloads := '';
    if (WebPIndex >= 0) and DownloadsPage.Values[WebPIndex] then AddChosen('webp');
    if (AppPacksIndex >= 0) and DownloadsPage.Values[AppPacksIndex] then AddChosen('app-packs');
    if (FilePacksIndex >= 0) and DownloadsPage.Values[FilePacksIndex] then AddChosen('file-packs');
    if ChosenDownloads = '' then Log('Optional downloads: none chosen.') else Log('Optional downloads: chosen: ' + ChosenDownloads + '.');
  end;
end;

// Appended to the Open BetterIcon entry, so the app that opens fetches the chosen downloads.
function SetupDownloadArgs(Param: String): String;
begin
  Result := '';
  if ChosenDownloads <> '' then Result := ' --setup-downloads ' + ChosenDownloads;
end;

// When nothing else opens BetterIcon after Setup (a silent install, or Open BetterIcon unchecked), it starts in the
// tray to download what was chosen.
procedure HandOverDownloads();
var
  Code: Integer;
begin
  if ChosenDownloads = '' then Exit;
  if (not WizardSilent) and (WizardForm.RunList.Items.Count > 0) and WizardForm.RunList.Checked[0] then Exit;
  if ExecAsOriginalUser(ExpandConstant('{#AppExe}'), '--tray ' + InstalledHelperArgs() + ' --setup-downloads ' + ChosenDownloads, '', SW_HIDE, ewNoWait, Code) then
    Log('Optional downloads: BetterIcon starts in the tray to download ' + ChosenDownloads + '.')
  else
    Log('Optional downloads: BetterIcon could not start; it offers the downloads again the next time it starts.');
end;

procedure InitializeWizard();
begin
  DownloadsPage := CreateInputOptionPage(wpInstalling, 'Optional downloads', 'Download more for BetterIcon now?',
    'BetterIcon downloads what you choose here after Setup closes and checks each file. A pack you skip still downloads when you choose it in BetterIcon.',
    False, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    UpdateLoginEntry();
    RemoveSupersededVersions();
    CheckOptionalDownloads();
  end;
  if CurStep = ssDone then HandOverDownloads();
end;

// Uninstall removes the login entry when it starts this installation. Windows' own Startup apps state is left alone.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep = usUninstall then
    if RegQueryStringValue(HKCU, '{#RunKey}', '{#RunValue}', Data) then
      if Pos(Lowercase(ExpandConstant('{app}') + '\'), Lowercase(Data)) > 0 then
        RegDeleteValue(HKCU, '{#RunKey}', '{#RunValue}');
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
