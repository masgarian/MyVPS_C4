#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# create-reality.sh
# Generate a fresh VLESS + REALITY + TCP configuration
# for a standalone Xray systemd service.
#
# IMPORTANT:
# - This script manages /usr/local/etc/xray/config.json
# - It does NOT modify the 3x-ui database.
# - It assumes the standalone Xray service is "xray".
# ============================================================

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_SERVICE="${XRAY_SERVICE:-xray}"
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.json}"
BACKUP_DIR="${CONFIG_DIR}/backups"

LISTEN_PORT="${LISTEN_PORT:-443}"

# A stable, publicly reachable TLS site is used only as the Reality destination.
# You can override it when running the script:
#   REALITY_DEST=www.cloudflare.com:443 bash create-reality.sh
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com:443}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"

# Client-facing values
FINGERPRINT="${FINGERPRINT:-chrome}"
NETWORK="${NETWORK:-tcp}"
FLOW="${FLOW:-xtls-rprx-vision}"

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------

die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

info() {
    echo "[INFO]  $*"
}

ok() {
    echo "[ OK ]  $*"
}

command -v jq >/dev/null 2>&1 || die "jq is required. Install it with: apt update && apt install -y jq"
command -v openssl >/dev/null 2>&1 || die "openssl is required."
command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."

[[ -x "$XRAY_BIN" ]] || die "Xray binary not found at: $XRAY_BIN"
[[ "$(id -u)" -eq 0 ]] || die "Run this script as root."

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
chmod 700 "$CONFIG_DIR" "$BACKUP_DIR"

# ----------------------------------------------------------------
# Detect public IPv4
# ----------------------------------------------------------------

SERVER_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"

if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi

[[ -n "$SERVER_IP" ]] || die "Could not determine server IPv4 address."

# ----------------------------------------------------------------
# Generate UUID
# ----------------------------------------------------------------

UUID="$("$XRAY_BIN" uuid 2>/dev/null || true)"

if [[ -z "$UUID" ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
fi

# ----------------------------------------------------------------
# Generate REALITY key pair
#
# Supported Xray versions normally provide:
#   xray x25519
# with output containing Private key / Public key.
# ----------------------------------------------------------------

KEY_OUTPUT="$("$XRAY_BIN" x25519 2>/dev/null || true)"

PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" \
    | awk -F': ' '/^PrivateKey:/ {print $2; exit}')"

PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" \
    | awk -F': ' '/^Password \(PublicKey\):/ {print $2; exit}')"

# Some Xray builds use different labels.
if [[ -z "$PRIVATE_KEY" ]]; then
    PRIVATE_KEY="$(printf '%s\n' "$KEY_OUTPUT" \
        | sed -nE 's/.*PrivateKey: *([^[:space:]]+).*/\1/p' \
        | head -n1)"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(printf '%s\n' "$KEY_OUTPUT" \
        | sed -nE 's/.*Password \(PublicKey\): *([^[:space:]]+).*/\1/p' \
        | head -n1)"
fi

[[ -n "$PRIVATE_KEY" ]] || die "Could not generate/read REALITY private key.
Xray output was:
$KEY_OUTPUT"

[[ -n "$PUBLIC_KEY" ]] || die "Could not generate/read REALITY public key.
Xray output was:
$KEY_OUTPUT"

# ----------------------------------------------------------------
# Generate 8-byte / 16-hex-character Short ID
# ----------------------------------------------------------------

SHORT_ID="$(openssl rand -hex 8)"

# ----------------------------------------------------------------
# Create a candidate configuration in a temporary file.
# ----------------------------------------------------------------

TMP_CONFIG="$(mktemp "${CONFIG_DIR}/config.json.tmp.XXXXXX")"
trap 'rm -f "$TMP_CONFIG"' EXIT

cat > "$TMP_CONFIG" <<JSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "${FLOW}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "${NETWORK}",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${REALITY_SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
JSON

chmod 600 "$TMP_CONFIG"

# ----------------------------------------------------------------
# Validate candidate before touching active configuration.
# ----------------------------------------------------------------

info "Testing new Xray configuration..."

TEST_OUTPUT="$("$XRAY_BIN" run -test -config "$TMP_CONFIG" 2>&1)" || {
    echo "$TEST_OUTPUT"
    die "New configuration failed Xray validation. Existing configuration was NOT changed."
}

ok "Xray configuration test passed."

# ----------------------------------------------------------------
# Make backup of current config.
# ----------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

if [[ -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "${BACKUP_DIR}/config-${TIMESTAMP}.json"
    ok "Previous configuration backed up."
fi

# ----------------------------------------------------------------
# Install new configuration atomically.
# ----------------------------------------------------------------

mv -f "$TMP_CONFIG" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

trap - EXIT

# ----------------------------------------------------------------
# Restart Xray and verify service.
# ----------------------------------------------------------------

info "Restarting Xray service..."
systemctl restart "$XRAY_SERVICE"

sleep 2

if ! systemctl is-active --quiet "$XRAY_SERVICE"; then
    echo
    echo "Xray did not remain active."
    echo
    systemctl --no-pager --full status "$XRAY_SERVICE" || true
    echo
    echo "Rolling back to previous configuration..."

    LATEST_BACKUP="$(ls -1t "${BACKUP_DIR}"/config-*.json 2>/dev/null | head -n1 || true)"

    if [[ -n "$LATEST_BACKUP" ]]; then
        cp -a "$LATEST_BACKUP" "$CONFIG_FILE"
        systemctl restart "$XRAY_SERVICE" || true
        ok "Rollback attempted."
    fi

    die "Xray restart failed."
fi

ok "Xray service is running."

# ----------------------------------------------------------------
# Verify port 443 is actually listening.
# ----------------------------------------------------------------

if command -v ss >/dev/null 2>&1; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)'"${LISTEN_PORT}"'$'; then
        ok "TCP port ${LISTEN_PORT} is listening."
    else
        echo "[WARN] Xray is running, but port ${LISTEN_PORT} was not detected by ss."
    fi
fi

# ----------------------------------------------------------------
# UFW: allow TCP 443 if UFW exists and is active.
# ----------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS="$(ufw status 2>/dev/null || true)"

    if printf '%s\n' "$UFW_STATUS" | grep -q '^Status: active'; then
        if ! printf '%s\n' "$UFW_STATUS" | grep -Eq "^${LISTEN_PORT}/tcp[[:space:]]"; then
            info "Opening TCP ${LISTEN_PORT} in UFW..."
            ufw allow "${LISTEN_PORT}/tcp" >/dev/null
            ok "UFW rule added for TCP ${LISTEN_PORT}."
        else
            ok "UFW already allows TCP ${LISTEN_PORT}."
        fi
    fi
fi

# ----------------------------------------------------------------
# Build VLESS URI.
# ----------------------------------------------------------------

VLESS_URI="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${REALITY_SERVER_NAME}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=${NETWORK}#Reality-${TIMESTAMP}"

# Save machine-readable information for later use.
INFO_FILE="${CONFIG_DIR}/last-reality.txt"

cat > "$INFO_FILE" <<EOF
Created: ${TIMESTAMP}
Server IP: ${SERVER_IP}
Port: ${LISTEN_PORT}
Protocol: VLESS
Network: ${NETWORK}
Security: REALITY
SNI: ${REALITY_SERVER_NAME}
Destination: ${REALITY_DEST}
Fingerprint: ${FINGERPRINT}
UUID: ${UUID}
Private Key: ${PRIVATE_KEY}
Public Key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}

VLESS URI:
${VLESS_URI}
EOF

chmod 600 "$INFO_FILE"

# ----------------------------------------------------------------
# Final output
# ----------------------------------------------------------------

echo
echo "============================================================"
echo " NEW VLESS + REALITY CONFIGURATION"
echo "============================================================"
echo
echo "Server IP     : ${SERVER_IP}"
echo "Port          : ${LISTEN_PORT}"
echo "Protocol      : VLESS"
echo "Security      : REALITY"
echo "Network       : ${NETWORK}"
echo "Flow          : ${FLOW}"
echo "SNI           : ${REALITY_SERVER_NAME}"
echo "Destination   : ${REALITY_DEST}"
echo "Fingerprint   : ${FINGERPRINT}"
echo "UUID          : ${UUID}"
echo "Public Key    : ${PUBLIC_KEY}"
echo "Short ID      : ${SHORT_ID}"
echo
echo "VLESS URI:"
echo
echo "${VLESS_URI}"
echo
echo "Saved to:"
echo "${INFO_FILE}"
echo
echo "Backup directory:"
echo "${BACKUP_DIR}"
echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo "Import the VLESS URI into V2RayNG and test it."
echo "The private key is server-side only; never put it in V2RayNG."
echo "============================================================"
