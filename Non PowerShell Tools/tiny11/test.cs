using System;
        using System.Runtime.InteropServices;
        
        public class NativeMethods
        {
            public const uint GENERIC_READ = 0x80000000;
            public const uint GENERIC_WRITE = 0x40000000;
            public const uint FILE_SHARE_READ = 1;
            public const uint FILE_SHARE_WRITE = 2;
            public const uint OPEN_EXISTING = 3;
            public const uint CREATE_NEW = 1;
            public const uint FILE_ATTRIBUTE_NORMAL = 0x80;
            public const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
        
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern IntPtr CreateFile(
                string lpFileName,
                uint dwDesiredAccess,
                uint dwShareMode,
                IntPtr lpSecurityAttributes,
                uint dwCreationDisposition,
                uint dwFlagsAndAttributes,
                IntPtr hTemplateFile);
        
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool ReadFile(
                IntPtr hFile,
                byte[] lpBuffer,
                uint nNumberOfBytesToRead,
                out uint lpNumberOfBytesRead,
                IntPtr lpOverlapped);
        
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool WriteFile(
                IntPtr hFile,
                byte[] lpBuffer,
                uint nNumberOfBytesToWrite,
                out uint lpNumberOfBytesWritten,
                IntPtr lpOverlapped);
        
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool CloseHandle(IntPtr hObject);
        }