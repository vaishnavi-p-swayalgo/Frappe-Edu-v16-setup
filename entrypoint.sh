#!/usr/bin/env bash
# =============================================================================
#  entrypoint.sh  v4.0
#  Frappe v16 — ERPNext + Education
#  Fresh install on first boot. No backup restore.
#
#  Boot sequence:
#  1. Run installer (first boot only)
#  2. Start MariaDB
#  3. Start Redis (system + bench instances)
#  4. Set default site
#  5. Start cron (backup schedule)
#  6. Start bench (keeps container alive)
# =============================================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[ENTRYPOINT]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ENTRYPOINT]${RESET} $*"; }
err()  { echo -e "${RED}[ENTRYPOINT]${RESET} $*" >&2; exit 1; }

# ─── Bash guard ───────────────────────────────────────────────────────────────
if [ -z "${BASH_VERSION}" ]; then
  echo "[ENTRYPOINT] FATAL: Must run under bash, not sh." >&2
  exit 1
fi

# ─── Env vars ─────────────────────────────────────────────────────────────────
FRAPPE_USER="${FRAPPE_USER:-frappe}"
BENCH_NAME="${BENCH_NAME:-frappe-bench}"
SITE_NAME="${SITE_NAME:-erp.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin@1234}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-frappe@1234}"
FRAPPE_VERSION="16"
DOMAIN="${DOMAIN:-playground.swayalgo.com}"

BENCH_PATH="/home/${FRAPPE_USER}/${BENCH_NAME}"
INSTALL_FLAG="/home/${FRAPPE_USER}/.frappe_installed"

# ─── Export so frappe_setup.sh inherits ───────────────────────────────────────
export FRAPPE_VERSION FRAPPE_USER BENCH_NAME SITE_NAME
export ADMIN_PASSWORD DB_ROOT_PASSWORD DOMAIN

# ─── Validate ─────────────────────────────────────────────────────────────────
[[ -z "$ADMIN_PASSWORD" ]]   && err "ADMIN_PASSWORD is not set. Check your .env file."
[[ -z "$DB_ROOT_PASSWORD" ]] && err "DB_ROOT_PASSWORD is not set. Check your .env file."

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  Frappe v16 — ERPNext + Education"
log "  FRAPPE_USER  = ${FRAPPE_USER}"
log "  BENCH_NAME   = ${BENCH_NAME}"
log "  SITE_NAME    = ${SITE_NAME}"
log "  DOMAIN       = ${DOMAIN}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Step 1: Install (first boot only) ────────────────────────────────────────
if [[ ! -f "$INSTALL_FLAG" ]]; then
  log "First boot — running Frappe v16 installer (30-40 min)..."
  bash /frappe_setup.sh --install
  INSTALL_RC=$?
  [[ $INSTALL_RC -ne 0 ]] && err "Installation FAILED (exit ${INSTALL_RC}). Check logs above."
  touch "$INSTALL_FLAG"
  log "Installation complete ✔"
else
  log "Already installed — skipping install step."
fi

# ─── Step 2: Start MariaDB ────────────────────────────────────────────────────
log "Starting MariaDB..."
if service mariadb start 2>/dev/null; then
  log "MariaDB started via service."
elif service mysql start 2>/dev/null; then
  log "MariaDB started (mysql service)."
else
  mkdir -p /var/run/mysqld
  chown mysql:mysql /var/run/mysqld 2>/dev/null || true
  mysqld --user=mysql --datadir=/var/lib/mysql \
    --socket=/var/run/mysqld/mysqld.sock &>/dev/null &
  sleep 6
  log "MariaDB started directly (fallback)."
fi

local_attempts=0
until mysql -uroot -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; do
  sleep 2
  local_attempts=$((local_attempts + 1))
  log "Waiting for MariaDB... (${local_attempts}/15)"
  if [[ $local_attempts -ge 15 ]]; then
    warn "MariaDB not responding after 30s — continuing anyway."
    break
  fi
done
log "MariaDB ready."

# ─── Step 3: Start Redis ──────────────────────────────────────────────────────
log "Starting system Redis..."
service redis-server start 2>/dev/null || true

log "Clearing stale bench Redis processes..."
for port in 13000 11000 13001; do
  pid=$(lsof -ti tcp:${port} 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    log "  Killed stale Redis on port ${port}"
  fi
done
sleep 1

log "Starting bench Redis instances..."
for conf in redis_cache.conf redis_queue.conf redis_socketio.conf; do
  conf_path="${BENCH_PATH}/config/${conf}"
  if [[ -f "$conf_path" ]]; then
    redis-server "$conf_path" --daemonize yes 2>/dev/null || true
    log "  Started: ${conf}"
  fi
done
sleep 3

cache_attempts=0
until redis-cli -p 13000 ping 2>/dev/null | grep -q PONG; do
  sleep 2
  cache_attempts=$((cache_attempts + 1))
  log "Waiting for Redis cache... (${cache_attempts}/10)"
  if [[ $cache_attempts -ge 10 ]]; then
    warn "Redis cache not responding — bench may have issues."
    break
  fi
done
log "Redis ready."

# ─── Step 4: Set default site ─────────────────────────────────────────────────
log "Setting default site: ${SITE_NAME}..."
if [[ -d "${BENCH_PATH}/sites/${SITE_NAME}" ]]; then
  su - "${FRAPPE_USER}" -c "
    export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"
    cd ${BENCH_PATH}
    \$HOME/.local/bin/bench use ${SITE_NAME} 2>/dev/null || true
    echo '${SITE_NAME}' > sites/currentsite.txt
    \$HOME/.local/bin/bench set-config -g serve_default_site true 2>/dev/null || true
  " 2>/dev/null || true
  log "Default site: ${SITE_NAME} ✔"
else
  warn "Site directory not found — skipping."
fi

# ─── Step 5: Release Redis ports (bench start manages its own) ────────────────
log "Releasing Redis ports for bench start..."
for port in 13000 11000 13001; do
  pid=$(lsof -ti tcp:${port} 2>/dev/null || true)
  [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; }
done
sleep 1
log "Redis ports released."

# ─── Step 6: Start cron ───────────────────────────────────────────────────────
log "Starting cron for automatic backups..."
service cron start 2>/dev/null || true
bash /frappe_setup.sh --setup-cron
log "Backup cron active (6 AM and 6 PM IST daily) ✔"

# ─── Step 7: Start bench ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  ✅ Frappe v16 is starting up!${RESET}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Local URL :${RESET}  http://localhost:8000"
echo -e "  ${BOLD}Domain    :${RESET}  https://${DOMAIN}"
echo -e "  ${BOLD}Username  :${RESET}  Administrator"
echo -e "  ${BOLD}Password  :${RESET}  ${ADMIN_PASSWORD}"
echo -e "  ${BOLD}Site      :${RESET}  ${SITE_NAME}"
echo -e "  ${BOLD}Apps      :${RESET}  ERPNext + Education"
echo ""
echo -e "  ${YELLOW}Wait ~15 seconds after bench starts for the UI to load.${RESET}"
echo ""

su - "${FRAPPE_USER}" -c "
  export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"
  cd ${BENCH_PATH}
  bench start
"