# dokku-login-auth

Authentication front-end for [Dokku](https://dokku.com/) apps: form login + SSO
for UIs and static API-key authentication for APIs, with per-app/per-path
granularity. It is implemented purely through Dokku's per-app nginx
`nginx.conf.d/` include mechanism plus this custom Dokku plugin. No Dokku core
changes, no per-path proxying `location` blocks, no duplicated `proxy_pass` /
`proxy_set_header` directives.

The plugin is a Bash Dokku plugin named `login-auth`.

> Full design and requirements: see the
> [cloudbox-auth SPEC](https://github.com/lbovet/cloudbox-auth/pull/2).

## Overview

For each protected app the plugin generates:

- `login-auth-00-internal.conf` — a fixed `auth_request` target
  (`/internal/login-auth/authz`) that branches on the request's resolved mode,
  the mode-aware `@login_auth_redirect__<app>` named location, and an
  exact-match `/400-error.html` location that turns an Authelia `401`
  `Location` into the portal redirect (Dokku's base `error_page 401` wins at
  server level, so the plugin shadows its internal handler instead);
- `login-auth-10-server.conf` — `server`-level `auth_request` /
  `error_page` / `map`-driven API-key enforcement and `headers-more` identity
  injection (`Remote-User`, `Remote-Groups`, `Remote-Email`, `Remote-Name`).
- global `http`-context `map` blocks in `/etc/nginx/conf.d/00-login-auth-routing.conf`
  (routing maps and the `Authorization: Bearer` API-key lookup).
- an API-key value file at `/etc/nginx/login-auth/<app>/apikeys.map`.

Every generated file is plugin-owned and starts with
`# Managed by dokku-login-auth. Do not edit manually.`

The login server runs as its own Dokku app, `auth-portal`, backed by
[Authelia](https://www.authelia.com/) with a flat-file user store.

### Portal theme

Fresh installs render `configuration.yml` with `theme: 'auto'`, so the portal
follows the device/system `prefers-color-scheme`. On an existing install you can
override the theme without rewriting `configuration.yml` (Authelia resolves
configuration as defaults → files → environment, so the environment wins):

```bash
dokku config:set auth-portal AUTHELIA_THEME=auto   # or 'light' / 'dark'
```

This is the recommended path for existing portals, because
`login-auth:init` preserves an existing `configuration.yml` (only `--force`
rewrites it, and that rotates the JWT/session/storage secrets).

## Requirements

- Dokku with its nginx-vhosts plugin (per-app `nginx.conf.d/` include).
- The nginx `headers-more` module
  (`ngx_http_headers_more_filter_module`). OpenResty bundles it; on
  Debian/Ubuntu install `libnginx-mod-http-headers-more-filter`. The `install`
  script detects it and fails clearly when absent.
- `openssl` (secret generation) and [Mike Farah's Go `yq` v4](https://github.com/mikefarah/yq)
  (installed automatically by `install` if missing).

## Installation

```bash
dokku plugin:install https://github.com/lbovet/dokku-login-auth.git
```

Pinned dependencies (recorded here so upgrades are explicit; never use
`latest` or a floating major tag):

| Dependency | Pinned version | Notes |
|---|---|---|
| `mikefarah/yq` | `v4.54.1` | Installed by `install` from GitHub releases, SHA-256 verified. |
| Authelia image | `authelia/authelia:4.38.19` | Deployed by `login-auth:init` as `auth-portal`. |

To update a pin: bump the version and the corresponding SHA-256 in `install`
(for `yq`), update the image tag in `functions` (for Authelia), and adjust this
table. Re-run `dokku plugin:install` (or `login-auth:install`) after a `yq`
bump.

## Subcommands

```
login-auth:init [--parent-domain <domain>] [--auth-subdomain <sub>] [--force]
login-auth:enable-form <app> [--path </prefix>] [--force]
login-auth:disable-form <app> [--path </prefix>]
login-auth:enable-apikey <app> --path </prefix> [--force]
login-auth:disable-apikey <app> --path </prefix>
login-auth:bypass <app> --path </prefix> [--force]
login-auth:add-key <app> <key-name> [<key-value>] [--from-stdin]
login-auth:remove-key <app> <key-name>
login-auth:user-add <username> <password> [--group <group>]... [--displayname <name>] [--email <email>]
login-auth:user-remove <username>
login-auth:user-passwd <username> <new-password>
login-auth:user-list
login-auth:report [<app>] [--format json]
```

### Quick example

```bash
dokku login-auth:init --parent-domain example.com
dokku login-auth:user-add alice 'correct horse battery staple' \
  --displayname "Alice" --email alice@example.com

dokku login-auth:enable-form dashboard-ui
dokku login-auth:enable-apikey backend-api --path /api
printf '%s' 'sk_live_abc123' | dokku login-auth:add-key backend-api ci-pipeline --from-stdin

dokku login-auth:enable-form dev-center --path /
dokku login-auth:bypass dev-center --path /api/webhook/github
```

## State

- `/var/lib/dokku/services/login-auth/<app>/state.json` — per-app path/mode
  state.
- `/var/lib/dokku/services/login-auth/_global/state.json` — global settings
  (parent domain, pins).
- `/etc/nginx/login-auth/<app>/apikeys.map` — API-key value map (mode `0640`,
  owned `root:www-data`).

## Tests

```bash
make test        # self-contained bats suite (no Dokku required)
make lint        # shellcheck
```

The Docker/Dokku integration harness and `tests/smoke.sh` are opt-in/manual;
see `tests/README.md`.

## License

MIT — see [LICENSE](LICENSE).
