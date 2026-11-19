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

HOOK_URL="${KRATOS_HOOK_URL:-https://${FDS_HOSTNAME}/api/hooks/login}"

cat > kratos/config/kratos.hooks.yml <<EOF
selfservice:
  flows:
    login:
      after:
        password:
          hooks:
            - hook: web_hook
              config:
                url: ${HOOK_URL}
                method: POST
                auth:
                  type: api_key
                  config:
                    name: X-Hook-Token
                    value: ${KRATOS_HOOK_SECRET}
                    in: header
                body: file:///etc/config/kratos/hooks/login-event.jsonnet
EOF
chmod 644 kratos/config/kratos.hooks.yml

docker compose up -d "$@"
