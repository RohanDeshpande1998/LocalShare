# ─────────────────────────────────────────────────────────────────────────────
#  LocalShare – Windows Installer (Folders + Recursive Browser)
# ─────────────────────────────────────────────────────────────────────────────

$ScriptDir  = "$env:APPDATA\LocalShare"
$ScriptPath = "$ScriptDir\share.py"

Write-Host "🔍 Checking for Python..." -ForegroundColor Cyan
try {
    $pyver = & python --version 2>&1
    Write-Host "   Found: $pyver" -ForegroundColor Green
} catch {
    Write-Host "❌ Python not found. Install from https://python.org" -ForegroundColor Red
    exit 1
}

Write-Host "📦 Installing dependencies..." -ForegroundColor Cyan
& python -m pip install --quiet "qrcode[pil]"

New-Item -ItemType Directory -Force -Path $ScriptDir | Out-Null

$PythonScript = @'
import sys, os, socket, threading, tempfile, shutil
import http.server, urllib.parse, zipfile, mimetypes, io
from pathlib import Path
import tkinter as tk
from PIL import Image as PILImage, ImageTk
import qrcode

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.home().resolve()

def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def find_free_port(start=8765, end=8899):
    for port in range(start, end + 1):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(("", port))
            s.close()
            return port
        except OSError:
            continue
    raise RuntimeError("No free ports available")

PORT = find_free_port()
IP   = local_ip()
URL  = f"http://{IP}:{PORT}"

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".heic"}

class GalleryHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, *a): pass

    def safe_path(self, rel):
        path = (ROOT / rel).resolve()
        if ROOT not in path.parents and path != ROOT:
            return None
        return path

    def do_GET(self):
        rel = urllib.parse.unquote(self.path.split("?")[0]).strip("/")

        if rel.startswith("thumb/"):
            return self.serve_thumbnail(rel[6:])

        if rel.startswith("download-folder/"):
            return self.serve_folder_zip(rel[len("download-folder/"):])

        target = self.safe_path(rel)

        if target is None:
            self.send_error(403)
            return

        if target.is_dir():
            self.serve_gallery(target, rel)
        elif target.is_file():
            self.serve_file(target)
        else:
            self.send_error(404)

    def serve_gallery(self, cwd, rel_path):
        folders = sorted([f for f in cwd.iterdir() if f.is_dir()])
        images = sorted([f for f in cwd.iterdir()
                         if f.is_file() and f.suffix.lower() in IMAGE_EXT])
        others = sorted([f for f in cwd.iterdir()
                         if f.is_file() and f.suffix.lower() not in IMAGE_EXT])

        cards = ""

        if rel_path:
            parent = "/".join(rel_path.split("/")[:-1])
            cards += f"""
            <a class="folder-card back-card" href="/{parent}">
              <div class="folder-icon">↩</div>
              <div class="folder-name">..</div>
            </a>
            """

        for folder in folders:
            folder_rel = f"{rel_path}/{folder.name}" if rel_path else folder.name
            cards += f"""
            <div class="folder-wrap">
              <a class="folder-card" href="/{urllib.parse.quote(folder_rel)}">
                <div class="folder-icon">📁</div>
                <div class="folder-name">{folder.name}</div>
              </a>
              <a class="folder-download"
                 href="/download-folder/{urllib.parse.quote(folder_rel)}">⬇</a>
            </div>
            """

        for f in images:
            rel_file = f"{rel_path}/{f.name}" if rel_path else f.name
            size_mb = f.stat().st_size / 1_048_576
            size_str = f"{size_mb:.1f} MB" if size_mb >= 1 else f"{f.stat().st_size // 1024} KB"

            cards += f"""
            <div class="card"
                 onclick="openLightbox('/{urllib.parse.quote(rel_file)}',
                                        '{urllib.parse.quote(f.name)}')">
              <img src="/thumb/{urllib.parse.quote(rel_file)}">
              <div class="card-info">
                <span class="card-name">{f.name}</span>
                <span class="card-size">{size_str}</span>
              </div>
            </div>
            """

        file_rows = ""

        for f in others:
            rel_file = f"{rel_path}/{f.name}" if rel_path else f.name
            size_mb = f.stat().st_size / 1_048_576
            size_str = f"{size_mb:.1f} MB" if size_mb >= 1 else f"{f.stat().st_size // 1024} KB"

            file_rows += f"""
            <a class="file-row"
               href="/{urllib.parse.quote(rel_file)}" download>
              <span>📄</span>
              <span class="file-name">{f.name}</span>
              <span class="file-size">{size_str}</span>
            </a>
            """

        html = f"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LocalShare</title>

<style>
body {{
    background:#0f0f1a;
    color:#e8eaf6;
    font-family:system-ui;
    padding:16px;
}}

.grid {{
    display:grid;
    grid-template-columns:repeat(auto-fill,minmax(150px,1fr));
    gap:12px;
}}

.card,.folder-card {{
    background:#1a1a2e;
    border-radius:14px;
    overflow:hidden;
    text-decoration:none;
    color:white;
}}

.card img {{
    width:100%;
    aspect-ratio:1;
    object-fit:cover;
}}

.card-info {{
    padding:10px;
}}

.folder-card {{
    display:flex;
    flex-direction:column;
    justify-content:center;
    align-items:center;
    min-height:150px;
}}

.folder-icon {{
    font-size:42px;
}}

.folder-name {{
    margin-top:10px;
    font-size:14px;
    text-align:center;
    padding:0 8px;
}}

.folder-wrap {{
    position:relative;
}}

.folder-download {{
    position:absolute;
    top:8px;
    right:8px;
    background:#111827;
    color:#63caff;
    text-decoration:none;
    border-radius:999px;
    width:28px;
    height:28px;
    display:flex;
    align-items:center;
    justify-content:center;
}}

.file-row {{
    display:flex;
    gap:12px;
    background:#1a1a2e;
    padding:12px;
    border-radius:10px;
    margin-top:10px;
    text-decoration:none;
    color:white;
}}

.file-name {{
    flex:1;
}}

.file-size {{
    color:#777;
}}

#lb {{
    display:none;
    position:fixed;
    inset:0;
    background:rgba(0,0,0,.9);
    align-items:center;
    justify-content:center;
    flex-direction:column;
}}

#lb.open {{
    display:flex;
}}

#lb img {{
    max-width:95vw;
    max-height:85vh;
}}
</style>
</head>

<body>

<h2>📡 LocalShare</h2>

<div class="grid">
{cards}
</div>

<div style="margin-top:18px">
{file_rows}
</div>

<div id="lb">
    <img id="lb-img">
</div>

<script>
function openLightbox(src) {{
    document.getElementById('lb-img').src = src;
    document.getElementById('lb').classList.add('open');
}}

document.getElementById('lb').onclick = function() {{
    this.classList.remove('open');
}};
</script>

</body>
</html>
"""

        encoded = html.encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def serve_thumbnail(self, rel):
        path = self.safe_path(rel)

        if not path or not path.is_file():
            self.send_error(404)
            return

        try:
            img = PILImage.open(path)
            img.thumbnail((300,300))
            img = img.convert("RGB")

            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=82)

            data = buf.getvalue()

            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        except Exception:
            self.send_error(500)

    def serve_file(self, filepath):
        mime,_ = mimetypes.guess_type(str(filepath))

        self.send_response(200)
        self.send_header("Content-Type", mime or "application/octet-stream")
        self.send_header("Content-Length", str(filepath.stat().st_size))
        self.end_headers()

        with open(filepath, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    def serve_folder_zip(self, rel):
        folder = self.safe_path(rel)

        if not folder or not folder.is_dir():
            self.send_error(404)
            return

        buf = io.BytesIO()

        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for file in folder.rglob("*"):
                if file.is_file():
                    zf.write(file, file.relative_to(folder.parent))

        data = buf.getvalue()

        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header(
            "Content-Disposition",
            f'attachment; filename="{folder.name}.zip"'
        )
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

httpd = None

def start_server():
    global httpd
    httpd = http.server.ThreadingHTTPServer(("", PORT), GalleryHandler)
    httpd.serve_forever()

threading.Thread(target=start_server, daemon=True).start()

def make_qr(url):
    qr = qrcode.QRCode(box_size=8, border=3)
    qr.add_data(url)
    qr.make(fit=True)

    img = qr.make_image(fill_color="#1a1a2e", back_color="#f0f4ff")
    return ImageTk.PhotoImage(img)

def stop():
    global httpd
    if httpd:
        threading.Thread(target=httpd.shutdown, daemon=True).start()
    root.destroy()

root = tk.Tk()
root.title("LocalShare")
root.geometry("380x520")
root.configure(bg="#0f0f1a")
root.resizable(False, False)

tk.Label(
    root,
    text="📡 LocalShare",
    fg="#63caff",
    bg="#0f0f1a",
    font=("Segoe UI", 18, "bold")
).pack(pady=(20,10))

tk.Label(
    root,
    text=URL,
    fg="#a8f0c6",
    bg="#111827",
    font=("Consolas", 11),
    padx=10,
    pady=8
).pack(fill="x", padx=20)

qr = make_qr(URL)

lbl = tk.Label(root, image=qr, bg="#f0f4ff")
lbl.pack(pady=20)

tk.Button(
    root,
    text="Stop Sharing",
    command=stop,
    bg="#e05c5c",
    fg="white",
    font=("Segoe UI", 11, "bold"),
    relief="flat",
    padx=10,
    pady=8
).pack(fill="x", padx=40)

root.protocol("WM_DELETE_WINDOW", stop)

root.mainloop()
'@

Set-Content -Path $ScriptPath -Value $PythonScript -Encoding UTF8

Write-Host ""
Write-Host "✅ LocalShare installed!"