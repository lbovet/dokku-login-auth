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
login-auth:init [--parent-domain <domain>] [--auth-subdomain <sub>]
                [--admin-password <password>] [--force]
login-auth:enable-form <app> [--path </prefix>] [--force]
login-auth:disable-form <app> [--path </prefix>]
login-auth:enable-apikey <app> --path </prefix> [--force]
login-auth:disable-apikey <app> --path </prefix>
login-auth:bypass <app> --path </prefix> [--force]
login-auth:access-set <app> [--user <username>]... [--group <group>]...
login-auth:access-list <app>
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
dokku login-auth:access-set dashboard-ui --user alice --group devs
dokku login-auth:enable-apikey backend-api --path /api
printf '%s' 'sk_live_abc123' | dokku login-auth:add-key backend-api ci-pipeline --from-stdin

dokku login-auth:enable-form dev-center --path /
dokku login-auth:bypass dev-center --path /api/webhook/github
```

## Users

Users live in Authelia's file backend (`users.yml`) and are managed with the
`login-auth:user-*` subcommands. The built-in `admin` user is created by
`login-auth:init` (see below), always has access to every form-protected app,
and cannot be removed; `login-auth:user-list` marks it with `(built-in)`.

## Per-app access

Access is configured per app, not per path. Every app with at least one
`form` path has an allow list of users and groups; the allow list applies to
all of the app's `form` paths. `apikey` and `none` paths are unaffected.

```bash
dokku login-auth:access-set dashboard-ui --user alice --user bob --group devs
dokku login-auth:access-list dashboard-ui
```

- An app with no allow list (or an empty one) is **admin-only**: only the
  built-in `admin` user may access it. There is no implicit "all authenticated
  users" access.
- `admin` always has access to every form-protected app and cannot be removed.
  `login-auth:init` creates it (displayname `Administrator`, group `admin`)
  if missing. If `--admin-password` is omitted a 32-character hex password is
  generated and printed once; existing admin credentials are never
  overwritten. `login-auth:user-remove admin` always fails, while
  `login-auth:user-add admin` works only when the user does not exist.
- `login-auth:user-list` appends `(built-in)` to the `admin` row.
- Usernames must exist in `users.yml`; groups may be referenced before anyone
  joins them (the plugin warns).
- The allow list is stored in the app's `state.json`; the plugin renders the
  matching Authelia ACL rule on the next mutating command.

For every app with at least one `form` path the plugin writes one
`one_factor` rule into `configuration.yml`:

- `domain` is the app's effective Dokku vhosts, resolved with
  `dokku domains:report <app> --domains-app-vhosts`, falling back to the
  global vhosts when the app has none. Wildcards are kept as configured.
- `subject` is the app's allow list preceded by the implicit `user:admin`;
  an app with no allow list gets `['user:admin']` (admin-only).
- Rules follow the portal bypass rule in domain-specificity order, so an
  exact `b.example.com` wins over a broader `*.example.com`.

There is no catch-all `*.<parent-domain>` rule: an app without a generated
rule is denied by `default_policy: deny`, which is the safe default. A
form-protected app with no resolvable domain fails the mutating command and
leaves the previous configuration untouched.

The rules are regenerated on `enable-form`, `disable-form`, `access-set`,
`user-remove`, and `init`; the generated secrets are never regenerated.
Domain changes are not watched automatically — after
`dokku domains:add`/`domains:remove`, re-run a mutating command (for example
`dokku login-auth:access-set <app>` with the app's current allow-list flags)
so the ACL rule picks up the new domains. `auth-portal` is restarted only
when the generated rules changed.

## State

- `/var/lib/dokku/services/login-auth/<app>/state.json` — per-app path/mode
  and access state.
- `/var/lib/dokku/services/login-auth/_global/state.json` — global settings
  (parent domain, pins).
- `/var/lib/dokku/data/storage/auth-portal/config/configuration.yml` —
  Authelia configuration, including the generated `access_control.rules`
  list (do not hand-edit the rules; the plugin rewrites them).
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
