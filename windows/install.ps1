# ─────────────────────────────────────────────────────────────────────────────
#  LocalShare – Windows Installer
#  Run from the windows\ folder:
#    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # one-time unlock
#    .\install.ps1
# ─────────────────────────────────────────────────────────────────────────────

$ScriptDir  = "$env:APPDATA\LocalShare"
$ScriptPath = "$ScriptDir\share.py"
$SourcePy   = Join-Path $PSScriptRoot "share.py"

# ── 1. Check Python ───────────────────────────────────────────────────────────
Write-Host "Checking for Python..." -ForegroundColor Cyan
try {
    $pyver = & python --version 2>&1
    Write-Host "   Found: $pyver" -ForegroundColor Green
} catch {
    Write-Host "Python not found. Install from https://python.org" -ForegroundColor Red
    exit 1
}

# ── 2. Install dependencies ───────────────────────────────────────────────────
Write-Host "Installing dependencies..." -ForegroundColor Cyan
& python -m pip install --quiet "qrcode[pil]"

# ── 3. Copy share.py ──────────────────────────────────────────────────────────
if (-not (Test-Path $SourcePy)) {
    Write-Host "share.py not found next to install.ps1" -ForegroundColor Red
    Write-Host "Make sure both files are in the same folder." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
Copy-Item -Path $SourcePy -Destination $ScriptPath -Force
Write-Host "Copied share.py to $ScriptPath" -ForegroundColor Green

# ── 4. Find pythonw.exe ───────────────────────────────────────────────────────
$pythonw = & python -c "import sys,os; print(os.path.join(os.path.dirname(sys.executable),'pythonw.exe'))"
if (-not (Test-Path $pythonw)) {
    $pythonw = & python -c "import sys; print(sys.executable)"
}

$command   = "`"$pythonw`" `"$ScriptPath`" `"%1`""
$bgCommand = "`"$pythonw`" `"$ScriptPath`" `"%V`""

# ── 5. Registry entries ───────────────────────────────────────────────────────
# Note: PowerShell's registry provider treats * as a wildcard and hangs.
#       We use reg.exe for the file key (Classes\*) and PowerShell for the rest.
Write-Host "Writing registry entries..." -ForegroundColor Cyan

# Right-click a FOLDER
$key = "HKCU:\Software\Classes\Directory\shell\LocalShare"
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name "(Default)" -Value "Share via HTTP"
Set-ItemProperty -Path $key -Name "Icon"      -Value "imageres.dll,168"
New-Item -Path "$key\command" -Force | Out-Null
Set-ItemProperty -Path "$key\command" -Name "(Default)" -Value $command
Write-Host "   Folder key done" -ForegroundColor DarkGray

# Right-click a FILE — use reg.exe because the * in the path confuses PowerShell
$regFileBase = "HKCU\Software\Classes\*\shell\LocalShare"
& reg add "$regFileBase"          /ve /d "Share via HTTP" /f | Out-Null
& reg add "$regFileBase"          /v "Icon" /d "imageres.dll,168" /f | Out-Null
& reg add "$regFileBase\command"  /ve /d $command /f | Out-Null
Write-Host "   File key done" -ForegroundColor DarkGray

# Right-click folder BACKGROUND (nothing selected)
$key = "HKCU:\Software\Classes\Directory\Background\shell\LocalShare"
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -Path $key -Name "(Default)" -Value "Share this folder via HTTP"
Set-ItemProperty -Path $key -Name "Icon"      -Value "imageres.dll,168"
New-Item -Path "$key\command" -Force | Out-Null
Set-ItemProperty -Path "$key\command" -Name "(Default)" -Value $bgCommand
Write-Host "   Background key done" -ForegroundColor DarkGray

# ── 6. Write uninstaller ──────────────────────────────────────────────────────
$uninstallPath = "$ScriptDir\uninstall.ps1"
$uninstallContent = @"
reg delete "HKCU\Software\Classes\*\shell\LocalShare" /f 2>nul
Remove-Item "HKCU:\Software\Classes\Directory\shell\LocalShare" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\Classes\Directory\Background\shell\LocalShare" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$ScriptDir" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "LocalShare uninstalled." -ForegroundColor Green
"@
Set-Content -Path $uninstallPath -Value $uninstallContent -Encoding UTF8

# ── 7. Done ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "LocalShare installed!" -ForegroundColor Green
Write-Host ""
Write-Host "   Right-click any file or folder in Explorer"
Write-Host "   and choose 'Share via HTTP'"
Write-Host ""
Write-Host "   Windows 11: the entry is under 'Show more options'" -ForegroundColor Yellow
Write-Host "   To restore the classic full menu run:" -ForegroundColor Yellow
Write-Host "   reg add HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32 /f /ve" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "   To uninstall: $uninstallPath" -ForegroundColor Cyan