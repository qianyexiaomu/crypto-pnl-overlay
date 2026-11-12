using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace OkxPnlExe
{
    internal static class Program
    {
        /// <summary>单实例：已有实例在跑就不再开第二个</summary>
        private static Mutex _mutex;

        /// <summary>把还在跑的老版 .ps1 实例停掉，避免 exe 和 ps1 各开一个窗口</summary>
        private static void KillLegacyInstances()
        {
            try
            {
                // 只认「本目录下的 OkxPnl.ps1 被 -File 直接执行」这一种，避免误杀别的 PowerShell
                string want = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "OkxPnl.ps1");
                using (var searcher = new System.Management.ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
                {
                    foreach (System.Management.ManagementObject mo in searcher.Get())
                    {
                        string cmd = Convert.ToString(mo["CommandLine"]);
                        if (cmd == null) continue;
                        if (cmd.IndexOf("-File", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        if (cmd.IndexOf(want, StringComparison.OrdinalIgnoreCase) < 0) continue;
                        int pid;
                        if (!int.TryParse(Convert.ToString(mo["ProcessId"]), out pid)) continue;
                        try { System.Diagnostics.Process.GetProcessById(pid).Kill(); } catch { }
                    }
                }
                Thread.Sleep(300);
            }
            catch { }
        }

        [STAThread]
        private static void Main()
        {
            bool created;
            _mutex = new Mutex(true, "OkxPnlOverlayExe", out created);
            if (!created)
            {
                return;
            }

            try
            {
                KillLegacyInstances();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                string dir = AppDomain.CurrentDomain.BaseDirectory;
                if (dir.EndsWith(Path.DirectorySeparatorChar.ToString())) dir = dir.TrimEnd(Path.DirectorySeparatorChar);

                Application.Run(new OkxPnl.Board(dir));
            }
            catch (Exception ex)
            {
                try
                {
                    File.AppendAllText(Path.Combine(Path.GetTempPath(), "okxpnl-exe-crash.txt"),
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + ex + Environment.NewLine);
                    MessageBox.Show("启动失败：" + Environment.NewLine + ex.Message, "持仓盈亏悬浮窗",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch { }
            }
            finally
            {
                try { _mutex.ReleaseMutex(); } catch { }
            }
        }
    }
}
