#!/usr/bin/env bats
load test_helper

@test "yq pins carry checksums for supported architectures" {
  [ "$(fn-login-auth-yq-sha256 amd64)" == "8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f" ]
  [ "$(fn-login-auth-yq-sha256 arm64)" == "189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b" ]
  run fn-login-auth-yq-sha256 riscv64
  [ "$status" -ne 0 ]
}

@test "headers-more detection succeeds when nginx reports it" {
  nginx() { echo "configure arguments: --add-dynamic-module=/build/headers_more"; }
  run fn-login-auth-has-headers-more
  [ "$status" -eq 0 ]
}

@test "headers-more detection fails when absent" {
  nginx() { echo "configure arguments: --with-http_ssl_module"; }
  openresty() { return 127; }
  run fn-login-auth-has-headers-more
  [ "$status" -ne 0 ]
}

@test "authelia image pin is explicit and frozen" {
  [ "$LOGIN_AUTH_AUTHELIA_IMAGE" == "authelia/authelia:4.38.19" ]
  [[ "$LOGIN_AUTH_AUTHELIA_IMAGE" != *":latest"* ]]
}

@test "managed header is present in every generated file" {
  cmd-login-auth-enable-form app1 --path /
  cmd-login-auth-enable-apikey app1 --path /api

  grep -qF '# Managed by dokku-login-auth. Do not edit manually.' "$LOGIN_AUTH_GLOBAL_CONF"
  grep -qF '# Managed by dokku-login-auth. Do not edit manually.' "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-00-internal.conf"
  grep -qF '# Managed by dokku-login-auth. Do not edit manually.' "$DOKKU_ROOT/app1/nginx.conf.d/login-auth-10-server.conf"
}
