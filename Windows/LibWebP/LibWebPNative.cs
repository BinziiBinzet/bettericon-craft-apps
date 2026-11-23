// P/Invoke declarations and helpers for testing libwebpdecoder.dll from
// Windows PowerShell 5.1 (Add-Type, C# 5). Test-LibWebP.ps1 loads the DLL by
// full path with LoadLibraryW first, so the DllImport by file name below binds
// to exactly that module.
//
// libwebp exports plain C functions with the default cdecl convention, so every
// import says CallingConvention.Cdecl (this matters for the 32-bit DLL).

using System;
using System.Runtime.InteropServices;
using System.Text;

namespace BetterIconLibWebPTest
{
    // struct WebPBitstreamFeatures from src/webp/decode.h (libwebp 1.6.0): 40 bytes.
    [StructLayout(LayoutKind.Sequential)]
    public struct WebPBitstreamFeatures
    {
        public int Width;
        public int Height;
        public int HasAlpha;
        public int HasAnimation;
        public int Format;        // 0 undefined/mixed, 1 lossy, 2 lossless
        public uint Pad0;
        public uint Pad1;
        public uint Pad2;
        public uint Pad3;
        public uint Pad4;
    }

    public static class Native
    {
        public const string Dll = "libwebpdecoder.dll";

        // WEBP_DECODER_ABI_VERSION in src/webp/decode.h. WebPGetFeatures() is an
        // inline wrapper in that header that passes this value.
        public const int DecoderAbiVersion = 0x0210;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        public static extern IntPtr LoadLibraryW(string fileName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        public static extern uint GetModuleFileNameW(IntPtr module, StringBuilder fileName, uint size);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int WebPGetDecoderVersion();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int WebPGetInfo(byte[] data, UIntPtr dataSize, out int width, out int height);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int WebPGetFeaturesInternal(byte[] data, UIntPtr dataSize, ref WebPBitstreamFeatures features, int version);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern IntPtr WebPDecodeRGBAInto(byte[] data, UIntPtr dataSize, IntPtr output, UIntPtr outputSize, int outputStride);
    }

    public sealed class DecodeOutcome
    {
        public bool Returned;        // WebPDecodeRGBAInto returned non-NULL
        public bool ReturnedBuffer;  // ... and the value was the output buffer
        public byte[] Buffer;        // the whole output buffer after the call
    }

    public static class Harness
    {
        public static string ModulePath(IntPtr module)
        {
            StringBuilder sb = new StringBuilder(32768);
            uint n = Native.GetModuleFileNameW(module, sb, (uint)sb.Capacity);
            return n == 0 ? null : sb.ToString(0, (int)n);
        }

        public static int GetInfo(byte[] data, out int width, out int height)
        {
            return Native.WebPGetInfo(data, new UIntPtr((uint)data.Length), out width, out height);
        }

        public static WebPBitstreamFeatures GetFeatures(byte[] data, out int status)
        {
            WebPBitstreamFeatures f = new WebPBitstreamFeatures();
            status = Native.WebPGetFeaturesInternal(data, new UIntPtr((uint)data.Length), ref f, Native.DecoderAbiVersion);
            return f;
        }

        // Decodes into a pinned buffer of bufferSize bytes that is first filled with 'fill'.
        public static DecodeOutcome Decode(byte[] data, int stride, int bufferSize, byte fill)
        {
            byte[] buffer = new byte[bufferSize];
            for (int i = 0; i < buffer.Length; i++) buffer[i] = fill;
            GCHandle handle = GCHandle.Alloc(buffer, GCHandleType.Pinned);
            try
            {
                IntPtr p = handle.AddrOfPinnedObject();
                IntPtr r = Native.WebPDecodeRGBAInto(data, new UIntPtr((uint)data.Length), p,
                                                     new UIntPtr((uint)bufferSize), stride);
                DecodeOutcome o = new DecodeOutcome();
                o.Returned = r != IntPtr.Zero;
                o.ReturnedBuffer = r == p;
                o.Buffer = buffer;
                return o;
            }
            finally
            {
                handle.Free();
            }
        }

        // Compares the first width*4 bytes of each row of 'actual' (rows 'stride'
        // bytes apart) with the tightly packed 'expected'.
        // Returns { differing bytes, differing pixels, largest channel difference, first differing byte index or -1 }.
        public static int[] Compare(byte[] actual, int stride, byte[] expected, int width, int height)
        {
            int diffBytes = 0, diffPixels = 0, maxDiff = 0, firstDiff = -1;
            int row = width * 4;
            for (int y = 0; y < height; y++)
            {
                for (int x = 0; x < width; x++)
                {
                    bool pixelDiffers = false;
                    for (int c = 0; c < 4; c++)
                    {
                        int a = actual[y * stride + x * 4 + c];
                        int e = expected[y * row + x * 4 + c];
                        int d = a > e ? a - e : e - a;
                        if (d != 0)
                        {
                            diffBytes++;
                            pixelDiffers = true;
                            if (d > maxDiff) maxDiff = d;
                            if (firstDiff < 0) firstDiff = y * row + x * 4 + c;
                        }
                    }
                    if (pixelDiffers) diffPixels++;
                }
            }
            return new int[] { diffBytes, diffPixels, maxDiff, firstDiff };
        }

        // Counts bytes beyond width*4 in each row (the stride padding) that no longer hold 'fill'.
        public static int PaddingTouched(byte[] actual, int stride, int width, int height, byte fill)
        {
            int touched = 0;
            for (int y = 0; y < height; y++)
                for (int i = width * 4; i < stride; i++)
                    if (actual[y * stride + i] != fill) touched++;
            return touched;
        }

        // Counts pixels whose alpha is above 0 (visible) or equal to 255 (opaque).
        public static int CountAlpha(byte[] rgba, int stride, int width, int height, bool opaqueOnly)
        {
            int n = 0;
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                {
                    byte a = rgba[y * stride + x * 4 + 3];
                    if (opaqueOnly ? a == 255 : a > 0) n++;
                }
            return n;
        }

        public static byte[] Pixel(byte[] rgba, int stride, int x, int y)
        {
            byte[] p = new byte[4];
            Array.Copy(rgba, y * stride + x * 4, p, 0, 4);
            return p;
        }
    }
}
