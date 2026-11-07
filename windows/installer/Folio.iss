; Folio for Windows: the installer people run.
;
; Velopack builds the app (Folio-win-<arch>-Portable.zip: Update.exe, Folio.exe, current\) and keeps it up to date;
; this wizard puts that folder where the user chooses, with the usual pages: welcome, licence, location, shortcuts,
; and Folio started at the end. Updates then come from inside Folio as before (Velopack's portable layout).
;
; Built by .github/workflows/release-windows.yml:
;   ISCC.exe /DArch=arm64 /DAppVersion=1.2.0 /DSourceDir=<unzipped Portable.zip> /DOutputDir=releases windows\installer\Folio.iss

#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "portable"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
; Microsoft's WebView2 bootstrapper (MicrosoftEdgeWebview2Setup.exe), run only where the runtime is missing (some
; Windows 10). CI downloads it; a local build may leave it out.
#ifndef WebView2Bootstrapper
  #define WebView2Bootstrapper ""
#endif

[Setup]
AppId={{BA84E7D0-2191-46C0-A2E2-8088B026856E}
AppName=Folio
AppVersion={#AppVersion}
AppVerName=Folio {#AppVersion}
AppPublisher=Folio
AppPublisherURL=https://github.com/Alonemo-Nnqc/Folio
AppSupportURL=https://github.com/Alonemo-Nnqc/Folio/issues
VersionInfoVersion={#AppVersion}
; For the user who installs it: no administrator needed, and the in-app updater can write to the folder.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Folio
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
DisableDirPage=no
DisableReadyPage=no
LicenseFile=..\..\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename=Folio-win-{#Arch}-Setup
SetupIconFile=..\src\Folio.Desktop\Assets\Folio.ico
UninstallDisplayIcon={app}\current\Folio.exe
UninstallDisplayName=Folio
WizardStyle=modern
WizardSizePercent=110
WizardImageFile=wizard-100.bmp,wizard-150.bmp,wizard-200.bmp
WizardSmallImageFile=wizard-small-100.bmp,wizard-small-150.bmp,wizard-small-200.bmp
Compression=lzma2/ultra64
SolidCompression=yes
ShowLanguageDialog=auto
; A running Folio (also one in the notification area) is closed first; it saves what is in flight as on shutdown.
CloseApplications=force
RestartApplications=no
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#if WebView2Bootstrapper != ""
Source: "{#WebView2Bootstrapper}"; DestName: "MicrosoftEdgeWebview2Setup.exe"; Flags: dontcopy
#endif

[Icons]
Name: "{userprograms}\Folio"; Filename: "{app}\current\Folio.exe"; WorkingDir: "{app}\current"
Name: "{userdesktop}\Folio"; Filename: "{app}\current\Folio.exe"; WorkingDir: "{app}\current"; Tasks: desktopicon

[Run]
; Through Explorer, so Folio starts as from the Start menu: with the shell's environment, not the installer's (on ARM64
; the installer runs emulated as x64, and what it hands its children made Folio miss the user's command-line agents).
Filename: "{win}\explorer.exe"; Parameters: """{app}\current\Folio.exe"""; Description: "{cm:LaunchProgram,Folio}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Folio's own clean-up (the folio:// link it registered), as Velopack's uninstaller would ask it to.
Filename: "{app}\current\Folio.exe"; Parameters: "--veloapp-uninstall {#AppVersion}"; Flags: runhidden waituntilterminated; RunOnceId: "FolioUnregister"

[UninstallDelete]
; Updates add versions and packages the installer never wrote. The library and settings live elsewhere and stay.
Type: filesandordirs; Name: "{app}\current"
Type: filesandordirs; Name: "{app}\packages"
Type: dirifempty; Name: "{app}"

[Code]
const
  OneClickKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\Folio';
  WebView2Client = 'Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

{ The WebView2 runtime, installed for the machine or for this user. }
function HasWebView2: Boolean;
var
  Version: String;
begin
  Result := (RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\' + WebView2Client, 'pv', Version) or
             RegQueryStringValue(HKLM, 'SOFTWARE\' + WebView2Client, 'pv', Version) or
             RegQueryStringValue(HKCU, 'Software\' + WebView2Client, 'pv', Version)) and (Version <> '') and (Version <> '0.0.0.0');
end;

{ Folio used to install in one click (Velopack's Setup.exe, into %LocalAppData%\Folio). That copy is removed first, so
  there is one Folio with one set of shortcuts; the library and settings are not in it and stay. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Command: String;
  Code: Integer;
begin
  Result := '';
  if RegQueryStringValue(HKCU, OneClickKey, 'QuietUninstallString', Command) and (Pos('Update.exe', Command) > 0) then
    Exec(ExpandConstant('{cmd}'), '/c "' + Command + '"', '', SW_HIDE, ewWaitUntilTerminated, Code);
#if WebView2Bootstrapper != ""
  { Folio's reader needs it; Windows 11 has it. Without it Folio still starts and says where to get it. }
  if not HasWebView2 then
  begin
    WizardForm.StatusLabel.Caption := 'Microsoft Edge WebView2';
    ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
    Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
#endif
end;
