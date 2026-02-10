# Installing Inno Setup

## Quick Installation Steps

1. **Download Inno Setup**:
   - Go to: https://jrsoftware.org/isdl.php
   - Download the latest version (Inno Setup 6.x recommended)
   - Choose the "Inno Setup" installer (not QuickStart Pack)

2. **Run the installer**:
   - Double-click the downloaded `.exe` file
   - Follow the installation wizard
   - Accept the default installation path (usually `C:\Program Files (x86)\Inno Setup 6\`)

3. **Verify installation**:
   - After installation, run `windows\test_installer.bat` again
   - It should now find Inno Setup and compile the installer

## Alternative: Portable Version

If you prefer a portable version:
1. Download "Inno Setup" (not the installer, but the ZIP version)
2. Extract it to a folder (e.g., `C:\Tools\Inno Setup 6\`)
3. Update `build_release.bat` to point to your custom path:
   ```batch
   set INNO_SETUP="C:\Tools\Inno Setup 6\ISCC.exe"
   ```

## After Installation

Once Inno Setup is installed, you can:

1. **Test the installer compilation**:
   ```batch
   windows\test_installer.bat
   ```

2. **Build the full release**:
   ```batch
   windows\build_release.bat
   ```

3. **Or manually compile**:
   - Open `windows\installer.iss` in Inno Setup Compiler
   - Click "Build" → "Compile"
   - The installer will be created in `windows\installer\`

## Notes

- Inno Setup is **free and open-source**
- No license required for personal or commercial use (though donations are appreciated)
- The installer will be created as `FinalRoundSetup-1.0.0.exe` in the `windows\installer\` folder
