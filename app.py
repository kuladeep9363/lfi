
from pathlib import Path
import secrets

from flask import Flask, jsonify, request, render_template, send_file

# --------------------------------------------------
# Paths and application setup
# --------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent
CHALLENGE_ROOT = (BASE_DIR / "challenge_fs").resolve()
PUBLIC_DIR = (CHALLENGE_ROOT / "public").resolve()
CONFIG_FILE = CHALLENGE_ROOT / ".env"

app = Flask(__name__)


# --------------------------------------------------
# Load simulated challenge configuration
# --------------------------------------------------

def load_config():
    config = {}

    if CONFIG_FILE.exists():
        for line in CONFIG_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()

            if not line or line.startswith("#") or "=" not in line:
                continue

            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()

    return config


CONFIG = load_config()
ADMIN_API_KEY = CONFIG.get("ADMIN_API_KEY", "")
FLAG = "HNS{lfi_to_admin_key_demo}"


# --------------------------------------------------
# Main portal
# --------------------------------------------------

@app.get("/")
def home():
    return render_template("index.html")


# --------------------------------------------------
# Public API endpoints
# --------------------------------------------------

@app.get("/api/status")
def status():
    return jsonify({
        "service": "Internal File API",
        "version": "1.3.0",
        "status": "online"
    })


@app.get("/api/help")
def help_api():
    return jsonify({
        "available_endpoints": {
            "status": "/api/status",
            "help": "/api/help",
            "download": "/api/download",
            "file_viewer": "/api/files?path=<file_path>",
            "admin_portal": "/api/admin/"
        },
        "file_viewer_description":
            "View the contents of a requested document."
    })



# --------------------------------------------------
# Secure download endpoint
# --------------------------------------------------

@app.get("/api/download")
def download():
    filename = request.args.get("file", "")

    if not filename or Path(filename).name != filename:
        return jsonify({"error": "Invalid filename"}), 400

    candidate = (PUBLIC_DIR / filename).resolve()

    if not candidate.is_relative_to(PUBLIC_DIR):
        return jsonify({"error": "Invalid path"}), 400

    if not candidate.is_file():
        return jsonify({"error": "File not found"}), 404

    return send_file(
        candidate,
        as_attachment=True,
        download_name=candidate.name
    )


# --------------------------------------------------
# Intentionally vulnerable LFI endpoint for the CTF
# --------------------------------------------------


@app.get("/api/files")
def view_file():
    filename = request.args.get("path", "")

    if not filename:
        return jsonify({
            "error": "Missing path parameter",
            "hint": "Specify a file path in the query string."
        }), 400

    try:
        candidate = (PUBLIC_DIR / filename).resolve()

        if not candidate.is_file():
            return jsonify({"error": "File not found"}), 404

        content = candidate.read_text(
            encoding="utf-8",
            errors="replace"
        )

        return jsonify({
            "path": filename,
            "content": content
        })

    except (OSError, ValueError):
        return jsonify({"error": "Unable to read file"}), 400



# --------------------------------------------------
# Admin portal: form submission and flag display
# --------------------------------------------------

@app.route("/api/admin/", methods=["GET", "POST"])
def admin_portal():
    message = ""
    flag = None

    if request.method == "POST":
        api_key = request.form.get("api_key", "")

        if (
            ADMIN_API_KEY
            and secrets.compare_digest(api_key, ADMIN_API_KEY)
        ):
            message = "Authentication successful."
            flag = FLAG
        else:
            message = "Invalid API key. Access denied."

    return render_template(
        "admin.html",
        message=message,
        flag=flag
    )


# --------------------------------------------------
# Original API-based admin authentication endpoints
# These remain available but are not used by admin.html.
# --------------------------------------------------

@app.post("/api/admin/login")
def admin_login():
    data = request.get_json(silent=True) or {}
    api_key = data.get("api_key", "")

    if (
        not isinstance(api_key, str)
        or not ADMIN_API_KEY
        or not secrets.compare_digest(api_key, ADMIN_API_KEY)
    ):
        return jsonify({"error": "Invalid API key"}), 401

    return jsonify({
        "message": "Administrator authenticated"
    })


@app.get("/api/admin/flag")
def admin_flag():
    # The new form portal displays the flag directly.
    # This original endpoint is not used by that portal.
    return jsonify({"error": "Use the admin portal"}), 403


# --------------------------------------------------
# Error handling
# --------------------------------------------------

@app.errorhandler(404)
def not_found(_error):
    return jsonify({"error": "Endpoint not found"}), 404


# --------------------------------------------------
# Run locally
# --------------------------------------------------

if __name__ == "__main__":
    app.run(
        host="127.0.0.1",
        port=5000,
        debug=False
    )
