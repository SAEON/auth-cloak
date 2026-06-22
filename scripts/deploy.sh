#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auth-cloak first-time deployment script
#
# Usage:
#   sudo -E bash scripts/deploy.sh
#
# Run as root (or with sudo) so Docker can be managed. The -E flag preserves
# environment variables set before sudo.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

cd "$REPO_DIR"

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "Pre-flight checks"

command -v docker         >/dev/null 2>&1 || error "Docker not installed"
docker compose version    >/dev/null 2>&1 || error "Docker Compose plugin not found"
command -v openssl        >/dev/null 2>&1 || error "openssl not installed"

# ── .env setup ────────────────────────────────────────────────────────────────
step ".env configuration"

if [[ ! -f .env ]]; then
    warn ".env not found — copying from .env.example"
    cp .env.example .env
    chmod 600 .env
    [[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}:${SUDO_USER}" .env
fi

# Replace any remaining CHANGE_ME password placeholders with generated secrets
if grep -q "CHANGE_ME_strong_random_password" .env; then
    PG_PASS=$(openssl rand -hex 32)
    sed -i "0,/CHANGE_ME_strong_random_password/s//${PG_PASS}/" .env
    info "Generated POSTGRES_PASSWORD."
fi

if grep -q "CHANGE_ME_cookie_secret" .env; then
    sed -i "s/CHANGE_ME_cookie_secret/$(openssl rand -hex 32)/" .env
    info "Generated KRATOS_COOKIE_SECRET."
fi

if grep -q "CHANGE_ME_cipher_secret" .env; then
    sed -i "s/CHANGE_ME_cipher_secret/$(openssl rand -hex 32)/" .env
    info "Generated KRATOS_CIPHER_SECRET."
fi

# Load env for validation steps
set -o allexport
source .env
set +o allexport

# ── Prompt for hostnames if still placeholders ────────────────────────────────
if [[ "$KRATOS_HOSTNAME" == "CHANGE_ME"* ]]; then
    read -rp "Enter the public hostname for this auth server (e.g. auth.example.org): " KRATOS_HOSTNAME
    [[ -n "$KRATOS_HOSTNAME" ]] || error "Hostname cannot be empty."
    sed -i "s|KRATOS_HOSTNAME=.*|KRATOS_HOSTNAME=${KRATOS_HOSTNAME}|" .env
    info "KRATOS_HOSTNAME set to ${KRATOS_HOSTNAME}."
fi

if [[ "$FDS_HOSTNAME" == "CHANGE_ME"* ]]; then
    read -rp "Enter the FDS app hostname (e.g. fds.example.org): " FDS_HOSTNAME
    [[ -n "$FDS_HOSTNAME" ]] || error "FDS hostname cannot be empty."
    sed -i "s|FDS_HOSTNAME=.*|FDS_HOSTNAME=${FDS_HOSTNAME}|" .env
    info "FDS_HOSTNAME set to ${FDS_HOSTNAME}."
fi

# ── Derive SSL_CERT_DIR from hostname if still a placeholder ──────────────────
if [[ "$SSL_CERT_DIR" == *"CHANGE_ME"* ]]; then
    SSL_CERT_DIR="/etc/letsencrypt/live/${KRATOS_HOSTNAME}"
    sed -i "s|SSL_CERT_DIR=.*|SSL_CERT_DIR=${SSL_CERT_DIR}|" .env
    info "SSL_CERT_DIR set to ${SSL_CERT_DIR}."
fi

# ── SSL certificates ──────────────────────────────────────────────────────────
step "SSL certificate check"
[[ -f "${SSL_CERT_DIR}/fullchain.pem" ]] || error "SSL cert not found: ${SSL_CERT_DIR}/fullchain.pem"
[[ -f "${SSL_CERT_DIR}/privkey.pem"   ]] || error "SSL key not found: ${SSL_CERT_DIR}/privkey.pem"
[[ -f "${SSL_CERT_DIR}/chain.pem"     ]] || error "SSL chain not found: ${SSL_CERT_DIR}/chain.pem"
info "SSL certs found at ${SSL_CERT_DIR}."

# ── Backup directory ──────────────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/opt/apps/auth-cloak/backups}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
info "Backup directory: $BACKUP_DIR"

# ── Pull images ───────────────────────────────────────────────────────────────
step "Pulling images"
docker compose pull postgres kratos nginx

# ── Start PostgreSQL ──────────────────────────────────────────────────────────
step "Starting PostgreSQL"
docker compose up -d postgres
info "Waiting for PostgreSQL to be ready..."
until docker compose exec -T postgres \
        env PGPASSWORD="${POSTGRES_PASSWORD}" \
        pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; do
    printf "."
    sleep 2
done
echo ""
info "PostgreSQL ready."

# ── Run Kratos migrations ─────────────────────────────────────────────────────
step "Running Kratos database migrations"
docker compose run --rm kratos migrate sql -e --yes
info "Migrations complete."

# ── Start remaining services ──────────────────────────────────────────────────
step "Starting Kratos and Nginx"
docker compose up -d --remove-orphans
info "Containers started."

# ── Wait for Kratos health ────────────────────────────────────────────────────
step "Waiting for Kratos to be ready"
MAX_WAIT=120
ELAPSED=0
until [[ "$(docker inspect --format='{{.State.Health.Status}}' auth-cloak-kratos 2>/dev/null)" == "healthy" ]]; do
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        error "Kratos did not become healthy within ${MAX_WAIT}s.
       Check logs: docker compose logs kratos"
    fi
    printf "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
step "Deployment complete"
docker compose ps
echo ""
info "Public API:  https://${KRATOS_HOSTNAME}/identity/"
info "Health:      https://${KRATOS_HOSTNAME}/identity/health/ready"
echo ""
warn "Next steps:"
echo "  1. Seed the first data_manager account:"
echo "     curl -s -X POST http://127.0.0.1:4434/admin/identities \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"schema_id\":\"fds-identity\",\"traits\":{\"email\":\"<email>\",\"name\":\"<name>\",\"role\":\"data_manager\"},\"credentials\":{\"password\":{\"config\":{\"password\":\"<strong-password>\"}}}}"
echo "  2. Allow FDS server LAN IP to reach Admin API:"
echo "     sudo ufw allow from <fds-server-lan-ip> to any port 4434"
echo "  3. Update KRATOS_ADMIN_BIND_IP in .env to the server's LAN IP, then redeploy nginx"
echo "  4. Set up backup cron: 0 2 * * * $(pwd)/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1"
