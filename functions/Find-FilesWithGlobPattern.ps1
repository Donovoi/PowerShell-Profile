function Find-FilesWithGlobPattern {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$GlobPattern
    )

    # Load the required native libraries
    Add-Type -TypeDefinition @'
    using System;
    using System.Collections.Concurrent;
    using System.Collections.Generic;
    using System.IO;
    using System.Runtime.Intrinsics;
    using System.Runtime.Intrinsics.X86;
    using System.Threading.Tasks;
    
    namespace simd
    {
        namespace simd
        {
            public class SIMDFileSearch
            {
                public static List<string> FindFilesWithGlobPattern(string path, string globPattern)
                {
                    List<string> matchingFiles = new List<string>();
    
                    try
                    {
                        var entries = Directory.EnumerateFileSystemEntries(path, "*", SearchOption.AllDirectories);
    
                        // Prepare the pattern for search
                        byte[] pattern = new byte[16];
                        for (int i = 0; i < globPattern.Length; i++)
                        {
                            if (globPattern[i] == '*')
                                pattern[i % 16] = 0;
                            else
                                pattern[i % 16] = (byte)globPattern[i];
                        }
    
                        // Create a vector from the pattern
                        Vector128<byte> patternVector = Vector128<byte>.Zero;
                        for (int i = 0; i < 16; i++)
                        {
                            patternVector = Vector128.WithElement(patternVector, i, pattern[i]);
                        }
    
                        // Concurrent collection to store the matching files
                        var matchingFilesCollection = new ConcurrentBag<string>();
    
                        // Create tasks for searching files concurrently
                        var tasks = new List<Task>();
                        foreach (var entry in entries)
                        {
                            if (File.Exists(entry))
                            {
                                tasks.Add(Task.Run(() =>
                                {
                                    if (SearchFileWithSIMD(entry, patternVector))
                                        matchingFilesCollection.Add(entry);
                                }));
                            }
                        }
    
                        // Wait for all tasks to complete
                        Task.WaitAll(tasks.ToArray());
    
                        // Convert concurrent bag to list
                        matchingFiles = new List<string>(matchingFilesCollection);
                    }
                    catch (UnauthorizedAccessException)
                    {
                        // Ignore unauthorized access exceptions and continue the search
                    }
    
                    return matchingFiles;
                }
    
                private static bool SearchFileWithSIMD(string filePath, Vector128<byte> pattern)
                {
                    try
                    {
                        using FileStream stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                        int fileSize = (int)stream.Length;
                        byte[] buffer = new byte[fileSize];
                        stream.Read(buffer, 0, fileSize);
    
                        return SearchBufferWithSIMD(buffer, pattern);
                    }
                    catch (UnauthorizedAccessException)
                    {
                        // Ignore unauthorized access exceptions and continue the search
                    }
    
                    return false;
                }
    
                private static bool SearchBufferWithSIMD(byte[] buffer, Vector128<byte> pattern)
                {
                    int bufferLength = buffer.Length;
    
                    int searchLength = bufferLength - 15;
    
                    for (int i = 0; i < searchLength; i += 16)
                    {
                        Vector128<byte> data = Vector128<byte>.Zero;
                        for (int j = 0; j < 16; j++)
                        {
                            data = Vector128.WithElement(data, j, buffer[i + j]);
                        }
    
                        var result = Sse2.CompareEqual(data, pattern);
                        if (Sse2.MoveMask(result) != 0)
                            return true;
                    }
    
                    return false;
                }
            }
        }
    }
'@
    
    # Invoke the native method to search for the file
    $result = [SIMDFileSearch]::FindFileWithGlobPattern($Path, $GlobPattern)

    if ($result) {
        return $result
    }
    else {
        Write-Host 'No matching file found.'
    }
}