# This function will update rust and cargo and make sure all exes installed by cargo are up to date
function Update-RustAndFriends {
    [CmdletBinding()]
    
    param(

    )
    
    Write-Host 'Installing Rust'
    winget install Rustlang.Rustup --force --accept-source-agreements --accept-package-agreements
    Write-Host 'Finished installing Rust'

    Write-Host 'Installing Rust MSVC'
    winget install Rustlang.Rust.MSVC --force --accept-source-agreements --accept-package-agreements
    Write-Host 'Finished installing Rust MSVC'

    Write-Host 'Updating cargo'
    cargo install cargo-update
    cargo install-update -a
    Write-Host 'Finished updating cargo'

}