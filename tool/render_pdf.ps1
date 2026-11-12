param([string]$Pdf='build/urdu-statement.pdf',[string]$Output='build/urdu-pdf-preview.png')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$root=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dll=Join-Path $root 'build/windows/x64/runner/Release/pdfium.dll'
$code=@'
using System;
using System.Runtime.InteropServices;
public static class KhataPdfRaster {
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDF_InitLibrary();
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr FPDF_LoadDocument(string path,string password);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr FPDF_LoadPage(IntPtr doc,int index);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern double FPDF_GetPageWidth(IntPtr page);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern double FPDF_GetPageHeight(IntPtr page);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr FPDFBitmap_Create(int width,int height,int alpha);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDFBitmap_FillRect(IntPtr bitmap,int left,int top,int width,int height,uint color);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDF_RenderPageBitmap(IntPtr bitmap,IntPtr page,int x,int y,int width,int height,int rotate,int flags);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr FPDFBitmap_GetBuffer(IntPtr bitmap);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern int FPDFBitmap_GetStride(IntPtr bitmap);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDFBitmap_Destroy(IntPtr bitmap);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDF_ClosePage(IntPtr page);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDF_CloseDocument(IntPtr doc);
[DllImport(@"__PDFIUM__",CallingConvention=CallingConvention.Cdecl)] public static extern void FPDF_DestroyLibrary();
}
'@
Add-Type -TypeDefinition $code.Replace('__PDFIUM__',$dll)
[KhataPdfRaster]::FPDF_InitLibrary()
$doc=[KhataPdfRaster]::FPDF_LoadDocument([System.IO.Path]::GetFullPath((Join-Path $root $Pdf)),$null)
if($doc -eq [IntPtr]::Zero){throw 'Cannot load generated PDF'}
$page=[KhataPdfRaster]::FPDF_LoadPage($doc,0)
$width=[int]([KhataPdfRaster]::FPDF_GetPageWidth($page)*2)
$height=[int]([KhataPdfRaster]::FPDF_GetPageHeight($page)*2)
$native=[KhataPdfRaster]::FPDFBitmap_Create($width,$height,1)
[KhataPdfRaster]::FPDFBitmap_FillRect($native,0,0,$width,$height,[uint32]::MaxValue)
[KhataPdfRaster]::FPDF_RenderPageBitmap($native,$page,0,0,$width,$height,0,0)
$bitmap=New-Object System.Drawing.Bitmap $width,$height,([KhataPdfRaster]::FPDFBitmap_GetStride($native)),([System.Drawing.Imaging.PixelFormat]::Format32bppArgb),([KhataPdfRaster]::FPDFBitmap_GetBuffer($native))
$bitmap.Save((Join-Path $root $Output),[System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
[KhataPdfRaster]::FPDFBitmap_Destroy($native)
[KhataPdfRaster]::FPDF_ClosePage($page)
[KhataPdfRaster]::FPDF_CloseDocument($doc)
[KhataPdfRaster]::FPDF_DestroyLibrary()
Write-Output $Output
