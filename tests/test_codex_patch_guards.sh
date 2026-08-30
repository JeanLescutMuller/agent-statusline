#!/bin/bash
# Tests for codex-patch/install-codex-statusline-patch.sh's fast guard
# clauses only - never the real `git clone` + `cargo build` path, which
# needs network access and minutes of compile time and does not belong in
# this suite. `codex` itself is stubbed via a fake CODEX_BIN executable that
# just answers `--version`.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT="$REPO_ROOT/codex-patch/install-codex-statusline-patch.sh"

fake_codex() {
    local dir="$1" version="$2"
    mkdir -p "$dir"
    cat > "$dir/codex" <<EOF
#!/bin/bash
echo "codex-cli $version"
EOF
    chmod +x "$dir/codex"
    printf '%s/codex' "$dir"
}

section "codex binary missing at CODEX_BIN"
th_run env CODEX_BIN=/nonexistent/codex CODEX_PATCH_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")" \
    bash "$SCRIPT"
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains Codex isn't installed there" "$TH_ERR" "Codex is not installed at"

section "unsupported Codex version"
stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-codexstub.XXXXXX")"
codex_bin="$(fake_codex "$stub_dir" "9.9.9")"
th_run env CODEX_BIN="$codex_bin" CODEX_PATCH_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")" \
    bash "$SCRIPT"
assert_status "exits 0 (informational, not an error)" 0 "$TH_STATUS"
assert_contains "explains the version has no patch" "$TH_OUT" "9.9.9 has no bootstrap-home status-line patch"

section "supported version but the patch file is missing"
isolated_script_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-scriptdir.XXXXXX")"
cp "$SCRIPT" "$isolated_script_dir/install-codex-statusline-patch.sh"
codex_bin="$(fake_codex "$stub_dir" "0.150.1")"
th_run env CODEX_BIN="$codex_bin" CODEX_PATCH_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")" \
    bash "$isolated_script_dir/install-codex-statusline-patch.sh"
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains the patch file is missing" "$TH_ERR" "missing"
rm -rf "$isolated_script_dir"

section "idempotent short-circuit: already-installed marker skips clone/build entirely"
if command -v rustc >/dev/null 2>&1; then
    real_patch="$REPO_ROOT/codex-patch/patches/codex-0.150.1-status-line-command.patch"
    patch_hash="$(shasum -a 256 "$real_patch" | awk '{print $1}')"
    host_target="$(rustc -vV 2>/dev/null | awk '/^host:/ {print $2}')"
    commit="40630160d8d8164626fbfe5b7d2653b5c3d684f8"

    th_home="$(mktemp -d "${TMPDIR:-/tmp}/th-codexhome.XXXXXX")"
    destination="$th_home/.codex/packages/standalone/releases/0.150.1-status-line-command-lean-$host_target"
    mkdir -p "$destination/bin"
    printf '#!/bin/bash\necho stub\n' > "$destination/bin/codex"
    chmod +x "$destination/bin/codex"
    printf '%s %s\n' "$commit" "$patch_hash" > "$destination/.bootstrap-home-patch"

    codex_bin="$(fake_codex "$stub_dir" "0.150.1")"
    runtime="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")"
    th_run env HOME="$th_home" CODEX_BIN="$codex_bin" CODEX_PATCH_RUNTIME="$runtime" bash "$SCRIPT"
    assert_status "exits 0" 0 "$TH_STATUS"
    assert_contains "reports it's already installed" "$TH_OUT" "already installed"
    assert_file_missing "never touches source- (no clone/build was attempted)" "$runtime/source-0.150.1"
    assert_file_exists "symlinks 'current' to the existing deployment" "$th_home/.codex/packages/standalone/current"
    resolved="$(cd "$th_home/.codex/packages/standalone/current" && pwd -P)"
    assert_eq "'current' resolves to the pre-seeded destination" "$(cd "$destination" && pwd -P)" "$resolved"
    rm -rf "$th_home" "$runtime"
else
    section "  (skipped: rustc not on PATH, can't compute host_target)"
fi

rm -rf "$stub_dir"

harness_summary
