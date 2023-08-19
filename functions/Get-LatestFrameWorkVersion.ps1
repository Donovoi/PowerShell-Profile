function Get-LatestFrameWorkVersion {
    [CmdletBinding()]
    param(
        [switch]$IncludeNetVersion
    )

    function WriteVersion {
        param(
            [string]$version,
            [string]$spLevel = ''
        )
        if (!$version) {
            return
        }
        $spLevelString = if ($spLevel) {
            " Service Pack $spLevel"
        }
        else {
            ''
        }

        Write-Output "${version}${spLevelString}"
    }


    function Get-1To45VersionFromRegistry {
        process {
            $ndpKey = Get-Item 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\'
            $ndpKey.GetSubKeyNames() | ForEach-Object {
                $versionKeyName = $_

                if ($versionKeyName -eq 'v4') {
                    return
                }

                if ($versionKeyName -like 'v*') {
                    $versionKey = $ndpKey.OpenSubKey($versionKeyName)
                    $name = $versionKey.GetValue('Version', '')
                    $sp = $versionKey.GetValue('SP', '').ToString()

                    $install = $versionKey.GetValue('Install', '').ToString()

                    if (!$install) {
                        WriteVersion $name
                    }
                    else {
                        if ($sp -and $install -eq '1') {
                            WriteVersion $name $sp
                        }
                    }

                    if ($name) {
                        return
                    }
                }
            }
        }
    }

    function Get-45PlusFromRegistry {
        process {
            $subkey = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\'

            $ndpKey = Get-Item $subkey

            if ($null -eq $ndpKey) {
                return
            }

            if ($null -ne $ndpKey.GetValue('Version')) {
                WriteVersion $ndpKey.GetValue('Version').ToString()
            }
            else {
                if ($null -ne $ndpKey.GetValue('Release')) {
                    WriteVersion (CheckFor45PlusVersion ([int]$ndpKey.GetValue('Release')))
                }
            }
        }
    }
    function CheckFor45PlusVersion {
        param(
            [int]$releaseKey
        )

        switch ($true) {
            { $releaseKey -ge 533320 } {
                '4.8.1'; break
            }
            { $releaseKey -ge 528040 } {
                '4.8'; break
            }
            { $releaseKey -ge 461808 } {
                '4.7.2'; break
            }
            { $releaseKey -ge 461308 } {
                '4.7.1'; break
            }
            { $releaseKey -ge 460798 } {
                '4.7'; break
            }
            { $releaseKey -ge 394802 } {
                '4.6.2'; break
            }
            { $releaseKey -ge 394254 } {
                '4.6.1'; break
            }
            { $releaseKey -ge 393295 } {
                '4.6'; break
            }
            { $releaseKey -ge 379893 } {
                '4.5.'
            } { '4.5.2'; break } {
                $releaseKey -ge 378675
            } { '4.5.1'; break } {
                $releaseKey -ge 378389
            } { '4.5'; break } {
                default {
                    $null
                }
            }
        }


    }

    <#
    .SYNOPSIS
        Short description
    .DESCRIPTION
        Long description
    .EXAMPLE
        Example of how to use this cmdlet
    .EXAMPLE
        Another example of how to use this cmdlet
    #>
    function Get-LatestDotNetVersionInstalled {
        [CmdletBinding()]
        [OutputType([version])]
        param(

        )

        # Get the latest installed .net version
        $Latestdotnetversion = (dotnet --list-runtimes |
                Where-Object { $_ -match 'Microsoft.NETCore.App\s(\d+\.\d+)' } |
                    ForEach-Object { $matches[1] } |
                        ForEach-Object {
                            try {
                                $version = New-Object System.Version($_)
                                $major = $version.Major
                                $minor = $version.Minor
                                if ($version.Build -ne -1) {
                                    "$major.$minor$($version.Build)"
                                }
                                else {
                                    "$major.$minor"
                                }
                            }
                            catch {
                                Write-Warning "Failed to parse version: $_"
                                continue
                            }
                        } |
                            Sort-Object -Descending | Select-Object -First 1 )

        # Get-1To45VersionFromRegistry
        $latestnetframworkversion = $(Get-45PlusFromRegistry) ? $(Get-45PlusFromRegistry) : $(Get-1To45VersionFromRegistry)


        #  Get latest install version of .NET Framework
        [float]$latestNetFrameWorkVersion = Get-LatestFrameWorkVersion -IncludeNetVersion | ForEach-Object {
            $splitParts = $_.ToString().Split('.', 3)
            if ($splitParts.Count -ge 2) {
                "$($splitParts[0]).$($splitParts[1])"
            }
            else {
                $_.ToString()
            }
        }


        # Rest of your code

        $versionTable = @{
            'net7.0'         = [float]'7.0'
            'net472'         = [float]'4.72'
            'netstandard2.1' = [float]'2.1'
        }

        if (-not $versionTable.ContainsKey($Latestdotnetversion)) {
            $versionTable[$Latestdotnetversion] = [float]$Latestdotnetversion
        }

        if (-not $versionTable.ContainsKey($latestNetFrameWorkVersion)) {
            $versionTable[$latestNetFrameWorkVersion] = [float]$latestNetFrameWorkVersion
        }

        # Resolving the version using ternary operator
        $versionForSwitch = $versionTable[$Latestdotnetversion] ? $versionTable[$Latestdotnetversion] : $versionTable[$latestNetFrameWorkVersion]


        # Switch statement
        switch ($versionForSwitch) {
            { $_ -ge $versionTable['net7.0'] } {
                $TerminalGuiPath = Get-ChildItem -Path $PWD -Filter 'net7.0-Terminal.Gui.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            { ($_ -ge $versionTable['net472']) -and ($_ -lt $versionTable['net7.0']) } {
                $TerminalGuiPath = Get-ChildItem -Path $PWD -Filter 'net472-Terminal.Gui.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            { ($_ -ge $versionTable['netstandard2.1']) -and ($_ -lt $versionTable['net472']) } {
                $TerminalGuiPath = Get-ChildItem -Path $PWD -Filter 'netstandard2.1-Terminal.Gui.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            }
            default {
                Write-Log -Message 'No matching version found possibly running this on an iphone'
                # write ascii art of an iphone and a confused face
                Write-Log -Message '¯\_(ツ)_/¯'
                # Now the iPhone
                Write-Log -Message '  /""""""""""""\'
                Write-Log -Message ' /              \'
                Write-Log -Message '|                |'
                Write-Log -Message '|                |'
                Write-Log -Message '|                |'
                Write-Log -Message '|                |'
                Write-Log -Message '|       iPhone   |'
                Write-Log -Message '|                |'
                Write-Log -Message '|                |'
                Write-Log -Message ' \              /'
                Write-Log -Message '  \____________/'
                # exit the script
                exit
            }

        }
    }


    return $latestnetframworkversion
}