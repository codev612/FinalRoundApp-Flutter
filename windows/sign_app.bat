@echo off
REM Code signing script for FinalRound Windows executable
REM Usage: sign_app.bat [path_to_exe] [path_to_pfx] [pfx_password]

set EXE_PATH=%1
set PFX_PATH=%2
set PFX_PASSWORD=%3

if "%EXE_PATH%"=="" (
    echo Usage: sign_app.bat ^<exe_path^> ^<pfx_path^> ^<pfx_password^>
    echo Example: sign_app.bat build\windows\x64\runner\Release\finalround.exe certificate.pfx MyPassword123
    exit /b 1
)

if "%PFX_PATH%"=="" (
    echo Error: PFX certificate path is required
    exit /b 1
)

if "%PFX_PASSWORD%"=="" (
    echo Error: PFX password is required
    exit /b 1
)

if not exist "%EXE_PATH%" (
    echo Error: Executable not found: %EXE_PATH%
    exit /b 1
)

if not exist "%PFX_PATH%" (
    echo Error: Certificate not found: %PFX_PATH%
    exit /b 1
)

echo Signing %EXE_PATH%...
signtool sign /f "%PFX_PATH%" /p "%PFX_PASSWORD%" /t http://timestamp.digicert.com /fd SHA256 "%EXE_PATH%"

if %ERRORLEVEL% EQU 0 (
    echo Successfully signed: %EXE_PATH%
    signtool verify /pa /v "%EXE_PATH%"
) else (
    echo Error: Signing failed
    exit /b 1
)
