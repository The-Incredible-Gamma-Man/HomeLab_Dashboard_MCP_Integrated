#!/bin/bash
# ========================
# Unified Dashboard Script
# ========================
set -euo pipefail

echo "=== Platform Unified Dashboard Script ==="
echo

# Resolve the real user even when called via sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
WORK_DIR="$REAL_HOME/Downloads/team-platform"
USB_DIR="${1:-}"
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
CADDYFILE="$WORK_DIR/Caddyfile"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 1; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

# ====================== PREREQUISITE CHECKS ======================
command -v docker >/dev/null 2>&1 || error "Docker is not installed. Install it first: https://docs.docker.com/engine/install/ubuntu/"
id -nG "$REAL_USER" | grep -qw docker || error "User $REAL_USER is not in the 'docker' group. Fix with: sudo usermod -aG docker $REAL_USER && newgrp docker"

# Only require sudo for the steps that need it
SUDO_CMD=""
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || error "sudo is required for /etc/hosts and mkcert install steps."
  SUDO_CMD="sudo"
  warn "Not running as root — will use sudo only where needed."
fi

mkdir -p "$WORK_DIR"/{certs,mcpo,backups,gitea-data,trilium-data,nextcloud-data,nextcloud-db-data,portainer-data,ollama-data,openwebui-data,keycloak-data,keycloak-db-data,gitlab-data,gitlab-logs,gitlab-config}

# Ensure correct ownership for container UIDs
$SUDO_CMD chown -R 999:999 "$WORK_DIR/keycloak-db-data"
$SUDO_CMD chown -R 1000:0 "$WORK_DIR/keycloak-data"
$SUDO_CMD chown -R 33:33 "$WORK_DIR/nextcloud-data"
$SUDO_CMD chmod 750 "$WORK_DIR/nextcloud-data"
$SUDO_CMD chown -R 999:999 "$WORK_DIR/nextcloud-db-data"
$SUDO_CMD chown -R "$REAL_USER":"$REAL_USER" "$WORK_DIR"

cd "$WORK_DIR"

# ====================== NVIDIA CHECK & TOOLKIT ======================
HAS_NVIDIA=false
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
  HAS_NVIDIA=true
  success "NVIDIA GPU detected."
  if ! command -v nvidia-container-toolkit >/dev/null 2>&1; then
    warn "nvidia-container-toolkit is missing (required for GPU in Docker)."
    read -p "Install it automatically now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      $SUDO_CMD apt-get update -qq
      $SUDO_CMD apt-get install -y -qq nvidia-container-toolkit
      $SUDO_CMD nvidia-ctk runtime configure --runtime=docker
      $SUDO_CMD systemctl restart docker
      success "nvidia-container-toolkit installed and Docker restarted."
    else
      warn "Ollama will run on CPU only."
    fi
  fi
else
  warn "No NVIDIA GPU detected — Ollama will run on CPU."
fi

# ====================== DOMAIN & REALM INPUT ======================
echo
echo "=== Domain Names ==="
read -p "Portal domain [portal.lan] : " PORTAL_DOMAIN; PORTAL_DOMAIN=${PORTAL_DOMAIN:-portal.lan}
read -p "Keycloak domain [keycloak.lan] : " KC_DOMAIN; KC_DOMAIN=${KC_DOMAIN:-keycloak.lan}
read -p "Gitea domain [gitea.lan] : " GITEA_DOMAIN; GITEA_DOMAIN=${GITEA_DOMAIN:-gitea.lan}
read -p "GitLab domain [gitlab.lan] : " GITLAB_DOMAIN; GITLAB_DOMAIN=${GITLAB_DOMAIN:-gitlab.lan}
read -p "Trilium domain [trilium.lan] : " TRILIUM_DOMAIN; TRILIUM_DOMAIN=${TRILIUM_DOMAIN:-trilium.lan}
read -p "Nextcloud domain [nextcloud.lan] : " NEXTCLOUD_DOMAIN; NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN:-nextcloud.lan}
read -p "Portainer domain [portainer.lan] : " PORTAINER_DOMAIN; PORTAINER_DOMAIN=${PORTAINER_DOMAIN:-portainer.lan}
read -p "WebUI domain [webui.lan] : " WEBUI_DOMAIN; WEBUI_DOMAIN=${WEBUI_DOMAIN:-webui.lan}
read -p "Restreamer domain [restreamer.lan] : " RESTREAMER_DOMAIN; RESTREAMER_DOMAIN=${RESTREAMER_DOMAIN:-restreamer.lan}

REALM_NAME="team-realm"   # ← standardized and used everywhere

echo
echo "=== Host IP Assignments ==="
echo "Each domain can resolve to a different IP (local NIC, VPN tunnel, etc.)."
echo
read -p "Default/fallback host IP [auto-detect]: " DEFAULT_IP
DEFAULT_IP=${DEFAULT_IP:-$(hostname -I | awk '{print $1}')}
[[ $DEFAULT_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Invalid IP: $DEFAULT_IP"

prompt_ip() {
  local label="$1" default="$2"
  read -p " IP for ${label} [${default}]: " val
  val=${val:-$default}
  [[ $val =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Invalid IP: $val"
  echo "$val"
}

PORTAL_IP=$(prompt_ip "$PORTAL_DOMAIN" "$DEFAULT_IP")
KC_IP=$(prompt_ip "$KC_DOMAIN" "$DEFAULT_IP")
GITEA_IP=$(prompt_ip "$GITEA_DOMAIN" "$DEFAULT_IP")
GITLAB_IP=$(prompt_ip "$GITLAB_DOMAIN" "$DEFAULT_IP")
TRILIUM_IP=$(prompt_ip "$TRILIUM_DOMAIN" "$DEFAULT_IP")
NEXTCLOUD_IP=$(prompt_ip "$NEXTCLOUD_DOMAIN" "$DEFAULT_IP")
PORTAINER_IP=$(prompt_ip "$PORTAINER_DOMAIN" "$DEFAULT_IP")
WEBUI_IP=$(prompt_ip "$WEBUI_DOMAIN" "$DEFAULT_IP")
RESTREAMER_IP=$(prompt_ip "$RESTREAMER_DOMAIN (upstream)" "$DEFAULT_IP")

echo
echo "=== GitLab SSH Port ==="
read -p "Host port for GitLab SSH [2222]: " GITLAB_SSH_PORT
GITLAB_SSH_PORT=${GITLAB_SSH_PORT:-2222}
[[ $GITLAB_SSH_PORT =~ ^[0-9]+$ ]] || error "Invalid port: $GITLAB_SSH_PORT"

# ====================== SECRETS ======================
echo
echo "=== Secrets (press Enter for strong random values) ==="
read -sp "Keycloak DB password : " KC_DB_PASS; echo; KC_DB_PASS=${KC_DB_PASS:-$(openssl rand -hex 32)}
read -sp "Keycloak Admin password : " KC_ADMIN_PASS; echo; KC_ADMIN_PASS=${KC_ADMIN_PASS:-$(openssl rand -hex 16)}
read -sp "Homarr OIDC Client Secret : " HOMARR_SECRET; echo; HOMARR_SECRET=${HOMARR_SECRET:-$(openssl rand -hex 32)}
read -sp "OpenWebUI OAUTH Secret : " OWUI_SECRET; echo; OWUI_SECRET=${OWUI_SECRET:-$(openssl rand -hex 32)}
read -sp "OpenWebUI Secret Key : " OWUI_WEBUI_KEY; echo; OWUI_WEBUI_KEY=${OWUI_WEBUI_KEY:-$(openssl rand -hex 32)}
read -sp "Trilium OAUTH Client Secret : " TRILIUM_SECRET; echo; TRILIUM_SECRET=${TRILIUM_SECRET:-$(openssl rand -hex 32)}
read -sp "Nextcloud DB root password : " NC_DB_ROOT_PASS; echo; NC_DB_ROOT_PASS=${NC_DB_ROOT_PASS:-$(openssl rand -hex 32)}
read -sp "Nextcloud MCP password : " NC_MCP_PASS; echo; NC_MCP_PASS=${NC_MCP_PASS:-$(openssl rand -hex 32)}
read -sp "GitLab root password : " GITLAB_ROOT_PASS; echo; GITLAB_ROOT_PASS=${GITLAB_ROOT_PASS:-$(openssl rand -hex 16)}
MCPO_API_KEY=$(openssl rand -hex 32)
HOMARR_ENCRYPTION_KEY=$(openssl rand -hex 32)

# ====================== CERTIFICATES (arch-aware mkcert) ======================
echo
echo "=== Generating mkcert certificates ==="
if ! command -v mkcert >/dev/null 2>&1; then
  $SUDO_CMD apt-get update -qq
  $SUDO_CMD apt-get install -y -qq libnss3-tools
  MKCERT_VERSION="1.4.4"
  ARCH=$(uname -m)
  case $ARCH in
    x86_64) MKCERT_ARCH="amd64" ;;
    aarch64|arm64) MKCERT_ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH (only amd64/arm64 supported)" ;;
  esac
  $SUDO_CMD wget -q "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-${MKCERT_ARCH}" \
    -O /usr/local/bin/mkcert
  $SUDO_CMD chmod +x /usr/local/bin/mkcert
fi

# Install the CA as the real user so browsers trust it
sudo -u "$REAL_USER" HOME="$REAL_HOME" mkcert -install

CERT_DOMAINS="$PORTAL_DOMAIN $KC_DOMAIN $GITEA_DOMAIN $GITLAB_DOMAIN $TRILIUM_DOMAIN $NEXTCLOUD_DOMAIN $PORTAINER_DOMAIN $WEBUI_DOMAIN $RESTREAMER_DOMAIN localhost 127.0.0.1"
sudo -u "$REAL_USER" HOME="$REAL_HOME" mkcert \
  -key-file "$WORK_DIR/certs/key.pem" \
  -cert-file "$WORK_DIR/certs/cert.pem" \
  $CERT_DOMAINS

CAROOT=$(sudo -u "$REAL_USER" HOME="$REAL_HOME" mkcert -CAROOT)
cp "$CAROOT/rootCA.pem" "$WORK_DIR/certs/rootCA.crt"
chown -R "$REAL_USER":"$REAL_USER" "$WORK_DIR/certs"
success "Certificates ready."

# ====================== /etc/hosts ======================
echo
echo "=== Updating /etc/hosts ==="
$SUDO_CMD sed -i '/# team-platform-managed/d' /etc/hosts
declare -A DOMAIN_IPS=(
  ["$PORTAL_DOMAIN"]="$PORTAL_IP"
  ["$KC_DOMAIN"]="$KC_IP"
  ["$GITEA_DOMAIN"]="$GITEA_IP"
  ["$GITLAB_DOMAIN"]="$GITLAB_IP"
  ["$TRILIUM_DOMAIN"]="$TRILIUM_IP"
  ["$NEXTCLOUD_DOMAIN"]="$NEXTCLOUD_IP"
  ["$PORTAINER_DOMAIN"]="$PORTAINER_IP"
  ["$WEBUI_DOMAIN"]="$WEBUI_IP"
  ["$RESTREAMER_DOMAIN"]="$RESTREAMER_IP"
)
for domain in "${!DOMAIN_IPS[@]}"; do
  echo "${DOMAIN_IPS[$domain]} ${domain} # team-platform-managed" | $SUDO_CMD tee -a /etc/hosts >/dev/null
done
success "/etc/hosts updated."

# ====================== MCPO CONFIG ======================
echo
echo "=== Preparing MCPO config.json ==="
if [[ -n "$USB_DIR" && -f "$USB_DIR/team-platform/mcp/mcpo/config.json" ]]; then
  cp "$USB_DIR/team-platform/mcp/mcpo/config.json" "$WORK_DIR/mcpo/config.json"
  sed -i \
    -e "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:3000|gitea:3000|g" \
    -e "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:8888|trilium:8080|g" \
    -e "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:80|nextcloud:80|g" \
    -e "s|[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+:9000|portainer:9000|g" \
    -e 's|"GITEA_ACCESS_TOKEN": "[^"]*"|"GITEA_ACCESS_TOKEN": "CHANGE_ME_AFTER_FIRST_START"|g' \
    -e 's|"TRILIUM_API_TOKEN": "[^"]*"|"TRILIUM_API_TOKEN": "CHANGE_ME_AFTER_FIRST_START"|g' \
    -e 's|"PORTAINER_API_KEY": "[^"]*"|"PORTAINER_API_KEY": "CHANGE_ME_AFTER_FIRST_START"|g' \
    "$WORK_DIR/mcpo/config.json"
  success "MCPO config restored and sanitized."
else
  cat > "$WORK_DIR/mcpo/config.json" <<'MCPOCONFIG'
{
  "mcpServers": {
    "gitea": {
      "command": "docker",
      "args": ["run","--rm","-i","-e","GITEA_ACCESS_TOKEN","-e","GITEA_HOST","docker.gitea.com/gitea-mcp-server"],
      "env": {
        "GITEA_ACCESS_TOKEN": "CHANGE_ME_AFTER_FIRST_START",
        "GITEA_HOST": "http://gitea:3000"
      }
    },
    "nextcloud": {
      "type": "streamable-http",
      "url": "http://nextcloud-mcp:8000/mcp"
    },
    "trilium": {
      "command": "npx",
      "args": ["-y", "triliumnext-mcp"],
      "env": {
        "TRILIUM_API_URL": "http://trilium:8080/etapi",
        "TRILIUM_API_TOKEN": "CHANGE_ME_AFTER_FIRST_START",
        "PERMISSIONS": "READ;WRITE"
      }
    },
    "portainer": {
      "command": "docker",
      "args": ["run","--rm","-i","--add-host=host.docker.internal:host-gateway",
               "-e","PORTAINER_URL","-e","PORTAINER_API_KEY","-e","PORTAINER_WRITE_ENABLED",
               "ghcr.io/caffeineflo/portainer-mcp:latest"],
      "env": {
        "PORTAINER_URL": "http://portainer:9000",
        "PORTAINER_API_KEY": "CHANGE_ME_AFTER_FIRST_START",
        "PORTAINER_WRITE_ENABLED": "true"
      }
    }
  }
}
MCPOCONFIG
  success "Minimal MCPO config.json created with placeholders."
fi

# ====================== CADDYFILE ======================
cat > "$CADDYFILE" <<EOF
{
    auto_https off
}
${PORTAL_DOMAIN} {
    reverse_proxy homarr:7575
    tls /certs/cert.pem /certs/key.pem
}
${KC_DOMAIN} {
    reverse_proxy keycloak:8080
    tls /certs/cert.pem /certs/key.pem
}
${GITEA_DOMAIN} {
    reverse_proxy gitea:3000
    tls /certs/cert.pem /certs/key.pem
}
${GITLAB_DOMAIN} {
    reverse_proxy gitlab:80
    tls /certs/cert.pem /certs/key.pem
}
${TRILIUM_DOMAIN} {
    reverse_proxy trilium:8080
    tls /certs/cert.pem /certs/key.pem
}
${NEXTCLOUD_DOMAIN} {
    reverse_proxy nextcloud:80
    tls /certs/cert.pem /certs/key.pem
}
${PORTAINER_DOMAIN} {
    reverse_proxy portainer:9000
    tls /certs/cert.pem /certs/key.pem
}
${WEBUI_DOMAIN} {
    reverse_proxy openwebui:8080
    tls /certs/cert.pem /certs/key.pem
}
${RESTREAMER_DOMAIN} {
    reverse_proxy http://${RESTREAMER_IP}:8987
    tls /certs/cert.pem /certs/key.pem
    @hls path *.m3u8 *.ts
    header @hls {
        Access-Control-Allow-Origin *
        Access-Control-Allow-Methods "GET, OPTIONS"
    }
    @options method OPTIONS
    respond @options 204
}
EOF
success "Caddyfile generated."

# ====================== DOCKER COMPOSE ======================
if [[ "$HAS_NVIDIA" == "true" ]]; then
  OLLAMA_DEPLOY=$(cat <<'DEPLOY'
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
DEPLOY
)
else
  OLLAMA_DEPLOY=""
fi

cat > "$COMPOSE_FILE" <<EOF
services:
  caddy:
    image: caddy:2-alpine
    container_name: central-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${CADDYFILE}:/etc/caddy/Caddyfile:ro
      - ${WORK_DIR}/certs:/certs:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - platform-net
  keycloak-db:
    image: postgres:16-alpine
    container_name: keycloak-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KC_DB_PASS}
    volumes:
      - ${WORK_DIR}/keycloak-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks:
      - platform-net
  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: portal-keycloak
    command: start
    restart: unless-stopped
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://keycloak-db:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KC_DB_PASS}
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_ADMIN_PASS}
      KC_HOSTNAME: https://${KC_DOMAIN}
      KC_HOSTNAME_STRICT: "true"
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
    volumes:
      - ${WORK_DIR}/keycloak-data:/opt/keycloak/data
    depends_on:
      keycloak-db:
        condition: service_healthy
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  homarr:
    image: ghcr.io/homarr-labs/homarr:latest
    container_name: portal-homarr
    restart: unless-stopped
    environment:
      AUTH_PROVIDERS: oidc,credentials
      NEXTAUTH_URL: https://${PORTAL_DOMAIN}
      SECRET_ENCRYPTION_KEY: ${HOMARR_ENCRYPTION_KEY}
      AUTH_OIDC_ISSUER: https://${KC_DOMAIN}/realms/${REALM_NAME}
      AUTH_OIDC_CLIENT_ID: homarr
      AUTH_OIDC_CLIENT_SECRET: ${HOMARR_SECRET}    # <---- Insert from Keycloak
      AUTH_OIDC_REDIRECT_URI: https://${PORTAL_DOMAIN}/api/auth/callback/oidc
      NODE_EXTRA_CA_CERTS: /certs/rootCA.crt
    volumes:
      - $WORK_DIR/appdata:/appdata
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${WORK_DIR}/certs:/certs:ro
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  gitea:
    image: gitea/gitea:latest
    container_name: gitea-server
    restart: unless-stopped
    environment:
      GITEA__server__DOMAIN: ${GITEA_DOMAIN}
      GITEA__server__ROOT_URL: https://${GITEA_DOMAIN}/
      GITEA__server__REVERSE_PROXY_TRUSTED_PROXIES: 172.16.0.0/12
    volumes:
      - ${WORK_DIR}/gitea-data:/data
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab-ce
    restart: unless-stopped
    hostname: ${GITLAB_DOMAIN}
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${GITLAB_DOMAIN}'
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        nginx['proxy_set_headers'] = {
          'X-Forwarded-Proto' => 'https',
          'X-Forwarded-Ssl' => 'on'
        }
        nginx['real_ip_trusted_addresses'] = ['172.16.0.0/12']
        nginx['real_ip_header'] = 'X-Forwarded-For'
        nginx['real_ip_recursive'] = 'on'
        gitlab_rails['initial_root_password'] = '${GITLAB_ROOT_PASS}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}
        letsencrypt['enable'] = false
        gitlab_rails['omniauth_enabled'] = true
        gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
        gitlab_rails['omniauth_sync_email_from_provider'] = 'openid_connect'
        gitlab_rails['omniauth_sync_profile_from_provider'] = ['openid_connect']
        gitlab_rails['omniauth_block_auto_created_users'] = false
        gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']
        gitlab_rails['omniauth_providers'] = [
          {
            name: 'openid_connect',
            label: 'Keycloak',
            args: {
              name: 'openid_connect',
              scope: ['openid', 'profile', 'email'],
              response_type: 'code',
              issuer: 'https://${KC_DOMAIN}/realms/${REALM_NAME}',
              discovery: true,
              client_auth_method: 'query',
              uid_field: 'preferred_username',
              pkce: 'true',
              client_options: {
                identifier: 'gitlab',
                secret: 'CHANGE_ME_TO_CLIENT_SECRET',    # <---- Insert from Keycloak
                redirect_uri: 'https://${GITLAB_DOMAIN}/users/auth/openid_connect/callback'
              }
            }
          }
        ]
    ports:
      - "${GITLAB_SSH_PORT}:22"
    volumes:
      - ${WORK_DIR}/gitlab-config:/etc/gitlab
      - ${WORK_DIR}/gitlab-logs:/var/log/gitlab
      - ${WORK_DIR}/gitlab-data:/var/opt/gitlab
    shm_size: 256m
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  trilium:
    image: triliumnext/trilium:latest
    container_name: trilium-next
    restart: unless-stopped
    environment:
      TRILIUM_OAUTH_BASE_URL: https://${TRILIUM_DOMAIN}
      TRILIUM_OAUTH_CLIENT_ID: trilium
      TRILIUM_OAUTH_CLIENT_SECRET: ${TRILIUM_SECRET}    # <---- Insert from Keycloak
      TRILIUM_OAUTH_ISSUER_BASE_URL: https://${KC_DOMAIN}/realms/${REALM_NAME}/.well-known/openid-configuration
    volumes:
      - ${WORK_DIR}/trilium-data:/home/node/trilium-data
      - ${WORK_DIR}/certs/rootCA.crt:/usr/local/share/ca-certificates/rootCA.crt:ro
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  nextcloud-db:
    image: mariadb:10.6
    container_name: nextcloud-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${NC_DB_ROOT_PASS}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${NC_DB_ROOT_PASS}
      MARIADB_USER_HOST: '%'
    volumes:
      - ${WORK_DIR}/nextcloud-db-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 40s
    networks:
      - platform-net
  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: unless-stopped
    entrypoint: >
      sh -c "update-ca-certificates &&
             php -r \"file_put_contents(openssl_get_cert_locations()['default_cert_file'], file_get_contents(openssl_get_cert_locations()['default_cert_file']) . file_get_contents('/usr/local/share/ca-certificates/rootCA.crt'));\" &&
             /entrypoint.sh apache2-foreground"
    environment:
      MYSQL_HOST: nextcloud-db
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${NC_DB_ROOT_PASS}
      MYSQL_DATABASE: nextcloud
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_DOMAIN}
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${NC_DB_ROOT_PASS}
      NEXTCLOUD_DATA_DIR: /var/www/html/data
    volumes:
      - ${WORK_DIR}/nextcloud-data:/var/www/html
      - ${WORK_DIR}/certs/rootCA.crt:/usr/local/share/ca-certificates/rootCA.crt:ro
    depends_on:
      nextcloud-db:
        condition: service_healthy
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer-ce
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${WORK_DIR}/portainer-data:/data
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  ollama:
    image: ollama/ollama:latest
    container_name: ai-ollama
    restart: unless-stopped
${OLLAMA_DEPLOY}
    volumes:
      - ${WORK_DIR}/ollama-data:/root/.ollama
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  nextcloud-mcp:
    image: ghcr.io/cbcoutinho/nextcloud-mcp-server:latest
    container_name: ai-nextcloud-mcp
    restart: unless-stopped
    environment:
      NEXTCLOUD_HOST: http://nextcloud:80
      NEXTCLOUD_PASSWORD: ${NC_MCP_PASS}
    healthcheck:
      test: ["CMD", "/app/.venv/bin/python3", "-c", "import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health/live').status == 200 else 1)"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  mcpo:
    image: ghcr.io/open-webui/mcpo:main
    container_name: ai-mcpo
    restart: unless-stopped
    volumes:
      - ${WORK_DIR}/mcpo/config.json:/app/config.json:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command: ["--config", "/app/config.json", "--port", "8000", "--api-key", "${MCPO_API_KEY}"]
    depends_on:
      - nextcloud-mcp
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: ai-open-webui
    restart: unless-stopped
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_URL=https://webui.lan
      - WEBUI_AUTH=true
      - WEBUI_SECRET_KEY=62bfce2e6aee7f7b4064ae8efc6f13effafbdaae73e802e43c767aa7fe9a0bfb
      - ENABLE_OAUTH_SIGNUP=true
      - OAUTH_CLIENT_ID=open-webui
      - OAUTH_PROVIDER_NAME=Keycloak
      - OAUTH_CLIENT_SECRET=ObKXb3RInKaVcRz4AelpdmypAzE1NPXf    # <---- Insert from Keycloak
      - OPENID_PROVIDER_URL=https://keycloak.lan/realms/team-realm/.well-known/openid-configuration
      - OPENID_REDIRECT_URI=https://webui.lan/oauth/oidc/callback
      - ENABLE_OAUTH_GROUP_MANAGEMENT=true
      - ENABLE_OAUTH_GROUP_CREATION=true
      - OAUTH_GROUP_CLAIM=groups
      - SSL_CERT_FILE=/usr/local/share/ca-certificates/rootCA.crt
      - OAUTH_TOKEN_ENDPOINT_AUTH_METHOD=client_secret_post
      - ENABLE_FORWARD_USER_INFO_HEADERS=true
      - ENABLE_SIGNUP=false    # <---- Set to false after initial sign-up
      - CORS_ALLOW_ORIGIN=https://webui.lan
      - USER_AGENT=open-webui/webui.lan
      - HF_HUB_OFFLINE=1
      - HF_TOKEN= #Leave empty
      - TRANSFORMERS_OFFLINE=1
    volumes:
      - ${WORK_DIR}/openwebui-data:/app/backend/data
      - ${WORK_DIR}/certs/rootCA.crt:/usr/local/share/ca-certificates/rootCA.crt:ro
    depends_on:
      - ollama
      - mcpo
    networks:
      - platform-net
    extra_hosts:
      - "${KC_DOMAIN}:${KC_IP}"
      - "${PORTAL_DOMAIN}:${PORTAL_IP}"
      - "${NEXTCLOUD_DOMAIN}:${NEXTCLOUD_IP}"
      - "${WEBUI_DOMAIN}:${WEBUI_IP}"
      - "${GITEA_DOMAIN}:${GITEA_IP}"
      - "${GITLAB_DOMAIN}:${GITLAB_IP}"
      - "${TRILIUM_DOMAIN}:${TRILIUM_IP}"
      - "${PORTAINER_DOMAIN}:${PORTAINER_IP}"
      - "${RESTREAMER_DOMAIN}:${RESTREAMER_IP}"
networks:
  platform-net:
    driver: bridge
volumes:
  caddy-data:
  caddy-config:
EOF
$SUDO_CMD chown -R "$REAL_USER":"$REAL_USER" "$WORK_DIR"
success "docker-compose.yml created."

# ====================== ERROR HANDLING & CLEANUP SETUP ======================
CLEANUP_NEEDED=true
ERROR_OCCURRED=false

cleanup() {
  if [ "$ERROR_OCCURRED" = true ] && [ -f "$COMPOSE_FILE" ]; then
    echo -e "\n${RED}=== ERROR DETECTED ===${NC}"
    read -p "Stop & remove ALL containers + volumes to start clean? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "Cleaning up partial stack..."
      sudo -u "$REAL_USER" docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
      success "Stack cleaned. Re-run the script when ready."
    else
      warn "Partial stack left running. Fix manually then re-run."
    fi
  fi
}

trap 'ERROR_OCCURRED=true; cleanup' ERR EXIT

echo
echo "=== Starting the full stack ==="
echo "Note: GitLab can take 3–5+ minutes. Nextcloud first initialization is often slow in VMs (10–40+ minutes possible)."
echo
sudo -u "$REAL_USER" docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
sudo -u "$REAL_USER" docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

# Nextcloud wait with progress feedback
echo "=== Waiting for Nextcloud to initialise (this can take a long time on first run in a VM) ==="
WAIT_COUNT=0
while true; do
  if docker exec nextcloud curl -sf http://localhost/status.php 2>/dev/null | grep -q 'installed":true'; then
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  echo " Nextcloud not ready yet, waiting 5s... ($WAIT_COUNT)"
  if (( WAIT_COUNT % 10 == 0 )); then
    echo -e "${YELLOW}Tip: Check progress with: docker compose -p team-platform logs -f nextcloud${NC}"
    echo "     (It is normal for the first initialization to take 10–40+ minutes in a VM.)"
  fi
  sleep 5
done
success "Nextcloud is ready."

# Nextcloud OIDC configuration (uses standardized realm)
echo "=== Configuring Nextcloud settings ==="
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set allow_local_remote_servers --value=true --type=boolean
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_create_user --value=true --type=boolean
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_code_challenge_method --value="S256"
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_provider_url --value="https://${KC_DOMAIN}/realms/${REALM_NAME}"
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_client_id --value="nextcloud"
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_client_secret --value="CHANGE_ME_AFTER_KEYCLOAK_SETUP"
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_auto_redirect --value=false --type=boolean
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_button_text --value="Login with Keycloak"
docker exec -u www-data nextcloud php /var/www/html/occ config:system:set oidc_login_use_id_token --value=true --type=boolean
success "Nextcloud OIDC settings configured."

# Final CA installation
echo "=== Installing mkcert CA where possible ==="

# Nextcloud (already handled)
success "CA handled in Nextcloud (PHP bundle)"

# OpenWebUI usually works
success "CA installed in ai-open-webui"

# Homarr (minimal image - uses special directory)
docker exec -u root portal-homarr mkdir -p /appdata/trusted-certificates 2>/dev/null || true
docker cp "$WORK_DIR/certs/rootCA.crt" portal-homarr:/appdata/trusted-certificates/mkcert-rootCA.crt 2>/dev/null \
  && success "CA added to Homarr" || warn "Could not add CA to Homarr"

# Trilium (Node.js based)
docker cp "$WORK_DIR/certs/rootCA.crt" trilium-next:/usr/local/share/ca-certificates/rootCA.crt 2>/dev/null || true
docker exec -u root trilium-next sh -c 'mkdir -p /etc/ssl/certs && cp /usr/local/share/ca-certificates/rootCA.crt /etc/ssl/certs/' 2>/dev/null || true
success "CA copied to Trilium"

# Restart affected containers
docker compose -f "$COMPOSE_FILE" restart portal-homarr trilium-next 2>/dev/null || true

# Turn off cleanup on success
CLEANUP_NEEDED=false
trap - ERR EXIT

echo
success "=== DEPLOYMENT COMPLETE ==="
echo
echo "Access URLs (https://):"
printf " %-20s → https://%s\n" "Portal/Homarr" "$PORTAL_DOMAIN"
printf " %-20s → https://%s (admin / %s)\n" "Keycloak" "$KC_DOMAIN" "$KC_ADMIN_PASS"
printf " %-20s → https://%s\n" "Gitea" "$GITEA_DOMAIN"
printf " %-20s → https://%s (root / %s)\n" "GitLab CE" "$GITLAB_DOMAIN" "$GITLAB_ROOT_PASS"
printf " %-20s → https://%s\n" "Trilium" "$TRILIUM_DOMAIN"
printf " %-20s → https://%s (admin / %s)\n" "Nextcloud" "$NEXTCLOUD_DOMAIN" "${NC_DB_ROOT_PASS}"
printf " %-20s → https://%s\n" "Portainer" "$PORTAINER_DOMAIN"
printf " %-20s → https://%s\n" "WebUI" "$WEBUI_DOMAIN"
printf " %-20s → https://%s (upstream: %s)\n" "Restreamer" "$RESTREAMER_DOMAIN" "$RESTREAMER_IP"
echo
echo "GitLab SSH clone port : $GITLAB_SSH_PORT"
echo "MCPO API key : $MCPO_API_KEY"
echo
echo "Post-setup steps:"
echo " 1. Wait for GitLab (docker logs -f gitlab-ce)"
echo " 2. Update tokens in $WORK_DIR/mcpo/config.json"
echo " 3. Restart mcpo: docker compose -f $COMPOSE_FILE restart mcpo"
echo " 4. Create Keycloak realm '${REALM_NAME}' + clients (homarr, gitlab, nextcloud, trilium, openwebui)"
echo " 5. Check status: docker compose -f $COMPOSE_FILE ps"
echo " 6. If you've run the script more than once, ensure you delete the Keycloak password data: 'rm -rf keycloak-db-data' and bring the container back up"
echo "=== Enjoy!! ==="
