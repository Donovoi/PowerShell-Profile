
function Set-GitString {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepoFolder,

        [Parameter(Mandatory = $true)]
        [string]$SearchString,

        [Parameter(Mandatory = $true)]
        [string]$ReplacementString
    )

    # Navigate to the cloned repository's directory
    Set-Location $RepoFolder

    # Search for the string to replace
    $filesToReplace = git grep -l $SearchString | ForEach-Object { $_.Trim() }

    # Replace the string in each file
    foreach ($file in $filesToReplace) {
        Write-Host "Replacing '$SearchString' with '$ReplacementString' in $file ..."
        (Get-Content -Path $file) | ForEach-Object { $_ -replace $SearchString, $ReplacementString } | Set-Content -Path $file
    }

    # Stage the changes
    git add .

    # Commit the changes
    git commit -m "String replacement"

    # Push the changes to the remote repository
    git push origin main
}
