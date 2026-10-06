#!/usr/bin/env bats
load test_helper

@test "global config contains the two-stage Bearer map" {
  cmd-login-auth-enable-apikey app1 --path /api

  grep -qF 'map $http_authorization $login_auth_apikey_token__app1 {' "$LOGIN_AUTH_GLOBAL_CONF"
  grep -qF '"~^Bearer\s+(.+)$"   $1;' "$LOGIN_AUTH_GLOBAL_CONF"
  grep -qF 'map $login_auth_apikey_token__app1 $login_auth_apikey_ok__app1 {' "$LOGIN_AUTH_GLOBAL_CONF"
  grep -qF "include $LOGIN_AUTH_NGINX_ROOT/app1/apikeys.map;" "$LOGIN_AUTH_GLOBAL_CONF"
}

@test "form-only app still gets the apikey map so the variable is defined" {
  cmd-login-auth-enable-form app1 --path /

  grep -qF 'map $http_authorization $login_auth_apikey_token__app1 {' "$LOGIN_AUTH_GLOBAL_CONF"
  grep -qF 'map $login_auth_apikey_token__app1 $login_auth_apikey_ok__app1 {' "$LOGIN_AUTH_GLOBAL_CONF"
  grep -qF "include $LOGIN_AUTH_NGINX_ROOT/app1/apikeys.map;" "$LOGIN_AUTH_GLOBAL_CONF"

  local map
  map="$(fn-login-auth-apikey-map-path app1)"
  [ -f "$map" ]
  [ ! -s "$map" ]
}

@test "mixed form+apikey app emits the enforcement block and the map" {
  cmd-login-auth-enable-form app1 --path /
  cmd-login-auth-enable-apikey app1 --path /api

  local file="$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
  grep -q 'if ($login_auth_mode__app1 = "apikey")' "$file"
  grep -q 'if ($login_auth_apikey_ok__app1 = 1)' "$file"
  grep -q 'if ($login_auth_apikey_check__app1 = "check")' "$file"
  grep -qF 'map $login_auth_apikey_token__app1 $login_auth_apikey_ok__app1 {' "$LOGIN_AUTH_GLOBAL_CONF"
}

@test "enabling apikey creates an empty map file so nginx config stays valid" {
  cmd-login-auth-enable-apikey app1 --path /api

  local map
  map="$(fn-login-auth-apikey-map-path app1)"
  [ -f "$map" ]
  [ ! -s "$map" ]
}

@test "add-key stores the token with a name comment and remove-key deletes it" {
  cmd-login-auth-enable-apikey app1 --path /api
  printf '%s' 'sk_live_abc123' >"$TMP/key"

  run cmd-login-auth-add-key app1 ci-pipeline --from-stdin <"$TMP/key"
  [ "$status" -eq 0 ]

  local map
  map="$(fn-login-auth-apikey-map-path app1)"
  grep -qF '# ci-pipeline' "$map"
  grep -qF '"sk_live_abc123" 1;' "$map"

  run cmd-login-auth-remove-key app1 ci-pipeline
  [ "$status" -eq 0 ]
  run grep -qF 'sk_live_abc123' "$map"
  [ "$status" -ne 0 ]
}

@test "add-key replaces an existing key with the same name" {
  cmd-login-auth-enable-apikey app1 --path /api
  fn-login-auth-add-key app1 ci old-token
  fn-login-auth-add-key app1 ci new-token

  local map
  map="$(fn-login-auth-apikey-map-path app1)"
  grep -qF '"new-token" 1;' "$map"
  run grep -qF 'old-token' "$map"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^# ci$' "$map")" -eq 1 ]
}

@test "remove-key fails when the name is unknown" {
  cmd-login-auth-enable-apikey app1 --path /api
  run cmd-login-auth-remove-key app1 nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "add-key requires an apikey path to exist" {
  run cmd-login-auth-add-key app1 ci value
  [ "$status" -ne 0 ]
}

@test "map values with quotes and backslashes are escaped" {
  fn-login-auth-add-key app1 weird 'a"b\c'
  local map
  map="$(fn-login-auth-apikey-map-path app1)"
  grep -qF '"a\"b\\c" 1;' "$map"
}
