#!/usr/bin/env bash
# Hack & Shield — Service 6 deployment (LFI + admin-key lab)
#
# Expected repository layout:
#   script/service/06_service.sh
#   service6/app.py, requirements.txt, templates/, static/
#   service6/challenge_fs/           # created if absent; .env lives here
#   systemd/hackshield-service6.service
#
# This script:
#   - deploys the Flask app to /opt/hackshield/services/service6
#   - generates a protected flag file in /opt/flags/flag6
#   - stores the admin API key in challenge_fs/.env
#   - patches app.py so the flag is read from the protected file
#   - installs and starts the systemd unit

set -Eeuo pipefail
umask 027

log_info()    { printf '[INFO] %s\n' "$*"; }
log_success() { printf '[SUCCESS] %s\n' "$*"; }
log_warn()    { printf '[WARN] %s\n' "$*" >&2; }
log_error()   { printf '[ERROR] %s\n' "$*" >&2; }

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

SERVICE_ID="${SERVICE_ID:-6}"
SERVICE_USER="${SERVICE_USER:-user${SERVICE_ID}}"
SERVICE_GROUP="${SERVICE_GROUP:-hs-service-editors}"
SERVICE_NAME="${SERVICE_NAME:-hackshield-service${SERVICE_ID}.service}"

SOURCE_DIR="${SOURCE_DIR:-$REPO_DIR/service${SERVICE_ID}}"
UNIT_SOURCE="${UNIT_SOURCE:-$REPO_DIR/systemd/hackshield-service${SERVICE_ID}.service}"

DEST_DIR="${DEST_DIR:-/opt/hackshield/services/service${SERVICE_ID}}"
VENV_DIR="$DEST_DIR/.venv"
APP_FILE="$DEST_DIR/app.py"
CHALLENGE_FS="$DEST_DIR/challenge_fs"
CONFIG_FILE="$CHALLENGE_FS/.env"

FLAG_DIR="/opt/flags"
FLAG_FILE="$FLAG_DIR/flag${SERVICE_ID}"

PORT="${SERVICE_PORT:-5000}"
BACKUP_ROOT="/opt/hackshield/backups/service${SERVICE_ID}"

if [[ "$EUID" -ne 0 ]]; then
    exec sudo --preserve-env=SERVICE_ID,SERVICE_USER,SERVICE_GROUP,SERVICE_NAME,SERVICE_PORT,SERVICE_FLAG,SERVICE_ADMIN_API_KEY bash "$SCRIPT_PATH" "$@"
fi

# --------------------------------------------------
# 1) Validate repository and VM prerequisites
# --------------------------------------------------
[[ -d "$SOURCE_DIR" ]] || { log_error "Missing service source directory: $SOURCE_DIR"; exit 1; }
[[ -f "$SOURCE_DIR/app.py" ]] || { log_error "Missing $SOURCE_DIR/app.py"; exit 1; }
[[ -f "$SOURCE_DIR/requirements.txt" ]] || { log_error "Missing $SOURCE_DIR/requirements.txt"; exit 1; }
[[ -d "$SOURCE_DIR/templates" ]] || { log_error "Missing templates directory: $SOURCE_DIR/templates"; exit 1; }
[[ -d "$SOURCE_DIR/static" ]] || { log_error "Missing static directory: $SOURCE_DIR/static"; exit 1; }
[[ -f "$UNIT_SOURCE" ]] || { log_error "Missing systemd unit: $UNIT_SOURCE"; exit 1; }

getent passwd "$SERVICE_USER" >/dev/null || {
    log_error "$SERVICE_USER does not exist. Run the VM setup first."
    exit 1
}
getent group "$SERVICE_GROUP" >/dev/null || {
    log_error "$SERVICE_GROUP does not exist. Run the VM setup first."
    exit 1
}

# --------------------------------------------------
# 2) Install dependencies
# --------------------------------------------------
log_info "Installing Python, venv, ACL and curl..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 \
    python3-venv \
    python3-pip \
    acl \
    curl

# --------------------------------------------------
# 3) Back up any existing deployment
# --------------------------------------------------
if [[ -d "$DEST_DIR" ]]; then
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    install -d -o root -g root -m 0700 "$BACKUP_ROOT" "$BACKUP_DIR"
    cp -a "$DEST_DIR/." "$BACKUP_DIR/"
    log_success "Existing deployment backed up to $BACKUP_DIR"
fi

# --------------------------------------------------
# 4) Stop service before replacing files
# --------------------------------------------------
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

# --------------------------------------------------
# 5) Deploy application files
# --------------------------------------------------
log_info "Deploying application to $DEST_DIR..."
install -d -o root -g "$SERVICE_GROUP" -m 2775 "$DEST_DIR"

tar --exclude='./.venv' -C "$SOURCE_DIR" -cf - . | tar -C "$DEST_DIR" -xf -

chown -R root:"$SERVICE_GROUP" "$DEST_DIR"
find "$DEST_DIR" -type d -exec chmod 2775 {} +
find "$DEST_DIR" -type f -exec chmod 0664 {} +

usermod -a -G "$SERVICE_GROUP" "$SERVICE_USER"

# --------------------------------------------------
# 6) Create challenge config
# --------------------------------------------------
install -d -o root -g "$SERVICE_USER" -m 0750 "$CHALLENGE_FS"

if [[ ! -f "$CONFIG_FILE" ]]; then
    ADMIN_API_KEY="${SERVICE_ADMIN_API_KEY:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')}"
    (
        umask 077
        printf 'ADMIN_API_KEY=%s\n' "$ADMIN_API_KEY" > "$CONFIG_FILE"
    )
fi

chown root:"$SERVICE_USER" "$CONFIG_FILE"
chmod 0640 "$CONFIG_FILE"

# --------------------------------------------------
# 7) Protected flag
# --------------------------------------------------
install -d -o root -g root -m 0711 "$FLAG_DIR"
setfacl -m u:"$SERVICE_USER":--x "$FLAG_DIR"

if [[ ! -f "$FLAG_FILE" ]]; then
    FLAG_VALUE="${SERVICE_FLAG:-HS{service${SERVICE_ID}_$(python3 -c 'import secrets; print(secrets.token_hex(16))')}}"
    printf '%s\n' "$FLAG_VALUE" > "$FLAG_FILE"
fi

chown "$SERVICE_USER":"$SERVICE_USER" "$FLAG_FILE"
chmod 0400 "$FLAG_FILE"

# --------------------------------------------------
# 8) Patch app.py
# --------------------------------------------------
python3 - "$APP_FILE" "$FLAG_FILE" <<'PY'
from pathlib import Path
import sys

app_path = Path(sys.argv[1])
flag_path = sys.argv[2]

source = app_path.read_text()

source = source.replace(
    'FLAG = "HNS{lfi_to_admin_key_demo}"',
    f'''FLAG_FILE = Path("{flag_path}")
FLAG = FLAG_FILE.read_text(encoding="utf-8").strip() if FLAG_FILE.exists() else "HNS{{missing_flag}}"'''
)

app_path.write_text(source)
PY

# --------------------------------------------------
# 9) Virtual environment
# --------------------------------------------------
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$VENV_DIR"
    runuser -u "$SERVICE_USER" -- python3 -m venv "$VENV_DIR"
fi

chown -R "$SERVICE_USER":"$SERVICE_USER" "$VENV_DIR"

runuser -u "$SERVICE_USER" -- "$VENV_DIR/bin/python" -m pip install --upgrade pip
runuser -u "$SERVICE_USER" -- "$VENV_DIR/bin/python" -m pip install -r "$DEST_DIR/requirements.txt"

# --------------------------------------------------
# 10) Install systemd unit
# --------------------------------------------------
install -o root -g root -m 0644 \
    "$UNIT_SOURCE" \
    "/etc/systemd/system/$SERVICE_NAME"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# --------------------------------------------------
# 11) Verification
# --------------------------------------------------
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager
    exit 1
fi

curl --fail --silent \
    "http://127.0.0.1:${PORT}/api/status" >/dev/null

log_success "Deployment completed."

echo
echo "URL:       http://127.0.0.1:${PORT}/"
echo "Config:    $CONFIG_FILE"
echo "Flag:      $FLAG_FILE"
echo "Service:   $SERVICE_NAME"

systemctl --no-pager --full status "$SERVICE_NAME"
