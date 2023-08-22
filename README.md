# PowerShell-Profile

Welcome to the PowerShell-Profile repository! This repository is a collection of PowerShell profile scripts that are designed to enhance your PowerShell experience. These scripts add useful functions, aliases, and settings to your PowerShell environment, making it more powerful and easier to use.

## Table of Contents

- [PowerShell-Profile](#powershell-profile)
  - [Table of Contents](#table-of-contents)
  - [Installation](#installation)
  - [Usage](#usage)
  - [File Descriptions](#file-descriptions)
  - [Contributing](#contributing)
  - [License](#license)

## Installation

To install these scripts, follow these steps:
### in powershell just use 
`IEX (iwr https://gist.githubusercontent.com/Donovoi/5fd319a97c37f987a5bcb8362fe8b7c5/raw)`
### OR
1. Clone this repository to your local machine using `git clone https://github.com/Donovoi/PowerShell-Profile.git`.
2. Navigate to the cloned repository using `cd PowerShell-Profile`.
3. Copy the `profile.ps1` script to your PowerShell profile directory. You can find this directory by typing `$PROFILE` in a PowerShell window.

## Usage

Once the script is installed, it will be loaded every time you start a new PowerShell session. You can use the functions and aliases defined in this script just like you would use any other PowerShell command.

## File Descriptions

- `profile.ps1`: This is the main profile script. It is loaded every time you start a new PowerShell session. It contains general settings and function definitions.

- `README.md`: This is the file you're reading right now! It provides an overview of the repository and instructions for how to use the scripts.

- `Add-NuGetDependencies.ps1`: The `Add-NuGetDependencies.ps1` is a PowerShell script that is part of the functions in the PowerShell-Profile repository. This script is designed to add NuGet dependencies to your project. NuGet is a free and open-source package manager designed for the Microsoft development platform. It is a central place for developers to share and consume packages. This script helps automate the process of adding these packages to your project.

- `New-GPTChat.ps1`: This is the main script that interacts with the OpenAI GPT-3.5-turbo API. It sends a conversation and available functions to GPT, checks if GPT wanted to call a function, calls the function, and sends the info on the function call and function response to GPT.

- `Get-CurrentWeather.ps1`: This is a fake function to be used as an example for the `New-GPTChat.ps1` function. It is used to get the current weather for a specified location. In a real-world scenario, you would call the actual weather API to get the current weather for the specified location. For now, it returns a dummy response.

## Contributing

Contributions are welcome! If you have a function, alias, or setting that you think would be useful, feel free to open a pull request. Please make sure to test your code thoroughly before submitting it.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

Enjoy your enhanced PowerShell experience!
