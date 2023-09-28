<#
.SYNOPSIS
This function is used to invoke a process with the given file path and argument list.
It is a wrapper around the Start-Process cmdlet.

.DESCRIPTION
Taken from work done by Adam Bertram https://www.powershellgallery.com/packages/Invoke-Process/1.4/Content/Invoke-Process.ps1
The Invoke-Process function is an advanced function that supports common parameters like, -Debug etc.
It takes a mandatory file path and an optional argument list as input parameters.
The function also defines dynamic parameters for the Start-Process cmdlet excluding the 'FilePath', 'ArgumentList' and common parameters.

.PARAMETER FilePath
A mandatory parameter that specifies the file path of the process to be invoked. This parameter should not be null or empty.

.PARAMETER ArgumentList
An optional parameter that specifies the argument list for the process to be invoked. This parameter should not be null or empty.

.EXAMPLE
$rcloneexe = Join-Path -Path $PWD -ChildPath '.\rclone.exe' -Resolve
$RCloneConfig = Join-Path -Path $PWD -ChildPath '.\rclone.conf' -Resolve
$Arguments = @(
    'config',
    'create',
    'onedrive',
    'onedrive',
    "--config `"$RCloneConfig`""
)
$RCloneProcessParams = @{
    FilePath     = "$rcloneexe"
    ArgumentList = $Arguments
    NoNewWindow  = $true
    PassThru     = $true
    #Wait         = $true #dont use wait, it will hang the script
}

Invoke-Process @RCloneProcessParams

This example demonstrates how to use the Invoke-Process function to start a process with the specified file path and argument list.

.NOTES
The function creates temporary files for standard output and error. It then starts the process and keeps checking the process until it has exited. During this time, it writes new lines of standard output and error to the console. If any exception occurs, it throws a terminating error. Finally, it removes the temporary files.
#>
function Invoke-Process {
    # CmdletBinding attribute is used to make this function advanced which means it will support common parameters like, -Debug etc.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Mandatory parameter for file path. It should not be null or empty.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        # Optional parameter for argument list. It should not be null or empty.
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$ArgumentList
    )

    # Dynamic parameters are defined in this block.
    dynamicparam {
        # Get all parameters of Start-Process cmdlet.
        $startProcessParams = (Get-Command Start-Process).ParameterSets.parameters

        # Create a dictionary to hold dynamic parameters.
        $paramDictionary = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary

        # Define an array to hold names of parameters to ignore.
        $paramsToIgnore = @('FilePath', 'ArgumentList')

        # Add optional common parameters to ignore list.
        foreach ($param in [System.Management.Automation.PSCmdlet]::OptionalCommonParameters) {
            $paramsToIgnore += $param
        }

        # Add mandatory common parameters to ignore list.
        foreach ($param in [System.Management.Automation.PSCmdlet]::CommonParameters) {
            $paramsToIgnore += $param
        }

        # Iterate over each parameter of Start-Process cmdlet.
        foreach ($param in $startProcessParams) {
            # Skip parameters that are in ignore list.
            if ($param.Name -notin $paramsToIgnore) {
                # Create a new ParameterAttribute object.
                $attributes = New-Object System.Management.Automation.ParameterAttribute
                $attributes.Mandatory = $false

                # Create a collection to hold attributes.
                $attributeCollection = New-Object `
                    -Type System.Collections.ObjectModel.Collection[System.Attribute]
                $attributeCollection.Add($attributes)

                # Add a ValidateScript attribute for the Wait parameter.
                if ($param.Name -eq 'Wait') {
                    $validateScript = New-Object System.Management.Automation.ValidateScriptAttribute -ArgumentList {
                        if ($_ -eq $true) {
                            throw 'The Wait parameter is not supported at the moment.'
                        }
                    }
                    $attributeCollection.Add($validateScript)
                }

                # Get the type of the parameter.
                $paramType = $param.ParameterType

                # Create a new RuntimeDefinedParameter object.
                $dynParam1 = New-Object `
                    -Type System.Management.Automation.RuntimeDefinedParameter `
                    -ArgumentList ($param.name, $paramType, $attributeCollection)

                # Check if the key already exists in the dictionary.
                if (-not $paramDictionary.ContainsKey($param.Name)) {
                    $paramDictionary.Add($param.Name, $dynParam1)
                }
            }
        }
        return $paramDictionary
    }

    # Process block contains the main script that the function executes.
    process {
        try {
            # Create temporary files for standard output and error.
            $stdOutTempFile = "$env:TEMP\$((New-Guid).Guid)"
            $stdErrTempFile = "$env:TEMP\$((New-Guid).Guid)"

            # Define parameters for Start-Process cmdlet.
            $startProcessParams = @{
                FilePath               = $FilePath
                ArgumentList           = $ArgumentList
                RedirectStandardError  = $stdErrTempFile
                RedirectStandardOutput = $stdOutTempFile
            }
            # Merge the PSBoundParameters into the startProcessParams hashtable.
            foreach ($key in $PSBoundParameters.Keys) {
                if ($key -notin @('FilePath', 'ArgumentList')) {
                    $startProcessParams[$key] = $PSBoundParameters[$key]
                }
            }

            # Check if the cmdlet should process further based on ShouldProcess result.
            if ($PSCmdlet.ShouldProcess("Process [$($FilePath)]", "Run with args: [$($ArgumentList)]")) {
                # Start the process and get the process ID.
                $cmd = Start-Process @startProcessParams
                $processId = $cmd.Id
                $lastStdOutLineIndex = 0
                $lastStdErrLineIndex = 0

                # Keep checking the process until it has exited.
                do {
                    # Get the content of standard output and error files.
                    $cmdOutput = Get-Content -Path $stdOutTempFile
                    $cmdError = Get-Content -Path $stdErrTempFile

                    # Write new lines of standard output to console.
                    if ($cmdOutput.Count -gt $lastStdOutLineIndex) {
                        Write-Output -InputObject $cmdOutput[$lastStdOutLineIndex..($cmdOutput.Count - 1)]
                        $lastStdOutLineIndex = $cmdOutput.Count
                    }

                    # Write new lines of standard error to console.
                    if ($cmdError.Count -gt $lastStdErrLineIndex) {
                        Write-Output -Message $cmdError[$lastStdErrLineIndex..($cmdError.Count - 1)]
                        $lastStdErrLineIndex = $cmdError.Count
                    }

                    # Sleep for a second.
                    Start-SleepWithCountdown -Seconds 1 -NoConsoleOutput

                } while (Get-Process -Id $processId -ErrorAction SilentlyContinue)

                # If the process has exited, write remaining lines of standard output and error to console.
                if ($cmd.HasExited) {
                    if ($cmdOutput.Count -gt $lastStdOutLineIndex) {
                        Write-Output -InputObject $cmdOutput[$lastStdOutLineIndex..($cmdOutput.Count - 1)]
                        $lastStdOutLineIndex = $cmdOutput.Count
                    }

                    if ($cmdError.Count -gt $lastStdErrLineIndex) {
                        Write-Error -Message $cmdError[$lastStdErrLineIndex..($cmdError.Count - 1)]
                        $lastStdErrLineIndex = $cmdError.Count
                    }
                }
            }
        }
        catch {
            # Throw terminating error if any exception occurs.
            $PSCmdlet.ThrowTerminatingError($_)
        }
        finally {
            # Remove temporary files in the end.
            Remove-Item -Path $stdOutTempFile, $stdErrTempFile -Force -ErrorAction Ignore
        }
    }
}