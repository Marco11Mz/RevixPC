; Revix PC - instalador (Inno Setup 6)
; Lo compila GitHub Actions al publicar una etiqueta vX.Y.Z (ver .github/workflows/release.yml).
; Para probar a mano en Windows:  ISCC /DAppVersion=4.2.1 installer\RevixPC.iss
; (antes hay que tener dist\RevixPC.exe, el lanzador)

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppName "Revix PC"
#define AppExe "RevixPC.exe"
#define RepoUrl "https://github.com/Marco11Mz/RevixPC"

[Setup]
; AppId fijo: Windows guarda la entrada como "RevixPC_is1". No cambiarlo nunca.
AppId=RevixPC
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Marco11
AppPublisherURL={#RepoUrl}
AppSupportURL={#RepoUrl}/issues
AppUpdatesURL={#RepoUrl}/releases
AppCopyright=Marco11 - Licencia MIT
DefaultDirName={autopf}\Revix PC
DisableDirPage=yes
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
SetupIconFile=..\RevixPC.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir=..\dist
OutputBaseFilename=RevixPC-Setup-{#AppVersion}
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
CloseApplications=no
ShowLanguageDialog=no
UsedUserAreasWarning=no
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=Marco11
VersionInfoDescription=Instalador de Revix PC
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\dist\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\RevixPC.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\RevixPC.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; AppUserModelID: "Marco11.RevixPC"; Comment: "Actualizaciones, drivers y salud de la PC"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; AppUserModelID: "Marco11.RevixPC"; Comment: "Actualizaciones, drivers y salud de la PC"; Tasks: desktopicon

[InstallDelete]
; Restos de ActualizaPC 4.1
Type: files; Name: "{userdesktop}\ActualizaPC.lnk"
Type: files; Name: "{userprograms}\ActualizaPC.lnk"
Type: filesandordirs; Name: "{localappdata}\Programs\ActualizaPC"
; Accesos directos que creaba Revix PC 4.2.0 (ahora los crea el instalador)
Type: files; Name: "{userdesktop}\Revix PC.lnk"
Type: files; Name: "{userprograms}\Revix PC.lnk"

[Registry]
; Entrada de desinstalación que creaba Revix PC 4.2.0 (ahora la crea el instalador como RevixPC_is1)
Root: HKLM; Subkey: "Software\Microsoft\Windows\CurrentVersion\Uninstall\RevixPC"; Flags: deletekey

[Run]
; Tarea de inicio de ActualizaPC 4.1 (si no existe, no pasa nada)
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""ActualizaPC"" /F"; Flags: runhidden waituntilterminated; StatusMsg: "Quitando restos de ActualizaPC..."
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent shellexec
; Al actualizar desde la app (/SILENT /UPDATE) se vuelve a abrir sola
Filename: "{app}\{#AppExe}"; Flags: nowait shellexec; Check: IsUpdate

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""RevixPC"" /F"; Flags: runhidden waituntilterminated; RunOnceId: "QuitarTareaInicio"

[Code]
const
  AppMutexName = 'Local\RevixPC_Instance';

function IsUpdate: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/UPDATE') = 0 then
      Result := True;
end;

// Espera a que Revix PC se cierre (al actualizar, la app se cierra sola)
function WaitAppClosed(Silent: Boolean): Boolean;
var
  I: Integer;
begin
  for I := 1 to 30 do
  begin
    if not CheckForMutexes(AppMutexName) then
    begin
      Result := True;
      exit;
    end;
    Sleep(500);
  end;
  Result := False;
  while CheckForMutexes(AppMutexName) do
  begin
    if Silent then
      exit;
    if MsgBox('Revix PC está abierta.' + #13#10#13#10 +
              'Ciérrala del todo (clic derecho en su ícono junto al reloj > Salir) y pulsa Aceptar.',
              mbInformation, MB_OKCANCEL) <> IDOK then
      exit;
  end;
  Result := True;
end;

function InitializeSetup: Boolean;
begin
  Result := WaitAppClosed(WizardSilent and not IsUpdate);
end;

function InitializeUninstall: Boolean;
begin
  Result := WaitAppClosed(UninstallSilent);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if (CurUninstallStep = usPostUninstall) and (not UninstallSilent) then
  begin
    DataDir := ExpandConstant('{userappdata}\RevixPC');
    if DirExists(DataDir) then
      if MsgBox('¿Borrar también tus ajustes e historial de Revix PC?' + #13#10#13#10 + DataDir,
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
