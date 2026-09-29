#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# Xray VPS Bootstrap - Ubuntu 24.04
# VLESS + REALITY / xtls-rprx-vision / raw
#
# Run as root:
#   sudo bash install.sh
#
# IMPORTANT:
# - The script asks for the admin SSH public key.
# - It disables root/password SSH by default at the end.
# - Keep an existing SSH session open until final verification.
# ============================================================

readonly SCRIPT_VERSION="1.0.0"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly SSH_PORT_DEFAULT="9011"
readonly XRAY_PORT_DEFAULT="443"
readonly ADMIN_USER_DEFAULT="admin"
readonly REALITY_DEST_DEFAULT="www.cloudflare.com:443"
readonly REALITY_SERVER_NAME_DEFAULT="www.cloudflare.com"
readonly LOG_DIR="/var/log/xray-vps-setup"
readonly STATE_DIR="/var/lib/xray-vps-setup"
readonly OUTPUT_FILE="/root/xray-client.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'

log()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

on_error() {
    local code=$?
    echo -e "${RED}[ERROR]${RESET} Installation failed at line ${BASH_LINENO[0]} (exit ${code})."
    echo "Check: ${LOG_DIR}/install.log"
    exit "$code"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo bash install.sh)."

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec > >(tee -a "$LOG_DIR/install.log") 2>&1

log "Xray VPS Bootstrap ${SCRIPT_VERSION}"

# ---------- OS checks ----------
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu is required."
[[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 LTS is required. Detected: ${VERSION_ID:-unknown}"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "amd64 is required."

# ---------- Input ----------
read -r -p "SSH port [${SSH_PORT_DEFAULT}]: " SSH_PORT
SSH_PORT="${SSH_PORT:-$SSH_PORT_DEFAULT}"

read -r -p "Admin username [${ADMIN_USER_DEFAULT}]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-$ADMIN_USER_DEFAULT}"

read -r -p "Xray port [${XRAY_PORT_DEFAULT}]: " XRAY_PORT
XRAY_PORT="${XRAY_PORT:-$XRAY_PORT_DEFAULT}"

read -r -p "REALITY destination [${REALITY_DEST_DEFAULT}]: " REALITY_DEST
REALITY_DEST="${REALITY_DEST:-$REALITY_DEST_DEFAULT}"

read -r -p "REALITY serverName/SNI [${REALITY_SERVER_NAME_DEFAULT}]: " REALITY_SERVER_NAME
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-$REALITY_SERVER_NAME_DEFAULT}"

echo
echo "Paste the PUBLIC SSH key for ${ADMIN_USER}."
echo "Example: ssh-ed25519 AAAA... laptop-name"
read -r -p "SSH public key: " ADMIN_PUBKEY
[[ "$ADMIN_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\ [A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
    || die "The SSH public key format was not recognized."

read -r -p "Disable root SSH login and password authentication at the end? [Y/n]: " HARDEN_SSH
HARDEN_SSH="${HARDEN_SSH:-Y}"

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be numeric."
    (( 1 <= 10#$1 && 10#$1 <= 65535 )) || die "$2 must be 1..65535."
}
validate_port "$SSH_PORT" "SSH port"
validate_port "$XRAY_PORT" "Xray port"
[[ "$SSH_PORT" != "$XRAY_PORT" ]] || die "SSH and Xray ports must differ."

cat <<EOF

============================================================
Configuration
============================================================
OS                  : Ubuntu 24.04
Admin user          : ${ADMIN_USER}
SSH port            : ${SSH_PORT}
Xray port           : ${XRAY_PORT}
REALITY destination : ${REALITY_DEST}
REALITY SNI         : ${REALITY_SERVER_NAME}
Fail2ban            : enabled
UFW                 : enabled
Root SSH hardening  : ${HARDEN_SSH}
============================================================
EOF

read -r -p "Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Cancelled."; exit 0; }

# ---------- Packages ----------
log "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get full-upgrade -y
apt-get install -y \
    curl ca-certificates unzip openssl uuid-runtime \
    ufw fail2ban chrony jq

ok "Base packages installed."

# ---------- Time ----------
timedatectl set-timezone UTC || true
systemctl enable --now chrony
ok "Timezone set to UTC and time synchronization enabled."

# ---------- Admin user ----------
if id "$ADMIN_USER" >/dev/null 2>&1; then
    ok "User ${ADMIN_USER} already exists."
else
    adduser --disabled-password --gecos "" "$ADMIN_USER"
    ok "Created user ${ADMIN_USER}."
fi

usermod -aG sudo "$ADMIN_USER"

echo
read -r -s -p "Set a password for ${ADMIN_USER} (used for sudo; SSH password login will be disabled): " ADMIN_PASSWORD
echo
[[ -n "$ADMIN_PASSWORD" ]] || die "Admin password cannot be empty."
printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
unset ADMIN_PASSWORD

install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
printf '%s\n' "$ADMIN_PUBKEY" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "/home/${ADMIN_USER}/.ssh/authorized_keys"
chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"

ok "Admin SSH key and sudo access prepared."

# ---------- SSH ----------
mkdir -p /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/99-vps-hardening.conf <<EOF
Port ${SSH_PORT}
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Password/root SSH hardening is applied only after the user confirms
# that the new admin SSH key works from a second terminal.
if [[ "$HARDEN_SSH" =~ ^[Yy]$ ]]; then
    warn "Before continuing, open a SECOND terminal and test:"
    echo "  ssh -p ${SSH_PORT} ${ADMIN_USER}@<SERVER_IP>"
    echo "Then test:"
    echo "  sudo whoami"
    echo
    read -r -p "Did the new SSH key login AND sudo test succeed? [y/N]: " SSH_TEST_OK
    if [[ "$SSH_TEST_OK" =~ ^[Yy]$ ]]; then
        cat >>/etc/ssh/sshd_config.d/99-vps-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
        log "Root SSH and SSH password authentication will be disabled."
    else
        warn "SSH hardening was NOT applied. You can harden SSH later."
    fi
else
    cat >>/etc/ssh/sshd_config.d/99-vps-hardening.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
fi

sshd -t
systemctl enable ssh
systemctl restart ssh
ok "SSH configured on port ${SSH_PORT}."

# ---------- Firewall ----------
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment "SSH"
ufw allow "${XRAY_PORT}/tcp" comment "Xray"
ufw --force enable
ok "UFW enabled: SSH ${SSH_PORT}/tcp, Xray ${XRAY_PORT}/tcp."

# ---------- Fail2ban ----------
cat >/etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
banaction = nftables-multiport
maxretry = 5
findtime = 10m
bantime = 10m
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
ok "Fail2ban enabled for SSH."

# ---------- Xray ----------
log "Installing/updating Xray using the official XTLS installer..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

command -v xray >/dev/null || die "Xray binary was not installed."
ok "Xray installed: $(xray version | head -n 1)"

# ---------- Generate identity ----------
UUID="$(xray uuid)"
SHORT_ID="$(openssl rand -hex 8)"

X25519_OUTPUT="$(xray x25519)"
PRIVATE_KEY="$(awk '/^PrivateKey:/ {print $2; exit}' <<<"$X25519_OUTPUT")"
PUBLIC_KEY="$(awk '/PublicKey/ {print $NF; exit}' <<<"$X25519_OUTPUT")"

[[ -n "$UUID" && -n "$SHORT_ID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] \
    || die "Failed to generate Xray UUID/REALITY keys."

# ---------- Public IP ----------
PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
[[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="YOUR_SERVER_IP"

# ---------- Xray config ----------
install -d -m 755 /usr/local/etc/xray

cat >"$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
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
EOF

chmod 600 "$XRAY_CONFIG"

# ---------- Validate and start ----------
log "Validating Xray configuration..."
xray run -test -config "$XRAY_CONFIG"
ok "Xray configuration is valid."

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

systemctl is-active --quiet xray || {
    journalctl -u xray --no-pager -n 80
    die "Xray failed to start."
}

ss -lntup | grep -Eq ":${XRAY_PORT}\b" || die "Xray is not listening on port ${XRAY_PORT}."
ok "Xray is running and listening on ${XRAY_PORT}."

# ---------- Save client information ----------
CLIENT_LINK="vless://${UUID}@${PUBLIC_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F&type=tcp#My-VPS"

umask 077
cat >"$OUTPUT_FILE" <<EOF
Xray VLESS + REALITY
====================

Server IP : ${PUBLIC_IP}
Port      : ${XRAY_PORT}
UUID      : ${UUID}
Flow      : xtls-rprx-vision
Security  : reality
SNI       : ${REALITY_SERVER_NAME}
Fingerprint: chrome
Public Key: ${PUBLIC_KEY}
Short ID  : ${SHORT_ID}
Network   : raw

VLESS URI:
${CLIENT_LINK}
EOF

chmod 600 "$OUTPUT_FILE"

# ---------- Final verification ----------
echo
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo
ok "Admin user : ${ADMIN_USER}"
ok "SSH port   : ${SSH_PORT}"
ok "Xray port  : ${XRAY_PORT}"
ok "UFW        : active"
ok "Fail2ban   : active"
ok "Xray       : active"
echo
echo "Client configuration saved to:"
echo "  ${OUTPUT_FILE}"
echo
echo "VLESS URI:"
echo "${CLIENT_LINK}"
echo
echo "IMPORTANT:"
echo "1. Test a NEW SSH connection using ${ADMIN_USER} before closing this session."
echo "2. Test the VLESS profile in v2rayNG."
echo "3. Never publish ${XRAY_CONFIG}, ${OUTPUT_FILE}, or the REALITY private key."
echo "4. Keep the SSH public key in your password manager/repository if desired,"
echo "   but never commit private keys or client secrets."
echo
echo "Official Xray installer source:"
echo "https://github.com/XTLS/Xray-install"
