#!/usr/bin/env bats
load test_helper

@test "enable-form protects root by default and renders all files" {
  run cmd-login-auth-enable-form app1
  [ "$status" -eq 0 ]

  [ -f "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-00-internal.conf" ]
  [ -f "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf" ]
  grep -q 'auth_request /internal/login-auth/authz;' "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
  grep -q 'error_page 401 = @login_auth_redirect__app1;' "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
  grep -q 'default              "form";' "$LOGIN_AUTH_GLOBAL_CONF"
}

@test "form-only app gets a defined apikey map and stays form-protected" {
  run cmd-login-auth-enable-form app1 --path /
  [ "$status" -eq 0 ]

  # Regression for the pilot failure `unknown "login_auth_apikey_ok__app1"`:
  # the server snippet references the variable, so the global two-stage map must
  # exist even though the app has no apikey path.
  local file="$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
  grep -q 'if ($login_auth_apikey_ok__app1 = 1)' "$file"

  local map
  map="$(fn-login-auth-apikey-map-path app1)"
  [ -f "$map" ]
  [ ! -s "$map" ]
  grep -qF "include $map;" "$LOGIN_AUTH_GLOBAL_CONF"

  # An empty key map means a Bearer header cannot flip apikey_ok to 1, and the
  # path's mode is form (not apikey), so it is never bypassed by the header.
  [ "$(fn-login-auth-get-mode app1 /)" == "form" ]
}

@test "server-level enforcement never declares proxy_pass or proxy_set_header" {
  run cmd-login-auth-enable-form app1
  [ "$status" -eq 0 ]

  run grep -E 'proxy_pass|proxy_set_header' "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
  [ "$status" -ne 0 ]
}

@test "identity headers are injected with headers-more" {
  run cmd-login-auth-enable-form app1
  [ "$status" -eq 0 ]

  local file="$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
  grep -q 'more_set_input_headers "Remote-User:' "$file"
  grep -q 'more_set_input_headers "Remote-Groups:' "$file"
  grep -q 'more_set_input_headers "Remote-Email:' "$file"
  grep -q 'more_set_input_headers "Remote-Name:' "$file"
}

@test "authz internal location branches to authelia only for form mode" {
  run cmd-login-auth-enable-form app1
  [ "$status" -eq 0 ]

  local file="$DOKKU_ROOT/app1/nginx.conf.d/login-auth-00-internal.conf"
  grep -q 'location = /internal/login-auth/authz {' "$file"
  grep -q 'if ($login_auth_mode__app1 != "form")' "$file"
  grep -q 'proxy_pass http://auth-portal-9091/api/authz/auth-request;' "$file"
}

@test "apikey redirect location returns 401 instead of redirecting" {
  run cmd-login-auth-enable-apikey app1 --path /api
  [ "$status" -eq 0 ]

  local file="$DOKKU_ROOT/app1/nginx.conf.d/login-auth-00-internal.conf"
  grep -q 'location @login_auth_redirect__app1 {' "$file"
  grep -q 'if ($login_auth_mode__app1 = "apikey")' "$file"
  grep -q 'return 401;' "$file"
}

@test "per-path form protection leaves other paths unmatched" {
  run cmd-login-auth-enable-form app1 --path /admin
  [ "$status" -eq 0 ]

  run grep -q 'default              "none";' "$LOGIN_AUTH_GLOBAL_CONF"
  [ "$status" -eq 0 ]
  run grep -qF '~^/admin(/|$)   "form";' "$LOGIN_AUTH_GLOBAL_CONF"
  [ "$status" -eq 0 ]
}

@test "enable-apikey requires an explicit --path" {
  run cmd-login-auth-enable-apikey app1
  [ "$status" -ne 0 ]
  [[ "$output" == *"--path is required"* ]]
}

@test "a path cannot be reconfigured with a different mode without --force" {
  cmd-login-auth-enable-form app1 --path /api
  run cmd-login-auth-enable-apikey app1 --path /api
  [ "$status" -ne 0 ]
  [[ "$output" == *"already configured as form"* ]]

  run cmd-login-auth-enable-apikey app1 --path /api --force
  [ "$status" -eq 0 ]
  [ "$(fn-login-auth-get-mode app1 /api)" == "apikey" ]
}

@test "trailing slashes are normalized except for root" {
  cmd-login-auth-enable-form app1 --path /api/
  [ "$(fn-login-auth-get-mode app1 /api)" == "form" ]
  cmd-login-auth-enable-form app1 --path /
  [ "$(fn-login-auth-get-mode app1 /)" == "form" ]
}

@test "invalid paths are rejected before any state is written" {
  run cmd-login-auth-enable-form app1 --path api
  [ "$status" -ne 0 ]
  [ ! -f "$(fn-login-auth-state-file app1)" ]
}

@test "disable of an unconfigured path is a tolerant no-op" {
  run cmd-login-auth-disable-form app1 --path /nope
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
}

@test "removing the last path cleans per-app and global config" {
  cmd-login-auth-enable-form app1 --path /admin
  run cmd-login-auth-disable-form app1 --path /admin
  [ "$status" -eq 0 ]

  [ ! -f "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-00-internal.conf" ]
  [ ! -f "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf" ]
  [ ! -f "$(fn-login-auth-state-file app1)" ]
  run grep -q 'login_auth_mode__app1' "$LOGIN_AUTH_GLOBAL_CONF"
  [ "$status" -ne 0 ]
}

@test "bypass renders a public carve-out" {
  cmd-login-auth-enable-form app1 --path /
  run cmd-login-auth-bypass app1 --path /api/webhook
  [ "$status" -eq 0 ]

  grep -qF '~^/api/webhook(/|$)   "none";' "$LOGIN_AUTH_GLOBAL_CONF"
}

@test "enable fails before writing when auth-portal has no upstream" {
  DOKKU_PORTS_JSON='[]'
  run cmd-login-auth-enable-form app1
  [ "$status" -ne 0 ]
  [[ "$output" == *"deploy auth-portal first"* ]]
  [ ! -f "$(fn-login-auth-state-file app1)" ]
  [ ! -f "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf" ]
}
