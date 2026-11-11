# ===================================================================
#  Revix PC 4.2.0  -  Programas, Windows Update, drivers y salud de la PC
#  Windows 10/11 - Windows PowerShell 5.1 (viene con Windows)
#  Autor: Marco11  ·  Licencia MIT  ·  https://github.com/Marco11Mz/RevixPC
# ===================================================================
param([switch]$NoElevate, [switch]$Tray, [switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'Revix PC'
$script:AppVersion = '4.2.0'
$script:AppId      = 'Marco11.RevixPC'
$script:GitHubRepo = 'Marco11Mz/RevixPC'
$script:GitHubUrl  = "https://github.com/$($script:GitHubRepo)"
$script:AppDir     = $PSScriptRoot
$script:IconPath   = Join-Path $PSScriptRoot 'RevixPC.ico'
if (-not (Test-Path $script:IconPath) -and (Test-Path (Join-Path $PSScriptRoot 'ActualizaPC.ico'))) { $script:IconPath = Join-Path $PSScriptRoot 'ActualizaPC.ico' }
$script:InstallDir = Join-Path $env:ProgramFiles 'Revix PC'
$script:PsExe      = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RevixPC'

# ---------- STA + permisos de administrador ----------
$extra = ''
if ($Tray) { $extra += ' -Tray' }
if ($Uninstall) { $extra += ' -Uninstall' }
$relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -NoElevate$extra"

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process $script:PsExe -ArgumentList $relaunchArgs
    exit
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin -and -not $NoElevate) {
    try {
        Start-Process $script:PsExe -Verb RunAs -ArgumentList $relaunchArgs -ErrorAction Stop
        exit
    } catch { }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

$script:DataDir    = Join-Path $env:APPDATA 'RevixPC'
$script:OldDataDir = Join-Path $env:APPDATA 'ActualizaPC'
$script:ErrorLog   = Join-Path $env:TEMP 'RevixPC-error.log'
function Write-ErrorLog([string]$text) {
    try { Add-Content -Path $script:ErrorLog -Value ("[{0}] {1}" -f (Get-Date), $text) -Encoding UTF8 } catch {}
}

# ===================================================================
#  Desinstalar (se llama desde "Aplicaciones" de Windows o desde Ajustes)
# ===================================================================
if ($Uninstall) {
    $title = 'Desinstalar Revix PC'
    if (-not $script:IsAdmin) {
        [void][System.Windows.MessageBox]::Show('Para desinstalar Revix PC hay que aceptar el aviso de administrador de Windows.', $title, 'OK', 'Warning')
        exit
    }
    $ans = [System.Windows.MessageBox]::Show('¿Desinstalar Revix PC de este equipo?', $title, 'YesNo', 'Question')
    if ([string]$ans -ne 'Yes') { exit }
    # Cerrar la app si está abierta
    try { $ev = [System.Threading.EventWaitHandle]::OpenExisting('Local\RevixPC_Exit'); [void]$ev.Set(); Start-Sleep -Seconds 2 } catch {}
    try { Unregister-ScheduledTask -TaskName 'RevixPC' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        $l = Join-Path $folder 'Revix PC.lnk'
        if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
    }
    try { Remove-Item -Path $script:UninstallKey -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    if (Test-Path $script:DataDir) {
        $d = [System.Windows.MessageBox]::Show("¿Borrar también tus ajustes e historial?`n`n$($script:DataDir)", $title, 'YesNo', 'Question')
        if ([string]$d -eq 'Yes') { Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $script:InstallDir) {
        Set-Location $env:TEMP
        $cmd = "/c timeout /t 3 /nobreak >nul & rmdir /s /q `"$($script:InstallDir)`""
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList $cmd -WindowStyle Hidden
    }
    [void][System.Windows.MessageBox]::Show('Revix PC se desinstaló.', $title, 'OK', 'Information')
    exit
}

# ---------- Una sola copia abierta ----------
try {
    $created = $false
    $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\RevixPC_Instance', [ref]$created)
    if (-not $created) {
        try { $ev = [System.Threading.EventWaitHandle]::OpenExisting('Local\RevixPC_Show'); [void]$ev.Set() } catch {}
        exit
    }
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\RevixPC_Show')
    $script:ExitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\RevixPC_Exit')
} catch {
    $script:ShowEvent = $null; $script:ExitEvent = $null
}

# ---------- Clases de datos ----------
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace RevixPC {
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
        [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
        [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
        [PreserveSig] int Commit();
    }
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(8)] public long pad; }
    public class ProgramItem {
        public bool Selected { get; set; }
        public string Name { get; set; }
        public string Id { get; set; }
        public string Version { get; set; }
        public string Available { get; set; }
        public string Source { get; set; }
        public bool Ignored { get; set; }
        public bool Skipped { get; set; }
        public bool Auto { get; set; }
        public bool Hidden { get { return Ignored || Skipped; } }
        public string StateText { get { return Ignored ? "Ignorado" : (Skipped ? "Versión saltada" : (Auto ? "Automático" : "")); } }
    }
    public class UpdateItem {
        public bool Selected { get; set; }
        public string Title { get; set; }
        public string Kind { get; set; }
        public string KB { get; set; }
        public string Size { get; set; }
        public string Severity { get; set; }
        public string UpdateId { get; set; }
        public bool IsDriver { get; set; }
    }
    public class DeviceItem {
        public string StatusText { get; set; }
        public string StatusColor { get; set; }
        public string Name { get; set; }
        public string DeviceClass { get; set; }
        public string Manufacturer { get; set; }
        public string Version { get; set; }
        public string Date { get; set; }
        public string Note { get; set; }
        public string ActionText { get; set; }
        public string Link { get; set; }
        public bool HasLink { get; set; }
        public bool IsGeneric { get; set; }
        public int Priority { get; set; }
    }
    public class HealthRow {
        public string Section { get; set; }
        public string Item { get; set; }
        public string Value { get; set; }
        public string StatusText { get; set; }
        public string StatusColor { get; set; }
        public string ActionText { get; set; }
        public string Link { get; set; }
        public bool HasLink { get; set; }
        public int Level { get; set; }
    }
    public class CleanItem {
        public bool Selected { get; set; }
        public string Key { get; set; }
        public string Name { get; set; }
        public string SizeText { get; set; }
        public double Bytes { get; set; }
        public string Note { get; set; }
    }
    public class TaskItem : INotifyPropertyChanged {
        public event PropertyChangedEventHandler PropertyChanged;
        void N(string p) { var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
        string status, color, detail;
        public string Key { get; set; }
        public string Name { get; set; }
        public string StatusText { get { return status; } set { status = value; N("StatusText"); } }
        public string StatusColor { get { return color; } set { color = value; N("StatusColor"); } }
        public string Detail { get { return detail; } set { detail = value; N("Detail"); } }
    }
    public class InfoRow {
        public string Section { get; set; }
        public string Item { get; set; }
        public string Value { get; set; }
        public string Note { get; set; }
    }
    public class StartupItem {
        public bool Enabled { get; set; }
        public string Name { get; set; }
        public string Command { get; set; }
        public string Location { get; set; }
        public string Publisher { get; set; }
        public string Impact { get; set; }
        public string ValueName { get; set; }
        public string ApprovedPath { get; set; }
        public string FilePath { get; set; }
    }
    public class AppItem {
        public string Name { get; set; }
        public string Publisher { get; set; }
        public string Version { get; set; }
        public string Size { get; set; }
        public double SizeMB { get; set; }
        public string InstallDate { get; set; }
        public string UninstallString { get; set; }
    }
    public class RollbackItem {
        public bool Selected { get; set; }
        public string Name { get; set; }
        public string Id { get; set; }
        public string FromVersion { get; set; }
        public string ToVersion { get; set; }
        public string Date { get; set; }
    }
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
        [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int n);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr zero, int flags, ref Guid iid, out IPropertyStore store);

        // Borde oscuro o claro de la ventana (Windows 10 20H1+ y Windows 11)
        public static void SetDarkTitleBar(IntPtr h, bool dark) {
            try { int on = dark ? 1 : 0; if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); } catch { }
        }
        // Esquinas redondeadas en Windows 11 (en Windows 10 no hace nada)
        public static void SetRoundCorners(IntPtr h) {
            try { int round = 2; DwmSetWindowAttribute(h, 33, ref round, 4); } catch { }
        }
        public static void SetIcons(IntPtr h, IntPtr big, IntPtr small) {
            try { SendMessage(h, 0x80, (IntPtr)1, big); SendMessage(h, 0x80, IntPtr.Zero, small); } catch { }
        }
        public static void SetAppId(string id) {
            try { SetCurrentProcessExplicitAppUserModelID(id); } catch { }
        }
        public static bool SetShortcutAppId(string lnk, string appId) {
            try {
                Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
                IPropertyStore st;
                if (SHGetPropertyStoreFromParsingName(lnk, IntPtr.Zero, 2, ref iid, out st) != 0 || st == null) return false;
                var key = new PROPERTYKEY(); key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); key.pid = 5;
                var pv = new PROPVARIANT(); pv.vt = 31; pv.p = Marshal.StringToCoTaskMemUni(appId);
                try { st.SetValue(ref key, ref pv); st.Commit(); }
                finally { Marshal.FreeCoTaskMem(pv.p); Marshal.ReleaseComObject(st); }
                return true;
            } catch { return false; }
        }
        // true si hay un juego o app en pantalla completa (que no sea Revix PC)
        public static bool IsFullscreenAppRunning(int ownPid) {
            try {
                int st;
                if (SHQueryUserNotificationState(out st) == 0 && (st == 2 || st == 3 || st == 4)) return true;
            } catch { }
            try {
                IntPtr h = GetForegroundWindow();
                if (h == IntPtr.Zero) return false;
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (pid == (uint)ownPid) return false;
                var sb = new System.Text.StringBuilder(256);
                GetClassName(h, sb, 256);
                string c = sb.ToString();
                if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
                RECT r;
                if (!GetWindowRect(h, out r)) return false;
                IntPtr m = MonitorFromWindow(h, 2);
                var mi = new MONITORINFO();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (!GetMonitorInfo(m, ref mi)) return false;
                return r.Left <= mi.rcMonitor.Left && r.Top <= mi.rcMonitor.Top && r.Right >= mi.rcMonitor.Right && r.Bottom >= mi.rcMonitor.Bottom;
            } catch { return false; }
        }
    }
    public class TodoItem {
        public string Title { get; set; }
        public string Detail { get; set; }
        public string Kind { get; set; }
        public string Tile { get; set; }
        public string Letter { get; set; }
        public string ActionText { get; set; }
        public string Target { get; set; }
    }
    public class MiniRow {
        public string Name { get; set; }
        public string Value { get; set; }
        public double Pct { get; set; }
        public string Color { get; set; }
    }
    public class HistoryItem {
        public string Date { get; set; }
        public string Action { get; set; }
        public string Result { get; set; }
    }
}
'@
[RevixPC.Native]::SetAppId($script:AppId)

# Al maximizar, respetar la barra de tareas (la ventana usa un marco propio)
try {
    $refs = @([System.Windows.Interop.HwndSource].Assembly.Location, [System.Windows.Threading.Dispatcher].Assembly.Location, [System.Xaml.XamlReader].Assembly.Location)
    Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;
namespace RevixPC {
    public static class MaxFix {
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct MINMAXINFO { public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
        static HwndSourceHook hook = Hook;
        static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
            if (msg == 0x0024) {
                try {
                    IntPtr m = MonitorFromWindow(h, 2);
                    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                    if (m != IntPtr.Zero && GetMonitorInfo(m, ref mi)) {
                        var mmi = (MINMAXINFO)Marshal.PtrToStructure(l, typeof(MINMAXINFO));
                        mmi.ptMaxPosition.X = mi.rcWork.Left - mi.rcMonitor.Left;
                        mmi.ptMaxPosition.Y = mi.rcWork.Top - mi.rcMonitor.Top;
                        mmi.ptMaxSize.X = mi.rcWork.Right - mi.rcWork.Left;
                        mmi.ptMaxSize.Y = mi.rcWork.Bottom - mi.rcWork.Top;
                        Marshal.StructureToPtr(mmi, l, true);
                    }
                } catch { }
            }
            return IntPtr.Zero;
        }
        public static void Attach(IntPtr h) { var s = HwndSource.FromHwnd(h); if (s != null) s.AddHook(hook); }
    }
}
'@
} catch { Write-ErrorLog "maxfix: $_" }

# ---------- Configuracion e historial ----------
# Migrar los datos de ActualizaPC (versiones 4.1 y anteriores)
$script:Migrated = $false
if (-not (Test-Path $script:DataDir) -and (Test-Path $script:OldDataDir)) {
    try { Copy-Item -LiteralPath $script:OldDataDir -Destination $script:DataDir -Recurse -Force; $script:Migrated = $true } catch { Write-ErrorLog "migrar: $_" }
}
$script:ConfigFile  = Join-Path $script:DataDir 'config.json'
$script:HistoryFile = Join-Path $script:DataDir 'historial.json'
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

$script:Config = @{
    RestorePoint = $true; StartWithWindows = $false; CloseToTray = $true
    Notify = $true; AutoCheckHours = 12
    GameMode = $true; GameProcesses = ''
    TempAlert = $true; GpuPfid = ''
    Theme = 'System'; CheckAppUpdates = $true
    WelcomeAccepted = $false; LastVersion = ''; UpdateNotes = ''
}
$script:IgnoredIds = New-Object 'System.Collections.Generic.List[string]'
$script:Skipped    = @{}
$script:AutoUpdateIds = New-Object 'System.Collections.Generic.List[string]'
$script:PrevVersions  = @{}
$script:History    = New-Object 'System.Collections.Generic.List[RevixPC.HistoryItem]'

function Load-Data {
    try {
        if (Test-Path $script:ConfigFile) {
            $cfg = Get-Content -Raw -Encoding UTF8 $script:ConfigFile | ConvertFrom-Json
            foreach ($k in @($script:Config.Keys)) {
                if ($cfg.PSObject.Properties[$k]) { $script:Config[$k] = $cfg.$k }
            }
            foreach ($id in @($cfg.IgnoredIds)) { if ($id) { $script:IgnoredIds.Add([string]$id) } }
            if ($cfg.SkippedVersions) {
                foreach ($p in $cfg.SkippedVersions.PSObject.Properties) { $script:Skipped[$p.Name] = [string]$p.Value }
            }
            foreach ($id in @($cfg.AutoUpdateIds)) { if ($id) { $script:AutoUpdateIds.Add([string]$id) } }
            if ($cfg.PrevVersions) {
                foreach ($p in $cfg.PrevVersions.PSObject.Properties) {
                    $v = $p.Value
                    $script:PrevVersions[$p.Name] = @{ Name = [string]$v.Name; From = [string]$v.From; To = [string]$v.To; Date = [string]$v.Date }
                }
            }
        }
    } catch { Write-ErrorLog "config: $_" }
    try {
        if (Test-Path $script:HistoryFile) {
            $data = Get-Content -Raw -Encoding UTF8 $script:HistoryFile | ConvertFrom-Json
            foreach ($h in @($data)) {
                if (-not $h) { continue }
                $it = New-Object RevixPC.HistoryItem
                $it.Date = [string]$h.Date; $it.Action = [string]$h.Action; $it.Result = [string]$h.Result
                $script:History.Add($it)
            }
        }
    } catch { Write-ErrorLog "historial: $_" }
}

function Save-Config {
    try {
        $o = @{}
        foreach ($k in $script:Config.Keys) { $o[$k] = $script:Config[$k] }
        $o.IgnoredIds = @($script:IgnoredIds)
        $o.SkippedVersions = $script:Skipped
        $o.AutoUpdateIds = @($script:AutoUpdateIds)
        $o.PrevVersions = $script:PrevVersions
        $o | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigFile -Encoding UTF8
    } catch { Write-ErrorLog "guardar config: $_" }
}

function Add-History([string]$action, [string]$result) {
    $it = New-Object RevixPC.HistoryItem
    $it.Date = (Get-Date).ToString('dd/MM/yyyy HH:mm')
    $it.Action = $action
    $it.Result = $result
    $script:History.Insert(0, $it)
    while ($script:History.Count -gt 300) { $script:History.RemoveAt($script:History.Count - 1) }
    try {
        $arr = @($script:History | Select-Object Date, Action, Result)
        ConvertTo-Json -InputObject $arr -Depth 3 | Set-Content -Path $script:HistoryFile -Encoding UTF8
    } catch { Write-ErrorLog "guardar historial: $_" }
    if ($script:GridHistory) { $script:GridHistory.ItemsSource = $null; $script:GridHistory.ItemsSource = $script:History }
}

# ---------- Tema claro / oscuro ----------
$script:Themes = @{
    Dark = [ordered]@{
        BgWindow = '#0F1115'; BgSide = '#14171D'; BgCard = '#1A1E26'; BorderCard = '#262B35'; BorderSoft = '#232832'
        BgControl = '#20252F'; BorderControl = '#343B48'; BorderInput = '#2C3240'
        Fg = '#E8EAED'; FgSoft = '#AEB6C4'; FgMuted = '#9AA3B2'; FgFaint = '#6B7383'
        Hover = '#1B1F27'; Selected = '#222836'; Track = '#2A3140'; Chip = '#232935'; Thumb = '#3A4150'; CapIcon = '#C9CFD9'
        Accent = '#3B7BF6'; TextAmber = '#F5B547'; TextRed = '#FF8A8A'; TextBlue = '#8AB4FF'
        WarnBg = '#3A2E12'; WarnBorder = '#A16207'; WarnFg = '#FDE68A'
    }
    Light = [ordered]@{
        BgWindow = '#F3F4F7'; BgSide = '#FFFFFF'; BgCard = '#FFFFFF'; BorderCard = '#E2E5EA'; BorderSoft = '#ECEEF2'
        BgControl = '#F1F3F6'; BorderControl = '#D3D8E0'; BorderInput = '#CDD2DA'
        Fg = '#111827'; FgSoft = '#4B5563'; FgMuted = '#5B6472'; FgFaint = '#8A93A2'
        Hover = '#EEF1F5'; Selected = '#E3EBFC'; Track = '#E5E7EB'; Chip = '#EEF1F5'; Thumb = '#C3C8D0'; CapIcon = '#374151'
        Accent = '#2F6FEB'; TextAmber = '#B45309'; TextRed = '#B91C1C'; TextBlue = '#1D4ED8'
        WarnBg = '#FEF3C7'; WarnBorder = '#F59E0B'; WarnFg = '#78350F'
    }
}
function Get-EffectiveTheme {
    $t = [string]$script:Config.Theme
    if ($t -eq 'Light') { return 'Light' }
    if ($t -eq 'Dark') { return 'Dark' }
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        if ($v -eq 1) { return 'Light' }
    } catch {}
    return 'Dark'
}
function Apply-Theme($target) {
    if (-not $target) { return }
    $pal = $script:Themes[(Get-EffectiveTheme)]
    foreach ($k in $pal.Keys) {
        $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k]))
        $b.Freeze()
        $target.Resources[$k] = $b
    }
}

# ===================================================================
#  Funciones compartidas (ventana y trabajos en segundo plano)
# ===================================================================
$script:InitScriptText = @'
function Get-CancelFile { Join-Path $env:TEMP 'RevixPC-cancel.flag' }

function Get-WingetPath {
    $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($wg) { return $wg.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    $found = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match 'DesktopAppInstaller' } | Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function ConvertFrom-WingetTable {
    param([string]$Text)
    $result = New-Object System.Collections.ArrayList
    if (-not $Text) { return ,$result }
    $lines = @($Text -split "`n" | ForEach-Object {
        $l = $_.TrimEnd("`r")
        $idx = $l.LastIndexOf("`r")
        if ($idx -ge 0) { $l = $l.Substring($idx + 1) }
        $l
    })
    $sep = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{10,}\s*$') { $sep = $i; break }
    }
    if ($sep -lt 1) { return ,$result }
    $header = $lines[$sep - 1]
    $starts = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
    if ($starts.Count -lt 4) { return ,$result }
    for ($j = $sep + 1; $j -lt $lines.Count; $j++) {
        $line = $lines[$j]
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line.Length -le $starts[2]) { break }
        if ($line -match '^\d+\s+(upgrades?|actualizaci|paquetes?|packages?)') { break }
        if ($line[$starts[1] - 1] -ne ' ') { break }
        $cols = @()
        for ($k = 0; $k -lt $starts.Count; $k++) {
            $s = $starts[$k]
            if ($k -lt $starts.Count - 1) { $e = $starts[$k + 1] } else { $e = $line.Length }
            if ($s -ge $line.Length) { $cols += ''; continue }
            $len = [Math]::Min($e, $line.Length) - $s
            $cols += $line.Substring($s, $len).Trim()
        }
        $id = $cols[1]
        if (-not $id -or $id -match '\s') { continue }
        $source = ''
        if ($cols.Count -gt 4) { $source = $cols[4] }
        [void]$result.Add([pscustomobject]@{ Name = $cols[0]; Id = $id; Version = $cols[2]; Available = $cols[3]; Source = $source })
    }
    return ,$result
}

function Get-CleanCategories {
    $sid = ''
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch {}
    $bins = @()
    foreach ($dr in [System.IO.DriveInfo]::GetDrives()) {
        if ($dr.DriveType -eq 'Fixed' -and $sid) { $bins += (Join-Path $dr.RootDirectory.FullName ('$Recycle.Bin\' + $sid)) }
    }
    $la = $env:LOCALAPPDATA
    @(
        [pscustomobject]@{ Key = 'UserTemp';   Name = 'Temporales del usuario';            Default = $true;  Paths = @($env:TEMP);                                         Note = 'Archivos que los programas dejan olvidados' }
        [pscustomobject]@{ Key = 'WinTemp';    Name = 'Temporales de Windows';             Default = $true;  Paths = @((Join-Path $env:WINDIR 'Temp'));                     Note = 'Carpeta Temp del sistema' }
        [pscustomobject]@{ Key = 'WUDownload'; Name = 'Descargas de Windows Update';       Default = $true;  Paths = @((Join-Path $env:WINDIR 'SoftwareDistribution\Download')); Note = 'Instaladores de actualizaciones que ya se aplicaron' }
        [pscustomobject]@{ Key = 'DeliveryOpt';Name = 'Caché de Optimización de entrega';  Default = $true;  Paths = @((Join-Path $env:WINDIR 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')); Note = 'Copias de actualizaciones compartidas' }
        [pscustomobject]@{ Key = 'WER';        Name = 'Informes de errores de Windows';    Default = $true;  Paths = @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $la 'CrashDumps')); Note = 'Reportes de cierres inesperados ya enviados' }
        [pscustomobject]@{ Key = 'Shader';     Name = 'Caché de sombreadores (juegos)';    Default = $false; Paths = @((Join-Path $la 'D3DSCache'), (Join-Path $la 'NVIDIA\DXCache'), (Join-Path $la 'NVIDIA\GLCache'), (Join-Path $la 'AMD\DxCache'), (Join-Path $la 'AMD\DxcCache')); Note = 'Los juegos la vuelven a crear; puede dar tirones la primera partida' }
        [pscustomobject]@{ Key = 'RecycleBin'; Name = 'Papelera de reciclaje';             Default = $false; Paths = $bins;                                                Note = 'Se borra definitivamente lo que hay en la papelera' }
        [pscustomobject]@{ Key = 'Components'; Name = 'Componentes viejos de Windows';     Default = $false; Paths = @();                                                  Note = 'Versiones antiguas de archivos del sistema. Tarda varios minutos' }
    )
}

function Get-FolderBytes([string[]]$Paths) {
    $total = 0.0
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $m = Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        if ($m.Sum) { $total += [double]$m.Sum }
    }
    return $total
}

function Clear-FolderContent([string]$p) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return }
    Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'RevixPC-*' } | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }
}
'@
$script:InitScript = [scriptblock]::Create($script:InitScriptText)
. $script:InitScript

# ===================================================================
#  Trabajos en segundo plano
# ===================================================================

# Programas con actualizacion (winget)
$script:JobWingetScan = {
    $out = New-Object System.Collections.ArrayList
    $done = $false
    try {
        if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            $pk = @(Get-WinGetPackage -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable })
            foreach ($p in $pk) {
                [void]$out.Add([pscustomobject]@{
                    Name = [string]$p.Name; Id = [string]$p.Id; Version = [string]$p.InstalledVersion
                    Available = [string]($p.AvailableVersions | Select-Object -First 1); Source = [string]$p.Source
                })
            }
            $done = $true
        }
    } catch { $out.Clear(); $done = $false }
    if (-not $done) {
        $wg = Get-WingetPath
        if (-not $wg) { throw 'WINGET_NO_ENCONTRADO' }
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
        $text = & $wg upgrade --include-unknown --accept-source-agreements 2>&1 | Out-String
        foreach ($r in (ConvertFrom-WingetTable $text)) { [void]$out.Add($r) }
    }
    $out
}

# Actualizar programas, uno por uno (con progreso y cancelar)
$script:JobWingetUpgrade = {
    param([string[]]$Ids)
    $wg = Get-WingetPath
    if (-not $wg) { throw 'WINGET_NO_ENCONTRADO' }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $cancel = Get-CancelFile
    foreach ($id in $Ids) {
        if (Test-Path $cancel) { [pscustomobject]@{ Kind = 'cancel' }; break }
        [pscustomobject]@{ Kind = 'start'; Key = $id }
        $o = & $wg upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        $code = $LASTEXITCODE
        $last = (@($o -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^[\-\\\|/ ]+$' -and $_ -notmatch '[▀-▟]' }) | Select-Object -Last 1)
        [pscustomobject]@{ Kind = 'done'; Key = $id; ExitCode = $code; Message = [string]$last }
    }
}

# Buscar en Windows Update (incluye drivers)
$script:JobWUScan = {
    $ErrorActionPreference = 'Stop'
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $res = $searcher.Search("IsInstalled=0 and IsHidden=0")
    foreach ($u in $res.Updates) {
        $kbs = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
        $isDriver = ($u.Type -eq 2)
        $hw = ''; $model = ''; $mfr = ''
        if ($isDriver) { try { $hw = [string]$u.DriverHardwareID; $model = [string]$u.DriverModel; $mfr = [string]$u.DriverManufacturer } catch {} }
        [pscustomobject]@{
            Title = [string]$u.Title; UpdateId = [string]$u.Identity.UpdateID; KB = $kbs
            Severity = [string]$u.MsrcSeverity; SizeMB = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1)
            IsDriver = $isDriver; DriverHardwareId = $hw; DriverModel = $model; DriverManufacturer = $mfr
        }
    }
}

# Instalar desde Windows Update, una por una
$script:JobWUInstall = {
    param([string[]]$UpdateIds)
    $ErrorActionPreference = 'Stop'
    $cancel = Get-CancelFile
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $res = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $list = @()
    foreach ($u in $res.Updates) { if ($UpdateIds -contains [string]$u.Identity.UpdateID) { $list += $u } }
    foreach ($u in $list) {
        if (Test-Path $cancel) { [pscustomobject]@{ Kind = 'cancel' }; break }
        $key = [string]$u.Identity.UpdateID
        [pscustomobject]@{ Kind = 'start'; Key = $key }
        try {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$coll.Add($u)
            $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
            $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
            $r = $inst.Install()
            $code = $r.GetUpdateResult(0).ResultCode
            $txt = switch ($code) { 2 { 'Instalada' } 3 { 'Instalada con errores' } 4 { 'Falló' } 5 { 'Cancelada' } default { "Código $code" } }
            [pscustomobject]@{ Kind = 'done'; Key = $key; Title = [string]$u.Title; Result = $txt; Ok = ($code -eq 2 -or $code -eq 3); Reboot = [bool]$r.RebootRequired }
        } catch {
            [pscustomobject]@{ Kind = 'done'; Key = $key; Title = [string]$u.Title; Result = ('Error: ' + $_.Exception.Message); Ok = $false; Reboot = $false }
        }
    }
    foreach ($id in $UpdateIds) {
        if (-not ($list | Where-Object { [string]$_.Identity.UpdateID -eq $id })) {
            [pscustomobject]@{ Kind = 'done'; Key = $id; Title = ''; Result = 'Ya no estaba disponible'; Ok = $false; Reboot = $false }
        }
    }
}

# Dispositivos y sus drivers
$script:JobDeviceScan = {
    $ErrorActionPreference = 'Stop'
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName } | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.DeviceName; DeviceClass = [string]$_.DeviceClass; Manufacturer = [string]$_.Manufacturer
            Provider = [string]$_.DriverProviderName; Version = [string]$_.DriverVersion; Date = $_.DriverDate
            HardwareId = [string]$_.HardWareID
        }
    }
}

# Salud: seguridad, BIOS, discos y unidades (objetos planos con Type)
$script:JobHealth = {
    $info = [ordered]@{ Type = 'Info' }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $info.OS = "$($os.Caption) ($($os.Version))"; $info.LastBoot = $os.LastBootUpTime
    } catch {}
    try {
        $b = Get-CimInstance Win32_BIOS; $bb = Get-CimInstance Win32_BaseBoard
        $info.BiosVersion = [string]$b.SMBIOSBIOSVersion; $info.BiosDate = $b.ReleaseDate; $info.BiosMfr = [string]$b.Manufacturer
        $info.BoardMfr = [string]$bb.Manufacturer; $info.BoardProduct = [string]$bb.Product
    } catch {}
    try {
        $s = New-Object -ComObject Microsoft.Update.Session; $h = $s.CreateUpdateSearcher()
        $n = $h.GetTotalHistoryCount()
        if ($n -gt 0) {
            foreach ($e in $h.QueryHistory(0, [Math]::Min($n, 50))) {
                if ($e.ResultCode -eq 2 -and $e.Title -notmatch 'inteligencia de seguridad|Security Intelligence|antimalware') {
                    $info.LastWU = $e.Date; $info.LastWUTitle = [string]$e.Title; break
                }
            }
        }
    } catch {}
    [pscustomobject]$info

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        [pscustomobject]@{ Type = 'Defender'; On = [bool]$mp.AntivirusEnabled; RealTime = [bool]$mp.RealTimeProtectionEnabled; SigDate = $mp.AntivirusSignatureLastUpdated }
    } catch {}
    try {
        Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Type = 'AV'; Name = [string]$_.displayName; State = [int]$_.productState }
        }
    } catch {}
    try {
        Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Type = 'FW'; Name = [string]$_.Name; Enabled = ([string]$_.Enabled -eq 'True') }
        }
    } catch {}
    try {
        foreach ($d in Get-PhysicalDisk -ErrorAction Stop) {
            $rc = $null
            try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
            $o = [ordered]@{ Type = 'Disk'; Name = [string]$d.FriendlyName; Media = [string]$d.MediaType; Bus = [string]$d.BusType
                             Health = [string]$d.HealthStatus; SizeGB = [math]::Round([double]$d.Size / 1GB) }
            if ($rc) { $o.Temp = $rc.Temperature; $o.Wear = $rc.Wear; $o.Hours = $rc.PowerOnHours }
            [pscustomobject]$o
        }
    } catch {}
    foreach ($dr in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($dr.DriveType -eq 'Fixed' -and $dr.IsReady -and $dr.TotalSize -gt 0) {
                [pscustomobject]@{ Type = 'Volume'; Letter = $dr.Name.Substring(0, 2); Label = [string]$dr.VolumeLabel
                                   SizeGB = [math]::Round($dr.TotalSize / 1GB, 1); FreeGB = [math]::Round($dr.AvailableFreeSpace / 1GB, 1) }
            }
        } catch {}
    }

    # Estabilidad: apagados inesperados, pantallazos azules, errores de hardware y de disco (30 dias)
    $since = (Get-Date).AddDays(-30)
    $queries = @(
        @{ Kind = 'Power';    F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } }
        @{ Kind = 'PowerOld'; F = @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; StartTime = $since } }
        @{ Kind = 'BSOD';     F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } }
        @{ Kind = 'WHEA';     F = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = 2, 3; StartTime = $since } }
        @{ Kind = 'Disk';     F = @{ LogName = 'System'; ProviderName = 'disk'; Id = 7, 51, 153; StartTime = $since } }
    )
    foreach ($q in $queries) {
        try {
            foreach ($e in Get-WinEvent -FilterHashtable $q.F -MaxEvents 100 -ErrorAction Stop) {
                [pscustomobject]@{ Type = 'Event'; Kind = $q.Kind; Date = $e.TimeCreated }
            }
        } catch {}
    }
}

# Limpieza: calcular espacio
$script:JobCleanScan = {
    foreach ($c in Get-CleanCategories) {
        if ($c.Key -eq 'Components') { [pscustomobject]@{ Key = $c.Key; Bytes = -1 }; continue }
        [pscustomobject]@{ Key = $c.Key; Bytes = (Get-FolderBytes $c.Paths) }
    }
}

# Limpieza: borrar
$script:JobClean = {
    param([string[]]$Keys)
    $cancel = Get-CancelFile
    $sysDrive = New-Object System.IO.DriveInfo($env:SystemDrive)
    foreach ($c in (Get-CleanCategories | Where-Object { $Keys -contains $_.Key })) {
        if (Test-Path $cancel) { [pscustomobject]@{ Kind = 'cancel' }; break }
        [pscustomobject]@{ Kind = 'start'; Key = $c.Key }
        $freeBefore = $sysDrive.AvailableFreeSpace
        $before = Get-FolderBytes $c.Paths
        try {
            switch ($c.Key) {
                'RecycleBin' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
                'Components' { & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null }
                'WUDownload' {
                    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
                    foreach ($p in $c.Paths) { Clear-FolderContent $p }
                    Start-Service bits, wuauserv -ErrorAction SilentlyContinue
                }
                'DeliveryOpt' {
                    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { foreach ($p in $c.Paths) { Clear-FolderContent $p } }
                }
                default { foreach ($p in $c.Paths) { Clear-FolderContent $p } }
            }
            $after = Get-FolderBytes $c.Paths
            $freed = [Math]::Max(0, $before - $after)
            if ($c.Key -eq 'Components') { $sysDrive = New-Object System.IO.DriveInfo($env:SystemDrive); $freed = [Math]::Max(0, $sysDrive.AvailableFreeSpace - $freeBefore) }
            [pscustomobject]@{ Kind = 'done'; Key = $c.Key; Freed = [double]$freed; Ok = $true; Message = '' }
        } catch {
            [pscustomobject]@{ Kind = 'done'; Key = $c.Key; Freed = 0; Ok = $false; Message = $_.Exception.Message }
        }
    }
}

# Punto de restauracion: no enciende la protección del sistema sin permiso y deja el ajuste de Windows como estaba
$script:JobRestorePoint = {
    param([string]$Desc, [bool]$AllowEnable)
    $ErrorActionPreference = 'Stop'
    $enabled = $false
    try {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -ErrorAction Stop).'{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
        if (@($v | Where-Object { $_ }).Count -gt 0) { $enabled = $true }
    } catch {}
    if (-not $enabled -and -not $AllowEnable) { return [pscustomobject]@{ Ok = $false; NeedEnable = $true; Enabled = $false } }
    $turnedOn = $false
    if (-not $enabled) { Enable-ComputerRestore -Drive "$env:SystemDrive\"; $turnedOn = $true }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prev = $null; $had = $false
    try { $prev = (Get-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop).SystemRestorePointCreationFrequency; $had = $true } catch {}
    try {
        New-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description $Desc -RestorePointType 'MODIFY_SETTINGS'
    } finally {
        try {
            if ($had) { New-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -Value ([int]$prev) -PropertyType DWord -Force | Out-Null }
            else { Remove-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
        } catch {}
    }
    [pscustomobject]@{ Ok = $true; NeedEnable = $false; Enabled = $turnedOn }
}

# Respaldo y restauracion de drivers
$script:JobDriverBackup = {
    param([string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $r = @(Export-WindowsDriver -Online -Destination $Dest -ErrorAction Stop)
    [pscustomobject]@{ Count = $r.Count; Dest = $Dest }
}
$script:JobDriverRestore = {
    param([string]$Folder)
    $o = & pnputil.exe /add-driver (Join-Path $Folder '*.inf') /subdirs /install 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $o }
}

# Microsoft Store y Defender
$script:JobStore = {
    Get-CimInstance -Namespace 'Root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
        Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
    'OK'
}
$script:JobDefender = {
    Update-MpSignature -ErrorAction Stop
    'OK'
}

# Ultimo driver de NVIDIA para tu tarjeta (servicio de busqueda de NVIDIA)
$script:JobNvidia = {
    param([string]$GpuName, [string]$Pfid)
    $ErrorActionPreference = 'Stop'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $name = ($GpuName -replace '^NVIDIA\s+', '').Trim()
    if (-not $Pfid) {
        $raw = (Invoke-WebRequest -UseBasicParsing -Uri 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3' -TimeoutSec 30).Content
        $xml = [xml]$raw
        $match = @($xml.LookupValueSearch.LookupValues.LookupValue) | Where-Object { ([string]$_.Name).Trim() -eq $name } | Select-Object -First 1
        if (-not $match) { throw "No se encontró '$name' en la lista de NVIDIA" }
        $Pfid = [string]$match.Value
    }
    $url = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&pfid=$Pfid&osID=57&languageCode=1033&dch=1&numberOfResults=1"
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 30
    if ($r -is [string]) { $r = $r | ConvertFrom-Json }
    $info = @($r.IDS)[0].downloadInfo
    if (-not $info -or -not $info.Version) { throw 'NVIDIA no devolvió la versión' }
    $details = [string]$info.DetailsURL
    if (-not $details) { $details = 'https://www.nvidia.com/es-la/drivers/' }
    [pscustomobject]@{ Pfid = $Pfid; Version = [string]$info.Version; Url = [uri]::UnescapeDataString($details); Date = [string]$info.ReleaseDateTime }
}

# Programas que arrancan con Windows + cuanto tarda el arranque
$script:JobStartup = {
    function Get-Exe([string]$cmd) {
        $c = [Environment]::ExpandEnvironmentVariables(([string]$cmd).Trim())
        if ($c.StartsWith('"')) { $e = $c.IndexOf('"', 1); if ($e -gt 0) { return $c.Substring(1, $e - 1) } }
        $m = [regex]::Match($c, '^(.+?\.(exe|cmd|bat|lnk))', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
        return ($c -split ' ')[0]
    }
    function Get-Pub([string]$f) {
        try { if ($f -and (Test-Path -LiteralPath $f)) { return [string](Get-Item -LiteralPath $f).VersionInfo.CompanyName } } catch {}
        return ''
    }
    function Test-Approved([string]$appr, [string]$name) {
        try {
            $v = (Get-ItemProperty -LiteralPath $appr -Name $name -ErrorAction Stop).$name
            if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
        } catch {}
        return $true
    }
    $base = 'Software\Microsoft\Windows\CurrentVersion'
    $sources = @(
        @{ Reg = "HKCU:\$base\Run"; Appr = "HKCU:\$base\Explorer\StartupApproved\Run"; Loc = 'Registro (tu usuario)' }
        @{ Reg = "HKLM:\$base\Run"; Appr = "HKLM:\$base\Explorer\StartupApproved\Run"; Loc = 'Registro (todos)' }
        @{ Reg = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Appr = "HKLM:\$base\Explorer\StartupApproved\Run32"; Loc = 'Registro (todos, 32 bits)' }
    )
    foreach ($s in $sources) {
        if (-not (Test-Path $s.Reg)) { continue }
        $key = Get-Item -LiteralPath $s.Reg
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            $cmd = [string]$key.GetValue($n)
            $exe = Get-Exe $cmd
            [pscustomobject]@{ Type = 'Item'; Name = $n; Command = $cmd; Location = $s.Loc; ValueName = $n; ApprovedPath = $s.Appr
                               FilePath = $exe; Enabled = (Test-Approved $s.Appr $n); Publisher = (Get-Pub $exe) }
        }
    }
    $folders = @(
        @{ Dir = [Environment]::GetFolderPath('Startup'); Appr = "HKCU:\$base\Explorer\StartupApproved\StartupFolder"; Loc = 'Carpeta Inicio (tu usuario)' }
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "HKLM:\$base\Explorer\StartupApproved\StartupFolder"; Loc = 'Carpeta Inicio (todos)' }
    )
    foreach ($f in $folders) {
        if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $f.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
            $target = $file.FullName
            if ($file.Extension -eq '.lnk') {
                try { $t = (New-Object -ComObject WScript.Shell).CreateShortcut($file.FullName).TargetPath; if ($t) { $target = $t } } catch {}
            }
            [pscustomobject]@{ Type = 'Item'; Name = $file.BaseName; Command = $target; Location = $f.Loc; ValueName = $file.Name; ApprovedPath = $f.Appr
                               FilePath = $target; Enabled = (Test-Approved $f.Appr $file.Name); Publisher = (Get-Pub $target) }
        }
    }
    try {
        $bootDone = $false
        foreach ($e in Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -MaxEvents 400 -ErrorAction Stop) {
            if ($e.Id -ne 100 -and $e.Id -ne 101) { continue }
            $x = [xml]$e.ToXml(); $d = @{}
            foreach ($n in @($x.Event.EventData.Data)) { $d[[string]$n.Name] = [string]$n.'#text' }
            if ($e.Id -eq 100 -and -not $bootDone) {
                $bootDone = $true
                [pscustomobject]@{ Type = 'Boot'; Ms = [double]$d['BootTime']; Date = $e.TimeCreated }
            } elseif ($e.Id -eq 101) {
                $file = $d['FileName']; if (-not $file) { $file = $d['Name'] }
                [pscustomobject]@{ Type = 'Slow'; File = [string]$file; Ms = [double]$d['TotalTime']; Date = $e.TimeCreated }
            }
        }
    } catch {}
}

# Programas instalados (para desinstalar)
$script:JobApps = {
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $seen = @{}
    foreach ($p in $paths) {
        foreach ($k in Get-ItemProperty -Path $p -ErrorAction SilentlyContinue) {
            $n = [string]$k.DisplayName
            if (-not $n) { continue }
            if ($k.SystemComponent -eq 1 -or $k.ParentKeyName -or ([string]$k.ReleaseType) -match 'Update|Hotfix') { continue }
            $u = [string]$k.UninstallString
            if (-not $u) { continue }
            $key = "$n|$($k.DisplayVersion)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $date = ''; $d = [string]$k.InstallDate
            if ($d -match '^\d{8}$') { $date = $d.Substring(6, 2) + '/' + $d.Substring(4, 2) + '/' + $d.Substring(0, 4) }
            [pscustomobject]@{ Name = $n.Trim(); Publisher = [string]$k.Publisher; Version = [string]$k.DisplayVersion
                               SizeMB = [math]::Round([double]$k.EstimatedSize / 1024, 1); InstallDate = $date; Uninstall = $u }
        }
    }
}

# Ficha de la PC + bateria
$script:JobPcInfo = {
    function Row([string]$s, [string]$i, $v, [string]$n = '') { [pscustomobject]@{ Section = $s; Item = $i; Value = [string]$v; Note = $n } }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Row 'Windows' 'Edición' $os.Caption
        $disp = [string]$cv.DisplayVersion; if (-not $disp) { $disp = [string]$cv.ReleaseId }
        Row 'Windows' 'Versión' ("$disp (compilación $($cv.CurrentBuild).$($cv.UBR))")
        Row 'Windows' 'Instalado el' ($os.InstallDate.ToString('dd/MM/yyyy'))
    } catch {}
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        Row 'Procesador' 'Modelo' ($cpu.Name.Trim())
        Row 'Procesador' 'Núcleos / hilos' ("$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)")
        Row 'Procesador' 'Velocidad base' ('{0:N2} GHz' -f ($cpu.MaxClockSpeed / 1000))
    } catch {}
    try {
        $mods = @(Get-CimInstance Win32_PhysicalMemory)
        $total = ($mods | Measure-Object -Property Capacity -Sum).Sum
        $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
        Row 'Memoria RAM' 'Total' ('{0:N0} GB' -f ($total / 1GB))
        Row 'Memoria RAM' 'Módulos' ("$($mods.Count) de $slots ranuras")
        foreach ($m in $mods) {
            $rated = [int]$m.Speed; $conf = [int]$m.ConfiguredClockSpeed
            $note = ''
            if ($rated -gt 0 -and $conf -gt 0 -and $conf -lt $rated) { $note = "Trabaja a $conf de $rated MT/s: revisa XMP en la BIOS" }
            $pn = ([string]$m.PartNumber).Trim()
            Row 'Memoria RAM' ([string]$m.DeviceLocator) ('{0:N0} GB · {1} MT/s · {2} {3}' -f ($m.Capacity / 1GB), $conf, $m.Manufacturer, $pn) $note
        }
    } catch {}
    try {
        $bb = Get-CimInstance Win32_BaseBoard; $b = Get-CimInstance Win32_BIOS
        Row 'Placa madre' 'Modelo' ("$($bb.Manufacturer) $($bb.Product)")
        Row 'Placa madre' 'BIOS' ("$($b.SMBIOSBIOSVersion) ($($b.ReleaseDate.ToString('dd/MM/yyyy')))")
    } catch {}
    try {
        $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($v in Get-CimInstance Win32_VideoController) {
            $vram = ''
            foreach ($k in Get-ChildItem $cls -ErrorAction SilentlyContinue) {
                try {
                    $pp = Get-ItemProperty $k.PSPath -ErrorAction Stop
                    if ($pp.DriverDesc -eq $v.Name -and $pp.'HardwareInformation.qwMemorySize') { $vram = '{0:N0} GB' -f ([double]$pp.'HardwareInformation.qwMemorySize' / 1GB) }
                } catch {}
            }
            $txt = [string]$v.Name; if ($vram) { $txt += " · $vram" }
            Row 'Video' 'Tarjeta' $txt ("Driver " + $v.DriverVersion)
            if ($v.CurrentHorizontalResolution) { Row 'Video' 'Pantalla' ("$($v.CurrentHorizontalResolution) x $($v.CurrentVerticalResolution) a $($v.CurrentRefreshRate) Hz") }
        }
    } catch {}
    try {
        foreach ($d in Get-PhysicalDisk -ErrorAction Stop) {
            $media = [string]$d.MediaType; if ($media -eq 'Unspecified') { $media = '' }
            Row 'Discos' ([string]$d.FriendlyName) (("$media $($d.BusType)").Trim() + (' · {0:N0} GB' -f ($d.Size / 1GB)))
        }
    } catch {}
    try {
        foreach ($a in Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) {
            Row 'Red' ([string]$a.Name) ("$($a.InterfaceDescription) · $($a.LinkSpeed)")
        }
    } catch {}
    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        if ($bat.Count -gt 0) {
            $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
            $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
            $cycles = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount
            Row 'Batería' 'Carga actual' ("$($bat[0].EstimatedChargeRemaining) %")
            if ($design -and $full) {
                $pct = [math]::Round(100 * $full / $design)
                $note = ''; if ($pct -lt 60) { $note = 'Batería gastada: conviene cambiarla' } elseif ($pct -lt 80) { $note = 'Desgaste normal por uso' }
                Row 'Batería' 'Salud' ("$pct % ({0:N1} de {1:N1} Wh)" -f ($full / 1000), ($design / 1000)) $note
            }
            if ($cycles) { Row 'Batería' 'Ciclos de carga' $cycles }
        }
    } catch {}
}

# Temperatura de los discos
$script:JobDiskTemps = {
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $t = $null
        try { $t = ($d | Get-StorageReliabilityCounter -ErrorAction Stop).Temperature } catch {}
        if ($t) { [pscustomobject]@{ Name = [string]$d.FriendlyName; Temp = [int]$t } }
    }
}

# Volver a una version anterior (winget)
$script:JobRollback = {
    param([string[]]$Items)
    $wg = Get-WingetPath
    if (-not $wg) { throw 'WINGET_NO_ENCONTRADO' }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $cancel = Get-CancelFile
    foreach ($it in $Items) {
        if (Test-Path $cancel) { [pscustomobject]@{ Kind = 'cancel' }; break }
        $parts = $it -split '\|', 2
        $id = $parts[0]; $ver = $parts[1]
        [pscustomobject]@{ Kind = 'start'; Key = $id }
        $o = & $wg install --id $id --exact --version $ver --force --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
        $code = $LASTEXITCODE
        $last = (@($o -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^[\-\\\|/ ]+$' -and $_ -notmatch '[▀-▟]' }) | Select-Object -Last 1)
        [pscustomobject]@{ Kind = 'done'; Key = $id; ExitCode = $code; Message = [string]$last }
    }
}

# Nueva version de Revix PC: ultima release publicada en GitHub (las Pre-release no cuentan)
$script:JobCheckAppUpdate = {
    param([string]$Repo)
    $ErrorActionPreference = 'Stop'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $h = @{ 'User-Agent' = 'RevixPC'; 'Accept' = 'application/vnd.github+json' }
    try { $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $h -TimeoutSec 20 }
    catch {
        if ($_.Exception.Message -match '404') { throw 'Todavía no hay versiones publicadas en GitHub.' }
        throw "No se pudo conectar con GitHub: $($_.Exception.Message)"
    }
    $asset = @($r.assets) | Where-Object { [string]$_.name -match '^RevixPC.*\.zip$' } | Select-Object -First 1
    $digest = ''
    if ($asset -and $asset.PSObject.Properties['digest']) { $digest = [string]$asset.digest }
    $zip = ''; if ($asset) { $zip = [string]$asset.browser_download_url }
    [pscustomobject]@{ Version = ([string]$r.tag_name).TrimStart([char[]]'vV'); Zip = $zip; Notes = [string]$r.body; Digest = $digest; Page = [string]$r.html_url }
}
$script:JobDownload = {
    param([string]$Url, [string]$Dest, [string]$Digest, [string]$Repo)
    $ErrorActionPreference = 'Stop'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    # Solo se descarga desde las releases oficiales del repositorio
    $allowed = "https://github.com/$Repo/releases/download/"
    if (-not $Url.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw "Enlace de descarga no permitido: $Url" }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest -Headers @{ 'User-Agent' = 'RevixPC' } -TimeoutSec 180
    } catch { throw "No se pudo descargar: $($_.Exception.Message)" }
    if (-not (Test-Path -LiteralPath $Dest) -or (Get-Item -LiteralPath $Dest).Length -lt 1024) { throw 'La descarga llegó vacía o incompleta.' }
    # Comprobar que el archivo es exactamente el publicado (huella SHA-256 que da GitHub)
    if ($Digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $want = $matches[1]
        $got = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash
        if ($got -ne $want) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue; throw 'El archivo descargado no coincide con el publicado (huella SHA-256 distinta). No se instaló nada.' }
    }
    $Dest
}

# ===================================================================
#  Logica: clasificar actualizaciones, dispositivos y salud
# ===================================================================
$script:Links = @{
    NVIDIA   = 'https://www.nvidia.com/es-la/drivers/'
    AMD      = 'https://www.amd.com/es/support/download/drivers.html'
    Intel    = 'https://www.intel.la/content/www/xl/es/support/detect.html'
    Razer    = 'https://mysupport.razer.com/'
    Logitech = 'https://support.logi.com/'
    HyperX   = 'https://hyperx.com/'
}
# Colores sólidos para las pastillas de estado (texto blanco encima, se leen en tema claro y oscuro)
$script:C = @{ Green = '#15803D'; Amber = '#B45309'; Red = '#DC2626'; Blue = '#2563EB'; Gray = '#64748B'; Purple = '#7C3AED' }

function Get-UpdateKind($u) {
    if ($u.IsDriver) { return 'Driver' }
    if ($u.Severity) { return 'Seguridad' }
    $t = [string]$u.Title
    if ($t -match 'acumulativa|Cumulative') { return 'Acumulativa' }
    if ($t -match 'Defender|inteligencia de seguridad|Security Intelligence|antimalware') { return 'Defender' }
    if ($t -match '\.NET') { return '.NET' }
    if ($t -match 'Office|Microsoft 365') { return 'Office' }
    return 'Otra'
}

function Get-SeverityText([string]$s) {
    switch ($s) {
        'Critical'  { return 'Crítica' }
        'Important' { return 'Importante' }
        'Moderate'  { return 'Moderada' }
        'Low'       { return 'Baja' }
        default     { return $s }
    }
}

function Format-Bytes([double]$b) {
    if ($b -lt 0) { return '—' }
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    if ($b -gt 0)   { return ('{0:N0} KB' -f ($b / 1KB)) }
    return '0 MB'
}

function Get-WingetCodeText([int]$code) {
    $hex = '0x{0:X8}' -f $code
    if ($hex -eq '0x8A15002B') { return 'No hay actualización aplicable para esta instalación' }
    return "Código $hex"
}

# 32.0.15.6636 (Windows) -> 566.36 (NVIDIA)
function Convert-NvidiaVersion([string]$v) {
    $digits = ($v -replace '[^\d]', '')
    if ($digits.Length -lt 5) { return '' }
    $last = $digits.Substring($digits.Length - 5)
    return $last.Substring(0, 3) + '.' + $last.Substring(3)
}
function Compare-NvidiaVersion([string]$a, [string]$b) {
    try { return ([decimal]::Parse($a, [Globalization.CultureInfo]::InvariantCulture)).CompareTo([decimal]::Parse($b, [Globalization.CultureInfo]::InvariantCulture)) } catch { return 0 }
}

# Nota de 0 a 100 para la pantalla Resumen
function Get-HealthScore([int]$sec, [int]$wuOther, [int]$prog, [int]$drv, [int]$lvl2, [int]$lvl1) {
    $s = 100
    $s -= [Math]::Min(24, 8 * $sec)
    $s -= [Math]::Min(12, 3 * $wuOther)
    $s -= [Math]::Min(12, 2 * $prog)
    $s -= [Math]::Min(10, 5 * $drv)
    $s -= [Math]::Min(30, 10 * $lvl2)
    $s -= [Math]::Min(16, 4 * $lvl1)
    return [int][Math]::Max(0, [Math]::Min(100, $s))
}
function Get-ScoreLabel([int]$score) {
    if ($score -ge 85) { return @('Tu PC está en buen estado', '#22C55E') }
    if ($score -ge 60) { return @('Tu PC necesita algunas actualizaciones', '#F59E0B') }
    return @('Tu PC necesita atención', '#EF4444')
}

function Get-DeviceVendor($d) {
    $hw = ([string]$d.HardwareId).ToUpper()
    $name = [string]$d.Name
    if ($hw -match 'VID_1532' -or $name -match 'Razer') { return 'Razer' }
    if ($hw -match 'VID_046D' -or $name -match 'Logitech') { return 'Logitech' }
    if ($hw -match 'VID_0951' -or $name -match 'HyperX') { return 'HyperX' }
    return ''
}

function ConvertTo-DeviceItems($rawDevices, $wuUpdates) {
    $driverUpdates = @($wuUpdates | Where-Object { $_.IsDriver })
    $list = New-Object 'System.Collections.Generic.List[RevixPC.DeviceItem]'
    $seen = @{}
    $now = Get-Date
    $sorted = @($rawDevices | Sort-Object @{ Expression = { if ([string]$_.Name -match 'Razer|Logitech|HyperX') { 0 } else { 1 } } })

    foreach ($d in $sorted) {
        $vendor = Get-DeviceVendor $d
        $cls = ([string]$d.DeviceClass).ToUpper()
        $hwKey = ([string]$d.HardwareId).ToUpper()
        if ($vendor) {
            $usbPid = ''
            if ($hwKey -match 'PID_([0-9A-F]{4})') { $usbPid = $matches[1] }
            $key = "$vendor|$usbPid|$cls"
            if ($usbPid) { $key = "$vendor|$usbPid" }
        } else { $key = "$($d.Name)|$($d.Version)" }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $it = New-Object RevixPC.DeviceItem
        $it.Name = [string]$d.Name
        if ($vendor -and $it.Name -notmatch $vendor) { $it.Name = "$vendor - " + $it.Name }
        $it.DeviceClass = [string]$d.DeviceClass
        $it.Manufacturer = [string]$d.Manufacturer
        $it.Version = [string]$d.Version
        $date = $null
        if ($d.Date) { try { $date = [datetime]$d.Date } catch { $date = $null } }
        if ($date) { $it.Date = $date.ToString('dd/MM/yyyy') } else { $it.Date = '' }

        $hw = $hwKey
        $match = $driverUpdates | Where-Object {
            $uhw = ([string]$_.DriverHardwareId).ToUpper()
            ($uhw -and $hw -and ($hw -eq $uhw -or $hw.StartsWith($uhw))) -or ($_.DriverModel -and $_.DriverModel -eq $d.Name)
        } | Select-Object -First 1

        $isMs = ([string]$d.Provider) -match '^Microsoft'
        $mfr  = [string]$d.Manufacturer
        $status = 'Sin actualizaciones'; $color = $script:C.Green; $note = ''; $link = ''; $action = ''; $prio = 2; $generic = $false

        if ($match) {
            $status = 'Hay actualización'; $color = $script:C.Amber; $prio = 0
            $note = 'Instálala desde la pestaña Windows Update'
        }
        elseif ($cls -eq 'DISPLAY' -and $mfr -match 'NVIDIA') {
            $inst = Convert-NvidiaVersion $d.Version
            $nv = $script:NvidiaInfo
            if ($nv -and $nv.Latest -and $inst -and (Compare-NvidiaVersion $nv.Latest $inst) -gt 0) {
                $status = "Driver nuevo: $($nv.Latest)"; $color = $script:C.Amber; $prio = 0
                $note = "Tienes la $inst. La última de NVIDIA es la $($nv.Latest)"; $link = $nv.Url; $action = 'Descargar'
            } elseif ($nv -and $nv.Latest -and $inst) {
                $status = 'Al día'; $color = $script:C.Green; $prio = 2
                $note = "Versión $inst (la más reciente)"
            } else {
                $status = 'Revisar en la web'; $color = $script:C.Blue; $prio = 1
                $note = 'Windows Update suele traer versiones antiguas'
                if ($inst) { $note = "Tienes la $inst. No se pudo consultar a NVIDIA" }
                $link = $script:Links.NVIDIA; $action = 'Abrir NVIDIA'
            }
        }
        elseif ($cls -eq 'DISPLAY' -and $mfr -match 'AMD|Advanced Micro') {
            $status = 'Revisar en la web'; $color = $script:C.Blue; $prio = 1
            $note = 'Windows Update suele traer versiones antiguas'; $link = $script:Links.AMD; $action = 'Abrir AMD'
        }
        elseif ($cls -eq 'DISPLAY' -and $mfr -match 'Intel') {
            $status = 'Revisar en la web'; $color = $script:C.Blue; $prio = 1
            $note = 'Asistente de drivers de Intel'; $link = $script:Links.Intel; $action = 'Abrir Intel'
        }
        elseif ($vendor -eq 'Razer') {
            $status = 'Firmware opcional'; $color = $script:C.Blue; $prio = 1
            $link = $script:Links.Razer; $note = 'Busca el actualizador de firmware de tu modelo. Actualiza solo si tienes un problema.'
            $action = 'Abrir Razer'
        }
        elseif ($vendor -eq 'Logitech') {
            $status = 'Firmware opcional'; $color = $script:C.Blue; $prio = 1
            $note = 'Se actualiza con el software oficial de Logitech'; $link = $script:Links.Logitech; $action = 'Abrir Logitech'
        }
        elseif ($vendor -eq 'HyperX') {
            $status = 'Firmware opcional'; $color = $script:C.Blue; $prio = 1
            $note = 'Se actualiza con el software oficial de HyperX'; $link = $script:Links.HyperX; $action = 'Abrir HyperX'
        }
        elseif ($isMs) {
            $status = 'Genérico de Windows'; $color = $script:C.Gray; $prio = 3; $generic = $true
            $note = 'Viene con Windows, no necesita nada'
        }
        elseif ($date -and $date.Year -ge 2010 -and $date -lt $now.AddYears(-3)) {
            $status = 'Driver antiguo'; $color = $script:C.Purple; $prio = 2
            $note = 'Solo revísalo si el dispositivo da problemas'
        }

        $it.StatusText = $status; $it.StatusColor = $color; $it.Note = $note
        $it.Link = $link; $it.ActionText = $action; $it.HasLink = [bool]$link
        $it.Priority = $prio; $it.IsGeneric = $generic
        $list.Add($it)
    }
    return ,@($list | Sort-Object Priority, Name)
}

function New-HealthRow([string]$section, [string]$item, [string]$value, [string]$status, [string]$color, [int]$level, [string]$link = '', [string]$action = '') {
    $r = New-Object RevixPC.HealthRow
    $r.Section = $section; $r.Item = $item; $r.Value = $value; $r.StatusText = $status; $r.StatusColor = $color
    $r.Level = $level; $r.Link = $link; $r.ActionText = $action; $r.HasLink = [bool]$link
    return $r
}

function Get-DaysAgoText([datetime]$d) {
    $days = [int]((Get-Date) - $d).TotalDays
    if ($days -le 0) { return 'hoy' }
    if ($days -eq 1) { return 'ayer' }
    return "hace $days días"
}

# Level: 0 = bien, 1 = aviso, 2 = problema
function ConvertTo-HealthRows($out) {
    $rows = New-Object 'System.Collections.Generic.List[RevixPC.HealthRow]'
    $C = $script:C
    $now = Get-Date
    $info = $out | Where-Object { $_.Type -eq 'Info' } | Select-Object -First 1
    $def  = $out | Where-Object { $_.Type -eq 'Defender' } | Select-Object -First 1
    $avs  = @($out | Where-Object { $_.Type -eq 'AV' })
    $fws  = @($out | Where-Object { $_.Type -eq 'FW' })

    # --- Seguridad ---
    $activeThird = $false
    foreach ($a in $avs) {
        $on = ((($a.State -shr 8) -band 0xFF) -in 0x10, 0x11)
        $isMs = $a.Name -match 'Defender'
        if ($on -and -not $isMs) { $activeThird = $true }
        if ($isMs -and -not $on -and @($avs | Where-Object { $_.Name -notmatch 'Defender' }).Count -gt 0) {
            $rows.Add((New-HealthRow 'Seguridad' "Antivirus: $($a.Name)" 'En espera (otro antivirus está activo)' 'Normal' $C.Gray 0)); continue
        }
        if ($on) { $rows.Add((New-HealthRow 'Seguridad' "Antivirus: $($a.Name)" 'Protegiendo' 'Activo' $C.Green 0)) }
        else     { $rows.Add((New-HealthRow 'Seguridad' "Antivirus: $($a.Name)" 'No está protegiendo' 'Apagado' $C.Red 2)) }
    }
    if ($def -and -not $activeThird) {
        if ($avs.Count -eq 0) {
            if ($def.On) { $rows.Add((New-HealthRow 'Seguridad' 'Antivirus: Microsoft Defender' 'Protegiendo' 'Activo' $C.Green 0)) }
            else { $rows.Add((New-HealthRow 'Seguridad' 'Antivirus: Microsoft Defender' 'No está protegiendo' 'Apagado' $C.Red 2)) }
        }
        if ($def.RealTime) { $rows.Add((New-HealthRow 'Seguridad' 'Protección en tiempo real' 'Encendida' 'Activo' $C.Green 0)) }
        else { $rows.Add((New-HealthRow 'Seguridad' 'Protección en tiempo real' 'Apagada' 'Revisar' $C.Red 2)) }
        if ($def.SigDate) {
            $sd = [datetime]$def.SigDate; $age = ($now - $sd).TotalDays
            $txt = $sd.ToString('dd/MM/yyyy HH:mm') + ' (' + (Get-DaysAgoText $sd) + ')'
            if ($age -le 3) { $rows.Add((New-HealthRow 'Seguridad' 'Firmas del antivirus' $txt 'Al día' $C.Green 0)) }
            elseif ($age -le 7) { $rows.Add((New-HealthRow 'Seguridad' 'Firmas del antivirus' $txt 'Algo antiguas' $C.Amber 1)) }
            else { $rows.Add((New-HealthRow 'Seguridad' 'Firmas del antivirus' $txt 'Desactualizadas' $C.Red 2)) }
        }
    }
    $fwNames = @{ Domain = 'Dominio'; Private = 'Privada'; Public = 'Pública' }
    foreach ($f in $fws) {
        $n = $fwNames[[string]$f.Name]; if (-not $n) { $n = $f.Name }
        if ($f.Enabled) { $rows.Add((New-HealthRow 'Seguridad' "Firewall (red $n)" 'Encendido' 'Activo' $C.Green 0)) }
        else { $rows.Add((New-HealthRow 'Seguridad' "Firewall (red $n)" 'Apagado' 'Revisar' $C.Amber 1)) }
    }

    # --- Sistema ---
    if ($info) {
        if ($info.OS) { $rows.Add((New-HealthRow 'Sistema' 'Windows' $info.OS '' $C.Gray 0)) }
        if ($info.LastWU) {
            $lw = [datetime]$info.LastWU
            $txt = $lw.ToString('dd/MM/yyyy') + ' (' + (Get-DaysAgoText $lw) + ')'
            if (($now - $lw).TotalDays -le 40) { $rows.Add((New-HealthRow 'Sistema' 'Última actualización de Windows' $txt 'Bien' $C.Green 0)) }
            else { $rows.Add((New-HealthRow 'Sistema' 'Última actualización de Windows' $txt 'Hace mucho' $C.Amber 1)) }
        }
        if ($info.LastBoot) {
            $lb = [datetime]$info.LastBoot
            $txt = $lb.ToString('dd/MM/yyyy HH:mm') + ' (' + (Get-DaysAgoText $lb) + ')'
            if (($now - $lb).TotalDays -le 14) { $rows.Add((New-HealthRow 'Sistema' 'Último reinicio' $txt 'Bien' $C.Green 0)) }
            else { $rows.Add((New-HealthRow 'Sistema' 'Último reinicio' $txt 'Reinicia la PC' $C.Amber 1)) }
        }
        if ($info.BoardProduct) {
            $board = (($info.BoardMfr + ' ' + $info.BoardProduct).Trim())
            $rows.Add((New-HealthRow 'Sistema' 'Placa madre' $board '' $C.Gray 0))
        }
        if ($info.BiosVersion) {
            $q = [uri]::EscapeDataString((($info.BoardMfr + ' ' + $info.BoardProduct + ' BIOS').Trim()))
            $link = "https://www.google.com/search?q=$q"
            $txt = $info.BiosVersion
            $st = 'Revisa si hay nueva'; $col = $C.Blue; $lvl = 0
            if ($info.BiosDate) {
                $bd = [datetime]$info.BiosDate
                $txt += ' (' + $bd.ToString('dd/MM/yyyy') + ')'
                if (($now - $bd).TotalDays -gt 730) { $st = 'Más de 2 años'; $col = $C.Amber; $lvl = 1 }
                else { $st = 'Reciente'; $col = $C.Green }
            }
            $rows.Add((New-HealthRow 'Sistema' 'BIOS' $txt $st $col $lvl $link 'Buscar BIOS'))
        }
    }

    # --- Discos ---
    foreach ($d in @($out | Where-Object { $_.Type -eq 'Disk' })) {
        $media = [string]$d.Media
        if ($media -eq 'Unspecified' -or -not $media) { $media = 'Disco' }
        $parts = @("$media $($d.Bus)".Trim(), "$($d.SizeGB) GB")
        $lvl = 0; $st = 'Bueno'; $col = $C.Green
        if ($d.Temp) {
            $parts += "$($d.Temp) °C"
            if ([int]$d.Temp -ge 70) { $lvl = [Math]::Max($lvl, 2); $st = 'Muy caliente'; $col = $C.Red }
            elseif ([int]$d.Temp -ge 60) { $lvl = [Math]::Max($lvl, 1); $st = 'Caliente'; $col = $C.Amber }
        }
        if ($null -ne $d.Wear -and [string]$d.Wear -ne '') {
            $parts += "desgaste $($d.Wear)%"
            if ([int]$d.Wear -ge 90) { $lvl = 2; $st = 'Desgaste alto'; $col = $C.Red }
            elseif ([int]$d.Wear -ge 70 -and $lvl -lt 2) { $lvl = 1; $st = 'Desgaste medio'; $col = $C.Amber }
        }
        if ($d.Hours) { $parts += ('{0:N0} h encendido' -f [double]$d.Hours) }
        switch ([string]$d.Health) {
            'Warning'   { $lvl = [Math]::Max($lvl, 1); $st = 'Advertencia'; $col = $C.Amber }
            'Unhealthy' { $lvl = 2; $st = 'Con fallas'; $col = $C.Red }
        }
        $rows.Add((New-HealthRow 'Discos' $d.Name ($parts -join ' · ') $st $col $lvl))
    }
    foreach ($v in @($out | Where-Object { $_.Type -eq 'Volume' })) {
        $pct = 0; if ([double]$v.SizeGB -gt 0) { $pct = [math]::Round(100 * [double]$v.FreeGB / [double]$v.SizeGB) }
        $name = "Unidad $($v.Letter)"; if ($v.Label) { $name += " ($($v.Label))" }
        $txt = "$($v.FreeGB) GB libres de $($v.SizeGB) GB ($pct%)"
        if ($pct -lt 10) { $rows.Add((New-HealthRow 'Discos' $name $txt 'Casi llena' $C.Red 2)) }
        elseif ($pct -lt 20) { $rows.Add((New-HealthRow 'Discos' $name $txt 'Poco espacio' $C.Amber 1)) }
        else { $rows.Add((New-HealthRow 'Discos' $name $txt 'Bien' $C.Green 0)) }
    }
    # --- Estabilidad (ultimos 30 dias) ---
    $events = @($out | Where-Object { $_.Type -eq 'Event' })
    $power = @($events | Where-Object { $_.Kind -eq 'Power' })
    if ($power.Count -eq 0) { $power = @($events | Where-Object { $_.Kind -eq 'PowerOld' }) }
    $defs = @(
        @{ Item = 'Apagados inesperados (corte de luz, cuelgue o reinicio forzado)'; List = $power; Warn = 1; Bad = 3; BadText = 'Revisa la luz / el UPS' }
        @{ Item = 'Pantallazos azules'; List = @($events | Where-Object { $_.Kind -eq 'BSOD' }); Warn = 1; Bad = 2; BadText = 'Hay que revisar' }
        @{ Item = 'Errores de hardware (WHEA)'; List = @($events | Where-Object { $_.Kind -eq 'WHEA' }); Warn = 1; Bad = 5; BadText = 'Hay que revisar' }
        @{ Item = 'Errores de disco'; List = @($events | Where-Object { $_.Kind -eq 'Disk' }); Warn = 1; Bad = 5; BadText = 'Haz copia de seguridad' }
    )
    foreach ($df in $defs) {
        $n = $df.List.Count
        if ($n -eq 0) { $rows.Add((New-HealthRow 'Estabilidad' $df.Item 'Ninguno en 30 días' 'Bien' $C.Green 0)); continue }
        $lastE = ($df.List | Sort-Object Date -Descending | Select-Object -First 1).Date
        $txt = "$n en 30 días · último: " + ([datetime]$lastE).ToString('dd/MM/yyyy HH:mm')
        if ($n -ge $df.Bad) { $rows.Add((New-HealthRow 'Estabilidad' $df.Item $txt $df.BadText $C.Red 2 'perfmon-rel' 'Ver detalle')) }
        else { $rows.Add((New-HealthRow 'Estabilidad' $df.Item $txt 'Atención' $C.Amber 1 'perfmon-rel' 'Ver detalle')) }
    }
    return ,@($rows)
}

# ===================================================================
#  Ventana
# ===================================================================
$script:XamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Revix PC" Width="1280" Height="800" MinWidth="1080" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource BgWindow}" Foreground="{DynamicResource Fg}"
        WindowStyle="None" ResizeMode="CanResize"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13.5">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="40" ResizeBorderThickness="6" GlassFrameThickness="0,0,0,1" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <!--BRUSHES-->
    <BooleanToVisibilityConverter x:Key="BoolToVis"/>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource BgControl}"/>
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderControl}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="BtnSmall" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="{DynamicResource BgCard}"/>
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderCard}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="RowBackground" Value="{DynamicResource BgCard}"/>
      <Setter Property="AlternatingRowBackground" Value="{DynamicResource BgCard}"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource BorderSoft}"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="RowHeight" Value="40"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{DynamicResource BgCard}"/>
      <Setter Property="Foreground" Value="{DynamicResource FgMuted}"/>
      <Setter Property="Padding" Value="10,10"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderCard}"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{DynamicResource Selected}"/>
          <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource FgMuted}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="10,8" Margin="0,0,1,0" Cursor="Hand">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource BgCard}"/>
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderInput}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Fg}"/>
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource BgCard}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderCard}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="18,16"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource FgMuted}"/>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,18,0,8"/>
    </Style>
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding StatusText}" Value=""><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
        <DataTrigger Binding="{Binding StatusText}" Value="{x:Null}"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <DataTemplate x:Key="StatusCell">
      <Border Style="{StaticResource Pill}" Background="{Binding StatusColor}">
        <TextBlock Text="{Binding StatusText}" Foreground="#FFFFFF" FontWeight="SemiBold" FontSize="12.5"/>
      </Border>
    </DataTemplate>
    <Style x:Key="CapBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Foreground" Value="{DynamicResource CapIcon}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource BorderCard}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CapBtnClose" TargetType="Button" BasedOn="{StaticResource CapBtn}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#C42B1C"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <DataTemplate x:Key="LinkCell">
      <Button Content="{Binding ActionText}" Tag="{Binding Link}" Style="{StaticResource BtnSmall}"
              Visibility="{Binding HasLink, Converter={StaticResource BoolToVis}}"/>
    </DataTemplate>
    <DataTemplate x:Key="CheckCell">
      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/>
    </DataTemplate>
    <Style x:Key="CardBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{DynamicResource BgCard}" BorderBrush="{DynamicResource BorderCard}" BorderThickness="1" CornerRadius="14" Padding="18,16">
              <ContentPresenter HorizontalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource FgSoft}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="FontSize" Value="13.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Grid>
              <Border x:Name="Bg" CornerRadius="8" Background="Transparent" Padding="12,9">
                <ContentPresenter/>
              </Border>
              <Border x:Name="Bar" Width="3" CornerRadius="2" HorizontalAlignment="Left" Margin="0,9" Background="{DynamicResource Accent}" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="{DynamicResource Selected}"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Badge" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Track}"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="7,1"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
    <Style x:Key="NavIcon" TargetType="Path">
      <Setter Property="Stroke" Value="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ListBoxItem}}"/>
      <Setter Property="StrokeThickness" Value="1.8"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
      <Setter Property="StrokeStartLineCap" Value="Round"/>
      <Setter Property="StrokeEndLineCap" Value="Round"/>
    </Style>
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="3" Background="{DynamicResource Track}"/>
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="{DynamicResource Thumb}" Margin="2"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
                <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}"/></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                    <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}"/></Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid">
    <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- Menu lateral -->
    <Border Background="{DynamicResource BgSide}" BorderBrush="{DynamicResource BorderSoft}" BorderThickness="0,0,1,0">
      <DockPanel Margin="12,18,12,14">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="10,0,0,20">
          <Image x:Name="Logo" Width="32" Height="32" Margin="0,0,10,0"/>
          <TextBlock Text="Revix PC" FontSize="17" FontWeight="Bold" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="VersionText" DockPanel.Dock="Bottom" Foreground="{DynamicResource FgFaint}" FontSize="12" Margin="12,10,0,0"/>
        <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled" Foreground="{DynamicResource FgSoft}">
          <ListBoxItem Tag="0" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M3 11 L12 4 L21 11 V20 H15 V14 H9 V20 H3 Z" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Resumen" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="1" Style="{StaticResource NavItem}">
            <DockPanel>
                <Border x:Name="BadgeProgBox" DockPanel.Dock="Right" Style="{StaticResource Badge}"><TextBlock x:Name="BadgeProg" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource Fg}"/></Border>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Programas" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="2" Style="{StaticResource NavItem}">
            <DockPanel>
                <Border x:Name="BadgeWUBox" DockPanel.Dock="Right" Style="{StaticResource Badge}"><TextBlock x:Name="BadgeWU" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource Fg}"/></Border>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M3 5l8-1v8H3z M13 4l8-1v9h-8z M3 13h8v7l-8-1z M13 13h8v8l-8-1z" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Windows Update" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="3" Style="{StaticResource NavItem}">
            <DockPanel>
                <Border x:Name="BadgeDevBox" DockPanel.Dock="Right" Style="{StaticResource Badge}"><TextBlock x:Name="BadgeDev" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource Fg}"/></Border>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M7 7h10v10H7z M9 3v4 M15 3v4 M9 17v4 M15 17v4 M3 9h4 M3 15h4 M17 9h4 M17 15h4" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Dispositivos" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="4" Style="{StaticResource NavItem}">
            <DockPanel>
                <Border x:Name="BadgeHealthBox" DockPanel.Dock="Right" Style="{StaticResource Badge}"><TextBlock x:Name="BadgeHealth" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource Fg}"/></Border>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M20.8 5.6a5 5 0 0 0-7.1 0L12 7.3l-1.7-1.7a5 5 0 1 0-7.1 7.1L12 21.5l8.8-8.8a5 5 0 0 0 0-7.1z" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Salud" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="5" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M3 21h18 M7 21l2-8h6l2 8 M12 13V3" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Limpieza" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="6" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M12 2v10 M5.6 6.6a8 8 0 1 0 12.8 0" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Inicio de Windows" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="7" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M3 6h18 M8 6V4h8v2 M6 6l1 15h10l1-15" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Desinstalar" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="8" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M3 4h18v12H3z M8 20h8 M12 16v4" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Mi PC" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem IsEnabled="False" Focusable="False" Style="{StaticResource NavItem}"><Border Height="1" Background="{DynamicResource BorderSoft}" Margin="0,4"/></ListBoxItem>
          <ListBoxItem Tag="9" Style="{StaticResource NavItem}">
            <DockPanel>
                <Border x:Name="BadgeTaskBox" DockPanel.Dock="Right" Style="{StaticResource Badge}"><TextBlock x:Name="BadgeTask" FontSize="11.5" FontWeight="SemiBold" Foreground="{DynamicResource Fg}"/></Border>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M3 12h4l3 8 4-16 3 8h4" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Progreso" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="10" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M12 7v5l3 2 M21 12a9 9 0 1 1-9-9a9 9 0 0 1 9 9z" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Historial" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem Tag="11" Style="{StaticResource NavItem}">
            <DockPanel>
                <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left"><Canvas Width="24" Height="24"><Path Data="M4 6h9 M17 6h3 M4 12h3 M11 12h9 M4 18h11 M19 18h1 M15 4v4 M9 10v4 M17 16v4" Style="{StaticResource NavIcon}"/></Canvas></Viewbox>
              <TextBlock Text="Ajustes" VerticalAlignment="Center"/>
            </DockPanel>
          </ListBoxItem>
        </ListBox>
      </DockPanel>
    </Border>

    <!-- Contenido -->
    <Grid Grid.Column="1" Margin="28,40,28,12">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">
        <TextBlock x:Name="PageTitle" Text="Resumen" FontSize="24" FontWeight="Bold" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border Background="{DynamicResource BgCard}" BorderBrush="{DynamicResource BorderCard}" BorderThickness="1" CornerRadius="16" Padding="12,6" Margin="0,0,12,0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="GameDot" Width="8" Height="8" Fill="#6B7383" Margin="0,0,8,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="GameChipText" Text="Modo juego" Foreground="{DynamicResource FgSoft}" FontSize="12.5"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="LastScan" Foreground="{DynamicResource FgMuted}" FontSize="12.5" VerticalAlignment="Center" Margin="0,0,14,0"/>
          <Button x:Name="BtnExport" Content="Exportar reporte" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnScanAll" Content="Escanear todo" Style="{StaticResource BtnPrimary}" Margin="0"/>
        </StackPanel>
      </Grid>

      <Border x:Name="AdminWarning" Grid.Row="1" Background="{DynamicResource WarnBg}" BorderBrush="{DynamicResource WarnBorder}" BorderThickness="1" CornerRadius="10" Padding="14,9" Margin="0,14,0,0" Visibility="Collapsed">
        <TextBlock Foreground="{DynamicResource WarnFg}" TextWrapping="Wrap" Text="Sin permisos de administrador: puedes escanear, pero para instalar actualizaciones de Windows, crear puntos de restauración o respaldar drivers, cierra Revix PC (Salir) y ábrela aceptando el aviso de Windows."/>
      </Border>

    <TabControl x:Name="Tabs" Grid.Row="2" Background="Transparent" BorderThickness="0">
      <TabControl.Template>
        <ControlTemplate TargetType="TabControl">
          <ContentPresenter ContentSource="SelectedContent" Margin="0,16,0,0"/>
        </ControlTemplate>
      </TabControl.Template>

      <TabItem x:Name="TabHome" Header="Resumen">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,0,6,6">
            <Border Style="{StaticResource Card}" Padding="26,22">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <Grid Width="112" Height="112">
                  <Ellipse Width="100" Height="100" Stroke="{DynamicResource Track}" StrokeThickness="10"/>
                  <Path x:Name="ScoreArc" Stroke="#22C55E" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <TextBlock x:Name="ScoreText" Text="–" FontSize="30" FontWeight="Bold" HorizontalAlignment="Center"/>
                    <TextBlock Text="de 100" FontSize="12" Foreground="{DynamicResource FgMuted}" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Grid>
                <StackPanel Grid.Column="1" Margin="24,0" VerticalAlignment="Center">
                  <TextBlock x:Name="ScoreTitle" Text="Revisando tu PC..." FontSize="24" FontWeight="Bold" TextWrapping="Wrap"/>
                  <TextBlock x:Name="ScoreSub" Text="Esto tarda un momento." Foreground="{DynamicResource FgSoft}" TextWrapping="Wrap" Margin="0,6,0,0" FontSize="14"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="BtnHomeUpdate" Content="Actualizar programas" Style="{StaticResource BtnPrimary}" Margin="0,0,10,0" Padding="18,11"/>
                  <Button x:Name="BtnHomeClean" Content="Limpieza" Style="{StaticResource Btn}" Margin="0" Padding="18,11"/>
                </StackPanel>
              </Grid>
            </Border>

            <UniformGrid Columns="4" Margin="0,14,-14,0">
        <Button x:Name="CardProg" Tag="1" Style="{StaticResource CardBtn}">
          <StackPanel>
            <TextBlock Text="Programas" Foreground="{DynamicResource FgSoft}"/>
            <TextBlock x:Name="NumPrograms" Text="–" FontSize="30" FontWeight="Bold" Margin="0,8,0,6"/>
            <TextBlock x:Name="SubPrograms" Text=" " Foreground="{DynamicResource TextAmber}" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Button>
        <Button x:Name="CardWU" Tag="2" Style="{StaticResource CardBtn}">
          <StackPanel>
            <TextBlock Text="Windows Update" Foreground="{DynamicResource FgSoft}"/>
            <TextBlock x:Name="NumWU" Text="–" FontSize="30" FontWeight="Bold" Margin="0,8,0,6"/>
            <TextBlock x:Name="SubWU" Text=" " Foreground="{DynamicResource TextRed}" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Button>
        <Button x:Name="CardDrv" Tag="3" Style="{StaticResource CardBtn}">
          <StackPanel>
            <TextBlock Text="Drivers" Foreground="{DynamicResource FgSoft}"/>
            <TextBlock x:Name="NumDrivers" Text="–" FontSize="30" FontWeight="Bold" Margin="0,8,0,6"/>
            <TextBlock x:Name="SubDrivers" Text=" " Foreground="{DynamicResource TextAmber}" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Button>
        <Button x:Name="CardHealth" Tag="4" Style="{StaticResource CardBtn}">
          <StackPanel>
            <TextBlock Text="Salud y seguridad" Foreground="{DynamicResource FgSoft}"/>
            <TextBlock x:Name="NumHealth" Text="–" FontSize="30" FontWeight="Bold" Margin="0,8,0,6"/>
            <TextBlock x:Name="SubHealth" Text=" " Foreground="{DynamicResource TextBlue}" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Button>
            </UniformGrid>

            <Grid Margin="0,14,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
              <Border Style="{StaticResource Card}" Margin="0,0,14,0" Padding="20,16" VerticalAlignment="Top">
                <StackPanel>
                  <DockPanel Margin="0,0,0,6">
                    <TextBlock x:Name="TodoCount" DockPanel.Dock="Right" Foreground="{DynamicResource FgMuted}" VerticalAlignment="Center"/>
                    <TextBlock Text="Por hacer" FontSize="16" FontWeight="SemiBold"/>
                  </DockPanel>
                  <ItemsControl x:Name="TodoList">
                    <ItemsControl.ItemTemplate>
                      <DataTemplate>
                        <Border BorderBrush="{DynamicResource BorderSoft}" BorderThickness="0,1,0,0" Padding="0,12">
                          <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Border Width="36" Height="36" CornerRadius="9" Background="{Binding Tile}">
                              <TextBlock Text="{Binding Letter}" Foreground="#FFFFFF" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <StackPanel Grid.Column="1" Margin="14,0" VerticalAlignment="Center">
                              <TextBlock Text="{Binding Title}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                              <TextBlock Text="{Binding Detail}" Foreground="{DynamicResource FgMuted}" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                            <Border Grid.Column="2" Background="{DynamicResource Chip}" CornerRadius="10" Padding="10,3" VerticalAlignment="Center" Margin="0,0,10,0">
                              <TextBlock Text="{Binding Kind}" FontSize="12" Foreground="{DynamicResource FgSoft}"/>
                            </Border>
                            <Button Grid.Column="3" Content="{Binding ActionText}" Tag="{Binding Target}" Style="{StaticResource BtnSmall}" VerticalAlignment="Center"/>
                          </Grid>
                        </Border>
                      </DataTemplate>
                    </ItemsControl.ItemTemplate>
                  </ItemsControl>
                  <TextBlock x:Name="TodoEmpty" Text="Revisando..." Foreground="{DynamicResource FgMuted}" Margin="0,10,0,4"/>
                </StackPanel>
              </Border>
              <StackPanel Grid.Column="1">
                <Border Style="{StaticResource Card}" Padding="20,16">
                  <StackPanel>
                    <TextBlock Text="Temperaturas" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
                    <ItemsControl x:Name="MiniTemps">
                      <ItemsControl.ItemTemplate>
                        <DataTemplate>
                          <StackPanel Margin="0,0,0,12">
                            <DockPanel Margin="0,0,0,6">
                              <TextBlock Text="{Binding Value}" DockPanel.Dock="Right" FontWeight="SemiBold"/>
                              <TextBlock Text="{Binding Name}" Foreground="{DynamicResource FgSoft}" TextTrimming="CharacterEllipsis"/>
                            </DockPanel>
                            <ProgressBar Style="{StaticResource Bar}" Value="{Binding Pct, Mode=OneWay}" Foreground="{Binding Color}"/>
                          </StackPanel>
                        </DataTemplate>
                      </ItemsControl.ItemTemplate>
                    </ItemsControl>
                  </StackPanel>
                </Border>
                <Border Style="{StaticResource Card}" Padding="20,16" Margin="0,14,0,0">
                  <StackPanel>
                    <TextBlock Text="Estabilidad · 30 días" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,8"/>
                    <ItemsControl x:Name="MiniStab">
                      <ItemsControl.ItemTemplate>
                        <DataTemplate>
                          <DockPanel Margin="0,5">
                            <Ellipse Width="8" Height="8" Fill="{Binding Color}" Margin="0,0,10,0" VerticalAlignment="Center" DockPanel.Dock="Left"/>
                            <TextBlock Text="{Binding Value}" DockPanel.Dock="Right" FontWeight="SemiBold"/>
                            <TextBlock Text="{Binding Name}" Foreground="{DynamicResource FgSoft}"/>
                          </DockPanel>
                        </DataTemplate>
                      </ItemsControl.ItemTemplate>
                    </ItemsControl>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Grid>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="Programas">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,2">
            <CheckBox x:Name="ChkShowIgnored" Content="Mostrar ignorados y saltados" DockPanel.Dock="Right" Margin="10,0,0,8"/>
            <WrapPanel>
              <Button x:Name="BtnProgSelectAll" Content="Marcar todo" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnProgUpdateSel" Content="Actualizar marcados" Style="{StaticResource BtnPrimary}"/>
              <Button x:Name="BtnProgUpdateAll" Content="Actualizar todos" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnProgSkip" Content="Saltar esta versión" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnProgIgnore" Content="Ignorar siempre" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnProgAuto" Content="Automático sí / no" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnRollback" Content="Volver a una versión anterior" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnStore" Content="Apps de la Store" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </DockPanel>
          <DataGrid x:Name="GridPrograms" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTemplateColumn Width="42" CellTemplate="{StaticResource CheckCell}"/>
              <DataGridTextColumn Header="Programa" Binding="{Binding Name}" Width="*"/>
              <DataGridTextColumn Header="Versión actual" Binding="{Binding Version}" Width="130"/>
              <DataGridTextColumn Header="Nueva versión" Binding="{Binding Available}" Width="130"/>
              <DataGridTextColumn Header="Id" Binding="{Binding Id}" Width="210"/>
              <DataGridTextColumn Header="Origen" Binding="{Binding Source}" Width="75"/>
              <DataGridTextColumn Header="" Binding="{Binding StateText}" Width="110"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="Windows Update">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <WrapPanel Margin="0,0,0,2">
            <Button x:Name="BtnWUSelectAll" Content="Marcar todo" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnWUInstall" Content="Instalar marcadas" Style="{StaticResource BtnPrimary}"/>
            <Button x:Name="BtnWUSettings" Content="Abrir Windows Update" Style="{StaticResource Btn}"/>
          </WrapPanel>
          <DataGrid x:Name="GridWU" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTemplateColumn Width="42" CellTemplate="{StaticResource CheckCell}"/>
              <DataGridTextColumn Header="Actualización" Binding="{Binding Title}" Width="*"/>
              <DataGridTextColumn Header="Tipo" Binding="{Binding Kind}" Width="110"/>
              <DataGridTextColumn Header="Gravedad" Binding="{Binding Severity}" Width="100"/>
              <DataGridTextColumn Header="KB" Binding="{Binding KB}" Width="110"/>
              <DataGridTextColumn Header="Tamaño" Binding="{Binding Size}" Width="90"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="Dispositivos">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,2">
            <CheckBox x:Name="ChkShowGeneric" Content="Mostrar drivers genéricos de Windows" DockPanel.Dock="Right" Margin="10,0,0,8"/>
            <WrapPanel>
              <Button x:Name="BtnDevMgr" Content="Administrador de dispositivos" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnDrvBackup" Content="Respaldar drivers" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnDrvRestore" Content="Restaurar respaldo" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </DockPanel>
          <DataGrid x:Name="GridDevices" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="Estado" Width="170" CellTemplate="{StaticResource StatusCell}"/>
              <DataGridTextColumn Header="Dispositivo" Binding="{Binding Name}" Width="*"/>
              <DataGridTextColumn Header="Tipo" Binding="{Binding DeviceClass}" Width="95"/>
              <DataGridTextColumn Header="Fabricante" Binding="{Binding Manufacturer}" Width="130"/>
              <DataGridTextColumn Header="Versión" Binding="{Binding Version}" Width="115"/>
              <DataGridTextColumn Header="Fecha" Binding="{Binding Date}" Width="85"/>
              <DataGridTextColumn Header="Nota" Binding="{Binding Note}" Width="240"/>
              <DataGridTemplateColumn Header="" Width="125" CellTemplate="{StaticResource LinkCell}"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="Salud">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <WrapPanel Margin="0,0,0,2">
            <Button x:Name="BtnHealthScan" Content="Volver a revisar" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnDefender" Content="Actualizar firmas de Defender" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnSecurity" Content="Abrir Seguridad de Windows" Style="{StaticResource Btn}"/>
          </WrapPanel>
          <DataGrid x:Name="GridHealth" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Área" Binding="{Binding Section}" Width="90"/>
              <DataGridTextColumn Header="Elemento" Binding="{Binding Item}" Width="260"/>
              <DataGridTextColumn Header="Detalle" Binding="{Binding Value}" Width="*"/>
              <DataGridTemplateColumn Header="Estado" Width="170" CellTemplate="{StaticResource StatusCell}"/>
              <DataGridTemplateColumn Header="" Width="120" CellTemplate="{StaticResource LinkCell}"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="Limpieza">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,2">
            <TextBlock x:Name="CleanTotal" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="10,0,0,8" FontWeight="SemiBold"/>
            <WrapPanel>
              <Button x:Name="BtnCleanScan" Content="Calcular espacio" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnCleanRun" Content="Limpiar marcados" Style="{StaticResource BtnPrimary}"/>
            </WrapPanel>
          </DockPanel>
          <DataGrid x:Name="GridClean" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTemplateColumn Width="42" CellTemplate="{StaticResource CheckCell}"/>
              <DataGridTextColumn Header="Qué se limpia" Binding="{Binding Name}" Width="280"/>
              <DataGridTextColumn Header="Tamaño" Binding="{Binding SizeText}" Width="110"/>
              <DataGridTextColumn Header="Nota" Binding="{Binding Note}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabStartup" Header="Inicio de Windows">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,2">
            <TextBlock x:Name="BootInfo" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="10,0,0,8" FontWeight="SemiBold"/>
            <WrapPanel>
              <Button x:Name="BtnStartupScan" Content="Actualizar lista" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnTaskMgr" Content="Abrir Administrador de tareas" Style="{StaticResource Btn}"/>
              <TextBlock Text="Desmarca lo que no necesitas al prender la PC. No se borra nada." Style="{StaticResource Muted}" VerticalAlignment="Center" Margin="6,0,0,8"/>
            </WrapPanel>
          </DockPanel>
          <DataGrid x:Name="GridStartup" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="Activo" Width="60">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><CheckBox IsChecked="{Binding Enabled, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Programa" Binding="{Binding Name}" Width="200"/>
              <DataGridTextColumn Header="Editor" Binding="{Binding Publisher}" Width="170"/>
              <DataGridTextColumn Header="Impacto en el arranque" Binding="{Binding Impact}" Width="200"/>
              <DataGridTextColumn Header="Dónde" Binding="{Binding Location}" Width="160"/>
              <DataGridTextColumn Header="Comando" Binding="{Binding Command}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabApps" Header="Desinstalar">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,2">
            <TextBlock x:Name="AppsInfo" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="10,0,0,8" Style="{StaticResource Muted}"/>
            <WrapPanel>
              <TextBlock Text="Buscar:" VerticalAlignment="Center" Margin="0,0,6,8"/>
              <TextBox x:Name="TxtAppSearch" Width="220" Margin="0,0,8,8"/>
              <Button x:Name="BtnUninstall" Content="Desinstalar seleccionado" Style="{StaticResource BtnPrimary}"/>
              <Button x:Name="BtnAppsScan" Content="Actualizar lista" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnAppsSettings" Content="Aplicaciones de Windows" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </DockPanel>
          <DataGrid x:Name="GridApps" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Programa" Binding="{Binding Name}" Width="*"/>
              <DataGridTextColumn Header="Editor" Binding="{Binding Publisher}" Width="200"/>
              <DataGridTextColumn Header="Versión" Binding="{Binding Version}" Width="130"/>
              <DataGridTextColumn Header="Tamaño" Binding="{Binding Size}" SortMemberPath="SizeMB" Width="95"/>
              <DataGridTextColumn Header="Instalado" Binding="{Binding InstallDate}" Width="95"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabMyPC" Header="Mi PC">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="390"/></Grid.ColumnDefinitions>
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <WrapPanel Margin="0,0,0,2">
              <Button x:Name="BtnCopySpecs" Content="Copiar ficha" Style="{StaticResource BtnPrimary}"/>
              <Button x:Name="BtnPcScan" Content="Actualizar" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnBatteryReport" Content="Informe de batería" Style="{StaticResource Btn}" Visibility="Collapsed"/>
            </WrapPanel>
            <DataGrid x:Name="GridSpecs" Grid.Row="1">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Parte" Binding="{Binding Section}" Width="100"/>
                <DataGridTextColumn Header="Elemento" Binding="{Binding Item}" Width="150"/>
                <DataGridTextColumn Header="Detalle" Binding="{Binding Value}" Width="*"/>
                <DataGridTextColumn Header="Nota" Binding="{Binding Note}" Width="200"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
          <StackPanel Grid.Column="1" Margin="14,0,0,0">
            <TextBlock Text="Temperaturas en vivo" Style="{StaticResource SectionTitle}" Margin="0,4,0,8"/>
            <DataGrid x:Name="GridTemps" MaxHeight="420">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Sensor" Binding="{Binding Item}" Width="*"/>
                <DataGridTextColumn Header="Valor" Binding="{Binding Value}" Width="95"/>
                <DataGridTemplateColumn Header="Estado" Width="110" CellTemplate="{StaticResource StatusCell}"/>
              </DataGrid.Columns>
            </DataGrid>
            <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,10,0,0"
                       Text="Se actualiza cada 3 segundos mientras miras esta pestaña. La temperatura del procesador no se puede leer sin un driver especial (para eso usa HWiNFO)."/>
          </StackPanel>
        </Grid>
      </TabItem>

      <TabItem x:Name="TabProgress" Header="Progreso">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,2">
            <TextBlock x:Name="TaskHeader" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="10,0,0,8" Style="{StaticResource Muted}" Text="Sin tareas en curso"/>
            <WrapPanel>
              <Button x:Name="BtnCancel" Content="Cancelar (al terminar el actual)" Style="{StaticResource Btn}" IsEnabled="False"/>
              <Button x:Name="BtnClearTasks" Content="Limpiar lista" Style="{StaticResource Btn}"/>
            </WrapPanel>
          </DockPanel>
          <DataGrid x:Name="GridTasks" Grid.Row="1">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="Estado" Width="170" CellTemplate="{StaticResource StatusCell}"/>
              <DataGridTextColumn Header="Tarea" Binding="{Binding Name}" Width="*"/>
              <DataGridTextColumn Header="Detalle" Binding="{Binding Detail}" Width="380"/>
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>

      <TabItem Header="Historial">
        <DataGrid x:Name="GridHistory">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Fecha" Binding="{Binding Date}" Width="140"/>
            <DataGridTextColumn Header="Acción" Binding="{Binding Action}" Width="300"/>
            <DataGridTextColumn Header="Resultado" Binding="{Binding Result}" Width="*"/>
          </DataGrid.Columns>
        </DataGrid>
      </TabItem>

      <TabItem Header="Ajustes">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel MaxWidth="760" HorizontalAlignment="Left" Margin="0,0,0,16">
            <TextBlock Text="Funcionamiento" Style="{StaticResource SectionTitle}" Margin="0,4,0,8"/>
            <CheckBox x:Name="ChkStartup" Content="Iniciar con Windows (queda junto al reloj y revisa sola)" Margin="0,0,0,10"/>
            <CheckBox x:Name="ChkCloseToTray" Content="Al cerrar la ventana, seguir funcionando junto al reloj" Margin="0,0,0,10"/>
            <CheckBox x:Name="ChkNotify" Content="Avisarme con una notificación cuando haya actualizaciones" Margin="0,0,0,10"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
              <TextBlock Text="Revisar automáticamente:" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <ComboBox x:Name="CmbAutoCheck" Width="160" Foreground="#111318">
                <ComboBoxItem Content="Nunca" Tag="0"/>
                <ComboBoxItem Content="Cada 6 horas" Tag="6"/>
                <ComboBoxItem Content="Cada 12 horas" Tag="12"/>
                <ComboBoxItem Content="Cada 24 horas" Tag="24"/>
              </ComboBox>
            </StackPanel>

            <TextBlock Text="Apariencia" Style="{StaticResource SectionTitle}"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
              <TextBlock Text="Tema:" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <ComboBox x:Name="CmbTheme" Width="200" Foreground="#111318">
                <ComboBoxItem Content="Igual que Windows" Tag="System"/>
                <ComboBoxItem Content="Oscuro" Tag="Dark"/>
                <ComboBoxItem Content="Claro" Tag="Light"/>
              </ComboBox>
            </StackPanel>

            <TextBlock Text="Seguridad al instalar" Style="{StaticResource SectionTitle}"/>
            <CheckBox x:Name="ChkRestorePoint" Content="Crear un punto de restauración antes de instalar actualizaciones" Margin="0,0,0,6"/>
            <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="24,0,0,10"
                       Text="Si la protección del sistema está apagada, Revix PC te preguntará antes de encenderla. Si algo sale mal, puedes volver atrás con 'Restaurar sistema'."/>
            <Button x:Name="BtnOpenRestore" Content="Abrir Restaurar sistema" Style="{StaticResource Btn}" HorizontalAlignment="Left"/>

            <TextBlock Text="Modo juego" Style="{StaticResource SectionTitle}"/>
            <CheckBox x:Name="ChkGameMode" Content="Mientras juego o uso algo en pantalla completa: no avisar, no revisar y no instalar nada" Margin="0,0,0,8"/>
            <TextBlock Text="Juegos extra a detectar aunque no estén en pantalla completa (nombre del proceso, separados por comas):" Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="24,0,0,4"/>
            <TextBox x:Name="TxtGames" Width="560" HorizontalAlignment="Left" Margin="24,0,0,10"/>

            <TextBlock Text="Programas automáticos" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,10"
                       Text="Los programas marcados como 'Automático' (pestaña Programas) se actualizan solos en cada revisión automática, sin preguntar y sin crear punto de restauración. Nunca durante el modo juego."/>

            <TextBlock Text="Temperaturas" Style="{StaticResource SectionTitle}"/>
            <CheckBox x:Name="ChkTempAlert" Content="Avisarme si la tarjeta de video pasa de 85 °C (revisa cada 30 segundos)" Margin="0,0,0,10"/>

            <TextBlock Text="Actualizaciones de Revix PC" Style="{StaticResource SectionTitle}"/>
            <CheckBox x:Name="ChkAppUpdates" Content="Buscar nuevas versiones de Revix PC al abrir (en GitHub)" Margin="0,0,0,8"/>
            <Button x:Name="BtnCheckAppUpdate" Content="Buscar nueva versión ahora" Style="{StaticResource Btn}" HorizontalAlignment="Left"/>

            <TextBlock Text="Acerca de" Style="{StaticResource SectionTitle}"/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Image x:Name="AboutLogo" Width="40" Height="40" Margin="0,0,14,0"/>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="AboutTitle" Text="Revix PC" FontSize="16" FontWeight="SemiBold"/>
                    <TextBlock Text="Hecho por Marco11  ·  Licencia MIT (gratis y de código abierto)" Style="{StaticResource Muted}"/>
                  </StackPanel>
                </StackPanel>
                <TextBlock TextWrapping="Wrap" Margin="0,14,0,0" Style="{StaticResource Muted}"
                           Text="Privacidad: Revix PC no envía tus datos a nadie. Todo se revisa en tu PC. Solo se conecta a internet para consultar a Microsoft (winget, Windows Update y Defender), a NVIDIA (si tienes tarjeta NVIDIA, para ver el último driver) y a GitHub (para buscar versiones nuevas de Revix PC)."/>
                <TextBlock TextWrapping="Wrap" Margin="0,8,0,0" Style="{StaticResource Muted}"
                           Text="Revix PC no está afiliado ni respaldado por Microsoft, NVIDIA, AMD, Intel, Logitech, Razer, HyperX ni otras marcas que aparezcan en la app. Sus nombres pertenecen a sus dueños y solo se usan para identificar tu hardware y software."/>
                <TextBlock TextWrapping="Wrap" Margin="0,8,0,0" Style="{StaticResource Muted}"
                           Text="Se ofrece 'tal cual', sin garantía. Úsala bajo tu responsabilidad. Al actualizar programas, winget acepta en tu nombre las licencias de esos programas."/>
                <WrapPanel Margin="0,14,0,0">
                  <Button x:Name="BtnGitHub" Content="Ver en GitHub" Style="{StaticResource Btn}"/>
                  <Button x:Name="BtnLicense" Content="Ver licencia" Style="{StaticResource Btn}"/>
                  <Button x:Name="BtnReport" Content="Reportar un problema" Style="{StaticResource Btn}"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Expander x:Name="ExpAdvanced" Margin="0,18,0,0" Foreground="{DynamicResource Fg}">
              <Expander.Header><TextBlock Text="Avanzado" FontSize="15" FontWeight="SemiBold"/></Expander.Header>
              <StackPanel Margin="0,10,0,0">
                <TextBlock x:Name="InstallInfo" Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,0,0,8"/>
                <WrapPanel>
                  <Button x:Name="BtnInstallApp" Content="Reparar instalación" Style="{StaticResource Btn}"/>
                  <Button x:Name="BtnUpdateFromZip" Content="Instalar desde un archivo .zip" Style="{StaticResource Btn}"/>
                  <Button x:Name="BtnOpenData" Content="Abrir carpeta de datos" Style="{StaticResource Btn}"/>
                  <Button x:Name="BtnUninstallApp" Content="Desinstalar Revix PC" Style="{StaticResource Btn}"/>
                </WrapPanel>
                <TextBlock x:Name="AboutText" Style="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,8,0,0"/>
              </StackPanel>
            </Expander>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>

      <Grid Grid.Row="3" Margin="0,10,0,0">
        <StackPanel Orientation="Horizontal">
          <ProgressBar x:Name="Busy" Width="140" Height="5" IsIndeterminate="True" Visibility="Collapsed" Margin="0,0,10,0"
                       Background="{DynamicResource Track}" Foreground="{DynamicResource Accent}" BorderThickness="0"/>
          <TextBlock x:Name="StatusText" Text="Listo" Foreground="{DynamicResource FgMuted}" FontSize="12.5"/>
        </StackPanel>
      </Grid>
    </Grid>

    <!-- Botones de la ventana (tema, minimizar, maximizar, cerrar) -->
    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
      <Button x:Name="BtnTheme" Style="{StaticResource CapBtn}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="Cambiar a tema claro">
        <TextBlock x:Name="ThemeIcon" FontFamily="Segoe MDL2 Assets" FontSize="13" Text="&#xE706;" Foreground="{DynamicResource CapIcon}"/>
      </Button>
      <Button x:Name="BtnWinMin" Style="{StaticResource CapBtn}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="Minimizar">
        <Path Data="M0,0.5 H10" Stroke="{DynamicResource CapIcon}" StrokeThickness="1"/>
      </Button>
      <Button x:Name="BtnWinMax" Style="{StaticResource CapBtn}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="Maximizar">
        <Path x:Name="MaxIcon" Data="M0.5,0.5 H9.5 V9.5 H0.5 Z" Stroke="{DynamicResource CapIcon}" StrokeThickness="1"/>
      </Button>
      <Button x:Name="BtnWinClose" Style="{StaticResource CapBtnClose}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="Cerrar">
        <Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="{DynamicResource CapIcon}" StrokeThickness="1"/>
      </Button>
    </StackPanel>
  </Grid>
</Window>
'@
# Colores del tema oscuro como valores iniciales (Apply-Theme los cambia en vivo)
$brushXml = ($script:Themes.Dark.Keys | ForEach-Object { "<SolidColorBrush x:Key=`"$_`" Color=`"$($script:Themes.Dark[$_])`"/>" }) -join "`n    "
$script:XamlText = $script:XamlText.Replace('<!--BRUSHES-->', $brushXml)
$script:ResourcesText = [regex]::Match($script:XamlText, '<Window\.Resources>.*?</Window\.Resources>', 'Singleline').Value
[xml]$xaml = $script:XamlText

try {
    $script:App = New-Object System.Windows.Application
    $script:App.ShutdownMode = 'OnExplicitShutdown'

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $script:Window = $window

    $names = 'Logo','BtnExport','BtnScanAll','AdminWarning','NumPrograms','NumWU','NumDrivers','NumHealth','Tabs',
             'ChkShowIgnored','BtnProgSelectAll','BtnProgUpdateSel','BtnProgUpdateAll','BtnProgSkip','BtnProgIgnore','BtnStore','GridPrograms',
             'BtnWUSelectAll','BtnWUInstall','BtnWUSettings','GridWU',
             'ChkShowGeneric','BtnDevMgr','BtnDrvBackup','BtnDrvRestore','GridDevices',
             'BtnHealthScan','BtnDefender','BtnSecurity','GridHealth',
             'CleanTotal','BtnCleanScan','BtnCleanRun','GridClean',
             'TabProgress','TaskHeader','BtnCancel','BtnClearTasks','GridTasks','GridHistory',
             'ChkStartup','ChkCloseToTray','ChkNotify','CmbAutoCheck','ChkRestorePoint','BtnOpenRestore',
             'InstallInfo','BtnInstallApp','BtnOpenData','AboutText','Busy','StatusText','LastScan',
             'BtnProgAuto','BtnRollback','TabStartup','BootInfo','BtnStartupScan','BtnTaskMgr','GridStartup',
             'TabApps','AppsInfo','TxtAppSearch','BtnUninstall','BtnAppsScan','BtnAppsSettings','GridApps',
             'TabMyPC','BtnCopySpecs','BtnPcScan','BtnBatteryReport','GridSpecs','GridTemps',
             'ChkGameMode','TxtGames','ChkTempAlert','BtnUpdateFromZip','BtnCheckAppUpdate','ChkAppUpdates',
             'CmbTheme','BtnTheme','ThemeIcon','AboutLogo','AboutTitle','BtnGitHub','BtnLicense','BtnReport','BtnUninstallApp','ExpAdvanced',
             'TabHome','NavList','PageTitle','GameDot','GameChipText','VersionText','ScoreArc','ScoreText','ScoreTitle','ScoreSub',
             'BtnHomeUpdate','BtnHomeClean','CardProg','CardWU','CardDrv','CardHealth','SubPrograms','SubWU','SubDrivers','SubHealth',
             'TodoCount','TodoList','TodoEmpty','MiniTemps','MiniStab',
             'BadgeProgBox','BadgeProg','BadgeWUBox','BadgeWU','BadgeDevBox','BadgeDev','BadgeHealthBox','BadgeHealth','BadgeTaskBox','BadgeTask','RootGrid','BtnWinMin','BtnWinMax','BtnWinClose','MaxIcon'
    foreach ($n in $names) { Set-Variable -Scope Script -Name $n -Value $window.FindName($n) }

    $script:LogoImage = $null
    if (Test-Path $script:IconPath) {
        try {
            $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder([Uri]$script:IconPath, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $big = $dec.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
            $window.Icon = $big; $script:Logo.Source = $big; $script:AboutLogo.Source = $big; $script:LogoImage = $big
        } catch { Write-ErrorLog "icono: $_" }
    }

    # ---------- Estado ----------
    $script:ProgramItems = New-Object 'System.Collections.Generic.List[RevixPC.ProgramItem]'
    $script:WUItems      = New-Object 'System.Collections.Generic.List[RevixPC.UpdateItem]'
    $script:CleanItems   = New-Object 'System.Collections.Generic.List[RevixPC.CleanItem]'
    $script:Tasks        = New-Object 'System.Collections.ObjectModel.ObservableCollection[RevixPC.TaskItem]'
    $script:WUUpdates    = @()
    $script:RawDevices   = @()
    $script:DeviceItems  = @()
    $script:HealthRows   = @()
    $script:Scanned      = @{ Programs = $false; WU = $false; Devices = $false; Health = $false; Clean = $false }
    $script:Running      = @{}
    $script:Jobs         = New-Object System.Collections.ArrayList
    $script:AutoRound    = $false
    $script:ReallyExit   = $false
    $script:TrayTipShown = $false
    $script:InitialScanDone = $false
    $script:PendingNext  = ''

    foreach ($c in Get-CleanCategories) {
        $ci = New-Object RevixPC.CleanItem
        $ci.Key = $c.Key; $ci.Name = $c.Name; $ci.Note = $c.Note; $ci.Selected = [bool]$c.Default; $ci.SizeText = '...'; $ci.Bytes = 0
        $script:CleanItems.Add($ci)
    }

    # Ventana de aviso con el diseño de la app (reemplaza a los avisos grises de Windows)
    function Show-Msg([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK', $owner = $null) {
        $kinds = @{ Information = @('i', '#3B7BF6'); Warning = @('!', '#F59E0B'); Error = @('×', '#EF4444'); Question = @('?', '#3B7BF6') }
        $k = $kinds[$icon]; if (-not $k) { $k = $kinds['Information'] }
        try {
            $dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        SizeToContent="Height" Width="500" ShowInTaskbar="False" Title="Revix PC"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13.5" Foreground="{DynamicResource Fg}">
  $($script:ResourcesText)
  <Border x:Name="Card" Margin="18" Background="{DynamicResource BgCard}" BorderBrush="{DynamicResource BorderControl}" BorderThickness="1" CornerRadius="14">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="4" Opacity="0.45" Color="#000000"/></Border.Effect>
    <StackPanel Margin="24,22,24,20">
      <StackPanel Orientation="Horizontal">
        <Grid Width="40" Height="40">
          <Ellipse Fill="$($k[1])" Opacity="0.18"/>
          <TextBlock Text="$($k[0])" Foreground="$($k[1])" FontSize="20" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <TextBlock Text="Revix PC" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center" Margin="14,0,0,0"/>
      </StackPanel>
      <ScrollViewer MaxHeight="380" VerticalScrollBarVisibility="Auto" Margin="0,16,0,0">
        <TextBlock x:Name="MsgText" TextWrapping="Wrap" Foreground="{DynamicResource FgSoft}" LineHeight="20"/>
      </ScrollViewer>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
        <Button x:Name="BtnNo" Style="{StaticResource Btn}" Margin="0,0,10,0" MinWidth="96"/>
        <Button x:Name="BtnYes" Style="{StaticResource BtnPrimary}" Margin="0" MinWidth="96" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
            $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dx)))
            Apply-Theme $dlg
            $dlg.FindName('MsgText').Text = $text
            $by = $dlg.FindName('BtnYes'); $bn = $dlg.FindName('BtnNo')
            if ($buttons -eq 'YesNo') {
                $by.Content = 'Sí'; $bn.Content = 'No'; $bn.IsCancel = $true
                $script:MsgResult = 'No'
            } else {
                $by.Content = 'Aceptar'; $by.IsCancel = $true; $bn.Visibility = 'Collapsed'
                $script:MsgResult = 'OK'
            }
            $script:MsgDialog = $dlg
            $by.Add_Click({ if ($script:MsgDialog.FindName('BtnNo').Visibility -eq 'Visible') { $script:MsgResult = 'Yes' } else { $script:MsgResult = 'OK' }; $script:MsgDialog.Close() })
            $bn.Add_Click({ $script:MsgResult = 'No'; $script:MsgDialog.Close() })
            $dlg.FindName('Card').Add_MouseLeftButtonDown({ try { $script:MsgDialog.DragMove() } catch {} })
            if (-not $owner -and $script:Window -and $script:Window.IsVisible) { $owner = $script:Window }
            if ($owner) { $dlg.Owner = $owner; $dlg.WindowStartupLocation = 'CenterOwner' }
            else { $dlg.WindowStartupLocation = 'CenterScreen'; $dlg.Topmost = $true }
            [void]$dlg.ShowDialog()
            return $script:MsgResult
        } catch {
            Write-ErrorLog "aviso: $_"
            return [string][System.Windows.MessageBox]::Show($text, $script:AppName, [System.Windows.MessageBoxButton]$buttons, [System.Windows.MessageBoxImage]$icon)
        }
    }

    # Bienvenida: licencias, responsabilidad y privacidad. Devuelve $true si la persona acepta.
    function Show-Welcome([bool]$willInstall) {
        $dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        SizeToContent="Height" Width="600" Title="Revix PC" Topmost="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13.5" Foreground="{DynamicResource Fg}">
  $($script:ResourcesText)
  <Border x:Name="Card" Margin="18" Background="{DynamicResource BgCard}" BorderBrush="{DynamicResource BorderControl}" BorderThickness="1" CornerRadius="14">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="4" Opacity="0.45" Color="#000000"/></Border.Effect>
    <StackPanel Margin="28,24,28,22">
      <StackPanel Orientation="Horizontal">
        <Image x:Name="WLogo" Width="44" Height="44" Margin="0,0,14,0"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Bienvenido a Revix PC" FontSize="20" FontWeight="Bold"/>
          <TextBlock x:Name="WVer" Foreground="{DynamicResource FgMuted}"/>
        </StackPanel>
      </StackPanel>
      <TextBlock TextWrapping="Wrap" Margin="0,18,0,4" Foreground="{DynamicResource FgSoft}" LineHeight="20"
                 Text="Revix PC revisa y actualiza tus programas, Windows Update y drivers, y te muestra la salud de tu PC. Antes de empezar, lee esto:"/>
      <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{DynamicResource FgSoft}" LineHeight="20"><Run FontWeight="SemiBold" Foreground="{DynamicResource Fg}" Text="Licencias. "/><Run Text="Para actualizar programas, Revix PC usa winget (de Microsoft), que acepta en tu nombre los acuerdos de licencia de cada programa y de sus fuentes. Si no estás de acuerdo con la licencia de un programa, no lo actualices desde aquí."/></TextBlock>
      <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{DynamicResource FgSoft}" LineHeight="20"><Run FontWeight="SemiBold" Foreground="{DynamicResource Fg}" Text="Responsabilidad. "/><Run Text="Revix PC es gratis y de código abierto (licencia MIT). Se ofrece tal cual, sin garantía. Úsala bajo tu responsabilidad y ten copia de tus archivos importantes."/></TextBlock>
      <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{DynamicResource FgSoft}" LineHeight="20"><Run FontWeight="SemiBold" Foreground="{DynamicResource Fg}" Text="Privacidad. "/><Run Text="No envía tus datos a nadie. Solo se conecta a Microsoft, a NVIDIA (si tienes tarjeta NVIDIA) y a GitHub (para buscar versiones nuevas)."/></TextBlock>
      <TextBlock x:Name="WInstall" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{DynamicResource FgSoft}" LineHeight="20"><Run FontWeight="SemiBold" Foreground="{DynamicResource Fg}" Text="Instalación. "/><Run Text="Se instalará en Archivos de programa, con accesos directos en el Escritorio y el menú Inicio. Para quitarla: Configuración &gt; Aplicaciones &gt; Revix PC."/></TextBlock>
      <CheckBox x:Name="WChk" Content="Entiendo y acepto" Margin="0,18,0,0" FontWeight="SemiBold"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="WNo" Content="Salir" Style="{StaticResource Btn}" Margin="0,0,10,0" MinWidth="96" IsCancel="True"/>
        <Button x:Name="WYes" Content="Aceptar y empezar" Style="{StaticResource BtnPrimary}" Margin="0" MinWidth="140" IsEnabled="False"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
        try {
            $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dx)))
            Apply-Theme $dlg
            $script:WelcomeDialog = $dlg
            $script:WelcomeOk = $false
            if ($script:LogoImage) { $dlg.FindName('WLogo').Source = $script:LogoImage }
            $dlg.FindName('WVer').Text = "Versión $($script:AppVersion)  ·  Hecho por Marco11"
            if (-not $willInstall) { $dlg.FindName('WInstall').Visibility = 'Collapsed' }
            $dlg.FindName('WChk').Add_Click({ $script:WelcomeDialog.FindName('WYes').IsEnabled = [bool]$script:WelcomeDialog.FindName('WChk').IsChecked })
            $dlg.FindName('WYes').Add_Click({ $script:WelcomeOk = $true; $script:WelcomeDialog.Close() })
            $dlg.FindName('WNo').Add_Click({ $script:WelcomeDialog.Close() })
            $dlg.FindName('Card').Add_MouseLeftButtonDown({ try { $script:WelcomeDialog.DragMove() } catch {} })
            if ($script:Window.IsVisible) { $dlg.Owner = $script:Window; $dlg.WindowStartupLocation = 'CenterOwner' } else { $dlg.WindowStartupLocation = 'CenterScreen' }
            [void]$dlg.ShowDialog()
            return $script:WelcomeOk
        } catch {
            Write-ErrorLog "bienvenida: $_"
            return ((Show-Msg "Revix PC usa winget, que acepta en tu nombre las licencias de los programas que actualizas. Es gratis (licencia MIT), se ofrece sin garantía y la usas bajo tu responsabilidad. No envía tus datos.`n`n¿Aceptas?" 'Question' 'YesNo') -eq 'Yes')
        }
    }

    # ---------- Bandeja (junto al reloj) ----------
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    try { $script:TrayIcon.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application }
    $script:TrayIcon.Text = 'Revix PC'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Abrir Revix PC', $null, { Show-Main })
    [void]$menu.Items.Add('Escanear ahora', $null, { Start-ScanAll })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add('Salir', $null, { Exit-App })
    $script:TrayIcon.ContextMenuStrip = $menu
    $script:TrayIcon.Add_DoubleClick({ Show-Main })
    $script:TrayIcon.Add_BalloonTipClicked({ Show-Main })
    $script:TrayIcon.Visible = $true

    function Show-Notify([string]$title, [string]$text) {
        if (-not $script:Config.Notify) { return }
        if (Test-GameMode) { $script:QueuedNotify = @{ Title = $title; Text = $text }; return }
        try { $script:TrayIcon.ShowBalloonTip(8000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }

    function Show-Main {
        if (-not $script:Window.IsVisible) { $script:Window.Show() }
        if ($script:Window.WindowState -eq 'Minimized') { $script:Window.WindowState = 'Normal' }
        [void]$script:Window.Activate()
        if ($script:PendingAppUpdate -and -not (Test-GameMode)) {
            $script:Window.Dispatcher.BeginInvoke([Action]{ Offer-AppUpdate $script:PendingAppUpdate }) | Out-Null
        }
    }

    function Exit-App {
        if ($script:Exiting) { return }
        $script:Exiting = $true
        $script:ReallyExit = $true
        try { $script:Timer.Stop() } catch {}
        try { $script:AutoTimer.Stop() } catch {}
        try { $script:TempTimer.Stop() } catch {}
        foreach ($e in @($script:Jobs)) { try { Stop-Job $e.Job -ErrorAction SilentlyContinue; Remove-Job $e.Job -Force -ErrorAction SilentlyContinue } catch {} }
        try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch {}
        try { $script:Window.Close() } catch {}
        $script:App.Shutdown()
    }

    # ---------- Segundo plano ----------
    $script:ScanKinds = 'Programs', 'WU', 'Devices', 'Health', 'Clean'
    $script:WorkKinds = 'ProgInstall', 'WUInstall', 'Restore', 'DrvBackup', 'DrvRestore', 'Rollback', 'CleanRun'

    function Test-AnyRunning([string[]]$kinds) {
        foreach ($k in $kinds) { if ($script:Running[$k]) { return $true } }
        return $false
    }

    function Update-Busy {
        $labels = @($script:Jobs | ForEach-Object { $_.Label } | Where-Object { $_ })
        if ($labels.Count -gt 0) {
            $script:Busy.Visibility = 'Visible'
            $script:StatusText.Text = ($labels -join '  ·  ') + '...'
        } else {
            $script:Busy.Visibility = 'Collapsed'
            $script:StatusText.Text = 'Listo'
        }
        $script:BtnScanAll.IsEnabled = -not (Test-AnyRunning @('Programs', 'WU', 'Devices', 'Health'))
        $script:BtnCancel.IsEnabled = Test-AnyRunning @('ProgInstall', 'WUInstall', 'CleanRun', 'Rollback')
        if (Test-AnyRunning $script:WorkKinds) { $script:BadgeTask.Text = '•••'; $script:BadgeTaskBox.Visibility = 'Visible' }
        else { $script:BadgeTaskBox.Visibility = 'Collapsed' }

        if ($script:AutoRound -and -not (Test-AnyRunning @('Programs', 'WU', 'Devices'))) {
            $script:AutoRound = $false
            $p = @($script:ProgramItems | Where-Object { -not $_.Hidden }).Count
            $w = @($script:WUItems | Where-Object { -not $_.IsDriver }).Count
            $d = @($script:WUItems | Where-Object { $_.IsDriver }).Count + (Get-NvidiaNewCount)
            $total = $p + $w + $d
            if ($total -gt 0 -and -not $script:Window.IsVisible) {
                Show-Notify 'Hay actualizaciones disponibles' "Programas: $p   ·   Windows: $w   ·   Drivers: $d"
            }
        }
        Update-TrayText
    }

    function Update-TrayText {
        $p = @($script:ProgramItems | Where-Object { -not $_.Hidden }).Count
        $w = @($script:WUItems).Count
        $t = 'Revix PC'
        if ($script:Scanned.Programs -or $script:Scanned.WU) { $t = "Revix PC - $($p + $w) pendientes" }
        try { $script:TrayIcon.Text = $t } catch {}
    }

    function Start-Bg([string]$Kind, [string]$Label, [scriptblock]$Script, [object[]]$Arguments, [scriptblock]$OnDone, [scriptblock]$OnProgress) {
        if ($script:Running[$Kind]) { return $false }
        $script:Running[$Kind] = $true
        $p = @{ ScriptBlock = $Script; InitializationScript = $script:InitScript }
        if ($Arguments -and $Arguments.Count -gt 0) { $p.ArgumentList = $Arguments }
        $job = Start-Job @p
        [void]$script:Jobs.Add(@{ Job = $job; Kind = $Kind; Label = $Label; OnDone = $OnDone; OnProgress = $OnProgress
                                  Output = (New-Object System.Collections.ArrayList); Errors = (New-Object System.Collections.ArrayList) })
        Update-Busy
        return $true
    }

    function Receive-Partial($entry) {
        $errs = $null
        $new = @(Receive-Job $entry.Job -ErrorAction SilentlyContinue -ErrorVariable errs)
        foreach ($e in @($errs)) { if ($e) { [void]$entry.Errors.Add($e) } }
        foreach ($o in $new) {
            [void]$entry.Output.Add($o)
            if ($entry.OnProgress) {
                try { & $entry.OnProgress $o } catch { Write-ErrorLog "OnProgress $($entry.Kind): $_" }
            }
        }
    }

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:Timer.Add_Tick({
        if ($script:ShowEvent) { try { if ($script:ShowEvent.WaitOne(0)) { Show-Main } } catch {} }
        if ($script:ExitEvent) { try { if ($script:ExitEvent.WaitOne(0)) { Exit-App; return } } catch {} }
        $script:TickCount++
        if ($script:TickCount % 38 -eq 0) { Check-Deferred }
        foreach ($entry in @($script:Jobs)) {
            $j = $entry.Job
            $st = [string]$j.State
            if ($st -eq 'Running' -and $entry.OnProgress) { Receive-Partial $entry; continue }
            if ($st -ne 'Completed' -and $st -ne 'Failed' -and $st -ne 'Stopped') { continue }
            $script:Jobs.Remove($entry)
            Receive-Partial $entry
            $errText = ''
            try { $reason = $j.ChildJobs[0].JobStateInfo.Reason; if ($reason) { $errText = $reason.Message } } catch {}
            if (-not $errText -and $st -eq 'Failed' -and $entry.Errors.Count -gt 0) { $errText = ($entry.Errors[0] | Out-String).Trim() }
            Remove-Job $j -Force -ErrorAction SilentlyContinue
            $script:Running[$entry.Kind] = $false
            try { & $entry.OnDone @($entry.Output) $errText }
            catch { Write-ErrorLog "OnDone $($entry.Kind): $_"; Add-History 'Error interno' $_.Exception.Message }
            Update-Busy
        }
    })
    $script:Timer.Start()

    # ---------- Tareas (pestaña Progreso) ----------
    function Add-TaskRow([string]$key, [string]$name) {
        $t = New-Object RevixPC.TaskItem
        $t.Key = $key; $t.Name = $name; $t.StatusText = 'En cola'; $t.StatusColor = $script:C.Gray; $t.Detail = ''
        $script:Tasks.Add($t)
    }
    function Set-TaskRow([string]$key, [string]$status, [string]$color, [string]$detail) {
        foreach ($t in $script:Tasks) {
            if ($t.Key -eq $key -and ($t.StatusText -eq 'En cola' -or $t.StatusText -like '*...')) {
                $t.StatusText = $status; $t.StatusColor = $color
                if ($null -ne $detail) { $t.Detail = $detail }
                break
            }
        }
        $script:GridTasks.Items.Refresh()
    }
    function Set-QueuedCancelled {
        foreach ($t in $script:Tasks) { if ($t.StatusText -eq 'En cola') { $t.StatusText = 'Cancelado'; $t.StatusColor = $script:C.Gray } }
        $script:GridTasks.Items.Refresh()
    }
    function Reset-Cancel { try { Remove-Item (Get-CancelFile) -Force -ErrorAction SilentlyContinue } catch {} }
    function Show-ProgressTab([string]$header) {
        $script:TaskHeader.Text = $header
        $script:Tabs.SelectedItem = $script:TabProgress
    }

    # ---------- Refrescar vistas ----------
    function Update-Summary {
        if ($script:Scanned.Programs) { $script:NumPrograms.Text = [string]@($script:ProgramItems | Where-Object { -not $_.Hidden }).Count }
        if ($script:Scanned.WU) {
            $script:NumWU.Text      = [string]@($script:WUItems | Where-Object { -not $_.IsDriver }).Count
            $script:NumDrivers.Text = [string](@($script:WUItems | Where-Object { $_.IsDriver }).Count + (Get-NvidiaNewCount))
        }
        if ($script:Scanned.Health) { $script:NumHealth.Text = [string]@($script:HealthRows | Where-Object { $_.Level -ge 1 }).Count }
        Update-Home
    }

    function Refresh-Programs {
        $script:GridPrograms.ItemsSource = @($script:ProgramItems | Where-Object { $script:ChkShowIgnored.IsChecked -or -not $_.Hidden })
    }
    function Refresh-WU { $script:GridWU.ItemsSource = @($script:WUItems) }
    function Refresh-Devices {
        $script:GridDevices.ItemsSource = @($script:DeviceItems | Where-Object { $script:ChkShowGeneric.IsChecked -or -not $_.IsGeneric })
    }
    function Refresh-Clean {
        $script:GridClean.ItemsSource = $null
        $script:GridClean.ItemsSource = @($script:CleanItems)
        $sum = 0.0
        foreach ($c in $script:CleanItems) { if ($c.Selected -and $c.Bytes -gt 0) { $sum += $c.Bytes } }
        if ($script:Scanned.Clean) { $script:CleanTotal.Text = 'Se pueden liberar: ' + (Format-Bytes $sum) } else { $script:CleanTotal.Text = '' }
    }
    function Rebuild-Devices {
        if (-not $script:Scanned.Devices) { return }
        $script:DeviceItems = ConvertTo-DeviceItems $script:RawDevices $script:WUUpdates
        Refresh-Devices
        Update-Home
    }

    # ---------- Escaneos ----------
    function Scan-Programs {
        [void](Start-Bg 'Programs' 'Buscando programas' $script:JobWingetScan $null {
            param($out, $err)
            if ($err) {
                if ($err -match 'WINGET_NO_ENCONTRADO') { $msg = 'No se encontró winget. Instala "Instalador de aplicación" (App Installer) desde Microsoft Store y vuelve a escanear.' }
                else { $msg = $err }
                $script:NumPrograms.Text = '!'
                Add-History 'Escanear programas' "Error: $msg"
                if ($script:Window.IsVisible) { Show-Msg $msg 'Warning' | Out-Null }
                return
            }
            $script:ProgramItems.Clear()
            $seenIds = @{}
            foreach ($r in $out) {
                if (-not $r.Id -or $seenIds.ContainsKey([string]$r.Id)) { continue }
                $seenIds[[string]$r.Id] = $true
                $p = New-Object RevixPC.ProgramItem
                $p.Name = [string]$r.Name; $p.Id = [string]$r.Id; $p.Version = [string]$r.Version
                $p.Available = [string]$r.Available; $p.Source = [string]$r.Source
                if ($p.Source -eq 'msstore') { $p.Source = 'Store' }
                $p.Ignored = $script:IgnoredIds.Contains($p.Id)
                $p.Skipped = ($script:Skipped.ContainsKey($p.Id) -and $script:Skipped[$p.Id] -eq $p.Available)
                $p.Auto = $script:AutoUpdateIds.Contains($p.Id)
                $script:ProgramItems.Add($p)
            }
            if ($script:ProgramItems.Count -gt 0) {
                foreach ($k in @($script:Skipped.Keys)) {
                    $still = $script:ProgramItems | Where-Object { $_.Id -eq $k -and $_.Available -eq $script:Skipped[$k] }
                    if (-not $still) { $script:Skipped.Remove($k) }
                }
            }
            Save-Config
            $script:Scanned.Programs = $true
            Refresh-Programs; Update-Summary
            $n = @($script:ProgramItems | Where-Object { -not $_.Hidden }).Count
            Add-History 'Escanear programas' "$n con actualización"
            $script:LastScan.Text = 'Último escaneo: ' + (Get-Date).ToString('dd/MM/yyyy HH:mm')
            if ($script:AutoRound) { Start-AutoUpdates }
        })
    }

    function Scan-WU {
        [void](Start-Bg 'WU' 'Buscando en Windows Update' $script:JobWUScan $null {
            param($out, $err)
            if ($err) {
                $script:NumWU.Text = '!'; $script:NumDrivers.Text = '!'
                if ($err -match '8024402C|80072EE7|80072EFD|80072EE2|8024401C') { $err = 'Sin conexión a internet o Windows Update no responde. Se volverá a intentar en la próxima revisión.' }
                $script:SubWU.Text = 'No se pudo revisar'
                Add-History 'Escanear Windows Update' "Error: $err"
                return
            }
            $script:WUUpdates = @($out)
            $script:WUItems.Clear()
            foreach ($u in $script:WUUpdates) {
                $it = New-Object RevixPC.UpdateItem
                $it.Title = [string]$u.Title; $it.UpdateId = [string]$u.UpdateId; $it.KB = [string]$u.KB
                $it.IsDriver = [bool]$u.IsDriver; $it.Kind = Get-UpdateKind $u
                $it.Severity = Get-SeverityText ([string]$u.Severity)
                if ([double]$u.SizeMB -gt 0) { $it.Size = ('{0:N1} MB' -f [double]$u.SizeMB) } else { $it.Size = '' }
                $script:WUItems.Add($it)
            }
            $script:Scanned.WU = $true
            Refresh-WU; Update-Summary; Rebuild-Devices
            $nw = @($script:WUItems | Where-Object { -not $_.IsDriver }).Count
            $nd = @($script:WUItems | Where-Object { $_.IsDriver }).Count
            Add-History 'Escanear Windows Update' "$nw de Windows, $nd drivers"
        })
    }

    function Scan-Devices {
        [void](Start-Bg 'Devices' 'Revisando dispositivos' $script:JobDeviceScan $null {
            param($out, $err)
            if ($err) { Add-History 'Revisar dispositivos' "Error: $err"; return }
            $script:RawDevices = @($out)
            $script:Scanned.Devices = $true
            Rebuild-Devices
            Add-History 'Revisar dispositivos' ("{0} dispositivos revisados" -f $script:DeviceItems.Count)
            Check-Nvidia
        })
    }

    function Scan-Health {
        [void](Start-Bg 'Health' 'Revisando salud y seguridad' $script:JobHealth $null {
            param($out, $err)
            if ($err) { $script:NumHealth.Text = '!'; Add-History 'Revisar salud' "Error: $err"; return }
            $script:HealthRows = ConvertTo-HealthRows @($out)
            $script:Scanned.Health = $true
            $script:GridHealth.ItemsSource = @($script:HealthRows)
            Update-Summary
            $n = @($script:HealthRows | Where-Object { $_.Level -ge 1 }).Count
            Add-History 'Revisar salud y seguridad' "$n aviso(s)"
        })
    }

    function Scan-Clean {
        if (Test-AnyRunning @('CleanRun')) { return }
        foreach ($c in $script:CleanItems) { $c.SizeText = 'Calculando...' }
        Refresh-Clean
        [void](Start-Bg 'Clean' 'Calculando espacio a liberar' $script:JobCleanScan $null {
            param($out, $err)
            foreach ($r in $out) {
                $ci = $script:CleanItems | Where-Object { $_.Key -eq $r.Key } | Select-Object -First 1
                if ($ci) { $ci.Bytes = [double]$r.Bytes; $ci.SizeText = Format-Bytes ([double]$r.Bytes) }
            }
            $script:Scanned.Clean = $true
            Refresh-Clean
        })
    }

    function Start-ScanAll {
        Scan-Programs; Scan-WU; Scan-Devices; Scan-Health; Scan-Clean
        $script:InitialScanDone = $true
    }

    # ---------- Punto de restauracion y luego la tarea ----------
    function Invoke-WithRestorePoint([string]$next) {
        $script:PendingNext = $next
        if (-not $script:Config.RestorePoint) { Continue-Pending; return }
        Add-TaskRow 'restore' 'Punto de restauración'
        if (-not $script:IsAdmin) {
            Set-TaskRow 'restore' 'Omitido' $script:C.Gray 'Hace falta abrir la app como administrador'
            Continue-Pending; return
        }
        Start-RestorePoint $false
    }

    function Start-RestorePoint([bool]$allowEnable) {
        Set-TaskRow 'restore' 'Creando...' $script:C.Amber 'Puede tardar un minuto'
        [void](Start-Bg 'Restore' 'Creando punto de restauración' $script:JobRestorePoint @('Revix PC - antes de actualizar', $allowEnable) {
            param($out, $err)
            $r = $out | Select-Object -Last 1
            if (-not $err -and $r -and $r.NeedEnable) {
                $ans = Show-Msg "La protección del sistema está apagada en la unidad $env:SystemDrive, así que no se pueden crear puntos de restauración.`n`n¿Quieres que Revix PC la encienda? Usa algo de espacio del disco (Windows lo administra solo) y te permite deshacer cambios con 'Restaurar sistema'." 'Question' 'YesNo'
                if ($ans -eq 'Yes') { Start-RestorePoint $true; return }
                Set-TaskRow 'restore' 'Omitido' $script:C.Gray 'La protección del sistema está apagada'
                Add-History 'Punto de restauración' 'Omitido: protección del sistema apagada'
                $ans2 = Show-Msg '¿Continuar sin punto de restauración?' 'Warning' 'YesNo'
                if ($ans2 -ne 'Yes') { Set-QueuedCancelled; $script:TaskHeader.Text = 'Cancelado'; return }
                Continue-Pending; return
            }
            if ($err) {
                Set-TaskRow 'restore' 'No se pudo' $script:C.Red $err
                Add-History 'Punto de restauración' "Error: $err"
                $ans = Show-Msg "No se pudo crear el punto de restauración:`n$err`n`n¿Continuar sin él?" 'Warning' 'YesNo'
                if ($ans -ne 'Yes') { Set-QueuedCancelled; $script:TaskHeader.Text = 'Cancelado'; return }
            } else {
                $d = ''; if ($r -and $r.Enabled) { $d = "Se encendió la protección del sistema en $env:SystemDrive" }
                Set-TaskRow 'restore' 'Creado' $script:C.Green $d
                Add-History 'Punto de restauración' ('Creado ' + $d).Trim()
            }
            Continue-Pending
        })
    }

    function Continue-Pending {
        switch ($script:PendingNext) {
            'Prog'       { Start-ProgInstall }
            'WU'         { Start-WUInstallJob }
            'DrvRestore' { Start-DriverRestore }
        }
    }

    # ---------- Programas ----------
    function Update-Programs($items) {
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg 'Espera a que termine la tarea actual (mira la pestaña Progreso).' | Out-Null; return }
        $items = @($items | Where-Object { -not $_.Hidden })
        if ($items.Count -eq 0) { Show-Msg 'No hay programas marcados para actualizar.' | Out-Null; return }
        $names = ($items | Select-Object -First 12 | ForEach-Object { '  • ' + $_.Name }) -join "`n"
        if ($items.Count -gt 12) { $names += "`n  ... y $($items.Count - 12) más" }
        $ans = Show-Msg "Se actualizarán $($items.Count) programa(s):`n`n$names`n`nCierra esos programas antes de continuar. Al seguir, se aceptan las licencias de esos programas. ¿Seguir?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        Prepare-ProgInstall $items
        $script:SilentInstall = $false
        $script:Tasks.Clear(); Reset-Cancel
        Show-ProgressTab "Actualizando $($items.Count) programa(s)"
        Invoke-WithRestorePoint 'Prog'
    }

    function Prepare-ProgInstall($items) {
        $script:PendingProgIds = [string[]]@($items | ForEach-Object { $_.Id })
        $script:NameById = @{}; $script:PendingFrom = @{}
        foreach ($i in $items) {
            $script:NameById[$i.Id] = $i.Name
            $script:PendingFrom[$i.Id] = @{ From = $i.Version; To = $i.Available }
        }
    }

    function Start-AutoUpdates {
        if (Test-AnyRunning $script:WorkKinds) { return }
        if (Test-GameMode) { return }
        $items = @($script:ProgramItems | Where-Object { $_.Auto -and -not $_.Hidden })
        if ($items.Count -eq 0) { return }
        Prepare-ProgInstall $items
        $script:SilentInstall = $true
        $script:Tasks.Clear(); Reset-Cancel
        $script:TaskHeader.Text = "Actualización automática de $($items.Count) programa(s)"
        Start-ProgInstall
    }

    function Start-ProgInstall {
        foreach ($id in $script:PendingProgIds) { Add-TaskRow $id $script:NameById[$id] }
        [void](Start-Bg 'ProgInstall' "Actualizando programas" $script:JobWingetUpgrade @(, $script:PendingProgIds) {
            param($out, $err)
            if ($err) {
                Add-History 'Actualizar programas' "Error: $err"
                Set-QueuedCancelled
                Show-Msg $err 'Warning' | Out-Null; return
            }
            $done = @($out | Where-Object { $_.Kind -eq 'done' })
            $ok = @($done | Where-Object { [int]$_.ExitCode -eq 0 }).Count
            $bad = $done.Count - $ok
            $msg = "Actualizados: $ok"
            if ($bad -gt 0) { $msg += "   ·   Con problemas: $bad" }
            if ($out | Where-Object { $_.Kind -eq 'cancel' }) { $msg += '   ·   Cancelado' }
            $script:TaskHeader.Text = $msg
            if ($script:SilentInstall) {
                $names = @($done | Where-Object { [int]$_.ExitCode -eq 0 } | ForEach-Object { $script:NameById[[string]$_.Key] }) -join ', '
                if ($names) { Show-Notify 'Programas actualizados automáticamente' $names }
                $script:SilentInstall = $false
            } elseif (-not $script:Window.IsVisible) { Show-Notify 'Actualización terminada' $msg }
            Scan-Programs
        } {
            param($o)
            $name = $script:NameById[[string]$o.Key]; if (-not $name) { $name = $o.Key }
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key 'Instalando...' $script:C.Amber 'Descargando e instalando' }
                'done'   {
                    if ([int]$o.ExitCode -eq 0) {
                        Set-TaskRow $o.Key 'Correcto' $script:C.Green ''
                        $fv = $script:PendingFrom[[string]$o.Key]
                        if ($fv -and $fv.From -and $fv.From -notmatch '^(Unknown|Desconocid|<)' -and $fv.From -ne $fv.To) {
                            $script:PrevVersions[[string]$o.Key] = @{ Name = $name; From = [string]$fv.From; To = [string]$fv.To; Date = (Get-Date).ToString('dd/MM/yyyy HH:mm') }
                            Save-Config
                            Add-History "Actualizar $name" "Correcto ($($fv.From) -> $($fv.To))"
                        } else { Add-History "Actualizar $name" 'Correcto' }
                    }
                    else {
                        $d = (Get-WingetCodeText ([int]$o.ExitCode)); if ($o.Message) { $d += ' - ' + $o.Message }
                        Set-TaskRow $o.Key 'Error' $script:C.Red $d; Add-History "Actualizar $name" "Error: $d"
                    }
                }
                'cancel' { Set-QueuedCancelled }
            }
        })
    }

    $script:BtnProgSelectAll.Add_Click({
        $view = @($script:GridPrograms.ItemsSource)
        $allOn = (@($view | Where-Object { -not $_.Selected }).Count -eq 0)
        foreach ($p in $view) { $p.Selected = -not $allOn }
        $script:GridPrograms.Items.Refresh()
    })
    $script:BtnProgUpdateSel.Add_Click({ Update-Programs @($script:ProgramItems | Where-Object { $_.Selected }) })
    $script:BtnProgUpdateAll.Add_Click({ Update-Programs @($script:ProgramItems) })
    $script:BtnProgIgnore.Add_Click({
        $sel = @($script:ProgramItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg 'Marca primero los programas que quieres ignorar siempre (o dejar de ignorar).' | Out-Null; return }
        foreach ($p in $sel) {
            if ($p.Ignored) { $p.Ignored = $false; [void]$script:IgnoredIds.Remove($p.Id); Add-History "Dejar de ignorar $($p.Name)" '' }
            else { $p.Ignored = $true; if (-not $script:IgnoredIds.Contains($p.Id)) { $script:IgnoredIds.Add($p.Id) }; Add-History "Ignorar $($p.Name)" 'No se mostrará más' }
            $p.Selected = $false
        }
        Save-Config; Refresh-Programs; Update-Summary; Update-TrayText
    })
    $script:BtnProgSkip.Add_Click({
        $sel = @($script:ProgramItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg 'Marca los programas cuya versión nueva quieres saltar. Volverán a aparecer cuando salga una versión más nueva.' | Out-Null; return }
        foreach ($p in $sel) {
            if ($p.Skipped) { $p.Skipped = $false; [void]$script:Skipped.Remove($p.Id); Add-History "Quitar salto de $($p.Name)" '' }
            else { $p.Skipped = $true; $script:Skipped[$p.Id] = $p.Available; Add-History "Saltar $($p.Name) $($p.Available)" 'Volverá a avisar con la siguiente versión' }
            $p.Selected = $false
        }
        Save-Config; Refresh-Programs; Update-Summary; Update-TrayText
    })
    $script:ChkShowIgnored.Add_Click({ Refresh-Programs })
    $script:BtnStore.Add_Click({
        [void](Start-Bg 'Store' 'Pidiendo a la Store que busque actualizaciones' $script:JobStore $null {
            param($out, $err)
            if ($err) { Add-History 'Actualizar apps de la Store' 'Se abrió la Store para hacerlo manualmente' }
            else { Add-History 'Actualizar apps de la Store' 'La Store está buscando e instalando actualizaciones' }
        })
        Start-Process 'ms-windows-store://downloadsandupdates'
        Show-Msg "Se abrió la Microsoft Store en 'Descargas y actualizaciones'. Pulsa 'Obtener actualizaciones' para actualizar las apps de la Store." | Out-Null
    })

    # ---------- Windows Update ----------
    $script:BtnWUSelectAll.Add_Click({
        $allOn = (@($script:WUItems | Where-Object { -not $_.Selected }).Count -eq 0)
        foreach ($u in $script:WUItems) { $u.Selected = -not $allOn }
        $script:GridWU.Items.Refresh()
    })
    $script:BtnWUSettings.Add_Click({ Start-Process 'ms-settings:windowsupdate' })
    $script:BtnWUInstall.Add_Click({
        if (-not $script:IsAdmin) { Show-Msg 'Para instalar actualizaciones de Windows abre Revix PC como administrador (acepta el aviso de Windows al abrirla).' 'Warning' | Out-Null; return }
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg 'Espera a que termine la tarea actual (mira la pestaña Progreso).' | Out-Null; return }
        $sel = @($script:WUItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg 'Marca primero las actualizaciones que quieres instalar.' | Out-Null; return }
        $ans = Show-Msg "Se descargarán e instalarán $($sel.Count) actualización(es), una por una. Puede tardar y quizá pida reiniciar. ¿Seguir?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:PendingWU = @($sel | ForEach-Object { @{ Id = $_.UpdateId; Title = $_.Title } })
        $script:Tasks.Clear(); Reset-Cancel
        Show-ProgressTab "Instalando $($sel.Count) actualización(es) de Windows"
        Invoke-WithRestorePoint 'WU'
    })

    function Start-WUInstallJob {
        $ids = [string[]]@($script:PendingWU | ForEach-Object { $_.Id })
        foreach ($u in $script:PendingWU) { Add-TaskRow $u.Id $u.Title }
        $script:WUReboot = $false
        [void](Start-Bg 'WUInstall' 'Instalando actualizaciones de Windows' $script:JobWUInstall @(, $ids) {
            param($out, $err)
            if ($err) { Add-History 'Instalar Windows Update' "Error: $err"; Set-QueuedCancelled; Show-Msg "No se pudo instalar:`n$err" 'Warning' | Out-Null; return }
            $done = @($out | Where-Object { $_.Kind -eq 'done' })
            $ok = @($done | Where-Object { $_.Ok }).Count
            $msg = "Instaladas: $ok de $($done.Count)"
            if ($out | Where-Object { $_.Kind -eq 'cancel' }) { $msg += '   ·   Cancelado' }
            $script:TaskHeader.Text = $msg
            if ($script:WUReboot) {
                $ans = Show-Msg "$msg.`n`nWindows necesita reiniciar para terminar. Guarda tu trabajo. ¿Reiniciar ahora?" 'Question' 'YesNo'
                if ($ans -eq 'Yes') { Restart-Computer -Force }
            } elseif (-not $script:Window.IsVisible) { Show-Notify 'Windows Update terminado' $msg }
            Scan-WU; Scan-Health
        } {
            param($o)
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key 'Instalando...' $script:C.Amber 'Descargando e instalando' }
                'done'   {
                    if ($o.Ok) { $col = $script:C.Green } else { $col = $script:C.Red }
                    $d = ''; if ($o.Reboot) { $d = 'Necesita reiniciar'; $script:WUReboot = $true }
                    Set-TaskRow $o.Key $o.Result $col $d
                    $t = $o.Title; if (-not $t) { $t = $o.Key }
                    Add-History "Instalar $t" $o.Result
                }
                'cancel' { Set-QueuedCancelled }
            }
        })
    }

    # ---------- Dispositivos y drivers ----------
    $script:ChkShowGeneric.Add_Click({ Refresh-Devices })
    $script:BtnDevMgr.Add_Click({ Start-Process 'devmgmt.msc' })

    $linkHandler = [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $btn = $e.OriginalSource
        if ($btn -is [System.Windows.Controls.Button] -and $btn.Tag) {
            if ([string]$btn.Tag -eq 'perfmon-rel') { Start-Process 'perfmon.exe' -ArgumentList '/rel' }
            elseif ([string]$btn.Tag -match '^https://') { Start-Process ([string]$btn.Tag) }
        }
    }
    $script:GridDevices.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $linkHandler)
    $script:GridHealth.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $linkHandler)

    $script:BtnDrvBackup.Add_Click({
        if (-not $script:IsAdmin) { Show-Msg 'Para respaldar drivers abre Revix PC como administrador.' 'Warning' | Out-Null; return }
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg 'Espera a que termine la tarea actual.' | Out-Null; return }
        $dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('Revix PC\Respaldo-drivers-' + (Get-Date).ToString('yyyyMMdd-HHmm'))
        $ans = Show-Msg "Se guardará una copia de tus drivers (los que no vienen con Windows) en:`n`n$dest`n`n¿Continuar?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:Tasks.Clear(); Add-TaskRow 'backup' 'Respaldo de drivers'
        Set-TaskRow 'backup' 'Copiando...' $script:C.Amber $dest
        Show-ProgressTab 'Respaldando drivers'
        [void](Start-Bg 'DrvBackup' 'Respaldando drivers' $script:JobDriverBackup @($dest) {
            param($out, $err)
            if ($err) { Set-TaskRow 'backup' 'Error' $script:C.Red $err; Add-History 'Respaldar drivers' "Error: $err"; return }
            $r = $out | Select-Object -First 1
            Set-TaskRow 'backup' 'Listo' $script:C.Green "$($r.Count) drivers en $($r.Dest)"
            $script:TaskHeader.Text = "Respaldo listo: $($r.Count) drivers"
            Add-History 'Respaldar drivers' "$($r.Count) drivers en $($r.Dest)"
            Start-Process explorer.exe $r.Dest
        })
    })

    $script:BtnDrvRestore.Add_Click({
        if (-not $script:IsAdmin) { Show-Msg 'Para restaurar drivers abre Revix PC como administrador.' 'Warning' | Out-Null; return }
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg 'Espera a que termine la tarea actual.' | Out-Null; return }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Elige la carpeta del respaldo de drivers (Respaldo-drivers-...)'
        $def = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Revix PC'
        if (Test-Path $def) { $dlg.SelectedPath = $def }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:PendingDrvFolder = $dlg.SelectedPath
        $infs = @(Get-ChildItem -LiteralPath $script:PendingDrvFolder -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) { Show-Msg 'Esa carpeta no tiene drivers (archivos .inf).' 'Warning' | Out-Null; return }
        $ans = Show-Msg "Se instalarán $($infs.Count) driver(s) desde:`n$($script:PendingDrvFolder)`n`nInstala solo respaldos tuyos o de fuentes de confianza. ¿Continuar?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:Tasks.Clear(); Show-ProgressTab 'Restaurando drivers'
        Invoke-WithRestorePoint 'DrvRestore'
    })

    function Start-DriverRestore {
        Add-TaskRow 'drvrestore' 'Restaurar drivers'
        Set-TaskRow 'drvrestore' 'Instalando...' $script:C.Amber $script:PendingDrvFolder
        [void](Start-Bg 'DrvRestore' 'Restaurando drivers' $script:JobDriverRestore @($script:PendingDrvFolder) {
            param($out, $err)
            if ($err) { Set-TaskRow 'drvrestore' 'Error' $script:C.Red $err; Add-History 'Restaurar drivers' "Error: $err"; return }
            $r = $out | Select-Object -First 1
            $code = [int]$r.ExitCode
            if ($code -eq 0 -or $code -eq 3010) {
                $d = ''; if ($code -eq 3010) { $d = 'Reinicia la PC para terminar' }
                Set-TaskRow 'drvrestore' 'Listo' $script:C.Green $d
                Add-History 'Restaurar drivers' ('Correcto ' + $d)
            } else {
                Set-TaskRow 'drvrestore' "Terminó con código $code" $script:C.Amber 'Algunos drivers pueden no aplicar a este equipo'
                Add-History 'Restaurar drivers' "Código $code"
            }
            $script:TaskHeader.Text = 'Restauración terminada'
            Scan-Devices
        })
    }

    # ---------- Salud ----------
    $script:BtnHealthScan.Add_Click({ Scan-Health })
    $script:BtnSecurity.Add_Click({ Start-Process 'windowsdefender:' })
    $script:BtnDefender.Add_Click({
        [void](Start-Bg 'Defender' 'Actualizando firmas de Defender' $script:JobDefender $null {
            param($out, $err)
            if ($err) { Add-History 'Actualizar firmas de Defender' "Error: $err"; Show-Msg "No se pudo actualizar:`n$err" 'Warning' | Out-Null; return }
            Add-History 'Actualizar firmas de Defender' 'Correcto'
            Scan-Health
        })
    })

    # ---------- Limpieza ----------
    $script:BtnCleanScan.Add_Click({ Scan-Clean })
    $script:GridClean.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.CheckBox]) {
            $sum = 0.0
            foreach ($c in $script:CleanItems) { if ($c.Selected -and $c.Bytes -gt 0) { $sum += $c.Bytes } }
            if ($script:Scanned.Clean) { $script:CleanTotal.Text = 'Se pueden liberar: ' + (Format-Bytes $sum) }
        }
    })
    $script:BtnCleanRun.Add_Click({
        if (Test-AnyRunning ($script:WorkKinds + 'CleanRun')) { Show-Msg 'Espera a que termine la tarea actual.' | Out-Null; return }
        $sel = @($script:CleanItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg 'Marca qué quieres limpiar.' | Out-Null; return }
        $list = ($sel | ForEach-Object { '  • ' + $_.Name + '  (' + $_.SizeText + ')' }) -join "`n"
        $warn = ''
        if ($sel | Where-Object { $_.Key -eq 'RecycleBin' }) { $warn += "`n`nOjo: la papelera se vacía definitivamente." }
        if ($sel | Where-Object { $_.Key -eq 'Components' }) { $warn += "`nLos componentes viejos de Windows tardan varios minutos y después no podrás desinstalar actualizaciones ya instaladas." }
        $ans = Show-Msg "Se limpiará:`n`n$list$warn`n`n¿Continuar?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $keys = [string[]]@($sel | ForEach-Object { $_.Key })
        $script:Tasks.Clear(); Reset-Cancel
        foreach ($c in $sel) { Add-TaskRow $c.Key $c.Name }
        Show-ProgressTab 'Limpiando'
        $script:CleanFreed = 0.0
        [void](Start-Bg 'CleanRun' 'Limpiando' $script:JobClean @(, $keys) {
            param($out, $err)
            if ($err) { Add-History 'Limpieza' "Error: $err"; Set-QueuedCancelled; return }
            $msg = 'Espacio liberado: ' + (Format-Bytes $script:CleanFreed)
            $script:TaskHeader.Text = $msg
            Add-History 'Limpieza' $msg
            Scan-Clean
        } {
            param($o)
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key 'Limpiando...' $script:C.Amber '' }
                'done'   {
                    if ($o.Ok) { $script:CleanFreed += [double]$o.Freed; Set-TaskRow $o.Key 'Listo' $script:C.Green ('Liberado: ' + (Format-Bytes ([double]$o.Freed))) }
                    else { Set-TaskRow $o.Key 'Error' $script:C.Red $o.Message }
                }
                'cancel' { Set-QueuedCancelled }
            }
        })
    })

    # ---------- Progreso ----------
    $script:GridTasks.ItemsSource = $script:Tasks
    $script:BtnCancel.Add_Click({
        try { New-Item -ItemType File -Path (Get-CancelFile) -Force | Out-Null } catch {}
        $script:TaskHeader.Text = 'Cancelando... (se detendrá al terminar el elemento actual)'
        $script:BtnCancel.IsEnabled = $false
    })
    $script:BtnClearTasks.Add_Click({
        if (Test-AnyRunning ($script:WorkKinds + 'CleanRun')) { return }
        $script:Tasks.Clear(); $script:TaskHeader.Text = 'Sin tareas en curso'
    })

    # ---------- Reporte HTML ----------
    $script:BtnExport.Add_Click({
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
        $pill = { param($text, $color) if (-not $text) { return '' }; "<span class='pill' style='background:$color'>$([System.Net.WebUtility]::HtmlEncode([string]$text))</span>" }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Reporte Revix PC</title><style>')
        [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;background:#111318;color:#e5e7eb;margin:32px}h1{margin:0}h2{margin-top:32px;border-bottom:1px solid #2a2f3a;padding-bottom:6px}')
        [void]$sb.Append('.muted{color:#9ca3af}table{border-collapse:collapse;width:100%;margin-top:10px}th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #2a2f3a;font-size:14px}th{color:#9ca3af;background:#1a1d24}')
        [void]$sb.Append('.pill{color:#fff;padding:2px 9px;border-radius:9px;font-size:12.5px;font-weight:600;white-space:nowrap}')
        [void]$sb.Append('</style></head><body>')
        [void]$sb.Append("<h1>Reporte Revix PC</h1><p class='muted'>$($env:COMPUTERNAME) · $((Get-Date).ToString('dd/MM/yyyy HH:mm')) · Revix PC $($script:AppVersion)</p>")

        [void]$sb.Append('<h2>Programas por actualizar</h2>')
        $progs = @($script:ProgramItems | Where-Object { -not $_.Hidden })
        if (-not $script:Scanned.Programs) { [void]$sb.Append("<p class='muted'>No escaneado.</p>") }
        elseif ($progs.Count -eq 0) { [void]$sb.Append("<p class='muted'>Todo al día.</p>") }
        else {
            [void]$sb.Append('<table><tr><th>Programa</th><th>Versión actual</th><th>Nueva versión</th></tr>')
            foreach ($p in $progs) { [void]$sb.Append("<tr><td>$(& $enc $p.Name)</td><td>$(& $enc $p.Version)</td><td>$(& $enc $p.Available)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('<h2>Windows Update</h2>')
        if (-not $script:Scanned.WU) { [void]$sb.Append("<p class='muted'>No escaneado.</p>") }
        elseif ($script:WUItems.Count -eq 0) { [void]$sb.Append("<p class='muted'>Todo al día.</p>") }
        else {
            [void]$sb.Append('<table><tr><th>Actualización</th><th>Tipo</th><th>Gravedad</th><th>Tamaño</th></tr>')
            foreach ($u in $script:WUItems) { [void]$sb.Append("<tr><td>$(& $enc $u.Title)</td><td>$(& $enc $u.Kind)</td><td>$(& $enc $u.Severity)</td><td>$(& $enc $u.Size)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('<h2>Salud y seguridad</h2>')
        if (-not $script:Scanned.Health) { [void]$sb.Append("<p class='muted'>No revisado.</p>") }
        else {
            [void]$sb.Append('<table><tr><th>Área</th><th>Elemento</th><th>Detalle</th><th>Estado</th></tr>')
            foreach ($h in $script:HealthRows) { [void]$sb.Append("<tr><td>$(& $enc $h.Section)</td><td>$(& $enc $h.Item)</td><td>$(& $enc $h.Value)</td><td>$(& $pill $h.StatusText $h.StatusColor)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('<h2>Dispositivos</h2>')
        if (-not $script:Scanned.Devices) { [void]$sb.Append("<p class='muted'>No escaneado.</p>") }
        else {
            [void]$sb.Append('<table><tr><th>Estado</th><th>Dispositivo</th><th>Versión</th><th>Fecha</th><th>Nota</th></tr>')
            foreach ($d in @($script:DeviceItems | Where-Object { -not $_.IsGeneric })) { [void]$sb.Append("<tr><td>$(& $pill $d.StatusText $d.StatusColor)</td><td>$(& $enc $d.Name)</td><td>$(& $enc $d.Version)</td><td>$(& $enc $d.Date)</td><td>$(& $enc $d.Note)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        if ($script:Scanned.Clean) {
            [void]$sb.Append('<h2>Espacio que se puede liberar</h2><table><tr><th>Qué</th><th>Tamaño</th></tr>')
            foreach ($c in $script:CleanItems) { [void]$sb.Append("<tr><td>$(& $enc $c.Name)</td><td>$(& $enc $c.SizeText)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('</body></html>')
        $desk = [Environment]::GetFolderPath('Desktop')
        $file = Join-Path $desk ('Reporte-RevixPC-{0}.html' -f (Get-Date).ToString('yyyyMMdd-HHmm'))
        [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Add-History 'Exportar reporte' $file
        Start-Process $file
    })

    # ---------- Instalación (Archivos de programa, .exe, accesos directos y entrada en Aplicaciones) ----------
    function Get-InstalledExe { Join-Path $script:InstallDir 'RevixPC.exe' }
    function Get-InstalledPs1 { Join-Path $script:InstallDir 'RevixPC.ps1' }
    function Test-RunningInstalled {
        try { return ([IO.Path]::GetFullPath($script:AppDir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($script:InstallDir).TrimEnd('\')) } catch { return $false }
    }
    function Get-ScriptVersion([string]$ps1Path) {
        try {
            $txt = Get-Content -Raw -LiteralPath $ps1Path -Encoding UTF8
            $m = [regex]::Match($txt, '\$script:AppVersion\s*=\s*''([^'']+)''')
            if ($m.Success) { return $m.Groups[1].Value }
        } catch {}
        return '?'
    }
    function Compare-AppVersion([string]$a, [string]$b) {
        try { return ([version]$a).CompareTo([version]$b) } catch { return 0 }
    }

    # Quita lo que dejó ActualizaPC 4.1 (tarea de inicio, accesos directos y su carpeta vieja)
    function Remove-OldActualizaPC {
        try { Unregister-ScheduledTask -TaskName 'ActualizaPC' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            $l = Join-Path $folder 'ActualizaPC.lnk'
            if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
        }
        $old = Join-Path $env:LOCALAPPDATA 'Programs\ActualizaPC'
        $same = $false
        try { $same = ([IO.Path]::GetFullPath($script:AppDir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($old).TrimEnd('\')) } catch {}
        if ((Test-Path -LiteralPath $old) -and -not $same) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
    }

    function Register-Uninstall {
        $k = $script:UninstallKey
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        $exe = Get-InstalledExe
        $icon = Join-Path $script:InstallDir 'RevixPC.ico'
        if (Test-Path $exe) { $icon = "`"$exe`",0" }
        $size = 0
        try { $size = [int](((Get-ChildItem -LiteralPath $script:InstallDir -Recurse -File | Measure-Object Length -Sum).Sum) / 1KB) } catch {}
        $str = @{
            DisplayName = 'Revix PC'; DisplayVersion = $script:AppVersion; Publisher = 'Marco11'
            InstallLocation = $script:InstallDir; DisplayIcon = $icon
            UninstallString = "`"$($script:PsExe)`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Get-InstalledPs1)`" -Uninstall"
            URLInfoAbout = $script:GitHubUrl; HelpLink = "$($script:GitHubUrl)/issues"
            InstallDate = (Get-Date).ToString('yyyyMMdd')
        }
        foreach ($n in $str.Keys) { New-ItemProperty -Path $k -Name $n -Value $str[$n] -PropertyType String -Force | Out-Null }
        foreach ($n in 'NoModify', 'NoRepair') { New-ItemProperty -Path $k -Name $n -Value 1 -PropertyType DWord -Force | Out-Null }
        New-ItemProperty -Path $k -Name 'EstimatedSize' -Value $size -PropertyType DWord -Force | Out-Null
    }

    function Install-App([string]$SourceDir = $script:AppDir) {
        if (-not $script:IsAdmin) { throw 'Para instalar hace falta abrir Revix PC como administrador.' }
        $dir = $script:InstallDir
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $same = $false
        try { $same = ([IO.Path]::GetFullPath($SourceDir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($dir).TrimEnd('\')) } catch {}
        if (-not $same) {
            Copy-Item -LiteralPath (Join-Path $SourceDir 'RevixPC.ps1') -Destination (Get-InstalledPs1) -Force
            $icoSrc = Join-Path $SourceDir 'RevixPC.ico'
            if (-not (Test-Path $icoSrc)) { $icoSrc = Join-Path $SourceDir 'ActualizaPC.ico' }
            if (Test-Path $icoSrc) { Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $dir 'RevixPC.ico') -Force }
            foreach ($f in 'LICENSE', 'README.md', 'CHANGELOG.md') {
                $src = Join-Path $SourceDir $f
                if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $dir $f) -Force }
            }
        }
        $exe = Get-InstalledExe
        $ico = Join-Path $dir 'RevixPC.ico'
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        $exeOk = $false
        if (Test-Path $csc) {
            $tmp = Join-Path $env:TEMP ('RevixPC-build-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $cs = @'
using System;
using System.Diagnostics;
using System.IO;
static class Launcher {
    [STAThread]
    static void Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
        string script = Path.Combine(dir, "RevixPC.ps1");
        string extra = "";
        foreach (string a in args) { if (a == "-Tray") extra += " -Tray"; }
        var psi = new ProcessStartInfo(ps, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" -NoElevate" + extra);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
    }
}
'@
            $manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="4.2.0.0" name="RevixPC"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security><requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
      <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
    </requestedPrivileges></security>
  </trustInfo>
</assembly>
'@
            Set-Content -Path (Join-Path $tmp 'Launcher.cs') -Value $cs -Encoding UTF8
            Set-Content -Path (Join-Path $tmp 'app.manifest') -Value $manifest -Encoding UTF8
            $cscArgs = @('/nologo', '/target:winexe', "/out:$exe", "/win32manifest:$(Join-Path $tmp 'app.manifest')")
            if (Test-Path $ico) { $cscArgs += "/win32icon:$ico" }
            $cscArgs += (Join-Path $tmp 'Launcher.cs')
            $o = & $csc @cscArgs 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -and (Test-Path $exe)) { $exeOk = $true } else { Write-ErrorLog "csc: $o" }
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        $sh = New-Object -ComObject WScript.Shell
        foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
            $path = Join-Path $folder 'Revix PC.lnk'
            $lnk = $sh.CreateShortcut($path)
            if ($exeOk) {
                $lnk.TargetPath = $exe; $lnk.IconLocation = "$exe,0"
            } else {
                $lnk.TargetPath = $script:PsExe
                $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$(Get-InstalledPs1)`""
                if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
            }
            $lnk.WorkingDirectory = $dir
            $lnk.Description = 'Revix PC - actualizaciones, drivers y salud de la PC'
            $lnk.Save()
            [void][RevixPC.Native]::SetShortcutAppId($path, $script:AppId)
        }
        Register-Uninstall
        Remove-OldActualizaPC
        if ($script:Config.StartWithWindows) { [void](Set-Startup $true) }
        return $exeOk
    }

    function Set-Startup([bool]$on) {
        $name = 'RevixPC'
        try {
            if (-not $on) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue; return $true }
            $user = "$env:USERDOMAIN\$env:USERNAME"
            $exe = Get-InstalledExe
            $ps1 = Get-InstalledPs1
            if (-not (Test-Path $ps1)) { throw 'Primero instala Revix PC (Ajustes > Avanzado > Reparar instalación).' }
            if (Test-Path $exe) { $act = New-ScheduledTaskAction -Execute $exe -Argument '-Tray' }
            else { $act = New-ScheduledTaskAction -Execute $script:PsExe -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ps1`" -Tray -NoElevate" }
            $trg = New-ScheduledTaskTrigger -AtLogOn -User $user
            $prn = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
            return $true
        } catch {
            Write-ErrorLog "startup: $_"
            Show-Msg "No se pudo configurar el inicio con Windows:`n$($_.Exception.Message)" 'Warning' | Out-Null
            return $false
        }
    }

    function Update-InstallInfo {
        if (Test-RunningInstalled) { $script:InstallInfo.Text = "Instalada en $($script:InstallDir). Puedes anclar el acceso directo a la barra de tareas (clic derecho > Anclar)." }
        elseif (Test-Path (Get-InstalledPs1)) { $script:InstallInfo.Text = "Estás usando una copia suelta. La versión instalada está en $($script:InstallDir)." }
        else { $script:InstallInfo.Text = 'Revix PC no está instalada en este equipo.' }
        if (Test-Path (Get-InstalledPs1)) { $script:BtnInstallApp.Content = 'Reparar instalación' } else { $script:BtnInstallApp.Content = 'Instalar en este equipo' }
        $script:BtnUninstallApp.IsEnabled = (Test-Path (Get-InstalledPs1))
    }

    $script:BtnInstallApp.Add_Click({
        try {
            [void](Install-App)
            Add-History 'Instalar Revix PC' $script:InstallDir
            Update-InstallInfo
            Show-Msg "Listo. Revix PC está instalada en:`n$($script:InstallDir)`n`nTienes accesos directos en el Escritorio y el menú Inicio." | Out-Null
        } catch {
            Write-ErrorLog "instalar: $_"
            Show-Msg "No se pudo instalar:`n$($_.Exception.Message)" 'Warning' | Out-Null
        }
    })
    $script:BtnUninstallApp.Add_Click({
        $ps1 = Get-InstalledPs1
        if (-not (Test-Path $ps1)) { return }
        Start-Process $script:PsExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ps1`" -Uninstall"
    })
    $script:BtnOpenData.Add_Click({ Start-Process explorer.exe $script:DataDir })
    $script:BtnOpenRestore.Add_Click({ Start-Process 'rstrui.exe' })
    $script:BtnGitHub.Add_Click({ Start-Process $script:GitHubUrl })
    $script:BtnReport.Add_Click({ Start-Process "$($script:GitHubUrl)/issues/new/choose" })
    $script:BtnLicense.Add_Click({
        $lic = Join-Path $script:AppDir 'LICENSE'
        if (Test-Path $lic) { Start-Process notepad.exe -ArgumentList "`"$lic`"" } else { Start-Process "$($script:GitHubUrl)/blob/main/LICENSE" }
    })

    # ---------- Modo juego ----------
    function Test-GameMode {
        if (-not $script:Config.GameMode) { return $false }
        $now = Get-Date
        if ($script:GameCache -and ($now - $script:GameCache.Time).TotalSeconds -lt 10) { return $script:GameCache.Value }
        $v = $false
        try { $v = [RevixPC.Native]::IsFullscreenAppRunning($PID) } catch {}
        if (-not $v) {
            $names = @(([string]$script:Config.GameProcesses) -split ',' | ForEach-Object { ($_.Trim()) -replace '\.exe$', '' } | Where-Object { $_ })
            if ($names.Count -gt 0 -and (Get-Process -Name $names -ErrorAction SilentlyContinue)) { $v = $true }
        }
        $script:GameCache = @{ Time = $now; Value = $v }
        return $v
    }

    function Check-Deferred {
        if (-not ($script:QueuedNotify -or $script:DeferredAuto)) { return }
        if (Test-GameMode) { return }
        if ($script:QueuedNotify) {
            $q = $script:QueuedNotify; $script:QueuedNotify = $null
            Show-Notify $q.Title $q.Text
        }
        if ($script:DeferredAuto -and -not (Test-AnyRunning $script:WorkKinds)) {
            $script:DeferredAuto = $false
            $script:AutoRound = $true
            Start-ScanAll
        }
    }

    # ---------- NVIDIA ----------
    $script:NvidiaInfo = $null
    function Get-NvidiaNewCount {
        foreach ($d in @($script:DeviceItems)) { if ($d.StatusText -like 'Driver nuevo*') { return 1 } }
        return 0
    }
    function Check-Nvidia {
        $gpu = $script:RawDevices | Where-Object { ([string]$_.DeviceClass).ToUpper() -eq 'DISPLAY' -and [string]$_.Manufacturer -match 'NVIDIA' } | Select-Object -First 1
        if (-not $gpu) { return }
        [void](Start-Bg 'Nvidia' 'Consultando a NVIDIA' $script:JobNvidia @([string]$gpu.Name, [string]$script:Config.GpuPfid) {
            param($out, $err)
            if ($err) {
                Write-ErrorLog "nvidia: $err"
                if ($script:Config.GpuPfid) { $script:Config.GpuPfid = ''; Save-Config }
                return
            }
            $r = $out | Select-Object -First 1
            if (-not $r) { return }
            if ($r.Pfid -and $r.Pfid -ne $script:Config.GpuPfid) { $script:Config.GpuPfid = [string]$r.Pfid; Save-Config }
            $script:NvidiaInfo = @{ Latest = [string]$r.Version; Url = [string]$r.Url }
            Rebuild-Devices
            Update-Summary
            if (Get-NvidiaNewCount) { Add-History 'Driver de NVIDIA' "Hay versión nueva: $($r.Version)" }
        })
    }

    # ---------- Volver a una versión anterior ----------
    function Show-RollbackDialog {
        if ($script:PrevVersions.Count -eq 0) {
            Show-Msg "Todavía no hay programas actualizados con Revix PC.`n`nCada vez que actualices uno, aquí podrás volver a la versión que tenías antes." | Out-Null
            return
        }
        $dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Volver a una versión anterior" Width="820" Height="460" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource BgWindow}" Foreground="{DynamicResource Fg}" FontFamily="Segoe UI" FontSize="13">
  $($script:ResourcesText)
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock TextWrapping="Wrap" Style="{StaticResource Muted}" Margin="0,0,0,10"
               Text="Marca el programa que quieres regresar a la versión que tenías antes. La versión nueva quedará como 'saltada' para que no se vuelva a instalar sola."/>
    <DataGrid x:Name="GridRb" Grid.Row="1">
      <DataGrid.Columns>
        <DataGridTemplateColumn Width="42" CellTemplate="{StaticResource CheckCell}"/>
        <DataGridTextColumn Header="Programa" Binding="{Binding Name}" Width="*"/>
        <DataGridTextColumn Header="Volver a" Binding="{Binding FromVersion}" Width="130"/>
        <DataGridTextColumn Header="Versión actual" Binding="{Binding ToVersion}" Width="130"/>
        <DataGridTextColumn Header="Actualizado el" Binding="{Binding Date}" Width="130"/>
      </DataGrid.Columns>
    </DataGrid>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="BtnRbDo" Content="Volver a la versión anterior" Style="{StaticResource BtnPrimary}"/>
      <Button x:Name="BtnRbClose" Content="Cerrar" Style="{StaticResource Btn}" Margin="0,0,0,8"/>
    </StackPanel>
  </Grid>
</Window>
"@
        $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dx)))
        Apply-Theme $dlg
        $dlg.Owner = $script:Window
        $script:RbDialog = $dlg
        $items = New-Object 'System.Collections.Generic.List[RevixPC.RollbackItem]'
        foreach ($k in $script:PrevVersions.Keys) {
            $v = $script:PrevVersions[$k]
            $ri = New-Object RevixPC.RollbackItem
            $ri.Id = $k; $ri.Name = $v.Name; $ri.FromVersion = $v.From; $ri.ToVersion = $v.To; $ri.Date = $v.Date
            $items.Add($ri)
        }
        $script:RbItems = $items
        $dlg.FindName('GridRb').ItemsSource = @($items | Sort-Object Name)
        $dlg.FindName('BtnRbClose').Add_Click({ $script:RbDialog.Close() })
        $dlg.FindName('BtnRbDo').Add_Click({
            $sel = @($script:RbItems | Where-Object { $_.Selected })
            if ($sel.Count -eq 0) { [void](Show-Msg 'Marca al menos un programa.' 'Information' 'OK' $script:RbDialog); return }
            $list = ($sel | ForEach-Object { "  • $($_.Name): $($_.ToVersion) -> $($_.FromVersion)" }) -join "`n"
            $ans = Show-Msg "Se reinstalará la versión anterior de:`n`n$list`n`nOjo: las versiones viejas pueden tener fallas de seguridad ya corregidas. ¿Continuar?" 'Question' 'YesNo' $script:RbDialog
            if ($ans -ne 'Yes') { return }
            $script:RbDialog.Close()
            Start-Rollback $sel
        })
        [void]$dlg.ShowDialog()
    }

    function Start-Rollback($sel) {
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg 'Espera a que termine la tarea actual.' | Out-Null; return }
        $script:Tasks.Clear(); Reset-Cancel
        Show-ProgressTab "Volviendo a la versión anterior de $(@($sel).Count) programa(s)"
        $script:RbMap = @{}
        foreach ($i in $sel) { $script:RbMap[$i.Id] = $i; Add-TaskRow $i.Id "$($i.Name): volver a $($i.FromVersion)" }
        $arr = [string[]]@($sel | ForEach-Object { "$($_.Id)|$($_.FromVersion)" })
        [void](Start-Bg 'Rollback' 'Volviendo a versiones anteriores' $script:JobRollback @(, $arr) {
            param($out, $err)
            if ($err) { Add-History 'Volver a versión anterior' "Error: $err"; Set-QueuedCancelled; Show-Msg $err 'Warning' | Out-Null; return }
            $done = @($out | Where-Object { $_.Kind -eq 'done' })
            $ok = @($done | Where-Object { [int]$_.ExitCode -eq 0 }).Count
            $script:TaskHeader.Text = "Regresados a la versión anterior: $ok de $($done.Count)"
            Scan-Programs
        } {
            param($o)
            $i = $script:RbMap[[string]$o.Key]
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key 'Instalando...' $script:C.Amber "Reinstalando $($i.FromVersion)" }
                'done'   {
                    if ([int]$o.ExitCode -eq 0) {
                        Set-TaskRow $o.Key 'Correcto' $script:C.Green "Ahora tienes la $($i.FromVersion). La $($i.ToVersion) quedó saltada."
                        $script:Skipped[$i.Id] = $i.ToVersion
                        [void]$script:PrevVersions.Remove($i.Id)
                        Save-Config
                        Add-History "Volver a versión anterior: $($i.Name)" "$($i.ToVersion) -> $($i.FromVersion)"
                    } else {
                        $d = (Get-WingetCodeText ([int]$o.ExitCode)); if ($o.Message) { $d += ' - ' + $o.Message }
                        Set-TaskRow $o.Key 'Error' $script:C.Red $d
                        Add-History "Volver a versión anterior: $($i.Name)" "Error: $d"
                    }
                }
                'cancel' { Set-QueuedCancelled }
            }
        })
    }

    $script:BtnRollback.Add_Click({ Show-RollbackDialog })
    $script:BtnProgAuto.Add_Click({
        $sel = @($script:ProgramItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg "Marca los programas en los que confías (por ejemplo tu navegador). Se actualizarán solos en cada revisión automática." | Out-Null; return }
        foreach ($p in $sel) {
            if ($p.Auto) { $p.Auto = $false; [void]$script:AutoUpdateIds.Remove($p.Id); Add-History "Automático: $($p.Name)" 'Desactivado' }
            else { $p.Auto = $true; if (-not $script:AutoUpdateIds.Contains($p.Id)) { $script:AutoUpdateIds.Add($p.Id) }; Add-History "Automático: $($p.Name)" 'Activado' }
            $p.Selected = $false
        }
        Save-Config; Refresh-Programs
    })

    # ---------- Inicio de Windows ----------
    function Scan-Startup {
        [void](Start-Bg 'Startup' 'Revisando programas de inicio' $script:JobStartup $null {
            param($out, $err)
            if ($err) { Add-History 'Programas de inicio' "Error: $err"; return }
            $slow = @($out | Where-Object { $_.Type -eq 'Slow' })
            $boot = $out | Where-Object { $_.Type -eq 'Boot' } | Select-Object -First 1
            $list = New-Object 'System.Collections.Generic.List[RevixPC.StartupItem]'
            foreach ($r in @($out | Where-Object { $_.Type -eq 'Item' })) {
                $it = New-Object RevixPC.StartupItem
                $it.Enabled = [bool]$r.Enabled; $it.Name = [string]$r.Name; $it.Command = [string]$r.Command
                $it.Location = [string]$r.Location; $it.Publisher = [string]$r.Publisher
                $it.ValueName = [string]$r.ValueName; $it.ApprovedPath = [string]$r.ApprovedPath; $it.FilePath = [string]$r.FilePath
                $it.Impact = '—'
                $leaf = ''
                try { if ($it.FilePath) { $leaf = [IO.Path]::GetFileName($it.FilePath) } } catch {}
                if ($leaf) {
                    $m = $slow | Where-Object { $_.File -and ([IO.Path]::GetFileName([string]$_.File) -ieq $leaf) } | Sort-Object Date -Descending | Select-Object -First 1
                    if ($m -and $m.Ms -gt 0) { $it.Impact = ('Ralentizó {0:N1} s ({1})' -f ($m.Ms / 1000), ([datetime]$m.Date).ToString('dd/MM')) }
                }
                $list.Add($it)
            }
            $script:StartupItems = $list
            $script:GridStartup.ItemsSource = @($list | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)
            if ($boot -and $boot.Ms -gt 0) {
                $script:BootInfo.Text = ('Último arranque: {0:N1} s ({1})' -f ($boot.Ms / 1000), ([datetime]$boot.Date).ToString('dd/MM/yyyy'))
            } else { $script:BootInfo.Text = "$(@($list | Where-Object { $_.Enabled }).Count) de $($list.Count) activos" }
            $script:Scanned.Startup = $true
        })
    }

    function Set-StartupEnabled($item, [bool]$on) {
        $p = $item.ApprovedPath
        if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
        if ($on) { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        else { $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes((Get-Date).ToFileTime())) }
        New-ItemProperty -LiteralPath $p -Name $item.ValueName -Value $bytes -PropertyType Binary -Force | Out-Null
    }

    $script:GridStartup.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $cb = $e.OriginalSource
        if ($cb -isnot [System.Windows.Controls.CheckBox]) { return }
        $item = $cb.DataContext
        $want = [bool]$cb.IsChecked
        if ($item.ApprovedPath -like 'HKLM:*' -and -not $script:IsAdmin) {
            $item.Enabled = -not $want; $script:GridStartup.Items.Refresh()
            Show-Msg 'Este programa arranca para todos los usuarios. Para cambiarlo abre Revix PC como administrador.' 'Warning' | Out-Null
            return
        }
        try {
            Set-StartupEnabled $item $want
            if ($want) { Add-History "Inicio de Windows: $($item.Name)" 'Activado' } else { Add-History "Inicio de Windows: $($item.Name)" 'Desactivado (no arrancará con Windows)' }
        } catch {
            $item.Enabled = -not $want; $script:GridStartup.Items.Refresh()
            Show-Msg "No se pudo cambiar:`n$($_.Exception.Message)" 'Warning' | Out-Null
        }
    })
    $script:BtnStartupScan.Add_Click({ Scan-Startup })
    $script:BtnTaskMgr.Add_Click({ Start-Process 'taskmgr.exe' -ArgumentList '/0 /startup' })

    # ---------- Desinstalar programas ----------
    function Refresh-Apps {
        $q = ([string]$script:TxtAppSearch.Text).Trim()
        $view = @($script:AppItems | Where-Object { -not $q -or $_.Name -like "*$q*" -or $_.Publisher -like "*$q*" })
        $script:GridApps.ItemsSource = $view
        $mb = ($script:AppItems | Measure-Object -Property SizeMB -Sum).Sum
        $script:AppsInfo.Text = ('{0} programas · {1} en total (según lo que informa cada programa)' -f @($script:AppItems).Count, (Format-Bytes ([double]$mb * 1MB)))
    }
    function Scan-Apps {
        [void](Start-Bg 'Apps' 'Leyendo programas instalados' $script:JobApps $null {
            param($out, $err)
            if ($err) { Add-History 'Programas instalados' "Error: $err"; return }
            $list = New-Object 'System.Collections.Generic.List[RevixPC.AppItem]'
            foreach ($r in $out) {
                $a = New-Object RevixPC.AppItem
                $a.Name = [string]$r.Name; $a.Publisher = [string]$r.Publisher; $a.Version = [string]$r.Version
                $a.SizeMB = [double]$r.SizeMB; $a.InstallDate = [string]$r.InstallDate; $a.UninstallString = [string]$r.Uninstall
                if ($a.SizeMB -gt 0) { $a.Size = Format-Bytes ($a.SizeMB * 1MB) } else { $a.Size = '' }
                $list.Add($a)
            }
            $script:AppItems = @($list | Sort-Object Name)
            $script:Scanned.Apps = $true
            Refresh-Apps
        })
    }
    function Split-CommandLine([string]$cmd) {
        $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
        if ($c.StartsWith('"')) {
            $e = $c.IndexOf('"', 1)
            if ($e -gt 0) { return @($c.Substring(1, $e - 1), $c.Substring($e + 1).Trim()) }
        }
        $m = [regex]::Match($c, '^(.+?\.exe)(.*)$', 'IgnoreCase')
        if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value.Trim()) }
        $sp = $c.IndexOf(' ')
        if ($sp -gt 0) { return @($c.Substring(0, $sp), $c.Substring($sp + 1)) }
        return @($c, '')
    }
    $script:TxtAppSearch.Add_TextChanged({ Refresh-Apps })
    $script:BtnAppsScan.Add_Click({ Scan-Apps })
    $script:BtnAppsSettings.Add_Click({ Start-Process 'ms-settings:appsfeatures' })
    $script:BtnUninstall.Add_Click({
        $a = $script:GridApps.SelectedItem
        if (-not $a) { Show-Msg 'Selecciona un programa de la lista (un clic sobre él).' | Out-Null; return }
        $ans = Show-Msg "Se abrirá el desinstalador de:`n`n$($a.Name)`n`nSigue los pasos que te muestre. ¿Continuar?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        try {
            $cmd = $a.UninstallString
            $mm = [regex]::Match($cmd, 'msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-Fa-f\-]+\})', 'IgnoreCase')
            if ($mm.Success) { Start-Process 'msiexec.exe' -ArgumentList "/X$($mm.Groups[2].Value)" }
            else {
                $parts = Split-CommandLine $cmd
                if ($parts[1]) { Start-Process -FilePath $parts[0] -ArgumentList $parts[1] } else { Start-Process -FilePath $parts[0] }
            }
            $script:UninstallPending = $true
            Add-History "Desinstalar $($a.Name)" 'Se abrió el desinstalador'
        } catch {
            Show-Msg "No se pudo abrir el desinstalador:`n$($_.Exception.Message)`n`nPrueba desde 'Aplicaciones de Windows'." 'Warning' | Out-Null
        }
    })

    # ---------- Mi PC: ficha, batería y temperaturas ----------
    function Scan-PcInfo {
        [void](Start-Bg 'PcInfo' 'Leyendo la ficha de tu PC' $script:JobPcInfo $null {
            param($out, $err)
            if ($err) { Add-History 'Ficha de la PC' "Error: $err"; return }
            $list = New-Object 'System.Collections.Generic.List[RevixPC.InfoRow]'
            foreach ($r in $out) {
                $i = New-Object RevixPC.InfoRow
                $i.Section = [string]$r.Section; $i.Item = [string]$r.Item; $i.Value = [string]$r.Value; $i.Note = [string]$r.Note
                $list.Add($i)
            }
            $script:SpecRows = $list
            $script:GridSpecs.ItemsSource = @($list)
            if ($list | Where-Object { $_.Section -eq 'Batería' }) { $script:BtnBatteryReport.Visibility = 'Visible' }
            $script:Scanned.PcInfo = $true
        })
    }
    $script:BtnPcScan.Add_Click({ Scan-PcInfo })
    $script:BtnCopySpecs.Add_Click({
        if (-not $script:SpecRows) { return }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Ficha de mi PC ($env:COMPUTERNAME) - $((Get-Date).ToString('dd/MM/yyyy'))")
        $last = ''
        foreach ($r in $script:SpecRows) {
            if ($r.Section -ne $last) { [void]$sb.AppendLine(''); [void]$sb.AppendLine($r.Section.ToUpper()); $last = $r.Section }
            $line = "- $($r.Item): $($r.Value)"; if ($r.Note) { $line += "  ($($r.Note))" }
            [void]$sb.AppendLine($line)
        }
        [System.Windows.Clipboard]::SetText($sb.ToString())
        $script:StatusText.Text = 'Ficha copiada. Pégala donde quieras con Ctrl+V.'
    })
    $script:BtnBatteryReport.Add_Click({
        $file = Join-Path ([Environment]::GetFolderPath('Desktop')) ('Informe-bateria-{0}.html' -f (Get-Date).ToString('yyyyMMdd'))
        & powercfg.exe /batteryreport /output "$file" | Out-Null
        if (Test-Path $file) { Start-Process $file; Add-History 'Informe de batería' $file }
        else { Show-Msg 'No se pudo crear el informe de batería.' 'Warning' | Out-Null }
    })

    function Get-GpuSensor {
        $smi = @((Join-Path $env:WINDIR 'System32\nvidia-smi.exe'), (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $smi) { return $null }
        try {
            $line = & $smi '--query-gpu=name,temperature.gpu,utilization.gpu,fan.speed,power.draw,memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
            if (-not $line) { return $null }
            $p = @($line -split ',\s*')
            return [pscustomobject]@{ Name = $p[0]; Temp = $p[1]; Load = $p[2]; Fan = $p[3]; Power = $p[4]; MemUsed = $p[5]; MemTotal = $p[6] }
        } catch { return $null }
    }
    function Get-TempLevel([int]$t, [int]$warm, [int]$hot) {
        if ($t -ge $hot) { return @('Muy caliente', $script:C.Red) }
        if ($t -ge $warm) { return @('Caliente', $script:C.Amber) }
        return @('Normal', $script:C.Green)
    }
    function Update-Temps([bool]$full) {
        $g = Get-GpuSensor
        if ($g -and $g.Temp -match '^\d+$') {
            $t = [int]$g.Temp
            if ($script:Config.TempAlert -and $t -ge 85 -and (-not $script:LastTempAlert -or ((Get-Date) - $script:LastTempAlert).TotalMinutes -ge 10)) {
                $script:LastTempAlert = Get-Date
                try { $script:TrayIcon.ShowBalloonTip(8000, 'Tarjeta de video muy caliente', "$($g.Name): $t °C. Revisa la ventilación y el polvo.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch {}
                Add-History 'Alerta de temperatura' "$($g.Name): $t °C"
            }
        }
        if (-not $full) { return }
        $rows = New-Object 'System.Collections.Generic.List[RevixPC.HealthRow]'
        if ($g) {
            if ($g.Temp -match '^\d+$') { $lv = Get-TempLevel ([int]$g.Temp) 75 85; $rows.Add((New-HealthRow '' 'Video: temperatura' "$($g.Temp) °C" $lv[0] $lv[1] 0)) }
            if ($g.Load -match '^\d+$') { $rows.Add((New-HealthRow '' 'Video: uso' "$($g.Load) %" '' $script:C.Gray 0)) }
            if ($g.Fan -match '^\d+$') {
                $ft = "$($g.Fan) %"; if ([int]$g.Fan -eq 0) { $ft = 'Detenido (normal en reposo)' }
                $rows.Add((New-HealthRow '' 'Video: ventilador' $ft '' $script:C.Gray 0))
            }
            $pw = 0.0
            if ([double]::TryParse([string]$g.Power, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$pw)) { $rows.Add((New-HealthRow '' 'Video: consumo' ('{0:N0} W' -f $pw) '' $script:C.Gray 0)) }
            if ($g.MemUsed -match '^\d+$') { $rows.Add((New-HealthRow '' 'Video: memoria' "$($g.MemUsed) / $($g.MemTotal) MB" '' $script:C.Gray 0)) }
        } else {
            $rows.Add((New-HealthRow '' 'Tarjeta de video' 'No disponible' 'Solo NVIDIA' $script:C.Gray 0))
        }
        foreach ($d in @($script:DiskTemps)) {
            if (-not $d) { continue }
            $lv = Get-TempLevel ([int]$d.Temp) 60 70
            $rows.Add((New-HealthRow '' "Disco: $($d.Name)" "$($d.Temp) °C" $lv[0] $lv[1] 0))
        }
        $script:GridTemps.ItemsSource = @($rows)
    }
    function Scan-DiskTemps {
        [void](Start-Bg 'DiskTemp' '' $script:JobDiskTemps $null {
            param($out, $err)
            $script:DiskTemps = @($out)
        })
    }
    $script:TempTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TempTimer.Interval = [TimeSpan]::FromSeconds(3)
    $script:TempTimer.Add_Tick({
        $script:TempTick++
        Update-GameChip
        if ($script:Window.IsVisible -and $script:Tabs.SelectedItem -eq $script:TabHome -and ($script:TempTick % 10 -eq 0)) { Update-HomeTemps }
        $visible = $script:Window.IsVisible -and ($script:Tabs.SelectedItem -eq $script:TabMyPC)
        if ($visible) {
            Update-Temps $true
            if ($script:TempTick % 20 -eq 1) { Scan-DiskTemps }
        } elseif ($script:Config.TempAlert -and ($script:TempTick % 10 -eq 0)) {
            Update-Temps $false
        }
        # Tema "Igual que Windows": seguir el cambio de Windows
        if ($script:Config.Theme -eq 'System' -and ($script:TempTick % 5 -eq 0)) {
            $eff = Get-EffectiveTheme
            if ($eff -ne $script:CurrentTheme) { Set-Theme }
        }
    })

    # ---------- Navegación y pantalla Resumen ----------
    function Go-Tab([int]$i) { $script:Tabs.SelectedIndex = $i }
    $script:NavList.Add_SelectionChanged({
        if ($script:SyncingNav) { return }
        $it = $script:NavList.SelectedItem
        if ($it -and $it.Tag -ne $null) { Go-Tab ([int]$it.Tag) }
    })
    foreach ($c in @($script:CardProg, $script:CardWU, $script:CardDrv, $script:CardHealth)) {
        $c.Add_Click({ param($s, $e) Go-Tab ([int]$s.Tag) })
    }
    $script:TodoList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $b = $e.OriginalSource
        if ($b -isnot [System.Windows.Controls.Button]) { return }
        $t = [string]$b.Tag
        if ($t -like 'tab:*') { Go-Tab ([int]$t.Substring(4)) }
        elseif ($t -eq 'perfmon-rel') { Start-Process 'perfmon.exe' -ArgumentList '/rel' }
        elseif ($t -match '^https://') { Start-Process $t }
    })
    $script:BtnHomeUpdate.Add_Click({ Update-Programs @($script:ProgramItems) })
    $script:BtnHomeClean.Add_Click({ Go-Tab 5 })

    function Get-Brush([string]$c) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($c) }

    function Set-ScoreArc([int]$score, [string]$color) {
        $r = 45.0; $cx = 56.0; $cy = 56.0
        $frac = [Math]::Min(0.9999, [Math]::Max(0.0001, $score / 100.0))
        $ang = 2 * [Math]::PI * $frac
        $start = New-Object System.Windows.Point($cx, ($cy - $r))
        $end = New-Object System.Windows.Point(($cx + $r * [Math]::Sin($ang)), ($cy - $r * [Math]::Cos($ang)))
        $seg = New-Object System.Windows.Media.ArcSegment($end, (New-Object System.Windows.Size($r, $r)), 0, ($frac -gt 0.5), ([System.Windows.Media.SweepDirection]::Clockwise), $true)
        $fig = New-Object System.Windows.Media.PathFigure
        $fig.StartPoint = $start; $fig.IsClosed = $false
        [void]$fig.Segments.Add($seg)
        $geo = New-Object System.Windows.Media.PathGeometry
        [void]$geo.Figures.Add($fig)
        $script:ScoreArc.Data = $geo
        $script:ScoreArc.Stroke = Get-Brush $color
    }

    function Set-Badge($box, $tb, [int]$n) {
        if ($n -gt 0) { $tb.Text = [string]$n; $box.Visibility = 'Visible' } else { $box.Visibility = 'Collapsed' }
    }

    function New-Todo([string]$title, [string]$detail, [string]$kind, [string]$tile, [string]$letter, [string]$action, [string]$target) {
        $t = New-Object RevixPC.TodoItem
        $t.Title = $title; $t.Detail = $detail; $t.Kind = $kind; $t.Tile = $tile; $t.Letter = $letter; $t.ActionText = $action; $t.Target = $target
        return $t
    }

    function Update-Home {
        $prog = @($script:ProgramItems | Where-Object { -not $_.Hidden })
        $autoN = @($prog | Where-Object { $_.Auto }).Count
        $wuWin = @($script:WUItems | Where-Object { -not $_.IsDriver })
        $sec = @($wuWin | Where-Object { $_.Kind -eq 'Seguridad' }).Count
        $wuDrv = @($script:WUItems | Where-Object { $_.IsDriver }).Count
        $nv = Get-NvidiaNewCount
        $warn = @($script:HealthRows | Where-Object { $_.Level -ge 1 })
        $lvl2 = @($warn | Where-Object { $_.Level -ge 2 }).Count
        $lvl1 = $warn.Count - $lvl2

        if ($script:Scanned.Programs) {
            if ($prog.Count -eq 0) { $script:SubPrograms.Text = 'Todo al día' }
            elseif ($autoN -gt 0) { $script:SubPrograms.Text = "$autoN se actualizan solos" }
            else { $script:SubPrograms.Text = 'Esperan tu permiso' }
            $script:BtnHomeUpdate.Content = "Actualizar programas ($($prog.Count))"
            $script:BtnHomeUpdate.IsEnabled = ($prog.Count -gt 0)
        }
        if ($script:Scanned.WU) {
            if ($wuWin.Count -eq 0) { $script:SubWU.Text = 'Todo al día' }
            elseif ($sec -gt 0) { $script:SubWU.Text = "$sec de seguridad" }
            else { $script:SubWU.Text = 'Parches y mejoras' }
            if ($nv) { $script:SubDrivers.Text = 'NVIDIA tiene uno nuevo' }
            elseif ($wuDrv) { $script:SubDrivers.Text = 'En Windows Update' }
            else { $script:SubDrivers.Text = 'Todo al día' }
        }
        if ($script:Scanned.Health) {
            if ($warn.Count -eq 0) { $script:SubHealth.Text = 'Todo bien' }
            elseif ($lvl2 -gt 0) { $script:SubHealth.Text = "$lvl2 importante(s)" }
            else { $script:SubHealth.Text = 'Para revisar' }
        }
        if ($script:Scanned.Clean) {
            $sum = 0.0
            foreach ($c in $script:CleanItems) { if ($c.Selected -and $c.Bytes -gt 0) { $sum += $c.Bytes } }
            if ($sum -gt 50MB) { $script:BtnHomeClean.Content = 'Liberar ' + (Format-Bytes $sum) } else { $script:BtnHomeClean.Content = 'Limpieza' }
        }

        if ($script:Scanned.Programs) { Set-Badge $script:BadgeProgBox $script:BadgeProg $prog.Count }
        if ($script:Scanned.WU) { Set-Badge $script:BadgeWUBox $script:BadgeWU @($script:WUItems).Count }
        Set-Badge $script:BadgeDevBox $script:BadgeDev @($script:DeviceItems | Where-Object { $_.Priority -eq 0 }).Count
        if ($script:Scanned.Health) { Set-Badge $script:BadgeHealthBox $script:BadgeHealth $warn.Count }

        $todo = New-Object 'System.Collections.Generic.List[RevixPC.TodoItem]'
        if ($wuWin.Count -gt 0) {
            $d = 'Parches y mejoras de Windows'; if ($sec -gt 0) { $d = "$sec de seguridad · pueden pedir reiniciar" }
            $todo.Add((New-Todo "Instala $($wuWin.Count) actualización(es) de Windows" $d 'Windows' '#2F6FEB' 'W' 'Ver' 'tab:2'))
        }
        if ($nv) {
            $dv = $script:DeviceItems | Where-Object { $_.StatusText -like 'Driver nuevo*' } | Select-Object -First 1
            $todo.Add((New-Todo "Driver nuevo para tu $($dv.Name -replace '^NVIDIA\s+', '')" $dv.Note 'Driver' '#4D7C0F' 'N' 'Descargar' $dv.Link))
        }
        if ($wuDrv -gt 0) { $todo.Add((New-Todo "$wuDrv driver(s) en Windows Update" 'Se instalan desde la sección Windows Update' 'Driver' '#0E7490' 'D' 'Ver' 'tab:2')) }
        if ($prog.Count -gt 0) {
            $manual = $prog.Count - $autoN
            $d = 'Esperan tu permiso'
            if ($autoN -gt 0 -and $manual -gt 0) { $d = "$autoN se actualizan solos · $manual esperan tu permiso" }
            elseif ($autoN -gt 0) { $d = 'Se actualizan solos en la próxima revisión' }
            $todo.Add((New-Todo "Actualiza $($prog.Count) programa(s)" $d 'Programas' '#C2410C' 'P' 'Ver' 'tab:1'))
        }
        foreach ($h in @($warn | Sort-Object Level -Descending | Select-Object -First 3)) {
            $tile = '#8A5A00'; if ($h.Level -ge 2) { $tile = '#B42318' }
            $tgt = 'tab:4'; if ($h.Link) { $tgt = $h.Link }
            $todo.Add((New-Todo $h.Item ("$($h.Value) · $($h.StatusText)") 'Salud' $tile '!' 'Ver' $tgt))
        }
        $script:TodoList.ItemsSource = @($todo)
        $n = $todo.Count
        $allScanned = ($script:Scanned.Programs -and $script:Scanned.WU -and $script:Scanned.Health)
        if ($n -eq 0) {
            if ($allScanned) { $script:TodoEmpty.Text = 'Todo al día. No tienes nada pendiente.' } else { $script:TodoEmpty.Text = 'Revisando...' }
            $script:TodoEmpty.Visibility = 'Visible'
        } else { $script:TodoEmpty.Visibility = 'Collapsed' }
        if ($n -gt 0) { $script:TodoCount.Text = "$n por hacer" } else { $script:TodoCount.Text = '' }

        if ($allScanned) {
            $score = Get-HealthScore $sec ($wuWin.Count - $sec) $prog.Count ($nv + $wuDrv) $lvl2 $lvl1
            $lab = Get-ScoreLabel $score
            $script:ScoreText.Text = [string]$score
            $script:ScoreTitle.Text = $lab[0]
            Set-ScoreArc $score $lab[1]
            if ($n -eq 0) { $sub = 'Todo al día. No tienes nada pendiente.' }
            elseif ($n -eq 1) { $sub = 'Tienes 1 cosa por hacer.' }
            else { $sub = "Tienes $n cosas por hacer." }
            if ($n -gt 0 -and (Test-GameMode)) { $sub += ' Puedes hacerlas cuando termines de jugar.' }
            elseif ($n -gt 0 -and $lvl2 -eq 0 -and $sec -eq 0) { $sub += ' Nada urgente.' }
            $script:ScoreSub.Text = $sub
        }

        $stab = New-Object 'System.Collections.Generic.List[RevixPC.MiniRow]'
        $short = @{ 'Apagados' = 'Apagados inesperados'; 'Pantallazos' = 'Pantallazos azules'; 'Errores de hardware' = 'Errores de hardware'; 'Errores de disco' = 'Errores de disco' }
        foreach ($h in @($script:HealthRows | Where-Object { $_.Section -eq 'Estabilidad' })) {
            $m = New-Object RevixPC.MiniRow
            $m.Name = $h.Item
            foreach ($k in $short.Keys) { if ($h.Item -like "$k*") { $m.Name = $short[$k] } }
            $v = '0'; if ($h.Value -match '^(\d+)') { $v = $matches[1] }
            $m.Value = $v; $m.Color = $h.StatusColor
            $stab.Add($m)
        }
        $script:MiniStab.ItemsSource = @($stab)
    }

    function Update-HomeTemps {
        $rows = New-Object 'System.Collections.Generic.List[RevixPC.MiniRow]'
        $g = Get-GpuSensor
        if ($g -and $g.Temp -match '^\d+$') {
            $t = [int]$g.Temp; $lv = Get-TempLevel $t 75 85
            $m = New-Object RevixPC.MiniRow
            $m.Name = ($g.Name -replace '^NVIDIA\s+', ''); $m.Value = "$t °C"; $m.Pct = [Math]::Min(100, $t); $m.Color = $lv[1]
            $rows.Add($m)
        }
        foreach ($d in @($script:DiskTemps)) {
            if (-not $d) { continue }
            $lv = Get-TempLevel ([int]$d.Temp) 60 70
            $m = New-Object RevixPC.MiniRow
            $m.Name = $d.Name; $m.Value = "$($d.Temp) °C"; $m.Pct = [Math]::Min(100, [double]$d.Temp); $m.Color = $lv[1]
            $rows.Add($m)
        }
        if ($rows.Count -eq 0) {
            $m = New-Object RevixPC.MiniRow
            $m.Name = 'Leyendo sensores...'; $m.Value = ''; $m.Pct = 0; $m.Color = '#6B7383'
            $rows.Add($m)
            if (-not $script:Running['DiskTemp']) { Scan-DiskTemps }
        }
        $script:MiniTemps.ItemsSource = @($rows)
    }

    function Update-GameChip {
        if (-not $script:Config.GameMode) { $script:GameChipText.Text = 'Modo juego: apagado'; $script:GameDot.Fill = Get-Brush '#6B7383' }
        elseif (Test-GameMode) { $script:GameChipText.Text = 'Modo juego: activo'; $script:GameDot.Fill = Get-Brush '#F59E0B' }
        else { $script:GameChipText.Text = 'Modo juego: listo'; $script:GameDot.Fill = Get-Brush '#22C55E' }
    }

    $script:Tabs.Add_SelectionChanged({
        param($s, $e)
        if ($e.OriginalSource -ne $script:Tabs) { return }
        $t = $script:Tabs.SelectedItem
        if ($t) { $script:PageTitle.Text = [string]$t.Header }
        $script:SyncingNav = $true
        foreach ($it in $script:NavList.Items) { if ($it.Tag -ne $null -and [int]$it.Tag -eq $script:Tabs.SelectedIndex) { $script:NavList.SelectedItem = $it } }
        $script:SyncingNav = $false
        if ($t -eq $script:TabHome) { Update-HomeTemps }
        if ($t -eq $script:TabStartup -and -not $script:Scanned.Startup) { Scan-Startup }
        elseif ($t -eq $script:TabApps -and -not $script:Scanned.Apps) { Scan-Apps }
        elseif ($t -eq $script:TabMyPC) {
            if (-not $script:Scanned.PcInfo) { Scan-PcInfo }
            Scan-DiskTemps
            Update-Temps $true
        }
    })
    $window.Add_Activated({
        if ($script:UninstallPending) { $script:UninstallPending = $false; Scan-Apps }
    })

    # ---------- Tema ----------
    function Set-Theme {
        Apply-Theme $script:Window
        $script:CurrentTheme = Get-EffectiveTheme
        if ($script:CurrentTheme -eq 'Light') {
            $script:ThemeIcon.Text = [string][char]0xE708; $script:BtnTheme.ToolTip = 'Cambiar a tema oscuro'
        } else {
            $script:ThemeIcon.Text = [string][char]0xE706; $script:BtnTheme.ToolTip = 'Cambiar a tema claro'
        }
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
            if ($h -ne [IntPtr]::Zero) { [RevixPC.Native]::SetDarkTitleBar($h, ($script:CurrentTheme -eq 'Dark')) }
        } catch {}
    }
    $script:BtnTheme.Add_Click({
        if ($script:CurrentTheme -eq 'Light') { $script:Config.Theme = 'Dark' } else { $script:Config.Theme = 'Light' }
        Save-Config; Set-Theme
        $script:SyncingTheme = $true
        foreach ($it in $script:CmbTheme.Items) { if ([string]$it.Tag -eq $script:Config.Theme) { $script:CmbTheme.SelectedItem = $it } }
        $script:SyncingTheme = $false
    })
    $script:CmbTheme.Add_SelectionChanged({
        if ($script:SyncingTheme) { return }
        $sel = $script:CmbTheme.SelectedItem
        if ($sel) { $script:Config.Theme = [string]$sel.Tag; Save-Config; Set-Theme }
    })

    # ---------- Actualizar la propia app (releases de GitHub) ----------
    function Restart-App {
        $exe = Get-InstalledExe
        if (-not (Test-Path $exe)) {
            Show-Msg 'Listo. Cierra y vuelve a abrir Revix PC para usar la versión nueva.' | Out-Null
            return
        }
        $cmd = "Start-Sleep -Seconds 3; Start-Process -FilePath '$exe'"
        Start-Process $script:PsExe -ArgumentList "-NoProfile -WindowStyle Hidden -Command `"$cmd`"" -WindowStyle Hidden
        Exit-App
    }
    function ConvertTo-PlainNotes([string]$md) {
        if (-not $md) { return '' }
        $t = $md -replace "`r", ''
        $t = $t -replace '(?m)^#{1,6}\s*', '' -replace '\*\*', '' -replace '(?m)^\s*[-*]\s+', '• ' -replace '`', ''
        $t = $t.Trim()
        if ($t.Length -gt 1200) { $t = $t.Substring(0, 1200) + '...' }
        return $t
    }
    function Install-FromZip([string]$zip, [string]$notes = '') {
        $tmp = Join-Path $env:TEMP ('RevixPC-upd-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
            $ps1 = Get-ChildItem -LiteralPath $tmp -Filter 'RevixPC.ps1' -Recurse | Select-Object -First 1
            if (-not $ps1) { Show-Msg 'Ese .zip no contiene RevixPC.ps1.' 'Warning' | Out-Null; return }
            $newVer = Get-ScriptVersion $ps1.FullName
            $ans = Show-Msg "¿Instalar Revix PC $newVer? (tienes la $($script:AppVersion))`n`nTus ajustes e historial se mantienen. La app se reiniciará.`n`nInstala solo archivos descargados de la página oficial de Revix PC en GitHub." 'Question' 'YesNo'
            if ($ans -ne 'Yes') { return }
            [void](Install-App -SourceDir $ps1.DirectoryName)
            $script:Config.UpdateNotes = $notes; Save-Config
            Add-History 'Actualizar Revix PC' "$($script:AppVersion) -> $newVer"
            Restart-App
        } catch {
            Write-ErrorLog "actualizar app: $_"
            Show-Msg "No se pudo actualizar:`n$($_.Exception.Message)" 'Warning' | Out-Null
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    function Check-AppUpdate([bool]$quiet) {
        $script:AppUpdQuiet = $quiet
        [void](Start-Bg 'AppUpd' 'Buscando nueva versión de Revix PC' $script:JobCheckAppUpdate @($script:GitHubRepo) {
            param($out, $err)
            if ($err) { if (-not $script:AppUpdQuiet) { Show-Msg $err 'Warning' | Out-Null }; return }
            $r = $out | Select-Object -First 1
            if (-not $r -or -not $r.Version) { return }
            if ((Compare-AppVersion $r.Version $script:AppVersion) -le 0) { if (-not $script:AppUpdQuiet) { Show-Msg "Ya tienes la última versión ($($script:AppVersion))." | Out-Null }; return }
            if ($script:AppUpdQuiet -and (-not $script:Window.IsVisible -or (Test-GameMode))) {
                $script:PendingAppUpdate = $r
                Show-Notify 'Nueva versión de Revix PC' "Versión $($r.Version) disponible. Abre la app para ver las novedades."
                return
            }
            Offer-AppUpdate $r
        })
    }
    function Offer-AppUpdate($r) {
        $script:PendingAppUpdate = $null
        $notes = ConvertTo-PlainNotes $r.Notes
        $txt = "Hay una versión nueva de Revix PC: $($r.Version) (tienes la $($script:AppVersion))."
        if ($notes) { $txt += "`n`nNovedades:`n$notes" }
        if (-not $r.Zip) {
            $txt += "`n`nEsta versión no trae archivo para instalar automáticamente. ¿Abrir la página de descarga?"
            if ((Show-Msg $txt 'Question' 'YesNo') -eq 'Yes' -and $r.Page -match '^https://github\.com/') { Start-Process $r.Page }
            return
        }
        $ans = Show-Msg "$txt`n`n¿Descargar e instalar ahora?" 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:DownloadNotes = $notes
        $dest = Join-Path $env:TEMP ("RevixPC-$($r.Version).zip")
        [void](Start-Bg 'AppDl' 'Descargando Revix PC' $script:JobDownload @([string]$r.Zip, $dest, [string]$r.Digest, $script:GitHubRepo) {
            param($out2, $err2)
            if ($err2) { Show-Msg "No se pudo descargar:`n$err2" 'Warning' | Out-Null; return }
            $zipPath = [string]($out2 | Select-Object -Last 1)
            if (-not $zipPath -or -not (Test-Path -LiteralPath $zipPath)) { Show-Msg 'La descarga no se completó. Intenta de nuevo en unos minutos.' 'Warning' | Out-Null; return }
            Install-FromZip $zipPath $script:DownloadNotes
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        })
    }
    $script:BtnCheckAppUpdate.Add_Click({ Check-AppUpdate $false })
    $script:BtnUpdateFromZip.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Revix PC (*.zip)|*.zip'
        $dlg.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
        if ($dlg.ShowDialog($script:Window)) { Install-FromZip $dlg.FileName }
    })

    # ---------- Ajustes ----------
    function Set-AutoTimer {
        $h = [int]$script:Config.AutoCheckHours
        $script:AutoTimer.Stop()
        if ($h -gt 0) { $script:AutoTimer.Interval = [TimeSpan]::FromHours($h); $script:AutoTimer.Start() }
    }
    $script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:AutoTimer.Add_Tick({
        if (Test-GameMode) { $script:DeferredAuto = $true; return }
        if (-not (Test-AnyRunning $script:WorkKinds)) { $script:AutoRound = $true; Start-ScanAll }
    })

    $script:ChkStartup.Add_Click({
        $want = [bool]$script:ChkStartup.IsChecked
        if (-not $script:IsAdmin) {
            $script:ChkStartup.IsChecked = -not $want
            Show-Msg 'Para cambiar esto abre Revix PC como administrador.' 'Warning' | Out-Null; return
        }
        if ($want -and -not (Test-Path (Get-InstalledPs1))) {
            $ans = Show-Msg "Para iniciar con Windows, Revix PC tiene que estar instalada. ¿Instalar ahora?" 'Question' 'YesNo'
            if ($ans -eq 'Yes') { try { [void](Install-App); Update-InstallInfo } catch { Write-ErrorLog "instalar: $_" } }
            else { $script:ChkStartup.IsChecked = $false; return }
        }
        if (Set-Startup $want) {
            $script:Config.StartWithWindows = $want; Save-Config
            if ($want) { Add-History 'Iniciar con Windows' 'Activado' } else { Add-History 'Iniciar con Windows' 'Desactivado' }
        } else { $script:ChkStartup.IsChecked = -not $want }
    })
    $script:ChkCloseToTray.Add_Click({ $script:Config.CloseToTray = [bool]$script:ChkCloseToTray.IsChecked; Save-Config })
    $script:ChkNotify.Add_Click({ $script:Config.Notify = [bool]$script:ChkNotify.IsChecked; Save-Config })
    $script:ChkRestorePoint.Add_Click({ $script:Config.RestorePoint = [bool]$script:ChkRestorePoint.IsChecked; Save-Config })
    $script:CmbAutoCheck.Add_SelectionChanged({
        $sel = $script:CmbAutoCheck.SelectedItem
        if ($sel) { $script:Config.AutoCheckHours = [int]$sel.Tag; Save-Config; Set-AutoTimer }
    })
    $script:ChkGameMode.Add_Click({ $script:Config.GameMode = [bool]$script:ChkGameMode.IsChecked; $script:GameCache = $null; Save-Config })
    $script:TxtGames.Add_LostFocus({ $script:Config.GameProcesses = [string]$script:TxtGames.Text; $script:GameCache = $null; Save-Config })
    $script:ChkTempAlert.Add_Click({ $script:Config.TempAlert = [bool]$script:ChkTempAlert.IsChecked; Save-Config })
    $script:ChkAppUpdates.Add_Click({ $script:Config.CheckAppUpdates = [bool]$script:ChkAppUpdates.IsChecked; Save-Config })

    # ---------- Inicio ----------
    Load-Data
    $script:ChkStartup.IsChecked      = [bool]$script:Config.StartWithWindows
    $script:ChkCloseToTray.IsChecked  = [bool]$script:Config.CloseToTray
    $script:ChkNotify.IsChecked       = [bool]$script:Config.Notify
    $script:ChkRestorePoint.IsChecked = [bool]$script:Config.RestorePoint
    $script:ChkGameMode.IsChecked     = [bool]$script:Config.GameMode
    $script:TxtGames.Text             = [string]$script:Config.GameProcesses
    $script:ChkTempAlert.IsChecked    = [bool]$script:Config.TempAlert
    $script:ChkAppUpdates.IsChecked   = [bool]$script:Config.CheckAppUpdates
    $script:SyncingTheme = $true
    foreach ($it in $script:CmbTheme.Items) { if ([string]$it.Tag -eq [string]$script:Config.Theme) { $script:CmbTheme.SelectedItem = $it } }
    if (-not $script:CmbTheme.SelectedItem) { $script:CmbTheme.SelectedIndex = 0 }
    $script:SyncingTheme = $false
    Set-Theme
    $script:Scanned.Startup = $false; $script:Scanned.Apps = $false; $script:Scanned.PcInfo = $false
    $script:AppItems = @(); $script:DiskTemps = @()
    $script:TempTimer.Start()
    foreach ($it in $script:CmbAutoCheck.Items) { if ([int]$it.Tag -eq [int]$script:Config.AutoCheckHours) { $script:CmbAutoCheck.SelectedItem = $it } }
    if (-not $script:CmbAutoCheck.SelectedItem) { $script:CmbAutoCheck.SelectedIndex = 2 }
    Set-AutoTimer
    Update-InstallInfo
    $script:AboutTitle.Text = "Revix PC $($script:AppVersion)"
    $script:AboutText.Text = "Datos (ajustes e historial): $($script:DataDir)"
    $script:GridHistory.ItemsSource = $script:History
    Refresh-Clean
    if (-not $script:IsAdmin) { $script:AdminWarning.Visibility = 'Visible' }
    $window.Title = "Revix PC $($script:AppVersion)"
    $script:VersionText.Text = "Versión $($script:AppVersion)"
    $script:NavList.SelectedIndex = 0
    $script:Tabs.SelectedIndex = 0
    Update-GameChip
    Update-Home
    if ($script:Migrated) { Add-History 'Revix PC' 'Se trajeron los ajustes e historial de ActualizaPC' }
    $window.Add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
            try { [RevixPC.MaxFix]::Attach($h) } catch { Write-ErrorLog "maxfix attach: $_" }
            [RevixPC.Native]::SetDarkTitleBar($h, ($script:CurrentTheme -eq 'Dark'))
            [RevixPC.Native]::SetRoundCorners($h)
            if (Test-Path $script:IconPath) {
                $script:IconBig = New-Object System.Drawing.Icon($script:IconPath, 256, 256)
                $script:IconSmall = New-Object System.Drawing.Icon($script:IconPath, 16, 16)
                [RevixPC.Native]::SetIcons($h, $script:IconBig.Handle, $script:IconSmall.Handle)
            }
        } catch { Write-ErrorLog "ventana: $_" }
    })
    $script:BtnWinMin.Add_Click({ $script:Window.WindowState = 'Minimized' })
    $script:BtnWinMax.Add_Click({
        if ($script:Window.WindowState -eq 'Maximized') { $script:Window.WindowState = 'Normal' } else { $script:Window.WindowState = 'Maximized' }
    })
    $script:BtnWinClose.Add_Click({ $script:Window.Close() })
    $window.Add_StateChanged({
        if ($script:Window.WindowState -eq 'Maximized') {
            $script:MaxIcon.Data = [System.Windows.Media.Geometry]::Parse('M2.5,0.5 H9.5 V7.5 M0.5,2.5 H7.5 V9.5 H0.5 Z')
            $script:BtnWinMax.ToolTip = 'Restaurar'
        } else {
            $script:MaxIcon.Data = [System.Windows.Media.Geometry]::Parse('M0.5,0.5 H9.5 V9.5 H0.5 Z')
            $script:BtnWinMax.ToolTip = 'Maximizar'
        }
    })

    $window.Add_ContentRendered({
        if ($script:FirstRenderDone) { return }
        $script:FirstRenderDone = $true
        # 1) Bienvenida (una sola vez): licencias, responsabilidad, privacidad e instalación automática
        if (-not $script:Config.WelcomeAccepted) {
            $willInstall = ($script:IsAdmin -and -not (Test-RunningInstalled) -and -not (Test-Path (Get-InstalledPs1)))
            if (-not (Show-Welcome $willInstall)) { Exit-App; return }
            $script:Config.WelcomeAccepted = $true; $script:Config.LastVersion = $script:AppVersion; Save-Config
            Add-History 'Bienvenida' 'Aviso de licencias y responsabilidad aceptado'
            if ($willInstall) {
                try { [void](Install-App); Update-InstallInfo; Add-History 'Instalar Revix PC' $script:InstallDir }
                catch { Write-ErrorLog "instalar: $_"; Show-Msg "No se pudo instalar:`n$($_.Exception.Message)`n`nPuedes intentarlo en Ajustes > Avanzado." 'Warning' | Out-Null }
            }
        }
        # 2) Novedades después de actualizar
        elseif ([string]$script:Config.LastVersion -ne $script:AppVersion) {
            $notes = [string]$script:Config.UpdateNotes
            $txt = "Revix PC se actualizó a la versión $($script:AppVersion)."
            if ($notes) { $txt += "`n`nNovedades:`n$notes" }
            $script:Config.LastVersion = $script:AppVersion; $script:Config.UpdateNotes = ''; Save-Config
            Show-Msg $txt | Out-Null
        }
        # 3) Copia suelta más nueva que la instalada: ofrecer actualizar la instalación
        if ($script:IsAdmin -and -not (Test-RunningInstalled) -and (Test-Path (Get-InstalledPs1))) {
            $instVer = Get-ScriptVersion (Get-InstalledPs1)
            if ((Compare-AppVersion $script:AppVersion $instVer) -gt 0) {
                $ans = Show-Msg "Tienes instalada la versión $instVer. ¿Actualizar la instalación a la $($script:AppVersion)?" 'Question' 'YesNo'
                if ($ans -eq 'Yes') { try { [void](Install-App); Update-InstallInfo; Add-History 'Actualizar Revix PC' "$instVer -> $($script:AppVersion)" } catch { Show-Msg "No se pudo actualizar:`n$($_.Exception.Message)" 'Warning' | Out-Null } }
            }
        }
        if (-not $script:InitialScanDone) { Start-ScanAll }
        if (-not $script:AppUpdChecked) { $script:AppUpdChecked = $true; if ($script:Config.CheckAppUpdates) { Check-AppUpdate $true } }
    })
    $window.Add_Closing({
        param($s, $e)
        if (-not $script:ReallyExit -and $script:Config.CloseToTray) {
            $e.Cancel = $true
            $script:Window.Hide()
            if (-not $script:TrayTipShown) {
                $script:TrayTipShown = $true
                try { $script:TrayIcon.ShowBalloonTip(5000, 'Revix PC sigue funcionando', 'Está junto al reloj. Clic derecho en el ícono > Salir para cerrarla del todo.', [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
            }
            return
        }
        if (-not $script:Exiting) {
            $script:ReallyExit = $true
            $script:Window.Dispatcher.BeginInvoke([Action]{ Exit-App }) | Out-Null
        }
    })

    if ($Tray -and $script:Config.WelcomeAccepted) {
        # Arranque con Windows: espera un poco para no ralentizar el inicio y revisa en silencio
        $script:StartupTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:StartupTimer.Interval = [TimeSpan]::FromSeconds(45)
        $script:StartupTimer.Add_Tick({
            $script:StartupTimer.Stop()
            if (Test-GameMode) { $script:DeferredAuto = $true } else { $script:AutoRound = $true; Start-ScanAll }
            if ($script:Config.CheckAppUpdates -and -not $script:AppUpdChecked) { $script:AppUpdChecked = $true; Check-AppUpdate $true }
        })
        $script:StartupTimer.Start()
    } else {
        $window.Show()
    }
    # Desde aqui, un error en un boton no debe cerrar la app
    $ErrorActionPreference = 'Continue'
    $script:App.Add_DispatcherUnhandledException({
        param($s, $e)
        Write-ErrorLog ("Error no controlado: " + $e.Exception.ToString())
        $e.Handled = $true
    })
    [void]$script:App.Run()
}
catch {
    Write-ErrorLog ($_ | Out-String)
    try { $script:TrayIcon.Visible = $false } catch {}
    [System.Windows.MessageBox]::Show("Revix PC tuvo un error al abrir:`n`n$($_.Exception.Message)`n`nDetalle guardado en:`n$script:ErrorLog", 'Revix PC', 'OK', 'Error') | Out-Null
}
