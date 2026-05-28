<#
.SYNOPSIS
    Removes files or directories with retry and optional ownership repair.

.DESCRIPTION
    Safely wraps Remove-Item for profile maintenance. The command never tests
    removability by deleting the target. It first tries Remove-Item, then optionally
    takes ownership and grants the current user full control before retrying.

.PARAMETER Path
    One or more paths to remove. Accepts pipeline input.

.PARAMETER RetryCount
    Number of delete attempts per path. Defaults to 3.

.PARAMETER RetryDelayMilliseconds
    Delay between retry attempts. Defaults to 300 milliseconds.

.PARAMETER TakeOwnership
    Uses takeown.exe and icacls.exe before retrying a failed delete.

.EXAMPLE
    Invoke-RemoveItem -Path 'C:\Temp\OldFolder' -Recurse -Force

.EXAMPLE
    Invoke-RemoveItem -Path 'C:\Temp\OldFolder' -Recurse -Force -TakeOwnership -Verbose
#>
function Invoke-RemoveItem {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, Position = 0)]
        [Alias('FullName', 'LiteralPath')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter()]
        [switch]$Recurse,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 60000)]
        [int]$RetryDelayMilliseconds = 300,

        [Parameter()]
        [switch]$TakeOwnership
    )

    process {
        foreach ($itemPath in $Path) {
            if (-not (Test-Path -LiteralPath $itemPath)) {
                Write-Verbose "Path does not exist: $itemPath"
                continue
            }

            $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($itemPath)
            if (-not $PSCmdlet.ShouldProcess($resolvedPath, 'Remove item')) {
                continue
            }

            $removeParameters = @{
                LiteralPath = $resolvedPath
                ErrorAction = 'Stop'
            }
            if ($Recurse) {
                $removeParameters.Recurse = $true 
            }
            if ($Force) {
                $removeParameters.Force = $true 
            }

            for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
                try {
                    Remove-Item @removeParameters
                    Write-Verbose "Removed '$resolvedPath'."
                    break
                }
                catch {
                    $isLastAttempt = $attempt -eq $RetryCount

                    if ($TakeOwnership -and $attempt -eq 1) {
                        $ownershipParameters = @{
                            Path        = $resolvedPath
                            Recurse     = $Recurse
                            ErrorAction = 'Stop'
                        }
                        if ($VerbosePreference -ne 'SilentlyContinue') {
                            $ownershipParameters.Verbose = $true
                        }
                        Set-Removable @ownershipParameters
                    }

                    if ($isLastAttempt) {
                        throw "Failed to remove '$resolvedPath' after $RetryCount attempt(s): $($_.Exception.Message)"
                    }

                    Start-Sleep -Milliseconds $RetryDelayMilliseconds
                }
            }
        }
    }
}

function Set-Removable {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $PSCmdlet.ShouldProcess($resolvedPath, 'Take ownership and grant full control')) {
        return
    }

    $takeownArgs = @('/f', $resolvedPath)
    $icaclsArgs = @($resolvedPath, '/grant', "${env:USERNAME}:(F)")

    if ($Recurse -and (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        $takeownArgs += @('/r', '/d', 'Y')
        $icaclsArgs += @('/t', '/c')
    }

    $takeownOutput = & takeown.exe @takeownArgs 2>&1
    $takeownOutput | ForEach-Object { Write-Verbose -Message $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "takeown.exe failed for '$resolvedPath' with exit code $LASTEXITCODE."
    }

    $icaclsOutput = & icacls.exe @icaclsArgs 2>&1
    $icaclsOutput | ForEach-Object { Write-Verbose -Message $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "icacls.exe failed for '$resolvedPath' with exit code $LASTEXITCODE."
    }
}

function Test-IsRemovable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $acl = Get-Acl -LiteralPath $resolvedPath -ErrorAction Stop
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)

        foreach ($access in $acl.Access) {
            if ($access.AccessControlType -ne 'Allow') {
                continue 
            }

            $ruleApplies =
            $access.IdentityReference.Value -eq $identity.Name -or
            $principal.IsInRole($access.IdentityReference.Value)

            if ($ruleApplies -and (($access.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) -or ($access.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl))) {
                return $true
            }
        }

        return $false
    }
    catch {
        Write-Verbose "Could not determine removability for '$Path': $($_.Exception.Message)"
        return $false
    }
}