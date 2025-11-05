function Convert-PdfToMusicXml {
    <#
    .SYNOPSIS
    Headless Audiveris OMR for PDF/.omr → MusicXML (.mxl or .xml), with robust artifact discovery.

    .PARAMETER Path
    Input score (.pdf or .omr).

    .PARAMETER OutDir
    Base output directory (created if missing). Audiveris still nests a score-named
    “book folder” under this path; we search both. (See Audiveris handbook.) 

    .PARAMETER AudiverisPath
    Path to Audiveris launcher (Audiveris.exe / audiveris).

    .PARAMETER UncompressedXml
    Emit plain .xml (set useCompression=false). 

    .PARAMETER UseOpus
    Export multi-movement “opus” as a single file (useOpus=true).

    .PARAMETER Sheets
    Page selection: accepts ints and ranges like 1,3..5 or 1-3, mapped to “-sheets '1 3-5'”.

    .PARAMETER Force
    Force reprocessing.

    .PARAMETER PassThru
    Return artifact paths instead of printing.
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
    $candidate = @($AudiverisPath,
        'C:\Program Files\Audiveris\Audiveris.exe',
        'C:\Program Files (x86)\Audiveris\Audiveris.exe',
        'Audiveris.exe', 'Audiveris.bat', 'audiveris') | Where-Object { $_ }

    $launcher = $null
    foreach ($p in $candidate) {
        try {
            $src = (Get-Command $p -ErrorAction Stop).Source; if ($src) {
                $launcher = $src; break 
            } 
        }
        catch {
        }
    }
    if (-not $launcher) {
        throw 'Audiveris not found. Install it or pass -AudiverisPath.' 
    }

    # 2) Normalize paths & log
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null 
    }
    $resolvedInput = (Resolve-Path $Path).Path
    $baseName = [IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    $logFile = Join-Path $OutDir ('{0}.audiveris.log' -f $baseName)

    # 3) Build CLI args (per Audiveris CLI & issues)
    $args = @('-batch', '-export', '-save', '-output', $OutDir)
    if ($Force) {
        $args += '-force' 
    }
    if ($UseOpus) {
        $args += @('-option', 'org.audiveris.omr.sheet.BookManager.useOpus=true') 
    }       # single opus file
    if ($UncompressedXml) {
        $args += @('-option', 'org.audiveris.omr.sheet.BookManager.useCompression=false') 
    }# .xml instead of .mxl

    if ($Sheets) {
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
        $args += @('-sheets', ($tokens -join ' '))
    }

    # '--' before file list (CLI delimiter)
    $args += @('--', $resolvedInput)

    Write-Verbose ('[Audiveris] {0}' -f $launcher)
    Write-Verbose ('Args: {0}' -f ($args -join ' '))

    # 4) Run & tee output to log
    $null = (& $launcher @args *>&1) | Tee-Object -FilePath $logFile
    $exit = $LASTEXITCODE
    Write-Verbose ('Audiveris exit code: {0} (log: {1})' -f $exit, $logFile)

    # 5) Collect artifacts (dictionary for de-dupe; no .ToArray anywhere)
    $found = @{}  # key = full path, value = $true

    function Add-IfFile([string]$p) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            return 
        }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $rp = (Resolve-Path -LiteralPath $p).Path
            $found[$rp] = $true
        }
    }

    $filters = @("$baseName*.mxl", "$baseName*.xml", "$baseName*.musicxml", "$baseName*.omr")

    # OutDir directly
    foreach ($f in $filters) {
        Get-ChildItem -LiteralPath $OutDir -File -Filter $f -ErrorAction SilentlyContinue |
            ForEach-Object { Add-IfFile $_.FullName }
    }
    # Score-named "book folder" under OutDir (typical)
    $bookDir = Join-Path $OutDir $baseName
    if (Test-Path $bookDir -PathType Container) {
        foreach ($f in $filters) {
            Get-ChildItem -LiteralPath $bookDir -File -Filter $f -ErrorAction SilentlyContinue |
                ForEach-Object { Add-IfFile $_.FullName }
        }
    }
    # Legacy default: Documents\Audiveris\<ScoreName>\*
    $docsAud = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Audiveris'
    $legacyDir = Join-Path $docsAud $baseName
    if (Test-Path $legacyDir -PathType Container) {
        foreach ($f in $filters) {
            Get-ChildItem -LiteralPath $legacyDir -File -Filter $f -ErrorAction SilentlyContinue |
                ForEach-Object { Add-IfFile $_.FullName }
        }
    }
    # Parse the log for absolute paths Audiveris says it wrote
    if (Test-Path $logFile -PathType Leaf) {
        $logText = Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($logText) {
            $rx = '(?:[A-Za-z]:\\|/)[^\r\n<>:"|?*]+?\.(?:mxl|xml|musicxml|omr)'
            [Text.RegularExpressions.Regex]::Matches(($logText -join "`n"), $rx) |
                ForEach-Object { Add-IfFile $_.Value }
        }
    }

    $artifacts = @()
    if ($found.Count -gt 0) {
        $artifacts = $found.Keys | Get-Item | Sort-Object LastWriteTime -Descending
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
