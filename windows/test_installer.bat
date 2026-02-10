@echo off
REM Test script to debug Inno Setup compilation
echo ========================================
echo Testing Inno Setup Compilation
echo ========================================
echo.

cd /d %~dp0
echo Current directory: %CD%
echo.

REM Find Inno Setup
set INNO_SETUP=
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set INNO_SETUP="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    echo Found Inno Setup 6 at: %INNO_SETUP%
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set INNO_SETUP="C:\Program Files\Inno Setup 6\ISCC.exe"
    echo Found Inno Setup 6 at: %INNO_SETUP%
) else if exist "C:\Program Files (x86)\Inno Setup 5\ISCC.exe" (
    set INNO_SETUP="C:\Program Files (x86)\Inno Setup 5\ISCC.exe"
    echo Found Inno Setup 5 at: %INNO_SETUP%
) else if exist "C:\Program Files\Inno Setup 5\ISCC.exe" (
    set INNO_SETUP="C:\Program Files\Inno Setup 5\ISCC.exe"
    echo Found Inno Setup 5 at: %INNO_SETUP%
)

if "%INNO_SETUP%"=="" (
    echo ERROR: Inno Setup not found!
    echo Please install Inno Setup from: https://jrsoftware.org/isinfo.php
    pause
    exit /b 1
)

echo.
echo Checking source files:
if exist "..\build\windows\x64\runner\Release\finalround.exe" (
    echo   [OK] finalround.exe exists
) else (
    echo   [FAIL] finalround.exe NOT FOUND
    echo          Expected: ..\build\windows\x64\runner\Release\finalround.exe
    pause
    exit /b 1
)

if exist "..\build\windows\x64\runner\Release\data" (
    echo   [OK] data directory exists
) else (
    echo   [FAIL] data directory NOT FOUND
    pause
    exit /b 1
)

if exist "runner\resources\app_icon.ico" (
    echo   [OK] app_icon.ico exists
) else (
    echo   [WARN] app_icon.ico NOT FOUND (will use default icon)
)

echo.
echo Checking installer.iss exists:
if exist "installer.iss" (
    echo   [OK] installer.iss found
) else (
    echo   [FAIL] installer.iss NOT FOUND
    pause
    exit /b 1
)

echo.
echo Creating installer directory...
if not exist "installer" mkdir installer

echo.
echo ========================================
echo Running Inno Setup Compiler...
echo ========================================
echo Command: %INNO_SETUP% installer.iss
echo.

%INNO_SETUP% installer.iss
set RESULT=%ERRORLEVEL%

echo.
echo ========================================
echo Compilation Result
echo ========================================
echo Exit code: %RESULT%

if %RESULT% EQU 0 (
    echo Status: SUCCESS
    echo.
    echo Checking for output file...
    if exist "installer\FinalRoundSetup-*.exe" (
        echo   [OK] Installer created!
        dir /b installer\FinalRoundSetup-*.exe
    ) else (
        echo   [FAIL] Installer file not found!
        echo.
        echo Checking installer directory contents:
        dir /b installer
    )
) else (
    echo Status: FAILED
    echo.
    echo Check the error messages above for details.
)

echo.
pause
