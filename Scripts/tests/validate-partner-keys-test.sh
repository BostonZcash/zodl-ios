#!/bin/bash
#
# Tests for ../validate-partner-keys.sh.
# Creates temp PartnerKeys.plist fixtures, runs the validator with ACTION/SRCROOT
# set, and asserts the exit code. No external test framework.
# Run by hand:  bash Scripts/tests/validate-partner-keys-test.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/../validate-partner-keys.sh"

pass=0
fail=0

# run_case <name> <ACTION> <plist-body | __MISSING__> <expected-exit-code>
run_case() {
    name="$1"
    action="$2"
    body="$3"
    expected="$4"

    root="$(mktemp -d)"
    mkdir -p "${root}/secant/Resources"
    if [ "$body" != "__MISSING__" ]; then
        printf '%s\n' "$body" > "${root}/secant/Resources/PartnerKeys.plist"
    fi

    out="$(ACTION="$action" SRCROOT="$root" "$VALIDATOR" 2>&1)"
    rc=$?
    rm -rf "$root"

    if [ "$rc" -eq "$expected" ]; then
        echo "ok   - ${name} (exit ${rc})"
        pass=$((pass + 1))
    else
        echo "FAIL - ${name}: expected exit ${expected}, got ${rc}"
        echo "       output: ${out}"
        fail=$((fail + 1))
    fi
}

HEADER='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'

FULL="${HEADER}
<plist version=\"1.0\">
<dict>
    <key>cbProjectId</key><string>a</string>
    <key>flexaPublishableKey</key><string>a</string>
    <key>flexaPublishableTestKey</key><string>a</string>
    <key>nearKey</key><string>a</string>
    <key>cmcKey</key><string>a</string>
    <key>nearFeeDepositAddress</key><string>a</string>
    <key>nearAPIKey</key><string>a</string>
</dict>
</plist>"

EMPTY_DUMMY="${HEADER}
<plist version=\"1.0\"><dict/></plist>"

ONE_EMPTY="${HEADER}
<plist version=\"1.0\">
<dict>
    <key>cbProjectId</key><string></string>
    <key>flexaPublishableKey</key><string>a</string>
    <key>flexaPublishableTestKey</key><string>a</string>
    <key>nearKey</key><string>a</string>
    <key>cmcKey</key><string>a</string>
    <key>nearFeeDepositAddress</key><string>a</string>
    <key>nearAPIKey</key><string>a</string>
</dict>
</plist>"

WRONG_TYPE="${HEADER}
<plist version=\"1.0\">
<dict>
    <key>cbProjectId</key><integer>5</integer>
    <key>flexaPublishableKey</key><string>a</string>
    <key>flexaPublishableTestKey</key><string>a</string>
    <key>nearKey</key><string>a</string>
    <key>cmcKey</key><string>a</string>
    <key>nearFeeDepositAddress</key><string>a</string>
    <key>nearAPIKey</key><string>a</string>
</dict>
</plist>"

run_case "valid full plist passes (archive)"   install "$FULL"        0
run_case "empty dummy fails (archive)"          install "$EMPTY_DUMMY" 1
run_case "malformed plist fails (archive)"      install "not a plist"  1
run_case "missing file fails (archive)"         install "__MISSING__"  1
run_case "one empty value fails (archive)"      install "$ONE_EMPTY"   1
run_case "non-string value fails (archive)"     install "$WRONG_TYPE"  1
run_case "normal build is a no-op (bad plist)"  build   "$EMPTY_DUMMY" 0

echo
echo "Passed: ${pass}  Failed: ${fail}"
[ "$fail" -eq 0 ]
