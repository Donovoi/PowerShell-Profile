<#
.SYNOPSIS
    This powershell cmdlet will search the drive for index.dat files that are from internet explorer normally found in $ENV:USERPROFILE\AppData\Local\Microsoft\Windows\Temporary Internet Files\Content.IE5
    But will search the entire drive for index.dat files, and check the header of the file to make sure it is a valid index.dat file.
    the header is "Client UrlCache MMF Ver 5.2" or in hex it is 436C69656E742055726C4361636865204D4D462056657220352E32
    If the header is not found then the file is not a valid index.dat file and will be skipped.
    Once all valid index.dat files have been found and their full paths into an in memory array, the function will then loop through the array and parse the index.dat file for the data.
    
    each record has a header that is structured like:

typedef struct _RECORD_HEADER {
  /* 000 */ char        Signature[4];
  /* 004 */ uint32_t    NumberOfBlocksInRecord;
} RECORD_HEADER;

There is only 4 types of records that are used in the index.dat file. They are:
URL
REDR
HASH
LEAK

URL records are the most common and are used to store the url and the file name of the cached file.
REDR records are used to store the redirect url and the file name of the cached file.
HASH records are used to store the hash of the url and the file name of the cached file.
LEAK records are used to store the file name of the cached file.

The URL record header is structured like:

    typedef struct _URL_RECORD_HEADER {
  /* 000 */ char        Signature[4];
  /* 004 */ uint32_t    AmountOfBlocksInRecord;
  /* 008 */ FILETIME    LastModified;
  /* 010 */ FILETIME    LastAccessed;
  /* 018 */ FATTIME     Expires;
  /* 01c */
  // Not finished yet
} URL_RECORD_HEADER;

typedef struct _FILETIME {
  /* 000 */ uint32_t    lower;
  /* 004 */ uint32_t    upper;
} FILETIME;

typedef struct _FATTIME {
  /* 000 */ uint16_t    date;
  /* 002 */ uint16_t    time;
} FATTIME;

The only record type we are interested at the momemnt is the URL record type.
We will parse the URL record type and extract the url, the file name, the last modified date, the last accessed date, and the expires date.
if the url is not unique then we will count and show how many times the url is found within the index.dat files.

So the output will be a csv with the following columns:
file Path
url
count
last modified
last accessed
expires

#>

function Parse-IndexDat {
    param (
        [Parameter(Mandatory=$false)][string]$FolderPath
    )

    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi, Pack = 1)]
        public struct URL_RECORD_HEADER {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 4)]
            public string Signature;
            public UInt32 AmountOfBlocksInRecord;
            public long LastModified;
            public long LastAccessed;
            public UInt64 Expires;
        }
"@

    $fileStream = [System.IO.File]::OpenRead($filePath)
    $binaryReader = New-Object System.IO.BinaryReader($fileStream)
    $results = @()

    try {
        while ($fileStream.Position -lt $fileStream.Length) {
            $record = New-Object URL_RECORD_HEADER
            $record.Signature = $binaryReader.ReadString(4)
            $record.AmountOfBlocksInRecord = $binaryReader.ReadUInt32()
            $record.LastModified = $binaryReader.ReadInt64()
            $record.LastAccessed = $binaryReader.ReadInt64()
            $record.Expires = $binaryReader.ReadUInt64()

            $results += $record
        }
    } catch {
        Write-Error "Error parsing index.dat file."
    } finally {
        $binaryReader.Close()
        $fileStream.Close()
    }

    return $results
}