function Get-FlashThumbnail {
    [CmdletBinding()]
    param (
        # the swf file to be converted to html
        [Parameter(Mandatory = $true)]
        [string]$swfFile,
        # the html file to be created
        [Parameter(Mandatory = $true)]
        [string]$htmlFile
    )
    $cmdlets = @('Write-Logg', 'Install-Dependencies')
    $module = Install-Cmdlet -RepositoryCmdlets $cmdlets
    $nugetpackages = @('Selenium.WebDriver', 'Newtonsoft.Json', 'Selenium.Support', 'Castle.Core')
    #Install-Dependencies -PSModule pansies -NugetPackage $nugetpackages
    Write-logg -Message "Installed cmdlets: $($module.ExportedCommands.Keys -join ', ')" -Level 'Info'
    Write-logg -Message 'Creating HTML files for each swf file in the assets directory...' -Level 'Info'

    # Path to the Ruffle executable
    $RuffleExecutable = "$ENV:USerprofile\Desktop\ruffle.exe"

    # Path to the assets directory containing SWF files
    $PathToAssets = 'C:\Users\travis\swf-to-html5\assets'

    # Generate HTML files
    Get-ChildItem "$PathToAssets\*.swf" -Recurse | ForEach-Object {
        $swfFile = $_
        $swfTitle = [System.IO.Path]::GetFileNameWithoutExtension($swfFile.Name)

        $htmlContent = @"
    <!DOCTYPE html>
    <html>
    <head>
        <title>$swfTitle</title>
        <script src="$RuffleWebPlayerPath/ruffle.js"></script>
    </head>
    <body>
        <object type="application/x-shockwave-flash" data="$($swfFile.FullName)" width="800" height="600">
            <param name="movie" value="$($swfFile.FullName)" />
            Ruffle has encountered a major issue whilst trying to display this Flash content.
        </object>
    </body>
    </html>
"@

        $htmlFilePath = "$PathToAssets\$swfTitle.html"
        $htmlContent | Out-File -FilePath $htmlFilePath
    }
    Write-Host 'HTML files generated. You can now open them in a browser to view the SWF files using Ruffle.'

    # after creating each html file, we will generate a thumbnail for each swf file
    # check if appium is installed, if not we will check if nodejs is installed, if not we will install it, and then install appium
    if (-not (Get-Command -Name 'appium' -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command -Name 'node' -ErrorAction SilentlyContinue)) {
            Write-Logg -Message 'Node.js is not installed. Installing Node.js...' -Level 'Info'
            winget install OpenJS.NodeJS --force
            #we will reimport the chocolatey install module so it refreshes the env variables
            Import-Module "$env:ChocolateyInstall\helpers\chocolateyInstaller.psm1" -Force

        }
        Write-Logg -Message 'Appium is not installed. Installing Appium...' -Level 'Info'
        npm i -g appium
    }
    else {
        # just update appium if it is already installed
        Write-Logg -Message 'Appium is already installed. Updating Appium...' -Level 'Info'
        npm update -g appium

        # Get the driver
        Write-Logg -Message 'Getting the Appium driver...' -Level 'Info'
        appium driver install uiautomator2
        # using OpenQA.Selenium.Interactions;

        # var touch = new PointerInputDevice(PointerKind.Touch, "finger");
        # var sequence = new ActionSequence(touch);
        # var move = touch.CreatePointerMove(elementToTouch, elementToTouch.Location.X, elementToTouch.Location.Y,TimeSpan.FromSeconds(1));
        # var actionPress = touch.CreatePointerDown(MouseButton.Touch);
        # var pause = touch.CreatePause(TimeSpan.FromMilliseconds(250));
        # var actionRelease = touch.CreatePointerUp(MouseButton.Touch);

        # sequence.AddAction(move);
        # sequence.AddAction(actionPress);
        # sequence.AddAction(pause);
        # sequence.AddAction(actionRelease);

        # var actions_seq = new List<ActionSequence>
        # {
        #     sequence
        # };

        # _driver.PerformActions(actions_seq);
    }

}