---
name: patch-statusline
description: Restore the custom Codex status line after a Codex CLI update by updating and running agent-statusline's supported binary patch. Use when a Codex update removes the status line or the user asks to patch or reinstall it.
---

# Patch the Codex status line

Work from `/Users/jeanlescut/dev/agent-statusline` on the MacBook. Read that
repository's `AGENTS.md` first and preserve unrelated working-tree changes.
Commit your own work (only your files), never push. Use command `workdir` rather
than changing the user's live shell directory.

1. Read `codex --version`, `codex-patch/supported-versions.tsv`, and the current
   deployment target. If the installed version is already supported, run
   `codex-patch/install-codex-statusline-patch.sh`; its marker fast path should
   relink the patched release without rebuilding.
2. For a new version, resolve the exact official `rust-v<version>` tag from
   `https://github.com/openai/codex.git`. Use the peeled `^{}` commit for an
   annotated tag, falling back to the direct tag commit only for a lightweight
   tag. Never guess a commit or copy one from an unverified source. Add only
   that version/commit row to `supported-versions.tsv`.
3. Run the repository's full hermetic suite as `bash tests/run.sh`, redirecting
   stdout/stderr to `/tmp/agent-statusline-tests.log`. Inspect only the failure
   summary or relevant tail if it fails.
4. Run `codex-patch/install-codex-statusline-patch.sh` as the sole build and
   deployment path. Never drive its clone, Cargo build, copy, marker, or symlink
   steps manually. Do not stream or repeatedly inspect compiler output; the
   script intentionally writes verbose output to its runtime `build.log`.
5. If `git apply --check` rejects the shared patch, use one fixed disposable
   checkout under `/tmp`, wiping it before use. Rebase only the changed upstream
   integration context, keep custom Rust isolated in the existing module, and
   verify `git apply --check` against the new exact commit and every existing
   allowlisted commit. Rerun the full suite, then rerun the installer. Remove
   the disposable checkout afterward even on failure.
6. If compilation fails, inspect only the relevant tail of `build.log`, fix the
   smallest actual compatibility issue, rerun the suite, and retry through the
   installer. Do not bypass an unknown version, failed apply check, failed
   smoke test, or missing matching `codex-code-mode-host`.
7. Verify that `~/.codex/packages/standalone/current` targets the patched release,
   the deployed binary reports the expected version, `[tui].status_line` still
   contains `custom`, and all temporary source/build directories are absent.

Keep user updates concise. A fresh Rust build can be long; wait on the one
scripted process rather than spending turns narrating or polling its log.
