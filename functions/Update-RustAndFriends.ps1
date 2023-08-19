# This function will update rust and cargo and make sure all exes installed by cargo are up to date
function Update-RustAndFriends {
    [CmdletBinding()]
    
    param(

    )
    
    Write-Log -Message 'Installing Rust'
    winget install Rustlang.Rustup --force --accept-source-agreements --accept-package-agreements
    Write-Log -Message 'Finished installing Rust'

    Write-Log -Message 'Installing Rust MSVC'
    winget install Rustlang.Rust.MSVC --force --accept-source-agreements --accept-package-agreements
    Write-Log -Message 'Finished installing Rust MSVC'

    Write-Log -Message 'Updating cargo'
    cargo install cargo-update
    cargo install-update -a
    Write-Log -Message 'Finished updating cargo'

}