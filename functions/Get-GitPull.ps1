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
        [string]$Path = $(Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
    )
    try {
        $ErrorActionPreference = 'Continue'

        # Ensure Path is scoped correctly
        $script:Path = Resolve-Path -Path $Path -ErrorAction Stop

        # Import the required cmdlets
        $neededcmdlets = @('Write-Logg')
        $neededcmdlets | ForEach-Object {
            if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                # Write-Logg -Message "Importing cmdlet: $_" -Level VERBOSE
                # if write-logg is not available use write-OutPut, but check first
                if (-not (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue)) {
                    Write-Output "Importing cmdlet: $_"
                }
                else {
                    Write-Logg -Message "Importing cmdlet: $_" -Level VERBOSE
                }
                $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $_
                $Cmdletstoinvoke | Import-Module -Force
            }
        }

        # install rust if it is not installed. Do it without any need for user input
        Write-Logg -Message 'Checking if Rust is installed...' -Level VERBOSE
        if (-not (Test-Path -Path "$env:USERPROFILE\.cargo\bin\rustup.exe")) {
            Write-Logg -Message 'Rust is not installed. Installing Rust...' -Level VERBOSE
            $rustInstaller = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
            $rustInstallerPath = "$env:TEMP\rustup-init.exe"
            Invoke-WebRequest -Uri $rustInstaller -OutFile $rustInstallerPath
            Start-Process -FilePath $rustInstallerPath -ArgumentList '-y' -Wait
            Remove-Item -Path $rustInstallerPath -Force
        }

        # make sure we have cargo available, if not just call the cargo exe full path
        if (-not (Get-Command -Name 'cargo' -ErrorAction SilentlyContinue)) {
            $env:Path += ";$env:USERPROFILE\.cargo\bin"
        }

        # Get all the repositories in the path specified
        Write-Logg -Message "Searching for repositories in $script:Path, this can take a while..." -Level VERBOSE

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
    edition = '2021'
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
            Write-Logg -Message "$typeName already exists. Please exit PowerShell and try again." -Level ERROR
            Read-Host -Prompt 'Press Enter to exit'
            Exit-PSHostProcess
        }


        # Get the repositories

        $dir_path = $(Resolve-Path -Path $script:Path -ErrorAction Stop).Path
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
        Write-Logg -Message "Elapsed time: $($StopwatchENumMethod.Elapsed.TotalSeconds) seconds for the Rust GetFoundPaths function to run" -Level VERBOSE


        #Let the user know what we are doing and how many repositories we are working with
        Write-Logg -Message "Found $($repositories.Count) repositories to pull from." -Level VERBOSE

        if ($repositories.Count -gt 1) {
            $multiplerepos = $repositories.GetEnumerator()
        }
        else {
            $singleRepo = $repositories
        }
        #  We need to get the full path of the .git directory, then navigate to the parent directory and perform the git pull.
        $multiplerepos ? $multiplerepos : $singleRepo | ForEach-Object -Process {
            Write-Logg -Message "Pulling from $($_)" -Level VERBOSE
            $location = $(Resolve-Path -Path $_).Path
            Set-Location -Path $location
            # Set ownership to current user and grant full control to current user recursively
            icacls.exe $_ /setowner "$env:UserName" /t /c /q

            # Check if the upstream remote is added
            $upstream = git remote -v | Select-String 'upstream'
            if ($null -ne $upstream) {

                # Define the root path of the repository
                $repoRootPath = Get-Location
                try {
                    # Search for the lock file recursively
                    $lockFile = Get-ChildItem -Path $repoRootPath -Recurse -Filter 'HEAD.lock' -Force
                }
                catch {
                    Write-Warning "Unable to get lock file for $($_)" -Level VERBOSE
                    Write-Warning "Error is: $_.Exception.Message" -Level VERBOSE
                }


                # Check if the lock file was found
                if ($null -ne $lockFile) {
                    # Try to remove the lock file
                    try {
                        Remove-Item $lockFile.FullName -Force
                        Write-Logg -Message "Lock file $($lockFile.FullName) removed successfully." -Level Info
                    }
                    catch {
                        Write-Logg -Message "Failed to remove lock file. Error: $_" -Level error
                    }
                }
                else {
                    Write-Logg -Message 'Lock file not found.' -Level Info
                }
                try {


                    # If upstream is added, reset local changes and pull the latest changes from upstream
                    git reset --hard
                    git clean -fd
                    git fetch upstream

                    # Get the name of the default branch from the upstream remote
                    $defaultBranch = git remote show upstream | Select-String 'HEAD branch' | Out-String
                    $defaultBranch = ($defaultBranch -split ':')[1].Trim()

                    # Checkout to the default branch
                    git checkout $defaultBranch

                    # Merge with the upstream branch, favoring their changes in case of conflicts
                    git merge upstream/$defaultBranch -X theirs

                    # Get the name of the current branch
                    $currentBranch = git rev-parse --abbrev-ref HEAD

                    # Push the changes to the remote repository
                    git push origin $currentBranch

                }
                catch {

                    try {
                        # If the merge failed, check out the conflicted files from the upstream branch
                        git reset --hard upstream/$defaultBranch
                        git clean -fd
                        git fetch upstream
                    }
                    catch {
                        #    ignore error
                    }

                }
            }
            else {
                try {
                    git pull
                }
                catch {
                    Write-Warning "Unable to pull from $($_)" -Level VERBOSE
                }
            }
            Write-Logg -Message "git pull complete for $($_)" -Level INFO
            [GC]::Collect()
        }
        # clean up if we need to
        Remove-Variable -Name repositories -Force
        [GC]::Collect()
    }
    catch {
        Write-Logg -Message "An error occurred: $($_.Exception.Message)" -Level Error
    }
    finally {
        # Clean up the Rust DLL and Cargo files
        if (Test-Path -Path "$PWD/target/release/findfiles.dll") {
            Remove-Item -Path "$PWD/target" -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -Path "$PWD/Cargo.toml") {
            Remove-Item -Path "$PWD/Cargo.toml" -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -Path "$PWD/lib.rs") {
            Remove-Item -Path "$PWD/lib.rs" -Force -ErrorAction SilentlyContinue
        }

    }

}