#!/usr/bin/env bats
load test_helper

@test "routing map is longest-prefix-first regardless of command order" {
  cmd-login-auth-bypass app1 --path /api/public
  cmd-login-auth-enable-apikey app1 --path /api
  cmd-login-auth-enable-form app1 --path /

  local block public_line api_line
  block="$(login_auth_map_block app1)"
  public_line="$(printf '%s\n' "$block" | grep -nF '~^/api/public(/|$)' | cut -d: -f1)"
  api_line="$(printf '%s\n' "$block" | grep -nF '~^/api(/|$)' | cut -d: -f1)"

  [ -n "$public_line" ]
  [ -n "$api_line" ]
  [ "$public_line" -lt "$api_line" ]
  printf '%s\n' "$block" | grep -qF 'default              "form";'
  printf '%s\n' "$block" | grep -qF '~^/api/public(/|$)   "none";'
  printf '%s\n' "$block" | grep -qF '~^/api(/|$)   "apikey";'
}

@test "routing map order is stable when commands are issued in reverse" {
  cmd-login-auth-enable-form app2 --path /
  cmd-login-auth-bypass app2 --path /api/public
  cmd-login-auth-enable-apikey app2 --path /api

  local block public_line api_line
  block="$(login_auth_map_block app2)"
  public_line="$(printf '%s\n' "$block" | grep -nF '~^/api/public(/|$)' | cut -d: -f1)"
  api_line="$(printf '%s\n' "$block" | grep -nF '~^/api(/|$)' | cut -d: -f1)"

  [ "$public_line" -lt "$api_line" ]
  printf '%s\n' "$block" | grep -qF 'default              "form";'
}

@test "deeper overlapping prefix wins over a shallower one" {
  cmd-login-auth-enable-apikey app1 --path /api
  cmd-login-auth-enable-form app1 --path /api/admin

  local block admin_line api_line
  block="$(login_auth_map_block app1)"
  admin_line="$(printf '%s\n' "$block" | grep -nF '~^/api/admin(/|$)' | cut -d: -f1)"
  api_line="$(printf '%s\n' "$block" | grep -nF '~^/api(/|$)' | cut -d: -f1)"

  [ "$admin_line" -lt "$api_line" ]
}

@test "regex metacharacters in literal prefixes are escaped" {
  cmd-login-auth-enable-form app1 --path '/a.b+c'

  grep -qF '~^/a\.b\+c(/|$)' "$LOGIN_AUTH_GLOBAL_CONF"
}
