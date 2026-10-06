# Tests

## Self-contained bats suite (CI)

The bats suite under this directory is self-contained: it stubs `dokku`,
`docker` and `verify_app_name`, and operates entirely on temporary
directories. It needs `bats`, `jq`, `yq` (mikefarah v4) and `openssl` on
`PATH`.

```bash
# Debian/Ubuntu
sudo apt-get install -y bats jq openssl
sudo curl -fsSL -o /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.54.1/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

make test
```

The suite is run automatically on every pull request by
`.github/workflows/ci.yml`.

What it covers:

- per-app nginx rendering (fixed `auth_request` target, mode-aware redirect
  location, `headers-more` identity injection);
- longest-prefix-first routing-map generation and regex escaping
  (SPEC §10 #12);
- path/mode validation, `--force`, idempotency and tolerant no-ops;
- cleanup when the last path is removed or an app is deleted;
- API-key map add/remove/replace and value escaping;
- user add/remove/passwd/list without leaking hashes;
- `login-auth:init` idempotency and secret preservation;
- `login-auth:report` text/JSON output;
- dependency detection (`headers-more`, `yq` checksums).

## HTTP smoke test (manual, on a real Dokku host)

`tests/smoke.sh` exercises the checks that need an actual running stack:
HTTP redirects to Authelia, apikey `401` vs form `302`, bypass paths, and
fail-closed behaviour when `auth-portal` is stopped. It must run on a Dokku
host with `auth-portal` deployed.

```bash
PARENT_DOMAIN=chee.li \
FORM_APP=wanderlisi-luna \
API_APP=backend-api API_BASE=/api API_KEY=sk_live_xxx \
BYPASS_PATH=/api/webhook/github \
  tests/smoke.sh
```

The SSO and identity-propagation checks require a browser (log in once, then
open a second protected app under the same parent domain); the script prints
the exact steps and cannot assert them automatically.

## Docker/Dokku harness (opt-in)

A full `dokku`-in-Docker harness (as used by `dokku-http-auth`) is not wired
up here because the CI sandbox cannot run Docker-in-Docker. To run the smoke
test against a disposable Dokku, use any Dokku container image, install the
plugin with `dokku plugin:install`, run `login-auth:init`, then invoke
`tests/smoke.sh` from inside the container.
