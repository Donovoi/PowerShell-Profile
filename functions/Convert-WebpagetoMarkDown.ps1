<#
.SYNOPSIS
    Converts one or more web pages (SharePoint or generic) to a single
    concatenated Markdown file using pandoc.

.DESCRIPTION
    Accepts an array of URLs via parameter or pipeline, auto-detects whether
    each URL is a SharePoint page or a generic webpage, fetches the HTML
    content accordingly, concatenates everything into one document, and
    converts it to GitHub Flavored Markdown with pandoc.

    SharePoint pages are fetched through the Microsoft Graph API (requires
    the Microsoft.Graph.Authentication module and Sites.Read.All permission).
    Generic pages are fetched with Invoke-WebRequest.

    The resulting .md file path is returned as a [System.IO.FileInfo] object.

.PARAMETER Url
    One or more URLs to convert. Accepts pipeline input. SharePoint URLs
    (*.sharepoint.com) are handled via Microsoft Graph; all others are
    fetched directly over HTTP.

.PARAMETER OutputPath
    Optional path for the output Markdown file. Can be a directory (the
    filename is auto-generated) or a full file path. When omitted the file
    is created in the current directory with a name derived from the first
    page title.

.PARAMETER GraphScopes
    Microsoft Graph permission scopes requested when authenticating for
    SharePoint URLs.  Defaults to @('Sites.Read.All').

.PARAMETER SkipAuth
    Skip the automatic Connect-MgGraph call. Use this when you have already
    authenticated in the current session. If a SharePoint URL is provided
    and no Graph context exists, the function will throw.

.PARAMETER PandocPath
    Explicit path to the pandoc executable. When omitted the function
    searches PATH.

.PARAMETER IncludeSourceLinks
    Inserts a source-URL header above each page's content in the combined
    document.

.PARAMETER Force
    Overwrite the output file if it already exists.

.OUTPUTS
    [System.IO.FileInfo]  - The Markdown file that was created.

.EXAMPLE
    Convert-WebpageToMarkDown -Url 'https://example.com'

    Fetches example.com, converts to Markdown, and saves to .\example-com.md.

.EXAMPLE
    'https://example.com', 'https://httpbin.org/html' | Convert-WebpageToMarkDown -OutputPath 'C:\Docs\combined.md' -IncludeSourceLinks

    Fetches both pages, concatenates them with source links, and writes to
    the specified path.

.EXAMPLE
    Convert-WebpageToMarkDown -Url 'https://contoso.sharepoint.com/sites/Team/SitePages/Welcome.aspx' -SkipAuth

    Converts a SharePoint page using an existing Graph session. Throws if
    not already authenticated.

.NOTES
    Dependencies are installed automatically when missing:
      - pandoc is installed via winget if not found on PATH.
      - Microsoft.Graph.Authentication is installed from PSGallery when a
        SharePoint URL is provided.
    Uses Initialize-CmdletDependencies for helper loading and Write-Logg for
    structured logging.  Install-Dependencies handles PS module installation.
    Error handling uses Write-Logg -Level ERROR + continue so that a
    single bad URL does not abort the entire batch.
#>
function Convert-WebpageToMarkDown {

    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Url,

        [Parameter(Position = 1)]
        [string]$OutputPath,

        [string[]]$GraphScopes = @('Sites.Read.All'),

        [switch]$SkipAuth,

        [string]$PandocPath,

        [switch]$IncludeSourceLinks,

        [switch]$Force
    )

    begin {
        # ── dependency loading ────────────────────────────────────────────
        # Dot-source required cmdlets directly so they're available in this
        # function's scope.  Initialize-CmdletDependencies dot-sources inside
        # its own scope which makes the functions invisible to the caller.
        # Cmdlets this function calls directly, plus transitive dependencies
        # required by Install-Dependencies (Install-PSModule, Install-PackageProviders, etc.)
        $neededCmdlets = @(
            'Initialize-CmdletDependencies'
            'Install-Dependencies'
            'Get-FinalOutputPath'
            'Write-Logg'
            'Install-PSModule'
            'Install-PackageProviders'
            'Add-Assemblies'
            'Install-NugetDeps'
            'Add-NuGetDependencies'
            'Update-SessionEnvironment'
            'Get-EnvironmentVariable'
            'Get-EnvironmentVariableNames'
            'Invoke-RunAsAdmin'
            'Get-LongName'
            'Add-FileToAppDomain'
        )
        foreach ($cmdletName in $neededCmdlets) {
            if (-not (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
                $cmdletScript = Join-Path $PSScriptRoot "$cmdletName.ps1"
                if (Test-Path $cmdletScript) {
                    . $cmdletScript
                }
                else {
                    # Fallback: download from GitHub
                    $method = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$cmdletName.ps1"
                    . ([scriptblock]::Create($method))
                }
            }
        }

        # ── validate / install pandoc ─────────────────────────────────────
        if ($PandocPath) {
            if (-not (Test-Path $PandocPath)) {
                throw "Pandoc not found at specified path: $PandocPath"
            }
            $script:PandocExe = $PandocPath
        }
        else {
            $pandocCmd = Get-Command -Name 'pandoc' -ErrorAction SilentlyContinue
            if ($pandocCmd) {
                $script:PandocExe = $pandocCmd.Source
            }
            else {
                Write-Logg -Message 'pandoc not found on PATH — installing via WinGet PowerShell module...' -Level WARNING

                # Ensure the Microsoft.WinGet.Client module is available
                if (-not (Get-Module -Name Microsoft.WinGet.Client -ListAvailable -ErrorAction SilentlyContinue)) {
                    Write-Logg -Message 'Installing Microsoft.WinGet.Client module from PSGallery...' -Level INFO
                    $ProgressPreference = 'SilentlyContinue'
                    Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
                    Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -ErrorAction Stop | Out-Null
                }
                Import-Module Microsoft.WinGet.Client -ErrorAction Stop

                # Bootstrap WinGet package manager if needed
                try {
                    Repair-WinGetPackageManager -AllUsers -ErrorAction Stop
                }
                catch {
                    Write-Logg -Message "Repair-WinGetPackageManager failed: $_ — continuing anyway" -Level WARNING
                }

                # Install pandoc via WinGet module
                Install-WinGetPackage -Id JohnMacFarlane.Pandoc -Mode Silent -ErrorAction Stop

                # Refresh PATH so the current session can find the newly installed binary
                $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
                $pandocCmd = Get-Command -Name 'pandoc' -ErrorAction SilentlyContinue
                if (-not $pandocCmd) {
                    throw 'pandoc was installed but still cannot be found on PATH. You may need to restart your terminal.'
                }
                $script:PandocExe = $pandocCmd.Source
                Write-Logg -Message "pandoc installed successfully: $($script:PandocExe)" -Level INFO
            }
        }

        # ── accumulators ──────────────────────────────────────────────────
        $script:HtmlSections = New-Object System.Collections.Generic.List[string]
        $script:FirstTitle = $null
        $script:NeedsGraph = $false

        # ── SharePoint helper: extract HTML from a page via Graph ─────────
        function Get-SharePointPageHtml {
            param(
                [string]$PageUrl
            )

            $uri = [System.Uri]::new($PageUrl)
            $hostName = $uri.Host

            # Parse site path and page filename from URL segments
            # Expected pattern: /sites/<SiteName>/SitePages/<Page>.aspx
            $segments = $uri.AbsolutePath.TrimEnd('/') -split '/'
            $sitesIdx = [Array]::IndexOf($segments, 'sites')
            if ($sitesIdx -lt 0 -or ($sitesIdx + 1) -ge $segments.Count) {
                throw "Cannot parse SharePoint site path from URL: $PageUrl"
            }

            # Site path is everything up to (but not including) the SitePages segment
            $sitePagesIdx = [Array]::IndexOf($segments, 'SitePages')
            if ($sitePagesIdx -lt 0) {
                $sitePagesIdx = [Array]::IndexOf($segments, 'sitepages') 
            }

            if ($sitePagesIdx -gt $sitesIdx) {
                $sitePath = '/' + ($segments[$sitesIdx..$($sitePagesIdx - 1)] -join '/')
                $pageFile = $segments[-1]
            }
            else {
                # Fallback: treat last segment as page, rest as site path
                $sitePath = '/' + ($segments[$sitesIdx..$($segments.Count - 2)] -join '/')
                $pageFile = $segments[-1]
            }

            Write-Logg -Message "SharePoint host=$hostName  sitePath=$sitePath  page=$pageFile" -Level VERBOSE

            # 1) Resolve site
            $site = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/sites/${hostName}:${sitePath}"

            # 2) Find the page
            $pagesResponse = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/pages/microsoft.graph.sitePage?`$select=id,name,title,webUrl"

            $page = $pagesResponse.value |
                Where-Object { $_.name -eq $pageFile } |
                    Select-Object -First 1

            if (-not $page) {
                throw "SharePoint page not found: $pageFile"
            }

            # 3) Get web parts
            $webparts = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/sites/$($site.id)/pages/$($page.id)/microsoft.graph.sitePage/webparts"

            $parts = New-Object System.Collections.Generic.List[string]

            foreach ($wp in $webparts.value) {
                $odata = $wp.'@odata.type'
                switch ($odata) {
                    '#microsoft.graph.textWebPart' {
                        if ($wp.innerHtml) {
                            $parts.Add($wp.innerHtml) 
                        }
                    }
                    '#microsoft.graph.standardWebPart' {
                        $wpTitle = $wp.data.title
                        $wpDesc = $wp.data.description
                        if ($wpTitle) {
                            $parts.Add("<p><em>[SharePoint web part: $wpTitle]</em></p>")
                        }
                        elseif ($wpDesc) {
                            $parts.Add("<p><em>[SharePoint web part]</em> $wpDesc</p>")
                        }
                        else {
                            $parts.Add('<p><em>[SharePoint web part]</em></p>')
                        }
                    }
                    default {
                        $parts.Add("<p><em>[Unknown web part type: $odata]</em></p>")
                    }
                }
            }

            return @{
                Title  = $page.title
                Html   = ($parts -join "`n`n")
                WebUrl = $page.webUrl
            }
        }
    }

    process {
        foreach ($pageUrl in $Url) {
            $isSharePoint = $pageUrl -match '\.sharepoint\.com'

            # ── Microsoft Graph auth (once, on first SharePoint URL) ──────
            if ($isSharePoint -and -not $script:NeedsGraph) {
                $script:NeedsGraph = $true

                # Ensure the Graph module is available — install via Install-Dependencies if missing
                if (-not (Get-Module -Name Microsoft.Graph.Authentication -ListAvailable -ErrorAction SilentlyContinue)) {
                    Write-Logg -Message 'Microsoft.Graph.Authentication module not found — installing from PSGallery...' -Level WARNING
                    try {
                        Install-Dependencies -PSModule 'Microsoft.Graph.Authentication' -NoNugetPackage
                        Write-Logg -Message 'Microsoft.Graph.Authentication installed successfully.' -Level INFO
                    }
                    catch {
                        Write-Logg -Message "Failed to install Microsoft.Graph.Authentication: $_. Install manually with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser" -Level ERROR
                        continue
                    }
                }
                Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

                $ctx = Get-MgContext -ErrorAction SilentlyContinue
                if (-not $ctx) {
                    if ($SkipAuth) {
                        Write-Logg -Message 'No active Microsoft Graph session and -SkipAuth was specified. Run Connect-MgGraph first.' -Level ERROR
                        continue
                    }
                    Write-Logg -Message 'Connecting to Microsoft Graph...' -Level INFO
                    Connect-MgGraph -Scopes $GraphScopes -ErrorAction Stop
                }
            }

            try {
                if ($isSharePoint) {
                    Write-Logg -Message "Fetching SharePoint page: $pageUrl" -Level VERBOSE
                    $result = Get-SharePointPageHtml -PageUrl $pageUrl
                    $pageTitle = $result.Title
                    $pageHtml = $result.Html
                    $sourceUrl = $result.WebUrl
                }
                else {
                    Write-Logg -Message "Fetching generic webpage: $pageUrl" -Level VERBOSE
                    $response = Invoke-WebRequest -Uri $pageUrl -UseBasicParsing -ErrorAction Stop

                    # Extract <title> from HTML
                    if ($response.Content -match '<title[^>]*>([^<]+)</title>') {
                        $pageTitle = $matches[1].Trim()
                    }
                    else {
                        $pageTitle = ([System.Uri]::new($pageUrl)).Host
                    }

                    $pageHtml = $response.Content
                    $sourceUrl = $pageUrl
                }

                # Track the first title for auto-generated filename
                if (-not $script:FirstTitle) {
                    $script:FirstTitle = $pageTitle
                }

                # Build this page's HTML section
                $section = "<h1>$([System.Net.WebUtility]::HtmlEncode($pageTitle))</h1>`n"
                if ($IncludeSourceLinks) {
                    $section += "<p><strong>Source:</strong> <a href=`"$sourceUrl`">$sourceUrl</a></p>`n"
                }
                $section += "<hr />`n$pageHtml"

                $script:HtmlSections.Add($section)
                Write-Logg -Message "Accumulated page: $pageTitle" -Level VERBOSE

                # Throttle between Graph API calls
                if ($isSharePoint) {
                    Start-Sleep -Milliseconds 200
                }
            }
            catch {
                Write-Logg -Message "Failed to process URL '$pageUrl': $_" -Level ERROR
            }
        }
    }

    end {
        if ($script:HtmlSections.Count -eq 0) {
            Write-Logg -Message 'No pages were successfully fetched. Nothing to convert.' -Level WARNING
            return
        }

        # ── determine output markdown path ────────────────────────────────
        if ($OutputPath) {
            if (Test-Path -Path $OutputPath -PathType Container) {
                $autoName = Get-SafeFileName -Title $script:FirstTitle
                $mdPath = Join-Path $OutputPath $autoName
            }
            else {
                $mdPath = $OutputPath
                $parentDir = Split-Path $mdPath -Parent
                if ($parentDir -and -not (Test-Path $parentDir)) {
                    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
                }
            }
        }
        else {
            $autoName = Get-SafeFileName -Title $script:FirstTitle
            $mdPath = Join-Path $PWD $autoName
        }

        # Handle existing file
        if ((Test-Path $mdPath) -and -not $Force) {
            if (-not $PSCmdlet.ShouldProcess($mdPath, 'Overwrite existing file')) {
                Write-Logg -Message "File already exists: $mdPath. Use -Force to overwrite." -Level ERROR
                return
            }
        }

        # ── combine HTML and convert via pandoc ───────────────────────────
        $combinedHtml = $script:HtmlSections -join "`n`n<hr />`n`n"
        $tempHtml = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.html'

        try {
            Set-Content -Path $tempHtml -Value $combinedHtml -Encoding UTF8

            Write-Logg -Message 'Converting combined HTML to Markdown with pandoc...' -Level VERBOSE
            & $script:PandocExe $tempHtml -f html -t gfm -o $mdPath 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    Write-Logg -Message $_ -Level ERROR
                }
                else {
                    Write-Logg -Message $_ -Level VERBOSE
                }
            }

            if ($LASTEXITCODE -ne 0) {
                throw "pandoc exited with code $LASTEXITCODE"
            }

            Write-Logg -Message "Markdown saved to: $mdPath" -Level INFO
            return Get-Item -Path $mdPath
        }
        finally {
            if (Test-Path $tempHtml) {
                Remove-Item $tempHtml -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── private helper ────────────────────────────────────────────────────────
function Get-SafeFileName {
    param([string]$Title)
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = ($Title.ToCharArray() | Where-Object { $invalidChars -notcontains $_ }) -join ''
    $safe = ($safe -replace '\s+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = 'ConvertedWebpage-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    return "$safe.md"
}