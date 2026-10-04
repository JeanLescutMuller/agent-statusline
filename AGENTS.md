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
│   ├── codex_tui.toml       # template merged into ~/.codex/config.toml's [tui] table
│   ├── merge_codex_config.py  # the merge logic, run by install.sh's "codex config" step
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
`codex-patch/supported-versions.tsv` (currently 0.150.1 through 0.154.0). The
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

- `src/statusline/cache.sh`'s `statusline_read_static` shells out to `~/opt/bootstrap-home/bin/get_host_color` for the deterministic per-host color (falls back to a default). Owned by `bootstrap-home`.
- **agent-usage-tracker** (`~/dev/agent-usage-tracker`, split out of this repo on 2026-09-30 - git history before that is here, up to `d744951`). The contract is three files, specified in README.md's "agent-usage-tracker" section: the Claude provider pipes its raw stdin payload into the tracker's `bin/ingest-claude-statusline.sh` and reads back its `state/quota/claude`; the tracker's pollers read this repo's `state/heartbeat/*` mtimes. Rules that keep it clean:
  - Only `providers/claude-statusline-command.sh` references the tracker (enforced by `tests/test_repo_hygiene.sh`), and neither project writes into the other's tree.
  - Forward the payload unchanged - never pick fields for the tracker here, so what it records can change without touching this repo.
  - Never let the tracker break or freeze a render: its output and exit status are ignored, and its state file is used only when it holds a poller reading (`P`) whose `observed_at` beats this repo's own `state/quota/claude` - its `X` readings duplicate our own stdin, stamped by its rules, not ours. The statusline must stay complete on its own (own cross-session cache, `–` when nothing is known).
  - The state file's six-field format and the heartbeat path are a shared format; changing either is a change in both repos.

## Tests

`bash tests/run.sh` before committing a change to `src/statusline/`, `providers/`, `install.sh`, `uninstall.sh`, or `codex-patch/install-codex-statusline-patch.sh`. See `tests/README.md` for what the suite covers and what it deliberately doesn't (the real Codex `git clone` + `cargo build` path; agent-usage-tracker itself, replaced by a stub via `AGENT_USAGE_TRACKER_DIR`). It's hermetic — temp git repos and a temp `$HOME` — and never touches this machine's real `~/.claude`, `~/.codex`, or account state.
