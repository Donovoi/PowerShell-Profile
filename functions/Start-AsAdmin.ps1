function Start-AsAdmin {
    <#
    .SYNOPSIS
    Starts an elevated PowerShell shell or an explicitly named script.
    .DESCRIPTION
    Never exits the caller. Without FilePath, opens an interactive elevated shell.
    Script arguments are individual values, safely encoded before the UAC handoff.
    PassThru returns the launched process. WindowsPowerShell selects the legacy host.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Diagnostics.Process])]
    param(
        [Alias('ScriptPath')] [string]$FilePath,
        [AllowEmptyString()] [string[]]$ArgumentList = @(),
        [switch]$WindowsPowerShell,
        [switch]$PassThru
    )
    if (-not $IsWindows) { throw 'Start-AsAdmin requires Windows.' }
    if ($ArgumentList.Count -and -not $FilePath) { throw 'ArgumentList requires FilePath.' }
    $executable = if ($WindowsPowerShell) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $PSHOME 'pwsh.exe' }
    $arguments = @('-NoLogo', '-NoProfile')
    if ($FilePath) {
        $resolvedPath = (Get-Item -LiteralPath $FilePath -ErrorAction Stop).FullName
        if ([IO.Path]::GetExtension($resolvedPath) -ine '.ps1' -or -not [IO.File]::Exists($resolvedPath)) { throw 'FilePath must identify an existing .ps1 file.' }
        $payload = @{ Path = $resolvedPath; Arguments = @($ArgumentList) } | ConvertTo-Json -Compress
        $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $command = '$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $payload64 + ''')) | ConvertFrom-Json; $scriptArguments = @($p.Arguments); & $p.Path @scriptArguments'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $arguments += @('-EncodedCommand', $encoded)
    }
    if ($PSCmdlet.ShouldProcess($(if ($FilePath) { $resolvedPath } else { $executable }), 'Start elevated PowerShell')) {
        Start-Process -FilePath $executable -ArgumentList $arguments -Verb RunAs -WorkingDirectory $PWD.ProviderPath -WindowStyle $(if ($FilePath) { 'Hidden' } else { 'Normal' }) -PassThru:$PassThru
    }
}
