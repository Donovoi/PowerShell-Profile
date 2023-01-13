<#
.SYNOPSIS
This function will download and install any missing VC++ Distributables
.EXAMPLE
Update-VcRedist -DownloadDirectory "C:\temp";
#>

function Update-VcRedist {
    [CmdletBinding()]
    param(
        [string][Parameter(mandatory = $false)] $DownloadDirectory = "$ENV:USERPROFILE\Downloads"
    )
  
    begin {
        ##we need to install a few things before we install any modules
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            Install-PackageProvider -Name NuGet -Force;
        }

        Install-Module -Name VcRedist -Force;
        Import-Module -Name VcRedist;
        $VcFolder = New-Item -Path "$DownloadDirectory\VcRedist" -ItemType Directory -Force;
    }
  
    process {
        # Install VC++ Redis, if it fails then the install needs to stop so we can fix it
        try {
            Get-VcList | Save-VcRedist -Path $VcFolder;
            $VcList = Get-VcList;
            Install-VcRedist -VcList $VcList -Path $VcFolder;
        }
        catch {
            Write-Host $_;
            Write-Error 'There is a problem installing the required Visual Studio Redistributables' -ErrorAction Stop;
        }
    }
  
    end {
        #Sometimes VC++ 2013 is not installed via the above method - so ensuring it is installed
        Invoke-WebRequest -Uri 'http://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x64.exe' -Verbose -UseBasicParsing -OutFile "$DownloadDirectory\vc2013.exe";
        Start-Process -FilePath "$DownloadDirectory\vc2013.exe" -ArgumentList '/install /passive';
  
        Write-Host 'All Done!';
    }
}