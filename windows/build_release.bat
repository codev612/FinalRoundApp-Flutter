@echo off
REM Automated build, sign, and installer creation script for FinalRound
REM Usage: build_release.bat [pfx_path] [pfx_password]

setlocal enabledelayedexpansion

set PFX_PATH=%1
set PFX_PASSWORD=%2

echo ========================================
echo FinalRound Release Build Script
echo ========================================
echo.

REM Step 1: Clean and build Flutter app
echo [1/6] Cleaning Flutter build...
call flutter clean
if %ERRORLEVEL% NEQ 0 (
    echo Error: Flutter clean failed
    exit /b 1
)

echo [2/6] Getting Flutter dependencies...
call flutter pub get
if %ERRORLEVEL% NEQ 0 (
    echo Error: Flutter pub get failed
    exit /b 1
)

echo [3/6] Building Windows release...
call flutter build windows --release
if %ERRORLEVEL% NEQ 0 (
    echo Error: Flutter build failed
    exit /b 1
)

REM Step 2: Verify executable exists before signing
set EXE_PATH=build\windows\x64\runner\Release\finalround.exe
if not exist "%EXE_PATH%" (
    echo Error: Executable not found: %EXE_PATH%
    echo        Make sure Flutter build completed successfully.
    exit /b 1
)

REM Step 3: Sign executable (if certificate provided)
if not "%PFX_PATH%"=="" (
    echo [4/6] Signing executable...
    if not exist "%PFX_PATH%" (
        echo Warning: Certificate not found: %PFX_PATH%
        echo Skipping code signing...
    ) else (
        call sign_app.bat "%EXE_PATH%" "%PFX_PATH%" "%PFX_PASSWORD%"
        if %ERRORLEVEL% NEQ 0 (
            echo Warning: Code signing failed, continuing without signature...
        )
    )
) else (
    echo [4/6] Skipping code signing (no certificate provided)
    echo        To sign: build_release.bat certificate.pfx YourPassword
)

REM Step 4: Verify all required files exist
echo [4/6] Verifying build files...
set BUILD_DIR=build\windows\x64\runner\Release
if not exist "%BUILD_DIR%\finalround.exe" (
    echo Error: Executable not found: %BUILD_DIR%\finalround.exe
    exit /b 1
)
if not exist "%BUILD_DIR%\data" (
    echo Error: Data directory not found: %BUILD_DIR%\data
    exit /b 1
)
if not exist "%BUILD_DIR%\flutter_windows.dll" (
    echo Warning: flutter_windows.dll not found - app may not work correctly
)
echo Build files verified.

REM Step 5: Create installer output directory
if not exist windows\installer mkdir windows\installer

REM Step 6: Build installer
echo [5/6] Building installer...
REM Try multiple possible Inno Setup locations
set INNO_SETUP=
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set INNO_SETUP="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set INNO_SETUP="C:\Program Files\Inno Setup 6\ISCC.exe"
) else if exist "C:\Program Files (x86)\Inno Setup 5\ISCC.exe" (
    set INNO_SETUP="C:\Program Files (x86)\Inno Setup 5\ISCC.exe"
) else if exist "C:\Program Files\Inno Setup 5\ISCC.exe" (
    set INNO_SETUP="C:\Program Files\Inno Setup 5\ISCC.exe"
)

if "%INNO_SETUP%"=="" (
    echo Error: Inno Setup not found. Please install from: https://jrsoftware.org/isinfo.php
    echo        Searched locations:
    echo          - C:\Program Files (x86)\Inno Setup 6\ISCC.exe
    echo          - C:\Program Files\Inno Setup 6\ISCC.exe
    echo          - C:\Program Files (x86)\Inno Setup 5\ISCC.exe
    echo          - C:\Program Files\Inno Setup 5\ISCC.exe
    exit /b 1
)
echo Found Inno Setup at: %INNO_SETUP%

cd windows
echo Running Inno Setup compiler...
echo Command: %INNO_SETUP% installer.iss
echo Working directory: %CD%
echo.
echo Checking source files exist:
if exist "..\build\windows\x64\runner\Release\finalround.exe" (echo   [OK] finalround.exe) else (echo   [FAIL] finalround.exe)
if exist "..\build\windows\x64\runner\Release\data" (echo   [OK] data directory) else (echo   [FAIL] data directory)
if exist "runner\resources\app_icon.ico" (echo   [OK] app_icon.ico) else (echo   [FAIL] app_icon.ico)
echo.
echo Compiling installer (this may take a moment)...
%INNO_SETUP% installer.iss
set INSTALLER_RESULT=%ERRORLEVEL%
echo.
echo Inno Setup exit code: %INSTALLER_RESULT%
if %INSTALLER_RESULT% EQU 0 (
    echo Compilation completed successfully.
) else (
    echo Compilation failed with exit code %INSTALLER_RESULT%
    echo Check the error messages above for details.
)
cd ..

if %INSTALLER_RESULT% NEQ 0 (
    echo.
    echo ========================================
    echo ERROR: Installer build failed!
    echo ========================================
    echo Exit code: %INSTALLER_RESULT%
    echo.
    echo Common issues:
    echo   1. Check that all source files exist in build\windows\x64\runner\Release
    echo   2. Verify Inno Setup is installed correctly
    echo   3. Check the installer.iss file for syntax errors
    echo.
    exit /b 1
)

REM Verify installer was created
echo.
echo Verifying installer was created...
if exist "windows\installer\FinalRoundSetup-*.exe" (
    echo SUCCESS: Installer created!
    dir /b windows\installer\FinalRoundSetup-*.exe
) else (
    echo WARNING: Installer file not found with expected pattern.
    echo Checking installer directory contents:
    if exist "windows\installer" (
        dir /b windows\installer
    ) else (
        echo Installer directory does not exist!
    )
    echo.
    echo This may indicate a compilation error. Check Inno Setup output above.
)

REM Step 7: Sign installer (if certificate provided)
if not "%PFX_PATH%"=="" (
    if exist "%PFX_PATH%" (
        echo [6/6] Signing installer...
        cd windows
        for %%f in (installer\FinalRoundSetup-*.exe) do (
            call sign_app.bat "%%f" "%PFX_PATH%" "%PFX_PASSWORD%"
        )
        cd ..
    )
) else (
    echo [7/7] Skipping installer signing (no certificate provided)
)

echo.
echo ========================================
echo Build Complete!
echo ========================================
echo.
echo Executable: %EXE_PATH%
echo Installer: installer\FinalRoundSetup-*.exe
echo.
