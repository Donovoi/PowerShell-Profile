function Convert-PdfToMusicXml {
    <#
.SYNOPSIS
Highest-quality PDF/.OMR → MusicXML via Audiveris with smart rasterization & preprocessing.

.DESCRIPTION
1) If the input is a PDF:
   - Try `pdfimages` to extract the page images at native resolution (best for scanned PDFs).
   - Otherwise rasterize with `pdftoppm` or `pdftocairo` at 400–600 DPI, grayscale PNG.
   - Optionally deskew/normalize with ImageMagick if available.
2) Run Audiveris headless: -batch -export -save -output [-force] [-sheets] and set quality-focused
   constants via -constant (uncompressed XML, opus export, OCR languages, etc.).
3) Collect .mxl/.xml/.musicxml/.omr artifacts from OutDir, score-named subfolder, and legacy folder.

.PARAMETER Path
PDF or .omr (you can also pass a folder of pre-rendered images).

.PARAMETER OutDir
Base output directory (created if missing). Audiveris still nests a book-named subfolder.

.PARAMETER AudiverisPath
Path to Audiveris launcher (Audiveris.exe / audiveris).

.PARAMETER Dpi
Rasterization DPI for vector PDFs (default 450; 400–600 recommended). 300–600 DPI is typical
and you want ~20 px interline thickness for best recognition.  # per Audiveris guidance.  [docs]

.PARAMETER Sheets
Subset pages (e.g. 1,3..5 or 2-4). Passed to Audiveris -sheets "1 3-5".

.PARAMETER OcrLang
OCR language spec for lyrics/text (e.g., 'eng' or 'ita+eng'). Wired to
org.audiveris.omr.text.Language.defaultSpecification.  # per handbook.

.PARAMETER UncompressedXml
Export plain .xml (via BookManager.useCompression=false). Default is compressed .mxl.

.PARAMETER UseOpus
Export multi-movement books as a single “opus” file (BookManager.useOpus=true).

.PARAMETER Deskew
If ImageMagick is installed, apply -deskew/normalize to rasters before OMR.

.PARAMETER Force
Force Audiveris reprocessing / overwrite prior outputs.

.PARAMETER PassThru
Return artifact paths instead of printing.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path,

        [Parameter(Position = 1)]
        [string]$OutDir = (Join-Path (Split-Path -Parent $Path) 'audiveris-export'),

        [string]$AudiverisPath,

        [int]$Dpi = 450,

        [object[]]$Sheets,

        [string]$OcrLang = 'eng',

        [switch]$UncompressedXml,
        [switch]$UseOpus,
        [switch]$Deskew,
        [switch]$Force,
        [switch]$PassThru
    )

    # ---------- helpers ----------
    function Resolve-Exe([string[]]$candidates) {
        foreach ($c in $candidates) {
            if (-not $c) {
                continue 
            }
            try {
                $cmd = Get-Command $c -ErrorAction Stop
                if ($cmd.Source -and (Test-Path $cmd.Source)) {
                    return $cmd.Source 
                }
            }
            catch {
            }
            if (Test-Path $c) {
                return (Resolve-Path $c).Path 
            }
        }
        return $null
    }
    function New-Dir($p) {
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Force -Path $p | Out-Null 
        } 
    }
    function Add-Found([string]$p, [hashtable]$bag) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            return 
        }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $rp = (Resolve-Path -LiteralPath $p).Path
            $bag[$rp] = $true
        }
    }
    function Parse-RangeTokens([object[]]$vals) {
        if (-not $vals) {
            return $null 
        }
        $tokens = foreach ($s in $vals) {
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
        return ($tokens -join ' ')
    }

    # ---------- discover tools ----------
    $aud = if ($AudiverisPath) {
        $AudiverisPath 
    }
    else {
        Resolve-Exe @(
            'C:\Program Files\Audiveris\Audiveris.exe',
            'C:\Program Files (x86)\Audiveris\Audiveris.exe',
            'Audiveris.exe', 'audiveris'
        )
    }
    if (-not $aud) {
        throw 'Audiveris not found. Install it or pass -AudiverisPath.' 
    }

    $pdfimages = Resolve-Exe @('pdfimages.exe', 'pdfimages')
    $pdftoppm = Resolve-Exe @('pdftoppm.exe', 'pdftoppm', 'pdftocairo.exe', 'pdftocairo')
    $magick = Resolve-Exe @('magick.exe', 'convert.exe', 'magick')  # ImageMagick (deskew/normalize)

    # ---------- prepare paths ----------
    New-Dir $OutDir
    $inAbs = (Resolve-Path $Path).Path
    $baseName = [IO.Path]::GetFileNameWithoutExtension($inAbs)
    $logFile = Join-Path $OutDir ('{0}.audiveris.log' -f $baseName)
    $work = Join-Path $OutDir ('.audiveris-work-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    New-Dir $work

    # ---------- build input image list ----------
    $inputs = @()
    $ext = [IO.Path]::GetExtension($inAbs).ToLowerInvariant()

    if ($ext -eq '.pdf') {
        # 1) Try pdfimages (extract embedded bitmaps with no resampling).  :contentReference[oaicite:5]{index=5}
        $imgDir = Join-Path $work 'images'
        New-Dir $imgDir
        if ($pdfimages) {
            # Prefer PNG output where possible
            & $pdfimages -png $inAbs (Join-Path $imgDir 'page') 2>$null | Out-Null
        }
        # If that produced nothing, use pdftoppm/pdftocairo at high DPI, grayscale PNG.  :contentReference[oaicite:6]{index=6}
        if (-not (Get-ChildItem -LiteralPath $imgDir -Filter '*.png' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            if (-not $pdftoppm) {
                throw 'Neither pdfimages nor pdftoppm/pdftocairo found on PATH.' 
            }
            # Try pdftoppm first; fallback to pdftocairo if that's what's resolved
            $ppmRoot = Join-Path $imgDir 'ppm'
            if ($pdftoppm.ToLower().Contains('pdftoppm')) {
                & $pdftoppm -gray -r $Dpi $inAbs $ppmRoot 2>$null | Out-Null
                Get-ChildItem -LiteralPath $imgDir -Filter 'ppm-*.pgm' -File -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $png = $_.FullName -replace '\.pgm$', '.png'
                        # Use ImageMagick if present, else .NET encoder
                        if ($magick) {
                            & $magick $_.FullName $png 2>$null | Out-Null
                        }
                        else {
                            Add-Type -AssemblyName System.Drawing
                            $bmp = [System.Drawing.Image]::FromFile($_.FullName)
                            $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
                            $bmp.Dispose()
                        }
                    }
            }
            else {
                # pdftocairo path (supports -png -gray -r)  :contentReference[oaicite:7]{index=7}
                & $pdftoppm -png -gray -r $Dpi $inAbs (Join-Path $imgDir 'page') 2>$null | Out-Null
            }
        }

        # Optional deskew/normalize to improve recognition.  :contentReference[oaicite:8]{index=8}
        if ($Deskew -and $magick) {
            Get-ChildItem -LiteralPath $imgDir -Filter '*.png' -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    & $magick $_.FullName -colorspace Gray -strip -deskew 40% -normalize $_.FullName 2>$null | Out-Null
                }
        }

        $inputs = Get-ChildItem -LiteralPath $imgDir -Filter '*.png' -File -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -ExpandProperty FullName
        if (-not $inputs) {
            throw 'PDF rasterization produced no images.' 
        }
    }
    elseif ($ext -eq '.omr') {
        $inputs = @($inAbs)  # re-export path
    }
    else {
        # image or folder of images
        if (Test-Path $inAbs -PathType Container) {
            $inputs = Get-ChildItem -LiteralPath $inAbs -Include *.png, *.tif, *.tiff, *.jpg, *.jpeg -File -Recurse |
                Sort-Object FullName | Select-Object -ExpandProperty FullName
        }
        else {
            $inputs = @($inAbs)
        }
    }

    # ---------- Audiveris CLI ----------
    $sheetArg = Parse-RangeTokens $Sheets
    $argumentsList = @('-batch', '-export', '-save', '-output', $OutDir)
    if ($Force) {
        $argumentsList += '-force' 
    }

    # Quality-minded constants:
    # - Set OCR language(s) (eng by default).  :contentReference[oaicite:9]{index=9}
    if ($OcrLang) {
        $argumentsList += @('-constant', "org.audiveris.omr.text.Language.defaultSpecification=$OcrLang")
    }
    # - Uncompressed XML if requested (BookManager.useCompression=false).
    if ($UncompressedXml) {
        $argumentsList += @('-constant', 'org.audiveris.omr.sheet.BookManager.useCompression=false')
    }
    # - Single opus export if requested.  (BookManager.useOpus=true)
    if ($UseOpus) {
        $argumentsList += @('-constant', 'org.audiveris.omr.sheet.BookManager.useOpus=true')
    }
    # - Page subset
    if ($sheetArg) {
        $argumentsList += @('-sheets', $sheetArg) 
    }

    # File list delimiter
    $argumentsList += @('--')
    $argumentsList += $inputs

    Write-Verbose ('[Audiveris] {0}' -f $aud)
    Write-Verbose ('Args: {0}' -f ($argumentsList -join ' '))

    # Run and tee output to log
    $allOut = & $aud @argumentsList *>&1
    $allOut | Tee-Object -FilePath $logFile | Out-Null
    $exit = $LASTEXITCODE
    Write-Verbose ('Audiveris exit code: {0} (log: {1})' -f $exit, $logFile)

    # ---------- collect artifacts ----------
    $found = @{}  # path -> true
    $filters = @("$baseName*.mxl", "$baseName*.xml", "$baseName*.musicxml", "$baseName*.omr")

    # a) directly under OutDir
    foreach ($f in $filters) {
        Get-ChildItem -LiteralPath $OutDir -File -Filter $f -ErrorAction SilentlyContinue |
            ForEach-Object { Add-Found $_.FullName $found }
    }
    # b) score-named subfolder (typical)  :contentReference[oaicite:10]{index=10}
    $bookDir = Join-Path $OutDir $baseName
    if (Test-Path $bookDir -PathType Container) {
        foreach ($f in $filters) {
            Get-ChildItem -LiteralPath $bookDir -File -Filter $f -ErrorAction SilentlyContinue |
                ForEach-Object { Add-Found $_.FullName $found }
        }
    }
    # c) legacy Documents\Audiveris\ScoreName  :contentReference[oaicite:11]{index=11}
    $legacyBase = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Audiveris'
    $legacyDir = Join-Path $legacyBase $baseName
    if (Test-Path $legacyDir -PathType Container) {
        foreach ($f in $filters) {
            Get-ChildItem -LiteralPath $legacyDir -File -Filter $f -ErrorAction SilentlyContinue |
                ForEach-Object { Add-Found $_.FullName $found }
        }
    }
    # d) scrape absolute paths Audiveris printed
    if (Test-Path $logFile -PathType Leaf) {
        $rx = '(?:[A-Za-z]:\\|/)[^\r\n<>:"|?*]+?\.(?:mxl|xml|musicxml|omr)'
        [Text.RegularExpressions.Regex]::Matches((Get-Content $logFile -Raw), $rx) |
            ForEach-Object { Add-Found $_.Value $found }
    }

    $artifacts = @()
    if ($found.Count -gt 0) {
        $artifacts = $found.Keys | Get-Item | Sort-Object LastWriteTime -Descending
    }
    if (-not $artifacts) {
        $tail = ''
        if (Test-Path $logFile) {
            $tail = "`n----- log tail -----`n" + ((Get-Content $logFile -Tail 60) -join "`n") 
        }
        throw ("Audiveris ran (exit {0}) but no {1}.{{mxl,xml,musicxml,omr}} were found under:`n - {2}`n - {3}`n - {4}{5}" -f `
                $exit, $baseName, $OutDir, $bookDir, $legacyDir, $tail)
    }

    if ($PassThru) {
        return ($artifacts | Select-Object -ExpandProperty FullName) 
    }
    Write-Host ("Artifacts for '{0}':" -f $baseName)
    $artifacts | ForEach-Object { Write-Host (' - {0}' -f $_.FullName) }
    Write-Host ("`nFull log: {0}" -f $logFile)
}
