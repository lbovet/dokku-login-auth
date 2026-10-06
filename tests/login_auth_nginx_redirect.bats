#!/usr/bin/env bats
# Real-nginx regression test for the Dokku base `error_page 401` precedence bug.
#
# Dokku's app nginx template declares `error_page 400 401 402 403 405 ...
# /400-error.html` BEFORE the plugin's nginx.conf.d include, and nginx keeps the
# first error_page for a status code. The plugin therefore cannot win with a
# server-level `error_page 401`; it shadows Dokku's internal handler instead.
# This test runs a real nginx with a Dokku-shaped server block and asserts the
# end-to-end HTTP behaviour: form login redirects, apikey stays 401, and the
# original Dokku error page is preserved for non-auth errors.
#
# The `more_set_input_headers` lines (headers-more) are stripped: this test is
# about error_page precedence, not identity propagation, and it keeps the test
# independent of whether the headers-more module is installed on the runner.

setup() {
  if ! command -v nginx >/dev/null 2>&1; then
    skip "nginx not installed"
  fi

  REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/tests/*}" && pwd)"
  TMP="$(mktemp -d)"
  export DOKKU_ROOT="$TMP/home"
  export DOKKU_LIB_ROOT="$TMP/lib"
  export PLUGIN_AVAILABLE_PATH="$REPO_ROOT"
  export PLUGIN_CORE_AVAILABLE_PATH="$TMP/core"
  export DOKKU_TRACE=""
  mkdir -p "$DOKKU_ROOT/app1/nginx.conf.d" "$DOKKU_LIB_ROOT"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/command-functions"

  LOGIN_AUTH_SERVICE_ROOT="$TMP/lib/services/login-auth"
  LOGIN_AUTH_GLOBAL_STATE_DIR="$LOGIN_AUTH_SERVICE_ROOT/_global"
  LOGIN_AUTH_GLOBAL_STATE_FILE="$LOGIN_AUTH_GLOBAL_STATE_DIR/state.json"
  LOGIN_AUTH_NGINX_ROOT="$TMP/etc/nginx/login-auth"
  LOGIN_AUTH_GLOBAL_CONF="$TMP/etc/nginx/conf.d/00-login-auth-routing.conf"
  LOGIN_AUTH_GLOBAL_CONF_PLACEHOLDER="$LOGIN_AUTH_GLOBAL_CONF"
  mkdir -p "$(dirname "$LOGIN_AUTH_GLOBAL_CONF")" "$LOGIN_AUTH_NGINX_ROOT"

  verify_app_name() { [[ "$1" == "app1" ]]; }
  dokku() {
    case "${1:-}" in
      nginx:validate-config | nginx:reload) return 0 ;;
      *) return 0 ;;
    esac
  }
  docker() { return 1; }

  APPPORT=$((20000 + (RANDOM % 2000) * 3))
  BACKPORT=$((APPPORT + 1))
  AUTHPORT=$((APPPORT + 2))

  # Point the plugin's Authelia upstream at a local fake served by nginx.
  fn-login-auth-resolve-upstream() { printf '127.0.0.1:%s' "$AUTHPORT"; }

  cmd-login-auth-enable-form app1 --path /
  cmd-login-auth-enable-apikey app1 --path /api
  cmd-login-auth-bypass app1 --path /public

  # Drop the headers-more lines so the test needs only a stock nginx.
  sed -i '/more_set_input_headers/d' "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"

  ERROR_ROOT="$TMP/lib/data/nginx-vhosts/dokku-errors"
  mkdir -p "$ERROR_ROOT"
  printf 'dokku-error-page\n' >"$ERROR_ROOT/400-error.html"

  NGINX_DIR="$TMP/nginx"
  mkdir -p "$NGINX_DIR/logs" "$NGINX_DIR/tmp/client_body" "$NGINX_DIR/tmp/proxy" \
    "$NGINX_DIR/tmp/fastcgi" "$NGINX_DIR/tmp/uwsgi" "$NGINX_DIR/tmp/scgi"

  {
    echo "worker_processes 1;"
    echo "error_log $NGINX_DIR/logs/error.log info;"
    echo "pid $NGINX_DIR/nginx.pid;"
    echo "events { worker_connections 64; }"
    echo "http {"
    echo "  access_log off;"
    echo "  default_type text/plain;"
    echo "  client_body_temp_path $NGINX_DIR/tmp/client_body;"
    echo "  proxy_temp_path $NGINX_DIR/tmp/proxy;"
    echo "  fastcgi_temp_path $NGINX_DIR/tmp/fastcgi;"
    echo "  uwsgi_temp_path $NGINX_DIR/tmp/uwsgi;"
    echo "  scgi_temp_path $NGINX_DIR/tmp/scgi;"
    grep -v '^# Managed' "$LOGIN_AUTH_GLOBAL_CONF"
    cat <<NGINX
  server {
    listen 127.0.0.1:$AUTHPORT;
    location = /api/authz/auth-request {
      add_header Location "https://auth.example.com/?rd=form&rm=GET" always;
      return 401;
    }
  }
  server {
    listen 127.0.0.1:$BACKPORT;
    location / { return 200 "backend-ok"; }
  }
  server {
    listen 127.0.0.1:$APPPORT;
    location / { proxy_pass http://127.0.0.1:$BACKPORT; }
    location = /public/trigger400 { return 400; }
    location = /public/trigger403 { return 403; }
    error_page 400 401 402 403 405 /400-error.html;
    location /400-error.html { root $ERROR_ROOT; internal; }
    include $DOKKU_ROOT/app1/nginx.conf.d/*.conf;
  }
}
NGINX
  } >"$NGINX_DIR/nginx.conf"

  nginx -p "$NGINX_DIR" -c "$NGINX_DIR/nginx.conf" -t
  nginx -p "$NGINX_DIR" -c "$NGINX_DIR/nginx.conf"
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$APPPORT/"; then
      break
    fi
    sleep 0.1
  done
}

teardown() {
  if [[ -n "${NGINX_DIR:-}" && -f "$NGINX_DIR/nginx.pid" ]]; then
    nginx -p "$NGINX_DIR" -c "$NGINX_DIR/nginx.conf" -s stop 2>/dev/null || true
  fi
  [[ -n "${TMP:-}" ]] && rm -rf "$TMP"
}

@test "real nginx: Dokku base error_page 401 does not shadow the form redirect" {
  run curl -s -o /dev/null -D - "http://127.0.0.1:$APPPORT/"
  [ "$status" -eq 0 ]
  [[ "$output" == *" 302 "* ]]
  [[ "$output" == *"Location: https://auth.example.com/?rd=form&rm=GET"* ]]
}

@test "real nginx: apikey paths still return 401 without a Location" {
  run curl -s -o /dev/null -D - "http://127.0.0.1:$APPPORT/api"
  [ "$status" -eq 0 ]
  [[ "$output" == *" 401 "* ]]
  [[ "$output" != *"Location:"* ]]
}

@test "real nginx: non-auth 4xx errors still serve Dokku's base page" {
  run curl -s -D - "http://127.0.0.1:$APPPORT/public/trigger400"
  [ "$status" -eq 0 ]
  [[ "$output" == *" 400 "* ]]
  [[ "$output" == *"dokku-error-page"* ]]

  run curl -s -D - "http://127.0.0.1:$APPPORT/public/trigger403"
  [[ "$output" == *" 403 "* ]]
  [[ "$output" == *"dokku-error-page"* ]]
}

@test "real nginx: bypass paths reach the backend" {
  run curl -s "http://127.0.0.1:$APPPORT/public"
  [ "$status" -eq 0 ]
  [[ "$output" == *"backend-ok"* ]]
}
