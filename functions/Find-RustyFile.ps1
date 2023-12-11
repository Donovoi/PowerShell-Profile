function Find-RustyFile {
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [bool]$UseRegex,

        [Parameter(Mandatory = $false)]
        [string]$StartDir = $PWD
    )

    begin {
        # Step 1: Generate Cargo.toml
        $cargoTomlContent = @'
        [package]
        name = "file_search"
        version = "0.1.0"
        edition = "2021"
        crate-type = ["cdylib"]

        # See more keys and their definitions at https://doc.rust-lang.org/cargo/reference/manifest.html

        [dependencies]
        regex = "1.10.2"
        glob = "0.3.1"
'@

        # Save Cargo.toml in the current directory
        $cargoTomlPath = Join-Path $PWD 'Cargo.toml'
        Set-Content -Path $cargoTomlPath -Value $cargoTomlContent -Force

        # Step 2: Generate Rust Source File
        $rustSource = @'
        use regex::Regex;
        use glob::glob;
        use std::path::PathBuf;
        use std::ffi::{CString, CStr};
        use std::os::raw::c_char;
        use std::time::{Instant};

        #[no_mangle]
        pub extern "C" fn search_files(pattern: *const c_char, use_regex: bool, start_dir: *const c_char, measure_time: bool) -> *mut c_char {
            let start_time = Instant::now();

            let pattern_str = unsafe {
                match CStr::from_ptr(pattern).to_str() {
                    Ok(str) => str.to_owned(),
                    Err(_) => return std::ptr::null_mut(),
                }
            };

            let start_dir_str = unsafe {
                match CStr::from_ptr(start_dir).to_str() {
                    Ok(str) => str.to_owned(),
                    Err(_) => return std::ptr::null_mut(),
                }
            };

            let paths = if use_regex {
                search_with_regex(&pattern_str, &start_dir_str).unwrap_or_else(|_| Vec::new())
            } else {
                search_with_glob(&pattern_str, &start_dir_str).unwrap_or_else(|_| Vec::new())
            };

            let joined_paths = paths.join("\n");
            let result_cstring = CString::new(joined_paths).unwrap().into_raw();

            if measure_time {
                let elapsed = start_time.elapsed();
                let elapsed_secs = elapsed.as_secs() as f64 + elapsed.subsec_nanos() as f64 / 1_000_000_000.0;
                println!("Search took {:.6} seconds", elapsed_secs);
            }

            result_cstring
        }

        fn search_with_regex(pattern: &str, start_dir: &str) -> Result<Vec<String>, regex::Error> {
            let regex = Regex::new(pattern)?;
            search_directory(PathBuf::from(start_dir), |entry| {
                regex.is_match(entry.file_name().to_str().unwrap_or(""))
            }).map_err(|_| regex::Error::Syntax(String::from("IO error during directory search")))
        }

        fn search_with_glob(pattern: &str, start_dir: &str) -> Result<Vec<String>, glob::PatternError> {
            glob(&format!("{}/{}", start_dir, pattern))?
                .filter_map(Result::ok)
                .map(|path| Ok(path.to_string_lossy().into_owned()))
                .collect()
        }

        fn search_directory<F>(dir: PathBuf, predicate: F) -> Result<Vec<String>, std::io::Error>
        where
            F: Fn(&std::fs::DirEntry) -> bool + Copy,
        {
            let mut results = Vec::new();
            for entry in std::fs::read_dir(dir)? {
                let entry = entry?;
                if entry.path().is_dir() {
                    results.extend(search_directory(entry.path(), predicate)?);
                } else if predicate(&entry) {
                    results.push(entry.path().to_string_lossy().into_owned());
                }
            }
            Ok(results)
        }

        #[no_mangle]
        pub extern "C" fn free(ptr: *mut c_char) {
            unsafe {
                if ptr.is_null() { return }
                CString::from_raw(ptr)
            };
        }
'@
        # Save Rust source file
        $rustSourcePath = Join-Path $PWD 'src/lib.rs'
        New-Item -Path (Join-Path $PWD 'src') -ItemType Directory -Force
        Set-Content -Path $rustSourcePath -Value $rustSource -Force

        # Step 3: Compile Rust Code
        cargo build --release --manifest-path $cargoTomlPath

        # Step 4: Define C Bindings (if needed, adjust accordingly based on Rust code)
        $libPath = Join-Path $PWD 'target/release/libfile_search.dll'
        $normalizedLibPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($libPath).Replace('\', '\\')
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;

        public class RustLib {
            [DllImport("$normalizedLibPath", CallingConvention = CallingConvention.Cdecl)]
            public static extern IntPtr search_files(string pattern, bool use_regex, string start_dir, bool measure_time);

            [DllImport("$normalizedLibPath", CallingConvention = CallingConvention.Cdecl)]
            public static extern void free(IntPtr ptr);
        }
"@
    }

    process {
        # Step 5: Use Rust Library in PowerShell
        try {
            $ptr = [RustLib]::search_files($Pattern, $UseRegex, $StartDir, $true)
            if ($ptr -eq [IntPtr]::Zero) {
                Write-Warning 'No results found or an error occurred.'
                return @()
            }
            $result = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($ptr)
            [RustLib]::free($ptr)
            return $result -split "`n"
        }
        catch {
            Write-Error "Error occurred: $($_.Exception.Message)"
        }
    }
    end {
    }
}


# Find-RustyFile -Pattern '*.txt' -UseRegex $false -StartDir 'C:\\' -Verbose -ErrorAction Break | ForEach-Object { Write-Host $_ }
