// Revix PC - lanzador (RevixPC.exe)
// Abre RevixPC.ps1 dentro de este mismo proceso con el PowerShell 5.1 que trae Windows.
// No abre ventanas de consola ni otros procesos de PowerShell.
// Se compila en GitHub Actions (ver .github/workflows/release.yml).
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using System.Text;

[assembly: System.Reflection.AssemblyTitle("Revix PC")]
[assembly: System.Reflection.AssemblyProduct("Revix PC")]
[assembly: System.Reflection.AssemblyCompany("Marco11")]
[assembly: System.Reflection.AssemblyCopyright("Marco11 - Licencia MIT")]
[assembly: System.Reflection.AssemblyDescription("Revix PC - actualizaciones, drivers y salud de la PC")]
[assembly: System.Reflection.AssemblyVersion("0.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("0.0.0.0")]

static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    static void ShowError(string text)
    {
        try
        {
            string log = Path.Combine(Path.GetTempPath(), "RevixPC-error.log");
            File.AppendAllText(log, "[" + DateTime.Now.ToString("s") + "] lanzador: " + text + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
        MessageBoxW(IntPtr.Zero, text, "Revix PC", 0x10);
    }

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "RevixPC.ps1");
        if (!File.Exists(script))
        {
            ShowError("No se encontró RevixPC.ps1 junto a RevixPC.exe.\n\nVuelve a instalar Revix PC con el instalador.");
            return 1;
        }
        bool tray = false;
        foreach (string a in args)
        {
            if (string.Equals(a, "-Tray", StringComparison.OrdinalIgnoreCase) || string.Equals(a, "/Tray", StringComparison.OrdinalIgnoreCase)) tray = true;
        }
        try
        {
            Directory.SetCurrentDirectory(dir);
            InitialSessionState iss = InitialSessionState.CreateDefault();
            // Solo para este proceso: permite cargar RevixPC.ps1 (no cambia la configuración de Windows)
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = System.Threading.ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script).AddParameter("NoElevate");
                    if (tray) ps.AddParameter("Tray");
                    ps.Invoke();
                    if (ps.HadErrors && ps.Streams.Error.Count > 0)
                    {
                        // Errores que no cerraron la app: solo se anotan en el registro
                        try
                        {
                            string log = Path.Combine(Path.GetTempPath(), "RevixPC-error.log");
                            StringBuilder sb = new StringBuilder();
                            foreach (ErrorRecord e in ps.Streams.Error) sb.AppendLine("[" + DateTime.Now.ToString("s") + "] " + e.ToString());
                            File.AppendAllText(log, sb.ToString(), Encoding.UTF8);
                        }
                        catch { }
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            ShowError("Revix PC no pudo abrir:\n\n" + ex.Message);
            return 1;
        }
    }
}
