$sessionName = New-PSSession -UseWindowsPowerShell
# Import the module in the session
Invoke-Command -Session $sessionName -ScriptBlock {
    if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
    }
    $cmdlets = @('Install-Dependencies')
    if (-not (Get-Command -Name 'Install-Dependencies' -ErrorAction SilentlyContinue)) {
        Write-Verbose -Message "Importing cmdlets: $cmdlets"
        $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $cmdlets
        $Cmdletstoinvoke | Import-Module -Force
        if (-not(Get-Module -Name 'PSReflect-Functions' -ErrorAction SilentlyContinue)) {
            Install-Dependencies -PSModule PSReflect-Functions -ErrorAction SilentlyContinue -NoNugetPackages
        }
        Import-Module -Name 'PSReflect-Functions' -Force
    }
}
# Now we can use the module in pwsh 7.1
Import-Module -PSSession $sessionName -Force -Name PSReflect-Functions

$kernel32::CopyFileExW($DriveLetter, $Destination, $ProgressRoutine, $Data, $Cancel, $dwFlags)