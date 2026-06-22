# Deployment Runbook

Step-by-step guide for a first-time production deployment of auth-cloak on Ubuntu 24.04.

## Pre-requisites

On the server:

```bash
# Docker Engine + Compose plugin
curl -fsSL https://get.docker.com | sh
docker compose version   # must show v2.x

# openssl (for secret generation in deploy.sh)
apt-get install -y openssl

# UFW rules — allow only what's needed
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

## 1. Clone the repository

```bash
git clone https://github.com/SAEON/auth-cloak.git /opt/apps/auth-cloak
cd /opt/apps/auth-cloak
```

## 2. Install certbot and generate SSL certificate

Certificates are obtained via Let's Encrypt using certbot. Run this **before** `deploy.sh` — certbot needs port 80 free (nginx is not running yet).

```bash
# Install certbot
apt install snapd -y
ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
systemctl enable snapd && systemctl start snapd
snap install core && snap refresh core
snap install --classic certbot
ln -s /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true

# Generate certificate — replace <hostname> and obtain EAB credentials from IT
certbot certonly --standalone --non-interactive --agree-tos \
  --email <admin-email> \
  --server https://acme.sectigo.com/v2/OV \
  --eab-kid <EAB_KID> \
  --eab-hmac-key <EAB_HMAC_KEY> \
  --domain <hostname>.example.org \
  --cert-name <hostname>.example.org
```

Certbot places the certs at `/etc/letsencrypt/live/<hostname>.example.org/`.

## 3. Configure `.env`

```bash
cp .env.example .env
nano .env
chmod 600 .env
```

Set at minimum:

```
KRATOS_HOSTNAME=<hostname>.example.org
FDS_HOSTNAME=<fds-hostname>.example.org
SSL_CERT_DIR=/etc/letsencrypt/live/<hostname>.example.org
KRATOS_ADMIN_BIND_IP=<server-lan-ip>
```

`deploy.sh` auto-generates strong secrets for `POSTGRES_PASSWORD`, `KRATOS_COOKIE_SECRET`, and `KRATOS_CIPHER_SECRET` on first run.

| Variable | Description |
|---|---|
| `KRATOS_HOSTNAME` | Public hostname of this auth server — must match the SSL cert CN |
| `FDS_HOSTNAME` | Hostname of the FDS app — used for CORS allowed origins |
| `KRATOS_ADMIN_BIND_IP` | Server's internal LAN IP — Admin API (port 4434) is bound here for FDS API access |
| `SSL_CERT_DIR` | Path to certbot cert directory (e.g. `/etc/letsencrypt/live/<hostname>`) |
| `POSTGRES_PASSWORD` | Auto-generated if missing; record it |
| `KRATOS_COOKIE_SECRET` | Auto-generated if missing; changing invalidates all active sessions |
| `KRATOS_CIPHER_SECRET` | Auto-generated if missing; changing invalidates encrypted data |
| `BACKUP_DIR` | Where `backup.sh` writes `.dump.gz` files (default `/opt/apps/auth-cloak/backups`) |

> `deploy.sh` checks that `fullchain.pem`, `privkey.pem`, and `chain.pem` exist in `SSL_CERT_DIR` before starting. See [ssl/README.md](../ssl/README.md) for the certbot renewal hook setup.

## 4. Run `deploy.sh`

> Do not run this before the SSL cert exists.

```bash
sudo -E bash scripts/deploy.sh
```

The script:
1. Checks Docker, Compose, and openssl are installed
2. Replaces any `CHANGE_ME` placeholders in `.env` with generated secrets
3. Validates SSL certs exist
4. Creates the backup directory
5. Pulls PostgreSQL, Kratos, and Nginx images
6. Starts PostgreSQL and waits for it to be ready
7. Runs Kratos database migrations (`kratos migrate sql`)
8. Starts all containers
9. Waits up to 120 s for Kratos health endpoint to respond
10. Prints the public API URL and next steps

Expected healthy output:

```
NAME                    IMAGE                  STATUS
auth-cloak-postgres     postgres:16-alpine     Up (healthy)
auth-cloak-kratos       oryd/kratos:v1.3       Up (healthy)
auth-cloak-nginx        nginx:1.27-alpine      Up (healthy)
```

## 5. Seed the first data_manager account

No user accounts exist after a fresh deploy. Create the first `data_manager` from Server 1 using the Admin API:

```bash
curl -s -X POST http://127.0.0.1:4434/admin/identities \
  -H "Content-Type: application/json" \
  -d '{
    "schema_id": "fds-identity",
    "traits": {
      "email": "<admin-email>",
      "name": "<Admin Name>",
      "role": "data_manager"
    },
    "credentials": {
      "password": {
        "config": { "password": "<strong-password>" }
      }
    }
  }'
```

Test it by initiating a Native login flow:

```bash
# Step 1: get flow ID
FLOW=$(curl -s https://<hostname>.example.org/identity/self-service/login/api | jq -r '.id')

# Step 2: submit credentials
curl -s -X POST "https://<hostname>.example.org/identity/self-service/login?flow=${FLOW}" \
  -H "Content-Type: application/json" \
  -d '{"method":"password","identifier":"<admin-email>","password":"<strong-password>"}' \
  | jq '.session_token'
```

A non-null session token confirms login works.

## 6. Allow FDS server to reach the Admin API

The Admin API is bound to `KRATOS_ADMIN_BIND_IP` (the server's LAN IP). Allow only the FDS server's LAN IP to reach it:

```bash
sudo ufw allow from <fds-server-lan-ip> to any port 4434
```

Confirm the FDS API can reach it:

```bash
# Run from FDS server (Server 2)
curl -s http://<auth-server-lan-ip>:4434/health/ready
# → {"status":"ok"}
```

## 7. Set up backup cron

```bash
crontab -e
```

Add:

```
0 2 * * * /opt/apps/auth-cloak/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1
```

Backups are written to `BACKUP_DIR` as gzipped pg_dump files named `kratos_YYYYMMDD_HHMMSS.dump.gz`. Files older than `BACKUP_RETENTION_DAYS` (default 30) are deleted automatically.

## 8. Configure Docker log rotation

Create or edit `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
```

Then restart Docker:

```bash
systemctl restart docker
docker compose up -d
```

---

## Operations reference

### Backup

```bash
bash scripts/backup.sh
```

### Restore

```bash
bash scripts/restore.sh /opt/apps/auth-cloak/backups/kratos_20260401_020000.dump.gz
```

Drops and recreates the Kratos database. Prompts for confirmation.

### Create a user account (Admin API)

```bash
curl -s -X POST http://127.0.0.1:4434/admin/identities \
  -H "Content-Type: application/json" \
  -d '{"schema_id":"fds-identity","traits":{"email":"<email>","name":"<name>","role":"technician"},"credentials":{"password":{"config":{"password":"<password>"}}}}'
```

### List all identities

```bash
curl -s http://127.0.0.1:4434/admin/identities | jq '.[].traits'
```

### Kratos version upgrade

```bash
# Edit docker-compose.yml: change oryd/kratos:v1.3 to the new version
docker compose pull kratos
docker compose up -d kratos
docker compose logs -f kratos   # watch for startup errors
```

Always check the [Kratos changelog](https://github.com/ory/kratos/releases) for breaking changes before upgrading.

### SSL certificate renewal

Let's Encrypt certs auto-renew via `certbot`. After renewal, reload Nginx without downtime:

```bash
docker compose exec nginx nginx -s reload
```

To automate this after every certbot renewal, see the deploy hook instructions in [ssl/README.md](../ssl/README.md).

### View logs

```bash
docker compose logs -f kratos
docker compose logs -f nginx
docker compose logs -f postgres
```

### Container status

```bash
docker compose ps
```

---

## Verification checklist

Run these after every deployment:

```bash
# All containers healthy
docker compose ps

# HTTP redirects to HTTPS
curl -I http://auth.example.org/

# Kratos Public API reachable
curl https://auth.example.org/identity/health/ready
# → {"status":"ok"}

# Native login flow initialises (no redirect)
curl -s https://auth.example.org/identity/self-service/login/api | jq '.type'
# → "api"

# Admin API not reachable via Nginx (must return 404)
curl -I https://auth.example.org/identity/admin/identities

# Catch-all returns 404
curl -I https://auth.example.org/

# Security headers present
curl -I https://auth.example.org/identity/health/ready
# Expect: Strict-Transport-Security, X-Content-Type-Options, X-Frame-Options
```
