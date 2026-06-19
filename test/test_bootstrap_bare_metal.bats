#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# 共用: 在 run 子进程里 source 脚本并调函数, 隔离 _common.sh 的 set 约束
call_func() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/bootstrap-bare-metal.sh'; $*"
}

# ---- validate_builder_user_name ----

@test "validate_builder_user_name: accepts default 'builder'" {
  call_func "validate_builder_user_name builder"
  [ "$status" -eq 0 ]
}

@test "validate_builder_user_name: accepts 'my_builder' and 'builder\$'" {
  call_func "validate_builder_user_name my_builder"
  [ "$status" -eq 0 ]
  call_func 'validate_builder_user_name "builder\$"'
  [ "$status" -eq 0 ]
}

@test "validate_builder_user_name: rejects 'root'" {
  call_func "validate_builder_user_name root"
  [ "$status" -ne 0 ]
}

@test "validate_builder_user_name: rejects uppercase / digit-start / spaces" {
  call_func "validate_builder_user_name Builder"
  [ "$status" -ne 0 ]
  call_func "validate_builder_user_name 1builder"
  [ "$status" -ne 0 ]
  call_func 'validate_builder_user_name "bu il der"'
  [ "$status" -ne 0 ]
}

# ---- validate_pubkey_line ----

@test "validate_pubkey_line: accepts modern key types" {
  call_func 'validate_pubkey_line "ssh-ed25519 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ssh-rsa AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ecdsa-sha2-nistp256 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ecdsa-sha2-nistp384 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "ecdsa-sha2-nistp521 AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "sk-ssh-ed25519@openssh.com AAAA"'
  [ "$status" -eq 0 ]
  call_func 'validate_pubkey_line "sk-ecdsa-sha2-nistp256@openssh.com AAAA"'
  [ "$status" -eq 0 ]
}

@test "validate_pubkey_line: accepts key with comment (3rd field, spaces in comment ok)" {
  call_func 'validate_pubkey_line "ssh-ed25519 AAAA user@host"'
  [ "$status" -eq 0 ]
  # comment can contain spaces (real authorized_keys allows it)
  call_func 'validate_pubkey_line "ssh-ed25519 AAAA my laptop key"'
  [ "$status" -eq 0 ]
}

@test "validate_pubkey_line: rejects ssh-dss / empty / options / garbage / keytype-only / bad-body" {
  call_func 'validate_pubkey_line "ssh-dss AAAA"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line ""'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "command=foo ssh-ed25519 AAAA"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "not-a-key"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "ssh-ed25519"'
  [ "$status" -ne 0 ]
  call_func 'validate_pubkey_line "ssh-ed25519 "'
  [ "$status" -ne 0 ]
  # body itself (2nd field) must be base64; non-base64 chars reject
  call_func 'validate_pubkey_line "ssh-ed25519 body!with!bangs"'
  [ "$status" -ne 0 ]
}

# ---- check_disk_threshold_inner ----

@test "check_disk_threshold_inner: die <15, warn 15-29, ok >=30" {
  call_func "check_disk_threshold_inner 10"
  [ "$output" = "die" ]
  call_func "check_disk_threshold_inner 14"
  [ "$output" = "die" ]
  call_func "check_disk_threshold_inner 15"
  [ "$output" = "warn" ]
  call_func "check_disk_threshold_inner 29"
  [ "$output" = "warn" ]
  call_func "check_disk_threshold_inner 30"
  [ "$output" = "ok" ]
  call_func "check_disk_threshold_inner 100"
  [ "$output" = "ok" ]
}
