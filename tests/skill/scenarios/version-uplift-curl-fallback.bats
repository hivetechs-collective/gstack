#!/usr/bin/env bats
# tests/skill/scenarios/version-uplift-curl-fallback.bats
#
# Spec: docs/specs/version-uplift-auto-chain.md (AC1)
#
# fetch-changelog.sh --curl parses stubbed curl output correctly. Covers:
#   - basic parse via curl
#   - redirect chain (curl -L handles automatically; verify we pass -L)
#   - --curl-url override

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

setup() {
  sandbox
  sandbox_git_init
  mkdir -p .claude/state .claude/scripts/version-uplift .stub-bin
  cp -R "$REPO_ROOT/.claude/scripts/." .claude/scripts/

  export STUBBED_PATH="$SANDBOX_DIR/.stub-bin:$PATH"
}

teardown() { teardown_sandbox; }

# Helper: write a curl stub that echoes a payload.
make_curl_stub() {
  local payload_file="$1"
  cat > .stub-bin/curl <<STUB_EOF
#!/usr/bin/env bash
# Record argv so tests can assert curl was called with -L.
echo "argv=\$*" >> "$SANDBOX_DIR/curl.log"
cat "$payload_file"
STUB_EOF
  chmod +x .stub-bin/curl
}

# ─── AC1 — basic parse via curl ──────────────────────────────────────────────
@test "AC1 curl mode parses changelog from stubbed curl" {
  cat > payload.md <<'EOF'
## 2.1.149

- entry-A
- entry-B

## 2.1.148

- earlier-entry
EOF
  make_curl_stub "$SANDBOX_DIR/payload.md"

  PATH="$STUBBED_PATH" run .claude/scripts/version-uplift/fetch-changelog.sh \
    --curl --to=2.1.149 --from=2.1.148
  assert_success

  # Output must be a JSON document with one 2.1.149 entry.
  echo "$output" | jq -e '.source == "curl"'
  echo "$output" | jq -e '.versions[0].version == "2.1.149"'
  echo "$output" | jq -e '.versions[0].entries | length == 2'

  # Curl must have been invoked with L (follow redirects) — either as
  # bundled `-fsSL` (current implementation) or as a standalone `-L`.
  grep -qE -- '-[a-zA-Z]*L|--location' "$SANDBOX_DIR/curl.log" \
    || { echo "expected curl invocation to include L for redirect handling"; cat "$SANDBOX_DIR/curl.log"; false; }

  echo "AC1: PASS"
}

# ─── AC1 — redirect chain via -L is transparent ──────────────────────────────
@test "AC1 redirect-chain transparency: stub simulates 301 → 200" {
  # curl -L makes redirect handling automatic — the stub returns the final
  # body. We just verify the parser sees the payload and SOURCE=curl.
  cat > redirected-body.md <<'EOF'
## 2.1.149

- redirected-entry

EOF
  make_curl_stub "$SANDBOX_DIR/redirected-body.md"

  PATH="$STUBBED_PATH" run .claude/scripts/version-uplift/fetch-changelog.sh \
    --curl --to=2.1.149
  assert_success
  echo "$output" | jq -e '.versions[0].entries[0] | contains("redirected-entry")'

  echo "AC1: PASS"
}

# ─── --curl-url override ─────────────────────────────────────────────────────
@test "AC1 --curl-url=... overrides default URL" {
  cat > payload.md <<'EOF'
## 2.1.149

- from-custom-url

EOF
  make_curl_stub "$SANDBOX_DIR/payload.md"

  PATH="$STUBBED_PATH" run .claude/scripts/version-uplift/fetch-changelog.sh \
    --curl-url=https://example.invalid/CHANGELOG.md --to=2.1.149
  assert_success
  grep -q 'example.invalid' "$SANDBOX_DIR/curl.log" \
    || { echo "expected custom URL in argv"; cat "$SANDBOX_DIR/curl.log"; false; }

  echo "AC1: PASS"
}
