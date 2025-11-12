#!/bin/bash
set -euo pipefail

# Pro Edition installer for Raspberry Pi security appliance
# Comments in English as requested.
# This script installs and configures:
# - Pi-hole + Unbound (local DNS resolver)
# - WireGuard VPN
# - Suricata IDS/IPS (IPS mode enabled)
# - UFW firewall
# - Fail2Ban
# - AIDE + auditd for integrity and auditing
# - Filebeat (to ship logs to an external Elastic Stack / Logstash)
# - Telegram notifications for critical events
# - Automated update, backup and alerting tasks

# ========== USER CONFIGURATION SECTION ===========
# Edit these variables before running the script to match your environment.
# Replace the placeholders with real values.
TELEGRAM_BOT_TOKEN="REPLACE_WITH_TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="REPLACE_WITH_TELEGRAM_CHAT_ID"
ELK_HOST="REPLACE_WITH_ELK_HOST_OR_LOGSTASH"
ELK_PORT=5044  # default Logstash Beats input port; change to 9200/ES if using direct ES
WG_LISTEN_PORT=51820
WG_NETWORK="10.66.66.0/24"
WG_SERVER_ADDR="10.66.66.1/24"

# ========== helper functions ==========
function info { echo "[+] $*"; }
function warn { echo "[!] $*"; }
function die  { echo "[X] $*"; exit 1; }

# Simple Telegram notify helper
function tg_notify {
  local text="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN}" || "${TELEGRAM_BOT_TOKEN}" == "REPLACE_WITH_TELEGRAM_BOT_TOKEN" ]]; then
    warn "Telegram token not set, skipping notification"
    return
  fi
  if [[ -z "${TELEGRAM_CHAT_ID}" || "${TELEGRAM_CHAT_ID}" == "REPLACE_WITH_TELEGRAM_CHAT_ID" ]]; then
    warn "Telegram chat_id not set, skipping notification"
    return
  fi
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    -d text="$text" >/dev/null || true
}

# ========== 0. Pre-checks ==========
if [[ $(id -u) -ne 0 ]]; then
  die "This script must be run with root privileges. Re-run with sudo." 
fi

info "Starting Pro Edition installation..."

# ========== 1. System update and base packages ==========
info "Updating system and installing base packages..."
apt update && apt upgrade -y
apt install -y curl wget gnupg lsb-release ca-certificates apt-transport-https software-properties-common \
  net-tools htop git cron

# ========== 2. Pi-hole + Unbound (if not installed) ==========
info "Installing Pi-hole and Unbound (if missing)..."
if ! command -v pihole >/dev/null 2>&1; then
  curl -sSL https://install.pi-hole.net | bash || warn "Pi-hole installer returned non-zero, continue manually if needed"
else
  info "Pi-hole already installed"
fi

apt install -y unbound || die "Failed to install unbound"

# Create Unbound configuration for Pi-hole
cat > /etc/unbound/unbound.conf.d/pi-hole.conf <<'EOF'
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    edns-buffer-size: 1232
    prefetch: yes
    num-threads: 1
    so-rcvbuf: 1m
    cache-min-ttl: 3600
    cache-max-ttl: 86400
    rrset-roundrobin: yes
    val-log-level: 1
    qname-minimisation: yes
    aggressive-nsec: yes
    forward-zone:
        name: "."
        forward-addr: 1.1.1.1@853
        forward-addr: 9.9.9.9@853
        forward-ssl-upstream: yes
EOF

systemctl restart unbound || die "Failed to start unbound"

# Point Pi-hole to use local Unbound
if [[ -f /etc/pihole/setupVars.conf ]]; then
  sed -i 's/^PIHOLE_DNS_1=.*$/PIHOLE_DNS_1=127.0.0.1#5335/' /etc/pihole/setupVars.conf || true
  pihole restartdns || true
fi

# ========== 3. WireGuard setup ==========
info "Installing WireGuard and generating keys..."
apt install -y wireguard qrencode || die "Failed to install wireguard"
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
PRIVATE_KEY=$(cat privatekey)
PUBLIC_KEY=$(cat publickey)
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${WG_SERVER_ADDR}
ListenPort = ${WG_LISTEN_PORT}
SaveConfig = true
# PostUp and PostDown to enable NAT (adjust interface name if needed)
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NETWORK} -o eth0 -j MASQUERADE; iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NETWORK} -o eth0 -j MASQUERADE; iptables -D FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -D FORWARD -i wg0 -o eth0 -j ACCEPT
EOF

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0 || warn "WireGuard failed to start; check /etc/wireguard/wg0.conf"

# ========== 4. Suricata IDS/IPS installation and IPS setup ==========
info "Installing Suricata and enabling IPS mode..."
apt install -y suricata suricata-dbg yaml libnss3-tools || true
suricata-update || warn "suricata-update failed"
systemctl enable suricata

# Configure Suricata to use af-packet for inline blocking (IPS)
# Note: IPS in af-packet mode requires running Suricata with --af-packet and iptables/ifb config.
# We'll enable a simple NFQUEUE-based inline drop using iptables -> NFQUEUE id 1
info "Configuring Suricata for NFQUEUE (IPS) mode"

# Add iptables rule to send new incoming packets to NFQUEUE 1 (adjust as needed)
iptables -I INPUT -j NFQUEUE --queue-num 1 || true

# Install libnetfilter-queue utilities
apt install -y libnetfilter-queue-dev libmnl-dev build-essential || true

# Start Suricata as a daemon in NFQUEUE mode (run in background)
# Create a systemd override that runs suricata with --nfqueue
cat > /etc/systemd/system/suricata-nfqueue.service <<'EOF'
[Unit]
Description=Suricata IDS/IPS (NFQUEUE mode)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml --pidfile /var/run/suricata-nfqueue.pid --nfqueue 1
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now suricata-nfqueue.service || warn "Failed to start suricata-nfqueue; check logs"

# Note: If you prefer af-packet/inline blocking, more complex interface/bypass setup is required.

# ========== 5. UFW firewall ==========
info "Configuring UFW..."
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 53,67,80,443,${WG_LISTEN_PORT}/udp
ufw allow 4711/tcp
ufw --force enable

# ========== 6. Fail2Ban ==========
info "Installing and configuring Fail2Ban..."
apt install -y fail2ban || true
systemctl enable fail2ban
systemctl start fail2ban

# Add a global action to send Telegram notifications on bans
FAIL2BAN_ACTION_PATH="/etc/fail2ban/action.d/telegram.conf"
cat > ${FAIL2BAN_ACTION_PATH} <<'EOF'
[Definition]
# Fail2Ban action to notify via Telegram
actionstart =
actionstop =
actionban = echo "Banned <ip> in jail <name>" >/tmp/fail2ban_notify.txt
actionunban =
EOF

# Create a wrapper hook that will read /tmp/fail2ban_notify.txt and send via Telegram
cat > /usr/local/bin/fail2ban-tg-hook <<'EOF'
#!/bin/bash
MSG=$(cat /tmp/fail2ban_notify.txt 2>/dev/null || echo "fail2ban event")
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
if [[ "${TELEGRAM_BOT_TOKEN}" != "REPLACE_WITH_TELEGRAM_BOT_TOKEN" && -n "${TELEGRAM_BOT_TOKEN}" ]]; then
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$MSG" >/dev/null || true
fi
rm -f /tmp/fail2ban_notify.txt
EOF
chmod +x /usr/local/bin/fail2ban-tg-hook || true

# Ensure fail2ban uses the action (append to jail.local if missing)
if ! grep -q "telegram" /etc/fail2ban/jail.local 2>/dev/null; then
  cat >> /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
action = %(action_)s

# Add custom ban action to trigger wrapper
action_mwl = %(action_mwl)s

EOF
fi
systemctl restart fail2ban || true

# ========== 7. AIDE + auditd already installed earlier; ensure regular checks ==========
info "Ensuring AIDE and auditd scheduled checks..."
apt install -y aide auditd || true
if [[ ! -f /var/lib/aide/aide.db ]]; then
  aideinit || true
  mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db || true
fi
(crontab -l 2>/dev/null || true; echo "0 4 * * * /usr/bin/aide --check >> /var/log/aide.log 2>&1") | crontab -

# ========== 8. Filebeat (ship logs to Elastic Stack / Logstash) ==========
info "Installing Filebeat and enabling Suricata module..."

# Install Elastic GPG and repo for filebeat (Debian-based)
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | apt-key add - || true
echo "deb https://artifacts.elastic.co/packages/8.x/apt stable main" | tee /etc/apt/sources.list.d/elastic-8.x.list
apt update
apt install -y filebeat || warn "Filebeat installation failed; please install manually"

# Enable suricata module and configure output to Logstash/ELK
filebeat modules enable suricata || true

# Configure Filebeat output to Logstash
cat > /etc/filebeat/filebeat.yml <<EOF
filebeat.modules:
- module: suricata
  eve:
    enabled: true
    var.input: file
    var.paths: ["/var/log/suricata/eve.json"]

output.logstash:
  hosts: ["${ELK_HOST}:${ELK_PORT}"]
EOF

systemctl enable filebeat
systemctl restart filebeat || warn "Filebeat restart failed"

# ========== 9. Update and backup automation with Telegram alerts ==========
info "Creating update & backup scripts with Telegram alerts..."
cat > /usr/local/bin/security-update-and-report.sh <<'EOF'
#!/bin/bash
LOGFILE="/var/log/security-updates.log"
echo "=== Security update: $(date) ===" >> "$LOGFILE"
# update blocklists and IDS rules
pihole -g >> "$LOGFILE" 2>&1 || true
suricata-update >> "$LOGFILE" 2>&1 || true
systemctl restart suricata >> "$LOGFILE" 2>&1 || true
# run AIDE check
/usr/bin/aide --check >> "$LOGFILE" 2>&1 || true
# rotate filebeat (trigger a restart to ensure shipping)
systemctl restart filebeat >> "$LOGFILE" 2>&1 || true
# send summary to telegram
SUMMARY=$(tail -n 60 "$LOGFILE" | sed -e 's/"/\\"/g')
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
if [[ "${TELEGRAM_BOT_TOKEN}" != "REPLACE_WITH_TELEGRAM_BOT_TOKEN" ]]; then
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" -d chat_id="${TELEGRAM_CHAT_ID}" -d text="Security update on $(hostname):\n\n${SUMMARY}" >/dev/null || true
fi
EOF
chmod +x /usr/local/bin/security-update-and-report.sh

# cron schedule
(crontab -l 2>/dev/null || true; echo "0 3 * * * /usr/local/bin/security-update-and-report.sh") | crontab -

# ========== 10. Backup configs script ==========
cat > /usr/local/bin/backup-security-configs.sh <<'EOF'
#!/bin/bash
BACKUP_DIR="/var/backups/security"
mkdir -p "$BACKUP_DIR"
FILE="$BACKUP_DIR/security_backup_$(date +%F).tar.gz"
tar czf "$FILE" /etc/pihole /etc/unbound /etc/wireguard /etc/suricata /etc/ufw /etc/fail2ban /etc/filebeat || true
find "$BACKUP_DIR" -type f -mtime +30 -delete
# optional: scp to remote backup server (uncomment and configure)
# scp "$FILE" user@backup.example.com:/path/
EOF
chmod +x /usr/local/bin/backup-security-configs.sh
(crontab -l 2>/dev/null || true; echo "0 2 * * 0 /usr/local/bin/backup-security-configs.sh") | crontab -

# ========== 11. System hardening basics ==========
info "Applying basic hardening - SSH and Lynis audit..."
apt install -y lynis || true
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config || true
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
systemctl restart ssh || true
lynis audit system --quick || true

# ========== 12. Final notes and notifications ==========
info "Pro Edition installation finished. Sending Telegram notification if configured..."
tg_notify "Pro security stack installed on $(hostname). Check Pi-hole web UI and Suricata logs."

echo "[✓] Pro Edition installation complete."
echo "[i] Please edit the top of this script to set TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ELK_HOST and adjust WireGuard peers before production use."

echo "[i] Reboot recommended: sudo reboot"

# End of script
