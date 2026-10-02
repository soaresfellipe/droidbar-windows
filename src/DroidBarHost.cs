// Droid Bar host executable: runs droid-bar.ps1 in-process so Windows shows
// "Droid Bar" (not "Windows PowerShell") in the tray settings and notifications.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Droid Bar")]
[assembly: AssemblyDescription("Droid Bar")]
[assembly: AssemblyProduct("Droid Bar")]
[assembly: AssemblyCompany("Droid Bar")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class DroidBarHost
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "droid-bar.ps1");
        try
        {
            if (!File.Exists(script)) throw new FileNotFoundException("droid-bar.ps1 not found next to the executable.", script);

            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            iss.ApartmentState = ApartmentState.STA;
            iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    // -Name value / -Switch
                    for (int i = 0; i < args.Length; i++)
                    {
                        if (!args[i].StartsWith("-")) continue;
                        string name = args[i].TrimStart('-');
                        if (i + 1 < args.Length && !args[i + 1].StartsWith("-")) ps.AddParameter(name, args[++i]);
                        else ps.AddParameter(name);
                    }
                    ps.Invoke();
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            string msg = ex.Message;
            try
            {
                string log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "droid-bar", "droid-bar.log");
                Directory.CreateDirectory(Path.GetDirectoryName(log));
                File.AppendAllText(log, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  host: " + ex + Environment.NewLine);
            }
            catch { }
            MessageBox.Show(msg, "Droid Bar", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
