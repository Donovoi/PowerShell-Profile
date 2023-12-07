function Get-CommandSource {
    <#
        .SYNOPSIS
         Gets command source code.

        .DESCRIPTION
         The Get-CommandSource cmdlet finds the source code/implementation for a cmdlet.

        .PARAMETER Name
         Specifies the path or name of the command to retrieve the source code. Accepts pipeline input.

        .PARAMETER Decompiler
         Specifies which decompiler or source will be used for browsing the source code.

        .INPUTS
         System.Management.Automation.CommandInfo
         System.String
            You can pipe command names to this cmdlet.

        .OUTPUTS
         System.Management.Automation.PSObject

        .EXAMPLE
         Get-CommandSource Write-Host

        .EXAMPLE
         Get-Command Write-Host | Get-CommandSource -Decompiler ILSpy

        .LINK
         https://github.com/aberus/ReflectCmdlet
    #>

    [CmdletBinding()]
    [OutputType([PSObject])]
    [Alias('gcmso')]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$Name,

        [Decompiler]$Decompiler
    )

    $commandInfo = if ($_ -is [System.Management.Automation.CommandInfo]) {
        $_
    }
    else {
        Get-Command -Name $Name
    }

    if ($commandInfo -is [System.Management.Automation.AliasInfo]) {
        $commandInfo = $commandInfo.ResolvedCommand
    }

    if ($commandInfo -is [System.Management.Automation.FunctionInfo]) {
        $object = New-Object PSObject -Property $([ordered]@{
                CommandType = $commandInfo.CommandType
                Name        = $commandInfo.Name
                Version     = $commandInfo.Version
                Type        = $commandInfo.CommandType
            })

        $functionPath = $commandInfo.ScriptBlock.File
        if ($functionPath) {
            $object | Add-Member -MemberType NoteProperty -Name Location -Value $functionPath
            Invoke-Item $functionPath
        }
        else {
            $modulePath = $commandInfo.Module.Path
            if ($modulePath) {
                $modulePath = Split-Path -Path $modulePath
                $object | Add-Member -MemberType NoteProperty -Name Location -Value $modulePath
                Invoke-Item $modulePath
            }
            else {
                Write-Error "Unable to find this function's file or module location"
            }
        }

        return $object
    }

    if ($commandInfo -is [System.Management.Automation.CmdletInfo]) {
        $assembly = $commandInfo.ImplementingType.Assembly.Location
        if (!$assembly) {
            $assembly = $commandInfo.DLL
        }
        $type = $commandInfo.ImplementingType.FullName

        if (($Decompiler -eq [Decompiler]::ILSpy -or !$Decompiler) -and (Get-Command ILSpy -ErrorAction Ignore)) {
            Start-Process -FilePath ILSpy -ArgumentList "`"$assembly`" /navigateTo:T:$type"
        }
        elseif (($Decompiler -eq [Decompiler]::dnSpy -or !$Decompiler) -and (Get-Command dnSpy -ErrorAction Ignore)) {
            Start-Process -FilePath dnSpy -ArgumentList "`"$assembly`" --select T:$type"
        }
        elseif (($Decompiler -eq [Decompiler]::dotPeek -or !$Decompiler) -and (Get-Command dotPeek -ErrorAction Ignore)) {
            Start-Process -FilePath dotPeek -ArgumentList /select=$assembly!$type
        }
        elseif (($Decompiler -eq [Decompiler]::JustDecompile -or !$Decompiler) -and (Get-Command JustDecompile -ErrorAction Ignore)) {
            Start-Process -FilePath JustDecompile -ArgumentList "/target:`"$assembly`""
        }
        elseif (($Decompiler -eq [Decompiler]::Reflector -or !$Decompiler) -and (Get-Command reflector -ErrorAction Ignore)) {
            Start-Process -FilePath reflector -ArgumentList "/select:$type `"$assembly`""
        }
        elseif ($Decompiler -eq [Decompiler]::GitHub -or !$Decompiler) {
            $class = $commandInfo.ImplementingType.Name
            $uri = "https://api.github.com/search/code?q=`"class+${class}`"+in:file+repo:powershell/powershell"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $result = Invoke-RestMethod -Uri $uri -Method Get
            if ($result) {
                $url = $result.items | Select-Object -ExpandProperty html_url
                Start-Process -FilePath $url
            }
        }
        else {
            throw 'Unable to find decompiler in your path'
        }

        $object = New-Object PSObject -Property $([ordered]@{
                CommandType = $commandInfo.CommandType
                Name        = $commandInfo.Name
                Version     = $commandInfo.Version
                Type        = $type
                Location    = $assembly
            })

        return $object
    }
}

enum Decompiler {
    dnSpy
    ILSpy
    dotPeek
    JustDecompile
    Reflector
    GitHub
}