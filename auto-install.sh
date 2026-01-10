#!/usr/bin/env bash

set -e

# ====== Fixed email for acme.sh ======
EMAIL="my-example@gmail.com"

V2RAY_DIR="/etc/v2ray"
V2RAY_CONFIG="/usr/local/etc/v2ray/config.json"

# ====== Helper functions ======
log() {
  echo -e "\n========== $1 ==========\n"
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this script as root"
    exit 1
  fi
}

# ====== Interactive input ======
input_domain() {
  read -rp "Enter your domain name (already pointing to this server IP): " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo "❌ Domain name cannot be empty"
    exit 1
  fi
}

# ====== 1. Wait for domain to resolve ======
wait_dns() {
    while ! getent hosts "$DOMAIN" > /dev/null; do
        sleep 10
    done
}

# ====== 1. Time check ======
check_time() {
  log "Checking system time (time drift should be < 90 seconds)"
  date -R
}

# ====== 2. Install dependencies ======
install_deps() {
  log "Installing required packages"
  apt update
  apt install -y curl nginx socat uuid-runtime
}

# ====== Stop nginx ======
stop_nginx() {
  log "Stopping nginx to free port 80"
  systemctl stop nginx || true
}

# ====== 3. Download v2ray installer ======
download_v2ray() {
  log "Downloading v2ray installation script"
  curl -O https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh
}

# ====== 4. Install v2ray ======
install_v2ray() {
  log "Installing v2ray"
  bash install-release.sh
}

# ====== 5. Install acme.sh ======
install_acme() {
  log "Installing acme.sh"
  curl https://get.acme.sh | sh -s email="${EMAIL}"

  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  source ~/.bashrc
}

# ====== 6. Remove ufw ======
remove_ufw() {
  log "Removing ufw firewall"
  apt purge -y ufw || true
}

# ====== 7. Issue SSL certificate ======
issue_cert() {
  log "Issuing SSL certificate"
  ~/.acme.sh/acme.sh \
    --issue \
    -d "${DOMAIN}" \
    --standalone \
    --keylength ec-256
}

# ====== 8. Install certificate with auto reload ======
install_cert() {
  log "Installing certificate and configuring auto reload"

  mkdir -p "${V2RAY_DIR}"

  ~/.acme.sh/acme.sh \
    --installcert \
    -d "${DOMAIN}" \
    --ecc \
    --fullchain-file "${V2RAY_DIR}/v2ray.crt" \
    --key-file "${V2RAY_DIR}/v2ray.key" \
    --reloadcmd "systemctl is-active --quiet nginx || systemctl start nginx; systemctl restart v2ray"
}

# ====== Configure v2ray ======
configure_v2ray() {
  log "Generating v2ray configuration"

  UUID=$(uuidgen)
  export UUID

  cat >"${V2RAY_CONFIG}" <<EOF
{
  "inbounds": [
    {
      "port": 7777,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/latest-po"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
}

# ====== Configure nginx ======
configure_nginx() {
  log "Generating nginx configuration"

  cat >/etc/nginx/conf.d/v2ray.conf <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    ssl_certificate       /etc/v2ray/v2ray.crt;
    ssl_certificate_key   /etc/v2ray/v2ray.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    server_name ${DOMAIN};

    location /latest-po {
        if (\$http_upgrade != "websocket") {
            return 404;
        }

        proxy_redirect off;
        proxy_pass http://127.0.0.1:7777;
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
}

# ====== Output client configuration ======
output_client_config() {
  log "Generating client configuration (vmess)"

  VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "${DOMAIN}",
  "add": "${DOMAIN}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "${DOMAIN}",
  "path": "/latest-po",
  "tls": "tls"
}
EOF
)

  VMESS_BASE64=$(echo -n "${VMESS_JSON}" | base64 -w 0)

  echo "========== Client Information =========="
  echo "Address : ${DOMAIN}"
  echo "Port    : 443"
  echo "UUID    : ${UUID}"
  echo "Path    : /latest-po"
  echo
  echo "vmess link:"
  echo "vmess://${VMESS_BASE64}"
  echo "========================================"
}

# ====== Start nginx ======
start_nginx() {
  log "Starting nginx"
  systemctl start nginx
}

# ====== Main flow ======
main() {
  check_root
  input_domain
  wait_dns
  check_time
  install_deps
  stop_nginx
  download_v2ray
  install_v2ray
  install_acme
  remove_ufw
  issue_cert
  install_cert
  configure_v2ray
  systemctl restart v2ray
  configure_nginx

  log "Testing nginx configuration"
  nginx -t

  start_nginx
  output_client_config

  log "🎉 Installation completed successfully"
}

main
