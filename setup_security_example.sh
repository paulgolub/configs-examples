#!/bin/bash
set -e

echo "[+] Installing essential packages..."

# Update system and install dependencies
sudo apt update && sudo apt upgrade -y
sudo apt install -y pi-hole-ftl unbound wireguard suricata ufw tcpdump net-tools cron htop netcat git

echo "[+] Basic packages installed."

# Pi-hole install
echo "[+] Installing Pi-hole..."
curl -sSL https://install.pi-hole.net | bash

# Configure Unbound DNS resolver
echo "[+] Configuring Unbound..."
sudo tee /etc/unbound/unbound.conf.d/pi-hole.conf > /dev/null <<EOF
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

sudo systemctl restart unbound

# Set Pi-hole DNS to Unbound
sed -i 's/^PIHOLE_DNS_1=.*$/PIHOLE_DNS_1=127.0.0.1#5335/' /etc/pihole/setupVars.conf
pihole restartdns

# Configure WireGuard
echo "[+] Setting up WireGuard VPN..."
sudo mkdir -p /etc/wireguard
cd /etc/wireguard

wg genkey | tee privatekey | wg pubkey > publickey
PRIVATE_KEY=$(cat privatekey)
PUBLIC_KEY=$(cat publickey)

sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.66.66.1/24
ListenPort = 51820
SaveConfig = true

# Example peer - replace or remove
#[Peer]
#PublicKey = examplepeerkey
#AllowedIPs = 10.66.66.2/32
EOF

sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Suricata IDS
echo "[+] Configuring Suricata IDS..."
sudo suricata-update
sudo systemctl enable suricata
sudo systemctl start suricata

# Firewall with UFW
echo "[+] Setting up UFW firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 53,67,80,443,51820/udp
sudo ufw allow 4711/tcp
sudo ufw --force enable

# Security update automation script
echo "[+] Creating scheduled threat updates..."
sudo tee /home/pi/update_security.sh > /dev/null <<'EOF'
#!/bin/bash
echo "Threat update: $(date)" >> /var/log/security-updates.log
pihole -g >> /var/log/security-updates.log
suricata-update >> /var/log/security-updates.log
EOF

chmod +x /home/pi/update_security.sh
(crontab -l ; echo "0 3 * * * /home/pi/update_security.sh") | crontab -

echo "[✓] Raspberry Pi security stack installed successfully."
echo "[i] Reboot the system with: sudo reboot"
echo "[i] Access Pi-hole at http://<raspberry-ip>/admin"
echo "[i] To add WireGuard clients, generate key pairs and update /etc/wireguard/wg0.conf"
