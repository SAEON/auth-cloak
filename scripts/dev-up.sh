#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

[[ -f .env ]] || { echo "No .env file found. Copy .env.example and fill in values."; exit 1; }

set -o allexport
source .env
set +o allexport

cat > kratos/config/kratos.secrets.yml <<EOF
secrets:
  cookie:
    - ${KRATOS_COOKIE_SECRET}
  cipher:
    - ${KRATOS_CIPHER_SECRET}
EOF
chmod 644 kratos/config/kratos.secrets.yml

docker compose up -d "$@"
