<#  
      .SYNOPSIS  
           Install Open Text and True Type Fonts  
        
      .DESCRIPTION  
           This script will install OTF and TTF fonts that exist in the same directory as the script.  
        
      .NOTES  
           ===========================================================================  
           Created with:    SAPIEN Technologies, Inc., PowerShell Studio 2021 v5.8.187  
           Created on:      6/24/2021 9:36 AM  
           Created by:      Mick Pletcher  
           Filename:        InstallFonts.ps1  
           ===========================================================================  
 #>  
   
<#  
      .SYNOPSIS  
           Install the font  
        
      .DESCRIPTION  
           This function will attempt to install the font by copying it to the c:\windows\fonts directory and then registering it in the registry. This also outputs the status of each step for easy tracking.   
        
      .PARAMETER FontFile  
           Name of the Font File to install  
        
      .EXAMPLE  
                     PS C:\> Install-Font -FontFile $value1  
        
      .NOTES  
           Additional information about the function.  
 #>  
function Install-Fonts {  
    [CmdletBinding()]
    param  
    (  
        #[Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][System.IO.FileInfo]$FontFile,
        [Parameter(Mandatory = $false)][string]$Path = "$PWD"           
    )  


    $FontItems = Get-ChildItem -Path $Path -Recurse | Where-Object { ($_.Name -like '*.ttf') -or ($_.Name -like '*.OTF') }
    $FontItems | ForEach-Object -ThrottleLimit 999999 -Parallel {
        #   Force garbage collection
        [System.GC]::Collect()
        $FontFile = $_
        #Get Font Name from the File's Extended Attributes  
        $oShell = New-Object -com shell.application  
        $Folder = $oShell.namespace($FontFile.DirectoryName)  
        $Item = $Folder.Items().Item($FontFile.Name)  
        $FontName = $Folder.GetDetailsOf($Item, 21)  
        try {  
            switch ($FontFile.Extension) {  
                '.ttf' {
                    $FontName = $FontName + [char]32 + '(TrueType)'
                }  
                '.otf' {
                    $FontName = $FontName + [char]32 + '(OpenType)'
                }  
            }  
            $Copy = $true  
            Write-Verbose ('Copying' + [char]32 + $FontFile.Name + '.....') 
            Copy-Item -Path $fontFile.FullName -Destination ('C:\Windows\Fonts\' + $FontFile.Name) -Force  
            #Test if font is copied over  
            If ((Test-Path ('C:\Windows\Fonts\' + $FontFile.Name)) -eq $true) {  
                Write-Verbose ('Success') 
            }
            else {  
                Write-Verbose ('Failed') 
            }  
            $Copy = $false  
            #Test if font registry entry exists  
            If ($null -ne (Get-ItemProperty -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue)) {  
                #Test if the entry matches the font file name  
                If ((Get-ItemPropertyValue -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') -eq $FontFile.Name) {  
                    Write-Verbose ('Adding' + [char]32 + $FontName + [char]32 + 'to the registry.....') 
                    Write-Verbose ('Success') 
                }
                else {  
                    $AddKey = $true  
                    Remove-ItemProperty -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -Force  
                    Write-Verbose ('Adding' + [char]32 + $FontName + [char]32 + 'to the registry.....') 
                    New-ItemProperty -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -PropertyType string -Value $FontFile.Name -Force -ErrorAction SilentlyContinue | Out-Null  
                    If ((Get-ItemPropertyValue -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') -eq $FontFile.Name) {  
                        Write-Verbose ('Success') 
                    }
                    else {  
                        Write-Verbose ('Failed') 
                    }  
                    $AddKey = $false  
                }  
            }
            else {  
                $AddKey = $true  
                Write-Verbose ('Adding' + [char]32 + $FontName + [char]32 + 'to the registry.....') 
                New-ItemProperty -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -PropertyType string -Value $FontFile.Name -Force -ErrorAction SilentlyContinue | Out-Null  
                If ((Get-ItemPropertyValue -Name $FontName -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts') -eq $FontFile.Name) {  
                    Write-Verbose ('Success') 
                }
                else {  
                    Write-Verbose ('Failed') 
                }  
                $AddKey = $false  
            }  
           
        }
        catch {  
            If ($Copy -eq $true) {  
                Write-Verbose ('Failed') 
                $Copy = $false  
            }  
            If ($AddKey -eq $true) {  
                Write-Verbose ('Failed') 
                $AddKey = $false  
            }  
            Write-Warning $_.exception.message  
        }  
    }  
}

#Install-Fonts -Path 'I:\nerd-fonts-master (1)\' -Verbose