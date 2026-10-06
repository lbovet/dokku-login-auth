#!/usr/bin/env bats
load test_helper

@test "report json exposes paths, modes and the resolved upstream" {
  cmd-login-auth-enable-apikey app1 --path /api
  fn-login-auth-add-key app1 ci topsecret

  local out
  out="$(cmd-login-auth-report app1 --format json)"
  printf '%s' "$out" | jq -e '.app == "app1"'
  printf '%s' "$out" | jq -e '.auth_portal_upstream == "auth-portal-9091"'
  printf '%s' "$out" | jq -e '.paths[0].mode == "apikey"'
  printf '%s' "$out" | jq -e '.paths[0].target == "auth_request:apikey"'
  [[ "$out" != *topsecret* ]]
}

@test "global report json includes every configured app and no hashes" {
  cmd-login-auth-enable-form app1
  cmd-login-auth-enable-apikey app2 --path /api

  local out
  out="$(cmd-login-auth-report --format json)"
  printf '%s' "$out" | jq -e 'length == 2'
  [[ "$out" != *"password"* ]]
}

@test "report text lists configured modes" {
  cmd-login-auth-enable-form app1 --path /admin
  run cmd-login-auth-report app1
  [ "$status" -eq 0 ]
  [[ "$output" == *"form:"* ]]
  [[ "$output" == *"/admin"* ]]
}
