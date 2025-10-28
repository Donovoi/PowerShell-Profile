function Convert-PdfToMusicXml {
    <#
    .SYNOPSIS
    Convert a sheet-music PDF to MusicXML using Audiveris (CLI).

    .DESCRIPTION
    Uses Audiveris' command-line interface to transcribe (-transcribe) and export (-export)
    MusicXML. By default exports compressed .MXL; use -UncompressedXml to force plain .musicxml.
    Optionally enable Book/Opus export to one file with -UseOpus. Supports selecting specific pages.

    .PARAMETER Path
    Input PDF (or image) file path.

    .PARAMETER OutDir
    Output directory for .mxl/.musicxml and .omr project files (created if missing).

    .PARAMETER AudiverisPath
    Full path to Audiveris launcher (e.g., "C:\Program Files\Audiveris\Audiveris.exe").
    If omitted, the function tries common defaults and PATH.

    .PARAMETER UncompressedXml
    Export plain MusicXML (.musicxml) rather than compressed .mxl.

    .PARAMETER UseOpus
    Export a single MusicXML file representing a multi-movement “opus” rather than one per movement.

    .PARAMETER Sheets
    One or more 1-based page numbers; ranges allowed (e.g., 1, 3, 5..8).

    .PARAMETER TessDataPath
    Optional path to Tesseract traineddata (sets TESSDATA_PREFIX) to improve text/lyrics OCR.

    .PARAMETER Force
    Force reprocessing even if outputs exist.

    .PARAMETER PassThru
    Return the output file path(s).

    .EXAMPLE
    Convert-PdfToMusicXml -Path "C:\scores\WhiteWinterHymnal.pdf" -OutDir "C:\scores\xml"

    .EXAMPLE
    Convert-PdfToMusicXml -Path .\score.pdf -UncompressedXml -UseOpus -Sheets 1,3,5..7 -PassThru
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Position = 1)]
        [string]$OutDir = $(Join-Path (Split-Path -Path $Path -Parent) 'audiveris-export'),

        [string]$AudiverisPath,

        [switch]$UncompressedXml,
        [switch]$UseOpus,
        [Parameter()]
        [Alias('Page', 'PageNumbers')]
        [object[]]$Sheets,

        [string]$TessDataPath,
        [switch]$Force,
        [switch]$PassThru
    )

    begin {
        # Resolve Audiveris location
        $candidatePaths = @(
            $AudiverisPath,
            'C:\Program Files\Audiveris\Audiveris.exe',
            'C:\Program Files (x86)\Audiveris\Audiveris.exe',
            'Audiveris.exe',
            'Audiveris.bat',
            'audiveris' # on PATH (Linux/WSL/macOS)
        ) | Where-Object { $_ }  # drop nulls

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
            throw 'Audiveris launcher not found. Install Audiveris 5.5+ or provide -AudiverisPath.'
        }

        # Prepare output directory
        if (-not (Test-Path $OutDir)) {
            New-Item -ItemType Directory -Path $OutDir | Out-Null 
        }

        # Optional OCR traineddata for lyrics/text
        if ($TessDataPath) {
            if (-not (Test-Path $TessDataPath -PathType Container)) {
                throw "TessDataPath '$TessDataPath' does not exist."
            }
            $env:TESSDATA_PREFIX = $TessDataPath
        }

        # Build CLI args
        $args = @(
            '-batch',
            '-transcribe',     # make pipeline explicit before export
            '-export',
            '-output', $OutDir
        )

        if ($Force) {
            $args += '-force' 
        }
        if ($UseOpus) {
            $args += @('-constant', 'org.audiveris.omr.sheet.BookManager.useOpus=true') 
        }
        if ($UncompressedXml) {
            # Export plain .xml instead of compressed .mxl
            $args += @('-constant', 'org.audiveris.omr.sheet.BookManager.useCompression=false')
        }

        # Sheets handling (convert 5..8 to "5-8", keep integers as-is)
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

        Write-Verbose ("[Audiveris] {0} `nArgs: {1}" -f $launcher, ($args -join ' '))
        & $launcher @args
        $exit = $LASTEXITCODE
        if ($exit -ne 0) {
            throw "Audiveris exited with code $exit. Check logs in '$OutDir' or try -Force."
        }

        # Collect outputs
        $pattern = if ($UncompressedXml) {
            '*.xml' 
        }
        else {
            '*.mxl' 
        }
        $files = Get-ChildItem -LiteralPath $OutDir -Filter $pattern -Recurse | Sort-Object LastWriteTime -Descending

        if (-not $files) {
            throw "No MusicXML files found in '$OutDir'. Ensure the PDF is legible and try -Force or different Sheets."
        }

        if ($PassThru) {
            $files.FullName 
        }
        else {
            Write-Host ('Exported {0} file(s) to: {1}' -f $files.Count, $OutDir)
        }
    }
}
