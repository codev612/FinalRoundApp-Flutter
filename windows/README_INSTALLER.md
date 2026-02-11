# FinalRound Windows Installer & Code Signing Guide

## Code Signing

### Prerequisites
- Code signing certificate (.pfx file)
- Windows SDK (includes `signtool.exe`)

### Signing the Executable

**Option 1: Using Batch Script**
```batch
sign_app.bat build\windows\x64\runner\Release\finalround.exe certificate.pfx YourPassword
```

**Option 2: Using PowerShell**
```powershell
.\sign_app.ps1 -ExePath "build\windows\x64\runner\Release\finalround.exe" -PfxPath "certificate.pfx" -PfxPassword "YourPassword"
```

**Option 3: Manual Signing**
```batch
signtool sign /f certificate.pfx /p YourPassword /t http://timestamp.digicert.com /fd SHA256 build\windows\x64\runner\Release\finalround.exe
```

### Verify Signature
```batch
signtool verify /pa /v build\windows\x64\runner\Release\finalround.exe
```

### Getting a Code Signing Certificate
- **DigiCert**: https://www.digicert.com/code-signing/
- **Sectigo (formerly Comodo)**: https://sectigo.com/ssl-certificates-tls/code-signing
- **GlobalSign**: https://www.globalsign.com/en/code-signing-certificate
- **Certum**: https://www.certum.eu/en/certificates/code-signing/

**Note**: Code signing certificates typically cost $200-500/year and require identity verification.

---

## Installer Setup (Inno Setup)

### Prerequisites
1. Download and install **Inno Setup**: https://jrsoftware.org/isinfo.php
2. Build your Flutter app in Release mode:
   ```batch
   flutter build windows --release
   ```

### Building the Installer

1. **Edit `installer.iss`**:
   - Update `#define AppVersion` with your current version
   - Verify `#define BuildDir` matches your build output path
   - Adjust paths if needed

2. **Compile the installer**:
   ```batch
   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
   ```
   
   Or open `installer.iss` in Inno Setup Compiler and click "Build" → "Compile"

3. **Output**:
   - Installer will be created in `windows\installer\FinalRoundSetup-1.0.0.exe`

### Signing the Installer

After building the installer, sign it:
```batch
sign_app.bat installer\FinalRoundSetup-1.0.0.exe certificate.pfx YourPassword
```

---

## Build & Release Workflow

### Complete Release Process:

1. **Update version in `pubspec.yaml`**:
   ```yaml
   version: 1.0.0+1
   ```

2. **Build the app**:
   ```batch
   flutter clean
   flutter pub get
   flutter build windows --release
   ```

3. **Sign the executable**:
   ```batch
   sign_app.bat build\windows\x64\runner\Release\finalround.exe certificate.pfx YourPassword
   ```

4. **Build the installer**:
   ```batch
   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
   ```

5. **Sign the installer**:
   ```batch
   sign_app.bat installer\FinalRoundSetup-1.0.0.exe certificate.pfx YourPassword
   ```

6. **Test the installer**:
   - Run the installer on a clean Windows machine
   - Verify the app installs and runs correctly
   - Check Windows Defender doesn't flag it

---

## Chrome / Browser Says "Malicious" or "Dangerous"

Browsers (Chrome, Edge, etc.) often warn on **unsigned** Windows installers because they have no way to verify the publisher. This is expected for an unsigned file.

### Fix: Code sign the installer (required)

1. **Sign both the app and the installer** before uploading to your server:
   - Sign `finalround.exe` (see "Signing the Executable" above).
   - Build the installer with Inno Setup.
   - Sign the installer `.exe` (e.g. `FinalRoundSetup-1.0.0.exe`) with the same certificate.
2. **Re-upload the signed installer** to your server so users download the signed build.
3. **Use timestamping** (your `sign_app.bat` already uses `/t http://timestamp.digicert.com`) so the signature stays valid after the cert expires.

Once the file is signed by a trusted certificate, Chrome and other browsers are much less likely to show "malicious" or "dangerous file" warnings.

### If you don’t have a certificate yet

- Get a **code signing certificate** from a trusted CA (DigiCert, Sectigo, GlobalSign, Certum, etc.). Cost is typically ~$200–500/year.
- **EV (Extended Validation)** certs often get SmartScreen reputation faster and can reduce browser warnings sooner.

### After signing: build reputation

- **Microsoft SmartScreen**: Submit the signed installer at [Microsoft Security Intelligence](https://www.microsoft.com/en-us/wdsi/filesubmission). Choose "Developer submission" and indicate it’s your legitimate app. This helps reduce "Unknown publisher" and Windows warnings.
- **Google Safe Browsing**: If Chrome still flags the download, you can [report a false positive](https://safebrowsing.google.com/safebrowsing/report_error/) and request review.
- **VirusTotal**: Upload the signed installer. If any engine flags it, use each vendor’s link to submit a false positive. This can help other AVs and browsers.

### Server / download tips

- Serve the installer over **HTTPS** (you likely already do).
- Use a clear, consistent **filename** (e.g. `FinalRoundSetup-1.0.0.exe`).
- Optional: set `Content-Disposition: attachment` so the browser offers "Save" instead of "Run" and the filename is preserved.

---

## Reducing False Positives

Even with code signing, you may still need to:

1. **Submit to Windows Defender**:
   - https://www.microsoft.com/en-us/wdsi/filesubmission
   - Upload your signed installer
   - Explain it's a legitimate Flutter app

2. **Submit to VirusTotal**:
   - Upload your signed installer
   - Request a review if flagged

3. **Build reputation**:
   - Consistent releases with signed installers
   - Clear app description and website
   - User downloads and positive feedback

---

## Troubleshooting

**"signtool is not recognized"**:
- Install Windows SDK or Visual Studio Build Tools
- Add SDK bin path to PATH: `C:\Program Files (x86)\Windows Kits\10\bin\<version>\x64`

**"Certificate expired"**:
- Renew your code signing certificate
- Re-sign all executables

**"Timestamp server unavailable"**:
- Try alternative timestamp servers:
  - `http://timestamp.digicert.com`
  - `http://timestamp.verisign.com/scripts/timstamp.dll`
  - `http://timestamp.globalsign.com/scripts/timestamp.dll`
