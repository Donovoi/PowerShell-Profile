
# Main function to handle screen recording
function Invoke-ScreenRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$OutputPath
    )
    # Function to download and extract NuGet package

    # Import the required cmdlets
    $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }

    # Load Silk.NET assemblies
    try {
        Install-Dependencies -NugetPackage @{
            'Silk.NET.Core'       = '2.21.0'
            'Silk.NET.Direct3D11' = '2.21.0'
            'Silk.NET.Maths'      = '2.21.0'
            'Silk.NET.Windowing'  = '2.21.0'
        } -NoPSModules
    }
    catch {
        Write-Warning "Failed to load Silk.NET assemblies: $_"
    }

    # Define the P/Invoke signatures for GDI
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;

public class GDI32
{
    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hdcDest, int nXDest, int nYDest, int nWidth, int nHeight, IntPtr hdcSrc, int nXSrc, int nYSrc, int dwRop);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int nWidth, int nHeight);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowDC(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool ReleaseDC(IntPtr hwnd, IntPtr hdc);
}
'@

    # Define the P/Invoke signatures for DirectX using Silk.NET
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Silk.NET.Core.Native;
using Silk.NET.Direct3D11;
using Silk.NET.Maths;
using Silk.NET.Windowing.Common;
using Silk.NET.Windowing.Desktop;

public class ScreenCapture
{
    private Silk.NET.Direct3D11.Device device;
    private Silk.NET.Direct3D11.ID3D11DeviceContext deviceContext;
    private IDXGIOutputDuplication duplicatedOutput;
    private D3D11_TEXTURE2D_DESC textureDesc;

    public ScreenCapture()
    {
        Initialize();
    }

    private void Initialize()
    {
        // Create the Direct3D device
        D3D11CreateDevice(null, D3D_DRIVER_TYPE.D3D_DRIVER_TYPE_HARDWARE, null, (uint)D3D11_CREATE_DEVICE_FLAG.D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, out device, null, out deviceContext);

        // Get the output device (the monitor)
        IDXGIFactory1 factory;
        CreateDXGIFactory1(out factory);
        IDXGIAdapter1 adapter;
        factory.EnumAdapters1(0, out adapter);
        IDXGIOutput output;
        adapter.EnumOutputs(0, out output);
        IDXGIOutput1 output1 = (IDXGIOutput1)output;
        
        textureDesc = new D3D11_TEXTURE2D_DESC
        {
            Width = output1.GetDesc().DesktopCoordinates.Right - output1.GetDesc().DesktopCoordinates.Left,
            Height = output1.GetDesc().DesktopCoordinates.Bottom - output1.GetDesc().DesktopCoordinates.Top,
            MipLevels = 1,
            ArraySize = 1,
            Format = Silk.NET.DXGI.DXGI_FORMAT.DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc = new Silk.NET.DXGI.DXGI_SAMPLE_DESC { Count = 1, Quality = 0 },
            Usage = D3D11_USAGE.D3D11_USAGE_STAGING,
            BindFlags = 0,
            CPUAccessFlags = (uint)D3D11_CPU_ACCESS_FLAG.D3D11_CPU_ACCESS_READ,
            MiscFlags = 0
        };

        // Create the duplicated output
        output1.DuplicateOutput(device, out duplicatedOutput);
    }

    public void CaptureScreen(string filePath)
    {
        // Capture the screen
        IDXGIResource screenResource;
        DXGI_OUTDUPL_FRAME_INFO frameInfo;

        duplicatedOutput.AcquireNextFrame(1000, out frameInfo, out screenResource);
        ID3D11Texture2D screenTexture = (ID3D11Texture2D)screenResource;

        // Copy the resource into memory that can be accessed by the CPU
        ID3D11Texture2D screenTextureCopy;
        device.CreateTexture2D(ref textureDesc, null, out screenTextureCopy);
        deviceContext.CopyResource(screenTexture, screenTextureCopy);

        // Get the desktop capture texture
        D3D11_MAPPED_SUBRESOURCE mapSource;
        deviceContext.Map(screenTextureCopy, 0, D3D11_MAP.D3D11_MAP_READ, 0, out mapSource);

        // Create a Drawing.Bitmap
        var bitmap = new Bitmap(textureDesc.Width, textureDesc.Height, PixelFormat.Format32bppArgb);
        var boundsRect = new Rectangle(0, 0, textureDesc.Width, textureDesc.Height);

        // Copy pixels from screen capture Texture to GDI bitmap
        var mapDest = bitmap.LockBits(boundsRect, ImageLockMode.WriteOnly, bitmap.PixelFormat);
        var sourcePtr = mapSource.PData;
        var destPtr = mapDest.Scan0;

        for (int y = 0; y < textureDesc.Height; y++)
        {
            // Copy a single line
            Utilities.CopyMemory(destPtr, sourcePtr, textureDesc.Width * 4);

            // Advance pointers
            sourcePtr = IntPtr.Add(sourcePtr, mapSource.RowPitch);
            destPtr = IntPtr.Add(destPtr, mapDest.Stride);
        }

        // Unlock the bits
        bitmap.UnlockBits(mapDest);
        deviceContext.Unmap(screenTextureCopy, 0);

        // Save the bitmap to a file
        bitmap.Save(filePath, ImageFormat.Png);

        // Clean up
        screenTextureCopy.Dispose();
        bitmap.Dispose();
        screenResource.Dispose();
        duplicatedOutput.ReleaseFrame();
    }
}
'@ -ReferencedAssemblies 'Silk.NET.Core.dll', 'Silk.NET.Direct3D11.dll', 'Silk.NET.Maths.dll', 'Silk.NET.Windowing.dll'

    # Function to capture screen using GDI
    function Invoke-ScreenCaptureGDI {
        try {
            $desktopWnd = [GDI32]::GetDesktopWindow()
            $desktopDC = [GDI32]::GetWindowDC($desktopWnd)
            $memDC = [GDI32]::CreateCompatibleDC($desktopDC)
            $width = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
            $height = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height
            $hBitmap = [GDI32]::CreateCompatibleBitmap($desktopDC, $width, $height)
            [GDI32]::SelectObject($memDC, $hBitmap)
            if (-not [GDI32]::BitBlt($memDC, 0, 0, $width, $height, $desktopDC, 0, 0, 0x00CC0020)) {
                throw 'BitBlt operation failed.'
            }
            [GDI32]::ReleaseDC($desktopWnd, $desktopDC)
            [GDI32]::DeleteDC($memDC)
        
            $bmp = [System.Drawing.Bitmap]::FromHbitmap($hBitmap)
            [GDI32]::DeleteObject($hBitmap)

            return $bmp
        }
        catch {
            Write-Error "Error capturing screen: $_"
            throw
        }
    }

    try {
        $osVersion = [System.Environment]::OSVersion.Version
        $useGPU = $false

        # Check if OS is Windows 8 or newer and if GPU is supported
        if ($osVersion.Major -gt 6 -or ($osVersion.Major -eq 6 -and $osVersion.Minor -ge 2)) {
            try {
                $screenCapture = [ScreenCapture]::new()
                $useGPU = $true
            }
            catch {
                Write-Warning "Failed to initialize GPU-based screen capture: $_. Falling back to GDI."
            }
        }

        if ($useGPU) {
            $screenCapture.CaptureScreen($OutputPath)
        }
        else {
            $screenshot = Invoke-ScreenCaptureGDI
            if (-not $screenshot) {
                throw 'Failed to capture screenshot.'
            }
            $screenshot.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $screenshot.Dispose()
        }

        Write-Output "Screenshot saved to $OutputPath"
    }
    catch {
        Write-Error "Failed to capture and save screenshot: $_"
        throw
    }
}