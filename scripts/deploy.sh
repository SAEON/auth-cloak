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
    warn ".env not found — generating from .env.example with random secrets"
    cp .env.example .env

    PG_PASS=$(openssl rand -base64 40 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 48)
    KC_PASS=$(openssl rand -base64 40 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 48)

    # Replace the two CHANGE_ME placeholders (first = PG, second = KC)
    sed -i "0,/CHANGE_ME_strong_random_password/s//${PG_PASS}/" .env
    sed -i "0,/CHANGE_ME_strong_random_password/s//${KC_PASS}/" .env

    chmod 600 .env
    info ".env created with generated secrets."
    echo ""
    echo -e "  ${BOLD}Bootstrap admin credentials (record these now):${NC}"
    echo -e "  Username: $(grep KC_BOOTSTRAP_ADMIN_USERNAME .env | cut -d= -f2)"
    echo -e "  Password: $(grep KC_BOOTSTRAP_ADMIN_PASSWORD .env | cut -d= -f2)"
    echo ""
    warn "Change the admin password immediately after first login."
    warn "Create a real admin user, then disable the bootstrap account."
else
    info ".env already exists — skipping secret generation."
fi

# Load env for validation steps
set -o allexport
source .env
set +o allexport

# ── SSL certificates ──────────────────────────────────────────────────────────
step "SSL certificate check"

[[ -f ssl/authcloak.crt ]] || error "ssl/authcloak.crt not found. See ssl/README.md."
[[ -f ssl/authcloak.key ]] || error "ssl/authcloak.key not found. See ssl/README.md."

chmod 644 ssl/authcloak.crt
chmod 640 ssl/authcloak.key
info "SSL certs found and permissions set."

# ── Backup directory ──────────────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/opt/auth-cloak/backups}"
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
until docker compose exec -T keycloak curl -sf http://localhost:9000/health/ready >/dev/null 2>&1; do
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
echo "  1. Log into the admin console from the LAN (192.168.117.x)"
echo "  2. Change the bootstrap admin password"
echo "  3. Create a permanent admin user with TOTP (2FA) enforced"
echo "  4. Disable/delete the bootstrap admin account"
echo "  5. Set Require SSL = all on both custom realms"
echo "  6. Register application clients in the appropriate realm"
echo "  7. Add backup cron: 0 2 * * * $(pwd)/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1"
echo "  8. Configure SMTP in Admin UI when available (for password reset emails)"
