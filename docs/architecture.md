# Architecture

auth-cloak is a containerised Ory Kratos deployment. All components run as Docker services on a single host, managed by Docker Compose.

## Stack

| Component | Image | Role |
|---|---|---|
| Ory Kratos v1.3 | `oryd/kratos:v1.3` | Identity engine — login, session management, identity schema |
| PostgreSQL 16 | `postgres:16-alpine` | Persistent identity and session storage |
| Nginx 1.27 | `nginx:1.27-alpine` | TLS termination, reverse proxy |

## Network diagram

```
Internet / clients (FDS PWA)
       │
       ▼ 80 / 443
   ┌─────────┐
   │  Nginx  │   ← TLS termination, rate limiting
   └────┬────┘   frontend network
        │ http://kratos:4433  (Public API — Native flows)
        ▼
   ┌──────────┐
   │  Kratos  │   ← Identity engine, session tokens, identity schema
   └────┬─────┘   frontend + backend networks
        │ postgres://postgres:5432/kratos
        ▼
   ┌──────────┐
   │ Postgres │   ← backend network (internal: true — no internet route)
   └──────────┘

FDS API (Server 2) ──── LAN ────▶ port 4434 on Server 1
                                   (Kratos Admin API — bound to LAN IP, never proxied)
```

## Docker networks

| Network | Type | Members |
|---|---|---|
| `frontend` | bridge (routable) | Nginx, Kratos |
| `backend` | bridge + `internal: true` | Kratos, PostgreSQL |

`internal: true` means PostgreSQL has no route to or from the internet or the Docker host. It is reachable only by Kratos on the `backend` network.

## Port exposure

| Service | Port | Bound to host | Reachable by |
|---|---|---|---|
| Nginx | 80, 443 | Yes — public-facing | Internet |
| Kratos Public API | 4433 | No — `expose:` only | Nginx (via Docker network) |
| Kratos Admin API | 4434 | Yes — LAN IP only | FDS API (Server 2) over LAN |
| PostgreSQL | 5432 | No — internal network | Kratos only |

## Two APIs — different trust levels

Kratos exposes two separate HTTP APIs. This distinction is the most important security boundary in the system.

| | Public API (:4433) | Admin API (:4434) |
|---|---|---|
| Who calls it | FDS PWA directly | FDS API (server-to-server, LAN only) |
| Auth required | No — this is how login itself works | No built-in auth — trust is enforced by network isolation |
| Exposure | Proxied through Nginx under `/identity/` | Bound to LAN IP, never proxied through Nginx |
| If exposed publicly | Expected — intended design | Anyone could create, modify, or delete any identity |

**The Admin API (port 4434) must never appear in any Nginx location block and must never be reachable from the public internet.** Network isolation and the UFW rule restricting access to the FDS server LAN IP are the only protection.

## Native (API-only) flows

Kratos is used exclusively in Native mode. Unlike OIDC browser flows, Native flows are pure JSON REST calls:

1. PWA calls `GET /identity/self-service/login/api` → Kratos returns a flow ID
2. PWA calls `POST /identity/self-service/login?flow=<id>` with `{method: "password", identifier, password}` → Kratos returns a session token
3. PWA attaches the session token as `Authorization: Bearer <token>` on every FDS API request
4. FDS API validates the token by calling `GET /sessions/whoami` on the Admin API (LAN)

No browser redirects. No cross-domain query strings. The WAF signature (Fortinet rule 60140003) never triggers.

## Identity schema

FDS uses a single identity schema (`fds-identity`) with three fields:

| Field | Required | Type | Notes |
|---|---|---|---|
| `email` | Yes | string (email format) | Login identifier |
| `name` | No | string | Full name |
| `role` | Yes | enum | `technician`, `technician_lead`, `data_manager` |

User accounts are admin-provisioned only (self-registration is disabled). New accounts are created via the Admin API by the FDS API on behalf of authorised `data_manager` and `technician_lead` users.

## Security layers

```
Client request
    │
    ▼
[Nginx]
  - TLS 1.2+ with strong cipher suite
  - HSTS (2 years + preload)
  - Security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy)
  - Rate limiting: 5 r/s on /identity/ endpoints
  - All other paths → 404
    │
    ▼
[Kratos Public API — port 4433]
  - Native-only flows (no browser redirects)
  - Argon2 password hashing
  - Session token lifespan: 24h
  - Self-registration: disabled
    │
    ▼
[PostgreSQL]
  - Internal Docker network (no internet route)
  - Password-authenticated connections only
```
