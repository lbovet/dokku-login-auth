#!/usr/bin/env bash
# Manual HTTP smoke test for the full login-auth stack (SPEC §10).
#
# This script must run on a real Dokku host that already has the plugin
# installed and an `auth-portal` deployed. It exercises the checks that
# cannot be covered by the self-contained bats suite (actual HTTP
# redirects, SSO cookie behaviour, fail-closed behaviour).
#
# Usage:
#   PARENT_DOMAIN=chee.li FORM_APP=wanderlisi-luna \
#   API_APP=backend-api API_BASE=/api API_KEY=sk_live_xxx \
#     tests/smoke.sh
#
# Environment:
#   PARENT_DOMAIN  shared parent domain (default: chee.li)
#   FORM_APP       app with form-login protection on /
#   API_APP        app with apikey protection on API_BASE (optional)
#   API_BASE       apikey-protected path prefix (default: /api)
#   API_KEY        a valid API key for API_APP (optional)
#   BYPASS_PATH    explicitly public path to check (optional, e.g. /api/webhook/github)
set -uo pipefail

PARENT_DOMAIN="${PARENT_DOMAIN:-chee.li}"
FORM_APP="${FORM_APP:-wanderlisi-luna}"
API_APP="${API_APP:-}"
API_BASE="${API_BASE:-/api}"
API_KEY="${API_KEY:-}"
BYPASS_PATH="${BYPASS_PATH:-}"

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  failures=$((failures + 1))
}
info() { printf '\n== %s ==\n' "$1"; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 2
  }
}

require dokku
require curl

form_url="https://$FORM_APP.$PARENT_DOMAIN/"

info "form login: unauthenticated request redirects to the portal"
status="$(curl -s -o /dev/null -w '%{http_code}' "$form_url")"
location="$(curl -s -o /dev/null -w '%{redirect_url}' "$form_url")"
if [[ "$status" == "302" && "$location" == *"auth.$PARENT_DOMAIN"* ]]; then
  pass "GET $form_url -> 302 to $location"
else
  fail "GET $form_url -> $status (location: $location); expected 302 to auth.$PARENT_DOMAIN"
fi

info "form login: an Authorization: Bearer header does not bypass the portal"
status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer not-a-real-key' "$form_url")"
location="$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Authorization: Bearer not-a-real-key' "$form_url")"
if [[ "$status" == "302" && "$location" == *"auth.$PARENT_DOMAIN"* ]]; then
  pass "GET $form_url with a Bearer header -> 302 to $location (not bypassed)"
else
  fail "GET $form_url with a Bearer header -> $status (location: $location); expected 302 to auth.$PARENT_DOMAIN"
fi

if [[ -n "$API_APP" ]]; then
  info "api key: missing Authorization header returns 401 (not a redirect)"
  status="$(curl -s -o /dev/null -w '%{http_code}' "https://$API_APP.$PARENT_DOMAIN$API_BASE")"
  if [[ "$status" == "401" ]]; then
    pass "GET $API_APP$API_BASE without token -> 401"
  else
    fail "GET $API_APP$API_BASE without token -> $status; expected 401"
  fi

  if [[ -n "$API_KEY" ]]; then
    info "api key: a valid Bearer token is accepted"
    status="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_KEY" "https://$API_APP.$PARENT_DOMAIN$API_BASE")"
    if [[ "$status" -ge 200 && "$status" -lt 400 ]]; then
      pass "GET $API_APP$API_BASE with token -> $status"
    else
      fail "GET $API_APP$API_BASE with token -> $status; expected 2xx/3xx"
    fi
  fi

  info "fail-closed: stopping auth-portal breaks form paths but not apikey paths"
  dokku ps:stop auth-portal >/dev/null 2>&1 || true
  form_status="$(curl -s -o /dev/null -w '%{http_code}' "$form_url")"
  if [[ "$form_status" == "500" || "$form_status" == "502" || "$form_status" == "504" ]]; then
    pass "form path -> $form_status while auth-portal is down (fail-closed)"
  else
    fail "form path -> $form_status while auth-portal is down; expected 5xx"
  fi
  if [[ -n "$API_KEY" ]]; then
    api_status="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $API_KEY" "https://$API_APP.$PARENT_DOMAIN$API_BASE")"
    if [[ "$api_status" -ge 200 && "$api_status" -lt 400 ]]; then
      pass "apikey path -> $api_status while auth-portal is down (unaffected)"
    else
      fail "apikey path -> $api_status while auth-portal is down; expected unaffected"
    fi
  fi
  dokku ps:start auth-portal >/dev/null 2>&1 || true
fi

if [[ -n "$BYPASS_PATH" ]]; then
  info "bypass: explicitly public path is reachable unauthenticated"
  status="$(curl -s -o /dev/null -w '%{http_code}' "https://$FORM_APP.$PARENT_DOMAIN$BYPASS_PATH")"
  if [[ "$status" -ge 200 && "$status" -lt 400 ]]; then
    pass "GET $FORM_APP$BYPASS_PATH -> $status"
  else
    fail "GET $FORM_APP$BYPASS_PATH -> $status; expected unauthenticated 2xx/3xx"
  fi
fi

info "SSO"
cat <<EOF
  This check requires a browser. Log in at https://auth.$PARENT_DOMAIN once
  while visiting $form_url, then open a second form-protected app under
  *.$PARENT_DOMAIN and confirm it does not re-prompt for credentials.
  Also confirm the backend receives the identity headers on that request
  (Remote-User / Remote-Groups / Remote-Email / Remote-Name), and that a
  client-supplied Remote-User header is overwritten.
EOF

echo
if [[ "$failures" -eq 0 ]]; then
  echo "smoke test: all automated checks passed"
  exit 0
fi
echo "smoke test: $failures check(s) failed"
exit 1
