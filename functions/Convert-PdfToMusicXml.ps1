function Convert-PdfToMusicXml {
    <#
    .SYNOPSIS
    Run Audiveris OMR headlessly on a PDF (or .omr) and export MusicXML.

    .DESCRIPTION
    - Uses documented CLI flags:
        -batch   : headless
        -export  : export MusicXML
        -save    : persist .omr project
        -output  : base output folder (parent of a score-named subfolder)
        -option  : set options (e.g., useOpus/useCompression)
        -sheets  : restrict pages
        --       : delimiter before file list
      (See citations after the code.)

    - Captures stdout+stderr to a per-score log.
    - Gathers artifacts from:
        1) the requested -OutDir,
        2) the score-named subfolder under -OutDir,
        3) the default Documents\Audiveris\{Score} fallback,
        4) any absolute paths found in the log.
      Returns the newest files first.

    .PARAMETER Path
    Input score file (.pdf or .omr).

    .PARAMETER OutDir
    Base output folder (created if missing). Audiveris will still nest a
    {ScoreName}\ subfolder under this base; this cmdlet handles both locations.

    .PARAMETER AudiverisPath
    Explicit path to Audiveris.exe (or "audiveris" on PATH).

    .PARAMETER UncompressedXml
    Export plain .xml MusicXML (instead of compressed .mxl).

    .PARAMETER UseOpus
    Export multi-movement books as a single opus .mxl/.xml.

    .PARAMETER Sheets
    Page selection (accepts ints, "1,3..5", or "1-3").

    .PARAMETER Force
    Force reprocessing.

    .PARAMETER PassThru
    Return artifact paths (string[]) instead of printing.

    .EXAMPLE
    Convert-PdfToMusicXml -Path C:\scores\song.pdf -OutDir C:\scores\omr `
                          -UseOpus -Verbose -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Position = 1)]
        [string]$OutDir = (Join-Path (Split-Path -Path $Path -Parent) 'audiveris-export'),

        [string]$AudiverisPath,

        [switch]$UncompressedXml,
        [switch]$UseOpus,
        [object[]]$Sheets,
        [switch]$Force,
        [switch]$PassThru
    )

    # 1) Locate Audiveris launcher
    $candidatePaths = @($AudiverisPath,
        'C:\Program Files\Audiveris\Audiveris.exe',
        'C:\Program Files (x86)\Audiveris\Audiveris.exe',
        'Audiveris.exe', 'Audiveris.bat', 'audiveris') | Where-Object { $_ }

    $launcher = $null
    foreach ($p in $candidatePaths) {
        try {
            $got = (Get-Command $p -ErrorAction Stop).Source; if ($got) {
                $launcher = $got; break 
            } 
        }
        catch {
        }
    }
    if (-not $launcher) {
        throw 'Audiveris not found. Install it or pass -AudiverisPath.' 
    }

    # 2) Normalize paths, filenames, and log file
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null 
    }
    $resolvedInput = (Resolve-Path $Path).Path
    $baseName = [IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    $logFile = Join-Path $OutDir ('{0}.audiveris.log' -f $baseName)

    # 3) Build CLI args per docs
    $args = @('-batch', '-export', '-save', '-output', $OutDir)
    if ($Force) {
        $args += '-force' 
    }
    if ($UseOpus) {
        $args += @('-option', 'org.audiveris.omr.sheet.BookManager.useOpus=true') 
    }
    if ($UncompressedXml) {
        $args += @('-option', 'org.audiveris.omr.sheet.BookManager.useCompression=false') 
    }

    if ($Sheets) {
        # Accept 1,3..5 or 1-3 or plain ints, output "1 3-5" as one argument after -sheets
        $tokens = foreach ($s in $Sheets) {
            $t = "$s"
            if ($t -match '^\s*(\d+)\s*\.\.\s*(\d+)\s*$') {
                '{0}-{1}' -f $Matches[1], $Matches[2] 
            }
            elseif ($t -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
                '{0}-{1}' -f $Matches[1], $Matches[2] 
            }
            else {
                $t.Trim() 
            }
        }
        # Audiveris expects one string with spaces between numbers / ranges
        $args += @('-sheets', ($tokens -join ' '))
    }

    # '--' delimiter before filename list (per CLI help)
    $args += @('--', $resolvedInput)

    Write-Verbose ('[Audiveris] {0}' -f $launcher)
    Write-Verbose ('Args: {0}' -f ($args -join ' '))

    # 4) Run process, tee stdout+stderr to the log
    #    Using pipeline avoids Start-Process redirection quirks.
    $null = (& $launcher @args *>&1) | Tee-Object -FilePath $logFile
    $exit = $LASTEXITCODE
    Write-Verbose ('Audiveris exit code: {0} (log: {1})' -f $exit, $logFile)

    # 5) Collect artifacts robustly
    #    Use a case-insensitive hash set of full paths to avoid the op_Addition trap.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    function Add-IfFile([string]$p) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            return 
        }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            [void]$seen.Add((Resolve-Path -LiteralPath $p).Path)
        }
    }

    $filters = @("$baseName*.mxl", "$baseName*.xml", "$baseName*.musicxml", "$baseName*.omr")
    # 5a) Directly in OutDir
    foreach ($f in $filters) {
        Get-ChildItem -LiteralPath $OutDir -File -Filter $f -ErrorAction SilentlyContinue | ForEach-Object { Add-IfFile $_.FullName }
    }
    # 5b) Score-named subfolder (expected by CLI: OutDir\{Score}\{Score}.mxl)
    $bookDir = Join-Path $OutDir $baseName
    if (Test-Path $bookDir -PathType Container) {
        foreach ($f in $filters) {
            Get-ChildItem -LiteralPath $bookDir -File -Filter $f -ErrorAction SilentlyContinue | ForEach-Object { Add-IfFile $_.FullName }
        }
    }
    # 5c) Legacy/default Windows location: Documents\Audiveris\{Score}\*
    $docsAud = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Audiveris'
    $legacyDir = Join-Path $docsAud $baseName
    if (Test-Path $legacyDir -PathType Container) {
        foreach ($f in $filters) {
            Get-ChildItem -LiteralPath $legacyDir -File -Filter $f -ErrorAction SilentlyContinue | ForEach-Object { Add-IfFile $_.FullName }
        }
    }
    # 5d) Parse the log for absolute file paths the app claims to have written
    if (Test-Path $logFile -PathType Leaf) {
        $logText = Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
        $rx = '(?:[A-Za-z]:\\|/)[^\r\n<>:"|?*]+?\.(?:mxl|xml|musicxml|omr)'
        if ($logText) {
            [Text.RegularExpressions.Regex]::Matches($logText -join "`n", $rx) | ForEach-Object {
                Add-IfFile $_.Value
            }
        }
    }

    $artifacts = @()
    if ($seen.Count -gt 0) {
        $artifacts = $seen.ToArray() | Get-Item | Sort-Object LastWriteTime -Descending
    }

    if (-not $artifacts -or $artifacts.Count -eq 0) {
        $tail = ''
        if (Test-Path $logFile) {
            $tail = "`n----- log tail -----`n" + (Get-Content $logFile -Tail 50 | Out-String)
        }
        throw ("Audiveris ran (exit {0}) but no {1}.{{mxl,xml,musicxml,omr}} were found under:`n - {2}`n - {3}`n - {4}{5}" -f `
                $exit, $baseName, $OutDir, $bookDir, $legacyDir, $tail)
    }

    if ($PassThru) {
        return ($artifacts | Select-Object -ExpandProperty FullName)
    }
    else {
        Write-Host ("Artifacts for '{0}':" -f $baseName)
        foreach ($f in $artifacts) {
            Write-Host (' - {0}' -f $f.FullName) 
        }
        Write-Host ("`nFull log: {0}" -f $logFile)
    }
}
