#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Restore the Kratos PostgreSQL database from a backup file.
#
# Usage:
#   bash scripts/restore.sh /path/to/kratos_20260401_020000.dump.gz
#
# WARNING: This drops and recreates the Kratos database.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE="docker compose -f $REPO_DIR/docker-compose.yml"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }

[[ -f "$REPO_DIR/.env" ]] || error ".env not found at $REPO_DIR/.env"
set -o allexport
source "$REPO_DIR/.env"
set +o allexport

BACKUP_FILE="${1:-}"
[[ -n "$BACKUP_FILE" ]] || { echo "Usage: $0 /path/to/backup.dump.gz"; exit 1; }
[[ -f "$BACKUP_FILE" ]] || error "Backup file not found: $BACKUP_FILE"

echo ""
warn "This will DROP and RECREATE the '${POSTGRES_DB}' database."
warn "All current Kratos identity data will be replaced by the backup."
echo "Backup file: ${BACKUP_FILE}"
echo ""
read -rp "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

info "Stopping Kratos (if running)..."
$COMPOSE stop kratos 2>/dev/null || true

info "Ensuring PostgreSQL is running..."
$COMPOSE up -d postgres
until $COMPOSE exec -T postgres \
        env PGPASSWORD="${POSTGRES_PASSWORD}" \
        pg_isready -U "${POSTGRES_USER}" -d postgres >/dev/null 2>&1; do
    echo -n "."
    sleep 2
done
echo ""

info "Dropping database '${POSTGRES_DB}'..."
$COMPOSE exec -T postgres \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    dropdb -U "${POSTGRES_USER}" --if-exists "${POSTGRES_DB}"

info "Creating database '${POSTGRES_DB}'..."
$COMPOSE exec -T postgres \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    createdb -U "${POSTGRES_USER}" -O "${POSTGRES_USER}" "${POSTGRES_DB}"

info "Restoring from ${BACKUP_FILE}..."
gunzip -c "$BACKUP_FILE" | \
    $COMPOSE exec -T postgres \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    pg_restore \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DB}" \
        --no-password \
        --exit-on-error

info "Restarting Kratos..."
$COMPOSE start kratos

echo ""
info "Restore complete. Monitor startup with:"
echo "  docker compose logs -f kratos"
