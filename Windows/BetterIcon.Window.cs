using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BetterIcon.Tray
{
    public sealed partial class LauncherForm
    {
        const int WindowCornerRadius = 32;
        readonly Dictionary<Control, ResizeHitWindow> resizeWindows = new Dictionary<Control, ResizeHitWindow>();
        bool roundedWindowReady, outlinedSquare;
        Size outlinedSize;

        int CornerRadius { get { return Math.Min(WindowCornerRadius, Math.Min(ClientSize.Width, ClientSize.Height) / 2); } }
        void InitializeRoundedWindow()
        {
            roundedWindowReady = true;
            ControlAdded += RoundedControlAdded;
            foreach (Control child in Controls) HookResizeControl(child);
            UpdateWindowOutline();
        }
        void RoundedControlAdded(object sender, ControlEventArgs e) { HookResizeControl(e.Control); }
        void HookResizeControl(Control control)
        {
            if (!roundedWindowReady || control == null || control.IsDisposed || resizeWindows.ContainsKey(control)) return;
            resizeWindows.Add(control, new ResizeHitWindow(this, control));
            foreach (Control child in control.Controls) HookResizeControl(child);
        }
        void UpdateWindowOutline()
        {
            if (!roundedWindowReady || IsDisposed || Disposing || ClientSize.Width < 1 || ClientSize.Height < 1) return;
            bool square = WindowState != FormWindowState.Normal;
            if (outlinedSize == ClientSize && outlinedSquare == square) return;
            // Set the cache before assigning Region: SetWindowRgn may cause layout.
            outlinedSize = ClientSize; outlinedSquare = square;
            Region replacement = null;
            if (!square) using (GraphicsPath path = new GraphicsPath()) {
                int diameter = CornerRadius * 2, width = ClientSize.Width, height = ClientSize.Height;
                if (diameter == 0) path.AddRectangle(ClientRectangle);
                else {
                    path.AddArc(0, 0, diameter, diameter, 180, 90);
                    path.AddArc(width - diameter, 0, diameter, diameter, 270, 90);
                    path.AddArc(width - diameter, height - diameter, diameter, diameter, 0, 90);
                    path.AddArc(0, height - diameter, diameter, diameter, 90, 90);
                    path.CloseFigure();
                }
                replacement = new Region(path);
            }
            Region previous = Region;
            Region = replacement;
            if (previous != null) previous.Dispose();
        }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); UpdateWindowOutline(); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); outlinedSize = Size.Empty; UpdateWindowOutline(); }
        static Point HitTestPoint(IntPtr value)
        {
            long point = value.ToInt64();
            return new Point(unchecked((short)(point & 0xFFFF)), unchecked((short)((point >> 16) & 0xFFFF)));
        }
        int ResizeHitTest(Point screen)
        {
            if (!IsHandleCreated || WindowState != FormWindowState.Normal) return 1;
            Point point = PointToClient(screen);
            if (!ClientRectangle.Contains(point) || (Region != null && !Region.IsVisible(point))) return 0;
            int border = Math.Max(6, Padding.Left), corner = Math.Max(border, CornerRadius);
            bool left = point.X < corner, right = point.X >= ClientSize.Width - corner;
            if (point.Y < corner) { if (left) return 13; if (right) return 14; }
            if (point.Y >= ClientSize.Height - corner) { if (left) return 16; if (right) return 17; }
            if (point.X < border) return 10;
            if (point.X >= ClientSize.Width - border) return 11;
            if (point.Y < border) return 12;
            if (point.Y >= ClientSize.Height - border) return 15;
            return 1;
        }
        protected override CreateParams CreateParams
        {
            get {
                CreateParams value = base.CreateParams;
                value.Style = (value.Style | 0x00040000) & ~0x00C00000;
                return value;
            }
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0083) { message.Result = IntPtr.Zero; return; } // Full-client WM_NCCALCSIZE.
            if (message.Msg == 0x0084 && WindowState == FormWindowState.Normal) {
                message.Result = new IntPtr(ResizeHitTest(HitTestPoint(message.LParam))); return;
            }
            if (WindowState == FormWindowState.Normal && !(appearancePalette == null ? SystemInformation.HighContrast : appearancePalette.HighContrast)) {
                // WS_THICKFRAME keeps native edge resizing, but Windows can still
                // paint its frame during activation/redraw even with no client inset.
                // The popup paints the entire surface; retain the system frame only
                // in high contrast. DWM border-color suppression alone is insufficient.
                if (message.Msg == 0x0085) { message.Result = IntPtr.Zero; return; } // WM_NCPAINT.
                // -1 preserves native activation bookkeeping without painting the frame.
                if (message.Msg == 0x0086) message.LParam = new IntPtr(-1); // WM_NCACTIVATE.
            }
            base.WndProc(ref message);
        }
        void DisposeRoundedWindow()
        {
            roundedWindowReady = false; ControlAdded -= RoundedControlAdded;
            foreach (ResizeHitWindow hook in resizeWindows.Values) hook.Dispose();
            resizeWindows.Clear();
            Region previous = Region; Region = null;
            if (previous != null) previous.Dispose();
        }

        // Controls fill most of the client area. Let resize hits on the curved
        // corners reach their parent instead of turning into tab or button clicks.
        sealed class ResizeHitWindow : NativeWindow, IDisposable
        {
            readonly LauncherForm owner;
            readonly Control control;
            IntPtr procedure;
            bool detached;
            public ResizeHitWindow(LauncherForm owner, Control control)
            {
                this.owner = owner; this.control = control;
                control.HandleCreated += HandleCreated;
                control.ControlAdded += owner.RoundedControlAdded;
                if (control.IsHandleCreated) Attach();
            }
            void Attach() { AssignHandle(control.Handle); procedure = WindowHooks.Procedure(Handle); }
            // The hook lets go of a destroyed window by itself (see WindowHooks). One it still holds when the control
            // gets a new window went without telling it.
            void HandleCreated(object sender, EventArgs e)
            {
                if (Handle != IntPtr.Zero && Handle != control.Handle) ReleaseHandle();
                if (Handle == IntPtr.Zero) Attach();
            }
            protected override void WndProc(ref Message message)
            {
                if (!detached && message.Msg == 0x0084 && owner.Enabled && !owner.IsDisposed) {
                    int hit = owner.ResizeHitTest(HitTestPoint(message.LParam));
                    if (hit >= 10 && hit <= 17) { message.Result = new IntPtr(-1); return; } // HTTRANSPARENT, same UI thread.
                }
                base.WndProc(ref message);
            }
            public void Dispose()
            {
                detached = true;
                control.HandleCreated -= HandleCreated;
                control.ControlAdded -= owner.RoundedControlAdded;
                WindowHooks.LetGo(this, procedure);
            }
        }
    }

    // WinForms takes a NativeWindow off a window by putting back the window procedure it replaced. When another subclass
    // came after it, such as the one a ToolTip adds to each control it explains, that cannot be done, and WinForms gives
    // the window DefWindowProc instead: everything beneath is cut out, the control's own procedure too. The control never
    // hears that its window is destroyed, and later tries to destroy it again, which fails as a call from another thread.
    // So a hook lets go of a live window only while it is still the window's outermost procedure. Otherwise it stays and
    // passes everything on, and NativeWindow lets go by itself as the window is destroyed (WM_NCDESTROY), after the
    // procedures beneath it have seen that message.
    static class WindowHooks
    {
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr64(IntPtr window, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern IntPtr GetWindowLong32(IntPtr window, int index);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
        // The window's outermost procedure (GWLP_WNDPROC); a hook reads it just after taking the window.
        internal static IntPtr Procedure(IntPtr window) { return IntPtr.Size == 8 ? GetWindowLongPtr64(window, -4) : GetWindowLong32(window, -4); }
        internal static void LetGo(NativeWindow hook, IntPtr procedure)
        {
            IntPtr window = hook.Handle;
            // A window that is already gone has no chain left to cut.
            if (window != IntPtr.Zero && (!IsWindow(window) || Procedure(window) == procedure)) hook.ReleaseHandle();
        }
    }
}
