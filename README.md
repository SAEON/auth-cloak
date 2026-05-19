# auth-cloak

A production-ready Keycloak 26 deployment for SAEON, providing centralised authentication for internal staff applications and public-facing data portals. All components run in Docker containers on a single host: Nginx handles TLS termination and access control, Keycloak manages identity and token issuance, and PostgreSQL provides persistent storage — all isolated from each other via Docker networks.

- [Architecture](docs/architecture.md) — stack, network diagram, realm design, security layers
- [Deployment runbook](docs/deployment.md) — first-time setup, post-deploy steps, operations reference

---

## Realms

| Realm | Audience | Registration | Notes |
|---|---|---|---|
| `saeon-internal` | SAEON staff | Admin-provisioned | Staff email domain only; no email verification; permanent lockout; 8h SSO |
| `saeon-external` | External researchers + guests | Open self-registration | No email verification; T&C required; 30-day idle session |

The **master** realm is used only for Keycloak administration — never for application authentication.

### `saeon-external` user profile

Fields collected at registration:

| Field | Required | Type |
|---|---|---|
| First name | Yes | Text |
| Last name | Yes | Text |
| Email | Yes | Text |
| Institution | Yes | Text |
| Are you a student? | No | Select: `yes` / `no` / `na` |
| Age group | No | Select: `under-18` … `65+` |
| Race | No | Free text |
| Gender | No | Free text |

All fields (plus `user_type`) are included in access tokens via the `saeon-profile` scope.

> **Note on built-in scopes:** Keycloak's built-in client scopes (`profile`, `email`, `roles`, `web-origins`) are not created automatically during realm JSON import. After first deploy, add them manually in Admin UI → saeon-external → Client scopes, or assign them to each client individually. See the [deployment runbook](docs/deployment.md#5e-add-built-in-client-scopes-to-saeon-external) for details.

---

## Local development (WSL)

### 1. Generate SSL certs and configure `.env`

```bash
# Create certs using the same filenames as prod
sudo mkdir -p /etc/letsencrypt/live/localhost
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/letsencrypt/live/localhost/privkey.pem \
  -out /etc/letsencrypt/live/localhost/fullchain.pem \
  -subj "/CN=localhost"
sudo cp /etc/letsencrypt/live/localhost/fullchain.pem /etc/letsencrypt/live/localhost/chain.pem

# Configure .env
cp .env.example .env
sed -i 's|KC_HOSTNAME=.*|KC_HOSTNAME=localhost|' .env
sed -i 's|SSL_CERT_DIR=.*|SSL_CERT_DIR=/etc/letsencrypt/live/localhost|' .env
```

### 2. Start the stack

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

The local override sets `KC_HOSTNAME_STRICT=false` and `ADMIN_ALLOWED_CIDR=0.0.0.0/0` (no IP restriction on admin).

### 3. Verify containers are healthy

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml ps
```

All three containers (`postgres`, `keycloak`, `nginx`) should show `Up (healthy)`. Keycloak can take up to 2 minutes on first start.

### 4. Access from Windows (Chrome)

Keycloak requires HTTPS. To access from a Windows browser while running in WSL:

1. Find your WSL IP: `ip addr show eth0 | grep 'inet '`
2. Open Chrome at `https://<wsl-ip>` (accept the self-signed cert warning)
3. Admin console: `https://<wsl-ip>/admin`

### 5. Stop the stack

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml down
```

---

## Configuration

All configuration is in `.env` (gitignored). Copy `.env.example` and fill in values.

| Variable | Description | Example |
|---|---|---|
| `POSTGRES_DB` | Database name | `keycloak` |
| `POSTGRES_USER` | DB username | `keycloak` |
| `POSTGRES_PASSWORD` | DB password — generate with `openssl rand -base64 32` | |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | Initial admin username — effective on first start only | `admin` |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | Initial admin password — change immediately after first login | |
| `KC_HOSTNAME` | Public hostname — must match your SSL cert | `auth.example.org` |
| `ADMIN_ALLOWED_CIDR` | Primary CIDR allowed to reach `/admin` — set to your LAN/VPN subnet | `10.0.0.0/24` |
| `ADMIN_ALLOWED_CIDR_2` | Optional second CIDR (e.g. VPN range) — defaults to `127.0.0.1` | `10.8.0.0/24` |
| `SSL_CERT_DIR` | Host path containing `fullchain.pem`, `privkey.pem`, `chain.pem` | `/etc/letsencrypt/live/auth.example.org` |
| `BACKUP_DIR` | Where backup files are written | `/opt/apps/auth-cloak/backups` |
| `BACKUP_RETENTION_DAYS` | Backup files older than this are deleted | `30` |
| `SMTP_HOST` | SMTP server for password-reset emails | |
| `SMTP_PORT` | SMTP port | `587` |
| `SMTP_USER` | SMTP username | |
| `SMTP_PASSWORD` | SMTP password | |
| `SMTP_FROM` | Sender address | `no-reply@example.org` |

> SMTP is optional at deploy time. Until configured, password reset emails will not be sent. When available, set the variables and configure the SMTP settings in Admin UI → Realm Settings → Email.

### SSL certificates

Production certificates are managed by the Linux admin via Let's Encrypt. The Nginx container mounts them directly from the host:

```
/etc/letsencrypt/live/<KC_HOSTNAME>/fullchain.pem
/etc/letsencrypt/live/<KC_HOSTNAME>/privkey.pem
/etc/letsencrypt/live/<KC_HOSTNAME>/chain.pem
```

`KC_HOSTNAME` in `.env` must match the Let's Encrypt directory name. See [ssl/README.md](ssl/README.md) for the certbot renewal hook setup.

---

## Client integration

### Which realm to use

| App type | Realm |
|---|---|
| Internal staff tools | `saeon-internal` |
| Public data portals, catalogue | `saeon-external` |

### OIDC discovery URLs

```
https://auth.example.org/realms/saeon-internal/.well-known/openid-configuration
https://auth.example.org/realms/saeon-external/.well-known/openid-configuration
```

### Registering a client (Admin UI)

1. Select the target realm
2. **Clients** → **Create client**
3. Client type: `OpenID Connect`
4. Client ID: choose a short, app-specific name (e.g. `saeon-catalogue`)
5. **Standard flow**: enabled; **Direct access grants**: disabled
6. Set **Valid redirect URIs** and **Web origins** to your app's exact URL — no wildcards in production
7. Add `saeon-profile` to **Default client scopes** for any external-realm client that needs demographic claims

### Browser apps (React, Vue, etc.) — Authorization Code + PKCE

```js
import Keycloak from 'keycloak-js'

const kc = new Keycloak({
  url: 'https://auth.example.org',
  realm: 'saeon-external',
  clientId: 'saeon-catalogue',
})

// Restores existing session silently; redirects to login only when the app calls kc.login()
await kc.init({ onLoad: 'check-sso', silentCheckSsoRedirectUri: window.location.origin + '/silent-check-sso.html' })
```

Trigger login on a protected action (e.g. download button):

```js
if (!kc.authenticated) {
  kc.login({ redirectUri: window.location.href })
  return
}
await kc.updateToken(30)   // refresh if within 30s of expiry
const token = kc.token     // Bearer token for API calls
```

### Backend API token validation

Validate the JWT before serving protected resources:

1. Fetch public keys: `https://auth.example.org/realms/saeon-external/protocol/openid-connect/certs`
2. Verify the JWT signature and expiry
3. Extract claims from the verified payload

Common libraries: `python-jose` (Python), `jsonwebtoken` (Node.js), `java-jwt` (Java).

### Token claims (`saeon-profile` scope)

```json
{
  "sub": "<user-uuid>",
  "email": "user@example.com",
  "given_name": "Jane",
  "family_name": "Doe",
  "institution": "University of Example",
  "user_type": "guest",
  "student_status": "no",
  "age_group": "25-34",
  "race": "...",
  "gender": "..."
}
```

---

## Operations

```bash
# Backup
bash scripts/backup.sh

# Restore (drops + recreates DB — prompts for confirmation)
bash scripts/restore.sh /opt/apps/auth-cloak/backups/keycloak_20260401_020000.dump.gz

# Upgrade Keycloak (reads migration notes prompt, takes pre-upgrade backup)
bash scripts/update-keycloak.sh 26.2.0

# View logs
docker compose logs -f keycloak
docker compose logs -f nginx

# Reload Nginx config (e.g. after cert renewal — no downtime)
docker compose exec nginx nginx -s reload

# Container status
docker compose ps
```

---

## Security

### Admin access

The Nginx config restricts `/admin` and `/realms/master` to `ADMIN_ALLOWED_CIDR` and `ADMIN_ALLOWED_CIDR_2` (your LAN/VPN subnets). All other sources receive HTTP 403 before the request reaches Keycloak. Update these values in `.env` and run `docker compose up -d nginx` if the subnet changes.

### Post-deploy checklist

- [ ] Change bootstrap admin password immediately after first login
- [ ] Create permanent admin user with TOTP (2FA) enforced
- [ ] Disable/delete bootstrap admin account
- [ ] Confirm `/admin` returns 403 from an external IP
- [ ] Set **Require SSL = All requests** on both custom realms
- [ ] Enable event logging (Admin UI → Events → Config → Save Events ON, 90-day expiry)
- [ ] Set up backup cron: `0 2 * * * /opt/apps/auth-cloak/scripts/backup.sh >> /var/log/auth-cloak-backup.log 2>&1`
- [ ] Configure Docker log rotation in `/etc/docker/daemon.json`
- [ ] Register application clients with explicit redirect URIs (no wildcards)
- [ ] Configure SMTP when available

### Secrets management

- `.env` is gitignored — never commit it
- SSL certs live at `SSL_CERT_DIR` on the host (outside the repo) — never committed
- `deploy.sh` generates secrets with `openssl rand` on first run
- Rotate `POSTGRES_PASSWORD` and `KC_BOOTSTRAP_ADMIN_PASSWORD` by updating `.env` and redeploying

---

## Troubleshooting

**Keycloak container stays unhealthy**

```bash
docker compose logs keycloak | tail -50
```

Common causes: PostgreSQL not yet ready (wait a bit and retry), wrong `KC_HOSTNAME` (must match the host nginx uses), missing environment variables.

**`invalid_scope` on token request**

Built-in scopes (`profile`, `email`, `roles`, `web-origins`) were not created during import. Add them in Admin UI → Client scopes, then assign to the client.

**403 on `/admin` from within the LAN**

Check `ADMIN_ALLOWED_CIDR` in `.env` matches your actual LAN/VPN subnet. After changing it, redeploy Nginx: `docker compose up -d nginx`.

**SSL certificate errors**

Verify the cert covers the hostname in `KC_HOSTNAME`. Check the files exist in `SSL_CERT_DIR`:

```bash
ls -la $SSL_CERT_DIR
# fullchain.pem, privkey.pem, chain.pem must all be present
```

**`SMTP_FROM_DISPLAY_NAME` causes bash error**

The value must be quoted in `.env`:

```
SMTP_FROM_DISPLAY_NAME="SAEON Auth"
```

**Password reset emails not sending**

SMTP is not configured. Set `SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD` in `.env`, then configure Realm Settings → Email in Admin UI.
