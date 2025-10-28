function Convert-PdfToMusicXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Position = 1)]
        [string]$OutDir = $(Join-Path (Split-Path -Path $Path -Parent) 'audiveris-export'),

        [string]$AudiverisPath,

        [switch]$UncompressedXml,   # emit .xml instead of .mxl
        [switch]$UseOpus,           # single "opus" file for multi-movement scores
        [object[]]$Sheets,          # 1,3..5 etc
        [switch]$Force,
        [switch]$PassThru
    )

    # region Resolve Audiveris binary
    $candidatePaths = @(
        $AudiverisPath,
        'C:\Program Files\Audiveris\Audiveris.exe',
        'C:\Program Files (x86)\Audiveris\Audiveris.exe',
        'Audiveris.exe',
        'Audiveris.bat',
        'audiveris'
    ) | Where-Object { $_ }

    $launcher = $null
    foreach ($p in $candidatePaths) {
        try {
            $resolved = (Get-Command $p -ErrorAction Stop).Source
            if ($resolved) {
                $launcher = $resolved; break 
            }
        }
        catch { 
        }
    }
    if (-not $launcher) {
        throw 'Audiveris not found. Install it or provide -AudiverisPath.'
    }
    # endregion

    # region Prep dirs and names
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $logFile = Join-Path $OutDir "$baseName.audiveris.log"

    # We'll ask Audiveris to:
    #   -batch (no GUI)
    #   -export (MusicXML)
    #   -save   (persist .omr so we can debug/fix later)
    #   -output $OutDir (where to dump stuff)
    #   -force if requested
    $args = @('-batch', '-export', '-save', '-output', $OutDir)
    if ($Force) {
        $args += '-force' 
    }

    # format tweaks
    if ($UseOpus) {
        $args += @('-constant', 'org.audiveris.omr.sheet.BookManager.useOpus=true')
    }
    if ($UncompressedXml) {
        $args += @('-constant', 'org.audiveris.omr.sheet.BookManager.useCompression=false')
    }

    # page selection (Sheets param like 1,3..5 -> "1 3-5")
    if ($Sheets) {
        $sheetTokens = foreach ($s in $Sheets) {
            if ($s -is [string] -and $s -match '^\s*(\d+)\s*\.\.\s*(\d+)\s*$') {
                "$($Matches[1])-$($Matches[2])"
            }
            else {
                "$s" 
            }
        }
        $args += @('-sheets', ($sheetTokens -join ' '))
    }

    $args += @('--', $Path)

    Write-Verbose "Launching Audiveris:`n$launcher `n$args"
    # run Audiveris and tee ALL output (stdout+stderr) to log
    & $launcher @args *> $logFile
    $exit = $LASTEXITCODE
    Write-Verbose "Audiveris exit code: $exit (log: $logFile)"

    # region Collect candidates
    $candidates = @()

    # 1. flat files in OutDir
    $candidates += Get-ChildItem -LiteralPath $OutDir -Filter "$baseName*.mxl" -ErrorAction SilentlyContinue
    $candidates += Get-ChildItem -LiteralPath $OutDir -Filter "$baseName*.xml" -ErrorAction SilentlyContinue
    $candidates += Get-ChildItem -LiteralPath $OutDir -Filter "$baseName*.omr" -ErrorAction SilentlyContinue

    # 2. subfolder named after the score (Audiveris "book folder")
    $bookDir = Join-Path $OutDir $baseName
    if (Test-Path $bookDir) {
        $candidates += Get-ChildItem -LiteralPath $bookDir -Filter "$baseName*.mxl" -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem -LiteralPath $bookDir -Filter "$baseName*.xml" -ErrorAction SilentlyContinue
        $candidates += Get-ChildItem -LiteralPath $bookDir -Filter "$baseName*.omr" -ErrorAction SilentlyContinue
    }

    # 3. legacy default under Documents\Audiveris (in case -output got ignored)
    $docsAud = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Audiveris'
    if (Test-Path $docsAud) {
        $legacyBookDir = Join-Path $docsAud $baseName
        if (Test-Path $legacyBookDir) {
            $candidates += Get-ChildItem -LiteralPath $legacyBookDir -Filter "$baseName*.mxl" -ErrorAction SilentlyContinue
            $candidates += Get-ChildItem -LiteralPath $legacyBookDir -Filter "$baseName*.xml" -ErrorAction SilentlyContinue
            $candidates += Get-ChildItem -LiteralPath $legacyBookDir -Filter "$baseName*.omr" -ErrorAction SilentlyContinue
        }
    }

    $candidates = $candidates | Sort-Object LastWriteTime -Descending -Unique

    if (-not $candidates) {
        throw "Audiveris ran (exit $exit) but I can't find $baseName.{mxl,xml,omr}. Check $logFile for recognition/export errors, rhythmic conflicts, or filename/path issues. See Audiveris GUI if needed."
    }

    if ($PassThru) {
        return $candidates.FullName
    }
    else {
        Write-Host 'Artifacts:'
        $candidates | ForEach-Object {
            Write-Host " - $($_.FullName)"
        }
        Write-Host "`nFull log: $logFile"
    }
}
