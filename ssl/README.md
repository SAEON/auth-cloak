# SSL Certificates

## Production

Certificates are obtained via Let's Encrypt using certbot. Run certbot **before** `deploy.sh` — it needs port 80 free.

```bash
# Obtain EAB_KID and EAB_HMAC_KEY from IT — do not commit these values
certbot certonly --standalone --non-interactive --agree-tos \
  --email <admin-email> \
  --server https://acme.sectigo.com/v2/OV \
  --eab-kid <EAB_KID> \
  --eab-hmac-key <EAB_HMAC_KEY> \
  --domain <hostname>.example.org \
  --cert-name <hostname>.example.org
```

Certbot places the certs at `/etc/letsencrypt/live/auth.example.org/`. The Nginx container mounts that directory directly:

```
/etc/letsencrypt/live/<KRATOS_HOSTNAME>/fullchain.pem   ← certificate + intermediates
/etc/letsencrypt/live/<KRATOS_HOSTNAME>/privkey.pem      ← private key
/etc/letsencrypt/live/<KRATOS_HOSTNAME>/chain.pem        ← intermediates only (for OCSP stapling)
```

Set `SSL_CERT_DIR=/etc/letsencrypt/live/<KRATOS_HOSTNAME>` in `.env` — this must match the certbot directory name exactly. `deploy.sh` checks for all three files before starting.

### Certificate renewal

Let's Encrypt certs auto-renew via `certbot`. After renewal, reload Nginx without downtime:

```bash
docker compose exec nginx nginx -s reload
```

To automate the reload after certbot renewal, add a deploy hook in `/etc/letsencrypt/renewal-hooks/deploy/`:

```bash
#!/usr/bin/env bash
cd /opt/apps/auth-cloak && docker compose exec nginx nginx -s reload
```

```bash
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

---

## Local development (WSL)

For local testing, generate a self-signed certificate and point `SSL_CERT_DIR` at it — the same env var used in prod:

```bash
sudo mkdir -p /etc/letsencrypt/live/localhost
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/letsencrypt/live/localhost/privkey.pem \
  -out    /etc/letsencrypt/live/localhost/fullchain.pem \
  -subj "/CN=localhost"
sudo cp /etc/letsencrypt/live/localhost/fullchain.pem /etc/letsencrypt/live/localhost/chain.pem
```

Then in `.env`:

```
KRATOS_HOSTNAME=localhost
SSL_CERT_DIR=/etc/letsencrypt/live/localhost
```
