// Local native event tests. No installed shortcuts are opened or changed.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

static class TrayTests
{
    static readonly List<object> checks = new List<object>();
    static void Check(bool ok, string name)
    {
        checks.Add(new { Test = name, Passed = ok });
        if (!ok) throw new Exception(name);
        Console.WriteLine("PASS: " + name);
    }
    [STAThread]
    static int Main(string[] args)
    {
        string failure = null, root = args[0];
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        try {
            Rectangle work = new Rectangle(0, 0, 1920, 1040);
            Rectangle bottom = PopupPlacement.AboveTray(new Size(900, 690), new Point(1850, 1060), work);
            Check(work.Contains(bottom) && bottom.Bottom <= 1040 && bottom.Right <= 1920, "Bottom taskbar placement remains above the taskbar");
            work = new Rectangle(-1920, -200, 1920, 1040);
            Rectangle left = PopupPlacement.AboveTray(new Size(900, 690), new Point(-1900, 800), work);
            Check(work.Contains(left), "Negative monitor coordinates stay on the selected screen");
            work = new Rectangle(64, 0, 1280, 800);
            Check(work.Contains(PopupPlacement.AboveTray(new Size(900, 690), new Point(20, 760), work)), "Side taskbar placement stays inside the work area");
            work = new Rectangle(0, 60, 1024, 708);
            Check(work.Contains(PopupPlacement.AboveTray(new Size(900, 690), new Point(1000, 20), work)), "Top taskbar placement stays inside the work area");
            work = new Rectangle(0, 0, 640, 480);
            Check(work.Contains(PopupPlacement.AboveTray(new Size(2000, 1500), new Point(630, 490), work)), "Oversized popup fits a small display");
            work = new Rectangle(0, 0, 1, 1);
            Check(PopupPlacement.AboveTray(new Size(900, 690), Point.Empty, work) == work, "Tiny work area remains valid");

            string workerState = Path.Combine(root, "worker-state");
            Directory.CreateDirectory(workerState);
            File.WriteAllText(Path.Combine(workerState, "manifest.json"), "{\"Product\":\"BetterIcon-Craft Apps Windows\",\"SchemaVersion\":1,\"Version\":\"1.1.0\",\"Scope\":\"CurrentUser\",\"Entries\":[]}");
            WorkerClient client = new WorkerClient(args[1], new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = workerState });
            WorkerReply catalog = client.Run(new WorkerRequest { Action = "Catalog", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
            Check(catalog.Success && catalog.Catalog.Themes.Length == 14 && catalog.Catalog.Apps.Length == 1 && catalog.Catalog.Apps[0].Application == "PhotoCraft", "Native process invokes the catalog worker with a real fixture shortcut");
            WorkerReply preview = client.Run(new WorkerRequest { Action = "RestorePreview", Scope = "CurrentUser" }, false).GetAwaiter().GetResult();
            Check(preview.Success && preview.StateHash.Length == 64 && preview.Results.Length == 0, "Native restore worker hashes an existing manifest with inherited module paths");

            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (LauncherForm form = new LauncherForm(args[1], new FixtureConfig { ShortcutDirectory = new[] { root }, StateDirectory = Path.Combine(root, "state") }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 50 }) {
                // Exercise the actual NotifyIcon MouseUp subscription. This is an
                // event-level check, not a claim of a physical taskbar click.
                NotifyIcon tray = (NotifyIcon)typeof(LauncherForm).GetField("tray", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form);
                MethodInfo mouseUp = typeof(NotifyIcon).GetMethod("OnMouseUp", BindingFlags.Instance | BindingFlags.NonPublic);
                Action click = delegate { mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Left, 1, 0, 0, 0) }); };
                Exception eventFailure = null;
                int ticks = 0;
                timer.Tick += delegate {
                    try {
                        if (++ticks > 600) throw new Exception("Tray startup did not finish within 30 seconds.");
                        if ((bool)typeof(LauncherForm).GetField("busy", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(form)) return;
                        timer.Stop();
                        Check(!form.Visible, "Tray-only startup stays hidden after the real message loop initializes");
                        click();
                        Check(form.Visible && Screen.FromPoint(Cursor.Position).WorkingArea.Contains(form.Bounds), "First tray release shows the popup on the clicked screen");
                        click(); Check(!form.Visible, "Second tray release hides the popup");
                        click(); click(); Check(!form.Visible, "Rapid double release ends hidden without reopening");
                        mouseUp.Invoke(tray, new object[] { new MouseEventArgs(MouseButtons.Right, 1, 0, 0, 0) });
                        Check(!form.Visible, "Right tray release does not toggle the popup");
                        form.ShowManager(); Check(form.Visible, "Explicit open reopens the existing popup");
                        form.Hide(); Check(!form.Visible, "Hide retains the launcher for another tray click");
                        stop.Set(); // Exercise normal shutdown through the same message loop.
                    }
                    catch (Exception error) { eventFailure = error; timer.Stop(); context.ExitThread(); }
                };
                timer.Start(); Application.Run(context);
                if (eventFailure != null) throw eventFailure;
            }
        }
        catch (Exception error) { failure = error.ToString(); Console.Error.WriteLine(failure); }
        finally { File.WriteAllText(Path.Combine(root, "results.json"), new JavaScriptSerializer().Serialize(new { Passed = failure == null, Error = failure, Checks = checks, ArtifactDirectory = root })); }
        return failure == null ? 0 : 1;
    }
}
