function Find-FilesRust {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SearchTerm,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    # Create the Cargo.toml file
    $cargoToml = @'
[package]
name = "search_files"
version = "0.1.0"
edition = "2018"

[dependencies]
grep = "0.2"

[lib]
path = "src/lib.rs"    # The source file of the target.
crate-type = ["lib"]   # The crate types to generate.
required-features = [] # Features required to build this target (N/A for lib).

'@

    Set-Content -Path "$ENV:TEMP\Cargo.toml" -Value $cargoToml -Force

    # Create the main.rs file
    $rustCode = @'
use grep::regex::RegexMatcher;
use grep::searcher::sinks::UTF8;
use grep::searcher::Searcher;

#[no_mangle]
pub extern fn search_files(search_term: *const u8, directory: *const u8) {
    let search_term = unsafe { std::ffi::CStr::from_ptr(search_term as *const i8).to_str().unwrap() };
    let directory = unsafe { std::ffi::CStr::from_ptr(directory as *const i8).to_str().unwrap() };
    let matcher = RegexMatcher::new(search_term).unwrap();
    let mut sink = UTF8(|_, result| {
        if let Ok(line) = result {
            let cleaned: String = line.text().chars()
                .filter(|c| c.is_ascii() && *c != '\x09' && *c != '\x0A' && *c != '\x0D' && (*c < '\x20' || *c > '\x7E'))
                .collect();
            println!("{}", cleaned);
        }
        Ok(true)
    });
    let searcher = Searcher::new();
    searcher.search_path(&matcher, directory, &mut sink).unwrap();
}
'@

    if (-not (Test-Path -Path "$ENV:TEMP\src")) {
        New-Item -Path "$ENV:TEMP\src" -ItemType Directory -Force
    }
    Set-Content -Path "$ENV:TEMP\lib.rs" -Value $rustCode -Force

    # Compile the Rust code into a DLL

    cargo build --release --manifest-path "$ENV:TEMP\Cargo.toml" --lib

    # Load the DLL
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class SearchFiles {
    [DllImport("target\\release\\search_files.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void search_files(byte[] search_term, byte[] directory);
}
'@

    # Convert the search term and directory to bytes and call the Rust function
    $searchTermBytes = [System.Text.Encoding]::UTF8.GetBytes($SearchTerm)
    $directoryBytes = [System.Text.Encoding]::UTF8.GetBytes($Directory)
    [SearchFiles]::search_files($searchTermBytes, $directoryBytes)
}


# Find-FilesRust -SearchTerm 'test' -Directory 'C:\Users\user\Documents\'
