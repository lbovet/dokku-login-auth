#!/usr/bin/env bats
load test_helper

@test "user-add creates a user and user-list never leaks the hash" {
  run cmd-login-auth-user-add alice secret --displayname Alice --email alice@example.com --group admins
  [ "$status" -eq 0 ]

  run cmd-login-auth-user-list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"Alice"* ]]
  [[ "$output" == *"alice@example.com"* ]]
  [[ "$output" == *"admins"* ]]
  [[ "$output" != *"argon2"* ]]

  grep -q 'argon2id' "$(fn-login-auth-users-file)"
}

@test "user-add rejects a duplicate username" {
  cmd-login-auth-user-add alice secret
  run cmd-login-auth-user-add alice other
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "user-passwd replaces the stored hash" {
  cmd-login-auth-user-add alice secret
  local before after
  before="$(yq eval -r '.users.alice.password' "$(fn-login-auth-users-file)")"

  run cmd-login-auth-user-passwd alice newsecret
  [ "$status" -eq 0 ]
  after="$(yq eval -r '.users.alice.password' "$(fn-login-auth-users-file)")"
  [ "$before" != "$after" ]
}

@test "user-passwd fails for an unknown user" {
  run cmd-login-auth-user-passwd nobody secret
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "user-remove deletes the user and is tolerant when missing" {
  cmd-login-auth-user-add alice secret
  run cmd-login-auth-user-remove alice
  [ "$status" -eq 0 ]
  run fn-login-auth-user-exists alice
  [ "$status" -ne 0 ]

  run cmd-login-auth-user-remove alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "user-add stores multiple groups as a list" {
  cmd-login-auth-user-add bob secret --group admins --group ops
  local groups
  groups="$(yq eval -r '.users.bob.groups | join(",")' "$(fn-login-auth-users-file)")"
  [ "$groups" == "admins,ops" ]
}
