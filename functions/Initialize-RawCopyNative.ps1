function Initialize-RawCopyNative {
    <# .SYNOPSIS
    Loads the minimal Win32 interop used by Invoke-RawCopy; opens no handles itself.
    #>
    [CmdletBinding()]
    param()
    if('ProfileRawCopy.Native' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ProfileRawCopy {
    public sealed class RetrievalResult {
        public byte[] Buffer;
        public bool More;
        public bool Resident;
    }
    public static class Native {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool DeviceIoControl(SafeFileHandle file, uint code, byte[] input, int inputLength, byte[] output, int outputLength, out int returned, IntPtr overlapped);
        public static SafeFileHandle OpenVolume(string path) {
            var handle=CreateFileW(path, 0x80000000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
            return handle;
        }
        public static RetrievalResult Retrieve(SafeFileHandle file, long startingVcn) {
            var output=new byte[65536];
            bool ok=DeviceIoControl(file, 0x90073, BitConverter.GetBytes(startingVcn), 8, output, output.Length, out int returned, IntPtr.Zero);
            int error=ok ? 0 : Marshal.GetLastWin32Error();
            if(error==38 && startingVcn==0) return new RetrievalResult { Buffer=Array.Empty<byte>(),Resident=true };
            if(!ok && error!=234) throw new Win32Exception(error);
            if(returned<16 || returned>output.Length) throw new InvalidOperationException("Invalid retrieval-pointer byte count.");
            Array.Resize(ref output,returned);
            return new RetrievalResult { Buffer=output,More=!ok };
        }
    }
}
'@ -ErrorAction Stop
}
