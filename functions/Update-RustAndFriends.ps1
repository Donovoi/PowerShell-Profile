# This function will update rust and cargo and make sure all exes installed by cargo are up to date
function Update-RustAndFriends {
    [CmdletBinding()]
    
    param(

    )
    
    Write-Logg -Message 'Installing Rust'
    winget install Rustlang.Rustup --force --accept-source-agreements --accept-package-agreements
    Write-Logg -Message 'Finished installing Rust'

    Write-Logg -Message 'Installing Rust MSVC'
    winget install Rustlang.Rust.MSVC --force --accept-source-agreements --accept-package-agreements
    Write-Logg -Message 'Finished installing Rust MSVC'

    Write-Logg -Message 'Updating cargo'
    cargo install cargo-update
    cargo install-update -a
    Write-Logg -Message 'Finished updating cargo'

}