#ifndef AppVersion
  #define AppVersion "1.1.0"
#endif
#ifndef SourceRoot
  #define SourceRoot "..\dist\WebPFolderConverter"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist\installer"
#endif

#define AppNameValue "WebP Folder Converter"
#define RepositoryUrl "https://github.com/kazurou147/WebP-Converter"

[Setup]
AppId={{A39D662A-4554-4EF0-9E11-541FFAD70C43}
AppName={#AppNameValue}
AppVersion={#AppVersion}
AppVerName={#AppNameValue} {#AppVersion}
AppPublisher=kazurou147
AppPublisherURL={#RepositoryUrl}
AppSupportURL={#RepositoryUrl}/issues
AppUpdatesURL={#RepositoryUrl}/releases
AppReadmeFile={app}\README.md
DefaultDirName={localappdata}\Programs\WebPFolderConverter
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
MinVersion=10.0.22000
ArchitecturesAllowed=x64os
SetupArchitecture=x64
OutputDir={#OutputDir}
OutputBaseFilename=WebP-Converter-Setup-{#AppVersion}
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}
VersionInfoCompany=kazurou147
VersionInfoDescription={#AppNameValue} Installer
VersionInfoProductName={#AppNameValue}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dynamic
Uninstallable=yes
UninstallDisplayName={#AppNameValue} {#AppVersion}
CreateUninstallRegKey=yes
UsePreviousAppDir=no
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
SetupLogging=yes

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceRoot}\package.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\package-lock.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\release-manifest.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\THIRD-PARTY-NOTICES.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\src\*"; DestDir: "{app}\src"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\node_modules\*"; DestDir: "{app}\node_modules"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\scripts\invoke.ps1"; DestDir: "{app}"; DestName: "invoke.ps1"; Flags: ignoreversion
Source: "{#SourceRoot}\scripts\installer-migration.ps1"; Flags: dontcopy
Source: "v1.0.0-installed-manifest.json"; Flags: dontcopy

[Registry]
Root: HKCU; Subkey: "Software\Classes\Directory\shell\WebPFolderConverter"; ValueType: string; ValueName: ""; ValueData: "WebPに変換"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Directory\shell\WebPFolderConverter"; ValueType: string; ValueName: "MUIVerb"; ValueData: "WebPに変換"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\WebPFolderConverter"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\runtime\node.exe"
Root: HKCU; Subkey: "Software\Classes\Directory\shell\WebPFolderConverter\command"; ValueType: string; ValueName: ""; ValueData: """{sys}\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""{app}\invoke.ps1"" ""%1"""

[UninstallDelete]
Type: files; Name: "{app}\uninstall.ps1"
Type: dirifempty; Name: "{app}"

[Code]
var
  LegacyMigrationPrepared: Boolean;
  InstallCommitted: Boolean;

function MigrationStatePath: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\.WebPFolderConverter.migration.json');
end;

function LegacyBackupPath: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\.WebPFolderConverter.v1.0.0-backup');
end;

function UninstallRegistryPath: String;
begin
  Result := 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A39D662A-4554-4EF0-9E11-541FFAD70C43}_is1';
end;

function RunMigrationHelper(ActionName: String; var ResultCode: Integer): Boolean;
var
  Parameters: String;
begin
  ExtractTemporaryFile('installer-migration.ps1');
  ExtractTemporaryFile('v1.0.0-installed-manifest.json');
  Parameters := '-NoProfile -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{tmp}\installer-migration.ps1')) +
    ' -Action ' + ActionName +
    ' -InstallDir ' + AddQuotes(ExpandConstant('{app}')) +
    ' -BackupDir ' + AddQuotes(LegacyBackupPath) +
    ' -StatePath ' + AddQuotes(MigrationStatePath) +
    ' -UninstallRegistryPath ' + AddQuotes(UninstallRegistryPath) +
    ' -TrustedManifestPath ' + AddQuotes(ExpandConstant('{tmp}\v1.0.0-installed-manifest.json'));
  Result := Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if not RunMigrationHelper('Prepare', ResultCode) then
  begin
    Result := '既存バージョンの確認処理を開始できませんでした。セットアップログを確認してください。';
    exit;
  end;
  if ResultCode = 10 then
  begin
    LegacyMigrationPrepared := True;
    Log('A verified v1.0.0 installation was backed up for migration.');
  end
  else if ResultCode <> 0 then
    Result := '既存インストールを安全に移行できません。アプリの状態を確認してから再実行してください。';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if LegacyMigrationPrepared then
    begin
      if (not RunMigrationHelper('Commit', ResultCode)) or (ResultCode <> 0) then
        RaiseException('v1.0.0からの更新を確定できませんでした。旧バージョンを復元します。');
    end;
    InstallCommitted := True;
  end;
end;

procedure DeinitializeSetup;
var
  ResultCode: Integer;
begin
  if LegacyMigrationPrepared and (not InstallCommitted) then
  begin
    if (not RunMigrationHelper('Restore', ResultCode)) or (ResultCode <> 0) then
      Log('ERROR: Automatic v1.0.0 restoration failed. Preserve the migration state and backup for manual recovery.');
  end;
end;
