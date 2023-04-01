Set-StrictMode -Version Latest

[UIAutomation.Preferences]::Timeout = 10000;
[UIAutomation.Preferences]::EveryCmdletAsTestResult = $true;
[UIAutomation.Preferences]::OnSuccessDelay = 0;

sleep -Seconds 10;

# names of the pages and buttons in the app menu
[string]$constPageMain = 'Home';
[string]$constPageFeaturedDestinations = 'Featured Destinations';
[string]$constPageDestinations = 'Destinations';
[string]$constPageFlights = 'Flights';
[string]$constPageHotels = 'Hotels';
[string]$constPageBestOfWeb = 'Best Of Web';

# names of wizard steps
[string]$constWizardName = 'TravelWizard';
[string]$constWizardStepHome = 'Home';
[string]$constWizardStepDestinations = 'Destinations';
[string]$constWizardStepFlights = 'Flights';
[string]$constWizardStepHotels = 'Hotels';
[string]$constWizardStepBestOfWeb = 'BestOfWeb';

# we need to clear the collection of wizards or delete
# the wizard we are playing with.
# Otherwise, the next run will throw an exception
# 'Wizard already exists'
[UIAutomation.WizardCollection]::Wizards.Clear();

# Creating a new wizard
New-UIAWizard -Name $constWizardName `
   -StartAction {
  # setting the Metro Start screen
  Get-UIADesktop;
  Show-UIAMetroStartScreen;

  # clicking on the tile of the AUT
  Get-UIAListItem -Name 'Travel' | `
     Invoke-UIAListItemClick;

  # the loading screen (if happened)
  try {
    Get-UIAWindow -Name 'Travel' | `
       Get-UIAProgressBar;
    #sleep -Seconds 5; # the app is loading
  }
  catch {}

  # start our tests from the Main page
  Show-UIAMetroMenu;
  Get-UIAWindow -Name 'Travel' | `
     Get-UIAMenuBar -Name 'App Bar' | `
     Get-UIAHyperlink -Name $constPageMain | `
     Invoke-UIAControlClick;
} | `
   Add-UIAWizardStep -Name $constWizardStepHome `
   -SearchCriteria @{ controlType = "Text"; Name = 'Bing Travel' } `
   -StepForwardAction {
  #[System.Windows.Forms.MessageBox]::Show("StepHome");
  "<<<<<<<<<< On the Home page >>>>>>>>>>";
  try {
    Get-UIAText -Name 'Bing Travel';
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Home page >>>>>>>>>>" -TestPassed;
  }
  catch {
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Home page >>>>>>>>>>";
  }
} -Passthru | `
   Add-UIAWizardStep -Name $constWizardStepDestinations `
   -SearchCriteria @{ controlType = "Text"; Name = 'Destinations' },
@{ controlType = "Button"; Name = 'Go Back' },
@{ controlType = "Text"; Name = 'Region' } `
   -StepForwardAction {
  #[System.Windows.Forms.MessageBox]::Show("StepDestinations");
  "<<<<<<<<<< On the Destinations page >>>>>>>>>>";
  try {
    Get-UIAText -Name 'Destinations';
    Get-UIAText -Name 'Region';
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Destinations page >>>>>>>>>>" -TestPassed;
  }
  catch {
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Destinations page >>>>>>>>>>";
  }
} -Passthru | `
   Add-UIAWizardStep -Name $constWizardStepFlights `
   -SearchCriteria @{ controlType = "Text"; Name = 'Flights' },
@{ controlType = "Button"; Name = 'Go Back' },
@{ controlType = "Text"; Name = 'Schedule' } `
   -StepForwardAction {
  #[System.Windows.Forms.MessageBox]::Show("StepFlights");
  "<<<<<<<<<< On the Flights page >>>>>>>>>>";
  try {
    Get-UIAText -Name 'Flights';
    Get-UIAText -Name 'Schedule';
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Flights page >>>>>>>>>>" -TestPassed;
  }
  catch {
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Flights page >>>>>>>>>>";
  }
} -Passthru | `
   Add-UIAWizardStep -Name $constWizardStepHotels `
   -SearchCriteria @{ controlType = "Text"; Name = 'Hotels' },
@{ controlType = "Button"; Name = 'Go Back' },
@{ controlType = "Text"; Name = 'Check-in' } `
   -StepForwardAction {
  #[System.Windows.Forms.MessageBox]::Show("StepHotels");
  "<<<<<<<<<< On the Hotels page >>>>>>>>>>";
  try {
    Get-UIAText -Name 'Hotels';
    Get-UIAText -Name 'Check-in';
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Hotels page >>>>>>>>>>" -TestPassed;
  }
  catch {
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the Hotels page >>>>>>>>>>";
  }
} -Passthru | `
   Add-UIAWizardStep -Name $constWizardStepBestOfWeb `
   -SearchCriteria @{ controlType = "Text"; Name = 'Travel' },
@{ controlType = "Button"; Name = 'Go Back' },
@{ controlType = "Text"; Name = 'Explore' },
@{ controlType = "Text"; Name = 'Plan a Trip' } `
   -StepForwardAction {
  #[System.Windows.Forms.MessageBox]::Show("Best Of Web");
  "<<<<<<<<<< On the 'Best Of Web' page >>>>>>>>>>";
  try {
    Get-UIAText -Name 'Travel';
    Get-UIAText -Name 'Explore';
    Get-UIAText -Name 'Plan a Trip';
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the 'Best Of Web' page >>>>>>>>>>" -TestPassed;
  }
  catch {
    Close-TMXTestResult -Name "<<<<<<<<<< Navigating to the 'Best Of Web' page >>>>>>>>>>";
  }
};

# Start the wizard
[UIAutomation.Wizard]$wizard = Invoke-UIAWizard -Name $constWizardName;

# Click on the Destinations button in the app menu
Show-UIAMetroMenu;
Get-UIAWindow -Name 'Travel' | `
   Get-UIAMenuBar -Name 'App Bar' | `
   Get-UIAHyperlink -Name $constPageDestinations | `
   Invoke-UIAControlClick;

# Check that this is the Destinations page and run code (in the future sample)
$wizard | Step-UIAWizard -Name $constWizardStepDestinations

# Click on the Flights button in the app menu
Show-UIAMetroMenu;
Get-UIAWindow -Name 'Travel' | `
   Get-UIAMenuBar -Name 'App Bar' | `
   Get-UIAHyperlink -Name $constPageFlights | `
   Invoke-UIAControlClick;

# Check that this is the Flights page and run code (in the future sample)
$wizard | Step-UIAWizard -Name $constWizardStepFlights;

# Click on the Hotels button in the app menu
Show-UIAMetroMenu;
Get-UIAWindow -Name 'Travel' | `
   Get-UIAMenuBar -Name 'App Bar' | `
   Get-UIAHyperlink -Name $constPageHotels | `
   Invoke-UIAControlClick;

# Check that this is the Hotels page and run code (in the future sample)
$wizard | Step-UIAWizard -Name $constWizardStepHotels;

# Click on the 'Best Of Web' button in the app menu
Show-UIAMetroMenu;
Get-UIAWindow -Name 'Travel' | `
   Get-UIAMenuBar -Name 'App Bar' | `
   Get-UIAHyperlink -Name $constPageBestOfWeb | `
   Invoke-UIAControlClick;

# Check that this is the 'Best Of Web' page and run code (in the future sample)
$wizard | Step-UIAWizard -Name $constWizardStepBestOfWeb;

