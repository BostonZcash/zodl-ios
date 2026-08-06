#!/usr/bin/env bats

setup() {
  export FASTLANE_CMD=echo
  RELEASE="$BATS_TEST_DIRNAME/../release.sh"
}

@test "translates GNU flags to fastlane key:value" {
  run "$RELEASE" --variant appstore --ref release/3.8.0 --version 3.8.0 --build 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"release variant:appstore ref:release/3.8.0 version:3.8.0 build:3"* ]]
}

@test "forwards --dry-run as dry_run:true" {
  run "$RELEASE" --variant testnet --ref main --version 3.8.0 --build 1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry_run:true"* ]]
}

@test "forwards --yes as yes:true" {
  run "$RELEASE" --variant internal --ref main --version 3.8.0 --build 1 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"yes:true"* ]]
}

@test "forwards -y as yes:true" {
  run "$RELEASE" --variant internal --ref main --version 3.8.0 --build 1 -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"yes:true"* ]]
}

@test "missing --build exits 2" {
  run "$RELEASE" --variant appstore --ref main --version 3.8.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--build is required"* ]]
}

@test "unknown flag exits 2" {
  run "$RELEASE" --variant appstore --bogus x
  [ "$status" -eq 2 ]
}

@test "--help exits 0 and prints usage" {
  run "$RELEASE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: Scripts/release.sh"* ]]
}
