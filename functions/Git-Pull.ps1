function Git-Pull {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Path = 'F:\'
    )

    $ErrorActionPreference = 'Continue'

    # Get all the repositories in the path specified. We are looking for directories that contain a .git directory
    Write-Host "Searching for repositories in $Path, this can take a while..."
    # $repositories = @{}
    # $repositories = Get-ChildItem -Path $Path -Recurse -Directory -Filter '.git' -Force | Split-Path -Parent

    # We will benchmark the get-childitem command to see if we can speed it up and put it against the FindFirstFileW API
  
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
        Remove-Item -Path "$PWD/target" -Recurse -Force
        Remove-Item -Path "$PWD/lib.rs" -Force
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
        Write-Error "$typeName already exists. Please exit PowerShell and try again."
        Read-Host -Prompt 'Press Enter to exit'
        Exit-PSHostProcess
    }
  
    $dir_path = 'F:\\'
    $search_name = '.git'
  
    if ((Test-Path -Path $dir_path) -and (-not([string]::IsNullOrWhiteSpace($search_name)))) {
        $foundPaths = $target::GetFoundPaths($dir_path, $search_name)
        $foundPaths
    }

  
  


    function Enumerate-FilesAndFolders($Path) {
  
    }
    # Start the stopwatch
    $StopwatchENumMethod = [System.Diagnostics.Stopwatch]::StartNew()
    # Get the repositories
    $repositories = Enumerate-FilesAndFolders -Path 'F:\'
    # Stop the stopwatch
    $StopwatchENumMethod.Stop()
    # Show the elapsed time
    Write-Host "Elapsed time: $($StopwatchENumMethod.Elapsed.TotalSeconds) seconds for the ENumerate-FilesAndFolders function to run"

    # Now do the same for the Get-ChildItem command
    # Start the stopwatch
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Get the repositories
    $repositories = Get-ChildItem -Path 'F:\' -Recurse -Filter '.git' -Force | Split-Path -Parent
    # Stop the stopwatch
    $Stopwatch.Stop()
    # Show the elapsed time
    Write-Host "Elapsed time: $($Stopwatch.Elapsed.TotalSeconds) seconds for the Get-ChildItem command to run"
    # calculate the difference and tell the user which method is faster
    $difference = $Stopwatch.Elapsed.TotalSeconds - $StopwatchENumMethod.Elapsed.TotalSeconds
    if ($difference -gt 0) {
        Write-Host "The ENumerate-FilesAndFolders function is faster by $difference seconds"
    }
    else {
        Write-Host "The Get-ChildItem command is faster by $difference seconds"
    }


    #Let the user know what we are doing and how many repositories we are working with
    Write-Output "Found $($repositories.Count) repositories to pull from."

    # iterate through the hashtable and perform a git pull on each repository. THe repository is the parent of the .git directory
    #  We need to get the full path of the .git directory, then navigate to the parent directory and perform the git pull.
    $repositories.GetEnumerator() | ForEach-Object -ThrottleLimit 20 -Parallel {
        Write-Output "Pulling from $($_)"
        Set-Location -Path $_
        # Set ownership to current user and grant full control to current user recursively
        icacls.exe $_ /setowner "$env:UserName" /t /c /q
        git config --global --add safe.directory $(Resolve-Path -Path $PWD)
        git pull --verbose
        Write-Output "git pull complete for $($_)"
        #  Show progress
        Write-Progress -Activity "Pulling from $($_)" -Status "Pulling from $($_)" -PercentComplete (($repositories.IndexOf($_) + 1) / $repositories.Count * 100)
    }


    # clean up
    Remove-Variable -Name repositories -Force
    [GC]::Collect()
}

Git-Pull -Path 'F:\' -Verbose