# This function will update rust and cargo and make sure all exes installed by cargo are up to date
function Update-RustAndFriends {
    [CmdletBinding()]
    
    param(

    )
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing Rust'
        winget install Rustlang.Rustup --force --accept-source-agreements --accept-package-agreements
        Write-Host 'Finished installing Rust'
    }
    else {
        Write-Host 'Updating Rust'
        winget install Rustlang.Rust --force --accept-source-agreements --accept-package-agreements
        Write-Host 'Finished updating Rust'
    }
    Write-Host 'Updating cargo'
    cargo install cargo-update
    cargo install-update -a
    Write-Host 'Finished updating cargo'

}