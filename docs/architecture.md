# Architecture

auth-cloak is a containerised Keycloak 26 deployment. All components run as Docker services on a single host, managed by Docker Compose.

## Stack

| Component | Image | Role |
|---|---|---|
| Keycloak 26.1 | `quay.io/keycloak/keycloak:26.1.2` (custom build) | Identity provider |
| PostgreSQL 16 | `postgres:16-alpine` | Persistent realm and session storage |
| Nginx 1.27 | `nginx:1.27-alpine` | TLS termination, reverse proxy, access control |

## Network diagram

```
Internet / clients
       │
       ▼ 80 / 443
   ┌─────────┐
   │  Nginx  │   ← TLS termination, rate limiting, admin IP restriction
   └────┬────┘   frontend network
        │ http://keycloak:8080
        ▼
   ┌──────────┐
   │ Keycloak │   ← Identity provider, realm logic, token issuance
   └────┬─────┘   frontend + backend networks
        │ jdbc:postgresql://postgres:5432/keycloak
        ▼
   ┌──────────┐
   │ Postgres │   ← backend network (internal: true — no internet route)
   └──────────┘
```

## Docker networks

| Network | Type | Members |
|---|---|---|
| `frontend` | bridge (routable) | Nginx, Keycloak |
| `backend` | bridge + `internal: true` | Keycloak, PostgreSQL |

`internal: true` means PostgreSQL has no route to or from the internet or the Docker host. It is reachable only by Keycloak on the `backend` network.

## Port exposure

| Service | Ports | Bound to host |
|---|---|---|
| Nginx | 80 (HTTP), 443 (HTTPS) | Yes — public-facing |
| Keycloak | 8080 (app), 9000 (management) | No — `expose:` only, container-to-container |
| PostgreSQL | 5432 | No — internal network, no host binding |

## Realm design

Two realms serve distinct audiences. The master realm is admin-only and never used for application authentication.

| Realm | Audience | Registration | Email verification | Lockout |
|---|---|---|---|---|
| `saeon-internal` | SAEON staff | Admin-provisioned only | Required on first login | Permanent (admin must unlock) |
| `saeon-external` | External researchers + self-registered guests | Open self-registration | Disabled | Temporary (900s, resets after 12h) |

### Why two realms?

- **Different security postures** — internal staff require stricter passwords (12 chars, 180-day expiry, history), permanent lockout, and no self-registration.
- **Separate session lifetimes** — internal: 8h SSO; external: 30-day idle.
- **Clean scope separation** — clients in each realm inherit only that realm's roles and scopes.
- **Independent brute-force config** — tightening internal policy does not affect external users.

## Custom OIDC claims

The `saeon-profile` client scope is added to all `saeon-external` clients by default. It exposes user attributes as JWT claims:

| Claim | User attribute | Notes |
|---|---|---|
| `institution` | `institution` | Required at registration |
| `user_type` | `user_type` | `guest` (default) or `external-user`; admin-editable |
| `student_status` | `student_status` | Select: `yes`, `no`, `na`; optional |
| `age_group` | `age_group` | Select: `under-18` … `65+`; optional |
| `race` | `race` | Free text; optional |
| `gender` | `gender` | Free text; optional |

All claims appear in the ID token, access token, and userinfo endpoint.

## Security layers

```
Client request
    │
    ▼
[Nginx]
  - TLS 1.2+ with strong cipher suite
  - HSTS (2 years + preload)
  - Security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy, Permissions-Policy)
  - /admin and /realms/master: allow LAN/VPN only, deny all others (HTTP 403)
  - /metrics: deny all
  - Rate limiting: 20 r/s global, 5 r/s token/login, 2 r/s admin
    │
    ▼
[Keycloak]
  - Brute-force protection per realm
  - Access token TTL: 5 min
  - Required actions: Terms & Conditions, profile completion
  - X-Forwarded-* headers trusted only from Docker bridge range (nginx only)
    │
    ▼
[PostgreSQL]
  - Internal Docker network (no internet route)
  - Password-authenticated connections only
  - Connection pool: 5–50 connections
```

## Keycloak build

A two-stage Docker build produces an optimized image:

```dockerfile
# Stage 1 — Quarkus augmentation (resolves all classpath at build time)
FROM quay.io/keycloak/keycloak:26.1.2 AS builder
ENV KC_DB=postgres
RUN /opt/keycloak/bin/kc.sh build

# Stage 2 — Runtime image (only compiled quarkus artifacts copied)
FROM quay.io/keycloak/keycloak:26.1.2
COPY --from=builder /opt/keycloak/lib/quarkus/ /opt/keycloak/lib/quarkus/
CMD ["start", "--optimized", "--import-realm"]
```

`--optimized` skips the Quarkus build step at startup (already baked in). `--import-realm` auto-imports realm JSON files from `/opt/keycloak/data/import/` on first start; existing realms are skipped on subsequent starts.
