#!/usr/bin/env bats
load test_helper

login_auth_config_file() {
  printf '%s/configuration.yml' "$(fn-login-auth-config-root)"
}

login_auth_rules() {
  yq eval -o=json -I=0 '.access_control.rules' "$(login_auth_config_file)"
}

@test "a form-protected app gets an ACL rule and no catch-all remains" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-enable-form app1

  local rules
  rules="$(login_auth_rules)"
  [ "$(printf '%s' "$rules" | jq 'length')" -eq 2 ]
  printf '%s' "$rules" | jq -e '.[0].policy == "bypass"'
  printf '%s' "$rules" | jq -e '.[1].domain == ["app1.example.com"]'
  printf '%s' "$rules" | jq -e '.[1].policy == "one_factor"'
  printf '%s' "$rules" | jq -e '.[1].subject == ["user:admin"]'
  # No generated catch-all: only the portal bypass and the specific app rule.
  printf '%s' "$rules" | jq -e 'all(.[]; (.domain != "*.example.com"))'
}

@test "app with only apikey or public paths gets no ACL rule" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-enable-apikey app1 --path /api
  cmd-login-auth-bypass app2 --path /public

  local rules
  rules="$(login_auth_rules)"
  [ "$(printf '%s' "$rules" | jq 'length')" -eq 1 ]
  printf '%s' "$rules" | jq -e '.[0].policy == "bypass"'
}

@test "subject is the allow list with the implicit admin first" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-user-add alice secret
  cmd-login-auth-user-add bob secret --group devs
  cmd-login-auth-enable-form app1
  cmd-login-auth-access-set app1 --user bob --user alice --group devs

  local subject
  subject="$(login_auth_rules | jq -c '.[1].subject')"
  [ "$subject" == '["user:admin","user:alice","user:bob","group:devs"]' ]
}

@test "app domains come from Dokku and include wildcards" {
  cmd-login-auth-init --parent-domain example.com
  APP2_DOMAINS="app2.example.com *.app2.example.com"
  cmd-login-auth-enable-form app2

  local domains
  domains="$(login_auth_rules | jq -c '.[1].domain | sort')"
  [ "$domains" == '["*.app2.example.com","app2.example.com"]' ]
}

@test "an app with no vhosts falls back to the global vhosts" {
  cmd-login-auth-init --parent-domain example.com
  APP1_DOMAINS=""
  DOKKU_GLOBAL_DOMAINS="g1.example.com g2.example.com"
  cmd-login-auth-enable-form app1

  local domains
  domains="$(login_auth_rules | jq -c '.[1].domain | sort')"
  [ "$domains" == '["g1.example.com","g2.example.com"]' ]
}

@test "rules are ordered by domain specificity after the portal bypass" {
  cmd-login-auth-init --parent-domain example.com
  APP1_DOMAINS="*.deep.example.com"
  cmd-login-auth-enable-form app1
  APP2_DOMAINS="short.example.com"
  cmd-login-auth-enable-form app2
  COMBO_DOMAINS="a.b.example.com"
  cmd-login-auth-enable-form combo

  local domains
  domains="$(login_auth_rules | jq -c 'map(.domain | if type == "array" then .[0] else . end)')"
  [ "$domains" == '["auth.example.com","a.b.example.com","short.example.com","*.deep.example.com"]' ]
}

@test "a form app with no resolvable domain fails and leaves state and config untouched" {
  cmd-login-auth-init --parent-domain example.com
  local config before
  config="$(login_auth_config_file)"
  before="$(cat "$config")"

  APP1_DOMAINS=""
  DOKKU_GLOBAL_DOMAINS=""
  run cmd-login-auth-enable-form app1
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve any Dokku domain"* ]]
  [ ! -f "$(fn-login-auth-state-file app1)" ]
  [ "$(cat "$config")" == "$before" ]
}

@test "regeneration preserves the generated secrets and file mode byte-for-byte" {
  cmd-login-auth-init --parent-domain example.com
  local config jwt session storage mode
  config="$(login_auth_config_file)"
  jwt="$(yq eval -r '.identity_validation.reset_password.jwt_secret' "$config")"
  session="$(yq eval -r '.session.secret' "$config")"
  storage="$(yq eval -r '.storage.encryption_key' "$config")"
  mode="$(stat -c '%a' "$config")"

  cmd-login-auth-user-add alice secret
  cmd-login-auth-enable-form app1
  cmd-login-auth-access-set app1 --user alice

  [ "$(yq eval -r '.identity_validation.reset_password.jwt_secret' "$config")" == "$jwt" ]
  [ "$(yq eval -r '.session.secret' "$config")" == "$session" ]
  [ "$(yq eval -r '.storage.encryption_key' "$config")" == "$storage" ]
  [ "$(stat -c '%a' "$config")" == "$mode" ]
}

@test "failed Authelia validation restores the previous configuration.yml" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-enable-form app1
  cmd-login-auth-user-add alice secret

  local config before
  config="$(login_auth_config_file)"
  before="$(cat "$config")"

  docker() { return 0; }
  dokku() {
    if [[ "${1:-}" == "enter" && "${5:-}" == "validate-config" ]]; then
      printf 'invalid configuration\n' >&2
      return 1
    fi
    _dokku_stub "$@"
  }

  run cmd-login-auth-access-set app1 --user alice
  [ "$status" -ne 0 ]
  [[ "$output" == *"Authelia rejected the generated configuration"* ]]
  [ "$(cat "$config")" == "$before" ]
  [ "$(fn-login-auth-access-read app1 | jq -r '.users | length')" -eq 0 ]
}

@test "auth-portal is restarted only when the ACL rules change" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-user-add alice secret

  : >"$TMP/restarts"
  docker() { return 0; }
  fn-login-auth-restart-auth-portal() { printf 'restart\n' >>"$TMP/restarts"; }

  cmd-login-auth-enable-form app1
  [ "$(wc -l <"$TMP/restarts")" -eq 1 ]

  : >"$TMP/restarts"
  cmd-login-auth-access-set app1
  [ ! -s "$TMP/restarts" ]

  cmd-login-auth-access-set app1 --user alice
  [ "$(wc -l <"$TMP/restarts")" -eq 1 ]
}

@test "disable-form removes the app rule" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-enable-form app1
  [ "$(login_auth_rules | jq 'length')" -eq 2 ]

  cmd-login-auth-disable-form app1
  [ "$(login_auth_rules | jq 'length')" -eq 1 ]
}

@test "init regenerates rules from existing app state" {
  fn-login-auth-set-path app1 / form
  cmd-login-auth-init --parent-domain example.com

  local rules
  rules="$(login_auth_rules)"
  [ "$(printf '%s' "$rules" | jq 'length')" -eq 2 ]
  printf '%s' "$rules" | jq -e '.[1].subject == ["user:admin"]'
}

@test "user-remove prunes the username from app allow lists and the ACL" {
  cmd-login-auth-init --parent-domain example.com
  cmd-login-auth-user-add alice secret
  cmd-login-auth-enable-form app1
  cmd-login-auth-access-set app1 --user alice
  login_auth_rules | jq -e '.[1].subject | index("user:alice")'

  cmd-login-auth-user-remove alice

  login_auth_rules | jq -e '.[1].subject == ["user:admin"]'
  [ "$(fn-login-auth-access-read app1 | jq -r '.users | length')" -eq 0 ]
}

@test "init --auth-subdomain uses the subdomain for the portal bypass and redirect URL" {
  cmd-login-auth-init --parent-domain example.com --auth-subdomain sso
  cmd-login-auth-enable-form app1

  local rules
  rules="$(login_auth_rules)"
  [ "$(printf '%s' "$rules" | jq -r '.[0].domain')" == "sso.example.com" ]
  printf '%s' "$rules" | jq -e '.[0].policy == "bypass"'
  printf '%s' "$rules" | jq -e '.[1].domain == ["app1.example.com"]'
  [ "$(yq eval -r '.session.cookies[0].default_redirection_url' "$(login_auth_config_file)")" == "https://sso.example.com" ]
  [ "$(yq eval -r '.session.cookies[0].authelia_url' "$(login_auth_config_file)")" == "https://sso.example.com" ]
}

@test "ACL regeneration preserves the configured auth subdomain" {
  cmd-login-auth-init --parent-domain example.com --auth-subdomain sso
  cmd-login-auth-enable-form app1
  cmd-login-auth-user-add alice secret
  cmd-login-auth-access-set app1 --user alice

  local rules
  rules="$(login_auth_rules)"
  [ "$(printf '%s' "$rules" | jq -r '.[0].domain')" == "sso.example.com" ]
  [ "$(printf '%s' "$rules" | jq -r '.[1].subject | join(",")')" == "user:admin,user:alice" ]
  [ "$(yq eval -r '.session.cookies[0].default_redirection_url' "$(login_auth_config_file)")" == "https://sso.example.com" ]
  [ "$(yq eval -r '.session.cookies[0].authelia_url' "$(login_auth_config_file)")" == "https://sso.example.com" ]
}

@test "re-running init repairs a config with the hardcoded default subdomain" {
  cmd-login-auth-init --parent-domain example.com --auth-subdomain sso

  # Simulate a configuration written by the old hardcoded generator.
  local config
  config="$(login_auth_config_file)"
  AUTH_DOMAIN="auth.example.com" yq eval -i '
    .access_control.rules[0].domain = strenv(AUTH_DOMAIN)
    | .session.cookies[0].authelia_url = ("https://" + strenv(AUTH_DOMAIN))
    | .session.cookies[0].default_redirection_url = ("https://" + strenv(AUTH_DOMAIN))
  ' "$config"
  [ "$(yq eval -r '.session.cookies[0].authelia_url' "$config")" == "https://auth.example.com" ]

  run cmd-login-auth-init --parent-domain example.com
  [ "$status" -eq 0 ]
  [ "$(yq eval -r '.access_control.rules[0].domain' "$config")" == "sso.example.com" ]
  [ "$(yq eval -r '.session.cookies[0].authelia_url' "$config")" == "https://sso.example.com" ]
  [ "$(yq eval -r '.session.cookies[0].default_redirection_url' "$config")" == "https://sso.example.com" ]
}

@test "the ACL generator has no hardcoded auth.<parent> portal domain" {
  run grep -nF '"auth." + $parent' "$REPO_ROOT/functions"
  [ "$status" -ne 0 ]
  run grep -nF 'auth.<PARENT_DOMAIN>' "$REPO_ROOT/templates/configuration.yml.template"
  [ "$status" -ne 0 ]
}
