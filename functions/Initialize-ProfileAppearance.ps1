function Initialize-ProfileAppearance {
    <#
    .SYNOPSIS
    Configures installed prompt and keyboard tools without installing dependencies.
    .DESCRIPTION
    Safe to call repeatedly. Invoke-OhMyPoshRandomTheme can be called directly to
    install Oh My Posh or obtain remote themes. Startup finds Store/MSIX themes
    and uses the executable's built-in default if no local theme is available.
    #>
    [CmdletBinding()]
    param()

    $poshBin = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin'
    if ((Test-Path -LiteralPath $poshBin -PathType Container) -and
        $poshBin.TrimEnd('\') -notin @($env:PATH -split ';' | ForEach-Object { $_.Trim().Trim('"').TrimEnd('\') })) {
        $env:PATH = $env:PATH.TrimEnd(';') + ';' + $poshBin
    }
    if (Get-Command Set-PSReadLineKeyHandler -ErrorAction Ignore) {
        try {
            # Set the mode first because changing it resets the key map.
            Invoke-SamplePSReadLineProfile -EditMode Windows -ErrorAction Stop
            foreach ($key in @('"', "'", '(', ')', '{', '}', '[', ']')) {
                Set-PSReadLineKeyHandler -Key $key -Function SelfInsert -ErrorAction Stop
            }
            Set-PSReadLineKeyHandler -Key Tab -Function Complete -ErrorAction Stop
        }
        catch { Write-Warning "PSReadLine configuration failed: $($_.Exception.Message)" }
    }
    if (-not $script:ProfilePromptInitialized -and (Get-Command oh-my-posh -CommandType Application -ErrorAction Ignore)) {
        try {
            $script:ProfilePromptInitialized = [bool](Invoke-OhMyPoshRandomTheme -LocalOnly -PassThru -ErrorAction Stop)
        }
        catch { Write-Warning "Prompt configuration failed: $($_.Exception.Message)" }
    }
}
