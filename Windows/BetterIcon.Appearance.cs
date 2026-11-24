using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BetterIcon.Tray
{
    // ComboBox's Framework preferred size omits owner-drawn item height.
    // TableLayoutPanel must reserve the same height that the native control uses.
    public class AppearanceComboBox : ComboBox
    {
        public AppearanceComboBox() { DrawMode = DrawMode.OwnerDrawFixed; FlatStyle = FlatStyle.Flat; ItemHeight = 24; }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); ItemHeight = Math.Max(24, Font.Height + 6); }
        public override Size GetPreferredSize(Size proposedSize)
        {
            Size size = base.GetPreferredSize(proposedSize);
            if (DrawMode != DrawMode.Normal) size.Height = Math.Max(size.Height, Math.Max(Height, ItemHeight + 8));
            return size;
        }
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct PaintInfo
        {
            public IntPtr Device; public int Erase; public Rect Area; public int Restore, Update;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Reserved;
        }
        [DllImport("user32.dll")] static extern IntPtr BeginPaint(IntPtr window, out PaintInfo paint);
        [DllImport("user32.dll")] static extern bool EndPaint(IntPtr window, ref PaintInfo paint);
        [DllImport("gdi32.dll")] static extern int SelectClipRgn(IntPtr device, IntPtr region);
        // A flat list reaches the screen in steps: its background, Windows' own list, WinForms' light gray dropdown button,
        // and only then the themed button over that. Each step showed for a moment on every repaint, and Windows repaints a
        // list several times as the pointer moves onto or off it. So a list that drops down paints the steps into a buffer,
        // and the finished picture goes to the screen once.
        // For the appearance checks: while set, a list keeps a copy of the last picture it sent to the screen.
        internal static bool KeepsPictures { get; set; }
        internal Bitmap Picture { get; private set; }
        protected override void Dispose(bool disposing) { if (disposing && Picture != null) { Picture.Dispose(); Picture = null; } base.Dispose(disposing); }
        bool PaintsBuffered
        {
            get { return FlatStyle == FlatStyle.Flat && DropDownStyle == ComboBoxStyle.DropDownList && !GetStyle(ControlStyles.UserPaint) && ClientSize.Width > 0 && ClientSize.Height > 0; }
        }
        protected override void WndProc(ref Message message)
        {
            // WM_ERASEBKGND: the buffer starts from the background color, so nothing is erased on the screen.
            if (message.Msg == 0x0014 && PaintsBuffered) { message.Result = (IntPtr)1; return; }
            if (message.Msg == 0x000F && message.WParam == IntPtr.Zero && PaintsBuffered) { PaintBuffered(ref message); return; }
            bool paint = message.Msg == 0x000F; // WM_PAINT
            // WM_PRINTCLIENT, or WM_PRINT requesting PRF_CLIENT, provides its own DC, as does a WM_PAINT with one in wParam.
            bool print = (message.Msg == 0x0318 || (message.Msg == 0x0317 && (message.LParam.ToInt64() & 4) != 0) || paint) && message.WParam != IntPtr.Zero;
            base.WndProc(ref message);
            // Keep native input and dropdown painting; add only the themed outline and dropdown button.
            if (paint || print) AppAppearance.DrawComboBorder(this, print ? message.WParam : IntPtr.Zero);
        }
        void PaintBuffered(ref Message message)
        {
            Rectangle area = new Rectangle(Point.Empty, ClientSize);
            using (Graphics screen = Graphics.FromHwnd(Handle))
            using (BufferedGraphics buffer = BufferedGraphicsManager.Current.Allocate(screen, area)) {
                buffer.Graphics.Clear(BackColor);
                IntPtr device = buffer.Graphics.GetHdc();
                try {
                    // Given a device in wParam, WinForms and Windows paint the part that needs painting into it, clipped to
                    // that part, and leave the window's update region as it is.
                    Message inner = Message.Create(message.HWnd, message.Msg, device, message.LParam);
                    base.WndProc(ref inner);
                    SelectClipRgn(device, IntPtr.Zero);
                    AppAppearance.DrawComboBorder(this, device);
                }
                finally { buffer.Graphics.ReleaseHdc(device); }
                if (KeepsPictures) {
                    if (Picture != null) Picture.Dispose();
                    Picture = new Bitmap(area.Width, area.Height);
                    using (Graphics copy = Graphics.FromImage(Picture)) buffer.Render(copy);
                }
                // BeginPaint clips to the update region, so only the part that needed painting changes on the screen.
                PaintInfo paint; IntPtr target = BeginPaint(Handle, out paint);
                try { if (target != IntPtr.Zero) buffer.Render(target); }
                finally { EndPaint(Handle, ref paint); }
            }
            message.Result = IntPtr.Zero;
        }
    }
    // Windows draws the slider's channel light gray in every theme. This slider draws its channel in the theme's colors
    // through the native custom-draw notification, and leaves the thumb, focus and input to Windows.
    public sealed class ThemedTrackBar : TrackBar
    {
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct NotifyHeader { public IntPtr Window, Id; public int Code; }
        [StructLayout(LayoutKind.Sequential)] struct CustomDraw { public NotifyHeader Header; public int Stage; public IntPtr Device; public Rect Bounds; public IntPtr Item; public int State; public IntPtr Data; }
        [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr SendRect(IntPtr window, int message, IntPtr wParam, ref Rect rect);
        [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr window, ref Rect area, bool erase);
        bool thumbHot;
        Rectangle ThumbBounds() { Rect thumb = new Rect(); SendRect(Handle, 0x0419, IntPtr.Zero, ref thumb); return Rectangle.FromLTRB(thumb.Left, thumb.Top, thumb.Right, thumb.Bottom); } // TBM_GETTHUMBRECT
        // Repaints the thumb in its new color: only the thumb, and without erasing. Erasing first fills the whole slider
        // with Windows' light gray, which showed for a moment each time the pointer crossed the thumb's edge.
        void RepaintThumb()
        {
            if (!IsHandleCreated) return;
            Rectangle thumb = Rectangle.Inflate(ThumbBounds(), 2, 2);
            Rect area = new Rect { Left = thumb.Left, Top = thumb.Top, Right = thumb.Right, Bottom = thumb.Bottom };
            InvalidateRect(Handle, ref area, false);
        }
        // The thumb lightens under the pointer, which Windows does not report to custom drawing reliably.
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            bool hot = IsHandleCreated && ThumbBounds().Contains(e.Location);
            if (hot != thumbHot) { thumbHot = hot; RepaintThumb(); }
        }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (thumbHot) { thumbHot = false; RepaintThumb(); } }
        protected override void OnMouseCaptureChanged(EventArgs e) { base.OnMouseCaptureChanged(e); RepaintThumb(); }
        protected override void WndProc(ref Message message)
        {
            // The parent reflects WM_NOTIFY back to the slider as WM_REFLECT + WM_NOTIFY. NM_CUSTOMDRAW is code -12.
            if (message.Msg == 0x204E && message.LParam != IntPtr.Zero) {
                CustomDraw draw = (CustomDraw)Marshal.PtrToStructure(message.LParam, typeof(CustomDraw));
                if (draw.Header.Window == Handle && draw.Header.Code == -12) {
                    // CDDS_PREPAINT: ask to be told about each part (CDRF_NOTIFYITEMDRAW).
                    if (draw.Stage == 0x0001) { message.Result = (IntPtr)0x20; return; }
                    if (draw.Stage == 0x10001) {
                        Rectangle bounds = Rectangle.FromLTRB(draw.Bounds.Left, draw.Bounds.Top, draw.Bounds.Right, draw.Bounds.Bottom);
                        // CDDS_ITEMPREPAINT for the channel (TBCD_CHANNEL): draw it and skip Windows' own (CDRF_SKIPDEFAULT).
                        if (draw.Item.ToInt64() == 3) {
                            Rectangle thumb = ThumbBounds();
                            int split = Orientation == Orientation.Horizontal ? (thumb.Left + thumb.Right) / 2 : (thumb.Top + thumb.Bottom) / 2;
                            if (AppAppearance.DrawSliderChannel(this, draw.Device, bounds, split)) { message.Result = (IntPtr)0x04; return; }
                        }
                        // The thumb (TBCD_THUMB): the accent, pressed while the slider holds the mouse (CDIS_SELECTED or capture).
                        if (draw.Item.ToInt64() == 2) {
                            bool pressed = Capture || (draw.State & 0x01) != 0, hot = thumbHot || (draw.State & 0x40) != 0;
                            if (AppAppearance.DrawSliderThumb(this, draw.Device, bounds, hot, pressed)) { message.Result = (IntPtr)0x04; return; }
                        }
                    }
                    message.Result = IntPtr.Zero; return; // CDRF_DODEFAULT
                }
            }
            base.WndProc(ref message);
        }
    }
    // A progress bar in the theme's colors: the button's gray track and an accent chunk. Windows' marquee cannot be
    // colored, so the bar runs one of its own while it is told to animate (PBM_SETMARQUEE).
    public sealed class ThemedProgressBar : ProgressBar
    {
        readonly Timer timer = new Timer { Interval = 30 };
        int offset; bool running;
        public ThemedProgressBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            timer.Tick += delegate { offset += Math.Max(2, Width / 90); if (offset > Width + Width / 4) offset = 0; Invalidate(); };
        }
        public bool MarqueeRunning { get { return running; } }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x040A) { running = m.WParam != IntPtr.Zero; offset = 0; if (running) timer.Start(); else timer.Stop(); Invalidate(); }
            base.WndProc(ref m);
        }
        protected override void OnPaint(PaintEventArgs e) { AppAppearance.DrawProgress(this, e.Graphics, running, offset); }
        protected override void Dispose(bool disposing) { if (disposing) timer.Dispose(); base.Dispose(disposing); }
    }
    // Draws a text box's, list's or table's border in the theme's border color, in place of Windows' own frame on screen
    // and over it when the window is printed.
    sealed class FrameBorder : NativeWindow
    {
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect area);
        [DllImport("user32.dll")] static extern bool ValidateRect(IntPtr window, ref Rect area);
        [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left, int top, int right, int bottom);
        [DllImport("gdi32.dll")] static extern int CombineRgn(IntPtr result, IntPtr first, IntPtr second, int mode);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr handle);
        readonly Control control;
        internal FrameBorder(Control control) { this.control = control; AssignHandle(control.Handle); }
        protected override void WndProc(ref Message m)
        {
            // Windows draws its own frame, in its own color and another under the pointer, and the themed frame went over
            // it afterwards: both showed in turn each time the frame repainted. So Windows is given everything but the frame
            // to paint, and the themed frame is the only one that reaches the screen.
            if (m.Msg == 0x0085) { // WM_NCPAINT: wParam is the region to paint, in screen coordinates, or 1 for all of it.
                int edge = AppAppearance.FrameEdge(control, Handle); Rect outer;
                if (edge > 0 && GetWindowRect(Handle, out outer)) {
                    IntPtr inside = CreateRectRgn(outer.Left + edge, outer.Top + edge, outer.Right - edge, outer.Bottom - edge);
                    try {
                        long region = m.WParam.ToInt64(); // A region's handle may have its high bit set, so it is not compared as a number.
                        if (region != 0 && region != 1) CombineRgn(inside, inside, m.WParam, 1); // RGN_AND
                        Message within = Message.Create(m.HWnd, m.Msg, inside, m.LParam);
                        base.WndProc(ref within); m.Result = within.Result;
                    }
                    finally { DeleteObject(inside); }
                    if (Handle != IntPtr.Zero) AppAppearance.DrawFrame(control, Handle, IntPtr.Zero);
                    return;
                }
            }
            // A single-line text box with a single border draws that border inside its own client area. Its four lines
            // are taken out of what Windows paints, and drawn in the theme's color below.
            else if (m.Msg == 0x000F && m.WParam == IntPtr.Zero && AppAppearance.OwnsClientBorder(control)) {
                int width = control.Width, height = control.Height;
                foreach (Rect line in new[] { new Rect { Right = width, Bottom = 1 }, new Rect { Top = height - 1, Right = width, Bottom = height },
                    new Rect { Right = 1, Bottom = height }, new Rect { Left = width - 1, Right = width, Bottom = height } }) {
                    Rect strip = line; ValidateRect(Handle, ref strip);
                }
            }
            base.WndProc(ref m);
            if (Handle == IntPtr.Zero) return;
            if (m.Msg == 0x0085) AppAppearance.DrawFrame(control, Handle, IntPtr.Zero); // WM_NCPAINT
            else if (m.Msg == 0x0317 && (m.LParam.ToInt64() & 0x2) != 0) AppAppearance.DrawFrame(control, Handle, m.WParam); // WM_PRINT with PRF_NONCLIENT
            // A single-line text box with a single border draws that border inside its own client area.
            else if (m.Msg == 0x000F) AppAppearance.DrawClientBorder(control, Handle, IntPtr.Zero); // WM_PAINT
            else if (m.Msg == 0x0318) AppAppearance.DrawClientBorder(control, Handle, m.WParam);    // WM_PRINTCLIENT
        }
    }
    // Windows draws scroll bars in its own grays and cannot color them. A ScrollSkin lays a window exactly over each scroll
    // bar of a window (a list, a list's dropdown, a scrolling panel, or a table's scroll bar control) and draws the bar there
    // in the theme's colors, from the bar's own state: the thumb's place and size, its arrows, hover and press. The skin
    // lets the mouse through, so the real bar beneath still does all the scrolling, and screen readers still find it.
    // High contrast shows Windows' bars.
    public sealed class ScrollSkin : NativeWindow
    {
        internal const int Vertical = -5, Horizontal = -6, Client = -4; // OBJID_VSCROLL, OBJID_HSCROLL, OBJID_CLIENT
        const int Invisible = 0x8000, Unavailable = 0x1, Pressed = 0x8; // STATE_SYSTEM_*
        [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] internal struct BarInfo
        {
            public int Size; public Rect Bar; public int Button, ThumbTop, ThumbBottom, Reserved;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)] public int[] States;
        }
        [StructLayout(LayoutKind.Sequential)] struct Tracking { public int Size, Flags; public IntPtr Window; public int HoverTime; }
        [StructLayout(LayoutKind.Sequential)] struct PaintInfo
        {
            public IntPtr Device; public int Erase; public Rect Area; public int Restore, Update;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] Reserved;
        }
        [DllImport("user32.dll")] static extern bool GetScrollBarInfo(IntPtr window, int id, ref BarInfo info);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, int flags);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr from, IntPtr to, ref Point point, int count);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, int flags);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr window, IntPtr area, bool erase);
        [DllImport("user32.dll")] static extern bool UpdateWindow(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr BeginPaint(IntPtr window, out PaintInfo paint);
        [DllImport("user32.dll")] static extern bool EndPaint(IntPtr window, ref PaintInfo paint);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out Rect area);
        [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr window, int key, byte alpha, int flags);
        [DllImport("user32.dll")] static extern bool TrackMouseEvent(ref Tracking tracking);
        [DllImport("user32.dll")] static extern IntPtr GetCapture();
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        readonly bool barControl, barVertical;
        readonly Overlay[] overlays = new Overlay[3]; // the vertical bar, the horizontal bar, and the square where they meet
        int hotBar, hotPart;
        internal AppearancePalette Palette;
        // The skins of this thread's windows. A bar can change without a message to its window: when a scrolling panel's
        // page grows or is scrolled by the program, WinForms gives the bar its new range and place (SetScrollInfo) and
        // Windows redraws the real bar itself, under the skin. So every skin is also brought up to date each time the
        // thread runs out of messages.
        [ThreadStatic] static List<ScrollSkin> live;
        internal ScrollSkin(IntPtr target, bool barControl, bool barVertical)
        {
            this.barControl = barControl; this.barVertical = barVertical; AssignHandle(target);
            if (live == null) live = new List<ScrollSkin>();
            // WinForms keeps Idle handlers with the thread's message loop and drops them when Application.Run returns,
            // so each new skin asks again; taking the handler off first leaves exactly one.
            Application.Idle -= WhenIdle; Application.Idle += WhenIdle;
            live.Add(this);
        }
        static void WhenIdle(object sender, EventArgs e) { SyncAll(); }
        internal static void SyncAll()
        {
            if (live == null) return;
            live.RemoveAll(skin => skin.Handle == IntPtr.Zero);
            foreach (ScrollSkin skin in live.ToArray()) skin.Sync();
        }
        static BarInfo Info(IntPtr window, int id)
        {
            BarInfo info = new BarInfo { States = new int[6] };
            info.Size = Marshal.SizeOf(typeof(BarInfo));
            if (!GetScrollBarInfo(window, id, ref info)) { info.States = new int[6]; info.States[0] = Invisible; }
            return info;
        }
        // A bar clipped by a scrolling parent still counts: its skin is clipped the same way.
        static bool Shown(BarInfo info) { return (info.States[0] & Invisible) == 0 && info.Bar.Right > info.Bar.Left && info.Bar.Bottom > info.Bar.Top; }
        // The skin windows of this target, for tests: each one's bounds on the screen, or empty while it is hidden.
        public Rectangle[] SkinBounds()
        {
            Rectangle[] bounds = new Rectangle[overlays.Length];
            for (int i = 0; i < overlays.Length; i++) bounds[i] = overlays[i] == null ? Rectangle.Empty : overlays[i].ScreenBounds();
            return bounds;
        }
        public IntPtr[] SkinHandles() { return overlays.Select(overlay => overlay == null ? IntPtr.Zero : overlay.Handle).ToArray(); }
        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            switch (m.Msg) {
                case 0x0082: // WM_NCDESTROY: the window is going; its skins go with it.
                    foreach (Overlay overlay in overlays) if (overlay != null) overlay.DestroyHandle();
                    if (live != null) live.Remove(this);
                    return;
                case 0x00A0: case 0x0200: Hover(m.Msg == 0x00A0); break; // WM_NCMOUSEMOVE, WM_MOUSEMOVE
                case 0x02A2: case 0x02A3: hotBar = hotPart = 0; break;   // WM_NCMOUSELEAVE, WM_MOUSELEAVE
                // Painting, scrolling, size, visibility, keys, the mouse letting go, and a scroll bar control's or list's own updates.
                case 0x000F: case 0x0085: case 0x0114: case 0x0115: case 0x020A: case 0x020E: case 0x0005: case 0x0047: case 0x0018:
                case 0x0100: case 0x0101: case 0x0202: case 0x00A2: case 0x0215: case 0x000A: case 0x007D: case 0x0113:
                case 0x2114: case 0x2115: case 0x00E0: case 0x00E2: case 0x00E6: case 0x00E9: case 0x0186: case 0x0197: case 0x1013: case 0x1014: case 0x1016:
                    break;
                default: return;
            }
            if (Handle != IntPtr.Zero) Sync();
        }
        void Hover(bool nonclient)
        {
            Point at = Cursor.Position; int bar = 0, part = 0;
            foreach (int id in barControl ? new[] { Client } : new[] { Vertical, Horizontal }) {
                BarInfo info = Info(Handle, id);
                Rectangle area = Rectangle.FromLTRB(info.Bar.Left, info.Bar.Top, info.Bar.Right, info.Bar.Bottom);
                if (!Shown(info) || !area.Contains(at)) continue;
                bool vertical = id == Vertical || (id == Client && barVertical);
                int along = vertical ? at.Y - area.Top : at.X - area.Left, length = vertical ? area.Height : area.Width;
                bar = id; part = along < info.Button ? 1 : along < info.ThumbTop ? 2 : along < info.ThumbBottom ? 3 : along < length - info.Button ? 4 : 5;
            }
            // Hear when the pointer leaves the bar, unless the window holds the mouse, as an open dropdown does.
            if (bar != 0 && hotBar == 0 && GetCapture() != Handle) {
                Tracking tracking = new Tracking { Size = Marshal.SizeOf(typeof(Tracking)), Flags = 0x02 | (nonclient ? 0x10 : 0), Window = Handle }; // TME_LEAVE, TME_NONCLIENT
                TrackMouseEvent(ref tracking);
            }
            hotBar = bar; hotPart = part;
        }
        // Lays each skin over its bar, or hides it, and redraws it when the bar has changed.
        internal void Sync()
        {
            if (Handle == IntPtr.Zero) return;
            bool active = Palette != null && !Palette.HighContrast && IsWindowVisible(Handle);
            if (barControl) { Place(0, Client, active); return; }
            Rectangle down = Place(0, Vertical, active), across = Place(1, Horizontal, active);
            if (!down.IsEmpty && !across.IsEmpty) Slot(2, 0).Update(Handle, Rectangle.FromLTRB(down.Left, across.Top, down.Right, across.Bottom), new BarInfo { States = new int[6] }, 0);
            else if (overlays[2] != null) overlays[2].Hide();
        }
        Overlay Slot(int slot, int id) { return overlays[slot] ?? (overlays[slot] = new Overlay(this, id)); }
        Rectangle Place(int slot, int id, bool active)
        {
            // A window that is hidden, or left to Windows, is not asked about its bars.
            BarInfo info = active ? Info(Handle, id) : new BarInfo();
            if (!active || !Shown(info)) { if (overlays[slot] != null) overlays[slot].Hide(); return Rectangle.Empty; }
            Rectangle screen = Rectangle.FromLTRB(info.Bar.Left, info.Bar.Top, info.Bar.Right, info.Bar.Bottom);
            Slot(slot, id).Update(Handle, screen, info, hotBar == id ? hotPart : 0);
            return screen;
        }
        internal static GraphicsPath Rounded(RectangleF area, float radius)
        {
            GraphicsPath path = new GraphicsPath(); float d = Math.Min(radius * 2, Math.Min(area.Width, area.Height));
            if (d <= 0.5f) { path.AddRectangle(area); return path; }
            path.AddArc(area.X, area.Y, d, d, 180, 90); path.AddArc(area.Right - d, area.Y, d, d, 270, 90);
            path.AddArc(area.Right - d, area.Bottom - d, d, d, 0, 90); path.AddArc(area.X, area.Bottom - d, d, d, 90, 90);
            path.CloseFigure(); return path;
        }
        // The track in the input color; the thumb rounded, thin until the pointer is on the bar; arrows while it is.
        void Draw(Overlay overlay, Graphics canvas, Size size)
        {
            AppearancePalette p = Palette; if (p == null) return;
            using (Brush track = new SolidBrush(p.ScrollTrack)) canvas.FillRectangle(track, 0, 0, size.Width, size.Height);
            BarInfo info = overlay.Info;
            if (overlay.Id == 0 || (info.States[0] & Unavailable) != 0) return;
            bool vertical = overlay.Id == Vertical || (overlay.Id == Client && barVertical);
            int thickness = vertical ? size.Width : size.Height, length = vertical ? size.Height : size.Width, hot = overlay.HotPart;
            canvas.SmoothingMode = SmoothingMode.AntiAlias;
            Func<int, Color> tone = part => (info.States[part] & Pressed) != 0 ? p.ScrollThumbPressed : hot == part ? p.ScrollThumbHot : p.ScrollThumb;
            if (hot != 0 && info.Button > 0) {
                Arrow(canvas, vertical ? new RectangleF(0, 0, thickness, info.Button) : new RectangleF(0, 0, info.Button, thickness), vertical, true, tone(1));
                Arrow(canvas, vertical ? new RectangleF(0, length - info.Button, thickness, info.Button) : new RectangleF(length - info.Button, 0, info.Button, thickness), vertical, false, tone(5));
            }
            if (info.ThumbBottom - info.ThumbTop < 4) return;
            float width = hot != 0 ? Math.Max(4, thickness / 2) : Math.Max(3, thickness / 4);
            RectangleF thumb = vertical ? new RectangleF((thickness - width) / 2f, info.ThumbTop + 1, width, info.ThumbBottom - info.ThumbTop - 2)
                : new RectangleF(info.ThumbTop + 1, (thickness - width) / 2f, info.ThumbBottom - info.ThumbTop - 2, width);
            using (Brush brush = new SolidBrush(tone(3))) using (GraphicsPath shape = Rounded(thumb, width / 2f)) canvas.FillPath(brush, shape);
        }
        static void Arrow(Graphics canvas, RectangleF area, bool vertical, bool first, Color color)
        {
            float s = Math.Max(2.5f, Math.Min(area.Width, area.Height) / 5f), x = area.X + area.Width / 2f, y = area.Y + area.Height / 2f;
            PointF[] points = vertical
                ? (first ? new[] { new PointF(x - s, y + s / 2), new PointF(x + s, y + s / 2), new PointF(x, y - s / 2) } : new[] { new PointF(x - s, y - s / 2), new PointF(x + s, y - s / 2), new PointF(x, y + s / 2) })
                : (first ? new[] { new PointF(x + s / 2, y - s), new PointF(x + s / 2, y + s), new PointF(x - s / 2, y) } : new[] { new PointF(x - s / 2, y - s), new PointF(x - s / 2, y + s), new PointF(x + s / 2, y) });
            using (Brush brush = new SolidBrush(color)) canvas.FillPolygon(brush, points);
        }
        // One skin window. Over a bar inside a window it is a child of that window's parent, kept above its siblings; over a
        // dropdown's bar it is a click-through popup owned by the dropdown.
        sealed class Overlay : NativeWindow
        {
            readonly ScrollSkin skin; internal readonly int Id; internal BarInfo Info; internal int HotPart;
            IntPtr parent; bool popup, shown; Rectangle placed; string painted;
            internal Overlay(ScrollSkin skin, int id) { this.skin = skin; Id = id; Info = new BarInfo { States = new int[6] }; }
            internal Rectangle ScreenBounds()
            {
                if (!shown || Handle == IntPtr.Zero) return Rectangle.Empty;
                Point origin = placed.Location;
                if (!popup) MapWindowPoints(parent, IntPtr.Zero, ref origin, 1);
                return new Rectangle(origin, placed.Size);
            }
            internal void Update(IntPtr target, Rectangle screen, BarInfo info, int hot)
            {
                if (Handle == IntPtr.Zero) Create(target);
                if (Handle == IntPtr.Zero) return;
                Rectangle at = screen;
                if (!popup) { Point origin = screen.Location; MapWindowPoints(IntPtr.Zero, parent, ref origin, 1); at.Location = origin; }
                // A dropdown comes back topmost each time it opens, so a popup skin is checked the same way.
                bool top = Above(target);
                if (!shown || at != placed || !top)
                    SetWindowPos(Handle, popup ? new IntPtr(-1) : IntPtr.Zero, at.X, at.Y, at.Width, at.Height, 0x0010 | 0x0040 | 0x0200); // NOACTIVATE, SHOWWINDOW, NOOWNERZORDER
                shown = true; placed = at; Info = info; HotPart = hot;
                string state = at.Width + "x" + at.Height + " " + info.Button + " " + info.ThumbTop + " " + info.ThumbBottom + " " + String.Join(",", info.States) + " " + hot + " " + skin.Palette.GetHashCode();
                if (state != painted) { painted = state; InvalidateRect(Handle, IntPtr.Zero, false); UpdateWindow(Handle); }
            }
            internal void Hide() { if (shown && Handle != IntPtr.Zero) ShowWindow(Handle, 0); shown = false; painted = null; }
            // True when this skin lies above the window it covers among their siblings (GW_HWNDNEXT walks down).
            bool Above(IntPtr target)
            {
                for (IntPtr window = GetWindow(Handle, 2); window != IntPtr.Zero; window = GetWindow(window, 2)) if (window == target) return true;
                return false;
            }
            void Create(IntPtr target)
            {
                // A dropdown is a child of the desktop, or a popup; its skin is a popup it owns, so it stays above it.
                IntPtr up = GetAncestor(target, 1); // GA_PARENT
                popup = (GetWindowLong(target, -16) & 0x40000000) == 0 || up == GetDesktopWindow();
                parent = popup ? target : up;
                if (parent == IntPtr.Zero) return;
                CreateParams cp = new CreateParams { Parent = parent, Width = 1, Height = 1 };
                if (popup) { cp.Style = unchecked((int)0x80000000); cp.ExStyle = 0x80 | 0x08000000 | 0x08 | 0x80000 | 0x20; } // WS_POPUP; TOOLWINDOW, NOACTIVATE, TOPMOST, LAYERED, TRANSPARENT
                else cp.Style = 0x40000000 | 0x04000000; // WS_CHILD | WS_CLIPSIBLINGS
                CreateHandle(cp);
                if (popup && Handle != IntPtr.Zero) SetLayeredWindowAttributes(Handle, 0, 255, 2); // LWA_ALPHA, opaque
            }
            protected override void WndProc(ref Message m)
            {
                switch (m.Msg) {
                    case 0x0084: m.Result = new IntPtr(-1); return; // WM_NCHITTEST: HTTRANSPARENT, so the real bar beneath takes the mouse
                    case 0x0021: m.Result = new IntPtr(3); return;  // WM_MOUSEACTIVATE: MA_NOACTIVATE
                    case 0x0014: m.Result = new IntPtr(1); return;  // WM_ERASEBKGND
                    case 0x000F: {
                        PaintInfo paint; IntPtr device = BeginPaint(Handle, out paint);
                        try { PaintTo(device); } finally { EndPaint(Handle, ref paint); }
                        return;
                    }
                    case 0x0318: PaintTo(m.WParam); return;           // WM_PRINTCLIENT
                }
                base.WndProc(ref m);
            }
            void PaintTo(IntPtr device)
            {
                Rect area; GetClientRect(Handle, out area);
                Size size = new Size(area.Right - area.Left, area.Bottom - area.Top);
                if (device == IntPtr.Zero || size.Width <= 0 || size.Height <= 0) return;
                using (BufferedGraphics buffer = BufferedGraphicsManager.Current.Allocate(device, new Rectangle(Point.Empty, size))) {
                    skin.Draw(this, buffer.Graphics, size);
                    buffer.Render(device);
                }
            }
        }
    }
    public static class AppBranding
    {
        public static readonly string[] Styles = { "clay", "copper", "mauve", "ochre", "sage", "slate", "stone", "teal", "grayscale", "contrast" };
        static readonly Dictionary<string, Color[]> tones = new Dictionary<string, Color[]>();
        // Each icon is drawn in two tones. Returns the darker one, then the lighter one.
        public static Color[] Tones(string style, string variant)
        {
            string key = style + "." + variant;
            lock (tones) {
                Color[] known;
                if (tones.TryGetValue(key, out known)) return known;
                using (Bitmap image = Preview(style, variant, 64)) {
                    Func<Color, double> luma = pixel => 0.299 * pixel.R + 0.587 * pixel.G + 0.114 * pixel.B;
                    List<Color> solid = new List<Color>();
                    for (int y = 0; y < image.Height; y++) for (int x = 0; x < image.Width; x++) { Color pixel = image.GetPixel(x, y); if (pixel.A >= 250) solid.Add(pixel); }
                    if (solid.Count == 0) throw new IOException("The BetterIcon app icon has no artwork.");
                    double middle = (solid.Min(luma) + solid.Max(luma)) / 2;
                    Func<IEnumerable<Color>, Color> mean = part => {
                        Color[] pixels = part.ToArray();
                        return pixels.Length == 0 ? solid[0] : Color.FromArgb((int)Math.Round(pixels.Average(p => (double)p.R)), (int)Math.Round(pixels.Average(p => (double)p.G)), (int)Math.Round(pixels.Average(p => (double)p.B)));
                    };
                    known = new[] { mean(solid.Where(pixel => luma(pixel) < middle)), mean(solid.Where(pixel => luma(pixel) >= middle)) };
                }
                tones[key] = known;
                return known;
            }
        }
        public static string Variant(string preference, bool dark) { return preference == "Dark" ? "dark" : preference == "Light" ? "light" : dark ? "dark" : "light"; }
        public static string ResourceName(string style, string variant) { return "BetterIcon.AppIcons." + style + "." + variant + ".ico"; }
        public static Icon Load(string style, string variant, int size = 256)
        {
            if (!Styles.Contains(style) || (variant != "dark" && variant != "light")) throw new ArgumentException("Unknown BetterIcon app icon.");
            using (Stream stream = typeof(AppBranding).Assembly.GetManifestResourceStream(ResourceName(style, variant))) {
                if (stream == null) throw new IOException("The BetterIcon app icon resource is missing.");
                using (Icon icon = new Icon(stream, size, size)) return (Icon)icon.Clone();
            }
        }
        public static Bitmap Preview(string style, string variant, int size)
        {
            Bitmap output = new Bitmap(size, size);
            using (Icon icon = Load(style, variant, size)) using (Graphics canvas = Graphics.FromImage(output)) {
                canvas.Clear(Color.Transparent); canvas.DrawIcon(icon, new Rectangle(0, 0, size, size));
            }
            return output;
        }
        public static string Title(string style) { return style == "contrast" ? "High contrast" : Char.ToUpperInvariant(style[0]) + style.Substring(1); }
    }

    public sealed class AppearancePalette
    {
        public bool Dark, HighContrast;
        public Color Background, Surface, Input, Text, Muted, Border, Accent, Selection, SelectionText, InactiveTab, Error;
        // A primary action's label, and how it and an ordinary button look under the pointer and while pressed.
        public Color AccentText, AccentHover, AccentPressed, Pressed;
        // Parts Windows draws light gray in every theme: a list's dropdown button (its face, the line beside the
        // list's text, its outline and its arrow) and the slider's channel (its face, and its edges before and after the thumb).
        public Color ControlFace, ControlLight, ControlOutline, ControlGlyph, ChannelEdgeBefore, ChannelEdge;
        // The theme's own scroll bars: the track, and the thumb at rest, under the pointer and while it is dragged.
        public Color ScrollTrack, ScrollThumb, ScrollThumbHot, ScrollThumbPressed;
    }

    public static class AppAppearance
    {
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr window, string application, string idList);
        [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct ComboInfo { public int Size; public Rect Item, Button; public int ButtonState; public IntPtr Combo, Edit, List; }
        [DllImport("user32.dll")] static extern bool GetComboBoxInfo(IntPtr combo, ref ComboInfo info);
        [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr window, IntPtr update, IntPtr region, uint flags);
        // A control's palette, its pointer state where BetterIcon draws it (a check box), and the windows that draw its scroll bars and border.
        sealed class Hook
        {
            public AppearancePalette Palette; public bool Hot, Pressed, GridLines; public ScrollSkin Skin; public FrameBorder Border;
            // A table's button cells (column, row): the one under the pointer, the one the mouse went down on, and the one Space holds down.
            public Point HotCell = NoCell, DownCell = NoCell, KeyCell = NoCell;
        }
        static readonly Point NoCell = new Point(-1, -1);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")] static extern IntPtr GetWindowDC(IntPtr window);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr window, IntPtr device);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect area);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        static readonly ConditionalWeakTable<Control, Hook> hooks = new ConditionalWeakTable<Control, Hook>();
        // Control.DoubleBuffered is protected. A list takes it as Windows' own double buffering (LVS_EX_DOUBLEBUFFER), a
        // table as WinForms' buffered painting.
        static readonly System.Reflection.PropertyInfo doubleBuffered = typeof(Control).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        static void Buffer(Control control) { if (doubleBuffered != null) doubleBuffered.SetValue(control, true, null); }
        public static bool SystemIsDark()
        {
            try { using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) return key != null && Convert.ToInt32(key.GetValue("AppsUseLightTheme", 1)) == 0; }
            catch (System.Security.SecurityException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (IOException) { return false; }
        }
        static readonly Dictionary<string, AppearancePalette> schemes = new Dictionary<string, AppearancePalette>();
        // WCAG relative luminance and contrast ratio.
        public static double Luminance(Color color)
        {
            Func<int, double> linear = value => { double v = value / 255.0; return v <= 0.03928 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4); };
            return 0.2126 * linear(color.R) + 0.7152 * linear(color.G) + 0.0722 * linear(color.B);
        }
        public static double Contrast(Color first, Color second)
        {
            double a = Luminance(first), b = Luminance(second);
            return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05);
        }
        static Color Mix(Color from, Color to, double amount)
        {
            return Color.FromArgb((int)Math.Round(from.R + (to.R - from.R) * amount), (int)Math.Round(from.G + (to.G - from.G) * amount), (int)Math.Round(from.B + (to.B - from.B) * amount));
        }
        // Move a color toward white or black, only as far as it needs to read on every background.
        static Color Readable(Color color, double ratio, params Color[] backgrounds)
        {
            Color target = backgrounds.Min(back => Contrast(Color.White, back)) >= backgrounds.Min(back => Contrast(Color.Black, back)) ? Color.White : Color.Black;
            for (int step = 0; step <= 20; step++) {
                Color candidate = Mix(color, target, step / 20.0);
                if (backgrounds.All(back => Contrast(candidate, back) >= ratio)) return candidate;
            }
            return target;
        }
        // The app takes its colors from the chosen app icon: the icon's dark tone is the
        // dark theme's background and its light tone the light theme's.
        static AppearancePalette Scheme(string style, bool dark)
        {
            string key = style + (dark ? ".dark" : ".light");
            lock (schemes) {
                AppearancePalette p;
                if (schemes.TryGetValue(key, out p)) return p;
                Color[] tones = AppBranding.Tones(style, dark ? "dark" : "light");
                bool strong = style == "contrast";
                Color low = strong ? Color.Black : tones[0], high = strong ? Color.White : tones[1];
                p = new AppearancePalette { Dark = dark };
                if (dark) {
                    p.Surface = low; p.Background = strong ? low : Mix(low, Color.Black, 0.18); p.Input = strong ? low : Mix(low, Color.Black, 0.12);
                    p.InactiveTab = Mix(low, high, 0.18); p.Selection = Mix(low, high, 0.28); p.Pressed = Mix(low, high, 0.40);
                    p.Border = strong ? high : Mix(low, high, 0.42);
                    p.Text = Readable(Readable(Mix(high, Color.White, 0.65), 7, p.Surface, p.Input, p.Background), 4.5, p.Selection, p.InactiveTab, p.Pressed);
                    p.Muted = strong ? p.Text : Readable(high, 4.5, p.Surface, p.Background, p.InactiveTab);
                    p.Accent = high; p.AccentHover = Mix(high, Color.White, 0.22); p.AccentPressed = Mix(high, Color.White, 0.40);
                    p.AccentText = Readable(low, 4.5, p.Accent, p.AccentHover, p.AccentPressed);
                    p.Error = Readable(Color.FromArgb(255, 161, 154), 4.5, p.Surface, p.Background);
                } else {
                    p.Surface = high; p.Background = strong ? high : Mix(high, low, 0.07); p.Input = strong ? high : Mix(high, Color.White, 0.55);
                    p.InactiveTab = Mix(high, low, 0.16); p.Selection = Mix(high, low, 0.16); p.Pressed = Mix(high, low, 0.28);
                    p.Border = strong ? low : Mix(high, low, 0.55);
                    p.Text = Readable(Readable(Mix(low, Color.Black, 0.55), 7, p.Surface, p.Input, p.Background), 4.5, p.Selection, p.InactiveTab, p.Pressed);
                    p.Muted = strong ? p.Text : Readable(Mix(low, Color.Black, 0.10), 4.5, p.Surface, p.Background, p.InactiveTab);
                    p.AccentText = Color.White;
                    p.Accent = Readable(low, 4.5, p.AccentText); p.AccentHover = Mix(p.Accent, Color.Black, 0.15); p.AccentPressed = Mix(p.Accent, Color.Black, 0.30);
                    p.Error = Readable(Color.Firebrick, 4.5, p.Surface, p.Background);
                }
                // Windows draws a list's dropdown button and the slider's channel light gray in every theme. They take the
                // background instead, lightened for Dark and darkened for Light, so they keep its tint.
                if (dark) {
                    p.ControlOutline = Mix(p.Surface, Color.White, 0.225); p.ControlFace = Mix(p.Surface, Color.White, 0.29);
                    p.ControlLight = Mix(p.Surface, Color.White, 0.33);
                    p.ChannelEdgeBefore = Mix(p.Surface, Color.White, 0.45); p.ChannelEdge = Mix(p.Surface, Color.White, 0.515);
                } else {
                    p.ControlOutline = p.Border; p.ControlFace = Mix(p.Surface, Color.Black, 0.07); p.ControlLight = p.Input;
                    p.ChannelEdgeBefore = Mix(p.Surface, Color.Black, 0.14); p.ChannelEdge = Mix(p.Surface, Color.Black, 0.17);
                }
                // The black and white scheme keeps its own border around the button and along the channel.
                if (strong) p.ControlOutline = p.ControlLight = p.ChannelEdgeBefore = p.ChannelEdge = p.Border;
                // Scroll bars run in the input color, with a thumb in the button's gray that stands out more under the pointer.
                p.ScrollTrack = strong ? p.Surface : p.Input;
                if (strong) p.ScrollThumb = p.ScrollThumbHot = p.ScrollThumbPressed = p.Border;
                else if (dark) { p.ScrollThumb = p.ControlFace; p.ScrollThumbHot = Mix(p.Surface, Color.White, 0.40); p.ScrollThumbPressed = Mix(p.Surface, Color.White, 0.50); }
                else { p.ScrollThumb = Mix(p.Surface, Color.Black, 0.30); p.ScrollThumbHot = Mix(p.Surface, Color.Black, 0.40); p.ScrollThumbPressed = Mix(p.Surface, Color.Black, 0.50); }
                // The dropdown arrow stays black, as Windows draws it, unless black is too faint on the button.
                p.ControlGlyph = Contrast(Color.Black, p.ControlFace) >= 3 ? Color.Black : p.Text;
                p.SelectionText = p.Text;
                schemes[key] = p;
                return p;
            }
        }
        public static AppearancePalette Resolve(string mode, bool? systemDark = null, bool? highContrast = null, string style = null)
        {
            bool contrast = highContrast ?? SystemInformation.HighContrast;
            bool dark = mode == "Dark" || (mode != "Light" && (systemDark ?? SystemIsDark()));
            if (contrast) return new AppearancePalette { HighContrast = true, Dark = SystemColors.Window.GetBrightness() < 0.5F,
                Background = SystemColors.Control, Surface = SystemColors.Window, Input = SystemColors.Window, Text = SystemColors.WindowText,
                Muted = SystemColors.WindowText, Border = SystemColors.WindowText, Accent = SystemColors.Highlight,
                AccentText = SystemColors.HighlightText, AccentHover = SystemColors.Highlight, AccentPressed = SystemColors.Highlight, Pressed = SystemColors.Highlight,
                Selection = SystemColors.Highlight, SelectionText = SystemColors.HighlightText, InactiveTab = SystemColors.Control, Error = SystemColors.WindowText,
                ControlFace = SystemColors.Control, ControlLight = SystemColors.Window, ControlOutline = SystemColors.WindowText, ControlGlyph = SystemColors.ControlText,
                ChannelEdgeBefore = SystemColors.ControlDark, ChannelEdge = SystemColors.ControlDark,
                ScrollTrack = SystemColors.Control, ScrollThumb = SystemColors.ControlDark, ScrollThumbHot = SystemColors.ControlDarkDark, ScrollThumbPressed = SystemColors.Highlight };
            return Scheme(AppBranding.Styles.Contains(style) ? style : "sage", dark);
        }
        public static void Apply(Control control, AppearancePalette palette)
        {
            Hook hook;
            if (!hooks.TryGetValue(control, out hook)) {
                hook = new Hook(); hooks.Add(control, hook);
                ComboBox combo = control as ComboBox;
                if (combo != null) {
                    combo.DrawItem += delegate(object sender, DrawItemEventArgs e) { DrawCombo((ComboBox)sender, e); };
                }
                // Windows draws a check box in its own accent color. Draw it over in the theme's, following the pointer.
                CheckBox box = control as CheckBox;
                if (box != null) {
                    Hook state = hook;
                    box.Paint += delegate(object sender, PaintEventArgs e) { DrawCheckBox((CheckBox)sender, e.Graphics); };
                    box.MouseEnter += delegate { state.Hot = true; box.Invalidate(); };
                    box.MouseLeave += delegate { state.Hot = state.Pressed = false; box.Invalidate(); };
                    box.MouseDown += delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) { state.Pressed = true; box.Invalidate(); } };
                    box.MouseUp += delegate { state.Pressed = false; box.Invalidate(); };
                }
                ListView list = control as ListView;
                if (list != null && !(list is IconGridView)) {
                    // Windows draws a details list's grid lines light whatever the theme, so the list draws its rows,
                    // and the lines in the theme's border color, itself. Rows drawn straight onto the screen flicker
                    // as the pointer moves over them, so the list paints through a buffer.
                    hook.GridLines = list.GridLines;
                    Buffer(list);
                    list.OwnerDraw = true;
                    list.DrawItem += delegate(object sender, DrawListViewItemEventArgs e) { e.DrawDefault = !OwnRows((ListView)sender); };
                    list.DrawSubItem += delegate(object sender, DrawListViewSubItemEventArgs e) { if (OwnRows((ListView)sender)) DrawListCell((ListView)sender, e); else e.DrawDefault = true; };
                    list.DrawColumnHeader += delegate(object sender, DrawListViewColumnHeaderEventArgs e) {
                        ListView current = (ListView)sender;
                        using (Brush brush = new SolidBrush(current.BackColor)) e.Graphics.FillRectangle(brush, e.Bounds);
                        TextRenderer.DrawText(e.Graphics, e.Header.Text, current.Font, Rectangle.Inflate(e.Bounds, -5, 0), current.ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
                        Hook own;
                        if (hooks.TryGetValue(current, out own) && own.Palette != null && !own.Palette.HighContrast)
                            using (Pen line = new Pen(own.Palette.Border)) {
                                e.Graphics.DrawLine(line, e.Bounds.Right - 1, e.Bounds.Top, e.Bounds.Right - 1, e.Bounds.Bottom - 1);
                                e.Graphics.DrawLine(line, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right - 1, e.Bounds.Bottom - 1);
                            }
                    };
                }
                // A table's button cells: Windows' flat buttons have light borders, so they are drawn in the theme's colors.
                DataGridView table = control as DataGridView;
                if (table != null) {
                    // A table repaints a button cell as the pointer enters and leaves it; through a buffer that shows once.
                    Buffer(table);
                    table.CellPainting += delegate(object sender, DataGridViewCellPaintingEventArgs e) { DrawTableButton((DataGridView)sender, e); };
                    // Windows' buttons showed the pointer over them and a press; the themed ones follow the same events.
                    Hook cells = hook;
                    table.CellMouseEnter += delegate(object sender, DataGridViewCellEventArgs e) { MarkCell((DataGridView)sender, ref cells.HotCell, new Point(e.ColumnIndex, e.RowIndex)); };
                    table.CellMouseLeave += delegate(object sender, DataGridViewCellEventArgs e) { MarkCell((DataGridView)sender, ref cells.HotCell, NoCell); };
                    table.CellMouseDown += delegate(object sender, DataGridViewCellMouseEventArgs e) { if (e.Button == MouseButtons.Left) MarkCell((DataGridView)sender, ref cells.DownCell, new Point(e.ColumnIndex, e.RowIndex)); };
                    table.CellMouseUp += delegate(object sender, DataGridViewCellMouseEventArgs e) { MarkCell((DataGridView)sender, ref cells.DownCell, NoCell); };
                    table.MouseCaptureChanged += delegate(object sender, EventArgs e) { if (!((DataGridView)sender).Capture) MarkCell((DataGridView)sender, ref cells.DownCell, NoCell); };
                    table.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Space && e.Modifiers == Keys.None) MarkCell((DataGridView)sender, ref cells.KeyCell, ((DataGridView)sender).CurrentCellAddress); };
                    table.KeyUp += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Space) MarkCell((DataGridView)sender, ref cells.KeyCell, NoCell); };
                    // The table losing the focus, also to another window: Space's release then goes elsewhere.
                    table.LostFocus += delegate(object sender, EventArgs e) { MarkCell((DataGridView)sender, ref cells.KeyCell, NoCell); };
                    // A mark names a place in the table; once rows go, that place may hold another row.
                    table.RowsRemoved += delegate { cells.HotCell = cells.DownCell = cells.KeyCell = NoCell; };
                    // A table draws its single-line border itself, in black; draw it over in the theme's border color.
                    table.Paint += delegate(object sender, PaintEventArgs e) {
                        DataGridView current = (DataGridView)sender; Hook own;
                        if (current.BorderStyle == BorderStyle.FixedSingle && hooks.TryGetValue(current, out own) && own.Palette != null && !own.Palette.HighContrast)
                            using (Pen border = new Pen(own.Palette.Border)) e.Graphics.DrawRectangle(border, 0, 0, current.Width - 1, current.Height - 1);
                    };
                }
                control.HandleCreated += delegate { ApplyNative(control); };
                // A window shown with its parent, or on another tab, gets no message of its own; lay its scroll bar skins again.
                // A form reports this while Windows is still about to show it (WM_SHOWWINDOW), so this waits for the next message.
                control.VisibleChanged += delegate {
                    Hook own;
                    if (!control.IsHandleCreated || !hooks.TryGetValue(control, out own) || own.Skin == null) return;
                    try { control.BeginInvoke(new Action(delegate { if (own.Skin != null && own.Skin.Handle != IntPtr.Zero) own.Skin.Sync(); })); }
                    catch (InvalidOperationException) { }
                };
            }
            hook.Palette = palette;
            string role = control.Tag as string;
            Color parent = control.Parent == null ? palette.Background : control.Parent.BackColor;
            // The popup's resize margin and pages share one surface. A contrasting
            // rectangular inner panel otherwise appears to cut through its curves.
            control.BackColor = control is LauncherForm && !palette.HighContrast ? palette.Surface : control is Form ? palette.Background : control is TabPage || control is ListView || control.Name.EndsWith("Section", StringComparison.Ordinal) ? palette.Surface : parent;
            control.ForeColor = role == "ErrorText" ? palette.Error : role == "SecondaryText" ? palette.Muted : palette.Text;
            LinkLabel link = control as LinkLabel;
            if (link != null) {
                link.LinkColor = link.VisitedLinkColor = control.ForeColor;
                link.ActiveLinkColor = palette.Text;
                link.DisabledLinkColor = palette.HighContrast ? SystemColors.GrayText : palette.Muted;
            }
            Button button = control as Button;
            if (button != null) {
                bool primary = role == "PrimaryAction";
                button.FlatStyle = FlatStyle.Flat; button.UseVisualStyleBackColor = false;
                button.BackColor = primary ? palette.Accent : palette.Surface;
                button.ForeColor = primary ? palette.AccentText : palette.Text;
                button.FlatAppearance.BorderColor = palette.Border;
                // A primary action keeps its own label color, so it stays in its accent family under the pointer.
                button.FlatAppearance.MouseOverBackColor = primary ? palette.AccentHover : palette.Selection;
                button.FlatAppearance.MouseDownBackColor = primary ? palette.AccentPressed : palette.Pressed;
            }
            if (control is ComboBox || control is TextBoxBase || control is NumericUpDown) control.BackColor = palette.Input;
            CheckBox check = control as CheckBox; if (check != null) check.UseVisualStyleBackColor = false;
            // A themed details list draws its own grid lines; high contrast gets Windows' back.
            ListView rows = control as ListView;
            if (rows != null && !(rows is IconGridView)) rows.GridLines = palette.HighContrast && hook.GridLines;
            DataGridView grid = control as DataGridView;
            if (grid != null) {
                grid.EnableHeadersVisualStyles = false; grid.BackgroundColor = palette.Input; grid.GridColor = palette.Border;
                // Single header lines take the grid color; the default raised ones are drawn light.
                grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single;
                grid.DefaultCellStyle.BackColor = palette.Input; grid.DefaultCellStyle.ForeColor = palette.Text;
                grid.DefaultCellStyle.SelectionBackColor = palette.Selection; grid.DefaultCellStyle.SelectionForeColor = palette.SelectionText;
                grid.ColumnHeadersDefaultCellStyle.BackColor = palette.Surface; grid.ColumnHeadersDefaultCellStyle.ForeColor = palette.Text;
                grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = palette.Surface;
                foreach (DataGridViewColumn column in grid.Columns) { DataGridViewButtonColumn action = column as DataGridViewButtonColumn; if (action != null) action.FlatStyle = FlatStyle.Flat; }
            }
            if (control.IsHandleCreated) ApplyNative(control);
            foreach (Control child in control.Controls) Apply(child, palette);
            control.Invalidate();
        }
        static void ApplyNative(Control control)
        {
            Hook hook; if (!hooks.TryGetValue(control, out hook) || hook.Palette == null || !control.IsHandleCreated) return;
            AppearancePalette p = hook.Palette;
            if (control is Form) {
                try {
                    int dark = p.Dark && !p.HighContrast ? 1 : 0;
                    DwmSetWindowAttribute(control.Handle, 20, ref dark, 4);
                    int caption = ColorTranslator.ToWin32(p.Background), text = ColorTranslator.ToWin32(p.Text);
                    DwmSetWindowAttribute(control.Handle, 35, ref caption, 4); DwmSetWindowAttribute(control.Handle, 36, ref text, 4);
                    if (control is LauncherForm) {
                        // Keep the resize frame and rounded region, without DWM's
                        // decorative outline. Restore OS borders in high contrast.
                        int border = p.HighContrast ? -1 : -2; // COLOR_DEFAULT / COLOR_NONE.
                        DwmSetWindowAttribute(control.Handle, 34, ref border, 4);
                    }
                }
                catch (DllNotFoundException) { }
                catch (EntryPointNotFoundException) { }
            }
            else if (control is ListView || control is TextBoxBase || control is DataGridView || (control is Panel && ((Panel)control).AutoScroll)) {
                // Older Windows builds may ignore this style; explicit control colors still apply.
                // A scrolling panel, like Manage Icons in a small window, takes it for its scroll bar.
                SetWindowTheme(control.Handle, p.Dark && !p.HighContrast ? "DarkMode_Explorer" : "Explorer", null);
                // Windows does not repaint a panel's scroll bar for a new theme by itself (RDW_INVALIDATE | RDW_FRAME).
                if (control is Panel) RedrawWindow(control.Handle, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0400);
            }
            else if (control is ComboBox) {
                // A list's dropdown is a window of its own, with its own scroll bar.
                ComboInfo info = new ComboInfo { Size = Marshal.SizeOf(typeof(ComboInfo)) };
                if (GetComboBoxInfo(control.Handle, ref info) && info.List != IntPtr.Zero)
                    SetWindowTheme(info.List, p.Dark && !p.HighContrast ? "DarkMode_Explorer" : "Explorer", null);
            }
            // Windows' scroll bars take the theme's colors from a skin laid over them (ScrollSkin): a list's, a scrolling
            // panel's, a table's (its scroll bar controls) and a list dropdown's.
            if (control is ListView || (control is Panel && ((Panel)control).AutoScroll)) Skin(hook, control, control.Handle, false);
            else if (control is ScrollBar) Skin(hook, control, control.Handle, true);
            else if (control is ComboBox) {
                ComboInfo info = new ComboInfo { Size = Marshal.SizeOf(typeof(ComboInfo)) };
                if (GetComboBoxInfo(control.Handle, ref info)) Skin(hook, control, info.List, false);
            }
            // The border of a text box, a list or a table, drawn in the theme's border color.
            if (control is TextBoxBase || control is ListView || control is DataGridView) {
                if (hook.Border == null || hook.Border.Handle != control.Handle) hook.Border = new FrameBorder(control);
                RedrawWindow(control.Handle, IntPtr.Zero, IntPtr.Zero, 0x0001 | 0x0400); // RDW_INVALIDATE | RDW_FRAME
            }
        }
        // An edit control takes a single border off its frame and draws it inside its client area, in Windows' gray;
        // draw it over in the theme's border color, into deviceContext when printing.
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr window);
        // Whether BetterIcon draws this control's border inside its client area: a themed single-line text box with a single border.
        internal static bool OwnsClientBorder(Control control)
        {
            Hook hook; TextBoxBase box = control as TextBoxBase;
            return box != null && !box.Multiline && box.BorderStyle == BorderStyle.FixedSingle && box.ClientSize == box.Size && box.Width >= 3 && box.Height >= 3
                && hooks.TryGetValue(control, out hook) && hook.Palette != null && !hook.Palette.HighContrast;
        }
        internal static void DrawClientBorder(Control control, IntPtr window, IntPtr deviceContext)
        {
            Hook hook; TextBoxBase box = control as TextBoxBase;
            if (!OwnsClientBorder(control) || !hooks.TryGetValue(control, out hook)) return;
            bool own = deviceContext == IntPtr.Zero;
            IntPtr device = own ? GetDC(window) : deviceContext;
            if (device == IntPtr.Zero) return;
            try { using (Graphics canvas = Graphics.FromHdc(device)) using (Pen border = new Pen(hook.Palette.Border)) canvas.DrawRectangle(border, 0, 0, box.Width - 1, box.Height - 1); }
            finally { if (own) ReleaseDC(window, device); }
        }
        // A details list whose rows BetterIcon draws: themed, not high contrast.
        static bool OwnRows(ListView list)
        {
            Hook hook; return list.View == View.Details && hooks.TryGetValue(list, out hook) && hook.Palette != null && !hook.Palette.HighContrast;
        }
        static void DrawListCell(ListView list, DrawListViewSubItemEventArgs e)
        {
            Hook hook; hooks.TryGetValue(list, out hook);
            AppearancePalette p = hook.Palette;
            // Without FullRowSelect only the first column shows the selection and the focus, as Windows draws them.
            bool whole = list.FullRowSelect || e.ColumnIndex == 0;
            bool selected = whole && e.Item.Selected && (list.Focused || !list.HideSelection);
            Rectangle cell = e.Bounds;
            // The first column's cell spans the whole row; keep it to its column.
            if (e.ColumnIndex == 0 && list.Columns.Count > 0) cell.Width = list.Columns[0].Width;
            using (Brush back = new SolidBrush(selected ? p.Selection : list.BackColor)) e.Graphics.FillRectangle(back, cell);
            TextRenderer.DrawText(e.Graphics, e.SubItem.Text, list.Font, Rectangle.Inflate(cell, -6, 0), selected ? p.SelectionText : list.ForeColor,
                TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
            if (hook.GridLines)
                using (Pen line = new Pen(p.Border)) {
                    e.Graphics.DrawLine(line, cell.Right - 1, cell.Top, cell.Right - 1, cell.Bottom - 1);
                    e.Graphics.DrawLine(line, cell.Left, cell.Bottom - 1, cell.Right - 1, cell.Bottom - 1);
                }
            // The focus rectangle runs around the whole row, and each cell is filled in turn, so each draws the part that
            // crosses it: drawn with the first cell alone, the later cells paint over it. Shown once the keyboard is in use.
            if (whole && e.Item.Focused && list.Focused && ShowsFocus(list)) {
                Rectangle around = list.FullRowSelect ? e.Item.Bounds : cell;
                if (hook.GridLines) { around.Width--; around.Height--; }
                using (Region clip = e.Graphics.Clip) {
                    e.Graphics.SetClip(cell, CombineMode.Intersect);
                    ControlPaint.DrawFocusRectangle(e.Graphics, around, list.ForeColor, selected ? p.Selection : list.BackColor);
                    e.Graphics.Clip = clip;
                }
            }
        }
        // WM_QUERYUISTATE: Windows hides the marks of keyboard focus until the keyboard is used (UISF_HIDEFOCUS).
        static bool ShowsFocus(Control control)
        {
            return control.IsHandleCreated && (SendMessage(control.Handle, 0x0129, IntPtr.Zero, IntPtr.Zero).ToInt32() & 0x1) == 0;
        }
        // Moves one of a table's cell marks, and redraws the cell that lost it and the cell that gained it.
        static void MarkCell(DataGridView table, ref Point mark, Point cell)
        {
            if (mark == cell) return;
            Point before = mark; mark = cell;
            foreach (Point changed in new[] { before, cell })
                if (changed.X >= 0 && changed.Y >= 0 && changed.X < table.ColumnCount && changed.Y < table.RowCount) table.InvalidateCell(changed.X, changed.Y);
        }
        // A table's button cell: the cell's own background and lines, then a flat button in the surface color with the
        // border color around it. Like the window's other buttons it takes the selection color under the pointer and the
        // pressed color while the mouse or Space holds it down, and the current one shows the keyboard focus.
        static void DrawTableButton(DataGridView table, DataGridViewCellPaintingEventArgs e)
        {
            Hook hook;
            if (e.RowIndex < 0 || e.ColumnIndex < 0 || !(table.Columns[e.ColumnIndex] is DataGridViewButtonColumn) || !hooks.TryGetValue(table, out hook) || hook.Palette == null || hook.Palette.HighContrast) return;
            AppearancePalette p = hook.Palette;
            Point at = new Point(e.ColumnIndex, e.RowIndex);
            bool current = table.Focused && table.CurrentCellAddress == at, hot = hook.HotCell == at;
            bool held = (hot && hook.DownCell == at) || (current && hook.KeyCell == at);
            Color tone = held ? p.Pressed : hot ? p.Selection : p.Surface;
            e.PaintBackground(e.ClipBounds, (e.State & DataGridViewElementStates.Selected) != 0);
            Rectangle face = new Rectangle(e.CellBounds.Left + 2, e.CellBounds.Top + 2, e.CellBounds.Width - 5, e.CellBounds.Height - 5);
            using (Brush fill = new SolidBrush(tone)) e.Graphics.FillRectangle(fill, face);
            using (Pen border = new Pen(p.Border)) e.Graphics.DrawRectangle(border, face);
            TextRenderer.DrawText(e.Graphics, Convert.ToString(e.FormattedValue), e.CellStyle.Font ?? table.Font, face, p.Text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            if (current && ShowsFocus(table) && face.Width > 8 && face.Height > 8) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(face, -2, -2), p.Text, tone);
            e.Handled = true;
        }
        static void Skin(Hook hook, Control owner, IntPtr target, bool barControl)
        {
            if (target == IntPtr.Zero) return;
            if (hook.Skin == null || hook.Skin.Handle != target) hook.Skin = new ScrollSkin(target, barControl, owner is VScrollBar);
            hook.Skin.Palette = hook.Palette; hook.Skin.Sync();
        }
        // Draws the border Windows gives a text box, list or table in the theme's border color, over Windows' own, and fills
        // a sunken border's inner line with the control's background. Into deviceContext when printing, else the window's
        // own. High contrast keeps Windows' border.
        // The width of the frame Windows gives a text box, list or table, which BetterIcon draws in the theme's colors. 0
        // where it draws none: high contrast, no frame, or one wider than a sunken edge.
        internal static int FrameEdge(Control control, IntPtr window)
        {
            Hook hook; Rect outer;
            if (!hooks.TryGetValue(control, out hook) || hook.Palette == null || hook.Palette.HighContrast || !GetWindowRect(window, out outer)) return 0;
            int style = GetWindowLong(window, -16), extended = GetWindowLong(window, -20);
            int width = outer.Right - outer.Left, height = outer.Bottom - outer.Top;
            // WS_BORDER, WS_EX_CLIENTEDGE, WS_EX_STATICEDGE. An edit control takes WS_BORDER off and draws that border
            // itself, so a single-line text box's border is measured instead.
            int edge = control is TextBoxBase && !((TextBoxBase)control).Multiline ? Math.Min(width - control.ClientSize.Width, height - control.ClientSize.Height) / 2
                : ((style & 0x00800000) != 0 ? 1 : 0) + ((extended & 0x200) != 0 ? 2 : 0) + ((extended & 0x20000) != 0 ? 1 : 0);
            return edge < 1 || edge > 3 || width < 2 * edge + 2 || height < 2 * edge + 2 ? 0 : edge;
        }
        internal static void DrawFrame(Control control, IntPtr window, IntPtr deviceContext)
        {
            Hook hook; Rect outer;
            int edge = FrameEdge(control, window);
            if (edge < 1 || !hooks.TryGetValue(control, out hook) || !GetWindowRect(window, out outer)) return;
            int width = outer.Right - outer.Left, height = outer.Bottom - outer.Top;
            bool own = deviceContext == IntPtr.Zero;
            IntPtr device = own ? GetWindowDC(window) : deviceContext;
            if (device == IntPtr.Zero) return;
            try {
                using (Graphics canvas = Graphics.FromHdc(device)) {
                    using (Pen border = new Pen(hook.Palette.Border)) canvas.DrawRectangle(border, 0, 0, width - 1, height - 1);
                    using (Pen inner = new Pen(control.BackColor)) for (int i = 1; i < edge; i++) canvas.DrawRectangle(inner, i, i, width - 1 - 2 * i, height - 1 - 2 * i);
                }
            }
            finally { if (own) ReleaseDC(window, device); }
        }
        // Draws a check box in the theme's colors over Windows' own: a rounded square in the input color with the border
        // color around it, filled with the accent once checked. High contrast keeps Windows' check box.
        static void DrawCheckBox(CheckBox box, Graphics canvas)
        {
            Hook hook;
            if (!hooks.TryGetValue(box, out hook) || hook.Palette == null || hook.Palette.HighContrast || box.Appearance != Appearance.Normal
                || box.CheckAlign != ContentAlignment.MiddleLeft || box.RightToLeft == RightToLeft.Yes) return;
            AppearancePalette p = hook.Palette; Rectangle client = box.ClientRectangle;
            using (Brush back = new SolidBrush(box.BackColor)) canvas.FillRectangle(back, client);
            Size glyph = CheckBoxRenderer.GetGlyphSize(canvas, System.Windows.Forms.VisualStyles.CheckBoxState.UncheckedNormal);
            Rectangle square = new Rectangle(client.Left + box.Padding.Left, client.Top + (client.Height - glyph.Height) / 2, glyph.Width, glyph.Height);
            bool on = box.CheckState != CheckState.Unchecked, enabled = box.Enabled;
            Color fill = on ? (!enabled ? Mix(p.Accent, p.Surface, 0.55) : hook.Pressed ? p.AccentPressed : hook.Hot ? p.AccentHover : p.Accent)
                : !enabled ? p.Surface : hook.Pressed ? p.Pressed : hook.Hot ? p.Selection : p.Input;
            Color edge = on ? fill : !enabled ? Mix(p.Border, p.Surface, 0.5) : hook.Hot ? p.Muted : p.Border;
            GraphicsState saved = canvas.Save();
            try {
                canvas.SmoothingMode = SmoothingMode.AntiAlias;
                using (GraphicsPath shape = ScrollSkin.Rounded(new RectangleF(square.X + 0.5f, square.Y + 0.5f, square.Width - 1, square.Height - 1), square.Width / 5f))
                using (Brush brush = new SolidBrush(fill)) using (Pen pen = new Pen(edge)) { canvas.FillPath(brush, shape); canvas.DrawPath(pen, shape); }
                using (Pen mark = new Pen(enabled ? p.AccentText : Mix(p.AccentText, fill, 0.5), Math.Max(1.5f, square.Width / 7f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round }) {
                    float x = square.X, y = square.Y, w = square.Width, h = square.Height;
                    if (box.CheckState == CheckState.Checked) canvas.DrawLines(mark, new[] { new PointF(x + w * 0.24f, y + h * 0.52f), new PointF(x + w * 0.43f, y + h * 0.70f), new PointF(x + w * 0.77f, y + h * 0.32f) });
                    else if (box.CheckState == CheckState.Indeterminate) canvas.DrawLine(mark, x + w * 0.28f, y + h / 2f, x + w * 0.72f, y + h / 2f);
                }
            }
            finally { canvas.Restore(saved); }
            // WM_QUERYUISTATE: whether to show keyboard focus and access keys, which Windows hides until the keyboard is used.
            int ui = box.IsHandleCreated ? SendMessage(box.Handle, 0x0129, IntPtr.Zero, IntPtr.Zero).ToInt32() : 0;
            TextFormatFlags flags = TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.SingleLine | TextFormatFlags.NoClipping;
            if (!box.UseMnemonic) flags |= TextFormatFlags.NoPrefix; else if ((ui & 0x2) != 0) flags |= TextFormatFlags.HidePrefix;
            Rectangle text = Rectangle.FromLTRB(square.Right + 3, client.Top, client.Right, client.Bottom);
            TextRenderer.DrawText(canvas, box.Text, box.Font, text, enabled ? box.ForeColor : p.Muted, flags);
            if (box.Focused && (ui & 0x1) == 0) {
                Size measured = TextRenderer.MeasureText(canvas, box.Text, box.Font, text.Size, flags);
                ControlPaint.DrawFocusRectangle(canvas, new Rectangle(text.Left - 1, client.Top + (client.Height - measured.Height) / 2 - 1, Math.Min(measured.Width + 2, client.Right - text.Left + 1), measured.Height + 2), box.ForeColor, box.BackColor);
            }
        }
        // The slider's thumb in the theme's accent, as the primary buttons, lighter under the pointer and while it is dragged.
        internal static bool DrawSliderThumb(TrackBar slider, IntPtr deviceContext, Rectangle thumb, bool hot, bool pressed)
        {
            Hook hook;
            if (deviceContext == IntPtr.Zero || thumb.Width < 2 || thumb.Height < 2 || !hooks.TryGetValue(slider, out hook) || hook.Palette == null || hook.Palette.HighContrast) return false;
            AppearancePalette p = hook.Palette;
            Color color = !slider.Enabled ? Mix(p.Accent, p.Surface, 0.55) : pressed ? p.AccentPressed : hot ? p.AccentHover : p.Accent;
            using (Graphics canvas = Graphics.FromHdc(deviceContext)) using (Brush brush = new SolidBrush(color)) canvas.FillRectangle(brush, thumb);
            return true;
        }
        // A progress bar: the button's gray track and an accent chunk, moving while a marquee runs.
        internal static void DrawProgress(ProgressBar bar, Graphics canvas, bool running, int offset)
        {
            Hook hook; AppearancePalette p = hooks.TryGetValue(bar, out hook) ? hook.Palette : null;
            Rectangle area = bar.ClientRectangle, chunk;
            using (Brush track = new SolidBrush(p == null ? SystemColors.Control : p.ControlFace)) canvas.FillRectangle(track, area);
            if (bar.Style == ProgressBarStyle.Marquee) {
                if (!running) return;
                int length = Math.Max(8, area.Width / 4);
                chunk = new Rectangle(area.Left + offset - length, area.Top, length, area.Height);
            }
            else chunk = new Rectangle(area.Left, area.Top, (int)((long)area.Width * Math.Max(0, bar.Value - bar.Minimum) / Math.Max(1, bar.Maximum - bar.Minimum)), area.Height);
            chunk.Intersect(area);
            if (chunk.Width > 0) using (Brush fill = new SolidBrush(p == null ? SystemColors.Highlight : p.Accent)) canvas.FillRectangle(fill, chunk);
        }
        internal static void DrawComboBorder(AppearanceComboBox combo, IntPtr deviceContext)
        {
            Hook hook;
            if (!combo.IsHandleCreated || combo.IsDisposed || combo.ClientSize.Width < 2 || combo.ClientSize.Height < 2
                || !hooks.TryGetValue(combo, out hook) || hook.Palette == null) return;
            AppearancePalette p = hook.Palette;
            using (Graphics canvas = deviceContext == IntPtr.Zero ? Graphics.FromHwnd(combo.Handle) : Graphics.FromHdc(deviceContext)) {
                using (Pen border = new Pen(p.Border))
                    canvas.DrawRectangle(border, 0, 0, combo.ClientSize.Width - 1, combo.ClientSize.Height - 1);
                // High contrast keeps the system's colors.
                if (!p.HighContrast && combo.FlatStyle == FlatStyle.Flat && combo.DropDownStyle != ComboBoxStyle.Simple && combo.RightToLeft != RightToLeft.Yes)
                    DrawComboButton(canvas, combo, p);
            }
        }
        // WinForms draws a flat list's dropdown button light gray whatever the theme (its FlatComboAdapter), and two
        // frames inside the list's border, light gray while the list is disabled. Draw them again in the same places,
        // in the theme's colors. Printing (DrawToBitmap) skips WinForms' drawing, so the frames are drawn every time.
        static void DrawComboButton(Graphics canvas, ComboBox combo, AppearancePalette p)
        {
            int width = combo.ClientSize.Width, height = combo.ClientSize.Height;
            int button = SystemInformation.GetHorizontalScrollBarArrowWidthForDpi(combo.DeviceDpi), left = width - button - 1;
            if (button < 4 || left < 6 || height < 6) return;
            using (Pen input = new Pen(p.Input)) {
                canvas.DrawRectangle(input, 1, 1, width - button - 3, height - 3);
                canvas.DrawRectangle(input, 2, 2, width - button - 5, height - 5);
            }
            using (Brush face = new SolidBrush(p.ControlFace)) canvas.FillRectangle(face, left + 1, 1, button - 1, height - 2);
            // A lighter line beside the list's text; an outline on the other three sides.
            using (Brush light = new SolidBrush(p.ControlLight)) canvas.FillRectangle(light, left, 1, 1, height - 2);
            using (Brush outline = new SolidBrush(p.ControlOutline)) {
                canvas.FillRectangle(outline, left, 0, button + 1, 1);
                canvas.FillRectangle(outline, left, height - 1, button + 1, 1);
                canvas.FillRectangle(outline, width - 1, 0, 1, height);
            }
            // The arrow where WinForms draws it, at the same size.
            int offset = combo.LogicalToDeviceUnits(2);
            Point middle = new Point(left + button / 2 + button % 2, 1 + (height - 2) / 2);
            using (Brush arrow = new SolidBrush(combo.Enabled ? p.ControlGlyph : Mix(p.ControlGlyph, p.ControlFace, 0.5)))
                canvas.FillPolygon(arrow, new[] { new Point(middle.X - offset, middle.Y - 1), new Point(middle.X + offset + 1, middle.Y - 1), new Point(middle.X, middle.Y + offset) });
        }
        // Draws the slider's channel: its face, then a one-pixel edge in one color before the thumb and another after it.
        // False leaves the channel to Windows.
        internal static bool DrawSliderChannel(TrackBar slider, IntPtr deviceContext, Rectangle channel, int split)
        {
            Hook hook;
            if (deviceContext == IntPtr.Zero || channel.Width < 3 || channel.Height < 3 || !hooks.TryGetValue(slider, out hook)
                || hook.Palette == null || hook.Palette.HighContrast) return false;
            AppearancePalette p = hook.Palette;
            bool across = slider.Orientation == Orientation.Horizontal;
            int middle = across ? Math.Max(channel.Left, Math.Min(channel.Right, split)) : Math.Max(channel.Top, Math.Min(channel.Bottom, split));
            Rectangle before = across ? Rectangle.FromLTRB(channel.Left, channel.Top, middle, channel.Bottom) : Rectangle.FromLTRB(channel.Left, channel.Top, channel.Right, middle);
            Rectangle after = across ? Rectangle.FromLTRB(middle, channel.Top, channel.Right, channel.Bottom) : Rectangle.FromLTRB(channel.Left, middle, channel.Right, channel.Bottom);
            using (Graphics canvas = Graphics.FromHdc(deviceContext))
            using (Brush face = new SolidBrush(p.ControlFace), first = new SolidBrush(p.ChannelEdgeBefore), last = new SolidBrush(p.ChannelEdge)) {
                canvas.FillRectangle(face, channel);
                ChannelEdges(canvas, first, before, across, true, false);
                ChannelEdges(canvas, last, after, across, false, true);
            }
            return true;
        }
        // The two long sides of one part of the channel, and the channel's end where the part has one.
        static void ChannelEdges(Graphics canvas, Brush brush, Rectangle part, bool across, bool start, bool end)
        {
            if (part.Width <= 0 || part.Height <= 0) return;
            if (across) {
                canvas.FillRectangle(brush, part.Left, part.Top, part.Width, 1); canvas.FillRectangle(brush, part.Left, part.Bottom - 1, part.Width, 1);
                if (start) canvas.FillRectangle(brush, part.Left, part.Top, 1, part.Height);
                if (end) canvas.FillRectangle(brush, part.Right - 1, part.Top, 1, part.Height);
            } else {
                canvas.FillRectangle(brush, part.Left, part.Top, 1, part.Height); canvas.FillRectangle(brush, part.Right - 1, part.Top, 1, part.Height);
                if (start) canvas.FillRectangle(brush, part.Left, part.Top, part.Width, 1);
                if (end) canvas.FillRectangle(brush, part.Left, part.Bottom - 1, part.Width, 1);
            }
        }
        static void DrawCombo(ComboBox combo, DrawItemEventArgs e)
        {
            Hook hook; if (!hooks.TryGetValue(combo, out hook) || hook.Palette == null || e.Bounds.Width < 1) return;
            AppearancePalette p = hook.Palette; bool selected = (e.State & DrawItemState.Selected) != 0;
            using (Brush brush = new SolidBrush(selected ? p.Selection : p.Input)) e.Graphics.FillRectangle(brush, e.Bounds);
            string text = e.Index >= 0 && e.Index < combo.Items.Count ? combo.Items[e.Index].ToString() : combo.Text;
            Rectangle textBounds = Rectangle.Inflate(e.Bounds, -5, 0);
            if (combo.Name == "AppIconStyle" && e.Index >= 0 && e.Index < AppBranding.Styles.Length) {
                using (Bitmap icon = AppBranding.Preview(AppBranding.Styles[e.Index], combo.Tag as string ?? (p.Dark ? "dark" : "light"), 22))
                    e.Graphics.DrawImage(icon, e.Bounds.Left + 3, e.Bounds.Top + (e.Bounds.Height - 22) / 2);
                textBounds.X += 26; textBounds.Width -= 26;
            }
            TextRenderer.DrawText(e.Graphics, text, combo.Font, textBounds, combo.Enabled ? selected ? p.SelectionText : p.Text : p.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            if ((e.State & DrawItemState.Focus) != 0) e.DrawFocusRectangle();
        }
        sealed class MenuColors : ProfessionalColorTable
        {
            readonly AppearancePalette p; public MenuColors(AppearancePalette palette) { p = palette; UseSystemColors = false; }
            public override Color ToolStripDropDownBackground { get { return p.Surface; } }
            public override Color ImageMarginGradientBegin { get { return p.Surface; } }
            public override Color ImageMarginGradientMiddle { get { return p.Surface; } }
            public override Color ImageMarginGradientEnd { get { return p.Surface; } }
            public override Color MenuItemSelected { get { return p.Selection; } }
            public override Color MenuItemBorder { get { return p.Border; } }
            public override Color MenuBorder { get { return p.Border; } }
            public override Color MenuItemPressedGradientBegin { get { return p.Selection; } }
            public override Color MenuItemPressedGradientEnd { get { return p.Selection; } }
            public override Color SeparatorDark { get { return p.Border; } }
            public override Color SeparatorLight { get { return p.Surface; } }
        }
        sealed class MenuRenderer : ToolStripProfessionalRenderer
        {
            readonly AppearancePalette p; public MenuRenderer(AppearancePalette palette) : base(new MenuColors(palette)) { p = palette; RoundedEdges = false; }
            protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) { e.ArrowColor = p.Text; base.OnRenderArrow(e); }
            protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Enabled ? p.Text : p.Muted; base.OnRenderItemText(e); }
        }
        public static void ApplyMenu(ToolStrip menu, AppearancePalette palette)
        {
            menu.BackColor = palette.Surface; menu.ForeColor = palette.Text; menu.Renderer = new MenuRenderer(palette);
            foreach (ToolStripItem item in menu.Items) {
                item.ForeColor = palette.Text;
                ToolStripDropDownItem sub = item as ToolStripDropDownItem; if (sub != null && sub.HasDropDownItems) ApplyMenu(sub.DropDown, palette);
            }
        }
        public static bool Message(Form owner, string title, string message, AppearancePalette palette, bool cancel)
        {
            using (Form dialog = new Form { Text = title, Font = owner.Font, StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(480, 190), MinimumSize = new Size(400, 200), MinimizeBox = false, MaximizeBox = false, Icon = owner.Icon }) {
                TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 2 };
                layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.Controls.Add(new Label { Text = message, Dock = DockStyle.Fill }, 0, 0);
                FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, AutoSize = true };
                Button ok = new Button { Text = cancel ? "Continue" : "OK", DialogResult = DialogResult.OK, AutoSize = true, MinimumSize = new Size(100, 32), Tag = "PrimaryAction" };
                if (cancel) { Button no = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(100, 32) }; buttons.Controls.Add(no); dialog.CancelButton = no; }
                buttons.Controls.Add(ok); layout.Controls.Add(buttons, 0, 1); dialog.Controls.Add(layout); dialog.AcceptButton = ok;
                Apply(dialog, palette); return dialog.ShowDialog(owner) == DialogResult.OK;
            }
        }
        // A question with several answers, each a button with its tooltip, and Cancel. Answers the index of the chosen answer,
        // or -1 for Cancel. The first answer is the default.
        public static int Choose(Form owner, string title, string message, AppearancePalette palette, string[] answers, string[] tips)
        {
            using (Form dialog = new Form { Text = title, Font = owner.Font, StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(580, 220), MinimumSize = new Size(480, 220), MinimizeBox = false, MaximizeBox = false, Icon = owner.Icon })
            using (ToolTip tooltips = new ToolTip()) {
                TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), ColumnCount = 1, RowCount = 2 };
                layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                layout.Controls.Add(new Label { Text = message, Dock = DockStyle.Fill }, 0, 0);
                FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, AutoSize = true };
                Button no = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(100, 32) };
                tooltips.SetToolTip(no, "Keep the pack as it is.");
                buttons.Controls.Add(no); dialog.CancelButton = no;
                int chosen = 0;
                Button first = null;
                for (int i = answers.Length - 1; i >= 0; i--) {
                    int index = i;
                    Button answer = new Button { Text = answers[i], DialogResult = DialogResult.OK, AutoSize = true, MinimumSize = new Size(120, 32), Tag = i == 0 ? "PrimaryAction" : null };
                    answer.Click += delegate { chosen = index; };
                    if (tips != null && i < tips.Length) tooltips.SetToolTip(answer, tips[i]);
                    buttons.Controls.Add(answer);
                    if (i == 0) first = answer;
                }
                layout.Controls.Add(buttons, 0, 1); dialog.Controls.Add(layout); dialog.AcceptButton = first;
                Apply(dialog, palette);
                return dialog.ShowDialog(owner) == DialogResult.OK ? chosen : -1;
            }
        }
    }

    public sealed partial class LauncherForm
    {
        readonly Button appIconButton = new Button(), appearanceModeButton = new Button();
        readonly ContextMenuStrip appIconMenu = new ContextMenuStrip();
        readonly ToolTip appearanceTips = new ToolTip();
        AppearancePalette appearancePalette;
        Icon ownedAppIcon, ownedTrayIcon;
        string activeAppIconKey;
        bool appearanceQueued, appearanceSubscribed, suppressAppIconClick;

        sealed class AppIconMenuColors : ProfessionalColorTable
        {
            readonly AppearancePalette palette;
            public AppIconMenuColors(AppearancePalette value) { palette = value; UseSystemColors = false; }
            public override Color ToolStripDropDownBackground { get { return palette.Surface; } }
            public override Color ImageMarginGradientBegin { get { return palette.Surface; } }
            public override Color ImageMarginGradientMiddle { get { return palette.Surface; } }
            public override Color ImageMarginGradientEnd { get { return palette.Surface; } }
            public override Color MenuItemSelected { get { return palette.Selection; } }
            public override Color MenuItemBorder { get { return palette.Selection; } }
            public override Color MenuBorder { get { return palette.Border; } }
        }
        sealed class AppIconMenuRenderer : ToolStripProfessionalRenderer
        {
            readonly AppearancePalette palette;
            public AppIconMenuRenderer(AppearancePalette value) : base(new AppIconMenuColors(value)) { palette = value; RoundedEdges = false; }
            protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
            {
                ToolStripMenuItem item = e.Item as ToolStripMenuItem;
                using (Brush brush = new SolidBrush(e.Item.Selected || (item != null && item.Checked) ? palette.Selection : palette.Surface))
                    e.Graphics.FillRectangle(brush, new Rectangle(Point.Empty, e.Item.Size));
            }
            // Highlight the selected row without a checkmark column or overlay.
            protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) { }
            protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Enabled ? palette.Text : palette.Muted; base.OnRenderItemText(e); }
        }
        void BuildAppearanceSettings()
        {
            foreach (Button button in new[] { appIconButton, appearanceModeButton }) {
                button.Size = new Size(44, 44); button.Margin = new Padding(4, 0, 0, 0);
                button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderSize = 0;
                button.ImageAlign = ContentAlignment.MiddleCenter;
            }
            appIconButton.Name = "AppIconButton"; appIconButton.AccessibleName = "Choose Better Icon app icon";
            appearanceModeButton.Name = "AppearanceModeButton";
            appIconMenu.Name = "AppIconMenu"; appIconMenu.Font = Font;
            appIconMenu.ShowCheckMargin = false; appIconMenu.ShowImageMargin = true;
            appIconMenu.ImageScalingSize = new Size(32, 32); appIconMenu.Padding = new Padding(4);
            ToolStripMenuItem automatic = new ToolStripMenuItem("Match app theme") { Tag = "Auto", ImageScaling = ToolStripItemImageScaling.None };
            automatic.Click += delegate { if (!busy) { preferences.AppIconVariant = "Auto"; ChangeAppearance(); } };
            appIconMenu.Items.Add(automatic);
            foreach (string color in AppBranding.Styles) foreach (string shade in new[] { "Dark", "Light" }) {
                string style = color, variant = shade;
                ToolStripMenuItem item = new ToolStripMenuItem(AppBranding.Title(style) + " " + variant) {
                    Tag = style + "/" + variant, Image = AppBranding.Preview(style, variant.ToLowerInvariant(), 32),
                    ImageScaling = ToolStripItemImageScaling.None
                };
                // The app takes the chosen icon's color scheme, so a Dark or Light icon also sets that theme.
                item.Click += delegate { if (!busy) { preferences.AppIconStyle = style; preferences.AppIconVariant = variant; preferences.AppearanceMode = variant; ChangeAppearance(); } };
                appIconMenu.Items.Add(item);
            }
            foreach (ToolStripItem item in appIconMenu.Items) {
                item.Padding = new Padding(4, 3, 8, 3);
                if (item.Tag as string != "Auto") item.ToolTipText = "Use this as BetterIcon's own icon, in the tray and on its window.";
            }
            ExplainMenu(appIconMenu);
            appIconMenu.Closing += delegate(object sender, ToolStripDropDownClosingEventArgs e) {
                suppressAppIconClick = e.CloseReason == ToolStripDropDownCloseReason.AppClicked && appIconButton.RectangleToScreen(appIconButton.ClientRectangle).Contains(Cursor.Position);
            };
            appIconButton.Click += delegate {
                if (suppressAppIconClick) { suppressAppIconClick = false; return; }
                ShowAppIconMenu();
            };
            appearanceModeButton.Click += delegate {
                if (busy) return;
                preferences.AppearanceMode = preferences.AppearanceMode == "Dark" ? "Light" : preferences.AppearanceMode == "Light" ? "System" : "Dark";
                ChangeAppearance();
            };
        }
        bool AppearanceMenuOpen { get { return appIconMenu.Visible; } }
        void ShowAppIconMenu()
        {
            if (busy || !Enabled) return;
            if (appIconMenu.Visible) { appIconMenu.Close(); return; }
            Rectangle anchor = appIconButton.RectangleToScreen(appIconButton.ClientRectangle), work = Screen.FromControl(appIconButton).WorkingArea;
            int above = anchor.Top - work.Top - 8, below = work.Bottom - anchor.Bottom - 8;
            bool upward = above >= 120 || above >= below;
            int available = Math.Max(80, Math.Min(work.Height - 16, upward ? above : below));
            // ToolStripDropDownMenu supplies native scroll arrows when constrained.
            appIconMenu.MaximumSize = new Size(Math.Max(1, work.Width - 16), available);
            Size size = appIconMenu.GetPreferredSize(Size.Empty);
            int x = Math.Max(work.Left + 4, Math.Min(work.Right - size.Width - 4, anchor.Right - size.Width));
            int y = upward ? anchor.Top - size.Height - 6 : anchor.Bottom + 6;
            y = Math.Max(work.Top + 4, Math.Min(work.Bottom - size.Height - 4, y));
            appIconMenu.Show(appIconButton, appIconButton.PointToClient(new Point(x, y)));
        }
        void SetAppearanceBusy(bool value)
        {
            appIconButton.Enabled = appearanceModeButton.Enabled = !value;
            if (value) appIconMenu.Close();
            foreach (ToolStripItem item in appIconMenu.Items) item.Enabled = !value;
        }
        void InitializeAppearance()
        {
            ApplyAppearance();
            SystemEvents.UserPreferenceChanged += OnSystemAppearanceChanged; appearanceSubscribed = true;
        }
        void OnSystemAppearanceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (IsDisposed || Disposing || !IsHandleCreated || appearanceQueued) return;
            appearanceQueued = true;
            try { BeginInvoke(new Action(delegate { try { if (!IsDisposed && !Disposing) ApplyAppearance(); } finally { appearanceQueued = false; } })); }
            catch (InvalidOperationException) { appearanceQueued = false; }
        }
        void ChangeAppearance()
        {
            if (busy) return;
            ApplyAppearance();
            try { WritePreferences(); status.Text = "Appearance saved."; }
            catch (IOException) { status.Text = "Appearance changed for this session, but could not be saved."; }
            catch (UnauthorizedAccessException) { status.Text = "Appearance changed for this session, but could not be saved."; }
        }
        void ApplyAppearance()
        {
            appearancePalette = AppAppearance.Resolve(preferences.AppearanceMode, style: preferences.AppIconStyle);
            string variant = AppBranding.Variant(preferences.AppIconVariant, appearancePalette.Dark), key = preferences.AppIconStyle + "." + variant;
            if (activeAppIconKey != key) {
                Icon replacement = AppBranding.Load(preferences.AppIconStyle, variant), previous = ownedAppIcon ?? Icon;
                Icon small = AppBranding.Load(preferences.AppIconStyle, variant, SystemInformation.SmallIconSize.Width), previousSmall = ownedTrayIcon;
                Icon = replacement; tray.Icon = small; ownedAppIcon = replacement; ownedTrayIcon = small; activeAppIconKey = key;
                foreach (Form dialog in OwnedForms) dialog.Icon = replacement;
                if (previous != null) previous.Dispose();
                if (previousSmall != null) previousSmall.Dispose();
                Image old = appIconButton.Image; appIconButton.Image = AppBranding.Preview(preferences.AppIconStyle, variant, 32); if (old != null) old.Dispose();
            }
            string description = AppBranding.Title(preferences.AppIconStyle) + " " + (variant == "dark" ? "Dark" : "Light");
            appIconButton.AccessibleDescription = description + (preferences.AppIconVariant == "Auto" ? "; matches the app theme." : "; fixed icon variant.");
            appearanceTips.SetToolTip(appIconButton, "BetterIcon's own icon and colors: " + description + ". Click to choose another.");
            foreach (ToolStripMenuItem item in appIconMenu.Items) item.Checked = (string)item.Tag == (preferences.AppIconVariant == "Auto" ? "Auto" : preferences.AppIconStyle + "/" + preferences.AppIconVariant);
            if (appIconMenu.Items.Count > 0) {
                ToolStripItem automatic = appIconMenu.Items[0]; Image old = automatic.Image;
                automatic.Image = AppBranding.Preview(preferences.AppIconStyle, appearancePalette.Dark ? "dark" : "light", 32);
                if (old != null) old.Dispose();
            }
            AppAppearance.Apply(this, appearancePalette);
            foreach (ContextMenuStrip menu in new[] { trayMenu, iconMenu, importPackMenu, managePackMenu, manageFilePackMenu }) AppAppearance.ApplyMenu(menu, appearancePalette);
            appIconMenu.BackColor = appearancePalette.Surface; appIconMenu.ForeColor = appearancePalette.Text;
            appIconMenu.Renderer = new AppIconMenuRenderer(appearancePalette);
            foreach (ToolStripItem item in appIconMenu.Items) item.ForeColor = appearancePalette.Text;
            foreach (Form dialog in OwnedForms) AppAppearance.Apply(dialog, appearancePalette);
            string next = preferences.AppearanceMode == "Dark" ? "Light" : preferences.AppearanceMode == "Light" ? "System" : "Dark";
            appearanceModeButton.AccessibleName = "App theme: " + preferences.AppearanceMode;
            appearanceModeButton.AccessibleDescription = "Click to switch to " + next + ". Cycles Dark, Light and System.";
            appearanceTips.SetToolTip(appearanceModeButton, preferences.AppearanceMode + " appearance. Click to switch to " + next + ".");
            Image oldGlyph = appearanceModeButton.Image;
            appearanceModeButton.Image = AppThemeGlyph(preferences.AppearanceMode, appearancePalette.Text);
            if (oldGlyph != null) oldGlyph.Dispose();
            pages.Invalidate();
        }
        static Bitmap AppThemeGlyph(string mode, Color color)
        {
            Bitmap image = new Bitmap(32, 32);
            using (Graphics canvas = Graphics.FromImage(image)) using (Pen pen = new Pen(color, 2F)) using (Brush brush = new SolidBrush(color)) {
                canvas.Clear(Color.Transparent); canvas.SmoothingMode = SmoothingMode.AntiAlias;
                if (mode == "Dark") {
                    // FillRegion ignores antialiasing. Join the same two ellipses
                    // at their intersections so both edges receive smooth alpha coverage.
                    using (GraphicsPath crescent = new GraphicsPath()) {
                        crescent.AddArc(5F, 4F, 23F, 24F, 40.146624F, 220.742574F);
                        crescent.AddArc(12F, 0F, 22F, 24F, 220.847704F, -142.866538F);
                        crescent.CloseFigure(); canvas.FillPath(brush, crescent);
                    }
                }
                else if (mode == "Light") {
                    canvas.DrawEllipse(pen, 10, 10, 12, 12);
                    for (int i = 0; i < 8; i++) {
                        double angle = i * Math.PI / 4;
                        canvas.DrawLine(pen, 16 + (float)Math.Cos(angle) * 10, 16 + (float)Math.Sin(angle) * 10, 16 + (float)Math.Cos(angle) * 14, 16 + (float)Math.Sin(angle) * 14);
                    }
                }
                else {
                    canvas.DrawRectangle(pen, 3, 6, 26, 18); canvas.DrawLine(pen, 16, 24, 16, 28); canvas.DrawLine(pen, 10, 29, 22, 29);
                    canvas.FillRectangle(brush, 6, 9, 10, 12);
                }
            }
            return image;
        }
        void ApplyDialogAppearance(Form dialog) { dialog.Icon = Icon; AppAppearance.Apply(dialog, appearancePalette ?? AppAppearance.Resolve(preferences.AppearanceMode, style: preferences.AppIconStyle)); }
        void DisposeAppearance()
        {
            if (appearanceSubscribed) { SystemEvents.UserPreferenceChanged -= OnSystemAppearanceChanged; appearanceSubscribed = false; }
            if (ownedAppIcon != null) { ownedAppIcon.Dispose(); ownedAppIcon = null; }
            if (ownedTrayIcon != null) { ownedTrayIcon.Dispose(); ownedTrayIcon = null; }
            if (appIconButton.Image != null) { appIconButton.Image.Dispose(); appIconButton.Image = null; }
            if (appearanceModeButton.Image != null) { appearanceModeButton.Image.Dispose(); appearanceModeButton.Image = null; }
            if (!appIconMenu.IsDisposed) {
                foreach (ToolStripItem item in appIconMenu.Items) if (item.Image != null) { item.Image.Dispose(); item.Image = null; }
                appIconMenu.Dispose();
            }
            appearanceTips.Dispose();
        }
    }
}
