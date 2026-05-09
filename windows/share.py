import sys, os, socket, threading, shutil
import http.server, urllib.parse, zipfile, mimetypes, io
from pathlib import Path
import tkinter as tk
from PIL import Image as PILImage, ImageTk
import qrcode

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.home().resolve()

# ── Network ───────────────────────────────────────────────────────────────────
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

# ── Helpers ───────────────────────────────────────────────────────────────────
def safe_path(rel):
    """Resolve rel against ROOT and reject any path that escapes ROOT."""
    path = (ROOT / rel).resolve() if rel else ROOT
    if path != ROOT and ROOT not in path.parents:
        return None
    return path

def list_dir(folder):
    """List a directory, silently skipping unreadable entries."""
    folders, images, others = [], [], []
    try:
        for entry in folder.iterdir():
            try:
                if entry.is_dir():
                    folders.append(entry)
                elif entry.is_file():
                    if entry.suffix.lower() in IMAGE_EXT:
                        images.append(entry)
                    else:
                        others.append(entry)
            except OSError:
                pass   # skip unreadable entries
    except OSError:
        pass
    return sorted(folders), sorted(images), sorted(others)

def content_disposition(filename):
    """
    RFC 5987-compliant Content-Disposition header value.
    Handles filenames with quotes, spaces, unicode, etc.
    """
    ascii_name = filename.encode("ascii", "replace").decode("ascii")
    utf8_name  = urllib.parse.quote(filename, safe="")
    return f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{utf8_name}"

def human_size(n_bytes):
    if n_bytes >= 1_048_576:
        return f"{n_bytes / 1_048_576:.1f} MB"
    return f"{n_bytes // 1024} KB"

# ── Gallery HTTP handler ──────────────────────────────────────────────────────
class GalleryHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, *a): pass

    def do_GET(self):
        rel = urllib.parse.unquote(self.path.split("?")[0]).strip("/")

        # ── Routing ───────────────────────────────────────────────────────────
        # FIX: use lstrip("/") after removing prefix so trailing slash
        #      on the root-level URL doesn't cause a routing miss.

        if rel == "thumb" or rel.startswith("thumb/"):
            return self.serve_thumbnail(rel[len("thumb"):].lstrip("/"))

        # "Download All" — zips only the files visible on the current page (non-recursive)
        if rel == "download-all" or rel.startswith("download-all/"):
            return self.serve_flat_zip(rel[len("download-all"):].lstrip("/"))

        # Per-folder ZIP — recursive
        if rel == "download-folder" or rel.startswith("download-folder/"):
            return self.serve_folder_zip(rel[len("download-folder"):].lstrip("/"))

        target = safe_path(rel)
        if target is None:
            self.send_error(403); return

        if target.is_dir():
            self.serve_gallery(target, rel)
        elif target.is_file():
            self.serve_file(target)
        else:
            self.send_error(404)

    # ── Gallery page ──────────────────────────────────────────────────────────
    def serve_gallery(self, cwd, rel_path):
        folders, images, others = list_dir(cwd)

        cards = ""

        if rel_path:
            parent = "/".join(rel_path.split("/")[:-1])
            cards += (
                f'<a class="folder-card back-card" href="/{parent}">'
                f'<div class="folder-icon">&#8617;</div>'
                f'<div class="folder-name">..</div></a>'
            )

        for folder in folders:
            folder_rel = f"{rel_path}/{folder.name}" if rel_path else folder.name
            cards += (
                f'<div class="folder-wrap">'
                f'<a class="folder-card" href="/{urllib.parse.quote(folder_rel)}">'
                f'<div class="folder-icon">&#128193;</div>'
                f'<div class="folder-name">{folder.name}</div></a>'
                f'<a class="folder-download" '
                f'   href="/download-folder/{urllib.parse.quote(folder_rel)}" '
                f'   title="Download folder as ZIP">&#8595;</a>'
                f'</div>'
            )

        for f in images:
            rel_file = f"{rel_path}/{f.name}" if rel_path else f.name
            size_str = human_size(f.stat().st_size)
            cards += (
                f'<div class="card" '
                f'     onclick="openLightbox(\'/{urllib.parse.quote(rel_file)}\','
                f'\'{urllib.parse.quote(f.name)}\')">'
                f'<img src="/thumb/{urllib.parse.quote(rel_file)}" loading="lazy" alt="">'
                f'<div class="card-info">'
                f'<span class="card-name">{f.name}</span>'
                f'<span class="card-size">{size_str}</span>'
                f'</div>'
                f'<a class="dl-btn" href="/{urllib.parse.quote(rel_file)}" '
                f'   download="{urllib.parse.quote(f.name)}" '
                f'   onclick="event.stopPropagation()">&#8595;</a>'
                f'</div>'
            )

        file_rows = ""
        for f in others:
            rel_file = f"{rel_path}/{f.name}" if rel_path else f.name
            size_str = human_size(f.stat().st_size)
            file_rows += (
                f'<a class="file-row" href="/{urllib.parse.quote(rel_file)}" '
                f'   download="{urllib.parse.quote(f.name)}">'
                f'<span>&#128196;</span>'
                f'<span class="file-name">{f.name}</span>'
                f'<span class="file-size">{size_str}</span>'
                f'<span class="file-dl">&#8595;</span>'
                f'</a>'
            )

        # "Download All" — only counts files visible on this page (not recursive)
        total = len(images) + len(others)
        zip_section = ""
        if total >= 1:
            zip_rel = f"download-all/{urllib.parse.quote(rel_path)}" if rel_path else "download-all"
            label   = f"Download all {total} file{'s' if total != 1 else ''} as ZIP"
            zip_section = f'<a class="zip-btn" href="/{zip_rel}">&#11015; {label}</a>'

        # Breadcrumb
        if rel_path:
            parts  = rel_path.split("/")
            crumbs = ['<a class="crumb" href="/">&#128225; Home</a>']
            for i, part in enumerate(parts):
                href = "/" + "/".join(parts[:i+1])
                crumbs.append(f'<a class="crumb" href="{href}">{part}</a>')
            breadcrumb = (
                '<div class="breadcrumb">'
                + '<span class="sep">/</span>'.join(crumbs)
                + '</div>'
            )
        else:
            breadcrumb = '<div class="breadcrumb"><span class="crumb-home">&#128225; LocalShare</span></div>'

        has_grid  = bool(folders or images)
        has_files = bool(others)
        grid_html  = ('<p class="section-label">Folders &amp; Images</p>'
                      '<div class="grid">' + cards + '</div>') if has_grid else ""
        files_html = '<p class="section-label">Files</p>' + file_rows if has_files else ""
        empty_html = ('<p style="color:#555577;text-align:center;padding:40px">Empty folder.</p>'
                      if not has_grid and not has_files else "")

        html = "\n".join([
            "<!DOCTYPE html>",
            '<html lang="en"><head>',
            '<meta charset="UTF-8">',
            '<meta name="viewport" content="width=device-width, initial-scale=1">',
            "<title>LocalShare</title>",
            "<style>",
            "*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }",
            "body { background: #0f0f1a; color: #e8eaf6; font-family: system-ui, sans-serif; padding: 16px; }",
            "header { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 12px; margin-bottom: 16px; }",
            ".breadcrumb { display: flex; align-items: center; flex-wrap: wrap; gap: 4px; font-size: 0.95rem; }",
            ".crumb { color: #63caff; text-decoration: none; }",
            ".crumb:hover { text-decoration: underline; }",
            ".crumb-home { color: #63caff; }",
            ".sep { color: #444466; margin: 0 2px; }",
            ".zip-btn { background: #1e3a5f; color: #63caff; border: 1px solid #63caff44; padding: 10px 18px; border-radius: 10px; text-decoration: none; font-size: 0.9rem; font-weight: 600; white-space: nowrap; }",
            ".section-label { font-size: 0.75rem; color: #555577; text-transform: uppercase; letter-spacing: 2px; margin: 16px 0 10px; }",
            ".grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; }",
            ".card { background: #1a1a2e; border-radius: 12px; overflow: hidden; position: relative; cursor: pointer; }",
            ".card img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; }",
            ".card-info { padding: 8px 10px 6px; }",
            ".card-name { display: block; font-size: 0.75rem; color: #aaa; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }",
            ".card-size { font-size: 0.7rem; color: #555577; }",
            ".dl-btn { position: absolute; top: 6px; right: 6px; background: rgba(0,0,0,.6); color: #63caff; border-radius: 50%; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; text-decoration: none; font-size: 0.85rem; font-weight: bold; }",
            ".folder-wrap { position: relative; }",
            ".folder-card { background: #1a1a2e; border-radius: 12px; text-decoration: none; color: white; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 130px; }",
            ".folder-card:active { background: #222240; }",
            ".folder-icon { font-size: 38px; }",
            ".folder-name { margin-top: 8px; font-size: 0.8rem; text-align: center; padding: 0 8px; color: #aaa; word-break: break-word; }",
            ".folder-download { position: absolute; top: 8px; right: 8px; background: rgba(0,0,0,.6); color: #63caff; border-radius: 50%; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; text-decoration: none; font-size: 0.85rem; font-weight: bold; }",
            ".back-card { background: #111827; }",
            ".file-row { display: flex; align-items: center; gap: 10px; background: #1a1a2e; border-radius: 10px; padding: 12px 14px; text-decoration: none; color: #e8eaf6; margin-bottom: 8px; }",
            ".file-name { flex: 1; font-size: 0.9rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }",
            ".file-size { font-size: 0.8rem; color: #555577; white-space: nowrap; }",
            ".file-dl { color: #63caff; font-weight: bold; }",
            "#lb { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.92); z-index: 100; flex-direction: column; align-items: center; justify-content: center; }",
            "#lb.open { display: flex; }",
            "#lb img { max-width: 95vw; max-height: 80vh; border-radius: 8px; object-fit: contain; }",
            "#lb-bar { display: flex; gap: 12px; margin-top: 16px; }",
            "#lb-dl { background: #1e3a5f; color: #63caff; border: 1px solid #63caff44; padding: 10px 20px; border-radius: 10px; text-decoration: none; font-weight: 600; font-size: 0.95rem; }",
            "#lb-close { background: #2a1a1a; color: #e05c5c; padding: 10px 20px; border-radius: 10px; cursor: pointer; font-weight: 600; font-size: 0.95rem; border: none; }",
            "</style></head><body>",
            f"<header>{breadcrumb}{zip_section}</header>",
            grid_html,
            f'<div style="margin-top:12px">{files_html}</div>',
            empty_html,
            '<div id="lb"><img id="lb-img" src="" alt=""><div id="lb-bar">',
            '<a id="lb-dl" href="" download>&#11015; Download</a>',
            '<button id="lb-close" onclick="closeLightbox()">&#x2715; Close</button>',
            "</div></div>",
            "<script>",
            "function openLightbox(src,fn){",
            "  document.getElementById('lb-img').src=src;",
            "  var dl=document.getElementById('lb-dl');",
            "  dl.href=src; dl.download=fn;",
            "  document.getElementById('lb').classList.add('open');",
            "}",
            "function closeLightbox(){",
            "  document.getElementById('lb').classList.remove('open');",
            "  document.getElementById('lb-img').src='';",
            "}",
            "document.getElementById('lb').addEventListener('click',function(e){",
            "  if(e.target===this)closeLightbox();",
            "});",
            "</script></body></html>",
        ])

        encoded = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    # ── Thumbnail ─────────────────────────────────────────────────────────────
    def serve_thumbnail(self, rel):
        path = safe_path(rel)
        if not path or not path.is_file():
            self.send_error(404); return
        try:
            img = PILImage.open(path)
            img.thumbnail((300, 300))
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

    # ── Single file download ───────────────────────────────────────────────────
    def serve_file(self, filepath):
        try:
            mime, _ = mimetypes.guess_type(str(filepath))
            size = filepath.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", mime or "application/octet-stream")
            self.send_header("Content-Disposition", content_disposition(filepath.name))
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(filepath, "rb") as f:
                shutil.copyfileobj(f, self.wfile)
        except OSError:
            self.send_error(500)

    # ── "Download All" ZIP — flat, only files visible on current page ──────────
    def serve_flat_zip(self, rel):
        folder = safe_path(rel)
        if not folder or not folder.is_dir():
            self.send_error(404); return

        _, images, others = list_dir(folder)
        files = images + others

        if not files:
            self.send_error(404); return

        zip_name = (folder.name or "localshare") + ".zip"
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", content_disposition(zip_name))
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        # Stream the ZIP directly to the socket — no RAM buffer
        self._stream_zip(files, arcname_fn=lambda f: f.name)

    # ── Per-folder ZIP — recursive ─────────────────────────────────────────────
    def serve_folder_zip(self, rel):
        folder = safe_path(rel)
        if not folder or not folder.is_dir():
            self.send_error(404); return

        zip_name = (folder.name or "localshare") + ".zip"
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", content_disposition(zip_name))
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        all_files = []
        try:
            for f in folder.rglob("*"):
                try:
                    if f.is_file():
                        all_files.append(f)
                except OSError:
                    pass
        except OSError:
            pass

        self._stream_zip(all_files, arcname_fn=lambda f: str(f.relative_to(folder.parent)))

    # ── Streaming ZIP writer ───────────────────────────────────────────────────
    def _stream_zip(self, files, arcname_fn):
        """
        Write a ZIP file in chunks directly to self.wfile.
        Avoids buffering the whole archive in RAM.
        Uses ZIP_STORED (no compression) so we can stream without knowing
        the compressed size in advance — images are already compressed anyway.
        """
        CHUNK = 256 * 1024  # 256 KB chunks

        def write_chunk(data):
            # HTTP chunked transfer encoding
            self.wfile.write(f"{len(data):X}\r\n".encode())
            self.wfile.write(data)
            self.wfile.write(b"\r\n")

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
            for filepath in files:
                try:
                    arcname = arcname_fn(filepath)
                    zf.write(filepath, arcname)
                    # Flush chunks as we go
                    chunk = buf.getvalue()
                    if len(chunk) >= CHUNK:
                        write_chunk(chunk)
                        buf.seek(0)
                        buf.truncate(0)
                except OSError:
                    pass  # skip unreadable files

        # Flush remaining bytes + ZIP central directory
        remaining = buf.getvalue()
        if remaining:
            write_chunk(remaining)

        # Chunked transfer terminator
        self.wfile.write(b"0\r\n\r\n")


# ── Start server ──────────────────────────────────────────────────────────────
httpd = None

def start_server():
    global httpd
    httpd = http.server.ThreadingHTTPServer(("", PORT), GalleryHandler)
    httpd.serve_forever()

threading.Thread(target=start_server, daemon=True).start()

# ── QR code ───────────────────────────────────────────────────────────────────
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

# ── Tkinter UI ────────────────────────────────────────────────────────────────
root = tk.Tk()
root.title("LocalShare")
root.configure(bg="#0f0f1a")
root.resizable(False, False)

root.update_idletasks()
w, h = 380, 520
x = (root.winfo_screenwidth()  - w) // 2
y = (root.winfo_screenheight() - h) // 2
root.geometry(f"{w}x{h}+{x}+{y}")
root.protocol("WM_DELETE_WINDOW", stop)

tk.Label(root, text="LocalShare", fg="#63caff", bg="#0f0f1a",
         font=("Segoe UI", 18, "bold")).pack(pady=(20, 4))
tk.Label(root, text="Scan to access from any device on this network",
         fg="#555577", bg="#0f0f1a", font=("Segoe UI", 9)).pack()
tk.Label(root, text=URL, fg="#a8f0c6", bg="#111827",
         font=("Consolas", 11), padx=10, pady=8).pack(fill="x", padx=20, pady=(10, 0))

qr_img = make_qr(URL)
lbl = tk.Label(root, image=qr_img, bg="#f0f4ff")
lbl.image = qr_img
lbl.pack(pady=16)

btn_frame = tk.Frame(root, bg="#0f0f1a")
btn_frame.pack(fill="x", padx=20)

def copy_url():
    root.clipboard_clear()
    root.clipboard_append(URL)

tk.Button(btn_frame, text="Copy URL", command=copy_url,
          bg="#1e2a3a", fg="#63caff", font=("Segoe UI", 11, "bold"),
          relief="flat", padx=10, pady=8).pack(side="left", expand=True, fill="x", padx=(0, 6))
tk.Button(btn_frame, text="Stop Sharing", command=stop,
          bg="#e05c5c", fg="white", font=("Segoe UI", 11, "bold"),
          relief="flat", padx=10, pady=8).pack(side="left", expand=True, fill="x")

root.mainloop()