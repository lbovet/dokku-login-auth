#!/usr/bin/env bash
# Shared test setup for the login-auth bats suite.
# The suite is self-contained: it stubs `dokku`, `docker`, `nginx` and
# `verify_app_name`, and works purely against temporary directories.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/tests/*}" && pwd)"
  TMP="$(mktemp -d)"

  export DOKKU_ROOT="$TMP/home"
  export DOKKU_LIB_ROOT="$TMP/lib"
  export PLUGIN_AVAILABLE_PATH="$REPO_ROOT"
  export PLUGIN_CORE_AVAILABLE_PATH="$TMP/core"
  export DOKKU_TRACE=""

  mkdir -p "$DOKKU_ROOT/app1/nginx.conf.d" "$DOKKU_ROOT/app2/nginx.conf.d" "$DOKKU_ROOT/combo/nginx.conf.d"
  mkdir -p "$DOKKU_LIB_ROOT"

  # command-functions sources functions; do it before overriding the paths.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/command-functions"

  LOGIN_AUTH_SERVICE_ROOT="$TMP/lib/services/login-auth"
  LOGIN_AUTH_GLOBAL_STATE_DIR="$LOGIN_AUTH_SERVICE_ROOT/_global"
  LOGIN_AUTH_GLOBAL_STATE_FILE="$LOGIN_AUTH_GLOBAL_STATE_DIR/state.json"
  LOGIN_AUTH_NGINX_ROOT="$TMP/etc/nginx/login-auth"
  LOGIN_AUTH_GLOBAL_CONF="$TMP/etc/nginx/conf.d/00-login-auth-routing.conf"
  LOGIN_AUTH_GLOBAL_CONF_PLACEHOLDER="$LOGIN_AUTH_GLOBAL_CONF"
  mkdir -p "$(dirname "$LOGIN_AUTH_GLOBAL_CONF")" "$LOGIN_AUTH_NGINX_ROOT"

  verify_app_name() {
    case "$1" in
      app1 | app2 | combo) return 0 ;;
      *) return 1 ;;
    esac
  }

  DOKKU_PORTS_JSON='[{"container_port":9091}]'
  dokku() { _dokku_stub "$@"; }
  docker() { return 1; }
}

teardown() {
  rm -rf "$TMP"
}

_dokku_stub() {
  local cmd="${1:-}"
  case "$cmd" in
    ports:report) printf '%s\n' "$DOKKU_PORTS_JSON" ;;
    nginx:validate-config) return 0 ;;
    nginx:reload) return 0 ;;
    apps:exists) return 0 ;;
    apps:create) return 0 ;;
    ports:set) return 0 ;;
    storage:list) return 0 ;;
    storage:mount) return 0 ;;
    domains:set) return 0 ;;
    ps:restart) return 0 ;;
    git:from-image) return 0 ;;
    enter) printf 'Digest: $argon2id$v=19$m=65536,t=3,p=4$%s$%s\n' "$(date +%s%N)" "$RANDOM" ;;
    *) return 0 ;;
  esac
}

# Extract a single app's `map $uri` block from the global config.
login_auth_map_block() {
  local app="$1"
  awk -v app="$app" '
    $0 ~ ("map \\$uri \\$login_auth_mode__" app) { found = 1 }
    found { print }
    found && /^}/ { exit }
  ' "$LOGIN_AUTH_GLOBAL_CONF"
}

# Line number of a pattern within a file, or empty.
login_auth_line_of() {
  local pattern="$1" file="$2"
  grep -n "$pattern" "$file" | head -n1 | cut -d: -f1
}
