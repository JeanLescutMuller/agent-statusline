# agent-statusline development instructions

These instructions govern development of this repository. User-facing usage,
runtime layout, and the cache design are documented in `README.md` — this
file only covers things relevant to *working on* the project.

## Instruction-file scope

`CLAUDE.md` at the repository root is a compatibility symlink to this file.

## Repo layout

Three independent mandates, kept in separate trees — see README.md's
"Architecture" section for the call-graph diagram.

```
agent-statusline/
├── install.sh              # deploy: shared lib, adapters, quota/ + its LaunchAgent; drives codex-patch/ conditionally
├── utils.sh                # shared echo/color helpers for install.sh and the patch script
├── lib/                    # statusline architecture: shared cache/format lib + refresh scripts
│   ├── statusline-refresh-claude-quota.sh   # fallback: reads the shared quota log
│   └── statusline-push-claude-quota.sh      # primary: pushes live rate_limits to the shared quota log
├── providers/               # statusline architecture: Claude/Codex payload adapters, call into lib/
├── quota/                    # quota tracking: folded in from the former agent-quota-tracker repo,
│   │                          # full git history preserved under this prefix (see its own AGENTS.md)
│   ├── poll_claude.py / poll_codex.py / poll_all.py   # LaunchAgent-scheduled pollers
│   ├── recompute_token_events.py / recompute_codex_events.py   # not scheduled, run by hand
│   ├── analysis.ipynb        # research notebook
│   └── AGENTS.md             # deep-dive: investigation, findings, gotchas - not force-merged into this file
├── codex-patch/              # Codex patch: build-time, one-off, unrelated to what runs on a render
│   ├── install-codex-statusline-patch.sh   # clone/patch/build/deploy the Codex binary
│   ├── codex_tui.toml       # template merged into ~/.codex/config.toml's [tui] table
│   └── patches/              # codex-<version>-status-line-command.patch, per pinned version
├── tests/                    # hermetic bash test suite, see tests/README.md
└── TODO.md                  # deliberately postponed work
```

## Deferred work

See `TODO.md` for deliberately postponed project improvements.

## Codex patch conventions

`codex-patch/install-codex-statusline-patch.sh` is the only supported way to
build and deploy the Codex status-line-command patch — it is deterministic,
idempotent, and quiet: verbose clone/patch/compiler output goes to
`~/opt/agent-statusline/codex-patch/build.log`, and only milestones plus the
final result print to the terminal. Never drive this build by hand-running
`cargo`/`git` steps or by polling compiler output through the model.

Only one Codex version is supported at a time (currently 0.150.1, hardcoded
in the script's `case` statement alongside its pinned upstream commit). To
add support for a new version: find the commit that introduces
`status_line_command` support upstream (or re-derive the patch against the
new pin), add a `codex-patch/patches/codex-<version>-status-line-command.patch`,
and add a case for it. Idempotency is keyed on `<commit> <patch-sha256>`
written to a marker file next to the deployed binary — bump the patch file
and the marker naturally invalidates.

Nothing in `codex-patch/` is sourced by `lib/` or `providers/`, and nothing
in `lib/`/`providers/` is sourced by `codex-patch/`. `install.sh` is the only
file that reaches into both trees.

## Cross-project dependency

`lib/statusline-cache.sh`'s `statusline_read_static` shells out to
`~/opt/bootstrap-home/bin/get_host_color` for the deterministic per-host
color (falls back to a default if absent — not a hard dependency). That
script is owned by `bootstrap-home`, not this repo.

## Quota tracking (`quota/`)

Folded in from the former `agent-quota-tracker` repo (merged 2026-08-31,
full git history preserved under the `quota/` prefix — the old repo's
"Cross-project dependency" section, describing this exact coupling as a
cross-repo one, is now obsolete; this section replaces it). Read
`quota/AGENTS.md` for the actual investigation, findings, and gotchas — it's
kept as its own file rather than merged into this one, the same way
`codex-patch/`'s own conventions live in this file rather than README.md.

The coupling between `quota/` and `lib/`/`providers/` is file-based, not a
`source`/import — see README.md's "Architecture" section for exactly which
scripts read/write `data/utilization-log.jsonl`. One thing worth stating
plainly here since it's easy to get backwards: `lib/statusline-push-claude-quota.sh`
is the *primary* Claude quota path now (free, rides existing traffic, never
rate-limited); `lib/statusline-refresh-claude-quota.sh` + `quota/poll_claude.py`
are a *fallback* for the one gap the push path can't cover — a session that
hasn't sent its first message yet, or a machine-wide idle stretch with no
statusline rendering anywhere at all.

`providers/claude-statusline-command.sh` touches `state/providers/claude.heartbeat`
on every render specifically so `quota/poll_claude.py` can tell a statusline
is live and poll faster (see `quota/AGENTS.md`'s "Architecture" section) —
this is the one piece of the old cross-repo coupling that's still real,
just intra-repo now instead of cross-repo.

## Tests

`bash tests/run.sh` before committing a change to `lib/`, `providers/`,
`quota/`, `install.sh`, or `codex-patch/install-codex-statusline-patch.sh`.
See `tests/README.md` for what the suite covers and what it deliberately
doesn't (the real Codex `git clone` + `cargo build` path; live
Anthropic/Keychain calls — the Keychain read lives entirely in
`quota/poll_claude.py`). It's hermetic — temp git repos, a temp `$HOME`, a
fixture quota log, `AGENT_STATUSLINE_SKIP_LAUNCHD=1` to keep `install.sh`'s
LaunchAgent step off the real `gui/$(id -u)` launchd domain — never touches
this machine's real `~/.claude`, `~/.codex`, or account state.
