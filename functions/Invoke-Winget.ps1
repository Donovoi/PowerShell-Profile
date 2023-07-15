function Invoke-Winget {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Position = 0, Mandatory = $true)]
        [ValidateSet('install', 'show', 'source', 'search', 'list', 'upgrade', 'uninstall', 'hash', 'validate', 'settings', 'features', 'export', 'import')]
        [string]$WCommand
    )

    dynamicparam {
        $paramDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
    
        $commandParams = @{
            'install'   = @('Manifest', 'Id', 'Name', 'Moniker', 'Version', 'Source', 'Scope', 'Exact', 'Interactive', 'Silent', 'Log', 'Override', 'Location', 'Force')
            'show'      = @('Manifest', 'Id', 'Version', 'Source')
            'source'    = @('Name', 'Arg', 'Type')
            'search'    = @('Query', 'Id', 'Name', 'Moniker', 'Tag', 'Command', 'Exact', 'Count', 'Source')
            'list'      = @('Query', 'Id', 'Name', 'Moniker', 'Source', 'Tag', 'Command', 'Exact', 'Count')
            'upgrade'   = @('Manifest', 'Id', 'Name', 'Moniker', 'Version', 'Source', 'Exact', 'Interactive', 'Silent', 'Log', 'Override', 'Location', 'Force', 'All', 'IncludeUnknown')
            'uninstall' = @('Manifest', 'Id', 'Name', 'Moniker', 'Version', 'Source', 'Exact', 'Interactive', 'Silent', 'Log', 'Override')
            'hash'      = @('File', 'Msix')
            'validate'  = @('Manifest', 'Help')
            'export'    = @('Output', 'Source', 'IncludeVersions')
            'import'    = @('ImportFile', 'IgnoreUnavailable', 'IgnoreVersions')
        }
    
        foreach ($param in $commandParams[$WCommand]) {
            $attributes = New-Object System.Management.Automation.ParameterAttribute
            $attributes.Mandatory = $false
            $attributes.ParameterSetName = $WCommand

            # Set 'Query' parameter as the first positional parameter for 'search' command
            if ($WCommand -eq 'search' -and $param -eq 'Query') {
                $attributes.Position = 0
            }

            $paramDictionary.Add($param, $(New-Object System.Management.Automation.RuntimeDefinedParameter($param, [string], $attributes)))
        }
    
        return $paramDictionary
    }
    
    process {
        try {
            $params = $PSBoundParameters
            $params.Remove('WCommand') | Out-Null            
            Write-Host "Executing command: winget $WCommand $($($params.Values.GetEnumerator())[-1])"
            $wingetoutput = cmd /c "winget $WCommand $($($params.Values.GetEnumerator())[-1])" | Out-String -Stream
            Write-Host "Command output: $wingetoutput"

            # convert output to objects using ConvertFrom-String
            # parse the wingetout into objects
            # Here's a sample
            #  Name                          Id                                       Version Match      Source
            # -------------------------------------------------------------------------------------------------
            # NuGet Package Explorer        9WZDNCRDMDM3                             Unknown            msstore
            # NuGet Cache Cleaner           9P7MQ2FFX51F                             Unknown            msstore
            # NuGet                         Microsoft.NuGet                          6.5.0              winget
            # MSBuild Structured Log Viewer KirillOsenkov.MSBuildStructuredLogViewer 2.1.790 Tag: nuget winget

            $WingetObjects = @{}
            $parsedWingetOutput = $wingetOutput | ConvertFrom-String -PropertyNames Name, Id, Version, Match, Source | Where-Object { $_.Name -ne 'Name'} | Where-Object {$_ -notmatch '(?!.*[a-zA-Z]).*'}
            foreach($line in $parsedWingetOutput) {
                if ([string]::IsNullOrWhiteSpace($_.Name) -or ($_.Name -eq 'Name')) {
                    continue
                }
                $wingetobject = New-Object -TypeName PSObject -Property @{
                    Name    = $_.Name
                    Id      = $_.Id
                    Version = $_.Version
                    Match   = $_.Match
                    Source  = $_.Source
                }

                $WingetObjects += $wingetobjects
                
            }


            return $wingetobjects

        }
        catch {
            Write-Error "Failed to execute command: $_"
        }
    }
    
}
