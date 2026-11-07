# agent-statusline development instructions

These instructions govern development of this repository. User-facing usage,
runtime layout, and the cache design are documented in `README.md` — this
file only covers things relevant to *working on* the project.

## Instruction-file scope

`CLAUDE.md` at the repository root is a compatibility symlink to this file.

## Repo layout

Two independent mandates, kept in separate trees — see README.md's "Architecture" section for the call-graph diagram.

```
agent-statusline/
├── install.sh                    # deploy onto a bare machine: shared lib, adapters (symlinked from ~/.claude, ~/.codex); drives codex-patch/ conditionally. No migration logic - see uninstall.sh
├── uninstall.sh                  # removes everything install.sh deploys; preserves codex-patch/; flags anything else left over as an orphan
├── utils.sh                      # shared echo/color helpers for install.sh, uninstall.sh, and the patch script
├── providers/                    # statusline architecture: Claude/Codex payload adapters, call into src/statusline/
├── src/statusline/               # statusline architecture: shared cache/format lib + refresh scripts
├── codex-patch/                  # Codex patch: build-time, one-off, unrelated to what runs on a render
│   ├── install-codex-statusline-patch.sh   # clone/patch/build/deploy the Codex binary
│   ├── supported-versions.tsv # exact release-commit allowlist
│   └── patches/              # one shared, cross-version status-line patch
└── tests/                    # hermetic bash test suite, see tests/README.md
```

## Install/uninstall

`install.sh` assumes a bare machine and carries no one-time migration logic. Past renames/restructurings (`lib/` → `src/statusline/`, the `agent-quota-tracker` fold-in and the 2026-09-30 split back out into `agent-usage-tracker`) would each have needed a permanent guard block in `install.sh`, and that only ever grows. If a change needs a layout migration: run `uninstall.sh` (removes what `install.sh` deploys, preserves `codex-patch/`, flags anything else left over as an orphan to check by hand), resolve any reported orphans, then run `install.sh` fresh. Don't add a migration guard back into `install.sh` instead - that's the pattern this pair replaced.

## Codex patch conventions

`codex-patch/install-codex-statusline-patch.sh` is the only supported way to
build and deploy the Codex status-line-command patch — it is deterministic,
idempotent, and quiet: verbose clone/patch/compiler output goes to
`~/opt/agent-statusline/codex-patch/build.log`, and only milestones plus the
final result print to the terminal. Never drive this build by hand-running
`cargo`/`git` steps or by polling compiler output through the model.

Supported Codex versions and their exact upstream release commits live in
`codex-patch/supported-versions.tsv` (currently 0.150.1 through 0.154.0, 0.160.1, 0.164.0 and 0.166.0). The
functional change is one shared patch, with almost all custom Rust isolated in
its own module. Before adding a release to the allowlist, check that the shared
patch applies cleanly to that exact tag and compile it; only re-derive the patch
if upstream changed one of its small integration points. The installer also
runs `git apply --check` before every fresh build and fails closed for unknown
versions. Idempotency is keyed on `<commit> <patch-sha256>` written to a marker
file next to the deployed binary, so changing the shared patch naturally
invalidates every affected marker.

Nothing in `codex-patch/` is sourced by `src/statusline/` or `providers/`,
and nothing in `src/statusline/`/`providers/` is sourced by `codex-patch/`.
`install.sh`/`uninstall.sh` are the only files that reach into both trees
(`uninstall.sh` only to know `codex-patch/`'s deployed directory name, so it
can deliberately leave it alone - see its own header comment).

## Cross-project dependencies

Both are optional: absent, the statusline still renders.

- `src/statusline/cache.sh`'s `statusline_read_host` shells out to `~/opt/my-setup/bin/get_host_color` for the deterministic per-host color (falls back to a default). Owned by `my-setup`.
- **agent-tracker** (`~/dev/agent-tracker`, was `agent-usage-tracker`, split out of this repo on 2026-09-30 - git history before that is here, up to `d744951`). The contract is one file, specified in README.md's "agent-tracker" section: the Claude provider reads `$AGENT_TRACKER_HOME/data/claude/quota_latest.json` (default `~/opt/agent-tracker`) and shows it, after rule 8 (a passed `resets_at` is 0%). Since 2026-11-07 this repo is display only: no tracker script is run here and no heartbeat is written (before: the payload piped into `src/statusline_payload_reader.py`, and `state/heartbeat/*` mtimes). The chain `agent-tracker tick | bash ~/.claude/statusline-command.sh` is my-setup's `statusLine` setting, never this repo's. Rules that keep it clean:
  - Only `providers/claude-statusline-command.sh` references the tracker (enforced by `tests/test_repo_hygiene.sh`), and this repo never writes into the tracker's tree.
  - Never call a tracker script from a render; never write a file for the tracker.
  - Never let the tracker break a render: a missing or unreadable file falls back to the session's own stdin reading, or `–`. The file is the only Claude quota this repo shows besides the session's own (no copy kept here).
  - The file's format is agent-tracker's (its `IMPLEMENTATION.md` §4, the shape of stdin's `rate_limits`); changing it is a change in both repos.

## Tests

`bash tests/run.sh` before committing a change to `src/statusline/`, `providers/`, `install.sh`, `uninstall.sh`, or `codex-patch/install-codex-statusline-patch.sh`. See `tests/README.md` for what the suite covers and what it deliberately doesn't (the real Codex `git clone` + `cargo build` path; agent-tracker itself, replaced by a hand-written `quota_latest.json` under `AGENT_TRACKER_HOME`). It's hermetic — temp git repos and a temp `$HOME` — and never touches this machine's real `~/.claude`, `~/.codex`, or account state.
