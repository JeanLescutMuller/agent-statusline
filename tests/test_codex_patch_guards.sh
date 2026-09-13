#!/bin/bash
# Tests for codex-patch/install-codex-statusline-patch.sh's fast guard
# clauses only - never the real `git clone` + `cargo build` path, which
# needs network access and minutes of compile time and does not belong in
# this suite. `codex` itself is stubbed via a fake CODEX_BIN executable that
# just answers `--version`.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

SCRIPT="$REPO_ROOT/codex-patch/install-codex-statusline-patch.sh"
PATCH="$REPO_ROOT/codex-patch/patches/codex-status-line-command.patch"
SUPPORTED="$REPO_ROOT/codex-patch/supported-versions.tsv"

pinned_commit() {
    awk -v wanted="$1" '$1 == wanted { print $2; exit }' "$SUPPORTED"
}

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
assert_contains "explains the version has no patch" "$TH_OUT" "9.9.9 has no agent-statusline patch"

section "supported version but the patch file is missing"
isolated_script_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-scriptdir.XXXXXX")"
cp "$SCRIPT" "$isolated_script_dir/install-codex-statusline-patch.sh"
cp "$SUPPORTED" "$isolated_script_dir/supported-versions.tsv"
codex_bin="$(fake_codex "$stub_dir" "0.150.1")"
th_run env CODEX_BIN="$codex_bin" CODEX_PATCH_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")" \
    bash "$isolated_script_dir/install-codex-statusline-patch.sh"
assert_status "exits 1" 1 "$TH_STATUS"
assert_contains "explains the patch file is missing" "$TH_ERR" "missing"
rm -rf "$isolated_script_dir"

section "build/deploy keeps the Code Mode companion binary"
script_text="$(cat "$SCRIPT")"
assert_contains "requires the matching installed code-mode host" "$script_text" \
    'matching Codex $version code-mode host is not installed'
assert_contains "copies the matching code-mode host into the custom release" "$script_text" \
    'cp "$code_mode_host_source" "$destination/bin/codex-code-mode-host"'
assert_not_contains "does not strip the signed official code-mode host" "$script_text" \
    'strip "$destination/bin/codex" "$destination/bin/codex-code-mode-host"'
assert_contains "smoke-tests codex-code-mode-host before marking success" "$script_text" \
    '"$destination/bin/codex-code-mode-host" --help'
assert_contains "builds in a scratch dir under TMPDIR, never under the persistent runtime dir" \
    "$script_text" '${TMPDIR:-/tmp}/agent-statusline-codex-patch-build'
assert_not_contains "scratch dir has a fixed name, not a fresh mktemp per run (never more than one on disk)" \
    "$script_text" 'mktemp -d "${TMPDIR:-/tmp}/agent-statusline-codex-patch'
assert_contains "wipes the scratch dir before building, so a crash/kill-9 run can't leave a second one behind" \
    "$script_text" 'rm -rf "$scratch_dir"
mkdir -p "$scratch_dir"'
assert_contains "also cleans up its scratch dir on a normal exit, success or failure" "$script_text" \
    "trap 'rm -rf \"\$scratch_dir\"' EXIT"

section "idempotent short-circuit: already-installed marker skips clone/build entirely"
patch_hash="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
host_target="test-host-target"
commit="$(pinned_commit 0.150.1)"
rustc_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-rustcstub.XXXXXX")"
printf '#!/bin/bash\nprintf "host: test-host-target\\n"\n' > "$rustc_stub_dir/rustc"
chmod +x "$rustc_stub_dir/rustc"

th_home="$(mktemp -d "${TMPDIR:-/tmp}/th-codexhome.XXXXXX")"
destination="$th_home/.codex/packages/standalone/releases/0.150.1-status-line-command-lean-$host_target"
mkdir -p "$destination/bin"
printf '#!/bin/bash\necho stub\n' > "$destination/bin/codex"
printf '#!/bin/bash\necho stub\n' > "$destination/bin/codex-code-mode-host"
chmod +x "$destination/bin/codex" "$destination/bin/codex-code-mode-host"
printf '%s %s\n' "$commit" "$patch_hash" > "$destination/.bootstrap-home-patch"

codex_bin="$(fake_codex "$stub_dir" "0.150.1")"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")"
th_run env HOME="$th_home" PATH="$rustc_stub_dir:$PATH" CODEX_BIN="$codex_bin" \
    CODEX_PATCH_RUNTIME="$runtime" bash "$SCRIPT"
assert_status "exits 0" 0 "$TH_STATUS"
assert_contains "reports it's already installed" "$TH_OUT" "already installed"
assert_file_missing "never touches source- (no clone/build was attempted)" "$runtime/source-0.150.1"
assert_file_exists "symlinks 'current' to the existing deployment" "$th_home/.codex/packages/standalone/current"
resolved="$(cd "$th_home/.codex/packages/standalone/current" && pwd -P)"
assert_eq "'current' resolves to the pre-seeded destination" "$(cd "$destination" && pwd -P)" "$resolved"
assert_file_exists "the deployed release includes the code-mode host" \
    "$th_home/.codex/packages/standalone/current/bin/codex-code-mode-host"
rm -rf "$th_home" "$runtime"

section "stale marker without code-mode host does not short-circuit"
th_home="$(mktemp -d "${TMPDIR:-/tmp}/th-codexhome.XXXXXX")"
destination="$th_home/.codex/packages/standalone/releases/0.150.1-status-line-command-lean-$host_target"
mkdir -p "$destination/bin"
printf '#!/bin/bash\necho stub\n' > "$destination/bin/codex"
chmod +x "$destination/bin/codex"
printf '%s %s\n' "$commit" "$patch_hash" > "$destination/.bootstrap-home-patch"

git_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/th-gitstub.XXXXXX")"
printf '#!/bin/bash\nexit 1\n' > "$git_stub_dir/git"
chmod +x "$git_stub_dir/git"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")"
th_run env HOME="$th_home" PATH="$git_stub_dir:$rustc_stub_dir:$PATH" CODEX_BIN="$codex_bin" \
    CODEX_PATCH_RUNTIME="$runtime" bash "$SCRIPT"
assert_status "attempts a rebuild" 1 "$TH_STATUS"
assert_contains "reaches the clone path" "$TH_ERR" "source download failed"
assert_not_contains "does not report the incomplete release as installed" "$TH_OUT" \
    "already installed"
rm -rf "$th_home" "$git_stub_dir" "$runtime"

section "all newer supported Codex releases use the shared patch and pinned commits"
patch_hash="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
for release_version in 0.151.0 0.152.0; do
    commit="$(pinned_commit "$release_version")"
    th_home="$(mktemp -d "${TMPDIR:-/tmp}/th-codexhome.XXXXXX")"
    destination="$th_home/.codex/packages/standalone/releases/$release_version-status-line-command-lean-$host_target"
    mkdir -p "$destination/bin"
    printf '#!/bin/bash\necho stub\n' > "$destination/bin/codex"
    printf '#!/bin/bash\necho stub\n' > "$destination/bin/codex-code-mode-host"
    chmod +x "$destination/bin/codex" "$destination/bin/codex-code-mode-host"
    printf '%s %s\n' "$commit" "$patch_hash" > "$destination/.bootstrap-home-patch"
    codex_bin="$(fake_codex "$stub_dir" "$release_version")"
    runtime="$(mktemp -d "${TMPDIR:-/tmp}/th-cprt.XXXXXX")"
    th_run env HOME="$th_home" PATH="$rustc_stub_dir:$PATH" CODEX_BIN="$codex_bin" \
        CODEX_PATCH_RUNTIME="$runtime" bash "$SCRIPT"
    assert_status "$release_version exits 0" 0 "$TH_STATUS"
    assert_contains "reports $release_version is already installed" "$TH_OUT" \
        "$release_version status-line patch is already installed"
    assert_file_missing "does not rebuild the matching $release_version release" \
        "$runtime/source-$release_version"
    assert_file_exists "the $release_version release includes the code-mode host" \
        "$th_home/.codex/packages/standalone/current/bin/codex-code-mode-host"
    rm -rf "$th_home" "$runtime"
done
rm -rf "$rustc_stub_dir"

rm -rf "$stub_dir"

harness_summary
