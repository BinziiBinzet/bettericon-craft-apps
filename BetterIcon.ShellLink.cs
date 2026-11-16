// Windows Shell interop for BetterIcon-Craft Apps. Loaded locally by PowerShell.
// Change only the icon of an existing link; never reconstruct its launch data.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace BetterIcon.Windows
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLinkObject { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int length);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetHotkey(out short value);
        void SetHotkey(short value);
        void GetShowCmd(out int value);
        void SetShowCmd(int value);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int length, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport, Guid("45E2B4AE-B1C3-11D0-B92F-00A0C90312E1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkDataList
    {
        void AddDataBlock(IntPtr block);
        [PreserveSig] int CopyDataBlock(uint signature, out IntPtr block);
        void RemoveDataBlock(uint signature);
        void GetFlags(out uint flags);
        void SetFlags(uint flags);
    }

    public sealed class LinkInfo
    {
        public string Target;
        public string Arguments;
        public string WorkingDirectory;
        public string Description;
        public string IconPath;
        public int IconIndex;
        public string InstallerIdentity;
        public string LaunchTarget;
        public string LaunchFingerprint;
    }

    public static class ShellLink
    {
        private static void CheckShellPath(string path)
        {
            // Shell link APIs can still hit MAX_PATH limits, independently of .NET's
            // long-path support. Refuse before saving instead of trusting truncation.
            if (path.Length >= 260) throw new System.IO.PathTooLongException(
                "Windows Shell shortcut/icon paths must be shorter than 260 characters. Use a shorter shortcut or state directory.");
        }

        [StructLayout(LayoutKind.Sequential)] private struct AttributeTag { public uint Attributes; public uint Tag; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, out AttributeTag info, uint size);
        [DllImport("shell32.dll")] private static extern uint ILGetSize(IntPtr idList);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint MsiGetShortcutTargetW(string path, StringBuilder product, StringBuilder feature, StringBuilder component);
        [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int MsiGetComponentPathW(string product, string component, StringBuilder path, ref uint length);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern void SHChangeNotify(uint eventId, uint flags, [MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr item2);

        public static bool IsRedirectedPath(string path)
        {
            // Cloud placeholders (Dropbox/OneDrive) are reparse points too, but do
            // not redirect names. Only name-surrogate tags indicate linked paths.
            using (SafeFileHandle handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
            {
                if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                AttributeTag info;
                if (!GetFileInformationByHandleEx(handle, 9, out info, 8))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return (info.Tag & 0x20000000) != 0;
            }
        }

        public static LinkInfo Read(string path)
        {
            CheckShellPath(path);
            object instance = new ShellLinkObject();
            try
            {
                ((IPersistFile)instance).Load(path, 0);
                IShellLinkW link = (IShellLinkW)instance;
                StringBuilder value = new StringBuilder(32768);
                LinkInfo info = new LinkInfo();
                StringBuilder product = new StringBuilder(39), feature = new StringBuilder(256), component = new StringBuilder(39);
                bool advertised = MsiGetShortcutTargetW(path, product, feature, component) == 0;
                info.InstallerIdentity = advertised ? product + "|" + feature + "|" + component : "";
                link.GetPath(value, value.Capacity, IntPtr.Zero, 4);
                info.Target = value.ToString();
                info.LaunchTarget = info.Target;
                if (advertised)
                {
                    StringBuilder executable = new StringBuilder(32768);
                    uint capacity = (uint)executable.Capacity;
                    int state = MsiGetComponentPathW(product.ToString(), component.ToString(), executable, ref capacity);
                    info.LaunchTarget = state.ToString() + ":" + executable;
                }
                value.Clear(); link.GetArguments(value, value.Capacity); info.Arguments = value.ToString();
                value.Clear(); link.GetWorkingDirectory(value, value.Capacity); info.WorkingDirectory = value.ToString();
                value.Clear(); link.GetDescription(value, value.Capacity); info.Description = value.ToString();
                value.Clear(); link.GetIconLocation(value, value.Capacity, out info.IconIndex); info.IconPath = value.ToString();
                short hotkey; int show;
                link.GetHotkey(out hotkey); link.GetShowCmd(out show);
                List<string> identity = new List<string> { info.LaunchTarget, info.Arguments, info.WorkingDirectory, info.Description, hotkey.ToString(), show.ToString() };
                IntPtr idList;
                link.GetIDList(out idList);
                if (idList != IntPtr.Zero)
                {
                    try
                    {
                        byte[] bytes = new byte[checked((int)ILGetSize(idList))];
                        Marshal.Copy(idList, bytes, 0, bytes.Length);
                        // For an advertised MSI link, the shell path/PIDL is its
                        // icon resource; the Darwin descriptor identifies launch.
                        identity.Add(advertised ? "" : Convert.ToBase64String(bytes));
                    }
                    finally { Marshal.FreeCoTaskMem(idList); }
                }
                else { identity.Add(""); }

                // Preserve installer/Darwin data, application IDs/property stores,
                // environment targets and other launch-related extra data blocks.
                IShellLinkDataList data = (IShellLinkDataList)instance;
                uint flags; data.GetFlags(out flags);
                // IPersistFile also drops a relative-path hint when a copied
                // shortcut is on a different drive. Target/PIDL (or MSI launch
                // identity) are checked independently, so this is not a launch change.
                uint normalizedFlags = 0x40u | 0x4000u | 0x8u;
                identity.Add((flags & ~normalizedFlags).ToString());
                uint[] signatures = { 0xA0000001, 0xA0000002, 0xA0000003, 0xA0000004,
                    0xA0000005, 0xA0000006, 0xA0000008, 0xA0000009, 0xA000000B, 0xA000000C };
                foreach (uint signature in signatures)
                {
                    IntPtr block;
                    if (data.CopyDataBlock(signature, out block) >= 0 && block != IntPtr.Zero)
                    {
                        try
                        {
                            int length = Marshal.ReadInt32(block);
                            if (length < 8 || length > 1048576) throw new InvalidOperationException("Invalid shortcut data block.");
                            byte[] bytes = new byte[length];
                            Marshal.Copy(block, bytes, 0, length);
                            identity.Add(signature.ToString() + ":" + Convert.ToBase64String(bytes));
                        }
                        finally { LocalFree(block); }
                    }
                }
                identity.Add(info.InstallerIdentity);
                // Length-prefix fields so embedded separators cannot hide a difference.
                StringBuilder fingerprint = new StringBuilder();
                foreach (string field in identity) fingerprint.Append(field.Length).Append(':').Append(field);
                info.LaunchFingerprint = fingerprint.ToString();
                return info;
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }

        public static void SetIcon(string path, string icon)
        {
            CheckShellPath(path);
            CheckShellPath(icon);
            object instance = new ShellLinkObject();
            try
            {
                IPersistFile file = (IPersistFile)instance;
                file.Load(path, 0);
                ((IShellLinkW)instance).SetIconLocation(icon, 0);
                file.Save(path, true);
            }
            finally { Marshal.FinalReleaseComObject(instance); }
        }

        public static void Notify(string path)
        {
            // SHCNE_UPDATEITEM, SHCNF_PATHW | SHCNF_FLUSH. Never kill Explorer.
            SHChangeNotify(0x2000, 0x2005, path, IntPtr.Zero);
        }
    }
}
