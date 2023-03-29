<#
.SYNOPSIS
    The Script creates test users to your demo domain based on first and last namnes from csv. 
.PARAMETER NumUsers
    Integer - number of users to create, default 100.
.NOTES
    File Name: CreateTestADUsers.ps1
    Author   : Johan Dahlbom, johan[at]dahlbom.eu
    Blog     : 365lab.net
    The script are provided "AS IS" with no guarantees, no warranties, and they confer no rights.    
#>
function Create-TestUsers {
  param([Parameter(Mandatory = $false)]
    [int]
    $NumUsers = '1000'
  )
  #Define variables
  $OU = 'OU=Users,DC=testdomain,DC=com'
  $Departments = @('IT','Finance','Logistics','Sourcing','Human Resources')
  $Names = Import-Csv FirstLastEurope.csv
  $firstnames = $Names.Firstname
  $lastnames = $Names.Lastname
  $Password = 'Password01!'

  #Import required module ActiveDirectory
  try {
    Import-Module ActiveDirectory -ErrorAction Stop
  }
  catch {
    throw 'Module GroupPolicy not Installed'
  }

  while ($NumUsers -gt 0) {
    #Choose a 'random' department Firstname and Lastname

    $i = Get-Random -Minimum 0 -Maximum $firstnames.Count
    $firstname = $FirstNames[$i]
    $i = Get-Random -Minimum 0 -Maximum $lastnames.Count
    $lastname = $LastNames[$i]

    if (($firstname -eq 'Johan') -or ($firstname -eq 'Andreas')) {
      $Department = 'Cool Department'
    }
    else {
      $i = Get-Random -Minimum 0 -Maximum $Departments.Count
      $Department = $Departments[$i]
    }
    #Generate username and check for duplicates

    $username = $firstname.Substring(0,3).ToLower() + $lastname.Substring(0,3).ToLower()
    $exit = 0
    $count = 1
    do {
      try {
        $userexists = Get-ADUser -Identity $username
        $username = $firstname.Substring(0,3).ToLower() + $lastname.Substring(0,3).ToLower() + $count++
      }
      catch {
        $exit = 1
      }
    }
    while ($exit -eq 0)

    #Set Displayname and UserPrincipalNBame
    $displayname = $firstname + ' ' + $lastname
    $upn = $username + '@' + (Get-ADDomain).DNSRoot

    #Create the user
    Write-Host "Creating user $username in $ou"
    New-ADUser -Name $displayname -DisplayName $displayname `
       -SamAccountName $username -UserPrincipalName $upn `
       -GivenName $firstname -Surname $lastname -Description 'Test User' `
       -Path $ou -Enabled $true -ChangePasswordAtLogon $false -Department $Department `
       -AccountPassword (ConvertTo-SecureString $Password -AsPlainText -Force)

    $NumUsers --
  }
}
