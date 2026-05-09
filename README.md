# LocalShare
Select files, folders to temporarily publish on local network. Quickly gain access to these files in your device through QR Code, or easy to copy link. Your devices have to be on the same network for this to work.

Built with Claude

<div align="center">

# 📡 LocalShare

**Instant LAN file sharing from your right-click menu — with a QR code.**

No cloud. No account. No setup. Just right-click → scan → done.

<br>

![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-blue?style=flat-square)
![Python](https://img.shields.io/badge/python-3.8%2B-yellow?style=flat-square&logo=python&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![No cloud](https://img.shields.io/badge/cloud-none-lightgrey?style=flat-square)

<br>


</div>

---

## What it does

Right-click any file or folder → **Share via HTTP 📡** → a popup appears with a QR code.

Scan it with your phone (or any device on the same Wi-Fi) and you instantly get a browser-based file listing you can browse and download from.

- **Files** — only that file is visible, nothing else in the folder
- **Folders** — the full folder tree is browsable
- Sharing stops the moment you close the popup. Nothing runs in the background.

---

## Install

### Linux (Nautilus / GNOME Files)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RohanDeshpande1998/localshare/main/linux/install.sh)
```

Or clone and run locally:

```bash
git clone https://github.com/RohanDeshpande1998/localshare
bash localshare/linux/install.sh
```

Then right-click any file or folder in Nautilus → **Scripts → Share via HTTP 📡**

> **First time?** If the Scripts menu doesn't appear, restart Nautilus: `nautilus -q && nautilus`

---

### Windows

```powershell
# One-time: allow local scripts to run
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# Install
irm https://raw.githubusercontent.com/RohanDeshpande1998/localshare/main/windows/install.ps1 | iex
```

Or clone and run locally:

```powershell
git clone https://github.com/RohanDeshpande1998/localshare
.\localshare\windows\install.ps1
```

Then right-click any file or folder in Explorer → **Share via HTTP 📡**

> **Windows 11:** The entry appears under *Show more options*. See [Windows 11 note](#windows-11) below.

---

## Requirements

| | Linux | Windows |
|---|---|---|
| **Runtime** | Python 3.8+ | Python 3.8+ ([python.org](https://python.org)) |
| **File manager** | Nautilus (GNOME Files) | Windows Explorer |
| **Auto-installed** | `python3-gi`, `qrcode[pil]` | `qrcode[pil]` |

The installers handle all dependencies automatically.

---

## How it works

```
Right-click
    ↓
Installer-placed script runs with the selected path as argument
    ↓
Python's built-in http.server starts on port 8765
    ↓
Local LAN IP is detected (no internet needed)
    ↓
QR code is generated pointing to http://<LAN-IP>:8765
    ↓
Popup window shows the QR code + a Stop button
    ↓
Phone scans QR → opens file browser in mobile browser
    ↓
Close popup → server stops, temp files cleaned up
```

**For files specifically:** instead of exposing the whole parent directory, a temporary folder is created containing only the selected file (via a hard link on Windows, symlink on Linux). The HTTP server is pointed at this temp folder, and it's deleted when sharing stops.

---

## Customisation

The Python script lives at:
- **Linux:** `~/.local/share/nautilus/scripts/Share via HTTP 📡`
- **Windows:** `%APPDATA%\LocalShare\share.py`

Open it in any text editor. Common tweaks:

| What | Where in the script |
|---|---|
| Change port | `PORT = 8765` |
| Bigger/smaller QR | `box_size=8` in `make_qr_*` |
| QR colours | `fill_color`, `back_color` in `make_image()` |
| Window colours | The colour constants at the top of the UI section |

---

## Uninstall

### Linux
```bash
rm ~/.local/share/nautilus/scripts/Share\ via\ HTTP\ 📡
```

### Windows
```powershell
%APPDATA%\LocalShare\uninstall_localshare_windows.ps1
```

---

## Windows 11

Windows 11 introduced a simplified right-click menu that hides third-party entries. To see LocalShare you either:

**Option A** — Click *Show more options* each time (no changes needed)

**Option B** — Restore the classic full right-click menu permanently:
```powershell
reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve
```
Restart Explorer to apply (`taskkill /f /im explorer.exe && start explorer`).

---

## FAQ

**Does this expose my files to the internet?**
No. `http.server` binds to all local interfaces but your router doesn't forward port 8765 unless you've explicitly set that up. It's LAN-only by default.

**Can I share multiple files at once?**
On Linux yes — select multiple files before right-clicking and all of them will appear in the shared listing. On Windows, Explorer only passes one path at a time to context menu scripts.

**What if port 8765 is already in use?**
Change `PORT = 8765` to any unused port above 1024 in the script file.

**Does it work on macOS?**
Not yet — macOS uses Finder which has a different extension system. PRs welcome.

---

## Contributing

Pull requests are welcome. If you want to add:
- **macOS support** — Finder Quick Actions (`.workflow` via Automator, or Swift/AppleScript)
- **Password protection** — subclass `SimpleHTTPRequestHandler` and check a token
- **HTTPS** — wrap the server socket with `ssl.wrap_socket()`
- **Upload support** — override `do_POST` in the handler

Please open an issue first for large changes so we can discuss direction.

---

## License

MIT — do whatever you want with it.

---