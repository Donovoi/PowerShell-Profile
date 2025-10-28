function Convert-PdfToMusicXml {
    <#
    .SYNOPSIS
    Run Audiveris OMR on a PDF (or existing .omr) and export MusicXML.

    .DESCRIPTION
    - Calls Audiveris headless (CLI) with:
        -batch    : no GUI
        -export   : export MusicXML (.mxl by default)
        -save     : save the .omr project file
        -output   : base output folder
        -force    : force reprocessing
      These flags are documented in Audiveris' CLI reference for batch processing and MusicXML export. :contentReference[oaicite:4]{index=4}

    - Captures stdout/stderr to a log next to your output.
    - Returns / prints the paths to the generated .mxl (compressed MusicXML),
      .xml (uncompressed if you ask for it), and .omr (Audiveris project).

    Note: Audiveris can spit scary Java "InaccessibleObjectException" errors
    about DirectByteBuffer.cleaner() because newer Java blocks reflective access
    to internal classes via the module system, but OMR and export can still
    succeed. :contentReference[oaicite:5]{index=5}

    .PARAMETER Path
    Input score. Usually a PDF of printed music. You can also pass an .omr
    you've already cleaned by hand to just re-export MusicXML.

    .PARAMETER OutDir
    Where to write output (.mxl / .omr / logs). Will be created if missing.

    .PARAMETER AudiverisPath
    Full path to Audiveris.exe (or audiveris on PATH). If omitted, we try
    common install locations like "C:\Program Files\Audiveris\Audiveris.exe".

    .PARAMETER UncompressedXml
    Ask Audiveris to emit plain .xml MusicXML (uncompressed) instead of .mxl.
    Compressed .mxl is the default MusicXML flavor and is widely supported by
    notation tools like MuseScore. :contentReference[oaicite:6]{index=6}

    .PARAMETER UseOpus
    Tell Audiveris to export multi-movement books as a single “opus” file.

    .PARAMETER Sheets
    Limit processing to certain pages/sheets. Accepts numbers and ranges
    like 1,3..5 and translates them to Audiveris’ "-sheets" arg, which takes
    things like "1 3-5". :contentReference[oaicite:7]{index=7}

    .PARAMETER Force
    Force re-run even if Audiveris thinks it's already processed that PDF.

    .PARAMETER PassThru
    Return the discovered artifact paths (string[]) instead of just printing.

    .EXAMPLE
    Convert-PdfToMusicXml -Path "C:\scores\SOPRANO.pdf" `
                          -OutDir "C:\scores\audiveris-batch" `
                          -Force -Verbose -PassThru

    .EXAMPLE
    # Re-export from a cleaned .omr you fixed in the GUI
    Convert-PdfToMusicXml -Path "C:\scores\SOPRANO.omr" `
                          -OutDir "C:\scores\audiveris-batch" `
                          -UncompressedXml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Position = 1)]
        [string]$OutDir = $(Join-Path (Split-Path -Path $Path -Parent) 'audiveris-export'),

        [string]$AudiverisPath,

        [switch]$UncompressedXml,   # emit .xml instead of .mxl
        [switch]$UseOpus,           # single multi-movement file if relevant
        [object[]]$Sheets,          # e.g. 1,3..5
        [switch]$Force,
        [switch]$PassThru
    )

    #
    # 1. Resolve Audiveris binary
    #
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
        throw 'Audiveris not found. Install Audiveris and/or pass -AudiverisPath.'
    }

    #
    # 2. Prep paths & filenames
    #
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    }

    $resolvedInput = (Resolve-Path $Path).Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    $logFile = Join-Path $OutDir ('{0}.audiveris.log' -f $baseName)

    #
    # 3. Build Audiveris CLI args
    #    (CLI flags per Audiveris docs: -batch runs headless,
    #     -export writes MusicXML, -save writes .omr, -output sets base dir,
    #     -force reprocesses. :contentReference[oaicite:8]{index=8})
    #
    $args = @(
        '-batch',
        '-export',
        '-save',
        '-output', $OutDir
    )

    if ($Force) {
        $args += '-force' 
    }

    if ($UseOpus) {
        # Export multi-movement book as one opus file
        $args += @(
            '-constant',
            'org.audiveris.omr.sheet.BookManager.useOpus=true'
        )
    }

    if ($UncompressedXml) {
        # Export plain .xml MusicXML instead of compressed .mxl
        $args += @(
            '-constant',
            'org.audiveris.omr.sheet.BookManager.useCompression=false'
        )
    }

    if ($Sheets) {
        # Translate 1,3..5 -> "1 3-5"
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

    # Audiveris CLI syntax expects "--" before file list. :contentReference[oaicite:9]{index=9}
    $args += @('--', $resolvedInput)

    Write-Verbose ("[Audiveris] {0}`nArgs: {1}" -f $launcher, ($args -join ' '))

    #
    # 4. Run Audiveris and capture stdout+stderr to log
    #
    & $launcher @args *> $logFile
    $exit = $LASTEXITCODE
    Write-Verbose "Audiveris exit code: $exit (log: $logFile)"

    #
    # 5. Collect output artifacts
    #    Audiveris typically writes:
    #      - <baseName>.mxl  (compressed MusicXML)  :contentReference[oaicite:10]{index=10}
    #      - <baseName>.omr  (its editable project)
    #    under the chosen -output directory, but it may also create a subfolder
    #    per score, or (in some versions) default to Documents\Audiveris.
    #
    $candidates = @()

    # Helper to append found files uniquely
    function Add-Candidate {
        param([string]$probePath)
        if (Test-Path $probePath -PathType Leaf) {
            $item = Get-Item $probePath
            $script:candidates += $item
        }
    }

    # 5a. Directly in OutDir
    $candidates += Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.mxl"
    $candidates += Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.xml"
    $candidates += Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.omr"

    # 5b. In a score-named subfolder under OutDir
    $bookDir = Join-Path $OutDir $baseName
    if (Test-Path $bookDir -PathType Container) {
        $candidates += Get-ChildItem -LiteralPath $bookDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.mxl"
        $candidates += Get-ChildItem -LiteralPath $bookDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.xml"
        $candidates += Get-ChildItem -LiteralPath $bookDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.omr"
    }

    # 5c. Legacy default under Documents\Audiveris (older layouts)
    $docsAud = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Audiveris'
    if (Test-Path $docsAud -PathType Container) {
        $legacyDir = Join-Path $docsAud $baseName
        if (Test-Path $legacyDir -PathType Container) {
            $candidates += Get-ChildItem -LiteralPath $legacyDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.mxl"
            $candidates += Get-ChildItem -LiteralPath $legacyDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.xml"
            $candidates += Get-ChildItem -LiteralPath $legacyDir -File -ErrorAction SilentlyContinue -Filter "$baseName*.omr"
        }
    }

    # 5d. Explicit fallbacks (sometimes pattern matching can miss exact names)
    Add-Candidate (Join-Path $OutDir "$baseName.mxl")
    Add-Candidate (Join-Path $OutDir "$baseName.xml")
    Add-Candidate (Join-Path $OutDir "$baseName.omr")
    if (Test-Path $bookDir -PathType Container) {
        Add-Candidate (Join-Path $bookDir "$baseName.mxl")
        Add-Candidate (Join-Path $bookDir "$baseName.xml")
        Add-Candidate (Join-Path $bookDir "$baseName.omr")
    }

    # De-dupe and sort by newest first
    $candidates = $candidates |
        Sort-Object FullName -Unique |
            Sort-Object LastWriteTime -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "Audiveris ran (exit $exit) but I couldn't find $baseName.{mxl,xml,omr}. Check $logFile for details."
    }

    #
    # 6. Print or return results
    #
    if ($PassThru) {
        return $candidates.FullName
    }
    else {
        Write-Host "Artifacts for '$baseName':"
        foreach ($f in $candidates) {
            Write-Host (' - {0}' -f $f.FullName)
        }
        Write-Host ''
        Write-Host ('Full log: {0}' -f $logFile)
    }
}
