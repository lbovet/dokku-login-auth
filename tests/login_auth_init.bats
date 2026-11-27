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
  grep -q "default_redirection_url: 'https://auth.example.com'" "$config"
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

@test "init creates the built-in admin user with displayname and group" {
  run cmd-login-auth-init --parent-domain example.com
  [ "$status" -eq 0 ]

  local users
  users="$(fn-login-auth-users-file)"
  fn-login-auth-user-exists admin
  [ "$(yq eval -r '.users.admin.displayname' "$users")" == "Administrator" ]
  [ "$(yq eval -r '.users.admin.groups | join(",")' "$users")" == "admin" ]
  [ "$(yq eval -r '.users.admin.disabled' "$users")" == "false" ]
  grep -q 'argon2id' "$users"
}

@test "init generates a 32-character hex admin password and prints it once" {
  run cmd-login-auth-init --parent-domain example.com
  [ "$status" -eq 0 ]

  local users password hash
  users="$(fn-login-auth-users-file)"
  password="$(printf '%s\n' "$output" | sed -n 's/.*generated password (shown once): //p' | head -n1)"
  [[ "$password" =~ ^[0-9a-f]{32}$ ]]
  hash="$(yq eval -r '.users.admin.password' "$users")"

  run cmd-login-auth-init --parent-domain example.com
  [ "$status" -eq 0 ]
  [[ "$output" != *"$password"* ]]
  [[ "$output" == *"Keeping existing 'admin' credentials"* ]]
  [ "$(yq eval -r '.users.admin.password' "$users")" == "$hash" ]
}

@test "init --admin-password uses the supplied password without printing one" {
  dokku() {
    if [[ "$1" == "enter" ]]; then
      printf 'Digest: %s\n' "${!#}"
      return 0
    fi
    _dokku_stub "$@"
  }

  run cmd-login-auth-init --parent-domain example.com --admin-password 's3cret'
  [ "$status" -eq 0 ]
  [[ "$output" != *"generated password"* ]]
  [ "$(yq eval -r '.users.admin.password' "$(fn-login-auth-users-file)")" == "s3cret" ]
}

@test "init never overwrites existing admin credentials" {
  dokku() {
    if [[ "$1" == "enter" ]]; then
      printf 'Digest: %s\n' "${!#}"
      return 0
    fi
    _dokku_stub "$@"
  }

  cmd-login-auth-init --parent-domain example.com --admin-password first
  local before
  before="$(yq eval -r '.users.admin.password' "$(fn-login-auth-users-file)")"
  [ "$before" == "first" ]

  run cmd-login-auth-init --parent-domain example.com --admin-password second
  [ "$status" -eq 0 ]
  [[ "$output" == *"--admin-password ignored"* ]]
  [ "$(yq eval -r '.users.admin.password' "$(fn-login-auth-users-file)")" == "first" ]
}
