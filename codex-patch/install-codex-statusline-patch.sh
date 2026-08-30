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

case "$version" in
    0.150.1) commit="40630160d8d8164626fbfe5b7d2653b5c3d684f8" ;;
    *)
        printf 'Codex %s has no bootstrap-home status-line patch; leaving it unchanged.\n' "$version"
        exit 0
        ;;
esac

patch_file="$ROOT/patches/codex-$version-status-line-command.patch"
[ -f "$patch_file" ] || die "missing $patch_file"
patch_hash="$(shasum -a 256 "$patch_file" | awk '{print $1}')"
host_target="$(rustc -vV 2>/dev/null | awk '/^host:/ {print $2}')"
[ -n "$host_target" ] || die "Rust/Cargo is not installed"

release_root="$HOME/.codex/packages/standalone/releases"
destination="$release_root/$version-status-line-command-lean-$host_target"
marker="$destination/.bootstrap-home-patch"
expected="$commit $patch_hash"

if [ -x "$destination/bin/codex" ] && [ -f "$marker" ] \
    && [ "$(cat "$marker")" = "$expected" ]; then
    ln -sfn "$destination" "$HOME/.codex/packages/standalone/current"
    printf 'Codex %s status-line patch is already installed.\n' "$version"
    exit 0
fi

source_dir="$RUNTIME/source-$version"
printf 'Preparing Codex %s source...\n' "$version"
rm -rf "$source_dir.new"
git clone --quiet https://github.com/openai/codex.git "$source_dir.new" >>"$BUILD_LOG" 2>&1 \
    || die "source download failed"
git -C "$source_dir.new" checkout --quiet "$commit" >>"$BUILD_LOG" 2>&1 \
    || die "upstream commit checkout failed"
git -C "$source_dir.new" apply --check "$patch_file" >>"$BUILD_LOG" 2>&1 \
    || die "patch no longer applies cleanly"
git -C "$source_dir.new" apply "$patch_file" >>"$BUILD_LOG" 2>&1 \
    || die "patch application failed"

# Rust 1.98 needs a larger macro recursion allowance for this pinned release.
# This is build compatibility only; it is deliberately outside the functional patch.
cli_main="$source_dir.new/codex-rs/cli/src/main.rs"
if ! grep -q '^#!\[recursion_limit = "256"\]' "$cli_main"; then
    { printf '#![recursion_limit = "256"]\n'; cat "$cli_main"; } > "$cli_main.tmp"
    mv "$cli_main.tmp" "$cli_main"
fi
rm -rf "$source_dir"
mv "$source_dir.new" "$source_dir"

printf 'Building quietly (details: %s)...\n' "$BUILD_LOG"
(
    cd "$source_dir/codex-rs"
    CARGO_PROFILE_RELEASE_LTO=false cargo build --release -j 1 -p codex-cli
) >>"$BUILD_LOG" 2>&1 || die "compiler failed"

built="$source_dir/codex-rs/target/release/codex"
[ -x "$built" ] || die "compiler produced no Codex binary"
mkdir -p "$destination/bin"
cp "$built" "$destination/bin/codex"
strip "$destination/bin/codex" 2>/dev/null || true
printf '%s\n' "$expected" > "$marker"
"$destination/bin/codex" --version >>"$BUILD_LOG" 2>&1 || die "built binary smoke test failed"

mkdir -p "$HOME/.codex/packages/standalone"
ln -sfn "$destination" "$HOME/.codex/packages/standalone/current"
"$CODEX_BIN" features list >>"$BUILD_LOG" 2>&1 || die "deployed binary smoke test failed"
printf 'Installed Codex %s status-line patch: %s\n' "$version" "$destination"
