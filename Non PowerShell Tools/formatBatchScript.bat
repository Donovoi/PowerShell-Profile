@echo off
setlocal enabledelayedexpansion

rem Check if argument is provided
if "%~1"=="" (
    echo No input file provided.
    set /p "inputFile=Please enter the file path: "
) else (
    set "inputFile=%~1"
)

rem Check if inputFile exists
if not exist "%inputFile%" (
    echo Input file does not exist.
    exit /b 1
)

rem Get the name and path of the file without extension
for %%A in ("%inputFile%") do (
    set "filePath=%%~dpA"
    set "fileName=%%~nA"
    set "fileExt=%%~xA"
)

rem Create a new file name with "-formatted" appended
set "outputFile=%filePath%%fileName%-formatted%fileExt%"

rem Check if outputFile already exists, if so delete it
if exist "%outputFile%" (
    del "%outputFile%" || (
        echo Failed to delete existing output file.
        exit /b 1
    )
)

set "tab=    "
set "indent="

for /f "usebackq delims=" %%a in ("%inputFile%") do (
    set "line=%%a"

    rem Trim leading whitespace (spaces and tabs)
    for /f "tokens=* delims=    " %%b in ("!line!") do set "line=%%b"
    
    rem Check if line starts with 'for', 'if', or 'else'
    if "!line:~0,3!"=="for" (
        echo !indent!!line! >> "%outputFile%"
        set "indent=!indent!!tab!"
    ) else if "!line:~0,2!"=="if" (
        echo !indent!!line! >> "%outputFile%"
        set "indent=!indent!!tab!"
    ) else if "!line:~0,4!"=="else" (
        echo !indent!!line! >> "%outputFile%"
        set "indent=!indent!!tab!"
    ) else (
        rem Check if line starts with ')'
        if "!line:~0,1!"==")" (
            rem Check if indent has at least 4 characters
            if "!indent:~3,1!" NEQ "" (
                set "indent=!indent:~0,-4!"
            ) else (
                set "indent="
            )
            echo !indent!!line! >> "%outputFile%"
        ) else (
            rem If line doesn't start with 'for', 'if', 'else', or ')', just print it as is
            echo !indent!!line! >> "%outputFile%"
        )
    )
)
