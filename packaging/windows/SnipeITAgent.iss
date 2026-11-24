; Inno Setup script for the Snipe-IT inventory agent (Windows).
; Built by .github/workflows/build-installers.yml:
;   iscc /DAppVersion=1.0.0 /DConfigFile=path\to\config.json /DOutputDir=out SnipeITAgent.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef ConfigFile
  #define ConfigFile "config.json"
#endif
#ifndef OutputDir
  #define OutputDir "out"
#endif

[Setup]
AppId={{6F1C9A52-3B7E-4D7A-9A3E-5D2C8B1F4E10}
AppName=WiSilica IT Inventory Agent
AppVersion={#AppVersion}
AppPublisher=WiSilica IT
DefaultDirName={commonpf}\SnipeIT Inventory Agent
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=SnipeIT-Agent-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=WiSilica IT Inventory Agent
SetupLogging=yes

[Messages]
WelcomeLabel2=This installs the IT inventory agent, which reports this computer's hardware and installed applications to the IT asset system once a day.%n%nIt runs in the background and does not collect files, browsing history or personal data.

[Files]
Source: "..\..\SnipeIT-Agent.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\Install-Agent.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\Uninstall-Agent.ps1"; DestDir: "{app}"; Flags: ignoreversion
; Copied to {app} only for the install step below, then deleted right away.
Source: "{#ConfigFile}"; DestDir: "{app}"; DestName: "config.json"; Flags: ignoreversion

[UninstallRun]
Filename: "{sysnative}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Uninstall-Agent.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveAgent"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Params: String;
begin
  if CurStep = ssPostInstall then
  begin
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\Install-Agent.ps1') +
              '" -ConfigFile "' + ExpandConstant('{app}\config.json') + '"';
    if (not Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'), Params, '',
                 SW_HIDE, ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
      MsgBox('The inventory agent could not be set up (error ' + IntToStr(ResultCode) + '). Please contact IT.',
             mbError, MB_OK);
    DeleteFile(ExpandConstant('{app}\config.json'));
  end;
end;
