# Building FinalRound Windows Setup Package

## Quick Start

### Option 1: Automated Build (Recommended)

```batch
cd windows
build_release.bat
```

Or with code signing:
```batch
cd windows
build_release.bat certificate.pfx YourPassword
```

This will:
1. Clean Flutter build
2. Get dependencies
3. Build Windows release
4. Sign executable (if certificate provided)
5. Create installer
6. Sign installer (if certificate provided)

**Output:** `windows\installer\FinalRoundSetup-1.0.0.exe`

---

## Prerequisites

### Required
1. **Flutter SDK** - Already installed
2. **Inno Setup** - Download from https://jrsoftware.org/isinfo.php
   - Install to default location: `C:\Program Files (x86)\Inno Setup 6\`

### Optional (for code signing)
- **Code signing certificate** (.pfx file)
- **Windows SDK** (includes `signtool.exe`)

---

## Manual Build Steps

### Step 1: Build Flutter App

```batch
flutter clean
flutter pub get
flutter build windows --release
```

### Step 2: Update Installer Version

Edit `windows\installer.iss` and update:
```iss
#define AppVersion "1.0.0"  ; Match your pubspec.yaml version (without build number)
```

### Step 3: Build Installer

**Method A: Using Inno Setup Compiler GUI**
1. Open `windows\installer.iss` in Inno Setup Compiler
2. Click **Build** → **Compile**
3. Installer will be created in `windows\installer\`

**Method B: Using Command Line**
```batch
cd windows
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
```

### Step 4: Sign Installer (Optional but Recommended)

```batch
cd windows
sign_app.bat installer\FinalRoundSetup-1.0.0.exe certificate.pfx YourPassword
```

---

## Installer Features

✅ **Modern wizard style**  
✅ **64-bit architecture support**  
✅ **Desktop shortcut option**  
✅ **Start menu integration**  
✅ **Uninstaller included**  
✅ **App icon in installer**  
✅ **LZMA compression** (smaller file size)  
✅ **Admin privileges** (for proper installation)

---

## Output Files

After building, you'll find:

- **Executable**: `build\windows\x64\runner\Release\finalround.exe`
- **Installer**: `windows\installer\FinalRoundSetup-1.0.0.exe`

The installer is ready to distribute to users!

---

## Testing the Installer

1. **Test on clean machine**:
   - Use a VM or clean Windows installation
   - Run the installer
   - Verify app installs and runs correctly

2. **Check Windows Defender**:
   - Right-click installer → **Scan with Microsoft Defender**
   - Should not flag if properly signed

3. **Verify installation**:
   - Check Start Menu entry
   - Verify desktop shortcut (if selected)
   - Test app functionality
   - Uninstall and verify cleanup

---

## Troubleshooting

**"Inno Setup not found"**:
- Install Inno Setup from https://jrsoftware.org/isinfo.php
- Or update path in `build_release.bat`

**"Build directory not found"**:
- Make sure you ran `flutter build windows --release` first
- Check that `build\windows\x64\runner\Release\finalround.exe` exists

**"Installer too large"**:
- Normal for Flutter apps (50-200MB)
- Compression is already enabled (LZMA)
- Consider code splitting if needed

**"Antivirus flags installer"**:
- Code sign both executable and installer
- Submit to Windows Defender: https://www.microsoft.com/en-us/wdsi/filesubmission
- Build reputation over time

---

## Distribution Checklist

- [ ] Update version in `pubspec.yaml` and `installer.iss`
- [ ] Build release: `flutter build windows --release`
- [ ] Create installer: `build_release.bat` or manual
- [ ] Code sign executable and installer
- [ ] Test installer on clean machine
- [ ] Verify Windows Defender doesn't flag it
- [ ] Upload to distribution platform
- [ ] Update download URL in version check API
