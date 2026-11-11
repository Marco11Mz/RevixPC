# ===================================================================
#  Revix PC 4.3.0  -  Programas, Windows Update, drivers y salud de la PC
#  Windows 10/11 - Windows PowerShell 5.1 (viene con Windows)
#  Autor: Marco11  ·  Licencia MIT  ·  https://github.com/Marco11Mz/RevixPC
#  Se abre con RevixPC.exe (lo instala RevixPC-Setup-x.y.z.exe).
# ===================================================================
param([switch]$NoElevate, [switch]$Tray)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'Revix PC'
$script:AppVersion = '4.4.0'
$script:AppId      = 'Marco11.RevixPC'
$script:GitHubRepo = 'Marco11Mz/RevixPC'
$script:GitHubUrl  = "https://github.com/$($script:GitHubRepo)"
$script:AppDir     = $PSScriptRoot
$script:IconPath   = Join-Path $PSScriptRoot 'RevixPC.ico'
if (-not (Test-Path $script:IconPath) -and (Test-Path (Join-Path $PSScriptRoot 'ActualizaPC.ico'))) { $script:IconPath = Join-Path $PSScriptRoot 'ActualizaPC.ico' }
$script:InstallDir = Join-Path $env:ProgramFiles 'Revix PC'
$script:PsExe      = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Entrada de desinstalación que crea el instalador (Inno Setup agrega "_is1")
$script:SetupKey   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RevixPC_is1'

# ---------- STA + permisos de administrador ----------
# Lo normal es abrir RevixPC.exe, que ya pide administrador y carga este archivo.
# Esto solo se usa si alguien ejecuta el .ps1 a mano (copia portátil o pruebas).
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needSta = ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')
if ($needSta -or (-not $script:IsAdmin -and -not $NoElevate)) {
    $launcher = Join-Path $PSScriptRoot 'RevixPC.exe'
    if (Test-Path -LiteralPath $launcher) {
        try {
            if ($Tray) { Start-Process -FilePath $launcher -ArgumentList '-Tray' -ErrorAction Stop } else { Start-Process -FilePath $launcher -ErrorAction Stop }
            exit
        } catch { }   # si no se acepta el aviso de administrador, sigue sin permisos (solo puede escanear)
    }
    if ($needSta) {
        Add-Type -AssemblyName System.Windows.Forms
        $msg = 'Open Revix PC with RevixPC.exe.'
        if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'es') { $msg = 'Abre Revix PC con RevixPC.exe.' }
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'Revix PC')
        exit
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

$script:DataDir    = Join-Path $env:APPDATA 'RevixPC'
$script:OldDataDir = Join-Path $env:APPDATA 'ActualizaPC'
$script:ErrorLog   = Join-Path $env:TEMP 'RevixPC-error.log'
function Write-ErrorLog([string]$text) {
    try { Add-Content -Path $script:ErrorLog -Value ("[{0}] {1}" -f (Get-Date), $text) -Encoding UTF8 } catch {}
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
    // Idioma de la interfaz: true = inglés (lo fija el script al abrir)
    public static class Lang { public static bool En; }
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
        public string StateText { get { return Lang.En ? (Ignored ? "Ignored" : (Skipped ? "Version skipped" : (Auto ? "Automatic" : ""))) : (Ignored ? "Ignorado" : (Skipped ? "Versión saltada" : (Auto ? "Automático" : ""))); } }
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
        public bool PendingReboot { get; set; }
        public bool CanSelect { get { return !PendingReboot; } }
        public string StatusText { get; set; }
        public string StatusColor { get; set; }
        public object StatusBrush { get; set; }
        public string Note { get; set; }
    }
    public class DeviceItem {
        public string StatusText { get; set; }
        public string StatusColor { get; set; }
        public object StatusBrush { get; set; }
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
        public bool IsNew { get; set; }
        public string Alert { get; set; }
        public int Priority { get; set; }
    }
    public class HealthRow {
        public string Section { get; set; }
        public string Item { get; set; }
        public string Value { get; set; }
        public string StatusText { get; set; }
        public string StatusColor { get; set; }
        public object StatusBrush { get; set; }
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
        string status, color, detail; object brush;
        public string Key { get; set; }
        public string Name { get; set; }
        public bool Queued { get; set; }
        public bool Open { get; set; }
        public string StatusText { get { return status; } set { status = value; N("StatusText"); } }
        public string StatusColor { get { return color; } set { color = value; N("StatusColor"); } }
        public string Detail { get { return detail; } set { detail = value; N("Detail"); } }
        public object StatusBrush { get { return brush; } set { brush = value; N("StatusBrush"); } }
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
    TempAlert = $true
    Theme = 'System'; CheckAppUpdates = $true
    WelcomeAccepted = $false; LastVersion = ''; UpdateNotes = ''
    Language = 'Auto'
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
    $it.Date = (Get-Date).ToString((Get-DateFmt) + ' HH:mm')
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
        # Se crea con ::new y se agrega con .Add() para que WPF reciba el pincel real (no un objeto envuelto de PowerShell)
        $color = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($pal[$k]))
        $b = [System.Windows.Media.SolidColorBrush]::new($color)
        $b.Freeze()
        if ($target.Resources.Contains($k)) { $target.Resources.Remove($k) }
        $target.Resources.Add($k, $b)
    }
}

# ===================================================================
#  Funciones compartidas (ventana y trabajos en segundo plano)
# ===================================================================
$script:InitScriptText = @'
# Texto en el idioma elegido (también funciona dentro de los trabajos en segundo plano)
function L([string]$es, [string]$en) { if ($env:REVIXPC_LANG -eq 'en') { return $en }; return $es }
# Formato de fecha: dd/MM/yyyy en español, yyyy-MM-dd en inglés (se entiende en cualquier país)
function Get-DateFmt { if ($env:REVIXPC_LANG -eq 'en') { return 'yyyy-MM-dd' }; return 'dd/MM/yyyy' }

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
        [pscustomobject]@{ Key = 'UserTemp';   Name = (L 'Temporales del usuario' 'User temporary files'); Default = $true;  Paths = @($env:TEMP); Note = (L 'Archivos que los programas dejan olvidados' 'Files that programs leave behind') }
        [pscustomobject]@{ Key = 'WinTemp';    Name = (L 'Temporales de Windows' 'Windows temporary files'); Default = $true;  Paths = @((Join-Path $env:WINDIR 'Temp')); Note = (L 'Carpeta Temp del sistema' 'System Temp folder') }
        [pscustomobject]@{ Key = 'WUDownload'; Name = (L 'Descargas de Windows Update' 'Windows Update downloads'); Default = $true;  Paths = @((Join-Path $env:WINDIR 'SoftwareDistribution\Download')); Note = (L 'Instaladores de actualizaciones que ya se aplicaron' 'Installers of updates that were already applied') }
        [pscustomobject]@{ Key = 'DeliveryOpt';Name = (L 'Caché de Optimización de entrega' 'Delivery Optimization cache'); Default = $true;  Paths = @((Join-Path $env:WINDIR 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')); Note = (L 'Copias de actualizaciones compartidas' 'Shared copies of updates') }
        [pscustomobject]@{ Key = 'WER';        Name = (L 'Informes de errores de Windows' 'Windows error reports'); Default = $true;  Paths = @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $la 'CrashDumps')); Note = (L 'Reportes de cierres inesperados ya enviados' 'Crash reports that were already sent') }
        [pscustomobject]@{ Key = 'Shader';     Name = (L 'Caché de sombreadores (juegos)' 'Shader cache (games)'); Default = $false; Paths = @((Join-Path $la 'D3DSCache'), (Join-Path $la 'NVIDIA\DXCache'), (Join-Path $la 'NVIDIA\GLCache'), (Join-Path $la 'AMD\DxCache'), (Join-Path $la 'AMD\DxcCache')); Note = (L 'Los juegos la vuelven a crear; puede dar tirones la primera partida' 'Games rebuild it; the first match may stutter') }
        [pscustomobject]@{ Key = 'RecycleBin'; Name = (L 'Papelera de reciclaje' 'Recycle Bin'); Default = $false; Paths = $bins; Note = (L 'Se borra definitivamente lo que hay en la papelera' 'Everything in the Recycle Bin is deleted permanently') }
        [pscustomobject]@{ Key = 'Components'; Name = (L 'Componentes viejos de Windows' 'Old Windows components'); Default = $false; Paths = @(); Note = (L 'Versiones antiguas de archivos del sistema. Tarda varios minutos' 'Old versions of system files. Takes several minutes') }
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

# ---------- Idioma (inglés / español) ----------
# "Auto" sigue el idioma de Windows: español si Windows está en español, si no inglés.
Load-Data
function Get-SystemLang {
    try { if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'es') { return 'es' } } catch {}
    return 'en'
}
$script:Lang = [string]$script:Config.Language
if ($script:Lang -ne 'es' -and $script:Lang -ne 'en') { $script:Lang = Get-SystemLang }
$env:REVIXPC_LANG = $script:Lang
[RevixPC.Lang]::En = ($script:Lang -eq 'en')

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
    $boot = $null
    try { $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch {}
    # Historial: último resultado de cada actualización (la más reciente primero)
    $last = @{}
    try {
        $n = $searcher.GetTotalHistoryCount()
        if ($n -gt 0) {
            foreach ($e in $searcher.QueryHistory(0, [Math]::Min($n, 200))) {
                $id = ''; try { $id = [string]$e.UpdateIdentity.UpdateID } catch {}
                if ($id -and -not $last.ContainsKey($id)) { $last[$id] = @{ Code = [int]$e.ResultCode; HResult = [int]$e.HResult; Date = $e.Date } }
            }
        }
    } catch {}
    foreach ($u in $res.Updates) {
        $kbs = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
        $isDriver = ($u.Type -eq 2)
        $hw = ''; $model = ''; $mfr = ''
        if ($isDriver) { try { $hw = [string]$u.DriverHardwareID; $model = [string]$u.DriverModel; $mfr = [string]$u.DriverManufacturer } catch {} }
        $id = [string]$u.Identity.UpdateID
        $h = $last[$id]
        # Instalada pero espera reiniciar: Windows la pide reinicio o el historial dice que se instaló bien
        $pending = $false
        try { if ([bool]$u.RebootRequired) { $pending = $true } } catch {}
        # (solo si se instaló después del último arranque; si no, Windows la volvió a ofrecer)
        if ($h -and ($h.Code -eq 2 -or $h.Code -eq 3) -and $boot -and ([datetime]$h.Date).ToLocalTime() -gt $boot) { $pending = $true }
        $failDate = $null; $failCode = 0
        if ($h -and $h.Code -eq 4) { $failDate = ([datetime]$h.Date).ToLocalTime(); $failCode = $h.HResult }
        [pscustomobject]@{
            Title = [string]$u.Title; UpdateId = $id; KB = $kbs
            Severity = [string]$u.MsrcSeverity; SizeMB = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1)
            IsDriver = $isDriver; DriverHardwareId = $hw; DriverModel = $model; DriverManufacturer = $mfr
            PendingReboot = $pending; FailDate = $failDate; FailCode = $failCode
        }
    }
    # Aviso general de reinicio pendiente (Windows Update o servicio de componentes)
    $reboot = $false
    try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reboot = $true } } catch {}
    try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reboot = $true } } catch {}
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { $reboot = $true } } catch {}
    [pscustomobject]@{ IsStatus = $true; RebootRequired = $reboot }
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
            $txt = switch ($code) { 2 { L 'Instalada' 'Installed' } 3 { L 'Instalada con errores' 'Installed with errors' } 4 { L 'Falló' 'Failed' } 5 { L 'Cancelada' 'Cancelled' } default { (L 'Código {0}' 'Code {0}') -f $code } }
            [pscustomobject]@{ Kind = 'done'; Key = $key; Title = [string]$u.Title; Result = $txt; Ok = ($code -eq 2 -or $code -eq 3); Reboot = [bool]$r.RebootRequired }
        } catch {
            [pscustomobject]@{ Kind = 'done'; Key = $key; Title = [string]$u.Title; Result = ('Error: ' + $_.Exception.Message); Ok = $false; Reboot = $false }
        }
    }
    foreach ($id in $UpdateIds) {
        if (-not ($list | Where-Object { [string]$_.Identity.UpdateID -eq $id })) {
            [pscustomobject]@{ Kind = 'done'; Key = $id; Title = ''; Result = (L 'Ya no estaba disponible' 'No longer available'); Ok = $false; Reboot = $false }
        }
    }
}

# Dispositivos y sus drivers + procesador, herramientas oficiales y perifericos (objetos con Type)
$script:JobDeviceScan = {
    $ErrorActionPreference = 'Stop'
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName } | ForEach-Object {
        [pscustomobject]@{
            Type = 'Drv'
            Name = [string]$_.DeviceName; DeviceClass = [string]$_.DeviceClass; Manufacturer = [string]$_.Manufacturer
            Provider = [string]$_.DriverProviderName; Version = [string]$_.DriverVersion; Date = $_.DriverDate
            HardwareId = [string]$_.HardWareID
        }
    }
    $ErrorActionPreference = 'Continue'

    # Herramientas oficiales instaladas (solo se lee el registro, no se conecta a internet)
    try {
        $apps = @(foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
        })
        $tools = @(
            @{ Key = 'NVIDIA';     Match = '^NVIDIA App';                             Exe = (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe') }
            @{ Key = 'AMD';        Match = '^AMD Software';                           Exe = (Join-Path $env:ProgramFiles 'AMD\CNext\CNext\RadeonSoftware.exe') }
            @{ Key = 'AMDChipset'; Match = '^AMD Chipset Software';                   Exe = '' }
            @{ Key = 'Intel';      Match = 'Intel.*Driver (&|and) Support Assistant'; Exe = '' }
        )
        foreach ($t in $tools) {
            $a = $apps | Where-Object { [string]$_.DisplayName -match $t.Match } | Select-Object -First 1
            if ($a) {
                $exe = ''; if ($t.Exe -and (Test-Path -LiteralPath $t.Exe)) { $exe = $t.Exe }
                [pscustomobject]@{ Type = 'Tool'; Key = $t.Key; Name = [string]$a.DisplayName; Version = [string]$a.DisplayVersion; Exe = $exe }
            }
        }
    } catch {}

    # Procesador: modelo, microcodigo en uso y placa madre
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $bb = Get-CimInstance Win32_BaseBoard
        $mc = ''
        $raw = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).'Update Revision'
        if ($raw -is [byte[]] -and $raw.Length -ge 8) {
            $v = [BitConverter]::ToUInt32($raw, 4); if ($v -eq 0) { $v = [BitConverter]::ToUInt32($raw, 0) }
            if ($v) { $mc = '0x{0:X}' -f $v }
        }
        [pscustomobject]@{ Type = 'Cpu'; Name = ([string]$cpu.Name).Trim(); Manufacturer = [string]$cpu.Manufacturer; Microcode = $mc
                           BoardMfr = ([string]$bb.Manufacturer).Trim(); BoardProduct = ([string]$bb.Product).Trim() }
    } catch {}

    # Perifericos USB y Bluetooth (teclados, mouse, audio, camaras, controles)
    try {
        $all = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        $byId = @{}; foreach ($p in $all) { $byId[([string]$p.InstanceId).ToUpper()] = $p }
        function Get-Prop([string]$iid, [string]$key) { try { return (Get-PnpDeviceProperty -InstanceId $iid -KeyName $key -ErrorAction Stop).Data } catch { return $null } }
        $genericRx = '^\s*$|^(USB|HID)[ -]?(Input|Composite|Keyboard|Device|Audio|compliant|Mouse|PnP)|Composite|compuesto|Input Device|dispositivo de entrada|HID[- ]compliant|compatible con HID|Teclado HID|^Dispositivo|Enumerator|Enumerador'
        $classes = 'Keyboard', 'Mouse', 'Media', 'Camera', 'Image', 'XnaComposite', 'HIDClass'
        $groups = [ordered]@{}
        foreach ($p in $all) {
            $cls = [string]$p.Class
            if ($classes -notcontains $cls) { continue }
            $id = ([string]$p.InstanceId).ToUpper()
            if ($id -notmatch 'VID[_&]([0-9A-F]{4,8})') { continue }
            $vid = $matches[1]; $vid = $vid.Substring($vid.Length - 4)
            if ($id -notmatch 'PID[_&]([0-9A-F]{4})') { continue }
            $prod = $matches[1]
            if ($vid -eq '0000') { continue }
            $key = "$vid|$prod"
            if (-not $groups.Contains($key)) { $groups[$key] = @{ Vid = $vid; Pid = $prod; Classes = @(); Ids = @(); Names = @(); Bt = $false; Main = ''; MainScore = 99999 } }
            $g = $groups[$key]
            $g.Classes += $cls; $g.Ids += $id; $g.Names += [string]$p.FriendlyName
            # La primera interfaz (MI_00 / COL01) dice que es: un mouse gamer tambien trae una interfaz de teclado para macros
            if ($cls -eq 'Keyboard' -or $cls -eq 'Mouse') {
                $sc = 0
                if ($id -match '&MI_([0-9A-F]{2})') { $sc += 100 * [Convert]::ToInt32($matches[1], 16) }
                if ($id -match '&COL([0-9A-F]{2})') { $sc += [Convert]::ToInt32($matches[1], 16) }
                if ($sc -lt $g.MainScore) { $g.MainScore = $sc; $g.Main = $cls }
            }
            if ($id -match '^BTH' -or $id -match '\{0000(1124|1812)-') { $g.Bt = $true }
        }
        foreach ($g in $groups.Values) {
            $name = ''; $rev = ''
            if (-not $g.Bt) {
                $usb = @($all | Where-Object { ([string]$_.InstanceId).ToUpper() -like "USB\VID_$($g.Vid)&PID_$($g.Pid)*" })
                $top = @($usb | Where-Object { ([string]$_.InstanceId) -notmatch '&MI_' }) + $usb | Select-Object -First 1
                if ($top) {
                    $name = [string](Get-Prop $top.InstanceId 'DEVPKEY_Device_BusReportedDeviceDesc')
                    foreach ($h in @(Get-Prop $top.InstanceId 'DEVPKEY_Device_HardwareIds')) { if ([string]$h -match 'REV_([0-9A-F]{4})') { $rev = $matches[1]; break } }
                    if ($name -match $genericRx -and [string]$top.FriendlyName -notmatch $genericRx) { $name = [string]$top.FriendlyName }
                }
            } else {
                foreach ($i in $g.Ids) { if ($i -match 'REV&([0-9A-F]{4})') { $rev = $matches[1]; break } }
                # Subir por los "padres" hasta el dispositivo Bluetooth, que tiene el nombre real
                $cur = $g.Ids[0]
                for ($n = 0; $n -lt 4 -and -not $name; $n++) {
                    $par = [string](Get-Prop $cur 'DEVPKEY_Device_Parent')
                    if (-not $par) { break }
                    $pd = $byId[$par.ToUpper()]
                    if ($pd -and [string]$pd.FriendlyName -and [string]$pd.FriendlyName -notmatch $genericRx -and [string]$pd.InstanceId -match '^BTH') { $name = [string]$pd.FriendlyName }
                    $cur = $par
                }
            }
            if (-not $name -or $name -match $genericRx) { $name = [string]($g.Names | Where-Object { $_ -and $_ -notmatch $genericRx } | Select-Object -First 1) }
            $cl = $g.Classes
            $kind = 'Other'
            if ($cl -contains 'Keyboard' -and $cl -contains 'Mouse' -and $name -match 'Receiver|Receptor|Dongle|Unifying|Lightspeed|Wireless') { $kind = 'Receiver' }
            elseif ($cl -contains 'Mouse' -and $cl -notcontains 'Keyboard') { $kind = 'Mouse' }
            elseif ($cl -contains 'Keyboard' -and $cl -notcontains 'Mouse') { $kind = 'Keyboard' }
            elseif ($cl -contains 'Keyboard') { if ($name -match 'Mouse|Rat[oó]n') { $kind = 'Mouse' } elseif ($name -match 'Keyboard|Teclado') { $kind = 'Keyboard' } else { $kind = $g.Main } }
            elseif ($cl -contains 'Camera' -or $cl -contains 'Image') { $kind = 'Camera' }
            elseif ($cl -contains 'Media') { $kind = 'Audio' }
            elseif ($cl -contains 'XnaComposite' -or $name -match 'Controller|Gamepad|Mando|Joystick') { $kind = 'Controller' }
            # Solo HID sin nombre real: no se muestra (sensores, interfaces internas)
            if ($kind -eq 'Other' -and (-not $name -or $name -match $genericRx)) { continue }
            if ($kind -ne 'Receiver' -and $name -match 'Receiver|Receptor|Dongle') { $kind = 'Receiver' }
            [pscustomobject]@{ Type = 'Periph'; Vid = $g.Vid; Pid = $g.Pid; Name = $name; Kind = $kind; Bluetooth = [bool]$g.Bt; Rev = $rev }
        }
    } catch {}
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
                    # Sin detener servicios: lo que Windows Update esté usando se salta
                    foreach ($p in $c.Paths) { Clear-FolderContent $p }
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
        @{ Reg = "HKCU:\$base\Run"; Appr = "HKCU:\$base\Explorer\StartupApproved\Run"; Loc = (L 'Registro (tu usuario)' 'Registry (your user)') }
        @{ Reg = "HKLM:\$base\Run"; Appr = "HKLM:\$base\Explorer\StartupApproved\Run"; Loc = (L 'Registro (todos)' 'Registry (all users)') }
        @{ Reg = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Appr = "HKLM:\$base\Explorer\StartupApproved\Run32"; Loc = (L 'Registro (todos, 32 bits)' 'Registry (all users, 32-bit)') }
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
        @{ Dir = [Environment]::GetFolderPath('Startup'); Appr = "HKCU:\$base\Explorer\StartupApproved\StartupFolder"; Loc = (L 'Carpeta Inicio (tu usuario)' 'Startup folder (your user)') }
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "HKLM:\$base\Explorer\StartupApproved\StartupFolder"; Loc = (L 'Carpeta Inicio (todos)' 'Startup folder (all users)') }
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
            if ($d -match '^\d{8}$') { try { $date = [datetime]::ParseExact($d, 'yyyyMMdd', $null).ToString((Get-DateFmt)) } catch {} }
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
        $sw = 'Windows'
        Row $sw (L 'Edición' 'Edition') $os.Caption
        $disp = [string]$cv.DisplayVersion; if (-not $disp) { $disp = [string]$cv.ReleaseId }
        Row $sw (L 'Versión' 'Version') ((L '{0} (compilación {1}.{2})' '{0} (build {1}.{2})') -f $disp, $cv.CurrentBuild, $cv.UBR)
        Row $sw (L 'Instalado el' 'Installed on') ($os.InstallDate.ToString((Get-DateFmt)))
    } catch {}
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $sc = L 'Procesador' 'Processor'
        Row $sc (L 'Modelo' 'Model') ($cpu.Name.Trim())
        Row $sc (L 'Núcleos / hilos' 'Cores / threads') ("$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)")
        Row $sc (L 'Velocidad base' 'Base speed') ('{0:N2} GHz' -f ($cpu.MaxClockSpeed / 1000))
    } catch {}
    try {
        $mods = @(Get-CimInstance Win32_PhysicalMemory)
        $total = ($mods | Measure-Object -Property Capacity -Sum).Sum
        $slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum
        $sm = L 'Memoria RAM' 'Memory (RAM)'
        Row $sm 'Total' ('{0:N0} GB' -f ($total / 1GB))
        Row $sm (L 'Módulos' 'Modules') ((L '{0} de {1} ranuras' '{0} of {1} slots') -f $mods.Count, $slots)
        foreach ($m in $mods) {
            $rated = [int]$m.Speed; $conf = [int]$m.ConfiguredClockSpeed
            $note = ''
            if ($rated -gt 0 -and $conf -gt 0 -and $conf -lt $rated) { $note = (L 'Trabaja a {0} de {1} MT/s: revisa XMP en la BIOS' 'Running at {0} of {1} MT/s: check XMP in the BIOS') -f $conf, $rated }
            $pn = ([string]$m.PartNumber).Trim()
            Row $sm ([string]$m.DeviceLocator) ('{0:N0} GB · {1} MT/s · {2} {3}' -f ($m.Capacity / 1GB), $conf, $m.Manufacturer, $pn) $note
        }
    } catch {}
    try {
        $bb = Get-CimInstance Win32_BaseBoard; $b = Get-CimInstance Win32_BIOS
        $sbrd = L 'Placa madre' 'Motherboard'
        Row $sbrd (L 'Modelo' 'Model') ("$($bb.Manufacturer) $($bb.Product)")
        Row $sbrd 'BIOS' ("$($b.SMBIOSBIOSVersion) ($($b.ReleaseDate.ToString((Get-DateFmt))))")
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
            Row (L 'Video' 'Graphics') (L 'Tarjeta' 'Card') $txt ("Driver " + $v.DriverVersion)
            if ($v.CurrentHorizontalResolution) { Row (L 'Video' 'Graphics') (L 'Pantalla' 'Display') ((L '{0} x {1} a {2} Hz' '{0} x {1} at {2} Hz') -f $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate) }
        }
    } catch {}
    try {
        foreach ($d in Get-PhysicalDisk -ErrorAction Stop) {
            $media = [string]$d.MediaType; if ($media -eq 'Unspecified') { $media = '' }
            Row (L 'Discos' 'Disks') ([string]$d.FriendlyName) (("$media $($d.BusType)").Trim() + (' · {0:N0} GB' -f ($d.Size / 1GB)))
        }
    } catch {}
    try {
        foreach ($a in Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }) {
            Row (L 'Red' 'Network') ([string]$a.Name) ("$($a.InterfaceDescription) · $($a.LinkSpeed)")
        }
    } catch {}
    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        if ($bat.Count -gt 0) {
            $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
            $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
            $cycles = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount
            $sbat = L 'Batería' 'Battery'
            Row $sbat (L 'Carga actual' 'Current charge') ("$($bat[0].EstimatedChargeRemaining) %")
            if ($design -and $full) {
                $pct = [math]::Round(100 * $full / $design)
                $note = ''; if ($pct -lt 60) { $note = L 'Batería gastada: conviene cambiarla' 'Worn battery: consider replacing it' } elseif ($pct -lt 80) { $note = L 'Desgaste normal por uso' 'Normal wear from use' }
                Row $sbat (L 'Salud' 'Health') ((L '{0} % ({1:N1} de {2:N1} Wh)' '{0} % ({1:N1} of {2:N1} Wh)') -f $pct, ($full / 1000), ($design / 1000)) $note
            }
            if ($cycles) { Row $sbat (L 'Ciclos de carga' 'Charge cycles') $cycles }
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
        if ($_.Exception.Message -match '404') { throw (L 'Todavía no hay versiones publicadas en GitHub.' 'There are no versions published on GitHub yet.') }
        throw ((L 'No se pudo conectar con GitHub: {0}' 'Could not connect to GitHub: {0}') -f $_.Exception.Message)
    }
    # Desde la 4.2.1 se actualiza con el instalador: RevixPC-Setup-x.y.z.exe
    $asset = @($r.assets) | Where-Object { [string]$_.name -match '^RevixPC-Setup-[\d.]+\.exe$' } | Select-Object -First 1
    $digest = ''
    if ($asset -and $asset.PSObject.Properties['digest']) { $digest = [string]$asset.digest }
    $setup = ''; if ($asset) { $setup = [string]$asset.browser_download_url }
    [pscustomobject]@{ Version = ([string]$r.tag_name).TrimStart([char[]]'vV'); Setup = $setup; Notes = [string]$r.body; Digest = $digest; Page = [string]$r.html_url }
}
# ===================================================================
#  Logica: clasificar actualizaciones, dispositivos y salud
# ===================================================================
$script:Links = @{
    NVIDIA   = (L 'https://www.nvidia.com/es-la/drivers/' 'https://www.nvidia.com/en-us/drivers/')
    AMD      = (L 'https://www.amd.com/es/support/download/drivers.html' 'https://www.amd.com/en/support/download/drivers.html')
    Intel    = (L 'https://www.intel.la/content/www/xl/es/support/detect.html' 'https://www.intel.com/content/www/us/en/support/detect.html')
}
# Marca por el código USB del fabricante (VID). Los "chips" los usan muchas marcas distintas.
$script:UsbBrands = @{
    '046D' = 'Logitech'; '1532' = 'Razer'; '0951' = 'HyperX'; '03F0' = 'HP'; '1B1C' = 'Corsair'; '1038' = 'SteelSeries'
    '0B05' = 'ASUS'; '1E7D' = 'ROCCAT'; '045E' = 'Microsoft'; '054C' = 'Sony'; '057E' = 'Nintendo'; '3434' = 'Keychron'
    '31E3' = 'Wooting'; '2516' = 'Cooler Master'; '0738' = 'Mad Catz'; '0DB0' = 'MSI'; '1462' = 'MSI'; '413C' = 'Dell'
    '17EF' = 'Lenovo'; '24AE' = 'Rapoo'; '28DE' = 'Valve'; '1395' = 'EPOS'; '047F' = 'Poly'; '0B0E' = 'Jabra'; '2DC8' = '8BitDo'
}
$script:UsbChips = @{
    '258A' = 'Sino Wealth'; '3554' = 'CompX'; '093A' = 'PixArt'; '04D9' = 'Holtek'; '0C45' = 'Microdia'; '1A86' = 'QinHeng'
    '0D8C' = 'C-Media'; '25A7' = 'Areson'; '1A2C' = 'China Resource Semico'
}
# Marcas que se reconocen por el nombre real del producto (HyperX nuevo usa el VID de HP, ATK/VXE usan chips genéricos, etc.)
$script:NameBrandRx = '\b(Logitech|Razer|HyperX|Corsair|SteelSeries|ASUS|ROG|ROCCAT|Redragon|ATK|VXE|VGN|Lamzu|Pulsar|Zowie|Glorious|Endgame|Finalmouse|Keychron|Wooting|Akko|Aula|Fantech|Xtrfy|Cooler ?Master|MSI|Turtle ?Beach|Sennheiser|EPOS|JBL|Trust|Genius|Havit|Rapoo|Xbox|DualSense|DualShock|8BitDo|Fifine|Elgato|Moondrop)\b'
$script:BrandAlias = @{ 'ROG' = 'ASUS'; 'Xbox' = 'Microsoft'; 'DualSense' = 'Sony'; 'DualShock' = 'Sony'; 'CoolerMaster' = 'Cooler Master'; 'TurtleBeach' = 'Turtle Beach' }
# Software oficial (solo se abre la página; Revix PC no descarga ni instala nada)
function Get-BrandSoftware([string]$brand, [string]$name) {
    switch ($brand) {
        'Logitech' {
            if ($name -match '\bG\s?\d|\bPRO\b|Lightspeed|Gaming|ASTRO') { return @{ Name = 'Logitech G HUB'; Short = 'G HUB'; Link = 'https://www.logitechg.com/innovation/g-hub.html' } }
            if ($name -match '\bMX\b|Ergo|Lift|Pebble|Signature|Bolt|Unifying') { return @{ Name = 'Logi Options+'; Short = 'Options+'; Link = 'https://www.logitech.com/software/logi-options-plus.html' } }
            return @{ Name = (L 'el software de Logitech' 'Logitech software'); Short = 'Logitech'; Link = 'https://support.logi.com/' }
        }
        'Razer'       { return @{ Name = 'Razer Synapse'; Short = 'Synapse'; Link = 'https://www.razer.com/synapse-4' } }
        'HyperX'      { return @{ Name = 'HyperX NGENUITY'; Short = 'NGENUITY'; Link = 'https://hyperx.com/pages/ngenuity' } }
        'Corsair'     { return @{ Name = 'Corsair iCUE'; Short = 'iCUE'; Link = 'https://www.corsair.com/us/en/explorer/icue/' } }
        'SteelSeries' { return @{ Name = 'SteelSeries GG'; Short = 'GG'; Link = 'https://steelseries.com/gg' } }
        'ASUS'        { return @{ Name = 'Armoury Crate'; Short = 'Armoury Crate'; Link = 'https://rog.asus.com/armoury-crate/' } }
        'Wooting'     { return @{ Name = 'Wootility'; Short = 'Wootility'; Link = 'https://wootility.io/' } }
    }
    return $null
}

# 32.0.15.6636 (Windows) -> 566.36 (NVIDIA)
function Convert-NvidiaVersion([string]$v) {
    $digits = ($v -replace '[^\d]', '')
    if ($digits.Length -lt 5) { return '' }
    $last = $digits.Substring($digits.Length - 5)
    return $last.Substring(0, 3) + '.' + $last.Substring(3)
}
# Revisión USB (bcdDevice) 0402 -> 4.02
function Convert-UsbRev([string]$r) {
    if ($r -notmatch '^[0-9]{4}$') { return $r }
    return ('{0}.{1}' -f [int]$r.Substring(0, 2), $r.Substring(2))
}
# Colores sólidos para las pastillas de estado (texto blanco encima, se leen en tema claro y oscuro)
$script:C = @{ Green = '#15803D'; Amber = '#B45309'; Red = '#DC2626'; Blue = '#2563EB'; Gray = '#64748B'; Purple = '#7C3AED' }
# Pincel real para el fondo de las pastillas (WPF no siempre convierte el texto "#RRGGBB" en color)
$script:BrushCache = @{}
function Set-StatusBrush($obj) {
    $c = [string]$obj.StatusColor
    if (-not $c) { return }
    if (-not $script:BrushCache.ContainsKey($c)) {
        $col = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($c))
        $b = [System.Windows.Media.SolidColorBrush]::new($col)
        $b.Freeze()
        $script:BrushCache[$c] = $b
    }
    $obj.StatusBrush = $script:BrushCache[$c]
}

function Get-UpdateKind($u) {
    if ($u.IsDriver) { return 'Driver' }
    if ($u.Severity) { return (L 'Seguridad' 'Security') }
    $t = [string]$u.Title
    if ($t -match 'acumulativa|Cumulative') { return (L 'Acumulativa' 'Cumulative') }
    if ($t -match 'Defender|inteligencia de seguridad|Security Intelligence|antimalware') { return 'Defender' }
    if ($t -match '\.NET') { return '.NET' }
    if ($t -match 'Office|Microsoft 365') { return 'Office' }
    return (L 'Otra' 'Other')
}

function Get-SeverityText([string]$s) {
    switch ($s) {
        'Critical'  { return (L 'Crítica' 'Critical') }
        'Important' { return (L 'Importante' 'Important') }
        'Moderate'  { return (L 'Moderada' 'Moderate') }
        'Low'       { return (L 'Baja' 'Low') }
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
    if ($hex -eq '0x8A15002B') { return (L 'No hay actualización aplicable para esta instalación' 'No applicable update for this installation') }
    return ((L 'Código {0}' 'Code {0}') -f $hex)
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
    if ($score -ge 85) { return @((L 'Tu PC está en buen estado' 'Your PC is in good shape'), '#22C55E') }
    if ($score -ge 60) { return @((L 'Tu PC necesita algunas actualizaciones' 'Your PC needs a few updates'), '#F59E0B') }
    return @((L 'Tu PC necesita atención' 'Your PC needs attention'), '#EF4444')
}

# Herramienta oficial de cada marca de video: si está instalada se abre, si no, su página oficial
function Get-GpuTool([string]$vendor, $tools) {
    $t = @($tools | Where-Object { $_.Key -eq $vendor }) | Select-Object -First 1
    switch ($vendor) {
        'NVIDIA' {
            if ($t -and $t.Exe) { return @{ Name = 'NVIDIA App'; Link = [string]$t.Exe; Action = (L 'Abrir NVIDIA App' 'Open NVIDIA App') } }
            return @{ Name = 'NVIDIA App'; Link = (L 'https://www.nvidia.com/es-la/software/nvidia-app/' 'https://www.nvidia.com/en-us/software/nvidia-app/'); Action = (L 'Descargar NVIDIA App' 'Get NVIDIA App') }
        }
        'AMD' {
            if ($t -and $t.Exe) { return @{ Name = 'AMD Software'; Link = [string]$t.Exe; Action = (L 'Abrir AMD Software' 'Open AMD Software') } }
            return @{ Name = 'AMD Software'; Link = $script:Links.AMD; Action = (L 'Abrir AMD' 'Open AMD') }
        }
        default { return @{ Name = (L 'el asistente de Intel' 'Intel''s assistant'); Link = $script:Links.Intel; Action = (L 'Abrir Intel' 'Open Intel') } }
    }
}

function New-DeviceItem([string]$name, [string]$cls, [string]$mfr, [string]$ver, [string]$date, [string]$status, [string]$color, [int]$prio, [string]$note, [string]$link = '', [string]$action = '', [string]$alert = '') {
    $it = New-Object RevixPC.DeviceItem
    $it.Name = $name; $it.DeviceClass = $cls; $it.Manufacturer = $mfr; $it.Version = $ver; $it.Date = $date
    $it.StatusText = $status; $it.StatusColor = $color; $it.Priority = $prio; $it.Note = $note
    $it.Link = $link; $it.ActionText = $action; $it.HasLink = [bool]$link
    $it.Alert = $alert; $it.IsNew = [bool]$alert
    Set-StatusBrush $it
    return $it
}

# Procesador (+ chipset AMD)
function Get-CpuItems($cpu, $tools) {
    $out = @()
    if (-not $cpu) { return $out }
    $name = [string]$cpu.Name
    $isIntel = ([string]$cpu.Manufacturer -match 'Intel' -or $name -match 'Intel')
    $isAmd = ([string]$cpu.Manufacturer -match 'AMD' -or $name -match '\bAMD\b')
    $mfr = ''; if ($isIntel) { $mfr = 'Intel' } elseif ($isAmd) { $mfr = 'AMD' }
    $mc = [string]$cpu.Microcode
    $mcVal = 0; if ($mc) { try { $mcVal = [Convert]::ToUInt32($mc.Substring(2), 16) } catch { $mcVal = 0 } }
    $board = ((([string]$cpu.BoardMfr) + ' ' + ([string]$cpu.BoardProduct)).Trim())
    $biosLink = ''; if ([string]$cpu.BoardProduct) { $biosLink = 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$board BIOS") }
    $cls = L 'Procesador' 'Processor'
    $verTxt = ''; if ($mc) { $verTxt = (L 'Microcódigo {0}' 'Microcode {0}') -f $mc }

    # Intel Core 13.ª/14.ª gen de escritorio: problema de inestabilidad (arreglo: microcódigo 0x12B o más nuevo)
    $raptor = $isIntel -and ($name -match '\bi(7|9)-1[34]\d{3}(K|KF|KS|F|T)?\b' -or $name -match '\bi5-1[34][5-9]\d{2}(K|KF|F|T)?\b')
    if ($raptor) {
        if ($mcVal -gt 0 -and $mcVal -lt 0x12B) {
            $out += New-DeviceItem $name $cls $mfr $verTxt '' (L 'Actualiza la BIOS' 'Update the BIOS') $script:C.Red 0 `
                ((L 'Intel publicó un arreglo para la inestabilidad de los Core 13.ª y 14.ª gen (microcódigo 0x12B o más nuevo). Tienes {0}. Instala la BIOS más reciente desde la web de tu placa ({1}).' 'Intel released a fix for the instability of 13th and 14th Gen Core processors (microcode 0x12B or newer). You have {0}. Install the latest BIOS from your motherboard''s website ({1}).') -f $mc, $board) `
                $biosLink (L 'Buscar BIOS' 'Search BIOS') (L 'Actualiza la BIOS de tu PC' 'Update your PC''s BIOS')
        } elseif ($mcVal -ge 0x12B) {
            $out += New-DeviceItem $name $cls $mfr $verTxt '' (L 'Con el arreglo de Intel' 'Has Intel''s fix') $script:C.Green 2 `
                ((L 'Tu procesador ya tiene el arreglo de Intel para los 13.ª/14.ª gen ({0}; hace falta 0x12B o más nuevo).' 'Your processor already has Intel''s fix for 13th/14th Gen ({0}; 0x12B or newer is needed).') -f $mc)
        } else {
            $out += New-DeviceItem $name $cls $mfr $verTxt '' (L 'Revisa la BIOS' 'Check the BIOS') $script:C.Amber 1 `
                (L 'Intel publicó un arreglo para los Core 13.ª/14.ª gen. No se pudo leer el microcódigo: revisa que tu BIOS sea de septiembre de 2024 o más nueva.' 'Intel released a fix for 13th/14th Gen Core. The microcode could not be read: check that your BIOS is from September 2024 or newer.') `
                $biosLink (L 'Buscar BIOS' 'Search BIOS')
        }
    } elseif ($isIntel) {
        $out += New-DeviceItem $name $cls $mfr $verTxt '' (L 'Sin avisos' 'No warnings') $script:C.Green 2 `
            (L 'El microcódigo lo actualizan la BIOS y Windows Update. El asistente de Intel revisa chipset y otros drivers Intel.' 'Microcode is updated by the BIOS and Windows Update. Intel''s assistant checks the chipset and other Intel drivers.') `
            $script:Links.Intel (L 'Abrir Intel' 'Open Intel')
    } else {
        $out += New-DeviceItem $name $cls $mfr $verTxt '' (L 'Sin avisos' 'No warnings') $script:C.Green 2 `
            (L 'El microcódigo lo actualizan la BIOS y Windows Update.' 'Microcode is updated by the BIOS and Windows Update.')
    }

    if ($isAmd) {
        $t = @($tools | Where-Object { $_.Key -eq 'AMDChipset' }) | Select-Object -First 1
        if ($t) {
            $out += New-DeviceItem 'AMD Chipset Software' 'Chipset' 'AMD' ([string]$t.Version) '' (L 'Instalado' 'Installed') $script:C.Green 2 `
                (L 'Se actualiza desde la web de AMD o la de tu placa' 'Updated from AMD''s or your motherboard''s website') $script:Links.AMD (L 'Abrir AMD' 'Open AMD')
        } else {
            $out += New-DeviceItem (L 'Drivers del chipset AMD' 'AMD chipset drivers') 'Chipset' 'AMD' '' '' (L 'No instalado' 'Not installed') $script:C.Blue 1 `
                (L 'Recomendado: el detector de AMD lo encuentra solo. En laptops usa el de la marca de la laptop.' 'Recommended: AMD''s detection tool finds it. On laptops use the one from the laptop maker.') $script:Links.AMD (L 'Abrir AMD' 'Open AMD')
        }
    }
    return $out
}

# Periféricos de cualquier marca
function Get-PeripheralItem($p) {
    $name = ([string]$p.Name).Trim()
    $brand = ''; $chip = ''
    if ($name -match $script:NameBrandRx) {
        $brand = $matches[1]; $k = $brand -replace ' ', ''
        if ($script:BrandAlias.ContainsKey($k)) { $brand = $script:BrandAlias[$k] } elseif ($script:BrandAlias.ContainsKey($brand)) { $brand = $script:BrandAlias[$brand] }
    }
    if (-not $brand -and $script:UsbBrands.ContainsKey([string]$p.Vid)) { $brand = $script:UsbBrands[[string]$p.Vid] }
    if (-not $brand -and $script:UsbChips.ContainsKey([string]$p.Vid)) { $chip = $script:UsbChips[[string]$p.Vid] }

    $kinds = @{
        Keyboard = (L 'Teclado' 'Keyboard'); Mouse = 'Mouse'; Audio = 'Audio'; Camera = (L 'Cámara' 'Camera')
        Controller = (L 'Control' 'Controller'); Receiver = (L 'Receptor' 'Receiver'); Other = (L 'Periférico' 'Peripheral')
    }
    $kind = $kinds[[string]$p.Kind]; if (-not $kind) { $kind = $kinds.Other }
    if (-not $name) { $name = $kind; if ($brand) { $name += " $brand" } else { $name += " (USB $($p.Vid):$($p.Pid))" } }
    elseif ($brand -and $name -notmatch [regex]::Escape($brand)) { $name = "$brand $name" }

    if ($p.Bluetooth) { $conn = 'Bluetooth' }
    elseif ([string]$p.Kind -eq 'Receiver' -or $name -match 'Wireless|Inal[aá]mbric|2\.4') { $conn = L 'Inalámbrico (receptor USB)' 'Wireless (USB receiver)' }
    else { $conn = 'USB' }
    $ver = ''; if ($p.Rev) { $ver = (L 'rev. {0}' 'rev. {0}') -f (Convert-UsbRev ([string]$p.Rev)) }
    $mfr = $brand; if (-not $mfr -and $chip) { $mfr = (L 'Chip {0}' '{0} chip') -f $chip }

    $sw = $null; if ($brand) { $sw = Get-BrandSoftware $brand $name }
    if ($sw) {
        $note = (L '{0} · Ajustes y firmware con {1}. Actualiza el firmware solo si tienes un problema.' '{0} · Settings and firmware with {1}. Only update firmware if you have a problem.') -f $conn, $sw.Name
        if ([string]$p.Kind -eq 'Receiver') { $note = (L '{0} · El modelo exacto se ve en {1}.' '{0} · The exact model is shown in {1}.') -f $conn, $sw.Name }
        return New-DeviceItem $name $kind $mfr $ver '' (L 'Firmware opcional' 'Optional firmware') $script:C.Blue 1 $note $sw.Link ((L 'Abrir {0}' 'Open {0}') -f $sw.Short)
    }
    if ($chip) { $note = (L '{0} · Este chip lo usan varias marcas: el software (si tiene) está en la web de la marca de tu equipo.' '{0} · Several brands use this chip: the software (if any) is on your device brand''s website.') -f $conn }
    elseif ($brand) { $note = (L '{0} · Si tiene software, búscalo en la web oficial de {1}.' '{0} · If it has software, look for it on {1}''s official website.') -f $conn, $brand }
    else { $note = $conn }
    return New-DeviceItem $name $kind $mfr $ver '' (L 'Detectado' 'Detected') $script:C.Gray 2 $note
}

function ConvertTo-DeviceItems($rawDevices, $wuUpdates, $extra) {
    $driverUpdates = @($wuUpdates | Where-Object { $_.IsDriver })
    $list = New-Object 'System.Collections.Generic.List[RevixPC.DeviceItem]'
    $seen = @{}
    $now = Get-Date
    $tools = @(); $periph = @(); $cpu = $null
    if ($extra) { $tools = @($extra.Tools); $periph = @($extra.Periph); $cpu = $extra.Cpu }
    $periphKeys = @{}; foreach ($p in $periph) { $periphKeys["$($p.Vid)|$($p.Pid)"] = $true }

    foreach ($i in (Get-CpuItems $cpu $tools)) { $list.Add($i) }
    foreach ($p in $periph) { $list.Add((Get-PeripheralItem $p)) }

    foreach ($d in $rawDevices) {
        $cls = ([string]$d.DeviceClass).ToUpper()
        $hw = ([string]$d.HardwareId).ToUpper()
        $match = $driverUpdates | Where-Object {
            $uhw = ([string]$_.DriverHardwareId).ToUpper()
            ($uhw -and $hw -and ($hw -eq $uhw -or $hw.StartsWith($uhw))) -or ($_.DriverModel -and $_.DriverModel -eq $d.Name)
        } | Select-Object -First 1
        # Lo que ya salió como periférico (con su nombre real) no se repite, salvo que tenga actualización
        if (-not $match -and $hw -match 'VID[_&]([0-9A-F]{4,8})') {
            $v = $matches[1]; $v = $v.Substring($v.Length - 4)
            if ($hw -match 'PID[_&]([0-9A-F]{4})' -and $periphKeys.ContainsKey("$v|$($matches[1])")) { continue }
        }
        $key = "$($d.Name)|$($d.Version)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $date = $null
        if ($d.Date) { try { $date = [datetime]$d.Date } catch { $date = $null } }
        $dateTxt = ''; if ($date) { $dateTxt = $date.ToString((Get-DateFmt)) }
        $ver = [string]$d.Version
        $isMs = ([string]$d.Provider) -match '^Microsoft'
        $mfr  = [string]$d.Manufacturer
        $status = L 'Sin actualizaciones' 'No updates'; $color = $script:C.Green; $note = ''; $link = ''; $action = ''; $prio = 2; $generic = $false; $alert = ''

        if ($match) {
            $status = L 'Hay actualización' 'Update available'; $color = $script:C.Amber; $prio = 0
            $note = L 'Instálala desde la pestaña Windows Update' 'Install it from the Windows Update tab'
        }
        elseif ($cls -eq 'DISPLAY' -and [string]$d.Name -match 'Basic Display|Basic Render|b[aá]sico') {
            $status = L 'Falta el driver de video' 'Graphics driver missing'; $color = $script:C.Red; $prio = 0
            $note = L 'Windows usa un driver básico (sin aceleración). Instala el de tu tarjeta desde la web de NVIDIA, AMD o Intel.' 'Windows is using a basic driver (no acceleration). Install your card''s driver from NVIDIA, AMD or Intel.'
            $alert = L 'Falta el driver de video' 'Graphics driver missing'
        }
        elseif ($cls -eq 'DISPLAY' -and $mfr -match 'NVIDIA|AMD|Advanced Micro|\bATI\b|Intel') {
            $gv = 'Intel'; if ($mfr -match 'NVIDIA') { $gv = 'NVIDIA' } elseif ($mfr -match 'AMD|Advanced Micro|\bATI\b') { $gv = 'AMD' }
            if ($gv -eq 'NVIDIA') { $nvv = Convert-NvidiaVersion $ver; if ($nvv) { $ver = "$nvv ($ver)" } }
            $tool = Get-GpuTool $gv $tools
            $link = $tool.Link; $action = $tool.Action
            $months = -1; if ($date) { $months = [int][Math]::Floor(($now - $date).TotalDays / 30.4) }
            if ($months -ge 6) {
                $status = L 'Revisa si hay nuevo' 'Check for a new one'; $color = $script:C.Blue; $prio = 1
                $note = (L 'Driver de hace {0} meses. Búscalo con {1}.' 'Driver from {0} months ago. Look for a newer one with {1}.') -f $months, $tool.Name
            } elseif ($months -ge 0) {
                $status = L 'Reciente' 'Recent'; $color = $script:C.Green; $prio = 2
                $note = (L 'Driver de hace menos de 6 meses. Para confirmar si hay uno nuevo usa {0}.' 'Driver less than 6 months old. To confirm whether there is a newer one, use {0}.') -f $tool.Name
            } else {
                $status = L 'Revisar en la web' 'Check online'; $color = $script:C.Blue; $prio = 1
                $note = (L 'Revisa si hay uno nuevo con {0}.' 'Check for a newer one with {0}.') -f $tool.Name
            }
            if ($gv -ne 'NVIDIA') { $note += ' ' + (L 'En laptops, a veces conviene el driver de la marca de la laptop.' 'On laptops, the laptop maker''s driver is sometimes better.') }
        }
        elseif ($isMs) {
            $status = L 'Genérico de Windows' 'Generic Windows driver'; $color = $script:C.Gray; $prio = 3; $generic = $true
            $note = L 'Viene con Windows, no necesita nada' 'Comes with Windows, nothing to do'
        }
        elseif ($date -and $date.Year -ge 2010 -and $date -lt $now.AddYears(-3)) {
            $status = L 'Driver antiguo' 'Old driver'; $color = $script:C.Purple; $prio = 2
            $note = L 'Solo revísalo si el dispositivo da problemas' 'Only check it if the device has problems'
        }

        $it = New-DeviceItem ([string]$d.Name) ([string]$d.DeviceClass) $mfr $ver $dateTxt $status $color $prio $note $link $action $alert
        $it.IsGeneric = $generic
        $list.Add($it)
    }
    return ,@($list | Sort-Object Priority, Name)
}

function New-HealthRow([string]$section, [string]$item, [string]$value, [string]$status, [string]$color, [int]$level, [string]$link = '', [string]$action = '') {
    $r = New-Object RevixPC.HealthRow
    $r.Section = $section; $r.Item = $item; $r.Value = $value; $r.StatusText = $status; $r.StatusColor = $color
    $r.Level = $level; $r.Link = $link; $r.ActionText = $action; $r.HasLink = [bool]$link
    Set-StatusBrush $r
    return $r
}

function Get-DaysAgoText([datetime]$d) {
    $days = [int]((Get-Date) - $d).TotalDays
    if ($days -le 0) { return (L 'hoy' 'today') }
    if ($days -eq 1) { return (L 'ayer' 'yesterday') }
    return ((L 'hace {0} días' '{0} days ago') -f $days)
}

# Level: 0 = bien, 1 = aviso, 2 = problema
function ConvertTo-HealthRows($out) {
    $rows = New-Object 'System.Collections.Generic.List[RevixPC.HealthRow]'
    $C = $script:C
    $secSec = L 'Seguridad' 'Security'; $secSys = L 'Sistema' 'System'; $secDisk = L 'Discos' 'Disks'; $secStab = L 'Estabilidad' 'Stability'
    $tOn = L 'Activo' 'Active'; $tOff = L 'Apagado' 'Off'; $tGood = L 'Bien' 'Good'; $tCheck = L 'Revisar' 'Check'
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
            $rows.Add((New-HealthRow $secSec "Antivirus: $($a.Name)" (L 'En espera (otro antivirus está activo)' 'On standby (another antivirus is active)') (L 'Normal' 'Normal') $C.Gray 0)); continue
        }
        if ($on) { $rows.Add((New-HealthRow $secSec "Antivirus: $($a.Name)" (L 'Protegiendo' 'Protecting') $tOn $C.Green 0)) }
        else     { $rows.Add((New-HealthRow $secSec "Antivirus: $($a.Name)" (L 'No está protegiendo' 'Not protecting') $tOff $C.Red 2)) }
    }
    if ($def -and -not $activeThird) {
        if ($avs.Count -eq 0) {
            if ($def.On) { $rows.Add((New-HealthRow $secSec 'Antivirus: Microsoft Defender' (L 'Protegiendo' 'Protecting') $tOn $C.Green 0)) }
            else { $rows.Add((New-HealthRow $secSec 'Antivirus: Microsoft Defender' (L 'No está protegiendo' 'Not protecting') $tOff $C.Red 2)) }
        }
        if ($def.RealTime) { $rows.Add((New-HealthRow $secSec (L 'Protección en tiempo real' 'Real-time protection') (L 'Encendida' 'On') $tOn $C.Green 0)) }
        else { $rows.Add((New-HealthRow $secSec (L 'Protección en tiempo real' 'Real-time protection') (L 'Apagada' 'Off') $tCheck $C.Red 2)) }
        if ($def.SigDate) {
            $sd = [datetime]$def.SigDate; $age = ($now - $sd).TotalDays
            $txt = $sd.ToString((Get-DateFmt) + ' HH:mm') + ' (' + (Get-DaysAgoText $sd) + ')'
            if ($age -le 3) { $rows.Add((New-HealthRow $secSec (L 'Firmas del antivirus' 'Antivirus signatures') $txt (L 'Al día' 'Up to date') $C.Green 0)) }
            elseif ($age -le 7) { $rows.Add((New-HealthRow $secSec (L 'Firmas del antivirus' 'Antivirus signatures') $txt (L 'Algo antiguas' 'A bit old') $C.Amber 1)) }
            else { $rows.Add((New-HealthRow $secSec (L 'Firmas del antivirus' 'Antivirus signatures') $txt (L 'Desactualizadas' 'Outdated') $C.Red 2)) }
        }
    }
    $fwNames = @{ Domain = (L 'Dominio' 'Domain'); Private = (L 'Privada' 'Private'); Public = (L 'Pública' 'Public') }
    foreach ($f in $fws) {
        $n = $fwNames[[string]$f.Name]; if (-not $n) { $n = $f.Name }
        if ($f.Enabled) { $rows.Add((New-HealthRow $secSec ((L 'Firewall (red {0})' 'Firewall ({0} network)') -f $n) (L 'Encendido' 'On') $tOn $C.Green 0)) }
        else { $rows.Add((New-HealthRow $secSec ((L 'Firewall (red {0})' 'Firewall ({0} network)') -f $n) $tOff $tCheck $C.Amber 1)) }
    }

    # --- Sistema ---
    if ($info) {
        if ($info.OS) { $rows.Add((New-HealthRow $secSys 'Windows' $info.OS '' $C.Gray 0)) }
        if ($info.LastWU) {
            $lw = [datetime]$info.LastWU
            $txt = $lw.ToString((Get-DateFmt)) + ' (' + (Get-DaysAgoText $lw) + ')'
            if (($now - $lw).TotalDays -le 40) { $rows.Add((New-HealthRow $secSys (L 'Última actualización de Windows' 'Last Windows update') $txt $tGood $C.Green 0)) }
            else { $rows.Add((New-HealthRow $secSys (L 'Última actualización de Windows' 'Last Windows update') $txt (L 'Hace mucho' 'Long ago') $C.Amber 1)) }
        }
        if ($info.LastBoot) {
            $lb = [datetime]$info.LastBoot
            $txt = $lb.ToString((Get-DateFmt) + ' HH:mm') + ' (' + (Get-DaysAgoText $lb) + ')'
            if (($now - $lb).TotalDays -le 14) { $rows.Add((New-HealthRow $secSys (L 'Último reinicio' 'Last restart') $txt $tGood $C.Green 0)) }
            else { $rows.Add((New-HealthRow $secSys (L 'Último reinicio' 'Last restart') $txt (L 'Reinicia la PC' 'Restart the PC') $C.Amber 1)) }
        }
        if ($info.BoardProduct) {
            $board = (($info.BoardMfr + ' ' + $info.BoardProduct).Trim())
            $rows.Add((New-HealthRow $secSys (L 'Placa madre' 'Motherboard') $board '' $C.Gray 0))
        }
        if ($info.BiosVersion) {
            $q = [uri]::EscapeDataString((($info.BoardMfr + ' ' + $info.BoardProduct + ' BIOS').Trim()))
            $link = "https://www.google.com/search?q=$q"
            $txt = $info.BiosVersion
            $st = L 'Revisa si hay nueva' 'Check for a new one'; $col = $C.Blue; $lvl = 0
            if ($info.BiosDate) {
                $bd = [datetime]$info.BiosDate
                $txt += ' (' + $bd.ToString((Get-DateFmt)) + ')'
                if (($now - $bd).TotalDays -gt 730) { $st = L 'Más de 2 años' 'Over 2 years old'; $col = $C.Amber; $lvl = 1 }
                else { $st = L 'Reciente' 'Recent'; $col = $C.Green }
            }
            $rows.Add((New-HealthRow $secSys 'BIOS' $txt $st $col $lvl $link (L 'Buscar BIOS' 'Search BIOS')))
        }
    }

    # --- Discos ---
    foreach ($d in @($out | Where-Object { $_.Type -eq 'Disk' })) {
        $media = [string]$d.Media
        if ($media -eq 'Unspecified' -or -not $media) { $media = L 'Disco' 'Disk' }
        $parts = @("$media $($d.Bus)".Trim(), "$($d.SizeGB) GB")
        $lvl = 0; $st = L 'Bueno' 'Good'; $col = $C.Green
        if ($d.Temp) {
            $parts += "$($d.Temp) °C"
            if ([int]$d.Temp -ge 70) { $lvl = [Math]::Max($lvl, 2); $st = L 'Muy caliente' 'Very hot'; $col = $C.Red }
            elseif ([int]$d.Temp -ge 60) { $lvl = [Math]::Max($lvl, 1); $st = L 'Caliente' 'Hot'; $col = $C.Amber }
        }
        if ($null -ne $d.Wear -and [string]$d.Wear -ne '') {
            $parts += ((L 'desgaste {0}%' 'wear {0}%') -f $d.Wear)
            if ([int]$d.Wear -ge 90) { $lvl = 2; $st = L 'Desgaste alto' 'High wear'; $col = $C.Red }
            elseif ([int]$d.Wear -ge 70 -and $lvl -lt 2) { $lvl = 1; $st = L 'Desgaste medio' 'Medium wear'; $col = $C.Amber }
        }
        if ($d.Hours) { $parts += ((L '{0:N0} h encendido' '{0:N0} h powered on') -f [double]$d.Hours) }
        switch ([string]$d.Health) {
            'Warning'   { $lvl = [Math]::Max($lvl, 1); $st = L 'Advertencia' 'Warning'; $col = $C.Amber }
            'Unhealthy' { $lvl = 2; $st = L 'Con fallas' 'Failing'; $col = $C.Red }
        }
        $rows.Add((New-HealthRow $secDisk $d.Name ($parts -join ' · ') $st $col $lvl))
    }
    foreach ($v in @($out | Where-Object { $_.Type -eq 'Volume' })) {
        $pct = 0; if ([double]$v.SizeGB -gt 0) { $pct = [math]::Round(100 * [double]$v.FreeGB / [double]$v.SizeGB) }
        $name = (L 'Unidad {0}' 'Drive {0}') -f $v.Letter; if ($v.Label) { $name += " ($($v.Label))" }
        $txt = (L '{0} GB libres de {1} GB ({2}%)' '{0} GB free of {1} GB ({2}%)') -f $v.FreeGB, $v.SizeGB, $pct
        if ($pct -lt 10) { $rows.Add((New-HealthRow $secDisk $name $txt (L 'Casi llena' 'Almost full') $C.Red 2)) }
        elseif ($pct -lt 20) { $rows.Add((New-HealthRow $secDisk $name $txt (L 'Poco espacio' 'Low space') $C.Amber 1)) }
        else { $rows.Add((New-HealthRow $secDisk $name $txt $tGood $C.Green 0)) }
    }
    # --- Estabilidad (ultimos 30 dias) ---
    $events = @($out | Where-Object { $_.Type -eq 'Event' })
    $power = @($events | Where-Object { $_.Kind -eq 'Power' })
    if ($power.Count -eq 0) { $power = @($events | Where-Object { $_.Kind -eq 'PowerOld' }) }
    $defs = @(
        @{ Item = (L 'Apagados inesperados (corte de luz, cuelgue o reinicio forzado)' 'Unexpected shutdowns (power cut, freeze or forced restart)'); List = $power; Warn = 1; Bad = 3; BadText = (L 'Revisa la luz / el UPS' 'Check power / the UPS') }
        @{ Item = (L 'Pantallazos azules' 'Blue screens'); List = @($events | Where-Object { $_.Kind -eq 'BSOD' }); Warn = 1; Bad = 2; BadText = (L 'Hay que revisar' 'Needs checking') }
        @{ Item = (L 'Errores de hardware (WHEA)' 'Hardware errors (WHEA)'); List = @($events | Where-Object { $_.Kind -eq 'WHEA' }); Warn = 1; Bad = 5; BadText = (L 'Hay que revisar' 'Needs checking') }
        @{ Item = (L 'Errores de disco' 'Disk errors'); List = @($events | Where-Object { $_.Kind -eq 'Disk' }); Warn = 1; Bad = 5; BadText = (L 'Haz copia de seguridad' 'Back up your files') }
    )
    foreach ($df in $defs) {
        $n = $df.List.Count
        if ($n -eq 0) { $rows.Add((New-HealthRow $secStab $df.Item (L 'Ninguno en 30 días' 'None in 30 days') $tGood $C.Green 0)); continue }
        $lastE = ($df.List | Sort-Object Date -Descending | Select-Object -First 1).Date
        $txt = ((L '{0} en 30 días · último: ' '{0} in 30 days · last: ') -f $n) + ([datetime]$lastE).ToString((Get-DateFmt) + ' HH:mm')
        if ($n -ge $df.Bad) { $rows.Add((New-HealthRow $secStab $df.Item $txt $df.BadText $C.Red 2 'perfmon-rel' (L 'Ver detalle' 'Details'))) }
        else { $rows.Add((New-HealthRow $secStab $df.Item $txt (L 'Atención' 'Attention') $C.Amber 1 'perfmon-rel' (L 'Ver detalle' 'Details'))) }
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
      <Border Style="{StaticResource Pill}" Background="{Binding StatusBrush}">
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
              <DataGridTemplateColumn Width="42">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanSelect}" HorizontalAlignment="Center"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTextColumn Header="Actualización" Binding="{Binding Title}" Width="*"/>
              <DataGridTemplateColumn Header="Estado" Width="190" CellTemplate="{StaticResource StatusCell}"/>
              <DataGridTextColumn Header="Tipo" Binding="{Binding Kind}" Width="100"/>
              <DataGridTextColumn Header="Gravedad" Binding="{Binding Severity}" Width="95"/>
              <DataGridTextColumn Header="KB" Binding="{Binding KB}" Width="100"/>
              <DataGridTextColumn Header="Tamaño" Binding="{Binding Size}" Width="85"/>
              <DataGridTextColumn Header="Nota" Binding="{Binding Note}" Width="200"/>
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
              <TextBlock Text="Tema:" VerticalAlignment="Center" Margin="0,0,10,0" MinWidth="64"/>
              <ComboBox x:Name="CmbTheme" Width="200" Foreground="#111318">
                <ComboBoxItem Content="Igual que Windows" Tag="System"/>
                <ComboBoxItem Content="Oscuro" Tag="Dark"/>
                <ComboBoxItem Content="Claro" Tag="Light"/>
              </ComboBox>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
              <TextBlock Text="Idioma:" VerticalAlignment="Center" Margin="0,0,10,0" MinWidth="64"/>
              <ComboBox x:Name="CmbLang" Width="200" Foreground="#111318">
                <ComboBoxItem Content="Igual que Windows" Tag="Auto"/>
                <ComboBoxItem Content="Español" Tag="es"/>
                <ComboBoxItem Content="English" Tag="en"/>
              </ComboBox>
            </StackPanel>
            <TextBlock x:Name="LangNote" Text="El idioma nuevo se usa al volver a abrir Revix PC." Style="{StaticResource Muted}" Margin="74,0,0,10" Visibility="Collapsed"/>

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
                           Text="Privacidad: Revix PC no envía tus datos a nadie. Todo se revisa en tu PC. Solo se conecta a internet para consultar a Microsoft (winget, Windows Update y Defender) y a GitHub (para buscar versiones nuevas de Revix PC). Los enlaces a marcas solo abren su página oficial."/>
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
                  <Button x:Name="BtnInstallApp" Content="Descargar instalador" Style="{StaticResource Btn}"/>
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

# Textos de la ventana en inglés (la ventana está escrita en español)
$script:XamlEn = @{
    'Resumen' = 'Overview'
    'Programas' = 'Programs'
    'Dispositivos' = 'Devices'
    'Salud' = 'Health'
    'Limpieza' = 'Cleanup'
    'Inicio de Windows' = 'Windows startup'
    'Desinstalar' = 'Uninstall'
    'Mi PC' = 'My PC'
    'Progreso' = 'Progress'
    'Historial' = 'History'
    'Ajustes' = 'Settings'
    'Modo juego' = 'Game mode'
    'Exportar reporte' = 'Export report'
    'Escanear todo' = 'Scan all'
    'Sin permisos de administrador: puedes escanear, pero para instalar actualizaciones de Windows, crear puntos de restauración o respaldar drivers, cierra Revix PC (Salir) y ábrela aceptando el aviso de Windows.' = 'No administrator rights: you can scan, but to install Windows updates, create restore points or back up drivers, close Revix PC (Exit) and open it again accepting the Windows prompt.'
    'de 100' = 'of 100'
    'Revisando tu PC...' = 'Checking your PC...'
    'Esto tarda un momento.' = 'This takes a moment.'
    'Actualizar programas' = 'Update programs'
    'Salud y seguridad' = 'Health and security'
    'Por hacer' = 'To do'
    'Revisando...' = 'Checking...'
    'Temperaturas' = 'Temperatures'
    'Estabilidad · 30 días' = 'Stability · 30 days'
    'Mostrar ignorados y saltados' = 'Show ignored and skipped'
    'Marcar todo' = 'Select all'
    'Actualizar marcados' = 'Update selected'
    'Actualizar todos' = 'Update all'
    'Saltar esta versión' = 'Skip this version'
    'Ignorar siempre' = 'Always ignore'
    'Automático sí / no' = 'Automatic on / off'
    'Volver a una versión anterior' = 'Go back to a previous version'
    'Apps de la Store' = 'Store apps'
    'Programa' = 'Program'
    'Versión actual' = 'Current version'
    'Nueva versión' = 'New version'
    'Origen' = 'Source'
    'Instalar marcadas' = 'Install selected'
    'Abrir Windows Update' = 'Open Windows Update'
    'Actualización' = 'Update'
    'Estado' = 'Status'
    'Tipo' = 'Type'
    'Gravedad' = 'Severity'
    'Tamaño' = 'Size'
    'Nota' = 'Note'
    'Mostrar drivers genéricos de Windows' = 'Show generic Windows drivers'
    'Administrador de dispositivos' = 'Device Manager'
    'Respaldar drivers' = 'Back up drivers'
    'Restaurar respaldo' = 'Restore backup'
    'Dispositivo' = 'Device'
    'Fabricante' = 'Manufacturer'
    'Versión' = 'Version'
    'Fecha' = 'Date'
    'Volver a revisar' = 'Check again'
    'Actualizar firmas de Defender' = 'Update Defender signatures'
    'Abrir Seguridad de Windows' = 'Open Windows Security'
    'Área' = 'Area'
    'Elemento' = 'Item'
    'Detalle' = 'Details'
    'Calcular espacio' = 'Calculate space'
    'Limpiar marcados' = 'Clean selected'
    'Qué se limpia' = 'What gets cleaned'
    'Actualizar lista' = 'Refresh list'
    'Abrir Administrador de tareas' = 'Open Task Manager'
    'Desmarca lo que no necesitas al prender la PC. No se borra nada.' = 'Uncheck what you don''t need when the PC starts. Nothing is deleted.'
    'Activo' = 'Active'
    'Editor' = 'Publisher'
    'Impacto en el arranque' = 'Startup impact'
    'Dónde' = 'Where'
    'Comando' = 'Command'
    'Buscar:' = 'Search:'
    'Desinstalar seleccionado' = 'Uninstall selected'
    'Aplicaciones de Windows' = 'Windows apps'
    'Instalado' = 'Installed'
    'Copiar ficha' = 'Copy specs'
    'Actualizar' = 'Refresh'
    'Informe de batería' = 'Battery report'
    'Parte' = 'Part'
    'Temperaturas en vivo' = 'Live temperatures'
    'Valor' = 'Value'
    'Se actualiza cada 3 segundos mientras miras esta pestaña. La temperatura del procesador no se puede leer sin un driver especial (para eso usa HWiNFO).' = 'Updates every 3 seconds while you''re on this tab. The processor temperature can''t be read without a special driver (use HWiNFO for that).'
    'Sin tareas en curso' = 'No tasks running'
    'Cancelar (al terminar el actual)' = 'Cancel (after the current one)'
    'Limpiar lista' = 'Clear list'
    'Tarea' = 'Task'
    'Acción' = 'Action'
    'Resultado' = 'Result'
    'Funcionamiento' = 'Behavior'
    'Iniciar con Windows (queda junto al reloj y revisa sola)' = 'Start with Windows (stays next to the clock and checks on its own)'
    'Al cerrar la ventana, seguir funcionando junto al reloj' = 'When closing the window, keep running next to the clock'
    'Avisarme con una notificación cuando haya actualizaciones' = 'Notify me when updates are available'
    'Revisar automáticamente:' = 'Check automatically:'
    'Nunca' = 'Never'
    'Cada 6 horas' = 'Every 6 hours'
    'Cada 12 horas' = 'Every 12 hours'
    'Cada 24 horas' = 'Every 24 hours'
    'Apariencia' = 'Appearance'
    'Tema:' = 'Theme:'
    'Idioma:' = 'Language:'
    'Igual que Windows' = 'Same as Windows'
    'Oscuro' = 'Dark'
    'Claro' = 'Light'
    'El idioma nuevo se usa al volver a abrir Revix PC.' = 'The new language is used the next time Revix PC opens.'
    'Seguridad al instalar' = 'Safety when installing'
    'Crear un punto de restauración antes de instalar actualizaciones' = 'Create a restore point before installing updates'
    'Si la protección del sistema está apagada, Revix PC te preguntará antes de encenderla. Si algo sale mal, puedes volver atrás con ''Restaurar sistema''.' = 'If System Protection is off, Revix PC will ask you before turning it on. If something goes wrong, you can go back with ''System Restore''.'
    'Abrir Restaurar sistema' = 'Open System Restore'
    'Mientras juego o uso algo en pantalla completa: no avisar, no revisar y no instalar nada' = 'While I''m gaming or using something full screen: don''t notify, check or install anything'
    'Juegos extra a detectar aunque no estén en pantalla completa (nombre del proceso, separados por comas):' = 'Extra games to detect even when not full screen (process name, separated by commas):'
    'Programas automáticos' = 'Automatic programs'
    'Los programas marcados como ''Automático'' (pestaña Programas) se actualizan solos en cada revisión automática, sin preguntar y sin crear punto de restauración. Nunca durante el modo juego.' = 'Programs marked as ''Automatic'' (Programs tab) update on their own at each automatic check, without asking and without creating a restore point. Never during game mode.'
    'Avisarme si la tarjeta de video pasa de 85 °C (revisa cada 30 segundos)' = 'Warn me if the graphics card goes above 85 °C (checks every 30 seconds)'
    'Actualizaciones de Revix PC' = 'Revix PC updates'
    'Buscar nuevas versiones de Revix PC al abrir (en GitHub)' = 'Check for new versions of Revix PC when opening (on GitHub)'
    'Buscar nueva versión ahora' = 'Check for a new version now'
    'Acerca de' = 'About'
    'Hecho por Marco11  ·  Licencia MIT (gratis y de código abierto)' = 'Made by Marco11  ·  MIT License (free and open source)'
    'Privacidad: Revix PC no envía tus datos a nadie. Todo se revisa en tu PC. Solo se conecta a internet para consultar a Microsoft (winget, Windows Update y Defender) y a GitHub (para buscar versiones nuevas de Revix PC). Los enlaces a marcas solo abren su página oficial.' = 'Privacy: Revix PC doesn''t send your data to anyone. Everything is checked on your PC. It only connects to the internet to query Microsoft (winget, Windows Update and Defender) and GitHub (to look for new versions of Revix PC). Brand links only open their official page.'
    'Revix PC no está afiliado ni respaldado por Microsoft, NVIDIA, AMD, Intel, Logitech, Razer, HyperX ni otras marcas que aparezcan en la app. Sus nombres pertenecen a sus dueños y solo se usan para identificar tu hardware y software.' = 'Revix PC is not affiliated with or endorsed by Microsoft, NVIDIA, AMD, Intel, Logitech, Razer, HyperX or any other brand shown in the app. Their names belong to their owners and are only used to identify your hardware and software.'
    'Se ofrece ''tal cual'', sin garantía. Úsala bajo tu responsabilidad. Al actualizar programas, winget acepta en tu nombre las licencias de esos programas.' = 'Provided ''as is'', without warranty. Use it at your own risk. When updating programs, winget accepts those programs'' licenses on your behalf.'
    'Ver en GitHub' = 'View on GitHub'
    'Ver licencia' = 'View license'
    'Reportar un problema' = 'Report a problem'
    'Avanzado' = 'Advanced'
    'Descargar instalador' = 'Download installer'
    'Abrir carpeta de datos' = 'Open data folder'
    'Desinstalar Revix PC' = 'Uninstall Revix PC'
    'Listo' = 'Ready'
    'Cambiar a tema claro' = 'Switch to light theme'
    'Minimizar' = 'Minimize'
    'Maximizar' = 'Maximize'
    'Cerrar' = 'Close'
    'Bienvenido a Revix PC' = 'Welcome to Revix PC'
    'Revix PC revisa y actualiza tus programas, Windows Update y drivers, y te muestra la salud de tu PC. Antes de empezar, lee esto:' = 'Revix PC checks and updates your programs, Windows Update and drivers, and shows you your PC''s health. Before you start, please read this:'
    'Licencias. ' = 'Licenses. '
    'Para actualizar programas, Revix PC usa winget (de Microsoft), que acepta en tu nombre los acuerdos de licencia de cada programa y de sus fuentes. Si no estás de acuerdo con la licencia de un programa, no lo actualices desde aquí.' = 'To update programs, Revix PC uses winget (from Microsoft), which accepts the license agreements of each program and its sources on your behalf. If you don''t agree with a program''s license, don''t update it from here.'
    'Responsabilidad. ' = 'Responsibility. '
    'Revix PC es gratis y de código abierto (licencia MIT). Se ofrece tal cual, sin garantía. Úsala bajo tu responsabilidad y ten copia de tus archivos importantes.' = 'Revix PC is free and open source (MIT license). It is provided as is, without warranty. Use it at your own risk and keep a backup of your important files.'
    'Privacidad. ' = 'Privacy. '
    'No envía tus datos a nadie. Solo se conecta a Microsoft y a GitHub (para buscar versiones nuevas).' = 'It doesn''t send your data to anyone. It only connects to Microsoft and GitHub (to look for new versions).'
    'Instalación. ' = 'Installation. '
    'Se instalará en Archivos de programa, con accesos directos en el Escritorio y el menú Inicio. Para quitarla: Configuración &gt; Aplicaciones &gt; Revix PC.' = 'It will be installed in Program Files, with shortcuts on the Desktop and in the Start menu. To remove it: Settings &gt; Apps &gt; Revix PC.'
    'Entiendo y acepto' = 'I understand and accept'
    'Salir' = 'Exit'
    'Aceptar y empezar' = 'Accept and start'
    'Marca el programa que quieres regresar a la versión que tenías antes. La versión nueva quedará como ''saltada'' para que no se vuelva a instalar sola.' = 'Check the program you want to return to the version you had before. The new version will be marked as ''skipped'' so it doesn''t install again on its own.'
    'Volver a' = 'Go back to'
    'Actualizado el' = 'Updated on'
    'Volver a la versión anterior' = 'Go back to the previous version'
}
function Convert-XamlLang([string]$x) {
    if ($script:Lang -ne 'en') { return $x }
    return [regex]::Replace($x, '\b(Text|Content|Header|ToolTip|Title)="([^"{]*)"', {
        param($m)
        $v = $m.Groups[2].Value
        if ($script:XamlEn.ContainsKey($v)) { return $m.Groups[1].Value + '="' + $script:XamlEn[$v] + '"' }
        return $m.Value
    })
}
$script:XamlText = Convert-XamlLang $script:XamlText
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
             'ChkGameMode','TxtGames','ChkTempAlert','BtnCheckAppUpdate','ChkAppUpdates',
             'CmbTheme','BtnTheme','ThemeIcon','AboutLogo','AboutTitle','BtnGitHub','BtnLicense','BtnReport','BtnUninstallApp','ExpAdvanced',
             'TabHome','NavList','PageTitle','GameDot','GameChipText','VersionText','ScoreArc','ScoreText','ScoreTitle','ScoreSub',
             'BtnHomeUpdate','BtnHomeClean','CardProg','CardWU','CardDrv','CardHealth','SubPrograms','SubWU','SubDrivers','SubHealth',
             'TodoCount','TodoList','TodoEmpty','MiniTemps','MiniStab','CmbLang','LangNote',
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
    $script:WURebootItems = New-Object 'System.Collections.Generic.List[RevixPC.UpdateItem]'
    $script:RebootPending = $false
    $script:CleanItems   = New-Object 'System.Collections.Generic.List[RevixPC.CleanItem]'
    $script:Tasks        = New-Object 'System.Collections.ObjectModel.ObservableCollection[RevixPC.TaskItem]'
    $script:WUUpdates    = @()
    $script:RawDevices   = @()
    $script:DevExtra     = $null
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
                $by.Content = (L 'Sí' 'Yes'); $bn.Content = 'No'; $bn.IsCancel = $true
                $script:MsgResult = 'No'
            } else {
                $by.Content = (L 'Aceptar' 'OK'); $by.IsCancel = $true; $bn.Visibility = 'Collapsed'
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
      <TextBlock TextWrapping="Wrap" Margin="0,10,0,0" Foreground="{DynamicResource FgSoft}" LineHeight="20"><Run FontWeight="SemiBold" Foreground="{DynamicResource Fg}" Text="Privacidad. "/><Run Text="No envía tus datos a nadie. Solo se conecta a Microsoft y a GitHub (para buscar versiones nuevas)."/></TextBlock>
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
            $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Convert-XamlLang $dx))))
            Apply-Theme $dlg
            $script:WelcomeDialog = $dlg
            $script:WelcomeOk = $false
            if ($script:LogoImage) { $dlg.FindName('WLogo').Source = $script:LogoImage }
            $dlg.FindName('WVer').Text = (L 'Versión {0}  ·  Hecho por Marco11' 'Version {0}  ·  Made by Marco11') -f $script:AppVersion
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
            return ((Show-Msg (L "Revix PC usa winget, que acepta en tu nombre las licencias de los programas que actualizas. Es gratis (licencia MIT), se ofrece sin garantía y la usas bajo tu responsabilidad. No envía tus datos.`n`n¿Aceptas?" "Revix PC uses winget, which accepts the licenses of the programs you update on your behalf. It's free (MIT license), provided without warranty, and you use it at your own risk. It doesn't send your data.`n`nDo you accept?") 'Question' 'YesNo') -eq 'Yes')
        }
    }

    # ---------- Bandeja (junto al reloj) ----------
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    try { $script:TrayIcon.Icon = New-Object System.Drawing.Icon($script:IconPath) } catch { $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Application }
    $script:TrayIcon.Text = 'Revix PC'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add((L 'Abrir Revix PC' 'Open Revix PC'), $null, { Show-Main })
    [void]$menu.Items.Add((L 'Escanear ahora' 'Scan now'), $null, { Start-ScanAll })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add((L 'Salir' 'Exit'), $null, { Exit-App })
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
            $script:StatusText.Text = L 'Listo' 'Ready'
        }
        $script:BtnScanAll.IsEnabled = -not (Test-AnyRunning @('Programs', 'WU', 'Devices', 'Health'))
        $script:BtnCancel.IsEnabled = Test-AnyRunning @('ProgInstall', 'WUInstall', 'CleanRun', 'Rollback')
        if (Test-AnyRunning $script:WorkKinds) { $script:BadgeTask.Text = '•••'; $script:BadgeTaskBox.Visibility = 'Visible' }
        else { $script:BadgeTaskBox.Visibility = 'Collapsed' }

        if ($script:AutoRound -and -not (Test-AnyRunning @('Programs', 'WU', 'Devices'))) {
            $script:AutoRound = $false
            $p = @($script:ProgramItems | Where-Object { -not $_.Hidden }).Count
            $w = @($script:WUItems | Where-Object { -not $_.IsDriver }).Count
            $d = @($script:WUItems | Where-Object { $_.IsDriver }).Count
            $total = $p + $w + $d
            if ($total -gt 0 -and -not $script:Window.IsVisible) {
                Show-Notify (L 'Hay actualizaciones disponibles' 'Updates available') ((L 'Programas: {0}   ·   Windows: {1}   ·   Drivers: {2}' 'Programs: {0}   ·   Windows: {1}   ·   Drivers: {2}') -f $p, $w, $d)
            }
        }
        Update-TrayText
    }

    function Update-TrayText {
        $p = @($script:ProgramItems | Where-Object { -not $_.Hidden }).Count
        $w = @($script:WUItems).Count
        $t = 'Revix PC'
        if ($script:Scanned.Programs -or $script:Scanned.WU) { $t = (L 'Revix PC - {0} pendientes' 'Revix PC - {0} pending') -f ($p + $w) }
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
            catch { Write-ErrorLog "OnDone $($entry.Kind): $_"; Add-History (L 'Error interno' 'Internal error') $_.Exception.Message }
            Update-Busy
        }
    })
    $script:Timer.Start()

    # Reinicio normal de Windows (sin forzar: los programas abiertos pueden pedir guardar)
    function Request-Restart {
        try { Restart-Computer -ErrorAction Stop }
        catch { Show-Msg ((L "Windows no pudo reiniciar ahora:`n{0}`n`nReinicia desde el menú Inicio." "Windows couldn't restart now:`n{0}`n`nRestart from the Start menu.") -f $_.Exception.Message) 'Warning' | Out-Null }
    }

    # ---------- Tareas (pestaña Progreso) ----------
    function Add-TaskRow([string]$key, [string]$name) {
        $t = New-Object RevixPC.TaskItem
        $t.Key = $key; $t.Name = $name; $t.StatusText = (L 'En cola' 'Queued'); $t.StatusColor = $script:C.Gray; $t.Detail = ''; $t.Queued = $true; $t.Open = $true
        Set-StatusBrush $t
        $script:Tasks.Add($t)
    }
    function Set-TaskRow([string]$key, [string]$status, [string]$color, [string]$detail) {
        foreach ($t in $script:Tasks) {
            if ($t.Key -eq $key -and $t.Open) {
                $t.StatusText = $status; $t.StatusColor = $color; Set-StatusBrush $t
                $t.Queued = $false; $t.Open = $status.EndsWith('...')
                if ($null -ne $detail) { $t.Detail = $detail }
                break
            }
        }
        $script:GridTasks.Items.Refresh()
    }
    function Set-QueuedCancelled {
        foreach ($t in $script:Tasks) { if ($t.Queued) { $t.StatusText = (L 'Cancelado' 'Cancelled'); $t.StatusColor = $script:C.Gray; $t.Queued = $false; $t.Open = $false; Set-StatusBrush $t } }
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
            $script:NumDrivers.Text = [string]@($script:WUItems | Where-Object { $_.IsDriver }).Count
        }
        if ($script:Scanned.Health) { $script:NumHealth.Text = [string]@($script:HealthRows | Where-Object { $_.Level -ge 1 }).Count }
        Update-Home
    }

    function Refresh-Programs {
        $script:GridPrograms.ItemsSource = @($script:ProgramItems | Where-Object { $script:ChkShowIgnored.IsChecked -or -not $_.Hidden })
    }
    function Refresh-WU { $script:GridWU.ItemsSource = @(@($script:WUItems) + @($script:WURebootItems)) }
    function Refresh-Devices {
        $script:GridDevices.ItemsSource = @($script:DeviceItems | Where-Object { $script:ChkShowGeneric.IsChecked -or -not $_.IsGeneric })
    }
    function Refresh-Clean {
        $script:GridClean.ItemsSource = $null
        $script:GridClean.ItemsSource = @($script:CleanItems)
        $sum = 0.0
        foreach ($c in $script:CleanItems) { if ($c.Selected -and $c.Bytes -gt 0) { $sum += $c.Bytes } }
        if ($script:Scanned.Clean) { $script:CleanTotal.Text = (L 'Se pueden liberar: ' 'Can be freed: ') + (Format-Bytes $sum) } else { $script:CleanTotal.Text = '' }
    }
    function Rebuild-Devices {
        if (-not $script:Scanned.Devices) { return }
        $script:DeviceItems = ConvertTo-DeviceItems $script:RawDevices $script:WUUpdates $script:DevExtra
        Refresh-Devices
        Update-Home
    }

    # ---------- Escaneos ----------
    function Scan-Programs {
        [void](Start-Bg 'Programs' (L 'Buscando programas' 'Looking for programs') $script:JobWingetScan $null {
            param($out, $err)
            if ($err) {
                if ($err -match 'WINGET_NO_ENCONTRADO') { $msg = L 'No se encontró winget. Instala "Instalador de aplicación" (App Installer) desde Microsoft Store y vuelve a escanear.' 'winget was not found. Install "App Installer" from the Microsoft Store and scan again.' }
                else { $msg = $err }
                $script:NumPrograms.Text = '!'
                Add-History (L 'Escanear programas' 'Scan programs') "Error: $msg"
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
            Add-History (L 'Escanear programas' 'Scan programs') ((L '{0} con actualización' '{0} with an update') -f $n)
            $script:LastScan.Text = (L 'Último escaneo: ' 'Last scan: ') + (Get-Date).ToString((Get-DateFmt) + ' HH:mm')
            if ($script:AutoRound) { Start-AutoUpdates }
        })
    }

    function Scan-WU {
        [void](Start-Bg 'WU' (L 'Buscando en Windows Update' 'Checking Windows Update') $script:JobWUScan $null {
            param($out, $err)
            if ($err) {
                $script:NumWU.Text = '!'; $script:NumDrivers.Text = '!'
                if ($err -match '8024402C|80072EE7|80072EFD|80072EE2|8024401C') { $err = L 'Sin conexión a internet o Windows Update no responde. Se volverá a intentar en la próxima revisión.' 'No internet connection or Windows Update is not responding. It will try again at the next check.' }
                $script:SubWU.Text = L 'No se pudo revisar' 'Could not check'
                Add-History (L 'Escanear Windows Update' 'Scan Windows Update') "Error: $err"
                return
            }
            $st = $out | Where-Object { $_.IsStatus } | Select-Object -Last 1
            $all = @($out | Where-Object { -not $_.IsStatus })
            # Las que ya se instalaron y solo esperan reiniciar no cuentan como pendientes
            $script:WUUpdates = @($all | Where-Object { -not $_.PendingReboot })
            $script:WUItems.Clear(); $script:WURebootItems.Clear()
            foreach ($u in $all) {
                $it = New-Object RevixPC.UpdateItem
                $it.Title = [string]$u.Title; $it.UpdateId = [string]$u.UpdateId; $it.KB = [string]$u.KB
                $it.IsDriver = [bool]$u.IsDriver; $it.Kind = Get-UpdateKind $u
                $it.Severity = Get-SeverityText ([string]$u.Severity)
                if ([double]$u.SizeMB -gt 0) { $it.Size = ('{0:N1} MB' -f [double]$u.SizeMB) } else { $it.Size = '' }
                $it.PendingReboot = [bool]$u.PendingReboot
                if ($it.PendingReboot) {
                    $it.StatusText = L 'Instalada · falta reiniciar' 'Installed · restart needed'; $it.StatusColor = $script:C.Blue
                    $it.Note = L 'Se termina de aplicar al reiniciar' 'Finishes applying after a restart'
                } elseif ($u.FailDate) {
                    $it.StatusText = L 'Falló antes' 'Failed before'; $it.StatusColor = $script:C.Red
                    $it.Note = (L 'Falló el ' 'Failed on ') + ([datetime]$u.FailDate).ToString((Get-DateFmt))
                    if ([int]$u.FailCode -ne 0) { $it.Note += (' (0x{0:X8})' -f [int]$u.FailCode) }
                }
                Set-StatusBrush $it
                if ($it.PendingReboot) { $script:WURebootItems.Add($it) } else { $script:WUItems.Add($it) }
            }
            $script:RebootPending = ($script:WURebootItems.Count -gt 0) -or ($st -and $st.RebootRequired)
            $script:Scanned.WU = $true
            Refresh-WU; Update-Summary; Rebuild-Devices
            $nw = @($script:WUItems | Where-Object { -not $_.IsDriver }).Count
            $nd = @($script:WUItems | Where-Object { $_.IsDriver }).Count
            $msg = (L '{0} de Windows, {1} drivers' '{0} for Windows, {1} drivers') -f $nw, $nd
            if ($script:WURebootItems.Count -gt 0) { $msg += (L ', {0} esperan reinicio' ', {0} waiting for restart') -f $script:WURebootItems.Count }
            elseif ($script:RebootPending) { $msg += L ', reinicio pendiente' ', restart pending' }
            Add-History (L 'Escanear Windows Update' 'Scan Windows Update') $msg
        })
    }

    function Scan-Devices {
        [void](Start-Bg 'Devices' (L 'Revisando dispositivos' 'Checking devices') $script:JobDeviceScan $null {
            param($out, $err)
            if ($err) { Add-History (L 'Revisar dispositivos' 'Check devices') "Error: $err"; return }
            $script:RawDevices = @($out | Where-Object { $_.Type -eq 'Drv' })
            $script:DevExtra = @{
                Tools  = @($out | Where-Object { $_.Type -eq 'Tool' })
                Periph = @($out | Where-Object { $_.Type -eq 'Periph' })
                Cpu    = ($out | Where-Object { $_.Type -eq 'Cpu' } | Select-Object -First 1)
            }
            $script:Scanned.Devices = $true
            Rebuild-Devices
            Update-Summary
            Add-History (L 'Revisar dispositivos' 'Check devices') ((L '{0} dispositivos revisados' '{0} devices checked') -f $script:DeviceItems.Count)
        })
    }

    function Scan-Health {
        [void](Start-Bg 'Health' (L 'Revisando salud y seguridad' 'Checking health and security') $script:JobHealth $null {
            param($out, $err)
            if ($err) { $script:NumHealth.Text = '!'; Add-History (L 'Revisar salud' 'Check health') "Error: $err"; return }
            $script:HealthRows = ConvertTo-HealthRows @($out)
            $script:Scanned.Health = $true
            $script:GridHealth.ItemsSource = @($script:HealthRows)
            Update-Summary
            $n = @($script:HealthRows | Where-Object { $_.Level -ge 1 }).Count
            Add-History (L 'Revisar salud y seguridad' 'Check health and security') ((L '{0} aviso(s)' '{0} warning(s)') -f $n)
        })
    }

    function Scan-Clean {
        if (Test-AnyRunning @('CleanRun')) { return }
        foreach ($c in $script:CleanItems) { $c.SizeText = L 'Calculando...' 'Calculating...' }
        Refresh-Clean
        [void](Start-Bg 'Clean' (L 'Calculando espacio a liberar' 'Calculating space to free') $script:JobCleanScan $null {
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
        Add-TaskRow 'restore' (L 'Punto de restauración' 'Restore point')
        if (-not $script:IsAdmin) {
            Set-TaskRow 'restore' (L 'Omitido' 'Skipped') $script:C.Gray (L 'Hace falta abrir la app como administrador' 'The app must be opened as administrator')
            Continue-Pending; return
        }
        Start-RestorePoint $false
    }

    function Start-RestorePoint([bool]$allowEnable) {
        Set-TaskRow 'restore' (L 'Creando...' 'Creating...') $script:C.Amber (L 'Puede tardar un minuto' 'May take a minute')
        [void](Start-Bg 'Restore' (L 'Creando punto de restauración' 'Creating restore point') $script:JobRestorePoint @((L 'Revix PC - antes de actualizar' 'Revix PC - before updating'), $allowEnable) {
            param($out, $err)
            $r = $out | Select-Object -Last 1
            if (-not $err -and $r -and $r.NeedEnable) {
                $ans = Show-Msg ((L "La protección del sistema está apagada en la unidad {0}, así que no se pueden crear puntos de restauración.`n`n¿Quieres que Revix PC la encienda? Usa algo de espacio del disco (Windows lo administra solo) y te permite deshacer cambios con 'Restaurar sistema'." "System Protection is off on drive {0}, so restore points can't be created.`n`nDo you want Revix PC to turn it on? It uses some disk space (Windows manages it) and lets you undo changes with 'System Restore'.") -f $env:SystemDrive) 'Question' 'YesNo'
                if ($ans -eq 'Yes') { Start-RestorePoint $true; return }
                Set-TaskRow 'restore' (L 'Omitido' 'Skipped') $script:C.Gray (L 'La protección del sistema está apagada' 'System Protection is off')
                Add-History (L 'Punto de restauración' 'Restore point') (L 'Omitido: protección del sistema apagada' 'Skipped: System Protection is off')
                $ans2 = Show-Msg (L '¿Continuar sin punto de restauración?' 'Continue without a restore point?') 'Warning' 'YesNo'
                if ($ans2 -ne 'Yes') { Set-QueuedCancelled; $script:TaskHeader.Text = L 'Cancelado' 'Cancelled'; return }
                Continue-Pending; return
            }
            if ($err) {
                Set-TaskRow 'restore' (L 'No se pudo' 'Failed') $script:C.Red $err
                Add-History (L 'Punto de restauración' 'Restore point') "Error: $err"
                $ans = Show-Msg ((L "No se pudo crear el punto de restauración:`n{0}`n`n¿Continuar sin él?" "The restore point could not be created:`n{0}`n`nContinue without it?") -f $err) 'Warning' 'YesNo'
                if ($ans -ne 'Yes') { Set-QueuedCancelled; $script:TaskHeader.Text = L 'Cancelado' 'Cancelled'; return }
            } else {
                $d = ''; if ($r -and $r.Enabled) { $d = (L 'Se encendió la protección del sistema en {0}' 'System Protection was turned on for {0}') -f $env:SystemDrive }
                Set-TaskRow 'restore' (L 'Creado' 'Created') $script:C.Green $d
                Add-History (L 'Punto de restauración' 'Restore point') ((L 'Creado ' 'Created ') + $d).Trim()
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
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg (L 'Espera a que termine la tarea actual (mira la pestaña Progreso).' 'Wait for the current task to finish (see the Progress tab).') | Out-Null; return }
        $items = @($items | Where-Object { -not $_.Hidden })
        if ($items.Count -eq 0) { Show-Msg (L 'No hay programas marcados para actualizar.' 'No programs are selected for updating.') | Out-Null; return }
        $names = ($items | Select-Object -First 12 | ForEach-Object { '  • ' + $_.Name }) -join "`n"
        if ($items.Count -gt 12) { $names += (L "`n  ... y {0} más" "`n  ... and {0} more") -f ($items.Count - 12) }
        $ans = Show-Msg ((L "Se actualizarán {0} programa(s):`n`n{1}`n`nCierra esos programas antes de continuar. Al seguir, se aceptan las licencias de esos programas. ¿Seguir?" "{0} program(s) will be updated:`n`n{1}`n`nClose those programs before continuing. By continuing, you accept those programs' licenses. Continue?") -f $items.Count, $names) 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        Prepare-ProgInstall $items
        $script:SilentInstall = $false
        $script:Tasks.Clear(); Reset-Cancel
        Show-ProgressTab ((L 'Actualizando {0} programa(s)' 'Updating {0} program(s)') -f $items.Count)
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
        $script:TaskHeader.Text = (L 'Actualización automática de {0} programa(s)' 'Automatic update of {0} program(s)') -f $items.Count
        Start-ProgInstall
    }

    function Start-ProgInstall {
        foreach ($id in $script:PendingProgIds) { Add-TaskRow $id $script:NameById[$id] }
        [void](Start-Bg 'ProgInstall' (L 'Actualizando programas' 'Updating programs') $script:JobWingetUpgrade @(, $script:PendingProgIds) {
            param($out, $err)
            if ($err) {
                Add-History (L 'Actualizar programas' 'Update programs') "Error: $err"
                Set-QueuedCancelled
                Show-Msg $err 'Warning' | Out-Null; return
            }
            $done = @($out | Where-Object { $_.Kind -eq 'done' })
            $ok = @($done | Where-Object { [int]$_.ExitCode -eq 0 }).Count
            $bad = $done.Count - $ok
            $msg = (L 'Actualizados: {0}' 'Updated: {0}') -f $ok
            if ($bad -gt 0) { $msg += (L '   ·   Con problemas: {0}' '   ·   With problems: {0}') -f $bad }
            if ($out | Where-Object { $_.Kind -eq 'cancel' }) { $msg += L '   ·   Cancelado' '   ·   Cancelled' }
            $script:TaskHeader.Text = $msg
            if ($script:SilentInstall) {
                $names = @($done | Where-Object { [int]$_.ExitCode -eq 0 } | ForEach-Object { $script:NameById[[string]$_.Key] }) -join ', '
                if ($names) { Show-Notify (L 'Programas actualizados automáticamente' 'Programs updated automatically') $names }
                $script:SilentInstall = $false
            } elseif (-not $script:Window.IsVisible) { Show-Notify (L 'Actualización terminada' 'Update finished') $msg }
            Scan-Programs
        } {
            param($o)
            $name = $script:NameById[[string]$o.Key]; if (-not $name) { $name = $o.Key }
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key (L 'Instalando...' 'Installing...') $script:C.Amber (L 'Descargando e instalando' 'Downloading and installing') }
                'done'   {
                    if ([int]$o.ExitCode -eq 0) {
                        Set-TaskRow $o.Key (L 'Correcto' 'Done') $script:C.Green ''
                        $fv = $script:PendingFrom[[string]$o.Key]
                        if ($fv -and $fv.From -and $fv.From -notmatch '^(Unknown|Desconocid|<)' -and $fv.From -ne $fv.To) {
                            $script:PrevVersions[[string]$o.Key] = @{ Name = $name; From = [string]$fv.From; To = [string]$fv.To; Date = (Get-Date).ToString((Get-DateFmt) + ' HH:mm') }
                            Save-Config
                            Add-History ((L 'Actualizar {0}' 'Update {0}') -f $name) ((L 'Correcto ({0} -> {1})' 'Done ({0} -> {1})') -f $fv.From, $fv.To)
                        } else { Add-History ((L 'Actualizar {0}' 'Update {0}') -f $name) (L 'Correcto' 'Done') }
                    }
                    else {
                        $d = (Get-WingetCodeText ([int]$o.ExitCode)); if ($o.Message) { $d += ' - ' + $o.Message }
                        Set-TaskRow $o.Key 'Error' $script:C.Red $d; Add-History ((L 'Actualizar {0}' 'Update {0}') -f $name) "Error: $d"
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
        if ($sel.Count -eq 0) { Show-Msg (L 'Marca primero los programas que quieres ignorar siempre (o dejar de ignorar).' 'First select the programs you want to always ignore (or stop ignoring).') | Out-Null; return }
        foreach ($p in $sel) {
            if ($p.Ignored) { $p.Ignored = $false; [void]$script:IgnoredIds.Remove($p.Id); Add-History ((L 'Dejar de ignorar {0}' 'Stop ignoring {0}') -f $p.Name) '' }
            else { $p.Ignored = $true; if (-not $script:IgnoredIds.Contains($p.Id)) { $script:IgnoredIds.Add($p.Id) }; Add-History ((L 'Ignorar {0}' 'Ignore {0}') -f $p.Name) (L 'No se mostrará más' 'Will no longer be shown') }
            $p.Selected = $false
        }
        Save-Config; Refresh-Programs; Update-Summary; Update-TrayText
    })
    $script:BtnProgSkip.Add_Click({
        $sel = @($script:ProgramItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg (L 'Marca los programas cuya versión nueva quieres saltar. Volverán a aparecer cuando salga una versión más nueva.' 'Select the programs whose new version you want to skip. They will show up again when a newer version comes out.') | Out-Null; return }
        foreach ($p in $sel) {
            if ($p.Skipped) { $p.Skipped = $false; [void]$script:Skipped.Remove($p.Id); Add-History ((L 'Quitar salto de {0}' 'Unskip {0}') -f $p.Name) '' }
            else { $p.Skipped = $true; $script:Skipped[$p.Id] = $p.Available; Add-History ((L 'Saltar {0} {1}' 'Skip {0} {1}') -f $p.Name, $p.Available) (L 'Volverá a avisar con la siguiente versión' 'Will notify again with the next version') }
            $p.Selected = $false
        }
        Save-Config; Refresh-Programs; Update-Summary; Update-TrayText
    })
    $script:ChkShowIgnored.Add_Click({ Refresh-Programs })
    $script:BtnStore.Add_Click({
        [void](Start-Bg 'Store' (L 'Pidiendo a la Store que busque actualizaciones' 'Asking the Store to look for updates') $script:JobStore $null {
            param($out, $err)
            if ($err) { Add-History (L 'Actualizar apps de la Store' 'Update Store apps') (L 'Se abrió la Store para hacerlo manualmente' 'The Store was opened to do it manually') }
            else { Add-History (L 'Actualizar apps de la Store' 'Update Store apps') (L 'La Store está buscando e instalando actualizaciones' 'The Store is looking for and installing updates') }
        })
        Start-Process 'ms-windows-store://downloadsandupdates'
        Show-Msg (L "Se abrió la Microsoft Store en 'Descargas y actualizaciones'. Pulsa 'Obtener actualizaciones' para actualizar las apps de la Store." "The Microsoft Store opened in 'Downloads and updates'. Click 'Get updates' to update your Store apps.") | Out-Null
    })

    # ---------- Windows Update ----------
    $script:BtnWUSelectAll.Add_Click({
        $allOn = (@($script:WUItems | Where-Object { -not $_.Selected }).Count -eq 0)
        foreach ($u in $script:WUItems) { $u.Selected = -not $allOn }
        $script:GridWU.Items.Refresh()
    })
    $script:BtnWUSettings.Add_Click({ Start-Process 'ms-settings:windowsupdate' })
    $script:BtnWUInstall.Add_Click({
        if (-not $script:IsAdmin) { Show-Msg (L 'Para instalar actualizaciones de Windows abre Revix PC como administrador (acepta el aviso de Windows al abrirla).' 'To install Windows updates, open Revix PC as administrator (accept the Windows prompt when opening it).') 'Warning' | Out-Null; return }
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg (L 'Espera a que termine la tarea actual (mira la pestaña Progreso).' 'Wait for the current task to finish (see the Progress tab).') | Out-Null; return }
        $sel = @($script:WUItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg (L 'Marca primero las actualizaciones que quieres instalar.' 'First select the updates you want to install.') | Out-Null; return }
        $ans = Show-Msg ((L '{0} actualización(es) se descargarán e instalarán, una por una. Puede tardar y quizá pida reiniciar. ¿Seguir?' '{0} update(s) will be downloaded and installed, one by one. It may take a while and may ask for a restart. Continue?') -f $sel.Count) 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:PendingWU = @($sel | ForEach-Object { @{ Id = $_.UpdateId; Title = $_.Title } })
        $script:Tasks.Clear(); Reset-Cancel
        Show-ProgressTab ((L 'Instalando {0} actualización(es) de Windows' 'Installing {0} Windows update(s)') -f $sel.Count)
        Invoke-WithRestorePoint 'WU'
    })

    function Start-WUInstallJob {
        $ids = [string[]]@($script:PendingWU | ForEach-Object { $_.Id })
        foreach ($u in $script:PendingWU) { Add-TaskRow $u.Id $u.Title }
        $script:WUReboot = $false
        [void](Start-Bg 'WUInstall' (L 'Instalando actualizaciones de Windows' 'Installing Windows updates') $script:JobWUInstall @(, $ids) {
            param($out, $err)
            if ($err) { Add-History (L 'Instalar Windows Update' 'Install Windows Update') "Error: $err"; Set-QueuedCancelled; Show-Msg ((L "No se pudo instalar:`n{0}" "Could not install:`n{0}") -f $err) 'Warning' | Out-Null; return }
            $done = @($out | Where-Object { $_.Kind -eq 'done' })
            $ok = @($done | Where-Object { $_.Ok }).Count
            $msg = (L 'Instaladas: {0} de {1}' 'Installed: {0} of {1}') -f $ok, $done.Count
            if ($out | Where-Object { $_.Kind -eq 'cancel' }) { $msg += L '   ·   Cancelado' '   ·   Cancelled' }
            $script:TaskHeader.Text = $msg
            if ($script:WUReboot) {
                $ans = Show-Msg ($msg + (L ".`n`nWindows necesita reiniciar para terminar. Guarda tu trabajo. ¿Reiniciar ahora?" ".`n`nWindows needs to restart to finish. Save your work. Restart now?")) 'Question' 'YesNo'
                if ($ans -eq 'Yes') { Request-Restart }
            } elseif (-not $script:Window.IsVisible) { Show-Notify (L 'Windows Update terminado' 'Windows Update finished') $msg }
            Scan-WU; Scan-Health
        } {
            param($o)
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key (L 'Instalando...' 'Installing...') $script:C.Amber (L 'Descargando e instalando' 'Downloading and installing') }
                'done'   {
                    if ($o.Ok) { $col = $script:C.Green } else { $col = $script:C.Red }
                    $d = ''; if ($o.Reboot) { $d = L 'Necesita reiniciar' 'Needs a restart'; $script:WUReboot = $true }
                    Set-TaskRow $o.Key $o.Result $col $d
                    $t = $o.Title; if (-not $t) { $t = $o.Key }
                    Add-History ((L 'Instalar {0}' 'Install {0}') -f $t) $o.Result
                }
                'cancel' { Set-QueuedCancelled }
            }
        })
    }

    # ---------- Dispositivos y drivers ----------
    $script:ChkShowGeneric.Add_Click({ Refresh-Devices })
    $script:BtnDevMgr.Add_Click({ Start-Process 'devmgmt.msc' })

    # Solo se abren programas instalados en Program Files (herramientas oficiales de video)
    function Test-OfficialExe([string]$path) {
        if (-not $path -or $path -notmatch '\.exe$') { return $false }
        try { $full = [IO.Path]::GetFullPath($path) } catch { return $false }
        return ($full.StartsWith($env:ProgramFiles + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf))
    }
    $linkHandler = [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $btn = $e.OriginalSource
        if ($btn -is [System.Windows.Controls.Button] -and $btn.Tag) {
            if ([string]$btn.Tag -eq 'perfmon-rel') { Start-Process 'perfmon.exe' -ArgumentList '/rel' }
            elseif ([string]$btn.Tag -match '^https://') { Start-Process ([string]$btn.Tag) }
            elseif (Test-OfficialExe ([string]$btn.Tag)) {
                # Por medio del Explorador se abre como usuario normal (Revix PC corre como administrador)
                Start-Process 'explorer.exe' -ArgumentList ('"' + [string]$btn.Tag + '"')
            }
        }
    }
    $script:GridDevices.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $linkHandler)
    $script:GridHealth.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $linkHandler)

    $script:BtnDrvBackup.Add_Click({
        if (-not $script:IsAdmin) { Show-Msg (L 'Para respaldar drivers abre Revix PC como administrador.' 'To back up drivers, open Revix PC as administrator.') 'Warning' | Out-Null; return }
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg (L 'Espera a que termine la tarea actual.' 'Wait for the current task to finish.') | Out-Null; return }
        $dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('Revix PC\' + (L 'Respaldo-drivers-' 'Driver-backup-') + (Get-Date).ToString('yyyyMMdd-HHmm'))
        $ans = Show-Msg ((L "Se guardará una copia de tus drivers (los que no vienen con Windows) en:`n`n{0}`n`n¿Continuar?" "A copy of your drivers (the ones that don't come with Windows) will be saved to:`n`n{0}`n`nContinue?") -f $dest) 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:Tasks.Clear(); Add-TaskRow 'backup' (L 'Respaldo de drivers' 'Driver backup')
        Set-TaskRow 'backup' (L 'Copiando...' 'Copying...') $script:C.Amber $dest
        Show-ProgressTab (L 'Respaldando drivers' 'Backing up drivers')
        [void](Start-Bg 'DrvBackup' (L 'Respaldando drivers' 'Backing up drivers') $script:JobDriverBackup @($dest) {
            param($out, $err)
            if ($err) { Set-TaskRow 'backup' 'Error' $script:C.Red $err; Add-History (L 'Respaldar drivers' 'Back up drivers') "Error: $err"; return }
            $r = $out | Select-Object -First 1
            Set-TaskRow 'backup' (L 'Listo' 'Done') $script:C.Green ((L '{0} drivers en {1}' '{0} drivers in {1}') -f $r.Count, $r.Dest)
            $script:TaskHeader.Text = (L 'Respaldo listo: {0} drivers' 'Backup ready: {0} drivers') -f $r.Count
            Add-History (L 'Respaldar drivers' 'Back up drivers') ((L '{0} drivers en {1}' '{0} drivers in {1}') -f $r.Count, $r.Dest)
            Start-Process explorer.exe $r.Dest
        })
    })

    $script:BtnDrvRestore.Add_Click({
        if (-not $script:IsAdmin) { Show-Msg (L 'Para restaurar drivers abre Revix PC como administrador.' 'To restore drivers, open Revix PC as administrator.') 'Warning' | Out-Null; return }
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg (L 'Espera a que termine la tarea actual.' 'Wait for the current task to finish.') | Out-Null; return }
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = L 'Elige la carpeta del respaldo de drivers (Respaldo-drivers-...)' 'Choose the driver backup folder (Driver-backup-... or Respaldo-drivers-...)'
        $def = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Revix PC'
        if (Test-Path $def) { $dlg.SelectedPath = $def }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:PendingDrvFolder = $dlg.SelectedPath
        $infs = @(Get-ChildItem -LiteralPath $script:PendingDrvFolder -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) { Show-Msg (L 'Esa carpeta no tiene drivers (archivos .inf).' 'That folder has no drivers (.inf files).') 'Warning' | Out-Null; return }
        $ans = Show-Msg ((L "Se instalarán {0} driver(s) desde:`n{1}`n`nInstala solo respaldos tuyos o de fuentes de confianza. ¿Continuar?" "{0} driver(s) will be installed from:`n{1}`n`nOnly install your own backups or ones from trusted sources. Continue?") -f $infs.Count, $script:PendingDrvFolder) 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $script:Tasks.Clear(); Show-ProgressTab (L 'Restaurando drivers' 'Restoring drivers')
        Invoke-WithRestorePoint 'DrvRestore'
    })

    function Start-DriverRestore {
        Add-TaskRow 'drvrestore' (L 'Restaurar drivers' 'Restore drivers')
        Set-TaskRow 'drvrestore' (L 'Instalando...' 'Installing...') $script:C.Amber $script:PendingDrvFolder
        [void](Start-Bg 'DrvRestore' (L 'Restaurando drivers' 'Restoring drivers') $script:JobDriverRestore @($script:PendingDrvFolder) {
            param($out, $err)
            if ($err) { Set-TaskRow 'drvrestore' 'Error' $script:C.Red $err; Add-History (L 'Restaurar drivers' 'Restore drivers') "Error: $err"; return }
            $r = $out | Select-Object -First 1
            $code = [int]$r.ExitCode
            if ($code -eq 0 -or $code -eq 3010) {
                $d = ''; if ($code -eq 3010) { $d = L 'Reinicia la PC para terminar' 'Restart the PC to finish' }
                Set-TaskRow 'drvrestore' (L 'Listo' 'Done') $script:C.Green $d
                Add-History (L 'Restaurar drivers' 'Restore drivers') (((L 'Correcto ' 'Done ') + $d).Trim())
            } else {
                Set-TaskRow 'drvrestore' ((L 'Terminó con código {0}' 'Finished with code {0}') -f $code) $script:C.Amber (L 'Algunos drivers pueden no aplicar a este equipo' 'Some drivers may not apply to this PC')
                Add-History (L 'Restaurar drivers' 'Restore drivers') ((L 'Código {0}' 'Code {0}') -f $code)
            }
            $script:TaskHeader.Text = L 'Restauración terminada' 'Restore finished'
            Scan-Devices
        })
    }

    # ---------- Salud ----------
    $script:BtnHealthScan.Add_Click({ Scan-Health })
    $script:BtnSecurity.Add_Click({ Start-Process 'windowsdefender:' })
    $script:BtnDefender.Add_Click({
        [void](Start-Bg 'Defender' (L 'Actualizando firmas de Defender' 'Updating Defender signatures') $script:JobDefender $null {
            param($out, $err)
            if ($err) { Add-History (L 'Actualizar firmas de Defender' 'Update Defender signatures') "Error: $err"; Show-Msg ((L "No se pudo actualizar:`n{0}" "Could not update:`n{0}") -f $err) 'Warning' | Out-Null; return }
            Add-History (L 'Actualizar firmas de Defender' 'Update Defender signatures') (L 'Correcto' 'Done')
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
            if ($script:Scanned.Clean) { $script:CleanTotal.Text = (L 'Se pueden liberar: ' 'Can be freed: ') + (Format-Bytes $sum) }
        }
    })
    $script:BtnCleanRun.Add_Click({
        if (Test-AnyRunning ($script:WorkKinds + 'CleanRun')) { Show-Msg (L 'Espera a que termine la tarea actual.' 'Wait for the current task to finish.') | Out-Null; return }
        $sel = @($script:CleanItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg (L 'Marca qué quieres limpiar.' 'Select what you want to clean.') | Out-Null; return }
        $list = ($sel | ForEach-Object { '  • ' + $_.Name + '  (' + $_.SizeText + ')' }) -join "`n"
        $warn = ''
        if ($sel | Where-Object { $_.Key -eq 'RecycleBin' }) { $warn += L "`n`nOjo: la papelera se vacía definitivamente." "`n`nNote: the Recycle Bin is emptied permanently." }
        if ($sel | Where-Object { $_.Key -eq 'Components' }) { $warn += L "`nLos componentes viejos de Windows tardan varios minutos y después no podrás desinstalar actualizaciones ya instaladas." "`nOld Windows components take several minutes, and afterwards you won't be able to uninstall updates that are already installed." }
        $ans = Show-Msg ((L "Se limpiará:`n`n{0}{1}`n`n¿Continuar?" "This will be cleaned:`n`n{0}{1}`n`nContinue?") -f $list, $warn) 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        $keys = [string[]]@($sel | ForEach-Object { $_.Key })
        $script:Tasks.Clear(); Reset-Cancel
        foreach ($c in $sel) { Add-TaskRow $c.Key $c.Name }
        Show-ProgressTab (L 'Limpiando' 'Cleaning')
        $script:CleanFreed = 0.0
        [void](Start-Bg 'CleanRun' (L 'Limpiando' 'Cleaning') $script:JobClean @(, $keys) {
            param($out, $err)
            if ($err) { Add-History (L 'Limpieza' 'Cleanup') "Error: $err"; Set-QueuedCancelled; return }
            $msg = (L 'Espacio liberado: ' 'Space freed: ') + (Format-Bytes $script:CleanFreed)
            $script:TaskHeader.Text = $msg
            Add-History (L 'Limpieza' 'Cleanup') $msg
            Scan-Clean
        } {
            param($o)
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key (L 'Limpiando...' 'Cleaning...') $script:C.Amber '' }
                'done'   {
                    if ($o.Ok) { $script:CleanFreed += [double]$o.Freed; Set-TaskRow $o.Key (L 'Listo' 'Done') $script:C.Green ((L 'Liberado: ' 'Freed: ') + (Format-Bytes ([double]$o.Freed))) }
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
        $script:TaskHeader.Text = L 'Cancelando... (se detendrá al terminar el elemento actual)' 'Cancelling... (it will stop after the current item)'
        $script:BtnCancel.IsEnabled = $false
    })
    $script:BtnClearTasks.Add_Click({
        if (Test-AnyRunning ($script:WorkKinds + 'CleanRun')) { return }
        $script:Tasks.Clear(); $script:TaskHeader.Text = L 'Sin tareas en curso' 'No tasks running'
    })

    # ---------- Reporte HTML ----------
    $script:BtnExport.Add_Click({
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
        $pill = { param($text, $color) if (-not $text) { return '' }; "<span class='pill' style='background:$color'>$([System.Net.WebUtility]::HtmlEncode([string]$text))</span>" }
        $sb = New-Object System.Text.StringBuilder
        $rt = L 'Reporte Revix PC' 'Revix PC report'
        $nsc = "<p class='muted'>" + (L 'No escaneado.' 'Not scanned.') + '</p>'
        $nok = "<p class='muted'>" + (L 'Todo al día.' 'All up to date.') + '</p>'
        [void]$sb.Append("<!DOCTYPE html><html lang=`"$($script:Lang)`"><head><meta charset=`"utf-8`"><title>$rt</title><style>")
        [void]$sb.Append('body{font-family:Segoe UI,Arial,sans-serif;background:#111318;color:#e5e7eb;margin:32px}h1{margin:0}h2{margin-top:32px;border-bottom:1px solid #2a2f3a;padding-bottom:6px}')
        [void]$sb.Append('.muted{color:#9ca3af}table{border-collapse:collapse;width:100%;margin-top:10px}th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #2a2f3a;font-size:14px}th{color:#9ca3af;background:#1a1d24}')
        [void]$sb.Append('.pill{color:#fff;padding:2px 9px;border-radius:9px;font-size:12.5px;font-weight:600;white-space:nowrap}')
        [void]$sb.Append('</style></head><body>')
        [void]$sb.Append("<h1>$rt</h1><p class='muted'>$($env:COMPUTERNAME) · $((Get-Date).ToString((Get-DateFmt) + ' HH:mm')) · Revix PC $($script:AppVersion)</p>")

        [void]$sb.Append('<h2>' + (L 'Programas por actualizar' 'Programs to update') + '</h2>')
        $progs = @($script:ProgramItems | Where-Object { -not $_.Hidden })
        if (-not $script:Scanned.Programs) { [void]$sb.Append($nsc) }
        elseif ($progs.Count -eq 0) { [void]$sb.Append($nok) }
        else {
            [void]$sb.Append((L '<table><tr><th>Programa</th><th>Versión actual</th><th>Nueva versión</th></tr>' '<table><tr><th>Program</th><th>Current version</th><th>New version</th></tr>'))
            foreach ($p in $progs) { [void]$sb.Append("<tr><td>$(& $enc $p.Name)</td><td>$(& $enc $p.Version)</td><td>$(& $enc $p.Available)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('<h2>Windows Update</h2>')
        if (-not $script:Scanned.WU) { [void]$sb.Append($nsc) }
        elseif ($script:WUItems.Count -eq 0) { [void]$sb.Append($nok) }
        else {
            [void]$sb.Append((L '<table><tr><th>Actualización</th><th>Tipo</th><th>Gravedad</th><th>Tamaño</th></tr>' '<table><tr><th>Update</th><th>Type</th><th>Severity</th><th>Size</th></tr>'))
            foreach ($u in $script:WUItems) { [void]$sb.Append("<tr><td>$(& $enc $u.Title)</td><td>$(& $enc $u.Kind)</td><td>$(& $enc $u.Severity)</td><td>$(& $enc $u.Size)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('<h2>' + (L 'Salud y seguridad' 'Health and security') + '</h2>')
        if (-not $script:Scanned.Health) { [void]$sb.Append("<p class='muted'>" + (L 'No revisado.' 'Not checked.') + '</p>') }
        else {
            [void]$sb.Append((L '<table><tr><th>Área</th><th>Elemento</th><th>Detalle</th><th>Estado</th></tr>' '<table><tr><th>Area</th><th>Item</th><th>Details</th><th>Status</th></tr>'))
            foreach ($h in $script:HealthRows) { [void]$sb.Append("<tr><td>$(& $enc $h.Section)</td><td>$(& $enc $h.Item)</td><td>$(& $enc $h.Value)</td><td>$(& $pill $h.StatusText $h.StatusColor)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('<h2>' + (L 'Dispositivos' 'Devices') + '</h2>')
        if (-not $script:Scanned.Devices) { [void]$sb.Append($nsc) }
        else {
            [void]$sb.Append((L '<table><tr><th>Estado</th><th>Dispositivo</th><th>Versión</th><th>Fecha</th><th>Nota</th></tr>' '<table><tr><th>Status</th><th>Device</th><th>Version</th><th>Date</th><th>Note</th></tr>'))
            foreach ($d in @($script:DeviceItems | Where-Object { -not $_.IsGeneric })) { [void]$sb.Append("<tr><td>$(& $pill $d.StatusText $d.StatusColor)</td><td>$(& $enc $d.Name)</td><td>$(& $enc $d.Version)</td><td>$(& $enc $d.Date)</td><td>$(& $enc $d.Note)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        if ($script:Scanned.Clean) {
            [void]$sb.Append((L '<h2>Espacio que se puede liberar</h2><table><tr><th>Qué</th><th>Tamaño</th></tr>' '<h2>Space that can be freed</h2><table><tr><th>What</th><th>Size</th></tr>'))
            foreach ($c in $script:CleanItems) { [void]$sb.Append("<tr><td>$(& $enc $c.Name)</td><td>$(& $enc $c.SizeText)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        [void]$sb.Append('</body></html>')
        $desk = [Environment]::GetFolderPath('Desktop')
        $file = Join-Path $desk ((L 'Reporte-RevixPC-{0}.html' 'RevixPC-Report-{0}.html') -f (Get-Date).ToString('yyyyMMdd-HHmm'))
        [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Add-History (L 'Exportar reporte' 'Export report') $file
        Start-Process $file
    })

    # ---------- Instalación (la hace el instalador RevixPC-Setup-x.y.z.exe) ----------
    function Get-SetupInfo {
        try {
            $k = Get-ItemProperty -Path $script:SetupKey -ErrorAction Stop
            return [pscustomobject]@{ Dir = ([string]$k.InstallLocation).TrimEnd('\'); Uninstaller = ([string]$k.UninstallString).Trim('"'); Version = [string]$k.DisplayVersion }
        } catch { return $null }
    }
    function Get-InstalledExe {
        $s = Get-SetupInfo
        if ($s -and $s.Dir) { return (Join-Path $s.Dir 'RevixPC.exe') }
        return (Join-Path $script:InstallDir 'RevixPC.exe')
    }
    function Test-Installed { return [bool](Get-SetupInfo) }
    function Test-RunningInstalled {
        $s = Get-SetupInfo
        if (-not $s -or -not $s.Dir) { return $false }
        try { return ([IO.Path]::GetFullPath($script:AppDir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($s.Dir).TrimEnd('\')) } catch { return $false }
    }
    function Compare-AppVersion([string]$a, [string]$b) {
        try { return ([version]$a).CompareTo([version]$b) } catch { return 0 }
    }

    function Set-Startup([bool]$on) {
        $name = 'RevixPC'
        try {
            if (-not $on) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue; return $true }
            $exe = Get-InstalledExe
            if (-not (Test-Installed) -or -not (Test-Path -LiteralPath $exe)) { throw (L 'Para iniciar con Windows, instala Revix PC con el instalador (RevixPC-Setup).' 'To start with Windows, install Revix PC with the installer (RevixPC-Setup).') }
            $user = "$env:USERDOMAIN\$env:USERNAME"
            $act = New-ScheduledTaskAction -Execute $exe -Argument '-Tray'
            $trg = New-ScheduledTaskTrigger -AtLogOn -User $user
            $prn = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
            return $true
        } catch {
            Write-ErrorLog "startup: $_"
            Show-Msg ((L "No se pudo configurar el inicio con Windows:`n{0}" "Could not set up starting with Windows:`n{0}") -f $_.Exception.Message) 'Warning' | Out-Null
            return $false
        }
    }

    function Update-InstallInfo {
        $s = Get-SetupInfo
        if (Test-RunningInstalled) { $script:InstallInfo.Text = (L 'Instalada en {0}. Puedes anclar el acceso directo a la barra de tareas (clic derecho > Anclar).' 'Installed in {0}. You can pin the shortcut to the taskbar (right-click > Pin).') -f $s.Dir }
        elseif ($s) { $script:InstallInfo.Text = (L 'Estás usando una copia portátil. La versión instalada ({0}) está en {1}.' "You're using a portable copy. The installed version ({0}) is in {1}.") -f $s.Version, $s.Dir }
        else { $script:InstallInfo.Text = L 'Estás usando una copia portátil (sin instalar). Para iniciar con Windows, instala Revix PC con el instalador.' "You're using a portable copy (not installed). To start with Windows, install Revix PC with the installer." }
        $script:BtnInstallApp.Visibility = $(if ($s) { 'Collapsed' } else { 'Visible' })
        $script:BtnUninstallApp.IsEnabled = [bool]($s -and $s.Uninstaller -and (Test-Path -LiteralPath $s.Uninstaller))
    }

    $script:BtnInstallApp.Add_Click({ Start-Process "$($script:GitHubUrl)/releases/latest" })
    $script:BtnUninstallApp.Add_Click({
        $s = Get-SetupInfo
        if (-not $s -or -not (Test-Path -LiteralPath $s.Uninstaller)) { Start-Process 'ms-settings:appsfeatures'; return }
        $ans = Show-Msg (L '¿Desinstalar Revix PC? Se cerrará la app y se abrirá el desinstalador de Windows.' 'Uninstall Revix PC? The app will close and the Windows uninstaller will open.') 'Question' 'YesNo'
        if ($ans -ne 'Yes') { return }
        Start-Process -FilePath $s.Uninstaller
        Exit-App
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

    # ---------- Volver a una versión anterior ----------
    function Show-RollbackDialog {
        if ($script:PrevVersions.Count -eq 0) {
            Show-Msg (L "Todavía no hay programas actualizados con Revix PC.`n`nCada vez que actualices uno, aquí podrás volver a la versión que tenías antes." "No programs have been updated with Revix PC yet.`n`nEach time you update one, you'll be able to go back to the version you had before from here.") | Out-Null
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
        $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Convert-XamlLang $dx))))
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
            if ($sel.Count -eq 0) { [void](Show-Msg (L 'Marca al menos un programa.' 'Select at least one program.') 'Information' 'OK' $script:RbDialog); return }
            $list = ($sel | ForEach-Object { "  • $($_.Name): $($_.ToVersion) -> $($_.FromVersion)" }) -join "`n"
            $ans = Show-Msg ((L "Se reinstalará la versión anterior de:`n`n{0}`n`nOjo: las versiones viejas pueden tener fallas de seguridad ya corregidas. ¿Continuar?" "The previous version of these will be reinstalled:`n`n{0}`n`nNote: old versions may have security flaws that have since been fixed. Continue?") -f $list) 'Question' 'YesNo' $script:RbDialog
            if ($ans -ne 'Yes') { return }
            $script:RbDialog.Close()
            Start-Rollback $sel
        })
        [void]$dlg.ShowDialog()
    }

    function Start-Rollback($sel) {
        if (Test-AnyRunning $script:WorkKinds) { Show-Msg (L 'Espera a que termine la tarea actual.' 'Wait for the current task to finish.') | Out-Null; return }
        $script:Tasks.Clear(); Reset-Cancel
        Show-ProgressTab ((L 'Volviendo a la versión anterior de {0} programa(s)' 'Going back to the previous version of {0} program(s)') -f @($sel).Count)
        $script:RbMap = @{}
        foreach ($i in $sel) { $script:RbMap[$i.Id] = $i; Add-TaskRow $i.Id ((L '{0}: volver a {1}' '{0}: go back to {1}') -f $i.Name, $i.FromVersion) }
        $arr = [string[]]@($sel | ForEach-Object { "$($_.Id)|$($_.FromVersion)" })
        [void](Start-Bg 'Rollback' (L 'Volviendo a versiones anteriores' 'Going back to previous versions') $script:JobRollback @(, $arr) {
            param($out, $err)
            if ($err) { Add-History (L 'Volver a versión anterior' 'Go back to previous version') "Error: $err"; Set-QueuedCancelled; Show-Msg $err 'Warning' | Out-Null; return }
            $done = @($out | Where-Object { $_.Kind -eq 'done' })
            $ok = @($done | Where-Object { [int]$_.ExitCode -eq 0 }).Count
            $script:TaskHeader.Text = (L 'Regresados a la versión anterior: {0} de {1}' 'Returned to the previous version: {0} of {1}') -f $ok, $done.Count
            Scan-Programs
        } {
            param($o)
            $i = $script:RbMap[[string]$o.Key]
            switch ($o.Kind) {
                'start'  { Set-TaskRow $o.Key (L 'Instalando...' 'Installing...') $script:C.Amber ((L 'Reinstalando {0}' 'Reinstalling {0}') -f $i.FromVersion) }
                'done'   {
                    if ([int]$o.ExitCode -eq 0) {
                        Set-TaskRow $o.Key (L 'Correcto' 'Done') $script:C.Green ((L 'Ahora tienes la {0}. La {1} quedó saltada.' 'You now have {0}. Version {1} was skipped.') -f $i.FromVersion, $i.ToVersion)
                        $script:Skipped[$i.Id] = $i.ToVersion
                        [void]$script:PrevVersions.Remove($i.Id)
                        Save-Config
                        Add-History ((L 'Volver a versión anterior: {0}' 'Go back to previous version: {0}') -f $i.Name) "$($i.ToVersion) -> $($i.FromVersion)"
                    } else {
                        $d = (Get-WingetCodeText ([int]$o.ExitCode)); if ($o.Message) { $d += ' - ' + $o.Message }
                        Set-TaskRow $o.Key 'Error' $script:C.Red $d
                        Add-History ((L 'Volver a versión anterior: {0}' 'Go back to previous version: {0}') -f $i.Name) "Error: $d"
                    }
                }
                'cancel' { Set-QueuedCancelled }
            }
        })
    }

    $script:BtnRollback.Add_Click({ Show-RollbackDialog })
    $script:BtnProgAuto.Add_Click({
        $sel = @($script:ProgramItems | Where-Object { $_.Selected })
        if ($sel.Count -eq 0) { Show-Msg (L 'Marca los programas en los que confías (por ejemplo tu navegador). Se actualizarán solos en cada revisión automática.' 'Select the programs you trust (for example your browser). They will update on their own at each automatic check.') | Out-Null; return }
        foreach ($p in $sel) {
            if ($p.Auto) { $p.Auto = $false; [void]$script:AutoUpdateIds.Remove($p.Id); Add-History ((L 'Automático: {0}' 'Automatic: {0}') -f $p.Name) (L 'Desactivado' 'Turned off') }
            else { $p.Auto = $true; if (-not $script:AutoUpdateIds.Contains($p.Id)) { $script:AutoUpdateIds.Add($p.Id) }; Add-History ((L 'Automático: {0}' 'Automatic: {0}') -f $p.Name) (L 'Activado' 'Turned on') }
            $p.Selected = $false
        }
        Save-Config; Refresh-Programs
    })

    # ---------- Inicio de Windows ----------
    function Scan-Startup {
        [void](Start-Bg 'Startup' (L 'Revisando programas de inicio' 'Checking startup programs') $script:JobStartup $null {
            param($out, $err)
            if ($err) { Add-History (L 'Programas de inicio' 'Startup programs') "Error: $err"; return }
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
                    if ($m -and $m.Ms -gt 0) { $it.Impact = ((L 'Ralentizó {0:N1} s ({1})' 'Slowed it by {0:N1} s ({1})') -f ($m.Ms / 1000), ([datetime]$m.Date).ToString((Get-DateFmt))) }
                }
                $list.Add($it)
            }
            $script:StartupItems = $list
            $script:GridStartup.ItemsSource = @($list | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)
            if ($boot -and $boot.Ms -gt 0) {
                $script:BootInfo.Text = ((L 'Último arranque: {0:N1} s ({1})' 'Last startup: {0:N1} s ({1})') -f ($boot.Ms / 1000), ([datetime]$boot.Date).ToString((Get-DateFmt)))
            } else { $script:BootInfo.Text = (L '{0} de {1} activos' '{0} of {1} active') -f @($list | Where-Object { $_.Enabled }).Count, $list.Count }
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
            Show-Msg (L 'Este programa arranca para todos los usuarios. Para cambiarlo abre Revix PC como administrador.' 'This program starts for all users. To change it, open Revix PC as administrator.') 'Warning' | Out-Null
            return
        }
        try {
            Set-StartupEnabled $item $want
            $hn = (L 'Inicio de Windows: {0}' 'Windows startup: {0}') -f $item.Name
            if ($want) { Add-History $hn (L 'Activado' 'Turned on') } else { Add-History $hn (L 'Desactivado (no arrancará con Windows)' "Turned off (won't start with Windows)") }
        } catch {
            $item.Enabled = -not $want; $script:GridStartup.Items.Refresh()
            Show-Msg ((L "No se pudo cambiar:`n{0}" "Could not change it:`n{0}") -f $_.Exception.Message) 'Warning' | Out-Null
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
        $script:AppsInfo.Text = ((L '{0} programas · {1} en total (según lo que informa cada programa)' '{0} programs · {1} in total (as reported by each program)') -f @($script:AppItems).Count, (Format-Bytes ([double]$mb * 1MB)))
    }
    function Scan-Apps {
        [void](Start-Bg 'Apps' (L 'Leyendo programas instalados' 'Reading installed programs') $script:JobApps $null {
            param($out, $err)
            if ($err) { Add-History (L 'Programas instalados' 'Installed programs') "Error: $err"; return }
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
        if (-not $a) { Show-Msg (L 'Selecciona un programa de la lista (un clic sobre él).' 'Select a program from the list (click on it).') | Out-Null; return }
        $ans = Show-Msg ((L "Se abrirá el desinstalador de:`n`n{0}`n`nSigue los pasos que te muestre. ¿Continuar?" "The uninstaller for this will open:`n`n{0}`n`nFollow the steps it shows you. Continue?") -f $a.Name) 'Question' 'YesNo'
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
            Add-History ((L 'Desinstalar {0}' 'Uninstall {0}') -f $a.Name) (L 'Se abrió el desinstalador' 'The uninstaller was opened')
        } catch {
            Show-Msg ((L "No se pudo abrir el desinstalador:`n{0}`n`nPrueba desde 'Aplicaciones de Windows'." "Could not open the uninstaller:`n{0}`n`nTry from 'Windows apps'.") -f $_.Exception.Message) 'Warning' | Out-Null
        }
    })

    # ---------- Mi PC: ficha, batería y temperaturas ----------
    function Scan-PcInfo {
        [void](Start-Bg 'PcInfo' (L 'Leyendo la ficha de tu PC' 'Reading your PC specs') $script:JobPcInfo $null {
            param($out, $err)
            if ($err) { Add-History (L 'Ficha de la PC' 'PC specs') "Error: $err"; return }
            $list = New-Object 'System.Collections.Generic.List[RevixPC.InfoRow]'
            foreach ($r in $out) {
                $i = New-Object RevixPC.InfoRow
                $i.Section = [string]$r.Section; $i.Item = [string]$r.Item; $i.Value = [string]$r.Value; $i.Note = [string]$r.Note
                $list.Add($i)
            }
            $script:SpecRows = $list
            $script:GridSpecs.ItemsSource = @($list)
            if ($list | Where-Object { $_.Section -eq (L 'Batería' 'Battery') }) { $script:BtnBatteryReport.Visibility = 'Visible' }
            $script:Scanned.PcInfo = $true
        })
    }
    $script:BtnPcScan.Add_Click({ Scan-PcInfo })
    $script:BtnCopySpecs.Add_Click({
        if (-not $script:SpecRows) { return }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(((L 'Ficha de mi PC ({0}) - {1}' 'My PC specs ({0}) - {1}') -f $env:COMPUTERNAME, (Get-Date).ToString((Get-DateFmt))))
        $last = ''
        foreach ($r in $script:SpecRows) {
            if ($r.Section -ne $last) { [void]$sb.AppendLine(''); [void]$sb.AppendLine($r.Section.ToUpper()); $last = $r.Section }
            $line = "- $($r.Item): $($r.Value)"; if ($r.Note) { $line += "  ($($r.Note))" }
            [void]$sb.AppendLine($line)
        }
        [System.Windows.Clipboard]::SetText($sb.ToString())
        $script:StatusText.Text = L 'Ficha copiada. Pégala donde quieras con Ctrl+V.' 'Specs copied. Paste them anywhere with Ctrl+V.'
    })
    $script:BtnBatteryReport.Add_Click({
        $file = Join-Path ([Environment]::GetFolderPath('Desktop')) ((L 'Informe-bateria-{0}.html' 'Battery-report-{0}.html') -f (Get-Date).ToString('yyyyMMdd'))
        & powercfg.exe /batteryreport /output "$file" | Out-Null
        if (Test-Path $file) { Start-Process $file; Add-History (L 'Informe de batería' 'Battery report') $file }
        else { Show-Msg (L 'No se pudo crear el informe de batería.' 'The battery report could not be created.') 'Warning' | Out-Null }
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
        if ($t -ge $hot) { return @((L 'Muy caliente' 'Very hot'), $script:C.Red) }
        if ($t -ge $warm) { return @((L 'Caliente' 'Hot'), $script:C.Amber) }
        return @('Normal', $script:C.Green)
    }
    function Update-Temps([bool]$full) {
        $g = Get-GpuSensor
        if ($g -and $g.Temp -match '^\d+$') {
            $t = [int]$g.Temp
            if ($script:Config.TempAlert -and $t -ge 85 -and (-not $script:LastTempAlert -or ((Get-Date) - $script:LastTempAlert).TotalMinutes -ge 10)) {
                $script:LastTempAlert = Get-Date
                try { $script:TrayIcon.ShowBalloonTip(8000, (L 'Tarjeta de video muy caliente' 'Graphics card very hot'), ((L '{0}: {1} °C. Revisa la ventilación y el polvo.' '{0}: {1} °C. Check airflow and dust.') -f $g.Name, $t), [System.Windows.Forms.ToolTipIcon]::Warning) } catch {}
                Add-History (L 'Alerta de temperatura' 'Temperature alert') "$($g.Name): $t °C"
            }
        }
        if (-not $full) { return }
        $rows = New-Object 'System.Collections.Generic.List[RevixPC.HealthRow]'
        if ($g) {
            if ($g.Temp -match '^\d+$') { $lv = Get-TempLevel ([int]$g.Temp) 75 85; $rows.Add((New-HealthRow '' (L 'Video: temperatura' 'Graphics: temperature') "$($g.Temp) °C" $lv[0] $lv[1] 0)) }
            if ($g.Load -match '^\d+$') { $rows.Add((New-HealthRow '' (L 'Video: uso' 'Graphics: load') "$($g.Load) %" '' $script:C.Gray 0)) }
            if ($g.Fan -match '^\d+$') {
                $ft = "$($g.Fan) %"; if ([int]$g.Fan -eq 0) { $ft = L 'Detenido (normal en reposo)' 'Stopped (normal at idle)' }
                $rows.Add((New-HealthRow '' (L 'Video: ventilador' 'Graphics: fan') $ft '' $script:C.Gray 0))
            }
            $pw = 0.0
            if ([double]::TryParse([string]$g.Power, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$pw)) { $rows.Add((New-HealthRow '' (L 'Video: consumo' 'Graphics: power') ('{0:N0} W' -f $pw) '' $script:C.Gray 0)) }
            if ($g.MemUsed -match '^\d+$') { $rows.Add((New-HealthRow '' (L 'Video: memoria' 'Graphics: memory') "$($g.MemUsed) / $($g.MemTotal) MB" '' $script:C.Gray 0)) }
        } else {
            $rows.Add((New-HealthRow '' (L 'Tarjeta de video' 'Graphics card') (L 'No disponible' 'Not available') (L 'Solo NVIDIA' 'NVIDIA only') $script:C.Gray 0))
        }
        foreach ($d in @($script:DiskTemps)) {
            if (-not $d) { continue }
            $lv = Get-TempLevel ([int]$d.Temp) 60 70
            $rows.Add((New-HealthRow '' ((L 'Disco: {0}' 'Disk: {0}') -f $d.Name) "$($d.Temp) °C" $lv[0] $lv[1] 0))
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
        elseif ($t -eq 'reboot') {
            if (Test-AnyRunning $script:WorkKinds) { Show-Msg (L 'Espera a que termine la tarea actual (mira la pestaña Progreso).' 'Wait for the current task to finish (see the Progress tab).') | Out-Null; return }
            $ans = Show-Msg (L 'Se reiniciará la PC para terminar de instalar las actualizaciones. Guarda tu trabajo y cierra tus programas. ¿Reiniciar ahora?' 'The PC will restart to finish installing updates. Save your work and close your programs. Restart now?') 'Question' 'YesNo'
            if ($ans -eq 'Yes') { Add-History (L 'Reiniciar PC' 'Restart PC') (L 'Para terminar actualizaciones de Windows' 'To finish Windows updates'); Request-Restart }
        }
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
        $sec = @($wuWin | Where-Object { $_.Severity }).Count
        $wuDrv = @($script:WUItems | Where-Object { $_.IsDriver }).Count
        $hwAlerts = @($script:DeviceItems | Where-Object { $_.Alert })
        $warn = @($script:HealthRows | Where-Object { $_.Level -ge 1 })
        $lvl2 = @($warn | Where-Object { $_.Level -ge 2 }).Count
        $lvl1 = $warn.Count - $lvl2

        if ($script:Scanned.Programs) {
            if ($prog.Count -eq 0) { $script:SubPrograms.Text = L 'Todo al día' 'All up to date' }
            elseif ($autoN -gt 0) { $script:SubPrograms.Text = (L '{0} se actualizan solos' '{0} update on their own') -f $autoN }
            else { $script:SubPrograms.Text = L 'Esperan tu permiso' 'Waiting for your OK' }
            $script:BtnHomeUpdate.Content = (L 'Actualizar programas ({0})' 'Update programs ({0})') -f $prog.Count
            $script:BtnHomeUpdate.IsEnabled = ($prog.Count -gt 0)
        }
        if ($script:Scanned.WU) {
            if ($wuWin.Count -eq 0) { $script:SubWU.Text = L 'Todo al día' 'All up to date' }
            elseif ($sec -gt 0) { $script:SubWU.Text = (L '{0} de seguridad' '{0} security') -f $sec }
            else { $script:SubWU.Text = L 'Parches y mejoras' 'Patches and improvements' }
            if ($wuDrv) { $script:SubDrivers.Text = L 'En Windows Update' 'In Windows Update' }
            else { $script:SubDrivers.Text = L 'Todo al día' 'All up to date' }
        }
        if ($script:Scanned.Health) {
            if ($warn.Count -eq 0) { $script:SubHealth.Text = L 'Todo bien' 'All good' }
            elseif ($lvl2 -gt 0) { $script:SubHealth.Text = (L '{0} importante(s)' '{0} important') -f $lvl2 }
            else { $script:SubHealth.Text = L 'Para revisar' 'Worth a look' }
        }
        if ($script:Scanned.Clean) {
            $sum = 0.0
            foreach ($c in $script:CleanItems) { if ($c.Selected -and $c.Bytes -gt 0) { $sum += $c.Bytes } }
            if ($sum -gt 50MB) { $script:BtnHomeClean.Content = (L 'Liberar ' 'Free ') + (Format-Bytes $sum) } else { $script:BtnHomeClean.Content = L 'Limpieza' 'Cleanup' }
        }

        if ($script:Scanned.Programs) { Set-Badge $script:BadgeProgBox $script:BadgeProg $prog.Count }
        if ($script:Scanned.WU) { Set-Badge $script:BadgeWUBox $script:BadgeWU @($script:WUItems).Count }
        Set-Badge $script:BadgeDevBox $script:BadgeDev @($script:DeviceItems | Where-Object { $_.Priority -eq 0 }).Count
        if ($script:Scanned.Health) { Set-Badge $script:BadgeHealthBox $script:BadgeHealth $warn.Count }

        $todo = New-Object 'System.Collections.Generic.List[RevixPC.TodoItem]'
        $tView = L 'Ver' 'View'
        if ($script:RebootPending) {
            $nr = $script:WURebootItems.Count
            $d = L 'Windows terminará de aplicar cambios al reiniciar' 'Windows will finish applying changes after a restart'
            if ($nr -gt 0) { $d = (L '{0} actualización(es) instaladas esperan el reinicio' '{0} installed update(s) waiting for a restart') -f $nr }
            $todo.Add((New-Todo (L 'Reinicio pendiente' 'Restart pending') $d 'Windows' '#1D4ED8' 'R' (L 'Reiniciar' 'Restart') 'reboot'))
        }
        if ($wuWin.Count -gt 0) {
            $d = L 'Parches y mejoras de Windows' 'Windows patches and improvements'; if ($sec -gt 0) { $d = (L '{0} de seguridad · pueden pedir reiniciar' '{0} security · may ask for a restart') -f $sec }
            $todo.Add((New-Todo ((L 'Instala {0} actualización(es) de Windows' 'Install {0} Windows update(s)') -f $wuWin.Count) $d 'Windows' '#2F6FEB' 'W' $tView 'tab:2'))
        }
        foreach ($dv in @($hwAlerts | Select-Object -First 2)) {
            $tgt = 'tab:3'; $act = $tView
            if ([string]$dv.Link -match '^https://') { $tgt = $dv.Link; $act = $dv.ActionText }
            $todo.Add((New-Todo $dv.Alert $dv.Name 'Hardware' '#B91C1C' 'H' $act $tgt))
        }
        if ($wuDrv -gt 0) { $todo.Add((New-Todo ((L '{0} driver(s) en Windows Update' '{0} driver(s) in Windows Update') -f $wuDrv) (L 'Se instalan desde la sección Windows Update' 'Install them from the Windows Update section') 'Driver' '#0E7490' 'D' $tView 'tab:2')) }
        if ($prog.Count -gt 0) {
            $manual = $prog.Count - $autoN
            $d = L 'Esperan tu permiso' 'Waiting for your OK'
            if ($autoN -gt 0 -and $manual -gt 0) { $d = (L '{0} se actualizan solos · {1} esperan tu permiso' '{0} update on their own · {1} waiting for your OK') -f $autoN, $manual }
            elseif ($autoN -gt 0) { $d = L 'Se actualizan solos en la próxima revisión' 'They update on their own at the next check' }
            $todo.Add((New-Todo ((L 'Actualiza {0} programa(s)' 'Update {0} program(s)') -f $prog.Count) $d (L 'Programas' 'Programs') '#C2410C' 'P' $tView 'tab:1'))
        }
        foreach ($h in @($warn | Sort-Object Level -Descending | Select-Object -First 3)) {
            $tile = '#8A5A00'; if ($h.Level -ge 2) { $tile = '#B42318' }
            $tgt = 'tab:4'; if ($h.Link) { $tgt = $h.Link }
            $todo.Add((New-Todo $h.Item ("$($h.Value) · $($h.StatusText)") (L 'Salud' 'Health') $tile '!' $tView $tgt))
        }
        $script:TodoList.ItemsSource = @($todo)
        $n = $todo.Count
        $allScanned = ($script:Scanned.Programs -and $script:Scanned.WU -and $script:Scanned.Health)
        if ($n -eq 0) {
            if ($allScanned) { $script:TodoEmpty.Text = L 'Todo al día. No tienes nada pendiente.' 'All up to date. Nothing pending.' } else { $script:TodoEmpty.Text = L 'Revisando...' 'Checking...' }
            $script:TodoEmpty.Visibility = 'Visible'
        } else { $script:TodoEmpty.Visibility = 'Collapsed' }
        if ($n -gt 0) { $script:TodoCount.Text = (L '{0} por hacer' '{0} to do') -f $n } else { $script:TodoCount.Text = '' }

        if ($allScanned) {
            $score = Get-HealthScore $sec ($wuWin.Count - $sec) $prog.Count ($nv + $wuDrv) $lvl2 $lvl1
            $lab = Get-ScoreLabel $score
            $script:ScoreText.Text = [string]$score
            $script:ScoreTitle.Text = $lab[0]
            Set-ScoreArc $score $lab[1]
            if ($n -eq 0) { $sub = L 'Todo al día. No tienes nada pendiente.' 'All up to date. Nothing pending.' }
            elseif ($n -eq 1) { $sub = L 'Tienes 1 cosa por hacer.' 'You have 1 thing to do.' }
            else { $sub = (L 'Tienes {0} cosas por hacer.' 'You have {0} things to do.') -f $n }
            if ($n -gt 0 -and (Test-GameMode)) { $sub += L ' Puedes hacerlas cuando termines de jugar.' ' You can do them when you finish playing.' }
            elseif ($n -gt 0 -and $lvl2 -eq 0 -and $sec -eq 0) { $sub += L ' Nada urgente.' ' Nothing urgent.' }
            $script:ScoreSub.Text = $sub
        }

        $stab = New-Object 'System.Collections.Generic.List[RevixPC.MiniRow]'
        # Nombres cortos en el mismo orden en que se crean las filas de Estabilidad
        $short = @((L 'Apagados inesperados' 'Unexpected shutdowns'), (L 'Pantallazos azules' 'Blue screens'), (L 'Errores de hardware' 'Hardware errors'), (L 'Errores de disco' 'Disk errors'))
        $si = 0
        foreach ($h in @($script:HealthRows | Where-Object { $_.Section -eq (L 'Estabilidad' 'Stability') })) {
            $m = New-Object RevixPC.MiniRow
            $m.Name = $h.Item
            if ($si -lt $short.Count) { $m.Name = $short[$si] }
            $si++
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
            $m.Name = L 'Leyendo sensores...' 'Reading sensors...'; $m.Value = ''; $m.Pct = 0; $m.Color = '#6B7383'
            $rows.Add($m)
            if (-not $script:Running['DiskTemp']) { Scan-DiskTemps }
        }
        $script:MiniTemps.ItemsSource = @($rows)
    }

    function Update-GameChip {
        if (-not $script:Config.GameMode) { $script:GameChipText.Text = L 'Modo juego: apagado' 'Game mode: off'; $script:GameDot.Fill = Get-Brush '#6B7383' }
        elseif (Test-GameMode) { $script:GameChipText.Text = L 'Modo juego: activo' 'Game mode: active'; $script:GameDot.Fill = Get-Brush '#F59E0B' }
        else { $script:GameChipText.Text = L 'Modo juego: listo' 'Game mode: ready'; $script:GameDot.Fill = Get-Brush '#22C55E' }
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
            $script:ThemeIcon.Text = [string][char]0xE708; $script:BtnTheme.ToolTip = L 'Cambiar a tema oscuro' 'Switch to dark theme'
        } else {
            $script:ThemeIcon.Text = [string][char]0xE706; $script:BtnTheme.ToolTip = L 'Cambiar a tema claro' 'Switch to light theme'
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
    function ConvertTo-PlainNotes([string]$md) {
        if (-not $md) { return '' }
        $t = $md -replace "`r", ''
        $t = $t -replace '(?m)^#{1,6}\s*', '' -replace '\*\*', '' -replace '(?m)^\s*[-*]\s+', '• ' -replace '`', ''
        $t = $t.Trim()
        if ($t.Length -gt 1200) { $t = $t.Substring(0, 1200) + '...' }
        return $t
    }
    function Check-AppUpdate([bool]$quiet) {
        $script:AppUpdQuiet = $quiet
        [void](Start-Bg 'AppUpd' (L 'Buscando nueva versión de Revix PC' 'Checking for a new version of Revix PC') $script:JobCheckAppUpdate @($script:GitHubRepo) {
            param($out, $err)
            if ($err) { if (-not $script:AppUpdQuiet) { Show-Msg $err 'Warning' | Out-Null }; return }
            $r = $out | Select-Object -First 1
            if (-not $r -or -not $r.Version) { return }
            if ((Compare-AppVersion $r.Version $script:AppVersion) -le 0) { if (-not $script:AppUpdQuiet) { Show-Msg ((L 'Ya tienes la última versión ({0}).' 'You already have the latest version ({0}).') -f $script:AppVersion) | Out-Null }; return }
            if ($script:AppUpdQuiet -and (-not $script:Window.IsVisible -or (Test-GameMode))) {
                $script:PendingAppUpdate = $r
                Show-Notify (L 'Nueva versión de Revix PC' 'New version of Revix PC') ((L 'Versión {0} disponible. Abre la app para ver las novedades.' 'Version {0} is available. Open the app to see what''s new.') -f $r.Version)
                return
            }
            Offer-AppUpdate $r
        })
    }
    function Offer-AppUpdate($r) {
        $script:PendingAppUpdate = $null
        $notes = ConvertTo-PlainNotes $r.Notes
        $txt = (L 'Hay una versión nueva de Revix PC: {0} (tienes la {1}).' 'A new version of Revix PC is available: {0} (you have {1}).') -f $r.Version, $script:AppVersion
        if ($notes) { $txt += (L "`n`nNovedades:`n" "`n`nWhat's new:`n") + $notes }
        $txt += L "`n`nDescarga el instalador desde la página oficial de Revix PC en GitHub y ábrelo: se actualiza sin perder tus ajustes. ¿Abrir la página?" "`n`nDownload the installer from the official Revix PC page on GitHub and run it: it updates without losing your settings. Open the page?"
        if ((Show-Msg $txt 'Question' 'YesNo') -eq 'Yes') {
            $page = [string]$r.Page
            if ($page -notmatch '^https://github\.com/Marco11Mz/RevixPC/') { $page = "$($script:GitHubUrl)/releases/latest" }
            Start-Process $page
        }
    }
    $script:BtnCheckAppUpdate.Add_Click({ Check-AppUpdate $false })

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
            Show-Msg (L 'Para cambiar esto abre Revix PC como administrador.' 'To change this, open Revix PC as administrator.') 'Warning' | Out-Null; return
        }
        if ($want -and -not (Test-Installed)) {
            $script:ChkStartup.IsChecked = $false
            $ans = Show-Msg (L 'Para iniciar con Windows, instala Revix PC con el instalador (RevixPC-Setup). ¿Abrir la página de descarga?' 'To start with Windows, install Revix PC with the installer (RevixPC-Setup). Open the download page?') 'Question' 'YesNo'
            if ($ans -eq 'Yes') { Start-Process "$($script:GitHubUrl)/releases/latest" }
            return
        }
        if (Set-Startup $want) {
            $script:Config.StartWithWindows = $want; Save-Config
            if ($want) { Add-History (L 'Iniciar con Windows' 'Start with Windows') (L 'Activado' 'Turned on') } else { Add-History (L 'Iniciar con Windows' 'Start with Windows') (L 'Desactivado' 'Turned off') }
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

    # ---------- Idioma ----------
    # Volver a abrir Revix PC (para aplicar el idioma). Necesita RevixPC.exe; Windows vuelve a pedir permiso de administrador.
    function Restart-App {
        $exe = Join-Path $script:AppDir 'RevixPC.exe'
        if (-not (Test-Path -LiteralPath $exe)) { return $false }
        try { $script:Mutex.ReleaseMutex() } catch {}
        try {
            Start-Process -FilePath $exe -ErrorAction Stop
        } catch {
            # Si no se acepta el aviso de Windows, Revix PC sigue abierta como estaba
            try { $c = $false; $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\RevixPC_Instance', [ref]$c) } catch {}
            return $false
        }
        Exit-App
        return $true
    }
    $script:CmbLang.Add_SelectionChanged({
        if ($script:SyncingLang) { return }
        $sel = $script:CmbLang.SelectedItem
        if (-not $sel) { return }
        $script:Config.Language = [string]$sel.Tag; Save-Config
        $new = [string]$sel.Tag
        if ($new -ne 'es' -and $new -ne 'en') { $new = Get-SystemLang }
        if ($new -eq $script:Lang) { $script:LangNote.Visibility = 'Collapsed'; return }
        $script:LangNote.Visibility = 'Visible'
        Add-History (L 'Idioma' 'Language') ([string]$sel.Content)
        if (Test-AnyRunning $script:WorkKinds) { return }
        # La pregunta va en el idioma nuevo
        if ($new -eq 'en') { $q = 'Restart Revix PC now to switch to English?' } else { $q = '¿Volver a abrir Revix PC ahora para cambiar a español?' }
        $ans = Show-Msg $q 'Question' 'YesNo'
        if ($ans -eq 'Yes' -and -not (Restart-App)) { Show-Msg (L 'Cierra Revix PC (Salir) y ábrela de nuevo para ver el idioma nuevo.' 'Close Revix PC (Exit) and open it again to see the new language.') | Out-Null }
    })

    # ---------- Inicio ----------
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
    $script:SyncingLang = $true
    foreach ($it in $script:CmbLang.Items) { if ([string]$it.Tag -eq [string]$script:Config.Language) { $script:CmbLang.SelectedItem = $it } }
    if (-not $script:CmbLang.SelectedItem) { $script:CmbLang.SelectedIndex = 0 }
    $script:SyncingLang = $false
    Set-Theme
    $script:Scanned.Startup = $false; $script:Scanned.Apps = $false; $script:Scanned.PcInfo = $false
    $script:AppItems = @(); $script:DiskTemps = @()
    $script:TempTimer.Start()
    foreach ($it in $script:CmbAutoCheck.Items) { if ([int]$it.Tag -eq [int]$script:Config.AutoCheckHours) { $script:CmbAutoCheck.SelectedItem = $it } }
    if (-not $script:CmbAutoCheck.SelectedItem) { $script:CmbAutoCheck.SelectedIndex = 2 }
    Set-AutoTimer
    Update-InstallInfo
    $script:AboutTitle.Text = "Revix PC $($script:AppVersion)"
    $script:AboutText.Text = (L 'Datos (ajustes e historial): {0}' 'Data (settings and history): {0}') -f $script:DataDir
    $script:GridHistory.ItemsSource = $script:History
    Refresh-Clean
    if (-not $script:IsAdmin) { $script:AdminWarning.Visibility = 'Visible' }
    $window.Title = "Revix PC $($script:AppVersion)"
    $script:VersionText.Text = (L 'Versión {0}' 'Version {0}') -f $script:AppVersion
    $script:NavList.SelectedIndex = 0
    $script:Tabs.SelectedIndex = 0
    Update-GameChip
    Update-Home
    if ($script:Migrated) { Add-History 'Revix PC' (L 'Se trajeron los ajustes e historial de ActualizaPC' 'Settings and history were brought over from ActualizaPC') }
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
            $script:BtnWinMax.ToolTip = L 'Restaurar' 'Restore'
        } else {
            $script:MaxIcon.Data = [System.Windows.Media.Geometry]::Parse('M0.5,0.5 H9.5 V9.5 H0.5 Z')
            $script:BtnWinMax.ToolTip = L 'Maximizar' 'Maximize'
        }
    })

    $window.Add_ContentRendered({
        if ($script:FirstRenderDone) { return }
        $script:FirstRenderDone = $true
        # 1) Bienvenida (una sola vez): licencias, responsabilidad y privacidad
        if (-not $script:Config.WelcomeAccepted) {
            if (-not (Show-Welcome $false)) { Exit-App; return }
            $script:Config.WelcomeAccepted = $true; $script:Config.LastVersion = $script:AppVersion; Save-Config
            Add-History (L 'Bienvenida' 'Welcome') (L 'Aviso de licencias y responsabilidad aceptado' 'License and responsibility notice accepted')
        }
        # 2) Novedades después de actualizar
        elseif ([string]$script:Config.LastVersion -ne $script:AppVersion) {
            $notes = [string]$script:Config.UpdateNotes
            $txt = (L 'Revix PC se actualizó a la versión {0}.' 'Revix PC was updated to version {0}.') -f $script:AppVersion
            if ($notes) { $txt += (L "`n`nNovedades:`n" "`n`nWhat's new:`n") + $notes }
            $script:Config.LastVersion = $script:AppVersion; $script:Config.UpdateNotes = ''; Save-Config
            Show-Msg $txt | Out-Null
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
                try { $script:TrayIcon.ShowBalloonTip(5000, (L 'Revix PC sigue funcionando' 'Revix PC is still running'), (L 'Está junto al reloj. Clic derecho en el ícono > Salir para cerrarla del todo.' "It's next to the clock. Right-click the icon > Exit to close it completely."), [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
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
    $em = "Revix PC tuvo un error al abrir:`n`n{0}`n`nDetalle guardado en:`n{1}"
    try { if ($script:Lang -eq 'en') { $em = "Revix PC had an error while opening:`n`n{0}`n`nDetails saved to:`n{1}" } } catch {}
    [System.Windows.MessageBox]::Show(($em -f $_.Exception.Message, $script:ErrorLog), 'Revix PC', 'OK', 'Error') | Out-Null
}
