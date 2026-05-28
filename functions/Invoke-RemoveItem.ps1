function Invoke-RemoveItem {
    [CmdletBinding()]
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
            $removeParameters = @{
                LiteralPath = $resolvedPath
                ErrorAction = 'Stop'
                Confirm     = $false
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
                    if ($TakeOwnership -and $attempt -eq 1) {
                        Set-Removable -Path $resolvedPath -Recurse:$Recurse -ErrorAction Stop
                    }

                    if ($attempt -eq $RetryCount) {
                        throw "Failed to remove '$resolvedPath' after $RetryCount attempt(s): $($_.Exception.Message)"
                    }

                    Start-Sleep -Milliseconds $RetryDelayMilliseconds
                }
            }
        }
    }
}

function Set-Removable {
    [CmdletBinding()]
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
    $takeownArgs = @('/f', $resolvedPath)
    $icaclsArgs = @($resolvedPath, '/grant', "${env:USERNAME}:(F)")

    if ($Recurse -and (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        $takeownArgs += @('/r', '/d', 'Y')
        $icaclsArgs += @('/t', '/c')
    }

    & takeown.exe @takeownArgs 2>&1 | ForEach-Object { Write-Verbose -Message $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "takeown.exe failed for '$resolvedPath' with exit code $LASTEXITCODE."
    }

    & icacls.exe @icaclsArgs 2>&1 | ForEach-Object { Write-Verbose -Message $_ }
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

            $hasDeleteRight = ($access.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Delete) -eq [Security.AccessControl.FileSystemRights]::Delete
            $hasFullControl = ($access.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl

            if ($ruleApplies -and ($hasDeleteRight -or $hasFullControl)) {
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