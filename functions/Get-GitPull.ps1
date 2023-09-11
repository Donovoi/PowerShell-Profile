<#
.SYNOPSIS
    Pulls the latest changes from all Git repositories in a specified directory.
.DESCRIPTION
    The Get-GitPull function searches for all Git repositories in a specified directory and pulls the latest changes from each repository. The function uses Rust code to efficiently search for the repositories and returns a list of repository paths. The function then uses PowerShell to navigate to each repository and perform a Git pull operation. The function supports parallel execution to improve performance.
.PARAMETER Path
    The path to the directory to search for Git repositories. The default value is 'f:\'.
.EXAMPLE
    PS C:\> Get-GitPull -Path 'C:\Projects'
    This example searches for Git repositories in the 'C:\Projects' directory and pulls the latest changes from each repository.
.NOTES
    This function requires Rust and Cargo to be installed on the system. The function will automatically build the Rust code if it has not been built already.
#>


function Get-GitPull {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
    )

    $ErrorActionPreference = 'Continue'
    # run my profile to import the functions
    $myDocuments = [Environment]::GetFolderPath('MyDocuments')
    $myProfile = Join-Path -Path $myDocuments -ChildPath 'PowerShell\Microsoft.PowerShell_profile.ps1'
    if (Test-Path -Path $myProfile) {
        . $myProfile
    }
    else {
       Write-Log -NoConsoleOutput -Message "No PowerShell profile found at $myProfile"
    }
    # $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
    # Get all the repositories in the path specified. We are looking for directories that contain a .git directory
    Write-Log -NoConsoleOutput -Message "Searching for repositories in $Path, this can take a while..."

    $rustPgm = @'
  extern crate jwalk;
  use jwalk::WalkDir;
  use std::alloc::{alloc_zeroed, Layout};
  use std::ffi::{CStr, CString};
  use std::mem;
  use std::os::raw::c_char;
  
  #[no_mangle]
  pub unsafe extern "C" fn find_directory_count_given_name(
      dir_path: *const c_char,
      search_name: *const c_char,
  ) -> *const *const c_char {
      let dir_path = {
          assert!(!dir_path.is_null());
          CStr::from_ptr(dir_path)
      };
      let dir_path = dir_path.to_str().unwrap();
  
      let search_name = {
          assert!(!search_name.is_null());
          CStr::from_ptr(search_name)
      };
      let search_name = search_name.to_str().unwrap();
  
      let mut matching_paths: Vec<*const c_char> = vec![];
  
      for entry in WalkDir::new(dir_path).skip_hidden(false).into_iter() {
          let entry = entry.unwrap();
          if entry.file_name().to_string_lossy() == search_name && entry.file_type().is_dir() {
              let path = entry.path().to_string_lossy().into_owned();
              let path_cstr = CString::new(path).unwrap();
              matching_paths.push(path_cstr.into_raw());
          }
      }
  
      let paths_len = matching_paths.len();
      let data_layout = Layout::array::<*const c_char>(paths_len + 1).unwrap();
      let result = alloc_zeroed(data_layout) as *mut *const c_char;
      for (idx, &item) in matching_paths.iter().enumerate() {
          result.add(idx).write(item);
      }
      mem::forget(matching_paths);
      result.add(paths_len).write(std::ptr::null());
  
      result
  }  
'@

    if (-not(Test-Path -Path "$PWD/target/release/findfiles.dll")) {
        Remove-Item -Path "$PWD/target" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$PWD/lib.rs" -Force -ErrorAction SilentlyContinue
        # If the cargo file does not exist, create it
        if (-not(Test-Path -Path "$PWD/Cargo.toml")) {

            $cargoFile = @'
    [lib]
    name = "findfiles"
    path = "./lib.rs"
    crate-type = ["cdylib"]

    [package]
    name = "findfiles"
    version = "0.1.0"

    [dependencies]
    jwalk = "0.8.1"
'@
            $cargoFile | Set-Content -Encoding UTF8 "$PWD/Cargo.toml" -Force
        }
        $rustPgm | Set-Content -Encoding UTF8 "$PWD/lib.rs" -Force
        cargo build --release
    }

    $definition = @'
  using System;
  using System.Collections.Generic;
  using System.Runtime.InteropServices;
  using System.Text;
  
  public class FileFinder
  {
      [DllImport(
          "target\\release\\findfiles.dll",
          CallingConvention = CallingConvention.Cdecl,
          CharSet = CharSet.Ansi
      )]
      private static extern IntPtr find_directory_count_given_name(
          string dir_path,
          string search_name
      );
  
      private static List<string> ConvertStringArray(IntPtr ptr)
      {
          List<string> result = new List<string>();
          while (true)
          {
              IntPtr currentPtr = Marshal.ReadIntPtr(ptr);
              if (currentPtr == IntPtr.Zero)
                  break;
              result.Add(Marshal.PtrToStringAnsi(currentPtr));
              ptr += IntPtr.Size;
          }
          return result;
      }
  
      private static void FreeStringArray(IntPtr ptr)
      {
          while (true)
          {
              IntPtr currentPtr = Marshal.ReadIntPtr(ptr);
              if (currentPtr == IntPtr.Zero)
                  break;
              Marshal.FreeCoTaskMem(currentPtr);
              ptr += IntPtr.Size;
          }
      }
  
      public static List<string> GetFoundPaths(string dir_path, string search_name)
      {
          IntPtr resultPtr = find_directory_count_given_name(dir_path, search_name);
          List<string> result = ConvertStringArray(resultPtr);
          FreeStringArray(resultPtr);
          return result;
      }
  }
  
'@

    $typeName = 'FileFinder'

    if (-not ([System.Management.Automation.PSTypeName]$typeName).Type) {
        $target = Add-Type -TypeDefinition $definition -PassThru
    }
    else {
        Write-Log -NoConsoleOutput -Message "$typeName already exists. Please exit PowerShell and try again." -Level ERROR
        Read-Host -Prompt 'Press Enter to exit'
        Exit-PSHostProcess
    }


    # Get the repositories
    
    $dir_path = Resolve-Path -Path $Path -ErrorAction Stop
    $search_name = '.git'
  
    if ((Test-Path -Path $dir_path) -and (-not([string]::IsNullOrWhiteSpace($search_name)))) {
        # Start the stopwatch
        $StopwatchENumMethod = [System.Diagnostics.Stopwatch]::StartNew()
        $foundPaths = $target::GetFoundPaths($dir_path, $search_name)
        # Stop the stopwatch
        $StopwatchENumMethod.Stop()
        # Make sure we only get the parent paths
        $repositories = $foundPaths | Split-Path -Parent
    }

    # Show the elapsed time
    Write-Log -NoConsoleOutput -Message "Elapsed time: $($StopwatchENumMethod.Elapsed.TotalSeconds) seconds for the Rust GetFoundPaths function to run"


    #Let the user know what we are doing and how many repositories we are working with
    Write-Log -NoConsoleOutput -Message "Found $($repositories.Count) repositories to pull from."

    if ($repositories.Count -gt 1) {
        $multiplerepos = $repositories.GetEnumerator()
    }
    else {
        $singleRepo = $repositories
    }
    #  We need to get the full path of the .git directory, then navigate to the parent directory and perform the git pull.
    $multiplerepos ? $multiplerepos : $singleRepo | ForEach-Object -Process {
        Write-Log -NoConsoleOutput -Message "Pulling from $($_)"
        $location = $(Resolve-Path -Path $_).Path
        Set-Location -Path $location
        # Set ownership to current user and grant full control to current user recursively
        icacls.exe $_ /setowner "$env:UserName" /t /c /q


        try {
            git pull
        }
        catch {
            Write-Warning "Unable to pull from $($_)"
        }
        
        Write-Log -NoConsoleOutput -Message "git pull complete for $($_)" -Level INFO
        #  Show progress
        #Write-Progress -Activity "Pulling from $($_)" -Status "Pulling from $($_)" -PercentComplete (($repositories.IndexOf($_) + 1) / $repositories.Count * 100)
    }
    # clean up if we need to
    Remove-Variable -Name repositories -Force
    [GC]::Collect()
}

