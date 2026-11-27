#!/usr/bin/env bats
load test_helper

@test "access-set stores users and groups; access-list shows them" {
  cmd-login-auth-user-add alice secret --group devs
  cmd-login-auth-user-add bob secret

  run cmd-login-auth-access-set app1 --user alice --user bob --group devs
  [ "$status" -eq 0 ]

  run cmd-login-auth-access-list app1
  [ "$status" -eq 0 ]
  [[ "$output" == *"users: alice,bob"* ]]
  [[ "$output" == *"groups: devs"* ]]
}

@test "access-set with no flags clears the allow list (admin-only)" {
  cmd-login-auth-user-add alice secret
  cmd-login-auth-access-set app1 --user alice

  run cmd-login-auth-access-set app1
  [ "$status" -eq 0 ]

  run cmd-login-auth-access-list app1
  [[ "$output" == *"users: (none)"* ]]
  [[ "$output" == *"groups: (none)"* ]]
}

@test "access-set rejects an unknown user before writing" {
  cmd-login-auth-user-add alice secret
  cmd-login-auth-access-set app1 --user alice
  local before
  before="$(cat "$(fn-login-auth-state-file app1)")"

  run cmd-login-auth-access-set app1 --user nobody
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [ "$(cat "$(fn-login-auth-state-file app1)")" == "$before" ]
}

@test "access-set warns for a group with no members but succeeds" {
  cmd-login-auth-user-add alice secret

  run cmd-login-auth-access-set app1 --group ghost
  [ "$status" -eq 0 ]
  [[ "$output" == *"no members"* ]]

  run cmd-login-auth-access-list app1
  [[ "$output" == *"groups: ghost"* ]]
}

@test "access-set rejects invalid names" {
  cmd-login-auth-user-add alice secret

  run cmd-login-auth-access-set app1 --user 'bad:name'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid username"* ]]

  run cmd-login-auth-access-set app1 --group 'bad name'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid group name"* ]]
}

@test "access-set sorts and deduplicates names" {
  cmd-login-auth-user-add alice secret
  cmd-login-auth-user-add bob secret

  cmd-login-auth-access-set app1 --user bob --user alice --user bob
  local users
  users="$(fn-login-auth-access-read app1 | jq -r '.users | join(",")')"
  [ "$users" == "alice,bob" ]
}

@test "access-set is idempotent" {
  cmd-login-auth-user-add alice secret
  cmd-login-auth-access-set app1 --user alice --group devs
  local before
  before="$(cat "$(fn-login-auth-state-file app1)")"

  cmd-login-auth-access-set app1 --user alice --group devs
  [ "$(cat "$(fn-login-auth-state-file app1)")" == "$before" ]
}

@test "state without an access key is admin-only" {
  fn-login-auth-state-write app1 '{"app":"app1","paths":[]}'
  local access
  access="$(fn-login-auth-access-read app1)"
  [ "$(printf '%s' "$access" | jq -r '.users | length')" -eq 0 ]
  [ "$(printf '%s' "$access" | jq -r '.groups | length')" -eq 0 ]
}

@test "report json includes the access allow list" {
  cmd-login-auth-user-add alice secret
  cmd-login-auth-enable-form app1
  cmd-login-auth-access-set app1 --user alice --group devs

  local out
  out="$(cmd-login-auth-report app1 --format json)"
  printf '%s' "$out" | jq -e '.access.users == ["alice"]'
  printf '%s' "$out" | jq -e '.access.groups == ["devs"]'
}

@test "report text shows the access allow list" {
  cmd-login-auth-user-add alice secret
  cmd-login-auth-enable-form app1
  cmd-login-auth-access-set app1 --user alice --group devs

  run cmd-login-auth-report app1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Allow-list users:"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"Allow-list groups:"* ]]
  [[ "$output" == *"devs"* ]]
}

@test "access-list on an app with no state shows empty allow lists" {
  run cmd-login-auth-access-list app1
  [ "$status" -eq 0 ]
  [[ "$output" == *"users: (none)"* ]]
  [[ "$output" == *"groups: (none)"* ]]
}

@test "access-set accepts --user= and --group= forms" {
  cmd-login-auth-user-add alice secret

  run cmd-login-auth-access-set app1 --user=alice --group=devs
  [ "$status" -eq 0 ]

  run cmd-login-auth-access-list app1
  [[ "$output" == *"users: alice"* ]]
  [[ "$output" == *"groups: devs"* ]]
}
