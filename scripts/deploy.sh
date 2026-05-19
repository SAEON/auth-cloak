#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auth-cloak first-time deployment script
#
# Usage:
#   sudo -E bash scripts/deploy.sh
#
# Run as root (or with sudo) so Docker can be managed. The -E flag preserves
# environment variables set before sudo (e.g. BACKUP_DIR overrides).
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
docker compose version    >/dev/null 2>&1 || error "Docker Compose plugin not found (need docker compose, not docker-compose)"
command -v openssl        >/dev/null 2>&1 || error "openssl not installed"

# ── .env setup ────────────────────────────────────────────────────────────────
step ".env configuration"

if [[ ! -f .env ]]; then
    warn ".env not found — copying from .env.example"
    cp .env.example .env
    chmod 600 .env
    # Return ownership to the calling user so non-root docker commands work
    [[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}:${SUDO_USER}" .env
fi

# Replace any remaining CHANGE_ME password placeholders with generated secrets
if grep -q "CHANGE_ME_strong_random_password" .env; then
    PG_PASS=$(openssl rand -base64 40 | tr -dc 'a-zA-Z0-9!@#$%^*' | head -c 48)
    KC_PASS=$(openssl rand -base64 40 | tr -dc 'a-zA-Z0-9!@#$%^*' | head -c 48)

    sed -i "0,/CHANGE_ME_strong_random_password/s//${PG_PASS}/" .env
    sed -i "0,/CHANGE_ME_strong_random_password/s//${KC_PASS}/" .env

    info "Generated secrets for POSTGRES_PASSWORD and KC_BOOTSTRAP_ADMIN_PASSWORD."
    echo ""
    echo -e "  ${BOLD}Bootstrap admin credentials (record these now):${NC}"
    echo -e "  Username: $(grep KC_BOOTSTRAP_ADMIN_USERNAME .env | cut -d= -f2)"
    echo -e "  Password: ${KC_PASS}"
    echo ""
    warn "Change the admin password immediately after first login."
    warn "Create a real admin user, then disable the bootstrap account."
else
    info ".env already has secrets — skipping secret generation."
fi

# Load env for validation steps
set -o allexport
source .env
set +o allexport

# ── Prompt for hostname if still a placeholder ────────────────────────────────
if [[ "$KC_HOSTNAME" == "CHANGE_ME"* ]]; then
    read -rp "Enter the public hostname for this Keycloak instance (e.g. auth.example.org): " KC_HOSTNAME
    [[ -n "$KC_HOSTNAME" ]] || error "Hostname cannot be empty."
    sed -i "s|KC_HOSTNAME=.*|KC_HOSTNAME=${KC_HOSTNAME}|" .env
    info "KC_HOSTNAME set to ${KC_HOSTNAME}."
fi

# ── Derive SSL_CERT_DIR from hostname if still a placeholder ──────────────────
if [[ "$SSL_CERT_DIR" == *"CHANGE_ME"* ]]; then
    SSL_CERT_DIR="/etc/letsencrypt/live/${KC_HOSTNAME}"
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

# ── Build Keycloak image ──────────────────────────────────────────────────────
step "Building optimized Keycloak image"
docker compose build --no-cache keycloak
info "Keycloak image built."

# ── Pull remaining images ─────────────────────────────────────────────────────
step "Pulling PostgreSQL and Nginx images"
docker compose pull postgres nginx

# ── Start stack ───────────────────────────────────────────────────────────────
step "Starting stack"
docker compose up -d --remove-orphans
info "Containers started."

# ── Wait for Keycloak health ──────────────────────────────────────────────────
step "Waiting for Keycloak to be ready"
MAX_WAIT=240
ELAPSED=0
until [[ "$(docker inspect --format='{{.State.Health.Status}}' auth-cloak-keycloak 2>/dev/null)" == "healthy" ]]; do
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        error "Keycloak did not become healthy within ${MAX_WAIT}s.
       Check logs: docker compose logs keycloak"
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
info "Admin console (LAN only): https://${KC_HOSTNAME}/admin"
info "External realm account:   https://${KC_HOSTNAME}/realms/saeon-external/account"
info "Internal realm account:   https://${KC_HOSTNAME}/realms/saeon-internal/account"
echo ""
warn "Next steps:"
echo "  1. Log into the admin console from your LAN/VPN"
echo "  2. Change the bootstrap admin password"
echo "  3. Create a permanent admin user with TOTP (2FA) enforced"
echo "  4. Disable/delete the bootstrap admin account"
echo "  5. Set Require SSL = all on both custom realms"
echo "  6. Register application clients in the appropriate realm"
echo "  7. Add backup cron: 0 2 * * * $(pwd)/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1"
echo "  8. Configure SMTP in Admin UI when available (for password reset emails)"
