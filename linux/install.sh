#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  LocalShare – QR-powered HTTP file sharing for Nautilus
#  Run once to install: bash install_share_qr.sh
# ─────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$HOME/.local/share/nautilus/scripts"
SCRIPT_NAME="Share via HTTP 📡"
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"

# ── 1. Dependencies ──────────────────────────────────────────
echo "📦 Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 \
     gir1.2-gdk-3.0 python3-pip python3-pil --no-install-recommends -qq

pip3 install --quiet qrcode[pil] 2>/dev/null || \
  pip3 install --quiet --break-system-packages qrcode[pil]

# ── 2. Create scripts directory ──────────────────────────────
mkdir -p "$SCRIPT_DIR"

# ── 3. Write the share script ────────────────────────────────
cat > "$SCRIPT_PATH" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
LocalShare – Nautilus right-click file sharing with QR code
Env vars set by Nautilus:
  NAUTILUS_SCRIPT_SELECTED_FILE_PATHS  (newline-separated absolute paths)
  NAUTILUS_SCRIPT_CURRENT_URI
"""

import os, sys, socket, threading, signal, tempfile
import subprocess
import http.server, urllib.parse
from pathlib import Path

# ── Resolve selected path ────────────────────────────────────
selected_raw = os.environ.get("NAUTILUS_SCRIPT_SELECTED_FILE_PATHS", "").strip()
paths = [p for p in selected_raw.splitlines() if p]

# NEW
temp_dir = None  # track it so we can clean up on stop

if not paths:
    uri = os.environ.get("NAUTILUS_SCRIPT_CURRENT_URI", "")
    serve_path = Path(uri.replace("file://", "")).parent if uri else Path.home()
else:
    first = Path(paths[0])
    if first.is_dir():
        serve_path = first                          # folder selected → serve it directly
    else:
        temp_dir = tempfile.mkdtemp(prefix="localshare_")
        for p in paths:
            src = Path(p)
            if src.is_file():
                os.symlink(src, Path(temp_dir) / src.name)   # symlink, not copy
        serve_path = Path(temp_dir)

os.chdir(serve_path)

# ── Find local IP ────────────────────────────────────────────
def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

PORT = 8765
IP   = local_ip()
URL  = f"http://{IP}:{PORT}"

# ── HTTP server ──────────────────────────────────────────────
httpd = None

def start_server():
    global httpd
    handler = http.server.SimpleHTTPRequestHandler
    handler.log_message = lambda *a: None  # silence stdout logs
    httpd = http.server.HTTPServer(("", PORT), handler)
    httpd.serve_forever()

server_thread = threading.Thread(target=start_server, daemon=True)
server_thread.start()

# ── GTK UI ───────────────────────────────────────────────────
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
import qrcode, io

def make_qr_pixbuf(url: str) -> GdkPixbuf.Pixbuf:
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=8,
        border=3,
    )
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="#1a1a2e", back_color="#f0f4ff")
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
    letter-spacing: 1px;
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
    font-size: 13px;
    border: none;
    border-radius: 10px;
    padding: 10px 24px;
    letter-spacing: 0.5px;
}
#stop_btn:hover {
    background: linear-gradient(135deg, #ff6b6b, #e74c3c);
}

#copy_btn {
    background: rgba(99,202,255,0.12);
    color: #63caff;
    font-weight: 600;
    font-size: 13px;
    border: 1px solid rgba(99,202,255,0.3);
    border-radius: 10px;
    padding: 10px 20px;
}
#copy_btn:hover {
    background: rgba(99,202,255,0.22);
}
"""

class ShareWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="LocalShare 📡")
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", self.on_stop)

        # Apply CSS
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.set_name("card")
        outer.pack_start(card, True, True, 0)

        # Title row
        title = Gtk.Label(label="LocalShare")
        title.set_name("title")
        title.set_halign(Gtk.Align.START)
        card.pack_start(title, False, False, 0)

        sub = Gtk.Label(label="Scan QR to access from any device on this network")
        sub.set_name("subtitle")
        sub.set_halign(Gtk.Align.START)
        card.pack_start(sub, False, False, 0)

        # URL chip
        url_lbl = Gtk.Label(label=URL)
        url_lbl.set_name("url_label")
        url_lbl.set_halign(Gtk.Align.START)
        url_lbl.set_selectable(True)
        card.pack_start(url_lbl, False, False, 0)

        # Path
        path_lbl = Gtk.Label(label=f"📁  {serve_path}")
        path_lbl.set_name("path_label")
        path_lbl.set_halign(Gtk.Align.START)
        path_lbl.set_ellipsize(3)  # END
        path_lbl.set_max_width_chars(48)
        card.pack_start(path_lbl, False, False, 0)

        # QR Code image
        try:
            pixbuf = make_qr_pixbuf(URL)
            qr_img = Gtk.Image.new_from_pixbuf(pixbuf)
        except Exception as e:
            qr_img = Gtk.Label(label=f"QR error:\n{e}")

        qr_frame = Gtk.EventBox()
        qr_frame.set_name("qr_frame")
        qr_frame.add(qr_img)
        card.pack_start(qr_frame, False, False, 0)

        # Buttons row
        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        card.pack_start(btn_box, False, False, 0)

        copy_btn = Gtk.Button(label="⎘  Copy URL")
        copy_btn.set_name("copy_btn")
        copy_btn.connect("clicked", self.on_copy)
        btn_box.pack_start(copy_btn, True, True, 0)

        stop_btn = Gtk.Button(label="⏹  Stop Sharing")
        stop_btn.set_name("stop_btn")
        stop_btn.connect("clicked", self.on_stop)
        btn_box.pack_start(stop_btn, True, True, 0)

        self.show_all()

    def on_copy(self, _btn):
        clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clip.set_text(URL, -1)

	# NEW
	def on_stop(self, *_):
	    if httpd:
		threading.Thread(target=httpd.shutdown, daemon=True).start()
	    if temp_dir:
		import shutil
		shutil.rmtree(temp_dir, ignore_errors=True)
	    Gtk.main_quit()

def run():
    win = ShareWindow()
    Gtk.main()

GLib.idle_add(run)
Gtk.main()
PYTHON_SCRIPT

chmod +x "$SCRIPT_PATH"

# ── 4. Done ──────────────────────────────────────────────────
echo ""
echo "✅  LocalShare installed!"
echo ""
echo "   Right-click any folder in Nautilus (Files)"
echo "   → Scripts → 'Share via HTTP 📡'"
echo ""
echo "   A QR code popup will appear."
echo "   Scan it with your phone to browse the folder."
echo ""
echo "   💡 If you don't see 'Scripts' in the menu,"
echo "      run:  nautilus -q && nautilus"
echo ""