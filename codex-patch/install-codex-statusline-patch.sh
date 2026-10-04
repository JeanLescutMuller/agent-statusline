#!/bin/bash
# Build and deploy the smallest supported Codex status-line patch.
# Verbose clone/patch/compiler output stays out of the terminal and in BUILD_LOG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${CODEX_PATCH_RUNTIME:-$HOME/opt/agent-statusline/codex-patch}"
BUILD_LOG="$RUNTIME/build.log"
CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"

mkdir -p "$RUNTIME"
: > "$BUILD_LOG"

die() {
    printf 'Codex patch failed: %s\nBuild log: %s\n' "$1" "$BUILD_LOG" >&2
    exit 1
}

[ -x "$CODEX_BIN" ] || die "Codex is not installed at $CODEX_BIN"
version="$($CODEX_BIN --version | awk '{print $NF}')"
support_file="$ROOT/supported-versions.tsv"
[ -f "$support_file" ] || die "missing $support_file"
commit="$(awk -v wanted="$version" '$1 == wanted { print $2; exit }' "$support_file")"
if [ -z "$commit" ]; then
    printf 'Codex %s has no agent-statusline patch; leaving it unchanged.\n' "$version"
    exit 0
fi
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid commit for Codex $version in $support_file"

patch_file="$ROOT/patches/codex-status-line-command.patch"
[ -f "$patch_file" ] || die "missing $patch_file"
patch_hash="$(shasum -a 256 "$patch_file" | awk '{print $1}')"
host_target="$(rustc -vV 2>/dev/null | awk '/^host:/ {print $2}')"
[ -n "$host_target" ] || die "Rust/Cargo is not installed"

release_root="$HOME/.codex/packages/standalone/releases"
destination="$release_root/$version-status-line-command-lean-$host_target"
marker="$destination/.bootstrap-home-patch"
expected="$commit $patch_hash"

if [ -x "$destination/bin/codex" ] \
    && [ -x "$destination/bin/codex-code-mode-host" ] \
    && [ -f "$marker" ] \
    && [ "$(cat "$marker")" = "$expected" ]; then
    ln -sfn "$destination" "$HOME/.codex/packages/standalone/current"
    printf 'Codex %s status-line patch is already installed.\n' "$version"
    exit 0
fi

# Source clone + Cargo build artifacts run several GB: one fixed-name /tmp
# scratch dir, wiped before every build and removed on exit.
scratch_dir="/tmp/agent-statusline-codex-patch-build"
rm -rf "$scratch_dir"
mkdir -p "$scratch_dir"
trap 'rm -rf "$scratch_dir"' EXIT
source_dir="$scratch_dir/source"

printf 'Preparing Codex %s source...\n' "$version"
git clone --quiet https://github.com/openai/codex.git "$source_dir" >>"$BUILD_LOG" 2>&1 \
    || die "source download failed"
git -C "$source_dir" checkout --quiet "$commit" >>"$BUILD_LOG" 2>&1 \
    || die "upstream commit checkout failed"
git -C "$source_dir" apply --check "$patch_file" >>"$BUILD_LOG" 2>&1 \
    || die "patch no longer applies cleanly"
git -C "$source_dir" apply "$patch_file" >>"$BUILD_LOG" 2>&1 \
    || die "patch application failed"

# Rust 1.98 needs a larger macro recursion allowance for this pinned release.
# This is build compatibility only; it is deliberately outside the functional patch.
cli_main="$source_dir/codex-rs/cli/src/main.rs"
{ printf '#![recursion_limit = "256"]\n'; cat "$cli_main"; } > "$cli_main.tmp"
mv "$cli_main.tmp" "$cli_main"

code_mode_host_source="$(dirname "$CODEX_BIN")/codex-code-mode-host"
[ -x "$code_mode_host_source" ] \
    || die "matching Codex $version code-mode host is not installed at $code_mode_host_source"

printf 'Building quietly (details: %s)...\n' "$BUILD_LOG"
(
    cd "$source_dir/codex-rs"
    # Use Cargo's normal parallelism for fresh-version builds. Callers can set
    # CARGO_BUILD_JOBS when they deliberately need a lower resource ceiling.
    CARGO_PROFILE_RELEASE_LTO=false cargo build --release -p codex-cli
) >>"$BUILD_LOG" 2>&1 || die "compiler failed"

built="$source_dir/codex-rs/target/release/codex"
[ -x "$built" ] || die "compiler produced no Codex binary"
mkdir -p "$destination/bin"
cp "$built" "$destination/bin/codex"
cp "$code_mode_host_source" "$destination/bin/codex-code-mode-host"
strip "$destination/bin/codex" 2>/dev/null || true
"$destination/bin/codex" --version >>"$BUILD_LOG" 2>&1 || die "built binary smoke test failed"
"$destination/bin/codex-code-mode-host" --help >>"$BUILD_LOG" 2>&1 \
    || die "built code-mode host smoke test failed"

mkdir -p "$HOME/.codex/packages/standalone"
ln -sfn "$destination" "$HOME/.codex/packages/standalone/current"
"$CODEX_BIN" features list >>"$BUILD_LOG" 2>&1 || die "deployed binary smoke test failed"
printf '%s\n' "$expected" > "$marker"
printf 'Installed Codex %s status-line patch: %s\n' "$version" "$destination"
