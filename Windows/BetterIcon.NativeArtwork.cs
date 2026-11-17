// Version 1.0.0: native image-list upload preserving straight ARGB edges.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
namespace BetterIcon.Tray {
 public static class NativeArtwork {
  [StructLayout(LayoutKind.Sequential)] struct Header { public uint Size;public int Width,Height;public ushort Planes,Bits;public uint Compression,ImageSize;public int Xppm,Yppm;public uint Colors,Important; }
  [DllImport("comctl32.dll")] static extern IntPtr ImageList_Create(int width,int height,uint flags,int initial,int grow);
  [DllImport("comctl32.dll")] static extern int ImageList_Add(IntPtr list,IntPtr bitmap,IntPtr mask);
  [DllImport("comctl32.dll")] static extern bool ImageList_Destroy(IntPtr list);
  [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc,ref Header info,uint usage,out IntPtr bits,IntPtr section,uint offset);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr bitmap);
  public static IntPtr Create(IList<Bitmap> artwork,int size) {
   if(artwork==null)throw new ArgumentNullException("artwork");
   if(size<1||size>4096)throw new ArgumentOutOfRangeException("size");
   if(artwork.Count==0)return IntPtr.Zero;
   IntPtr list=ImageList_Create(size,size,0x0021,artwork.Count,1);
   if(list==IntPtr.Zero)throw new OutOfMemoryException("Windows could not allocate the icon artwork.");
   bool complete=false;
   try {
    foreach(Bitmap source in artwork)using(Bitmap scaled=new Bitmap(size,size,PixelFormat.Format32bppArgb)) {
     using(Graphics canvas=Graphics.FromImage(scaled)) {
      canvas.Clear(Color.Transparent);canvas.InterpolationMode=InterpolationMode.HighQualityBicubic;
      canvas.DrawImage(source,new Rectangle(0,0,size,size));
     }
     Add(list,scaled);
    }
    complete=true;return list;
   }finally{if(!complete)ImageList_Destroy(list);}
  }
  static void Add(IntPtr list,Bitmap image) {
   Header header=new Header{Size=40,Width=image.Width,Height=-image.Height,Planes=1,Bits=32,ImageSize=checked((uint)(image.Width*image.Height*4))};
   IntPtr bits;IntPtr bitmap=CreateDIBSection(IntPtr.Zero,ref header,0,out bits,IntPtr.Zero,0);
   if(bitmap==IntPtr.Zero)throw new OutOfMemoryException("Windows could not allocate the icon bitmap.");
   try {
    Rectangle bounds=new Rectangle(0,0,image.Width,image.Height);
    BitmapData data=image.LockBits(bounds,ImageLockMode.ReadOnly,PixelFormat.Format32bppArgb);
    try {
     int length=checked(image.Width*4);byte[] row=new byte[length];
     for(int y=0;y<image.Height;y++) {
      Marshal.Copy(IntPtr.Add(data.Scan0,y*data.Stride),row,0,length);
      Marshal.Copy(row,0,IntPtr.Add(bits,y*length),length);
     }
    }finally{image.UnlockBits(data);}
    // ImageList_Add converts straight BGRA into its own internal alpha format.
    // GetHbitmap/managed Images.Add lightens edges; premultiplying twice or
    // uploading through GetHicon darkens them. Keep the native DIB bytes straight.
    if(ImageList_Add(list,bitmap,IntPtr.Zero)<0)throw new OutOfMemoryException("Windows could not load the icon bitmap.");
   }finally{DeleteObject(bitmap);}
  }
 }
}
