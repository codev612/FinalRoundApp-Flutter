# PowerShell script for code signing FinalRound Windows executable
# Usage: .\sign_app.ps1 -ExePath "path\to\finalround.exe" -PfxPath "path\to\certificate.pfx" -PfxPassword "password"

param(
    [Parameter(Mandatory=$true)]
    [string]$ExePath,
    
    [Parameter(Mandatory=$true)]
    [string]$PfxPath,
    
    [Parameter(Mandatory=$true)]
    [string]$PfxPassword
)

if (-not (Test-Path $ExePath)) {
    Write-Error "Executable not found: $ExePath"
    exit 1
}

if (-not (Test-Path $PfxPath)) {
    Write-Error "Certificate not found: $PfxPath"
    exit 1
}

Write-Host "Signing $ExePath..."

# Sign the executable
$signResult = & signtool sign /f $PfxPath /p $PfxPassword /t http://timestamp.digicert.com /fd SHA256 $ExePath

if ($LASTEXITCODE -eq 0) {
    Write-Host "Successfully signed: $ExePath" -ForegroundColor Green
    
    # Verify the signature
    Write-Host "Verifying signature..."
    & signtool verify /pa /v $ExePath
} else {
    Write-Error "Signing failed"
    exit 1
}
