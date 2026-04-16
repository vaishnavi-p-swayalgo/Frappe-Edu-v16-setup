#!/usr/bin/env bash
# =============================================================================
#  frappe_setup.sh  v4.0
#  Frappe v16 installer — ERPNext + Education only
#  Domain: playground.swayalgo.com
#
#  Supported OS : Ubuntu 22.04 (Docker)
#  Usage        : sudo bash frappe_setup.sh
# =============================================================================

set -o pipefail

# ─── Bash guard ───────────────────────────────────────────────────────────────
if [ -z "${BASH_VERSION}" ]; then
  echo "[ERROR] This script must run under bash, not sh." >&2
  exit 1
fi

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header() {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n"
}

# ─── App Registry — v16, ERPNext + Education ONLY ─────────────────────────────
declare -A APP_URLS=(
  [erpnext]="https://github.com/frappe/erpnext"
  [education]="https://github.com/frappe/education"
)

declare -A APP_BRANCH=(
  [erpnext]="version-16"
  [education]="main"
)

# ─── Global Defaults ──────────────────────────────────────────────────────────
FRAPPE_VERSION="${FRAPPE_VERSION:-16}"
FRAPPE_USER="${FRAPPE_USER:-frappe}"
BENCH_NAME="${BENCH_NAME:-frappe-bench}"
SITE_NAME="${SITE_NAME:-erp.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
DOMAIN="${DOMAIN:-playground.swayalgo.com}"
IS_DOCKER=false
BACKUP_DIR="/home/${FRAPPE_USER}/backups"
BACKUP_KEEP_DAYS=30

PYTHON_BIN=""
PYTHON_VER=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Please run as root:  sudo bash frappe_setup.sh"
  fi
}

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

detect_docker() {
  if [[ -f "/.dockerenv" ]] || grep -qa "docker\|container\|lxc" /proc/1/cgroup 2>/dev/null; then
    IS_DOCKER=true
    log "Docker environment detected."
  fi
}

svc_start()   { service "$1" start   2>/dev/null || systemctl start   "$1" 2>/dev/null || true; }
svc_restart() { service "$1" restart 2>/dev/null || systemctl restart "$1" 2>/dev/null || true; }
svc_enable()  { systemctl enable "$1" 2>/dev/null || true; }

# ─── Python resolver ──────────────────────────────────────────────────────────
resolve_python() {
  local wanted_ver="$1"
  log "Resolving Python binary for version ${wanted_ver}..."

  if command -v "python${wanted_ver}" >/dev/null 2>&1; then
    PYTHON_BIN="python${wanted_ver}"
    PYTHON_VER="${wanted_ver}"
    log "  Found exact binary: ${PYTHON_BIN} ✔"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    local sys_ver
    sys_ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "")
    if [[ "$sys_ver" == "$wanted_ver" ]]; then
      PYTHON_BIN="python3"
      PYTHON_VER="$sys_ver"
      log "  python3 is version ${sys_ver} — exact match ✔"
      return
    fi
    warn "  python3 is ${sys_ver}, wanted ${wanted_ver}. Trying deadsnakes PPA..."
    add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
    apt-get update -y -qq 2>/dev/null || true
    apt-get install -y "python${wanted_ver}" "python${wanted_ver}-venv" "python${wanted_ver}-dev" 2>/dev/null || true
    if command -v "python${wanted_ver}" >/dev/null 2>&1; then
      PYTHON_BIN="python${wanted_ver}"
      PYTHON_VER="${wanted_ver}"
      log "  Installed python${wanted_ver} successfully ✔"
      return
    fi
    PYTHON_BIN="python3"
    PYTHON_VER="$sys_ver"
    warn "  Could not install python${wanted_ver}. Falling back to python3 (${sys_ver})."
  else
    err "No python3 found on this system. Cannot continue."
  fi

  log "Python resolved: ${PYTHON_BIN} (${PYTHON_VER})"
}

# ─── bench_cmd helper ─────────────────────────────────────────────────────────
bench_cmd() {
  local tmp_script
  tmp_script=$(mktemp /tmp/bench_cmd_XXXXXX.sh)
  chmod 700 "$tmp_script"
  cat > "$tmp_script" << INNERSCRIPT
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
BENCH_BIN="\$HOME/.local/bin/bench"
if [[ ! -x "\$BENCH_BIN" ]]; then
  BENCH_BIN=\$(command -v bench 2>/dev/null || echo "")
fi
if [[ -z "\$BENCH_BIN" ]]; then
  echo "[bench_cmd] ERROR: bench not found" >&2
  exit 1
fi
cd "/home/${FRAPPE_USER}/${BENCH_NAME}" || exit 1
\$BENCH_BIN $*
INNERSCRIPT
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$tmp_script"
  su - "${FRAPPE_USER}" -c "bash $tmp_script"
  local rc=$?
  rm -f "$tmp_script"
  return $rc
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 1 — INSTALL
# ═══════════════════════════════════════════════════════════════════════════════

install_dependencies() {
  header "Installing System Dependencies"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y -qq || err "apt-get update failed."

  apt-get install -y \
    git curl wget nano software-properties-common \
    mariadb-server mariadb-client \
    redis-server \
    xvfb libfontconfig wkhtmltopdf \
    libssl-dev libffi-dev build-essential \
    python3-pip python3-setuptools python3-venv python3-dev \
    pipx \
    supervisor nginx ufw cron \
    || err "apt-get install failed."

  log "System packages installed."

  # Install uv system-wide
  if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh \
      | UV_INSTALL_DIR=/usr/local/bin sh 2>/dev/null || true
    if ! command -v uv >/dev/null 2>&1; then
      pip3 install uv --quiet 2>/dev/null || true
    fi
  fi

  if command -v uv >/dev/null 2>&1; then
    log "uv: $(uv --version) at $(which uv) ✔"
  else
    warn "uv not found system-wide — bench init may fall back to pip."
  fi
}

install_node() {
  header "Installing Node.js 20 & Yarn"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null || true
  apt-get install -y nodejs || err "nodejs install failed."
  npm install -g yarn --quiet 2>/dev/null || true
  log "Node $(node -v) and Yarn $(yarn -v) ready."
}

install_python() {
  local wanted_ver="$1"
  header "Installing Python ${wanted_ver}"
  export DEBIAN_FRONTEND=noninteractive

  apt-get install -y python3-venv python3-dev python3-pip 2>/dev/null || true

  if ! command -v "python${wanted_ver}" >/dev/null 2>&1; then
    log "python${wanted_ver} not found — adding deadsnakes PPA..."
    apt-get install -y software-properties-common 2>/dev/null || true
    add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
    apt-get update -y -qq 2>/dev/null || true
  fi

  apt-get install -y \
    "python${wanted_ver}" \
    "python${wanted_ver}-venv" \
    "python${wanted_ver}-dev" \
    2>/dev/null || true

  resolve_python "$wanted_ver"

  if "$PYTHON_BIN" -m venv --help >/dev/null 2>&1; then
    log "venv module confirmed working for ${PYTHON_BIN} ✔"
  else
    apt-get install -y python3-venv 2>/dev/null || true
    "$PYTHON_BIN" -m venv --help >/dev/null 2>&1 \
      || err "venv module not available for ${PYTHON_BIN}. Cannot continue."
  fi
}

setup_mariadb() {
  header "Configuring MariaDB"

  mkdir -p /etc/mysql/mariadb.conf.d
  cat > /etc/mysql/mariadb.conf.d/99-frappe.cnf <<'MARIAEOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
MARIAEOF

  log "Starting MariaDB..."
  if service mariadb start 2>/dev/null; then
    log "MariaDB started via service."
  elif service mysql start 2>/dev/null; then
    log "MariaDB started via mysql service."
  else
    mkdir -p /var/run/mysqld
    chown mysql:mysql /var/run/mysqld 2>/dev/null || true
    mysqld --user=mysql --datadir=/var/lib/mysql \
      --socket=/var/run/mysqld/mysqld.sock \
      --pid-file=/var/run/mysqld/mysqld.pid &>/dev/null &
    sleep 8
    log "MariaDB started directly (Docker fallback)."
  fi

  local attempts=0
  until mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; do
    sleep 2
    attempts=$((attempts + 1))
    log "Waiting for MariaDB... (${attempts}/15)"
    [[ $attempts -ge 15 ]] && err "MariaDB did not start after 30s."
  done

  log "Setting MariaDB root password..."
  mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null \
    || mysql -uroot -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_ROOT_PASSWORD}'); FLUSH PRIVILEGES;" 2>/dev/null \
    || true

  mysql -uroot -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1 \
    && log "MariaDB root password verified ✔" \
    || warn "MariaDB password verification inconclusive — continuing."
}

create_frappe_user() {
  header "Setting Up System User: ${FRAPPE_USER}"
  if ! id "$FRAPPE_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$FRAPPE_USER" || err "Failed to create user ${FRAPPE_USER}"
    log "User '${FRAPPE_USER}' created."
  else
    warn "User '${FRAPPE_USER}' already exists — skipping."
  fi

  echo "${FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${FRAPPE_USER}"
  chmod 440 "/etc/sudoers.d/${FRAPPE_USER}"

  local bashrc="/home/${FRAPPE_USER}/.bashrc"
  [[ ! -f "$bashrc" ]] && { cp /etc/skel/.bashrc "$bashrc" 2>/dev/null || touch "$bashrc"; }
  grep -q 'local/bin' "$bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$bashrc"

  mkdir -p "/home/${FRAPPE_USER}/.local/bin"
  chown -R "${FRAPPE_USER}:${FRAPPE_USER}" "/home/${FRAPPE_USER}"
  log "User '${FRAPPE_USER}' ready."
}

install_bench_cli() {
  header "Installing Bench CLI"
  [[ -z "$PYTHON_BIN" ]] && err "PYTHON_BIN not set — install_python() must run first."

  log "Using Python: ${PYTHON_BIN} (${PYTHON_VER})"

  local tmp_install
  tmp_install=$(mktemp /tmp/bench_install_XXXXXX.sh)
  chmod 700 "$tmp_install"
  cat > "$tmp_install" << INSTALLSCRIPT
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
export PIPX_HOME="\$HOME/.local/pipx"
export PIPX_BIN_DIR="\$HOME/.local/bin"

echo "[bench-cli] Python: ${PYTHON_BIN} (\$(${PYTHON_BIN} --version 2>&1))"

${PYTHON_BIN} -m venv --help >/dev/null 2>&1 \
  || { echo "[bench-cli] ERROR: venv module missing" >&2; exit 1; }

if ! command -v pipx >/dev/null 2>&1; then
  ${PYTHON_BIN} -m pip install --user pipx --quiet 2>/dev/null \
    || { echo "[bench-cli] ERROR: pipx install failed" >&2; exit 1; }
  export PATH="\$HOME/.local/bin:\$PATH"
fi

command -v pipx >/dev/null 2>&1 \
  || { echo "[bench-cli] ERROR: pipx not found after install" >&2; exit 1; }
echo "[bench-cli] pipx: \$(pipx --version)"

if pipx list 2>/dev/null | grep -q 'frappe-bench'; then
  pipx upgrade frappe-bench 2>/dev/null || true
else
  pipx install frappe-bench --python ${PYTHON_BIN} \
    || pipx install frappe-bench \
    || { echo "[bench-cli] ERROR: frappe-bench install failed" >&2; exit 1; }
fi

BENCH_PATH="\$HOME/.local/bin/bench"
[[ ! -x "\$BENCH_PATH" ]] && { echo "[bench-cli] ERROR: bench binary missing" >&2; exit 1; }
echo "[bench-cli] bench: \$(\$BENCH_PATH --version 2>/dev/null)"
grep -q 'local/bin' ~/.bashrc || echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc
echo "[bench-cli] Done ✔"
INSTALLSCRIPT

  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$tmp_install"
  su - "${FRAPPE_USER}" -c "bash $tmp_install"
  local rc=$?
  rm -f "$tmp_install"
  [[ $rc -ne 0 ]] && err "Bench CLI installation failed."
  log "Bench CLI ready."
}

init_bench() {
  local frappe_branch="version-16"
  local bench_path="/home/${FRAPPE_USER}/${BENCH_NAME}"

  header "Initialising Bench (Frappe v16 — ~10 min)"

  if [[ -d "$bench_path" ]]; then
    warn "Bench already exists at ${bench_path} — skipping."
    return 0
  fi

  [[ -z "$PYTHON_BIN" ]] && err "PYTHON_BIN not set."
  chown -R "${FRAPPE_USER}:${FRAPPE_USER}" "/home/${FRAPPE_USER}"

  su - "${FRAPPE_USER}" -c "
    yarn config set network-timeout 300000 2>/dev/null || true
    yarn config set registry https://registry.npmjs.org 2>/dev/null || true
  " 2>/dev/null || true

  local init_ok=false
  for attempt in 1 2 3; do
    log "Bench init attempt ${attempt}/3..."

    local tmp_init
    tmp_init=$(mktemp /tmp/bench_init_XXXXXX.sh)
    chmod 700 "$tmp_init"
    cat > "$tmp_init" << INITSCRIPT
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
BENCH_BIN="\$HOME/.local/bin/bench"
[[ ! -x "\$BENCH_BIN" ]] && { echo "ERROR: bench not found" >&2; exit 1; }
\$BENCH_BIN init \
  --frappe-branch ${frappe_branch} \
  --python ${PYTHON_BIN} \
  /home/${FRAPPE_USER}/${BENCH_NAME}
INITSCRIPT
    chown "${FRAPPE_USER}:${FRAPPE_USER}" "$tmp_init"
    su - "${FRAPPE_USER}" -c "bash $tmp_init"
    local rc=$?
    rm -f "$tmp_init"

    if [[ $rc -eq 0 ]]; then init_ok=true; break; fi
    warn "Bench init failed (attempt ${attempt}). Retrying in 15s..."
    rm -rf "${bench_path}" 2>/dev/null || true
    sleep 15
  done

  [[ "$init_ok" != "true" ]] && err "Bench init failed after 3 attempts."
  chown -R "${FRAPPE_USER}:${FRAPPE_USER}" "${bench_path}"
  log "Bench ready at ${bench_path}."
}

create_site() {
  header "Creating Site: ${SITE_NAME}"
  local bench_path="/home/${FRAPPE_USER}/${BENCH_NAME}"

  if [[ -d "${bench_path}/sites/${SITE_NAME}" ]]; then
    warn "Site '${SITE_NAME}' already exists — skipping."
    return 0
  fi

  local tmp
  tmp=$(mktemp /tmp/bench_newsite_XXXXXX.sh)
  chmod 700 "$tmp"
  cat > "$tmp" << SCRIPT
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
BENCH_BIN="\$HOME/.local/bin/bench"
[[ -z "\$BENCH_BIN" || ! -x "\$BENCH_BIN" ]] && BENCH_BIN=\$(command -v bench 2>/dev/null)
[[ -z "\$BENCH_BIN" ]] && { echo "ERROR: bench not found" >&2; exit 1; }
cd "/home/${FRAPPE_USER}/${BENCH_NAME}"
\$BENCH_BIN new-site "${SITE_NAME}" \
  --mariadb-root-password "${DB_ROOT_PASSWORD}" \
  --admin-password "${ADMIN_PASSWORD}" \
  --mariadb-user-host-login-scope='%'
SCRIPT
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$tmp"
  su - "${FRAPPE_USER}" -c "bash $tmp"
  local rc=$?
  rm -f "$tmp"
  [[ $rc -ne 0 ]] && err "bench new-site failed."
  log "Site '${SITE_NAME}' created."
  set_default_site
}

set_default_site() {
  log "Setting '${SITE_NAME}' as default site..."
  local tmp
  tmp=$(mktemp /tmp/bench_default_XXXXXX.sh)
  chmod 700 "$tmp"
  cat > "$tmp" << SCRIPT
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
BENCH_BIN="\$HOME/.local/bin/bench"
[[ ! -x "\$BENCH_BIN" ]] && BENCH_BIN=\$(command -v bench 2>/dev/null)
cd "/home/${FRAPPE_USER}/${BENCH_NAME}"
\$BENCH_BIN use "${SITE_NAME}"
echo "${SITE_NAME}" > sites/currentsite.txt
\$BENCH_BIN set-config -g serve_default_site true 2>/dev/null || true
SCRIPT
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$tmp"
  su - "${FRAPPE_USER}" -c "bash $tmp"
  rm -f "$tmp"
  log "Default site: ${SITE_NAME} ✔"
}

install_apps() {
  header "Installing Apps: ERPNext + Education (v16)"
  log "This takes 20-30 min — do NOT interrupt."

  # erpnext must be installed before education (education depends on it)
  local ordered_apps=("erpnext" "education")

  for app in "${ordered_apps[@]}"; do
    local url="${APP_URLS[$app]}"
    local branch="${APP_BRANCH[$app]}"
    log "━━━ ${app} (branch: ${branch}) ━━━"
    bench_cmd "get-app --branch ${branch} ${url}" \
      || warn "  get-app ${app} failed or already exists — continuing."
    bench_cmd "--site ${SITE_NAME} install-app ${app}" \
      || warn "  install-app ${app} had errors — may already be installed."
    log "  ✔ ${app} done."
  done

  log "ERPNext + Education installed."
}

setup_nginx_domain() {
  # Configures Nginx to proxy port 8000 → domain, with SSL via Certbot
  [[ -z "$DOMAIN" ]] && { warn "No DOMAIN set — skipping Nginx domain config."; return 0; }
  $IS_DOCKER && { warn "Docker mode — Nginx domain config skipped (handled on host)."; return 0; }

  header "Configuring Nginx for ${DOMAIN}"

  apt-get install -y certbot python3-certbot-nginx 2>/dev/null || true

  cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINXCONF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 50m;

    location / {
        proxy_pass         http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600;
    }

    location /socket.io {
        proxy_pass         http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_read_timeout 600;
    }
}
NGINXCONF

  ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}" 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  nginx -t && svc_restart nginx && log "Nginx configured for ${DOMAIN} ✔"

  log "Requesting SSL certificate for ${DOMAIN}..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    --email "admin@${DOMAIN}" \
    && log "SSL certificate issued ✔" \
    || warn "SSL failed — check DNS A record points to this server."
}

setup_production() {
  if $IS_DOCKER; then
    warn "Docker mode — skipping bench production setup (handled by entrypoint)."
    bench_cmd "--site ${SITE_NAME} set-config developer_mode 0" 2>/dev/null || true
    return 0
  fi
  header "Setting Up Production (Supervisor + Nginx)"
  bench_cmd "sudo bench setup production ${FRAPPE_USER} --yes"
  svc_enable nginx
  svc_enable supervisor
  svc_restart nginx
  svc_restart supervisor
  log "Production ready."
}

setup_firewall() {
  $IS_DOCKER && return 0
  header "Configuring Firewall"
  ufw --force enable
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 8000/tcp
  log "Firewall ready."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 2 — BACKUP
# ═══════════════════════════════════════════════════════════════════════════════

do_backup() {
  local site="$1"
  local bench_path="/home/${FRAPPE_USER}/${BENCH_NAME}"
  local timestamp; timestamp=$(date +%Y%m%d_%H%M%S)
  local dest="${BACKUP_DIR}/${site}/${timestamp}"
  mkdir -p "$dest"
  log "[$(date '+%Y-%m-%d %H:%M:%S')] Backing up: ${site}"

  local tmp; tmp=$(mktemp /tmp/bench_backup_XXXXXX.sh)
  chmod 700 "$tmp"
  cat > "$tmp" << SCRIPT
#!/usr/bin/env bash
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
BENCH_BIN="\$HOME/.local/bin/bench"
[[ ! -x "\$BENCH_BIN" ]] && BENCH_BIN=\$(command -v bench 2>/dev/null)
[[ -z "\$BENCH_BIN" ]] && { echo "ERROR: bench not found" >&2; exit 1; }
cd "${bench_path}"
\$BENCH_BIN --site ${site} backup --with-files
SCRIPT
  chown "${FRAPPE_USER}:${FRAPPE_USER}" "$tmp"
  su - "${FRAPPE_USER}" -c "bash $tmp" && log "Backup succeeded." || warn "Backup had warnings."
  rm -f "$tmp"

  local native="${bench_path}/sites/${site}/private/backups"
  if [[ -d "$native" ]]; then
    find "$native" -maxdepth 1 -type f -mmin -5 | while read -r f; do
      cp -n "$f" "$dest/" 2>/dev/null || true
    done
  fi
  find "${BACKUP_DIR}/${site}" -maxdepth 1 -mindepth 1 -type d \
    -mtime "+${BACKUP_KEEP_DAYS}" -exec rm -rf {} + 2>/dev/null || true
  log "Backup saved: ${dest}"
}

backup_all_sites() {
  require_root
  local bench_path="/home/${FRAPPE_USER}/${BENCH_NAME}"
  local sites=""
  sites=$(su - "${FRAPPE_USER}" -c "
    export PATH=\"\$HOME/.local/bin:\$PATH\"
    cd ${bench_path} && \$HOME/.local/bin/bench --list-sites 2>/dev/null
  " 2>/dev/null || echo "")
  [[ -z "$sites" ]] && sites="$SITE_NAME"
  for site in $sites; do do_backup "$site"; done
  log "All backups complete."
}

setup_backup_cron() {
  require_root
  local script_path; script_path=$(realpath "$0")
  header "Configuring Twice-Daily Backup Cron"
  crontab -l 2>/dev/null | grep -v "frappe_setup_backup" | crontab - 2>/dev/null || true
  (
    crontab -l 2>/dev/null
    echo "0 6  * * * root bash ${script_path} --backup-now >> /var/log/frappe_backup.log 2>&1  # frappe_setup_backup"
    echo "0 18 * * * root bash ${script_path} --backup-now >> /var/log/frappe_backup.log 2>&1  # frappe_setup_backup"
  ) | crontab -
  log "Cron set: 6 AM and 6 PM daily."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 3 — PROMPTS
# ═══════════════════════════════════════════════════════════════════════════════

prompt_install_vars() {
  header "Frappe v16 Setup — Configuration"
  detect_docker

  FRAPPE_VERSION="16"   # Hard-locked to v16
  FRAPPE_USER="${FRAPPE_USER:-frappe}"
  BENCH_NAME="${BENCH_NAME:-frappe-bench}"
  SITE_NAME="${SITE_NAME:-erp.local}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-}"
  DOMAIN="${DOMAIN:-playground.swayalgo.com}"
  BACKUP_DIR="/home/${FRAPPE_USER}/backups"

  local env_mode=false
  if [[ -n "$ADMIN_PASSWORD" && -n "$DB_ROOT_PASSWORD" ]]; then
    env_mode=true
    log "All required env vars found — skipping interactive prompts."
  fi

  if $env_mode; then
    [[ "$SITE_NAME" =~ [/[:space:]] ]] && err "SITE_NAME cannot contain slashes or spaces."
    [[ "$SITE_NAME" != *.* ]]          && err "SITE_NAME must contain a dot (e.g. erp.local)."
    [[ -z "$ADMIN_PASSWORD" ]]         && err "ADMIN_PASSWORD cannot be empty."
    [[ -z "$DB_ROOT_PASSWORD" ]]       && err "DB_ROOT_PASSWORD cannot be empty."
  else
    read -rp "Frappe system user [frappe]: " _u; FRAPPE_USER="${_u:-frappe}"
    BACKUP_DIR="/home/${FRAPPE_USER}/backups"
    read -rp "Bench name [frappe-bench]: " _b; BENCH_NAME="${_b:-frappe-bench}"

    while true; do
      read -rp "Site name (e.g. erp.local) [erp.local]: " _s
      SITE_NAME="${_s:-erp.local}"
      [[ "$SITE_NAME" =~ [/[:space:]] ]] && { warn "No slashes or spaces."; continue; }
      [[ "$SITE_NAME" != *.* ]]          && { warn "Must contain a dot."; continue; }
      break
    done

    while [[ -z "$ADMIN_PASSWORD" ]]; do
      read -rsp "Admin password: " ADMIN_PASSWORD; echo
      [[ -z "$ADMIN_PASSWORD" ]] && warn "Cannot be empty."
    done

    local _db_confirm=""
    while true; do
      read -rsp "Set MariaDB root password: " DB_ROOT_PASSWORD; echo
      read -rsp "Confirm: " _db_confirm; echo
      [[ -z "$DB_ROOT_PASSWORD" ]]            && { warn "Cannot be empty."; DB_ROOT_PASSWORD=""; continue; }
      [[ "$DB_ROOT_PASSWORD" != "$_db_confirm" ]] && { warn "Passwords do not match."; DB_ROOT_PASSWORD=""; continue; }
      break
    done

    read -rp "Domain [playground.swayalgo.com]: " _d
    DOMAIN="${_d:-playground.swayalgo.com}"
    read -rp "Proceed? (Y/n) [Y]: " _go
    [[ "$(to_lower "${_go:-y}")" == "n" ]] && { log "Aborted."; exit 0; }
  fi

  log ""
  log "Installation Summary:"
  echo "  ┌─────────────────────────────────────────"
  echo "  │  Frappe Version : v16"
  echo "  │  Apps           : ERPNext + Education"
  echo "  │  System User    : ${FRAPPE_USER}"
  echo "  │  Bench Name     : ${BENCH_NAME}"
  echo "  │  Site Name      : ${SITE_NAME}"
  echo "  │  Docker Mode    : ${IS_DOCKER}"
  echo "  │  Domain         : ${DOMAIN}"
  echo "  └─────────────────────────────────────────"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 4 — RUN INSTALL
# ═══════════════════════════════════════════════════════════════════════════════

run_install() {
  require_root
  prompt_install_vars

  # v16.15+ requires Python 3.14
  local wanted_py="3.14"

  install_dependencies
  install_node
  install_python "$wanted_py"
  setup_mariadb
  create_frappe_user
  install_bench_cli
  init_bench
  create_site
  install_apps
  setup_production
  setup_nginx_domain
  setup_firewall
  setup_backup_cron

  cat > /etc/frappe_setup.conf << CONF
FRAPPE_USER="${FRAPPE_USER}"
BENCH_NAME="${BENCH_NAME}"
SITE_NAME="${SITE_NAME}"
BACKUP_DIR="${BACKUP_DIR}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS}"
IS_DOCKER=${IS_DOCKER}
DOMAIN="${DOMAIN}"
CONF

  header "✅ Installation Complete"
  echo -e "  ${BOLD}Site URL  :${RESET} http://${SITE_NAME}:8000"
  echo -e "  ${BOLD}Domain    :${RESET} https://${DOMAIN}"
  echo -e "  ${BOLD}Username  :${RESET} Administrator"
  echo -e "  ${BOLD}Password  :${RESET} ${ADMIN_PASSWORD}"
  echo -e "  ${BOLD}Bench     :${RESET} /home/${FRAPPE_USER}/${BENCH_NAME}"
  echo -e "  ${BOLD}Backups   :${RESET} ${BACKUP_DIR}  (6 AM & 6 PM daily)"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  SECTION 5 — MENU & ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

main_menu() {
  header "Frappe v16 Setup  (ERPNext + Education)"
  echo "  1)  Install Frappe v16 + ERPNext + Education"
  echo "  2)  Setup Backup Schedule (twice daily)"
  echo "  3)  Run Backup Now"
  echo "  4)  Exit"
  echo ""
  read -rp "Choose an option [1-4]: " choice
  case "$choice" in
    1) run_install ;;
    2) setup_backup_cron ;;
    3) backup_all_sites ;;
    4) exit 0 ;;
    *) warn "Invalid option."; echo ""; main_menu ;;
  esac
}

CONFIG_FILE="/etc/frappe_setup.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

case "${1:-}" in
  --install)      run_install ;;
  --backup-now)   backup_all_sites ;;
  --setup-cron)   setup_backup_cron ;;
  *)              main_menu ;;
esac