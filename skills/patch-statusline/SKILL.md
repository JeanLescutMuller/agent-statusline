---
name: patch-statusline
description: Restore the custom Codex status line after a Codex CLI update by building agent-statusline's Codex patch. Use ONLY when the user expressly asks to build, patch or reinstall the Codex status line, never on your own (a build takes many GB of memory: on 2026-11-19 one took ~19 GB of the Mac's 16 GB); adapt the shared patch only when the installed release needs it.
---

# Patch the Codex status line

**Only when the user expressly asks for it, in that conversation** (the user, 2026-11-19). Never because the status line is missing, never from an install, a job or another agent's request. Before building: `resource-status --need-gb 8`; exit 1 → tell the user and wait.

Two machines (since 2026-11-22, task D3 of data-reorganisation): the code is edited in the NAS clone `~/dev/agent-statusline` (`ssh babisnas`; its development home), and the build runs on the MacBook, where Codex is, from a temporary clone made by my-setup's `dev-install` (`dev-install --run codex-patch/install-codex-statusline-patch.sh agent-statusline`: GitHub's last commit; `DEV_INSTALL_SOURCE=babisnas:dev` in front: the NAS clone's last commit, not pushed yet). The Mac has no `~/dev/agent-statusline` (only the marker `~/dev/agent-statusline.babisnas`). Read the NAS clone's `AGENTS.md` first and preserve unrelated working-tree changes. Commit only your changes there; pushing stays the user's (build an unpushed commit with `DEV_INSTALL_SOURCE=babisnas:dev`). Use command `workdir` rather than changing the user's live shell directory. Restore the installed Codex version; upgrading Codex is a separate request.

## Existing support: run the automation

1. Read `codex --version`, the executable selected by the shell, `codex-patch/supported-versions.tsv` (NAS clone; on the Mac: the clone the build will use), and the current deployment target. Confirm that the installer uses the same installation (`CODEX_BIN` defaults to `~/.local/bin/codex`).
2. If the version is supported, run on the Mac `dev-install --run codex-patch/install-codex-statusline-patch.sh agent-statusline` once. A supported version is not necessarily already built: reuse requires both executables and a marker matching the release commit and patch hash. A matching installation should return immediately; go straight to final verification, without source downloads or a full test run. If a build starts, follow "Build and finish" below.

## New release or compatibility failure

1. Resolve the exact official `rust-v<version>` tag from `https://github.com/openai/codex.git`. Use the peeled `^{}` commit for an annotated tag, or the direct commit for a lightweight tag. Never guess a commit. Add only the verified version/commit row to the allowlist.
2. Before starting a build, use one disposable checkout at `/tmp/agent-statusline-codex-patch-rebase` to check the shared patch against that exact commit. Inspect and clear any leftover checkout before reuse; remove it afterward, including on failure. If the release provides an equivalent native external-command status line, assess that before extending the patch; configurable built-in footer items alone are not equivalent.
3. If `git apply --check` fails, adjust only the changed integration context and keep custom Rust in its existing module. When changing the shared patch, check it against every allowlisted commit. Do not perform a manual build or deployment from this checkout. Commit the change in the NAS clone.
4. After version, patch, or installer changes, run in the NAS clone `bash ~/dev/agent-tracker/tests/run_with_test_tmux.sh bash tests/run.sh > /tmp/agent-statusline-tests.log 2>&1`. Inspect the failure summary only. Distinguish sandbox restrictions and reproduced pre-existing failures from regressions; report them accurately rather than repeatedly rerunning unchanged tests. State any dependency on earlier uncommitted changes.

## Build and finish

Use `codex-patch/install-codex-statusline-patch.sh`, run on the Mac by `dev-install --run codex-patch/install-codex-statusline-patch.sh agent-statusline` (with `DEV_INSTALL_SOURCE=babisnas:dev` for an unpushed NAS commit), as the sole build and deployment path; if it is already running, keep that execution. Its clone, Cargo build, copies, marker, smoke checks, and symlink changes are already programmatic. Verbose output goes to `/Users/jeanlescut/opt/agent-statusline/codex-patch/build.log`; dev-install's own log: `/Users/jeanlescut/opt/my-setup/logs/dev-install/agent-statusline.log`.

A fresh build can take tens of minutes. Keep one execution alive and use background completion notifications when the tool supports them. Otherwise resume the same execution with the longest permitted waits and minimal model work. Do not repeatedly read compiler output, inspect processes, reanalyse the same state, or restart a healthy build because it is slow. Keep required progress updates brief; model reasoning belongs at compatibility failures and the final result.

On compilation failure, inspect the relevant error excerpt, make the smallest compatibility fix, rerun affected checks, and retry through the installer. Never bypass an unknown version, failed patch check, failed smoke test, or missing matching `codex-code-mode-host`. An unsupported version can make the installer exit successfully without installing anything: verify the result.

Finally verify that `~/.codex/packages/standalone/current` targets the expected patched release, its marker matches the commit and patch hash, both executables are present, the binary reports the expected version, and `[tui].status_line` contains `custom`. Confirm the renderer exists and temporary source/build/test directories are removed. Report checks honestly and tell the user to restart Codex to load the patched binary.
