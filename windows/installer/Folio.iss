; Folio for Windows: the installer people run, and the one Folio's updater runs too.
;
; It puts the published app (dotnet publish of Folio.Desktop and folio-cli) where the user chooses, with the usual
; pages: welcome, licence, location, shortcuts, and Folio started at the end. An update is this same installer run
; quietly by Folio (/SILENT or /VERYSILENT); /RELAUNCH then starts Folio again.
;
; Built by .github/workflows/release.yml:
;   ISCC.exe /DArch=arm64 /DAppVersion=1.2.0 /DSourceDir=publish /DOutputDir=release windows\installer\Folio.iss

#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "publish"
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
#if Arch == "arm64"
OutputBaseFilename=Folio-{#AppVersion}-Windows-ARM64-Setup
#else
OutputBaseFilename=Folio-{#AppVersion}-Windows-x64-Setup
#endif
SetupIconFile=..\src\Folio.Desktop\Assets\Folio.ico
UninstallDisplayIcon={app}\Folio.exe
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
Name: "{userprograms}\Folio"; Filename: "{app}\Folio.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\Folio"; Filename: "{app}\Folio.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Through Explorer, so Folio starts as from the Start menu: with the shell's environment, not the installer's (on ARM64
; the installer runs emulated as x64, and what it hands its children made Folio miss the user's command-line agents).
Filename: "{win}\explorer.exe"; Parameters: """{app}\Folio.exe"""; Description: "{cm:LaunchProgram,Folio}"; Flags: nowait postinstall skipifsilent
; An update the user asked to restart for: Folio comes back by itself.
Filename: "{win}\explorer.exe"; Parameters: """{app}\Folio.exe"""; Flags: nowait; Check: Relaunch

[UninstallRun]
; Folio's own clean-up: the folio:// link it registered.
Filename: "{app}\Folio.exe"; Parameters: "--unregister"; Flags: runhidden waituntilterminated; RunOnceId: "FolioUnregister"

[UninstallDelete]
; The library and settings live elsewhere and stay.
Type: dirifempty; Name: "{app}"

[Code]
const
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

{ A running Folio (often only in the notification area) holds its files: it is asked to quit first, saving what is in
  flight, and ended if it has not after a moment. The library and settings live elsewhere and stay. }
function InitializeUninstall: Boolean;
var
  Code: Integer;
begin
  Result := True;
  if Exec(ExpandConstant('{app}\Folio.exe'), '--quit', '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Sleep(2000);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM Folio.exe /F', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function Relaunch: Boolean;
begin
  Result := WizardSilent and (Pos('/RELAUNCH', UpperCase(GetCmdTail)) > 0);
end;

{ Folio's reader needs the WebView2 runtime; Windows 11 has it. Without it Folio still starts and says where to get it. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
#if WebView2Bootstrapper != ""
  if not HasWebView2 then
  begin
    WizardForm.StatusLabel.Caption := 'Microsoft Edge WebView2';
    ExtractTemporaryFile('MicrosoftEdgeWebview2Setup.exe');
    Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
#endif
end;
