// WebP in the tray program: the left-out text, the offer of WebP support beside it, and Setup's downloads handed to the app.
// The libwebp release zips come from a local folder (BETTERICON_TEST_LIBWEBP), never from GitHub.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using BetterIcon.Tray;

// The checks of the process that runs WebPTests.RunPacks, which the main run reads back and reports as its own.
public sealed class WebPCheck { public string Test { get; set; } public bool Passed { get; set; } }
public sealed class WebPOutcome { public List<WebPCheck> Checks { get; set; } public string Error { get; set; } }

static class WebPTests
{
    const BindingFlags Instance = BindingFlags.Instance | BindingFlags.NonPublic;
    // Built by Test-TrayUI.ps1: downloaded packs whose artwork is WebP only, an app pack and a file type pack.
    const string AppsPack = "Craft-Icons-WebPFixture/Apps", FilesPack = "Craft-Icons-WebPFixture/Files";
    // Fixture A2 of the WebP spec: a lossless 32 pixel square.
    const string LosslessWebP = "UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEA8wPMM9KPMf8BDTEPqXdpsCEf2fAHq95QA=";
    static object Field(LauncherForm form, string name) { return typeof(LauncherForm).GetField(name, Instance).GetValue(form); }
    static object Call(LauncherForm form, string name, params object[] arguments) { return typeof(LauncherForm).GetMethod(name, Instance).Invoke(form, arguments); }
    static void Await(Func<bool> condition, string what)
    {
        Stopwatch watch = Stopwatch.StartNew();
        while (!condition()) {
            if (watch.Elapsed.TotalSeconds > 60) throw new Exception("Timed out: " + what);
            Application.DoEvents(); Thread.Sleep(10);
        }
    }
    // Like Await, but answers instead of throwing, so the check can say what did not happen.
    static bool Within(Func<bool> condition, int seconds)
    {
        Stopwatch watch = Stopwatch.StartNew();
        while (!condition()) {
            if (watch.Elapsed.TotalSeconds > seconds) return false;
            Application.DoEvents(); Thread.Sleep(10);
        }
        return true;
    }
    static string Sha256(string path) { using (SHA256 sha = SHA256.Create()) using (FileStream stream = File.OpenRead(path)) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(); }
    static IEnumerable<Control> Descendants(Control parent) { foreach (Control child in parent.Controls) { yield return child; foreach (Control inner in Descendants(child)) yield return inner; } }
    static void Click(LinkLabel link) { typeof(LinkLabel).GetMethod("OnLinkClicked", Instance).Invoke(link, new object[] { new LinkLabelLinkClickedEventArgs(link.Links[0]) }); }
    // A text of the tray program's DownloadTexts, or null where it has none.
    static string Text(string name)
    {
        FieldInfo field = typeof(LauncherForm).Assembly.GetType("BetterIcon.Tray.DownloadTexts").GetField(name);
        return field == null ? null : (string)field.GetValue(null);
    }

    public static void Run(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        // The status line text, three names at most. Pure text: no window needed.
        MethodInfo leftOutText = typeof(LauncherForm).GetMethod("LeftOutText", BindingFlags.Static | BindingFlags.NonPublic, null, new[] { typeof(ThemeEntry), typeof(bool) }, null);
        ThemeEntry five = new ThemeEntry { Id = "Craft-Icons-Fixture/Five", Name = "Five", Pack = "Craft-Icons-Fixture", Icons = new ThemeIcon[0], LeftOut = new[] {
            new LeftOutItem { Item = "ArtCraft Launcher", Reason = WebpArtwork.NoDecoder, Kind = "App" }, new LeftOutItem { Item = "AniCraft", Reason = WebpArtwork.Animated, Kind = "App" },
            new LeftOutItem { Item = "CADCraft", Reason = WebpArtwork.NoDecoder, Kind = "App" }, new LeftOutItem { Item = "FilmCraft", Reason = WebpArtwork.NoDecoder, Kind = "App" },
            new LeftOutItem { Item = "PhotoCraft", Reason = WebpArtwork.NoDecoder, Kind = "App" }, new LeftOutItem { Item = ".pcraft", Reason = WebpArtwork.Damaged, Kind = "File" } } };
        check((string)leftOutText.Invoke(null, new object[] { five, false }) == "Left out: ArtCraft Launcher, AniCraft, CADCraft and 2 more. " + WebpArtwork.NoDecoder
            && (string)leftOutText.Invoke(null, new object[] { five, true }) == "Left out: .pcraft. " + WebpArtwork.Damaged
            && leftOutText.Invoke(null, new object[] { new ThemeEntry { LeftOut = new LeftOutItem[0] }, false }) == null,
            "The status line names the items a pack leaves out and the first one's cause, three names at most");

        // Setup's pack choices as its page shows them, worded by the installed program (--setup-status). Pure text.
        MethodInfo packChoice = typeof(LauncherForm).Assembly.GetType("BetterIcon.Tray.SetupProbe").GetMethod("PackChoice", BindingFlags.Static | BindingFlags.NonPublic);
        Func<string, int, long, int, string> choice = (label, count, bytes, unknown) => packChoice == null ? null : (string)packChoice.Invoke(null, new object[] { label, count, bytes, unknown });
        check(choice("All file type icon packs", 1, 4299161, 0) == "All file type icon packs (1 pack, 4.1 MB)" && choice("All app icon packs", 27, 332433764, 0) == "All app icon packs (27 packs, 317.0 MB)"
            && choice("All app icon packs", 3, 3145728, 1) == "All app icon packs (3 packs, at least 3.0 MB)" && choice("All app icon packs", 1, 0, 1) == "All app icon packs (1 pack, size unknown)",
            "Setup's pack choices name one pack in the singular and say when sizes are unknown");

        // Packs that really are on this computer, from the start of BetterIcon, in a process of their own: a process loads
        // WebP support at most once, and those checks install it.
        RunPacksProcess(root, source, json, check);

        string links = Path.Combine(root, "webp-links"), state = Path.Combine(root, "webp-state");
        Directory.CreateDirectory(links); Directory.CreateDirectory(state);
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), Path.Combine(links, "PhotoCraft.lnk"));
        File.WriteAllText(Path.Combine(state, "tray-preferences.json"), json.Serialize(new Preferences { Theme = "Craft-Icons-Zach/HyGel", IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        string packages = Environment.GetEnvironmentVariable("BETTERICON_TEST_LIBWEBP");
        bool havePackages = !String.IsNullOrEmpty(packages) && File.Exists(Path.Combine(packages, "BetterIcon-libwebp-1.6.0-x64.zip")) && LibWebP.ProcessArchitecture == "x64";
        string[] seams = { WebpArtwork.DecoderSeam, LibWebP.SourceSeam };
        Exception failure = null;
        try {
            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
                ready.Tick += delegate {
                    if ((bool)Field(form, "busy") || Field(form, "catalog") == null) return;
                    ready.Stop();
                    try {
                        form.ShowManager(); ((TabControl)Field(form, "pages")).SelectedIndex = 1; Application.DoEvents();
                        LoadingTests.Wait((Task)Field(form, "setupDownloadsTask"));
                        ComboBox themes = (ComboBox)Field(form, "themes");
                        Label status = (Label)Field(form, "status");
                        ContextMenuStrip tray = (ContextMenuStrip)Field(form, "trayMenu");
                        Func<FlowLayoutPanel> offerRow = () => (FlowLayoutPanel)Field(form, "webpActions");
                        Func<bool> offered = () => offerRow() != null && offerRow().Visible;
                        Func<string, bool> inTray = name => tray.Items.Cast<ToolStripItem>().Any(item => item.Name == name);
                        ThemeEntry original = (ThemeEntry)themes.SelectedItem;
                        PngIcon(state, "PhotoCraft");
                        ThemeEntry fixture = new ThemeEntry { Id = "Craft-Icons-Fixture/WebP Only", Name = "WebP Only", Pack = "Craft-Icons-Fixture", Author = "Fixture", IconCount = 1, Downloaded = true,
                            Icons = new[] { new ThemeIcon { Application = "FilmCraft", Path = Path.Combine(state, "PhotoCraft.png"), PreviewPath = Path.Combine(state, "PhotoCraft.png") } },
                            FileIcons = new Dictionary<string, string>(), AppFileIcons = new Dictionary<string, string>(),
                            LeftOut = new[] { new LeftOutItem { Item = "PhotoCraft", Reason = WebpArtwork.NoDecoder, Kind = "App" } } };
                        Action<object> select = theme => {
                            typeof(LauncherForm).GetField("fillingThemes", Instance).SetValue(form, true);
                            try { if (!themes.Items.Contains(theme)) themes.Items.Add(theme); themes.SelectedItem = theme; }
                            finally { typeof(LauncherForm).GetField("fillingThemes", Instance).SetValue(form, false); }
                        };
                        Action<ThemeEntry> choose = theme => { select(theme); Call(form, "UpdateWebPOffer"); };

                        Environment.SetEnvironmentVariable(WebpArtwork.DecoderSeam, "none");
                        choose(fixture);
                        string text = (string)Call(form, "PackLoadedText", fixture, false);
                        LinkLabel link = offered() ? offerRow().Controls.OfType<LinkLabel>().FirstOrDefault(control => control.Name == "WebPSupportLink") : null;
                        check(text == fixture + " loaded. Left out: PhotoCraft. " + WebpArtwork.NoDecoder + " Choose Apply icons to change Windows shortcuts."
                            && offered() && link != null && link.Text == String.Format("Install WebP support ({0})", LauncherFormSize(LibWebP.DownloadBytes(LibWebP.NeededArchitectures)))
                            && offerRow().Parent == status.Parent && inTray("WebPSupportItem") && form.OwnedForms.Length == 0,
                            "A pack whose WebP-only artwork this PC can't read offers WebP support beside the status line and in the tray menu, never in a dialog");

                        // The usual way to choose a pack (a row click, Enter or the tray), which loads it while BetterIcon is busy.
                        select(original);
                        themes.GetType().GetMethod("ChooseItem").Invoke(themes, new object[] { fixture });
                        bool loaded = Within(() => ((Task)Field(form, "packLoadTask")).IsCompleted && !(bool)Field(form, "busy"), 60);
                        link = offered() ? offerRow().Controls.OfType<LinkLabel>().FirstOrDefault(control => control.Name == "WebPSupportLink") : null;
                        check(loaded && themes.SelectedItem == fixture && link != null && link.Enabled && inTray("WebPSupportItem"),
                            "After a pack is chosen the usual way, its Install WebP support link can be clicked");

                        fixture.LeftOut = new[] { new LeftOutItem { Item = "PhotoCraft", Reason = WebpArtwork.Animated, Kind = "App" } };
                        Call(form, "UpdateWebPOffer");
                        check(!offered() && !inTray("WebPSupportItem"), "Other reasons for left-out artwork do not offer WebP support");

                        fixture.LeftOut = new[] { new LeftOutItem { Item = "PhotoCraft", Reason = WebpArtwork.NoDecoder, Kind = "App" } };
                        Environment.SetEnvironmentVariable(WebpArtwork.DecoderSeam, null);
                        Call(form, "UpdateWebPOffer");
                        if (WebpArtwork.SystemDecoderAvailable) check(!offered() && !inTray("WebPSupportItem"), "When Windows decodes WebP, BetterIcon never offers WebP support");
                        else Console.WriteLine("SKIP When Windows decodes WebP, BetterIcon never offers WebP support (no system WebP decoder)");

                        // Setup handed over WebP support, and the download fails: BetterIcon goes on and offers it again.
                        Environment.SetEnvironmentVariable(WebpArtwork.DecoderSeam, "libwebp");
                        string empty = Path.Combine(root, "webp-empty-release"); Directory.CreateDirectory(empty);
                        Environment.SetEnvironmentVariable(LibWebP.SourceSeam, empty);
                        SetupDownloadRequest.Merge(state, "webp");
                        Task handOver = (Task)Call(form, "ProcessSetupDownloads", false);
                        LoadingTests.Wait(handOver);
                        SetupDownloadRequest kept = SetupDownloadRequest.Read(state);
                        FlowLayoutPanel setupRow = (FlowLayoutPanel)Field(form, "setupActions");
                        LinkLabel retry = setupRow == null ? null : setupRow.Controls.OfType<LinkLabel>().FirstOrDefault(control => control.Name == "SetupDownloadsRetry");
                        check(handOver.IsCompleted && !handOver.IsFaulted && kept != null && kept.WebP && kept.Attempts == 1 && kept.Failure != null && kept.Failure.StartsWith("Couldn't install the WebP support you chose in Setup.")
                            && status.Text == kept.Failure && setupRow.Visible && retry != null && retry.Visible && retry.Text == "Try again" && inTray("SetupDownloadsItem") && form.OwnedForms.Length == 0
                            && !LibWebP.Installed("x64"),
                            "A failed download of the WebP support chosen in Setup lets BetterIcon go on and offers it again");

                        // The same failure while BetterIcon waits hidden in the tray, as after a silent install or at login: the
                        // tray menu keeps offering it, and one balloon tells of it.
                        form.Hide(); Application.DoEvents();
                        SetupDownloadRequest.Merge(state, "webp");
                        Task hiddenHandOver = (Task)Call(form, "ProcessSetupDownloads", false);
                        LoadingTests.Wait(hiddenHandOver);
                        string trace = Path.Combine(state, "tray-events.jsonl");
                        int balloons = File.Exists(trace) ? File.ReadAllLines(trace).Count(line => line.Contains("Setup downloads balloon")) : 0;
                        Call(form, "BuildTrayMenu");
                        check(!form.Visible && inTray("SetupDownloadsItem") && balloons == 1,
                            "A download Setup handed over that fails while BetterIcon is hidden stays in the tray menu, and one balloon tells of it");
                        form.ShowManager(); ((TabControl)Field(form, "pages")).SelectedIndex = 1; Application.DoEvents();
                        Call(form, "UpdateWebPOffer");

                        // The same failure while the window shows the Launcher, as when Setup opens it there: the status line and the
                        // offer are in Manage Icons, so one balloon tells of it where the user is.
                        ((TabControl)Field(form, "pages")).SelectedIndex = 0; Application.DoEvents();
                        int balloonsBefore = File.Exists(trace) ? File.ReadAllLines(trace).Count(line => line.Contains("Setup downloads balloon")) : 0;
                        SetupDownloadRequest.Merge(state, "webp");
                        Task launcherHandOver = (Task)Call(form, "ProcessSetupDownloads", false);
                        LoadingTests.Wait(launcherHandOver);
                        int balloonsAfter = File.Exists(trace) ? File.ReadAllLines(trace).Count(line => line.Contains("Setup downloads balloon")) : 0;
                        SetupDownloadRequest announced = SetupDownloadRequest.Read(state);
                        check(form.Visible && ((TabControl)Field(form, "pages")).SelectedIndex == 0 && balloonsAfter == balloonsBefore + 1 && announced != null && announced.Announced && form.OwnedForms.Length == 0,
                            "A download Setup handed over that fails while the window shows the Launcher is told in one balloon, since its status line is in Manage Icons");
                        ((TabControl)Field(form, "pages")).SelectedIndex = 1; Application.DoEvents();
                        Call(form, "UpdateWebPOffer");

                        // An import that fails because this PC can't read WebP offers WebP support right there.
                        select(original);
                        Call(form, "UpdateWebPOffer");
                        bool quietBefore = !offered();
                        string importFolder = Path.Combine(root, "webp-import-only"); Directory.CreateDirectory(importFolder);
                        File.WriteAllBytes(Path.Combine(importFolder, "PhotoCraft.webp"), Convert.FromBase64String(LosslessWebP));
                        string reported = null;
                        MethodInfo importFrom = typeof(LauncherForm).GetMethod("ImportPackFrom", Instance);
                        if (importFrom != null) using (System.Windows.Forms.Timer answer = new System.Windows.Forms.Timer { Interval = 25 }) {
                            answer.Tick += delegate {
                                Form dialog = Application.OpenForms.Cast<Form>().FirstOrDefault(window => window != form && window.Visible && window.Text == "BetterIcon");
                                if (dialog == null) return;
                                answer.Stop();
                                reported = String.Join(" ", Descendants(dialog).OfType<Label>().Select(label => label.Text));
                                dialog.DialogResult = DialogResult.OK;
                            };
                            answer.Start();
                            LoadingTests.Wait((Task)importFrom.Invoke(form, new object[] { importFolder }));
                            answer.Stop();
                        }
                        check(quietBefore && reported != null && reported.Contains(WebpArtwork.NoDecoder) && offered() && inTray("WebPSupportItem") && form.OwnedForms.Length == 0,
                            "When an import fails because this PC can't read WebP, WebP support is offered beside the status line and in the tray menu");
                        // Not now puts that offer away again.
                        if (offerRow() != null) Click(offerRow().Controls.OfType<LinkLabel>().First(control => control.Name == "WebPSupportNotNow"));

                        if (!havePackages) {
                            Console.WriteLine("SKIP Installing WebP support from the offer makes WebP artwork load at once, without restarting BetterIcon (BETTERICON_TEST_LIBWEBP names no folder with the release zips)");
                            Console.WriteLine("SKIP A Setup request for WebP support that this PC no longer needs is cleared without a download (BETTERICON_TEST_LIBWEBP names no folder with the release zips)");
                        }
                        else {
                            // The user takes the offer beside the status line.
                            choose(fixture);
                            Environment.SetEnvironmentVariable(LibWebP.SourceSeam, packages);
                            link = offerRow().Controls.OfType<LinkLabel>().First(control => control.Name == "WebPSupportLink");
                            check(offered() && link.Enabled, "The WebP offer is ready while nothing else is running");
                            Click(link);
                            Await(() => !(bool)Field(form, "webpInstalling") && !(bool)Field(form, "busy") && status.Text == Text("WebPDone"), "the WebP support install");
                            string dll = Path.Combine(state, "libwebp", "1.6.0", "x64", "libwebpdecoder.dll");
                            check(File.Exists(dll) && Sha256(dll) == LibWebP.Pins.Packages["x64"].DllSha256 && WebpArtwork.Decoder == "libwebp" && LibWebP.LoadedFrom == dll && !offered()
                                && File.Exists(Path.Combine(state, "libwebp", "1.6.0", "x64", "COPYING")) && form.OwnedForms.Length == 0,
                                "Installing WebP support from the offer makes WebP artwork load at once, without restarting BetterIcon");
                            // What Setup asked for is here now: the request goes without another download.
                            Environment.SetEnvironmentVariable(LibWebP.SourceSeam, empty);
                            Task again = (Task)Call(form, "ProcessSetupDownloads", true);
                            LoadingTests.Wait(again);
                            check(SetupDownloadRequest.Read(state) == null && !File.Exists(SetupDownloadRequest.PathIn(state)) && !((FlowLayoutPanel)Field(form, "setupActions")).Visible,
                                "A Setup request for WebP support that this PC no longer needs is cleared without a download");
                        }
                        typeof(LauncherForm).GetField("fillingThemes", Instance).SetValue(form, true);
                        try { themes.Items.Remove(fixture); themes.SelectedItem = original; }
                        finally { typeof(LauncherForm).GetField("fillingThemes", Instance).SetValue(form, false); }
                        stop.Set();
                    }
                    catch (Exception error) { failure = error; context.ExitThread(); }
                };
                ready.Start(); Application.Run(context);
            }
        }
        finally { foreach (string seam in seams) Environment.SetEnvironmentVariable(seam, null); }
        if (failure != null) throw failure;
    }

    // ---- Packs on this computer, from the start of BetterIcon, in a process of its own ---------------------------------
    static readonly string[] PackTitles = {
        "At start, the status line names what the chosen packs leave out and why",
        "While BetterIcon waits hidden in the tray, its menu offers WebP support for the packs that need it",
        "After start, the Install WebP support link beside the status line can be clicked",
        "With the Launcher showing, the tray menu still offers WebP support",
        "One Not now hides the offer when the chosen app pack and file type pack both leave WebP artwork out",
        "Choosing a pack again after Not now offers WebP support again, and its link can be clicked" };
    static readonly string[] InstallTitles = {
        "WebP support installed while another task runs waits for it to end, and the status line says so",
        "When that task ends, the packs are read again and the left-out WebP icons load, without restarting BetterIcon",
        "An offer that ended while BetterIcon was hidden is gone when the window opens" };
    static void RunPacksProcess(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string results = Path.Combine(root, "webp-packs-results.json");
        Func<string, string> quote = value => "\"" + value.TrimEnd('\\') + "\"";
        ProcessStartInfo start = new ProcessStartInfo(Assembly.GetEntryAssembly().Location, quote(root) + " " + quote(source) + " --webp-packs") { UseShellExecute = false };
        using (Process child = Process.Start(start)) {
            if (!child.WaitForExit(600000)) { child.Kill(); throw new Exception("The WebP pack checks did not finish within 10 minutes."); }
        }
        if (!File.Exists(results)) throw new Exception("The WebP pack checks wrote no results.");
        WebPOutcome outcome = json.Deserialize<WebPOutcome>(File.ReadAllText(results));
        foreach (WebPCheck item in outcome.Checks ?? new List<WebPCheck>()) check(item.Passed, item.Test);
        if (outcome.Error != null) throw new Exception("The WebP pack checks stopped: " + outcome.Error);
    }
    // TrayTests.exe <root> <source> --webp-packs
    public static int RunPacksChild(string root, string source)
    {
        List<WebPCheck> results = new List<WebPCheck>();
        string error = null;
        Action<bool, string> check = (ok, name) => {
            results.Add(new WebPCheck { Test = name, Passed = ok });
            if (!ok) throw new Exception(name);
            Console.WriteLine("PASS: " + name);
        };
        try { RunPacks(root, source, new JavaScriptSerializer(), check); }
        catch (Exception failure) { error = failure.ToString(); Console.Error.WriteLine(error); }
        File.WriteAllText(Path.Combine(root, "webp-packs-results.json"), new JavaScriptSerializer().Serialize(new WebPOutcome { Checks = results, Error = error }));
        return error == null ? 0 : 1;
    }
    static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (string file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        foreach (string folder in Directory.GetDirectories(from)) CopyFolder(folder, Path.Combine(to, Path.GetFileName(folder)));
    }
    public static void RunPacks(string root, string source, JavaScriptSerializer json, Action<bool, string> check)
    {
        string built = Path.Combine(root, "webp-packs-state");
        if (!Directory.Exists(built)) {
            foreach (string title in PackTitles.Concat(InstallTitles)) Console.WriteLine("SKIP " + title + " (Test-TrayUI.ps1 made no WebP pack fixture)");
            return;
        }
        string state = Path.Combine(root, "webp-packs-run"), links = Path.Combine(root, "webp-packs-links");
        CopyFolder(built, state);
        Directory.CreateDirectory(links);
        File.Copy(Path.Combine(root, "PhotoCraft.lnk"), Path.Combine(links, "PhotoCraft.lnk"));
        File.WriteAllText(Path.Combine(state, "tray-preferences.json"), json.Serialize(new Preferences { Theme = AppsPack, FileTheme = FilesPack, IconSize = 48, Hotkey = new HotkeySettings { Enabled = false } }));
        string packages = Environment.GetEnvironmentVariable("BETTERICON_TEST_LIBWEBP");
        bool havePackages = !String.IsNullOrEmpty(packages) && File.Exists(Path.Combine(packages, "BetterIcon-libwebp-1.6.0-x64.zip")) && LibWebP.ProcessArchitecture == "x64";
        string[] seams = { WebpArtwork.DecoderSeam, LibWebP.SourceSeam };
        // Windows' decoder hidden and WebP support not installed: a PC that needs it.
        Environment.SetEnvironmentVariable(WebpArtwork.DecoderSeam, "libwebp");
        Exception failure = null;
        try {
            using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset))
            using (LauncherForm form = new LauncherForm(source, new FixtureConfig { ShortcutDirectory = new[] { links }, StateDirectory = state, KeepOpenForAutomation = true }, true, show, stop))
            using (LauncherContext context = new LauncherContext(form))
            using (System.Windows.Forms.Timer ready = new System.Windows.Forms.Timer { Interval = 50 }) {
                ready.Tick += delegate {
                    if ((bool)Field(form, "busy") || Field(form, "catalog") == null) return;
                    ready.Stop();
                    try {
                        LoadingTests.Wait((Task)Field(form, "setupDownloadsTask"));
                        ComboBox themes = (ComboBox)Field(form, "themes"), fileThemes = (ComboBox)Field(form, "fileThemes");
                        Label status = (Label)Field(form, "status");
                        ContextMenuStrip tray = (ContextMenuStrip)Field(form, "trayMenu");
                        TabControl pages = (TabControl)Field(form, "pages");
                        Func<FlowLayoutPanel> offerRow = () => (FlowLayoutPanel)Field(form, "webpActions");
                        Func<string, LinkLabel> offerLink = name => offerRow() == null ? null : offerRow().Controls.OfType<LinkLabel>().FirstOrDefault(control => control.Name == name);
                        Func<string, bool> inTray = name => tray.Items.Cast<ToolStripItem>().Any(item => item.Name == name);
                        Func<bool> idle = () => ((Task)Field(form, "packLoadTask")).IsCompleted && !(bool)Field(form, "busy");
                        ThemeEntry apps = themes.SelectedItem as ThemeEntry, files = fileThemes.SelectedItem as ThemeEntry;
                        bool chosen = apps != null && apps.Id == AppsPack && files != null && files.Id == FilesPack;

                        // Started hidden in the tray, as at login.
                        check(chosen && !form.Visible && status.Text == "Left out: PhotoCraft. " + WebpArtwork.NoDecoder, PackTitles[0]);
                        Call(form, "BuildTrayMenu");
                        check(!form.Visible && inTray("WebPSupportItem"), PackTitles[1]);
                        LinkLabel install = offerLink("WebPSupportLink");
                        check(install != null && install.Enabled, PackTitles[2]);
                        form.ShowManager(); pages.SelectedIndex = 0; Application.DoEvents();
                        Call(form, "BuildTrayMenu");
                        check(form.Visible && pages.SelectedIndex == 0 && inTray("WebPSupportItem"), PackTitles[3]);

                        pages.SelectedIndex = 1; Application.DoEvents();
                        bool shownBefore = offerRow() != null && offerRow().Visible;
                        LinkLabel notNow = offerLink("WebPSupportNotNow");
                        if (notNow != null) Click(notNow);
                        check(shownBefore && notNow != null && !offerRow().Visible && !inTray("WebPSupportItem"), PackTitles[4]);

                        // Another pack, then the app pack again: Not now lasted only while the packs it put off stayed chosen.
                        MethodInfo chooseItem = themes.GetType().GetMethod("ChooseItem");
                        chooseItem.Invoke(themes, new object[] { themes.Items.OfType<ThemeEntry>().First(theme => theme.IsDefault) });
                        bool loaded = Within(idle, 60);
                        chooseItem.Invoke(themes, new object[] { apps });
                        loaded = loaded && Within(idle, 60);
                        install = offerLink("WebPSupportLink");
                        check(loaded && themes.SelectedItem == apps && offerRow().Visible && inTray("WebPSupportItem") && install != null && install.Enabled, PackTitles[5]);

                        if (!havePackages) foreach (string title in InstallTitles) Console.WriteLine("SKIP " + title + " (BETTERICON_TEST_LIBWEBP names no folder with the release zips)");
                        else {
                            // Hidden, the install starts, and another operation begins before it finishes.
                            form.Hide(); Application.DoEvents();
                            Environment.SetEnvironmentVariable(LibWebP.SourceSeam, packages);
                            Task installing = (Task)Call(form, "InstallWebPSupport", false);
                            Call(form, "SetBusy", true, "A test operation is running...");
                            bool installed = Within(() => !(bool)Field(form, "webpInstalling") && installing.IsCompleted, 60);
                            string waiting = Text("WebPWaiting");
                            ThemeEntry during = themes.SelectedItem as ThemeEntry;
                            check(installed && waiting != null && status.Text == waiting && during != null && during.Id == AppsPack && during.LeftOut != null && during.LeftOut.Length > 0, InstallTitles[0]);
                            Call(form, "SetBusy", false, null);
                            Func<ThemeEntry> now = () => themes.SelectedItem as ThemeEntry;
                            bool reloaded = Within(() => !(bool)Field(form, "busy") && now() != null && now().Id == AppsPack && now().LeftOut != null && now().LeftOut.Length == 0 && status.Text == Text("WebPDone"), 90);
                            check(reloaded && now().IconCount == 1 && now().Icons.Length == 1 && now().Icons[0].Path.EndsWith("PhotoCraft.webp", StringComparison.OrdinalIgnoreCase) && WebpArtwork.Decoder == "libwebp", InstallTitles[1]);
                            form.ShowManager(); pages.SelectedIndex = 1; Application.DoEvents();
                            check(form.Visible && (offerRow() == null || !offerRow().Visible), InstallTitles[2]);
                        }
                        stop.Set();
                    }
                    catch (Exception error) { failure = error; context.ExitThread(); }
                };
                ready.Start(); Application.Run(context);
            }
        }
        finally { foreach (string seam in seams) Environment.SetEnvironmentVariable(seam, null); }
        if (failure != null) throw failure;
    }
    static string LauncherFormSize(long bytes) { return (string)typeof(LauncherForm).GetMethod("DownloadSize", BindingFlags.Static | BindingFlags.NonPublic).Invoke(null, new object[] { bytes }); }
    static void PngIcon(string folder, string name)
    {
        using (Bitmap bitmap = new Bitmap(32, 32)) {
            using (Graphics g = Graphics.FromImage(bitmap)) g.Clear(Color.SeaGreen);
            bitmap.Save(Path.Combine(folder, name + ".png"), System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
