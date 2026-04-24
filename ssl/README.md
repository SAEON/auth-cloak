# SSL Certificates

Place the admin-supplied TLS certificate files in this directory before running `scripts/deploy.sh`.

## Required filenames

| File | Description |
|---|---|
| `authcloak.crt` | Full certificate chain (server cert + intermediates) |
| `authcloak.key` | Private key |

If your Linux admin provided files with different names, either rename them or update `nginx/conf.d/authcloak.conf` to match:

```nginx
ssl_certificate     /etc/nginx/ssl/your-cert-name.crt;
ssl_certificate_key /etc/nginx/ssl/your-key-name.key;
```

## Permissions

```bash
chmod 644 ssl/authcloak.crt
chmod 640 ssl/authcloak.key
sudo chown root:docker ssl/authcloak.key
```

## Certificate renewal

When your Linux admin provides renewed certificates, replace the files in this directory and reload nginx without downtime:

```bash
docker compose exec nginx nginx -s reload
```

## Security note

Both files are gitignored and must never be committed to source control.
