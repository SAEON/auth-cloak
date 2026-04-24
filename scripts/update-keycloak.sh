#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Safe Keycloak version upgrade.
#
# Usage:
#   bash scripts/update-keycloak.sh 26.2.0
#
# Always read the Keycloak migration guide before running:
#   https://www.keycloak.org/docs/latest/upgrading/
#
# The script will:
#   1. Take a pre-upgrade database backup
#   2. Update the version in Dockerfile.keycloak
#   3. Rebuild the optimized image
#   4. Restart Keycloak with the new image (PostgreSQL stays up)
#   5. Wait for health check
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

NEW_VERSION="${1:-}"
[[ -n "$NEW_VERSION" ]] || { echo "Usage: $0 <new-version>  e.g. $0 26.2.0"; exit 1; }

CURRENT_VERSION=$(grep -oP '(?<=keycloak:)\d+\.\d+\.\d+' "$REPO_DIR/Dockerfile.keycloak" | head -1)

echo ""
echo -e "${BOLD}Keycloak upgrade: ${CURRENT_VERSION} → ${NEW_VERSION}${NC}"
echo ""
warn "Read the migration notes before proceeding:"
echo "  https://www.keycloak.org/docs/latest/upgrading/"
echo ""
read -rp "Have you reviewed the migration notes? (yes/no): " READ_NOTES
[[ "$READ_NOTES" == "yes" ]] || { echo "Please review migration notes first."; exit 1; }

# ── Pre-upgrade backup ────────────────────────────────────────────────────────
step "Pre-upgrade backup"
bash "$SCRIPT_DIR/backup.sh"

# ── Update Dockerfile ─────────────────────────────────────────────────────────
step "Updating Dockerfile.keycloak to ${NEW_VERSION}"
sed -i "s|quay.io/keycloak/keycloak:[0-9][0-9.]*|quay.io/keycloak/keycloak:${NEW_VERSION}|g" \
    "$REPO_DIR/Dockerfile.keycloak"
info "Dockerfile.keycloak updated."

# ── Rebuild image ─────────────────────────────────────────────────────────────
step "Rebuilding optimized Keycloak image"
docker compose -f "$REPO_DIR/docker-compose.yml" build --no-cache keycloak

# ── Restart Keycloak only (PostgreSQL stays up) ───────────────────────────────
step "Restarting Keycloak with new image"
docker compose -f "$REPO_DIR/docker-compose.yml" up -d --no-deps keycloak

# ── Wait for health ───────────────────────────────────────────────────────────
step "Waiting for Keycloak health"
MAX_WAIT=240
ELAPSED=0
until docker compose -f "$REPO_DIR/docker-compose.yml" exec -T keycloak \
        curl -sf http://localhost:9000/health/ready >/dev/null 2>&1; do
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        error "Keycloak failed health check within ${MAX_WAIT}s.
       Check:  docker compose logs keycloak
       Restore: bash scripts/restore.sh <backup_file>"
    fi
    printf "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo ""

step "Upgrade complete"
docker compose -f "$REPO_DIR/docker-compose.yml" ps
info "Keycloak is now running version ${NEW_VERSION}."
