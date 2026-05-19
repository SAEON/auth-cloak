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
systemctl enable snapd
systemctl start snapd
snap install core
snap refresh core
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

Copy `.env.example` and fill in the required values before running `deploy.sh`:

```bash
cp .env.example .env
nano .env
chmod 600 .env
```

Set at minimum:

```
KC_HOSTNAME=<hostname>.example.org
SSL_CERT_DIR=/etc/letsencrypt/live/<hostname>.example.org
ADMIN_ALLOWED_CIDR=<your-lan-or-vpn-subnet>   # e.g. 10.0.0.0/24
```

`deploy.sh` will auto-generate strong random secrets for `POSTGRES_PASSWORD` and `KC_BOOTSTRAP_ADMIN_PASSWORD` on first run. The remaining variables:

| Variable | Description |
|---|---|
| `KC_HOSTNAME` | Public hostname (e.g. `auth.example.org`) — must match the SSL certificate CN |
| `SSL_CERT_DIR` | Path to certbot cert directory (e.g. `/etc/letsencrypt/live/<hostname>`) |
| `ADMIN_ALLOWED_CIDR` | Primary CIDR allowed to reach `/admin` — set to your LAN/VPN subnet |
| `ADMIN_ALLOWED_CIDR_2` | Optional second CIDR (defaults to `127.0.0.1`) |
| `POSTGRES_PASSWORD` | Auto-generated if missing; record it |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | Auto-generated if missing; used only on first start |
| `BACKUP_DIR` | Where `backup.sh` writes `.dump.gz` files (default `/opt/apps/auth-cloak/backups`) |

> `deploy.sh` checks that `fullchain.pem`, `privkey.pem`, and `chain.pem` exist in `SSL_CERT_DIR` before starting. See [ssl/README.md](../ssl/README.md) for the certbot renewal hook setup.

## 4. Run `deploy.sh`

> This is the step where Docker builds and starts everything. Do not run it before the SSL cert exists.

```bash
sudo -E bash scripts/deploy.sh
```

The script:
1. Checks Docker, Compose, and openssl are installed
2. Replaces any `CHANGE_ME` password placeholders in `.env` with generated secrets (prints bootstrap credentials)
3. Validates SSL certs exist
4. Creates the backup directory
5. Builds the optimized Keycloak image (`docker compose build --no-cache keycloak`)
6. Pulls PostgreSQL and Nginx images
7. Starts all containers (`docker compose up -d`)
8. Waits up to 240 s for Keycloak's health endpoint to respond
9. Prints the admin console URL and next steps

Expected healthy output:

```
NAME                    IMAGE                        STATUS
auth-cloak-postgres     postgres:16-alpine           Up (healthy)
auth-cloak-keycloak     auth-cloak/keycloak:26.1.2   Up (healthy)
auth-cloak-nginx        nginx:1.27-alpine            Up (healthy)
```

## 5. Post-deploy admin console steps

Connect from your LAN or VPN (external access to `/admin` is blocked by Nginx).

### 5a. Change the bootstrap admin password

1. Open `https://auth.example.org/admin`
2. Log in with the bootstrap credentials printed by `deploy.sh`
3. Top-right menu → **Manage account** → **Password** → change it
4. Record the new password in your password manager

### 5b. Create a permanent admin account

1. Admin console → **Master** realm → **Users** → **Create user**
2. Set username, email; **Save**
3. **Credentials** tab → set a strong password, mark as temporary = off
4. **Required actions** → add **Configure OTP** (enforces TOTP on next login)
5. Log out, log back in as the new account, complete TOTP setup

### 5c. Disable the bootstrap account

1. **Users** → find the bootstrap admin user
2. **Details** tab → toggle **Enabled** to off → **Save**

### 5d. Require SSL on custom realms

For both `saeon-internal` and `saeon-external`:

1. Select the realm in the top-left dropdown
2. **Realm settings** → **General** → **Require SSL** → set to **All requests** → **Save**

### 5e. Add built-in client scopes to `saeon-external`

Keycloak's built-in scopes (`profile`, `email`, `roles`, `web-origins`) are not created by realm JSON import — they exist only in the master realm by default. Add them manually:

1. Select **saeon-external** realm
2. **Client scopes** → **Create client scope** for each: `profile`, `email`, `roles`, `web-origins`
   - Or: navigate to **Clients** → select a client → **Client scopes** tab → **Add client scope** → choose the built-in ones from the list (they may already appear if KC created them automatically)

Alternatively, verify from the admin CLI:

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh get client-scopes \
  --server http://localhost:8080 \
  --realm saeon-external \
  --user admin
```

## 6. Set up backup cron

```bash
crontab -e
```

Add:

```
0 2 * * * /opt/apps/auth-cloak/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1
```

Backups are written to `BACKUP_DIR` (default `/opt/apps/auth-cloak/backups`) as gzipped pg_dump files named `keycloak_YYYYMMDD_HHMMSS.dump.gz`. Files older than `BACKUP_RETENTION_DAYS` (default 30) are deleted automatically.

## 7. Configure Docker log rotation

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
docker compose up -d   # bring containers back up
```

## 8. Enable Keycloak event logging

1. Admin console → select a realm → **Events** → **Config** tab
2. Toggle **Save events** on
3. Set expiration to **90 days**
4. **Save**

Repeat for both `saeon-internal` and `saeon-external`.

---

## Operations reference

### Backup

```bash
bash scripts/backup.sh
```

### Restore

```bash
bash scripts/restore.sh /opt/apps/auth-cloak/backups/keycloak_20260401_020000.dump.gz
```

**Warning:** drops and recreates the Keycloak database. Prompts for confirmation. Stops Keycloak first, restores, then restarts it.

### Keycloak version upgrade

```bash
bash scripts/update-keycloak.sh 26.2.0
```

The script takes a pre-upgrade backup, updates `Dockerfile.keycloak`, rebuilds the image, and restarts only the Keycloak container (PostgreSQL stays up). Always read the [Keycloak migration notes](https://www.keycloak.org/docs/latest/upgrading/) first — the script prompts you to confirm you have.

### SSL certificate renewal

Let's Encrypt certs auto-renew via `certbot`. After renewal, reload Nginx without downtime:

```bash
docker compose exec nginx nginx -s reload
```

To automate this after every certbot renewal, see the deploy hook instructions in [ssl/README.md](../ssl/README.md).

### View logs

```bash
docker compose logs -f keycloak
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

# OIDC discovery reachable
curl https://auth.example.org/realms/saeon-external/.well-known/openid-configuration

# Admin blocked from internet (must return 403)
curl -I https://auth.example.org/admin

# Metrics blocked (must return 403)
curl https://auth.example.org/metrics

# Security headers present
curl -I https://auth.example.org/realms/saeon-external/account
# Expect: Strict-Transport-Security, X-Content-Type-Options, X-Frame-Options
```
