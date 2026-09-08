#requires -Version 7.0

function Update-WindowsThumbnailCache {
    <#
    .SYNOPSIS
    Recursively populates the current user's Windows thumbnail cache in parallel.
    .DESCRIPTION
    Streams all files, including hidden files, through persistent native COM workers.
    Windows' registered thumbnail providers determine support; no extension allowlist
    silently excludes files. Directory junctions/symlinks are not traversed.
    -Force re-extracts from source even when a thumbnail is already cached.
    Without -Force, Windows reuses cached thumbnails and extracts missing ones.
    The function requests reads of source files and writes to Windows' thumbnail cache.
    Windows controls provider timeouts; native calls already in progress can finish
    after Ctrl+C. No application, Explorer, or shared COM process is terminated.
    Returns a summary with a Failures array; -FailureLog optionally exports that array.
    .NOTES
    Safe to dot-source from the PowerShell profile: importing this file only defines
    the function. Native compilation, enumeration, and worker creation are deferred
    until Update-WindowsThumbnailCache is explicitly invoked.
    .LINK
    https://learn.microsoft.com/en-us/windows/win32/api/thumbcache/nf-thumbcache-ithumbnailcache-getthumbnail
    .EXAMPLE
    $result = Update-WindowsThumbnailCache -Path 'D:\Review' -ThrottleLimit 8 -Force
    $result.Failures | Format-Table Path, Stage, HResult, Message -Wrap
    .EXAMPLE
    Update-WindowsThumbnailCache -Path 'D:\Review' -ThrottleLimit 4 -Size 256 -FailureLog 'D:\Reports\thumbnail-failures.csv'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [Alias('LiteralPath')]
        [string] $Path,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = [Math]::Min(8, [Environment]::ProcessorCount),

        [ValidateRange(32, 1024)]
        [int] $Size = 256,

        [switch] $Force,

        [string] $FailureLog
    )

    if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
        throw 'Run this function in 64-bit PowerShell 7 on Windows.'
    }
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($root.PSProvider.Name -ne 'FileSystem' -or -not $root.PSIsContainer) {
        throw 'Path must be an existing filesystem folder.'
    }
    $logPath = $null
    if ($FailureLog) {
        $logPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FailureLog)
        if (Test-Path -LiteralPath $logPath) { throw "FailureLog already exists: $logPath" }
        if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($logPath))) {
            throw 'The FailureLog parent folder must already exist.'
        }
    }

    if (-not ('WindowsThumbnailWarmupV1.Job' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace WindowsThumbnailWarmupV1
{
    [ComImport, Guid("F676C15D-596A-4CE2-8234-33996F445DB1"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IThumbnailCache
    {
        [PreserveSig]
        int GetThumbnail(IntPtr item, uint size, uint flags,
            out IntPtr bitmap, out uint cacheFlags, out Guid thumbnailId);
        [PreserveSig]
        int GetThumbnailByID(Guid thumbnailId, uint size,
            out IntPtr bitmap, out uint cacheFlags);
    }

    internal static class Native
    {
        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern int CoInitializeEx(IntPtr reserved, uint flags);
        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern void CoUninitialize();
        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern int CoCreateInstance(ref Guid clsid, IntPtr outer,
            uint context, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IThumbnailCache cache);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        internal static extern int SHCreateItemFromParsingName(string path,
            IntPtr bindContext, ref Guid iid, out IntPtr item);

        internal static string ErrorText(int hr)
        {
            switch (unchecked((uint)hr))
            {
                case 0x8004B200: return "Thumbnail extraction failed; support or decodability is not established.";
                case 0x8004B201: return "Windows thumbnail extraction timed out.";
                case 0x8004B202: return "Windows thumbnail surrogate unavailable.";
                default:
                    Exception e = Marshal.GetExceptionForHR(hr);
                    return e == null ? "No thumbnail returned." : e.Message;
            }
        }
    }

    public sealed class Failure
    {
        public string Path { get; set; }
        public string Stage { get; set; }
        public string HResult { get; set; }
        public string Message { get; set; }
    }

    public sealed class Job
    {
        readonly string root;
        readonly uint size, flags;
        readonly BlockingCollection<string> pending;
        readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        readonly ConcurrentQueue<Failure> errors = new ConcurrentQueue<Failure>();
        int remaining;
        long discovered, processed, succeeded, failed, enumerationErrors, workerErrors, skippedDirectories;

        public long Discovered { get { return Interlocked.Read(ref discovered); } }
        public long Processed { get { return Interlocked.Read(ref processed); } }
        public long Succeeded { get { return Interlocked.Read(ref succeeded); } }
        public long Failed { get { return Interlocked.Read(ref failed); } }
        public long EnumerationErrors { get { return Interlocked.Read(ref enumerationErrors); } }
        public long WorkerErrors { get { return Interlocked.Read(ref workerErrors); } }
        public long SkippedReparseDirectories { get { return Interlocked.Read(ref skippedDirectories); } }
        public bool Complete { get { return Volatile.Read(ref remaining) == 0; } }
        public bool Cancelled { get { return cancellation.IsCancellationRequested; } }
        public Failure[] Failures { get { return errors.ToArray(); } }

        // mode: 0 = use cache/extract missing; 4 = force extraction; 1 = cache-only
        // Cache-only is exposed here solely to allow independent cache verification.
        public Job(string root, int size, int workers, uint mode)
        {
            this.root = root;
            this.size = (uint)size;
            flags = mode;
            pending = new BlockingCollection<string>(workers * 32);
            remaining = workers + 1;
            for (int i = 0; i < workers; i++)
            {
                Thread worker = new Thread(Work);
                worker.IsBackground = true;
                worker.Name = "Windows thumbnail worker";
                worker.SetApartmentState(ApartmentState.MTA);
                worker.Start();
            }
            Thread producer = new Thread(Enumerate);
            producer.IsBackground = true;
            producer.Name = "Windows thumbnail enumeration";
            producer.Start();
        }

        public void Cancel() { cancellation.Cancel(); }

        void Record(string path, string stage, int hr, string message)
        {
            errors.Enqueue(new Failure { Path = path, Stage = stage,
                HResult = "0x" + unchecked((uint)hr).ToString("X8"), Message = message });
        }

        void Enumerate()
        {
            try
            {
                Stack<string> dirs = new Stack<string>();
                dirs.Push(root);
                while (dirs.Count != 0)
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    string dir = dirs.Pop();
                    try
                    {
                        foreach (string entry in Directory.EnumerateFileSystemEntries(dir))
                        {
                            cancellation.Token.ThrowIfCancellationRequested();
                            FileAttributes attributes;
                            try { attributes = File.GetAttributes(entry); }
                            catch (Exception ex)
                            {
                                Interlocked.Increment(ref enumerationErrors);
                                Record(entry, "Enumerate", ex.HResult, ex.Message);
                                continue;
                            }
                            if ((attributes & FileAttributes.Directory) != 0)
                            {
                                if ((attributes & FileAttributes.ReparsePoint) != 0)
                                    Interlocked.Increment(ref skippedDirectories);
                                else dirs.Push(entry);
                            }
                            else
                            {
                                pending.Add(entry, cancellation.Token);
                                Interlocked.Increment(ref discovered);
                            }
                        }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex)
                    {
                        Interlocked.Increment(ref enumerationErrors);
                        Record(dir, "Enumerate", ex.HResult, ex.Message);
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Interlocked.Increment(ref enumerationErrors);
                Record(root, "Enumerate", ex.HResult, ex.Message);
                cancellation.Cancel();
            }
            finally
            {
                pending.CompleteAdding();
                Interlocked.Decrement(ref remaining);
            }
        }

        void Work()
        {
            bool initialized = false;
            IThumbnailCache cache = null;
            try
            {
                int hr = Native.CoInitializeEx(IntPtr.Zero, 0);
                Marshal.ThrowExceptionForHR(hr);
                initialized = true;
                Guid clsid = new Guid("50EF4544-AC9F-4A8E-B21B-8A26180DB13F");
                Guid iid = typeof(IThumbnailCache).GUID;
                Marshal.ThrowExceptionForHR(Native.CoCreateInstance(ref clsid,
                    IntPtr.Zero, 1, ref iid, out cache));
                Guid shellIID = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");

                foreach (string path in pending.GetConsumingEnumerable(cancellation.Token))
                {
                    IntPtr item = IntPtr.Zero, bitmap = IntPtr.Zero;
                    string stage = "ShellItem";
                    try
                    {
                        hr = Native.SHCreateItemFromParsingName(path, IntPtr.Zero,
                            ref shellIID, out item);
                        if (hr >= 0 && item != IntPtr.Zero)
                        {
                            stage = "Thumbnail";
                            uint cacheFlags;
                            Guid thumbnailId;
                            hr = cache.GetThumbnail(item, size, flags,
                                out bitmap, out cacheFlags, out thumbnailId);
                        }
                        if (hr >= 0 && bitmap != IntPtr.Zero)
                            Interlocked.Increment(ref succeeded);
                        else
                        {
                            Interlocked.Increment(ref failed);
                            Record(path, stage, hr, Native.ErrorText(hr));
                        }
                    }
                    catch (Exception ex)
                    {
                        Interlocked.Increment(ref failed);
                        Record(path, stage, ex.HResult, ex.Message);
                    }
                    finally
                    {
                        if (bitmap != IntPtr.Zero) Marshal.Release(bitmap);
                        if (item != IntPtr.Zero) Marshal.Release(item);
                        Interlocked.Increment(ref processed);
                    }
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                Interlocked.Increment(ref workerErrors);
                Record(root, "Worker", ex.HResult, ex.Message);
                cancellation.Cancel();
            }
            finally
            {
                try { if (cache != null) Marshal.ReleaseComObject(cache); }
                finally
                {
                    if (initialized) Native.CoUninitialize();
                    Interlocked.Decrement(ref remaining);
                }
            }
        }
    }
}
'@ -ErrorAction Stop
    }

    $mode = if ($Force) { [uint32]4 } else { [uint32]0 }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $job = [WindowsThumbnailWarmupV1.Job]::new($root.FullName, $Size, $ThrottleLimit, $mode)
    try {
        while (-not $job.Complete) {
            Write-Progress -Activity 'Generating Windows thumbnails' -Status (
                '{0} processed / {1} discovered; {2} succeeded; {3} failed' -f
                $job.Processed, $job.Discovered, $job.Succeeded, $job.Failed
            )
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        if (-not $job.Complete) { $job.Cancel() }
        $timer.Stop()
        Write-Progress -Activity 'Generating Windows thumbnails' -Completed
    }

    $failureRecords = $job.Failures
    if ($logPath) {
        if ($failureRecords.Count) {
            $failureRecords | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding utf8 -NoClobber -ErrorAction Stop
        }
        else {
            # A header-only report explicitly records that the failure list was empty.
            $stream = [IO.File]::Open($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try { $writer.WriteLine('"Path","Stage","HResult","Message"') }
            finally { $writer.Dispose() }
        }
    }
    if ($job.WorkerErrors -or $job.EnumerationErrors) {
        Write-Warning 'Coverage was incomplete. Inspect Failures for enumeration or worker errors.'
    }

    [pscustomobject]@{
        Path = $root.FullName
        Mode = if ($Force) { 'ForceExtraction' } else { 'ExtractMissing' }
        Size = $Size
        Workers = $ThrottleLimit
        Discovered = $job.Discovered
        Processed = $job.Processed
        Succeeded = $job.Succeeded
        Failed = $job.Failed
        EnumerationErrors = $job.EnumerationErrors
        WorkerErrors = $job.WorkerErrors
        SkippedReparseDirectories = $job.SkippedReparseDirectories
        Cancelled = $job.Cancelled
        ElapsedSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        FilesPerSecond = [Math]::Round($job.Processed / [Math]::Max(0.001, $timer.Elapsed.TotalSeconds), 1)
        FailureLog = $logPath
        Failures = $failureRecords
    }
}
