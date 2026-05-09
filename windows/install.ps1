# ─────────────────────────────────────────────────────────────────────────────
#  LocalShare – Windows Installer
#  Run once in PowerShell (no admin required):
#    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # one-time unlock
#    .\install_localshare_windows.ps1
# ─────────────────────────────────────────────────────────────────────────────

$ScriptDir  = "$env:APPDATA\LocalShare"
$ScriptPath = "$ScriptDir\share.py"

# ── 1. Check Python ───────────────────────────────────────────────────────────
Write-Host "🔍 Checking for Python..." -ForegroundColor Cyan
try {
    $pyver = & python --version 2>&1
    Write-Host "   Found: $pyver" -ForegroundColor Green
} catch {
    Write-Host "❌ Python not found. Install from https://python.org" -ForegroundColor Red
    exit 1
}

# ── 2. Install qrcode ─────────────────────────────────────────────────────────
Write-Host "📦 Installing qrcode..." -ForegroundColor Cyan
& python -m pip install --quiet "qrcode[pil]"

# ── 3. Write the Python share script ──────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null
Write-Host "📝 Writing share script to $ScriptPath..." -ForegroundColor Cyan

$PythonScript = @'
import sys, os, socket, threading, tempfile, shutil
import http.server, urllib.parse
from pathlib import Path
import tkinter as tk
from tkinter import font as tkfont
from PIL import Image, ImageTk
import qrcode, io

PORT     = 8765
httpd    = None
temp_dir = None

# ── Local IP ──────────────────────────────────────────────────────────────────
def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

# ── Resolve what to serve ─────────────────────────────────────────────────────
selected = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home()

if selected.is_dir():
    serve_path = selected

else:
    # File selected: hard-link it into a temp dir so only that file is visible
    temp_dir = tempfile.mkdtemp(prefix="localshare_")
    dst = Path(temp_dir) / selected.name
    try:
        os.link(selected, dst)        # instant hard link (same drive)
    except OSError:
        shutil.copy2(selected, dst)   # fallback: actual copy (cross-drive etc.)
    serve_path = Path(temp_dir)

os.chdir(serve_path)

# ── HTTP server ───────────────────────────────────────────────────────────────
def start_server():
    global httpd
    handler = http.server.SimpleHTTPRequestHandler
    handler.log_message = lambda *a: None
    httpd = http.server.HTTPServer(("", PORT), handler)
    httpd.serve_forever()

threading.Thread(target=start_server, daemon=True).start()

IP  = local_ip()
URL = f"http://{IP}:{PORT}"

# ── QR code ───────────────────────────────────────────────────────────────────
def make_qr_photoimage(url):
    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=8,
        border=3,
    )
    qr.add_data(url)
    qr.make(fit=True)
    pil_img = qr.make_image(fill_color="#1a1a2e", back_color="#f0f4ff")
    return ImageTk.PhotoImage(pil_img)

# ── Stop everything ───────────────────────────────────────────────────────────
def stop_sharing():
    global httpd, temp_dir
    if httpd:
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    if temp_dir:
        shutil.rmtree(temp_dir, ignore_errors=True)
    root.destroy()

# ── Tkinter UI ────────────────────────────────────────────────────────────────
BG        = "#0f0f1a"
CARD_BG   = "#1a1a2e"
ACCENT    = "#63caff"
GREEN     = "#a8f0c6"
MUTED     = "#555577"
RED       = "#e05c5c"
WHITE     = "#e8eaf6"

root = tk.Tk()
root.title("LocalShare")
root.configure(bg=BG)
root.resizable(False, False)

# Centre the window
root.update_idletasks()
w, h = 380, 520
x = (root.winfo_screenwidth()  - w) // 2
y = (root.winfo_screenheight() - h) // 2
root.geometry(f"{w}x{h}+{x}+{y}")

root.protocol("WM_DELETE_WINDOW", stop_sharing)

# Card frame
card = tk.Frame(root, bg=CARD_BG, padx=24, pady=20)
card.pack(fill="both", expand=True, padx=16, pady=16)

# Title
tk.Label(card, text="LocalShare 📡", font=("Segoe UI", 18, "bold"),
         fg=ACCENT, bg=CARD_BG).pack(anchor="w")

# Subtitle
tk.Label(card, text="Scan to access from any device on this network",
         font=("Segoe UI", 9), fg=MUTED, bg=CARD_BG).pack(anchor="w", pady=(2, 10))

# URL chip
url_frame = tk.Frame(card, bg="#0a0a18", padx=10, pady=6)
url_frame.pack(fill="x")
url_var = tk.StringVar(value=URL)
tk.Label(url_frame, textvariable=url_var, font=("Consolas", 11),
         fg=GREEN, bg="#0a0a18").pack(anchor="w")

# Path label
short_path = str(serve_path)
if len(short_path) > 50:
    short_path = "..." + short_path[-47:]
tk.Label(card, text=f"📁  {short_path}", font=("Segoe UI", 9),
         fg=MUTED, bg=CARD_BG).pack(anchor="w", pady=(6, 10))

# QR code
try:
    qr_photo = make_qr_photoimage(URL)
    qr_lbl = tk.Label(card, image=qr_photo, bg="#f0f4ff",
                      padx=8, pady=8, relief="flat")
    qr_lbl.image = qr_photo   # prevent garbage collection
    qr_lbl.pack(pady=(0, 16))
except Exception as e:
    tk.Label(card, text=f"QR error:\n{e}", fg="red", bg=CARD_BG).pack()

# Buttons
btn_frame = tk.Frame(card, bg=CARD_BG)
btn_frame.pack(fill="x")

def copy_url():
    root.clipboard_clear()
    root.clipboard_append(URL)

tk.Button(btn_frame, text="⎘  Copy URL", command=copy_url,
          font=("Segoe UI", 10, "bold"),
          fg=ACCENT, bg="#1e2a3a", relief="flat",
          activebackground="#263545", activeforeground=ACCENT,
          padx=12, pady=8, cursor="hand2").pack(side="left", expand=True, fill="x", padx=(0, 6))

tk.Button(btn_frame, text="⏹  Stop Sharing", command=stop_sharing,
          font=("Segoe UI", 10, "bold"),
          fg=WHITE, bg=RED, relief="flat",
          activebackground="#c0392b", activeforeground=WHITE,
          padx=12, pady=8, cursor="hand2").pack(side="left", expand=True, fill="x")

root.mainloop()
'@

Set-Content -Path $ScriptPath -Value $PythonScript -Encoding UTF8

# ── 4. Registry entries ───────────────────────────────────────────────────────
# Using HKCU (Current User) — no admin rights needed.
# HKCU\Software\Classes overrides HKCR for the current user only.

Write-Host "🔑 Writing registry entries..." -ForegroundColor Cyan

# Find pythonw.exe (runs Python without a console window)
$pythonw = & python -c "import sys,os; print(os.path.join(os.path.dirname(sys.executable),'pythonw.exe'))"
if (-not (Test-Path $pythonw)) {
    # Some installs only have python.exe — fall back to it
    $pythonw = & python -c "import sys; print(sys.executable)"
}

$command = "`"$pythonw`" `"$ScriptPath`" `"%1`""

# Right-click on a FOLDER
$folderKey = "HKCU:\Software\Classes\Directory\shell\LocalShare"
New-Item -Path $folderKey -Force | Out-Null
Set-ItemProperty -Path $folderKey -Name "(Default)" -Value "Share via HTTP 📡"
Set-ItemProperty -Path $folderKey -Name "Icon"      -Value "imageres.dll,168"
New-Item -Path "$folderKey\command" -Force | Out-Null
Set-ItemProperty -Path "$folderKey\command" -Name "(Default)" -Value $command

# Right-click on a FILE
$fileKey = "HKCU:\Software\Classes\*\shell\LocalShare"
New-Item -Path $fileKey -Force | Out-Null
Set-ItemProperty -Path $fileKey -Name "(Default)" -Value "Share via HTTP 📡"
Set-ItemProperty -Path $fileKey -Name "Icon"      -Value "imageres.dll,168"
New-Item -Path "$fileKey\command" -Force | Out-Null
Set-ItemProperty -Path "$fileKey\command" -Name "(Default)" -Value $command

# Right-click on folder BACKGROUND (when nothing is selected)
$bgCommand = "`"$pythonw`" `"$ScriptPath`" `"%V`""   # %V gives current folder path
$bgKey = "HKCU:\Software\Classes\Directory\Background\shell\LocalShare"
New-Item -Path $bgKey -Force | Out-Null
Set-ItemProperty -Path $bgKey -Name "(Default)" -Value "Share this folder via HTTP 📡"
Set-ItemProperty -Path $bgKey -Name "Icon"      -Value "imageres.dll,168"
New-Item -Path "$bgKey\command" -Force | Out-Null
Set-ItemProperty -Path "$bgKey\command" -Name "(Default)" -Value $bgCommand

# ── 5. Done ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "✅  LocalShare installed!" -ForegroundColor Green
Write-Host ""
Write-Host "   Right-click any file or folder in Explorer"
Write-Host "   → 'Share via HTTP 📡'"
Write-Host ""
Write-Host "   💡 On Windows 11: the entry is under 'Show more options'" -ForegroundColor Yellow
Write-Host "      Run the line below to restore the classic full menu:" -ForegroundColor Yellow
Write-Host "      reg add HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32 /f /ve" -ForegroundColor DarkYellow
Write-Host ""
Write-Host "   To uninstall, run: uninstall_localshare_windows.ps1" -ForegroundColor Cyan

# ── Bonus: write the uninstaller ─────────────────────────────────────────────
$Uninstaller = @"
Remove-Item -Path 'HKCU:\Software\Classes\Directory\shell\LocalShare' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Classes\*\shell\LocalShare'         -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Classes\Directory\Background\shell\LocalShare' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path '$ScriptDir' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'LocalShare uninstalled.' -ForegroundColor Green
"@
Set-Content -Path "$ScriptDir\uninstall_localshare_windows.ps1" -Value $Uninstaller -Encoding UTF8
Write-Host "   Uninstaller saved to: $ScriptDir\uninstall_localshare_windows.ps1" -ForegroundColor Cyan