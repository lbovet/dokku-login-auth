#!/usr/bin/env bats
load test_helper

@test "init writes configuration and users files" {
  run cmd-login-auth-init --parent-domain example.com
  [ "$status" -eq 0 ]

  local config users
  config="$(fn-login-auth-config-root)/configuration.yml"
  users="$(fn-login-auth-config-root)/users.yml"
  [ -f "$config" ]
  [ -f "$users" ]
  grep -q "theme: 'auto'" "$config"
  grep -q "domain: 'example.com'" "$config"
  grep -q "authelia_url: 'https://auth.example.com'" "$config"
  grep -q '__placeholder__' "$users"
  grep -q 'disabled: true' "$users"
}

@test "init is idempotent and preserves secrets" {
  cmd-login-auth-init --parent-domain example.com
  local config before
  config="$(fn-login-auth-config-root)/configuration.yml"
  before="$(cat "$config")"

  run cmd-login-auth-init --parent-domain example.com
  [ "$status" -eq 0 ]
  [ "$(cat "$config")" == "$before" ]
}

@test "init --force regenerates secrets" {
  cmd-login-auth-init --parent-domain example.com
  local config before
  config="$(fn-login-auth-config-root)/configuration.yml"
  before="$(cat "$config")"

  run cmd-login-auth-init --parent-domain example.com --force
  [ "$status" -eq 0 ]
  [ "$(cat "$config")" != "$before" ]
}

@test "init records global state and defaults the auth subdomain" {
  cmd-login-auth-init --parent-domain example.com
  [ "$(fn-login-auth-parent-domain)" == "example.com" ]
  [ "$(fn-login-auth-auth-subdomain)" == "auth" ]
}

@test "init requires --parent-domain on the first run" {
  run cmd-login-auth-init
  [ "$status" -ne 0 ]
  [[ "$output" == *"--parent-domain is required"* ]]
}
