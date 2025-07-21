function Update-SessionEnvironment {
    # (1) Import required cmdlets if missing
    $neededcmdlets = @(
        'Write-Logg',
        'Write-InformationColored',
        'Get-EnvironmentVariable'
        'Get-EnvironmentVariableNames'
    )
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }
    $refreshEnv = $false
    $invocation = $MyInvocation

    if ($invocation.InvocationName -eq 'refreshenv') {
        $refreshEnv = $true
    }

    if ($refreshEnv) {
        Write-Logg -Message 'Refreshing environment variables from the registry for powershell.exe. Please wait...'
    }
    else {
        Write-Verbose 'Refreshing environment variables from the registry.'
    }

    $userName = $env:USERNAME
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $psModulePath = $env:PSModulePath

    # ordering is important, user should override machine...
    $ScopeList = 'Process', 'Machine'
    if ('SYSTEM', "${env:COMPUTERNAME}`$" -notcontains $userName) {
        $ScopeList += 'User'
    }
    foreach ($Scope in $ScopeList) {
        Get-EnvironmentVariableNames -Scope $Scope |
            ForEach-Object {
                Set-Item "Env:$_" -Value (Get-EnvironmentVariable -Scope $Scope -Name $_)
            }
    }

    # unify PATH
    $paths = 'Machine', 'User' | ForEach-Object {
        (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
    } | Select-Object -Unique

    $Env:PATH = $paths -join ';'

    # preserve the PSModulePath
    $env:PSModulePath = $psModulePath

    # reset user and architecture
    if ($userName) {
        $env:USERNAME = $userName
    }
    if ($architecture) {
        $env:PROCESSOR_ARCHITECTURE = $architecture
    }

    if ($refreshEnv) {
        Write-Logg -Message 'Finished' -Level VERBOSE
    }
}