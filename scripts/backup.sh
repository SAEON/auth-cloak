#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PostgreSQL backup — dumps the Keycloak database to a compressed file.
#
# Usage:
#   bash scripts/backup.sh [/optional/backup/dir]
#
# Cron example (daily at 02:00):
#   0 2 * * * /opt/auth-cloak/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
[[ -f "$REPO_DIR/.env" ]] || { echo "[ERROR] .env not found at $REPO_DIR/.env"; exit 1; }
set -o allexport
source "$REPO_DIR/.env"
set +o allexport

BACKUP_DIR="${1:-${BACKUP_DIR:-/opt/auth-cloak/backups}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/keycloak_${TIMESTAMP}.dump.gz"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "[$(date -Iseconds)] Starting backup → ${BACKUP_FILE}"

docker compose -f "$REPO_DIR/docker-compose.yml" exec -T postgres \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    pg_dump \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DB}" \
        --format=custom \
        --no-password \
    | gzip > "$BACKUP_FILE"

BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || echo 0)
if [[ "$BACKUP_SIZE" -lt 1024 ]]; then
    echo "[ERROR] Backup file is suspiciously small (${BACKUP_SIZE} bytes). Removing."
    rm -f "$BACKUP_FILE"
    exit 1
fi

chmod 600 "$BACKUP_FILE"
echo "[$(date -Iseconds)] Backup complete: ${BACKUP_FILE} ($(du -sh "$BACKUP_FILE" | cut -f1))"

echo "[$(date -Iseconds)] Pruning backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "keycloak_*.dump.gz" -mtime "+${RETENTION_DAYS}" -delete -print

echo "[$(date -Iseconds)] Done."
