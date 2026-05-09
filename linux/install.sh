#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  LocalShare – QR-powered HTTP file sharing for Nautilus
# ─────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$HOME/.local/share/nautilus/scripts"
SCRIPT_NAME="Share via HTTP 📡"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

echo "📦 Installing dependencies..."

sudo apt-get update -qq

sudo apt-get install -y \
    python3-gi \
    python3-gi-cairo \
    gir1.2-gtk-3.0 \
    gir1.2-gdk-3.0 \
    python3-pip \
    python3-pil \
    --no-install-recommends -qq

pip3 install --quiet qrcode[pil] 2>/dev/null || \
pip3 install --quiet --break-system-packages qrcode[pil]

mkdir -p "$SCRIPT_DIR"

cat > "$SCRIPT_PATH" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3

import os
import io
import socket
import shutil
import zipfile
import mimetypes
import tempfile
import threading
import urllib.parse
import http.server

from pathlib import Path

# ─────────────────────────────────────────────────────────────
# Resolve selection
# ─────────────────────────────────────────────────────────────

selected_raw = os.environ.get(
    "NAUTILUS_SCRIPT_SELECTED_FILE_PATHS",
    ""
).strip()

paths = [p for p in selected_raw.splitlines() if p]

temp_dir = None

if not paths:

    uri = os.environ.get(
        "NAUTILUS_SCRIPT_CURRENT_URI",
        ""
    )

    serve_path = (
        Path(uri.replace("file://", "")).parent
        if uri else Path.home()
    )

else:

    first = Path(paths[0])

    if first.is_dir():

        serve_path = first

    else:

        temp_dir = tempfile.mkdtemp(
            prefix="localshare_"
        )

        for p in paths:

            src = Path(p)

            if src.is_file():
                os.symlink(
                    src,
                    Path(temp_dir) / src.name
                )

        serve_path = Path(temp_dir)

ROOT = serve_path.resolve()

# ─────────────────────────────────────────────────────────────
# Networking
# ─────────────────────────────────────────────────────────────

def local_ip():

    try:

        s = socket.socket(
            socket.AF_INET,
            socket.SOCK_DGRAM
        )

        s.connect(("8.8.8.8", 80))

        ip = s.getsockname()[0]

        s.close()

        return ip

    except Exception:

        return "127.0.0.1"

def find_free_port(start=8765, end=8899):

    for port in range(start, end + 1):

        try:

            s = socket.socket(
                socket.AF_INET,
                socket.SOCK_STREAM
            )

            s.bind(("", port))
            s.close()

            return port

        except OSError:
            continue

    raise RuntimeError("No free ports found")

PORT = find_free_port()
IP = local_ip()
URL = f"http://{IP}:{PORT}"

# ─────────────────────────────────────────────────────────────
# Gallery HTTP server
# ─────────────────────────────────────────────────────────────

from PIL import Image as PILImage

class GalleryHandler(http.server.BaseHTTPRequestHandler):

    IMAGE_EXT = {
        ".jpg", ".jpeg", ".png",
        ".gif", ".webp", ".bmp",
        ".heic"
    }

    def log_message(self, *args):
        pass

    def safe_path(self, rel_path=""):

        target = (ROOT / rel_path).resolve()

        if ROOT != target and ROOT not in target.parents:
            return None

        return target

    def do_GET(self):

        raw_path = urllib.parse.unquote(
            self.path.split("?")[0]
        )

        if raw_path == "/download-all.zip":
            self.serve_zip()
            return

        if raw_path.startswith("/download-folder/"):
            self.serve_folder_zip(
                raw_path[len("/download-folder/"):]
            )
            return

        if raw_path.startswith("/thumb/"):
            self.serve_thumbnail(raw_path[7:])
            return

        rel = raw_path.lstrip("/")

        target = self.safe_path(rel)

        if not target:
            self.send_error(403)
            return

        if target.is_dir():
            self.serve_gallery(target, rel)
            return

        if target.is_file():
            self.serve_file(rel)
            return

        self.send_error(404)

    def serve_gallery(self, cwd, rel_path):

        folders = sorted([
            f for f in cwd.iterdir()
            if f.is_dir()
        ])

        images = sorted([
            f for f in cwd.iterdir()
            if f.is_file()
            and f.suffix.lower() in self.IMAGE_EXT
        ])

        others = sorted([
            f for f in cwd.iterdir()
            if f.is_file()
            and f.suffix.lower() not in self.IMAGE_EXT
        ])

        parent_link = ""

        if rel_path:

            parent = str(Path(rel_path).parent)

            if parent == ".":
                parent = ""

            parent_link = f"""
            <a class="folder-row" href="/{urllib.parse.quote(parent)}">
                ⬅ Back
            </a>
            """

        folder_cards = ""

        for f in folders:

            folder_rel = str(Path(rel_path) / f.name)

            folder_cards += f"""
            <div class="folder-card-wrap">

                <a class="folder-card"
                   href="/{urllib.parse.quote(folder_rel)}">

                    <div class="folder-icon">📁</div>

                    <div class="folder-name">
                        {f.name}
                    </div>

                </a>

                <a class="folder-dl-btn"
                   href="/download-folder/{urllib.parse.quote(folder_rel)}"
                   download>
                   ⬇
                </a>

            </div>
            """

        img_cards = ""

        for f in images:

            rel_file = str(Path(rel_path) / f.name)

            size_mb = f.stat().st_size / 1_048_576

            size_str = (
                f"{size_mb:.1f} MB"
                if size_mb >= 1
                else f"{f.stat().st_size // 1024} KB"
            )

            quoted = urllib.parse.quote(rel_file)

            img_cards += f"""
            <div class="card"
                 onclick="openLightbox('/{quoted}','{f.name}')">

              <img src="/thumb/{quoted}"
                   loading="lazy"
                   alt="{f.name}">

              <div class="card-info">
                <span class="card-name">{f.name}</span>
                <span class="card-size">{size_str}</span>
              </div>

              <a class="dl-btn"
                 href="/{quoted}"
                 download
                 onclick="event.stopPropagation()">
                 ⬇
              </a>

            </div>
            """

        file_rows = ""

        for f in others:

            rel_file = str(Path(rel_path) / f.name)

            size_mb = f.stat().st_size / 1_048_576

            size_str = (
                f"{size_mb:.1f} MB"
                if size_mb >= 1
                else f"{f.stat().st_size // 1024} KB"
            )

            quoted = urllib.parse.quote(rel_file)

            file_rows += f"""
            <a class="file-row"
               href="/{quoted}"
               download>

              <span class="file-icon">📄</span>

              <span class="file-name">{f.name}</span>

              <span class="file-size">{size_str}</span>

              <span class="file-dl">⬇</span>

            </a>
            """

        zip_btn = """
        <a class="zip-btn"
           href="/download-all.zip"
           download>
           ⬇ Download ZIP
        </a>
        """

        html = f"""
<!DOCTYPE html>
<html lang="en">

<head>

<meta charset="UTF-8">

<meta name="viewport"
      content="width=device-width, initial-scale=1">

<title>LocalShare</title>

<style>

* {{
    box-sizing: border-box;
}}

body {{
    margin: 0;
    padding: 16px;
    background: #0f0f1a;
    color: #e8eaf6;
    font-family: system-ui, sans-serif;
}}

header {{
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 20px;
}}

h1 {{
    color: #63caff;
    font-size: 1.4rem;
}}

.zip-btn {{
    background: #1e3a5f;
    color: #63caff;
    text-decoration: none;
    padding: 10px 16px;
    border-radius: 10px;
}}

.section-label {{
    color: #555577;
    font-size: 0.75rem;
    margin: 18px 0 10px;
    text-transform: uppercase;
    letter-spacing: 2px;
}}

.folder-row {{
    display: block;
    background: #1a1a2e;
    color: #63caff;
    text-decoration: none;
    padding: 14px;
    border-radius: 10px;
    margin-bottom: 10px;
    font-weight: 600;
}}

.grid {{
    display: grid;
    grid-template-columns:
        repeat(auto-fill, minmax(150px, 1fr));
    gap: 10px;
}}

.folder-card-wrap {{
    position: relative;
}}

.folder-card {{
    background: #1a1a2e;
    border-radius: 12px;
    padding: 20px 12px;
    text-decoration: none;
    color: #e8eaf6;

    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;

    aspect-ratio: 1;
}}

.folder-dl-btn {{
    position: absolute;
    top: 8px;
    right: 8px;

    width: 30px;
    height: 30px;

    border-radius: 50%;

    background: rgba(0,0,0,.6);

    color: #63caff;

    display: flex;
    align-items: center;
    justify-content: center;

    text-decoration: none;
    font-size: 0.9rem;
}}

.folder-icon {{
    font-size: 3rem;
    margin-bottom: 10px;
}}

.folder-name {{
    font-size: 0.8rem;
    text-align: center;

    width: 100%;

    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}}

.card {{
    background: #1a1a2e;
    border-radius: 12px;
    overflow: hidden;
    position: relative;
}}

.card img {{
    width: 100%;
    aspect-ratio: 1;
    object-fit: cover;
}}

.card-info {{
    padding: 8px;
}}

.card-name {{
    display: block;
    font-size: 0.75rem;
    color: #aaa;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}}

.card-size {{
    color: #555577;
    font-size: 0.7rem;
}}

.dl-btn {{
    position: absolute;
    top: 6px;
    right: 6px;
    width: 28px;
    height: 28px;
    border-radius: 50%;
    text-decoration: none;
    background: rgba(0,0,0,.6);
    color: #63caff;
    display: flex;
    align-items: center;
    justify-content: center;
}}

.file-row {{
    display: flex;
    align-items: center;
    gap: 10px;
    background: #1a1a2e;
    border-radius: 10px;
    padding: 12px;
    margin-bottom: 8px;
    text-decoration: none;
    color: #e8eaf6;
}}

.file-name {{
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}}

.file-size {{
    color: #555577;
    font-size: 0.8rem;
}}

.file-dl {{
    color: #63caff;
}}

#lb {{
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(0,0,0,.92);
    z-index: 100;
    flex-direction: column;
    align-items: center;
    justify-content: center;
}}

#lb.open {{
    display: flex;
}}

#lb img {{
    max-width: 95vw;
    max-height: 80vh;
    object-fit: contain;
    border-radius: 8px;
}}

</style>

</head>

<body>

<header>
    <h1>📡 LocalShare</h1>
    {zip_btn}
</header>

{parent_link}

{"<p class='section-label'>Folders</p><div class='grid'>" + folder_cards + "</div>" if folders else ""}

{"<p class='section-label'>Images</p><div class='grid'>" + img_cards + "</div>" if images else ""}

{"<p class='section-label'>Files</p>" + file_rows if others else ""}

<div id="lb">

    <img id="lb-img">

</div>

<script>

function openLightbox(src) {{

    document.getElementById("lb-img").src = src;

    document.getElementById("lb")
        .classList.add("open");
}}

document.getElementById("lb")
.addEventListener("click", function(e) {{

    if (e.target === this) {{

        this.classList.remove("open");

        document.getElementById("lb-img").src = "";
    }}
}});

</script>

</body>
</html>
"""

        encoded = html.encode("utf-8")

        self.send_response(200)

        self.send_header(
            "Content-Type",
            "text/html; charset=utf-8"
        )

        self.send_header(
            "Content-Length",
            str(len(encoded))
        )

        self.end_headers()

        self.wfile.write(encoded)

    def serve_thumbnail(self, filename):

        filepath = self.safe_path(filename)

        if not filepath or not filepath.is_file():
            self.send_error(404)
            return

        try:

            img = PILImage.open(filepath)

            img.thumbnail((300, 300))

            img = img.convert("RGB")

            buf = io.BytesIO()

            img.save(
                buf,
                format="JPEG",
                quality=82
            )

            data = buf.getvalue()

            self.send_response(200)

            self.send_header(
                "Content-Type",
                "image/jpeg"
            )

            self.send_header(
                "Content-Length",
                str(len(data))
            )

            self.end_headers()

            self.wfile.write(data)

        except Exception:
            self.send_error(500)

    def serve_file(self, filename):

        filepath = self.safe_path(filename)

        if not filepath or not filepath.is_file():
            self.send_error(404)
            return

        mime, _ = mimetypes.guess_type(str(filepath))

        self.send_response(200)

        self.send_header(
            "Content-Type",
            mime or "application/octet-stream"
        )

        self.send_header(
            "Content-Disposition",
            f'attachment; filename="{filepath.name}"'
        )

        self.send_header(
            "Content-Length",
            str(filepath.stat().st_size)
        )

        self.end_headers()

        with open(filepath, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    def serve_folder_zip(self, foldername):

        folder = self.safe_path(foldername)

        if not folder or not folder.is_dir():
            self.send_error(404)
            return

        buf = io.BytesIO()

        with zipfile.ZipFile(
            buf,
            "w",
            zipfile.ZIP_STORED
        ) as zf:

            for f in folder.rglob("*"):

                if f.is_file():

                    zf.write(
                        f,
                        f.relative_to(folder.parent)
                    )

        data = buf.getvalue()

        self.send_response(200)

        self.send_header(
            "Content-Type",
            "application/zip"
        )

        self.send_header(
            "Content-Disposition",
            f'attachment; filename="{folder.name}.zip"'
        )

        self.send_header(
            "Content-Length",
            str(len(data))
        )

        self.end_headers()

        self.wfile.write(data)

httpd = None

def start_server():

    global httpd

    try:

        httpd = http.server.HTTPServer(
            ("", PORT),
            GalleryHandler
        )

        print(f"Serving on {URL}")

        httpd.serve_forever()

    except Exception as e:

        print("HTTP server failed:", e)

server_thread = threading.Thread(
    target=start_server,
    daemon=True
)

server_thread.start()

# ─────────────────────────────────────────────────────────────
# GTK UI
# ─────────────────────────────────────────────────────────────

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

from gi.repository import (
    Gtk,
    Gdk,
    GdkPixbuf,
    GLib,
    Pango
)

import qrcode

def make_qr_pixbuf(url):

    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=8,
        border=3,
    )

    qr.add_data(url)
    qr.make(fit=True)

    img = qr.make_image(
        fill_color="#1a1a2e",
        back_color="#f0f4ff"
    )

    buf = io.BytesIO()

    img.save(buf, format="PNG")

    buf.seek(0)

    loader = GdkPixbuf.PixbufLoader.new_with_type("png")

    loader.write(buf.read())
    loader.close()

    return loader.get_pixbuf()

CSS = b"""
* { font-family: 'Ubuntu', sans-serif; }

window {
    background-color: #0f0f1a;
}

#card {
    background: linear-gradient(145deg, #1a1a2e, #16213e);
    border-radius: 20px;
    border: 1px solid rgba(99,202,255,0.15);
    box-shadow: 0 8px 40px rgba(0,0,0,0.6);
    padding: 28px;
    margin: 16px;
}

#title {
    color: #63caff;
    font-size: 22px;
    font-weight: 700;
}

#subtitle {
    color: rgba(255,255,255,0.45);
    font-size: 12px;
    margin-top: 2px;
}

#url_label {
    color: #a8f0c6;
    font-size: 13px;
    font-family: monospace;
    background: rgba(0,0,0,0.35);
    border-radius: 8px;
    padding: 8px 14px;
    margin-top: 8px;
}

#path_label {
    color: rgba(255,255,255,0.35);
    font-size: 11px;
    margin-top: 6px;
}

#qr_frame {
    background: #f0f4ff;
    border-radius: 14px;
    padding: 10px;
    margin-top: 14px;
    margin-bottom: 14px;
}

#stop_btn {
    background: linear-gradient(135deg, #e05c5c, #c0392b);
    color: white;
    font-weight: 700;
    border-radius: 10px;
    padding: 10px 24px;
}

#copy_btn {
    background: rgba(99,202,255,0.12);
    color: #63caff;
    border-radius: 10px;
    padding: 10px 20px;
}
"""

class ShareWindow(Gtk.Window):

    def __init__(self):

        super().__init__(title="LocalShare 📡")

        self.set_resizable(False)

        self.set_position(
            Gtk.WindowPosition.CENTER
        )

        self.connect("destroy", self.on_stop)

        provider = Gtk.CssProvider()

        provider.load_from_data(CSS)

        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        outer = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL
        )

        self.add(outer)

        card = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL
        )

        card.set_name("card")

        outer.pack_start(card, True, True, 0)

        title = Gtk.Label(label="LocalShare")

        title.set_name("title")
        title.set_halign(Gtk.Align.START)

        card.pack_start(title, False, False, 0)

        sub = Gtk.Label(
            label="Scan QR to access from any device on this network"
        )

        sub.set_name("subtitle")
        sub.set_halign(Gtk.Align.START)

        card.pack_start(sub, False, False, 0)

        url_lbl = Gtk.Label(label=URL)

        url_lbl.set_name("url_label")
        url_lbl.set_halign(Gtk.Align.START)
        url_lbl.set_selectable(True)

        card.pack_start(url_lbl, False, False, 0)

        path_lbl = Gtk.Label(
            label=f"📁 {serve_path}"
        )

        path_lbl.set_name("path_label")
        path_lbl.set_halign(Gtk.Align.START)

        path_lbl.set_ellipsize(
            Pango.EllipsizeMode.END
        )

        path_lbl.set_max_width_chars(48)

        card.pack_start(path_lbl, False, False, 0)

        try:

            pixbuf = make_qr_pixbuf(URL)

            qr_img = Gtk.Image.new_from_pixbuf(
                pixbuf
            )

        except Exception as e:

            qr_img = Gtk.Label(
                label=f"QR error:\n{e}"
            )

        qr_frame = Gtk.EventBox()

        qr_frame.set_name("qr_frame")

        qr_frame.add(qr_img)

        card.pack_start(
            qr_frame,
            False,
            False,
            0
        )

        btn_box = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=10
        )

        card.pack_start(btn_box, False, False, 0)

        copy_btn = Gtk.Button(
            label="⎘ Copy URL"
        )

        copy_btn.set_name("copy_btn")

        copy_btn.connect(
            "clicked",
            self.on_copy
        )

        btn_box.pack_start(
            copy_btn,
            True,
            True,
            0
        )

        stop_btn = Gtk.Button(
            label="⏹ Stop Sharing"
        )

        stop_btn.set_name("stop_btn")

        stop_btn.connect(
            "clicked",
            self.on_stop
        )

        btn_box.pack_start(
            stop_btn,
            True,
            True,
            0
        )

        self.show_all()

    def on_copy(self, _btn):

        clip = Gtk.Clipboard.get(
            Gdk.SELECTION_CLIPBOARD
        )

        clip.set_text(URL, -1)

    def on_stop(self, *_):

        if httpd:

            threading.Thread(
                target=httpd.shutdown,
                daemon=True
            ).start()

        if temp_dir:

            shutil.rmtree(
                temp_dir,
                ignore_errors=True
            )

        Gtk.main_quit()

def run():

    ShareWindow()

    Gtk.main()

GLib.idle_add(run)

Gtk.main()

PYTHON_SCRIPT

chmod +x "$SCRIPT_PATH"

echo ""
echo "✅ LocalShare installed!"
echo ""
echo "Right click any file or folder in Nautilus"
echo "→ Scripts → Share via HTTP 📡"
echo ""
echo "Scan QR code to share locally."