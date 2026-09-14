# agent-statusline development instructions

These instructions govern development of this repository. User-facing usage,
runtime layout, and the cache design are documented in `README.md` — this
file only covers things relevant to *working on* the project.

## Instruction-file scope

`CLAUDE.md` at the repository root is a compatibility symlink to this file.

## Repo layout

Four independent mandates, kept in separate trees — see README.md's
"Architecture" section for the call-graph diagram.

```
agent-statusline/
├── install.sh                    # deploy onto a bare machine: shared lib, adapters, src/quota_polling/ + adhoc_quotas_analysis/ + their LaunchAgent; drives codex-patch/ conditionally. No migration logic - see uninstall.sh
├── uninstall.sh                  # removes everything install.sh deploys; preserves data/ and codex-patch/; flags anything else left under ~/opt/agent-statusline as an orphan
├── utils.sh                      # shared echo/color helpers for install.sh, uninstall.sh, and the patch script
├── providers/                    # statusline architecture: Claude/Codex payload adapters, call into src/statusline/
├── src/
│   ├── statusline/                # statusline architecture: shared cache/format lib + refresh scripts
│   │   ├── refresh-claude-quota.sh   # fallback: reads the claude quota log
│   │   └── push-claude-quota.sh      # primary: pushes live rate_limits to the claude quota log
│   └── quota_polling/            # quota polling: LaunchAgent-scheduled, deployed, unattended production code
│       ├── poll_claude.py / poll_codex.py       # per-provider pollers
│       ├── poll_all.py                          # the actual LaunchAgent entry point, runs both as subprocesses
│       └── com.jeanlescut.agent-statusline.plist.template  # __PYTHON3__/__RUNTIME__ placeholders, filled by install.sh
├── adhoc_quotas_analysis/        # quota research: folded in from the former agent-quota-tracker repo,
│                                 # full git history preserved under this prefix (see its own AGENTS.md)
│   ├── split_quota_log.py        # one-time, idempotent log-split migration, run by hand only if you still have an old combined data/quota-log.jsonl
│   ├── recompute_codex_events.py # not scheduled, run by hand (Claude side is now inline in analysis.ipynb's own cells)
│   ├── analysis.ipynb            # research notebook - recomputes claude-token-events.jsonl itself, top of the notebook
│   └── AGENTS.md                 # deep-dive: investigation, findings, gotchas - not force-merged into this file
├── codex-patch/                   # Codex patch: build-time, one-off, unrelated to what runs on a render
│   ├── install-codex-statusline-patch.sh   # clone/patch/build/deploy the Codex binary
│   ├── codex_tui.toml       # template merged into ~/.codex/config.toml's [tui] table
│   ├── merge_codex_config.py  # the merge logic, run by install.sh's "codex config" step
│   ├── supported-versions.tsv # exact release-commit allowlist
│   └── patches/              # one shared, cross-version status-line patch
├── tests/                    # hermetic bash test suite, see tests/README.md
└── TODO.md                  # deliberately postponed work
```

## Install/uninstall

`install.sh` assumes a bare machine and carries no one-time migration logic
- past renames/restructurings (`lib/` → `src/statusline/`, the
  `agent-quota-tracker` fold-in, the quota-log filename/split history, see
  `adhoc_quotas_analysis/AGENTS.md`'s "Naming history") each got a permanent
  guard block in `install.sh` at the time, and that only ever grows. If a
  future change needs the same kind of layout migration: run `uninstall.sh`
  (removes what `install.sh` deploys, preserves `data/` and `codex-patch/`,
  flags anything else left over as an orphan to check by hand), resolve any
  reported orphans, then run `install.sh` fresh. Don't add a migration guard
  back into `install.sh` instead - that's the pattern this pair replaced.

## Deferred work

See `TODO.md` for deliberately postponed project improvements.

## Codex patch conventions

`codex-patch/install-codex-statusline-patch.sh` is the only supported way to
build and deploy the Codex status-line-command patch — it is deterministic,
idempotent, and quiet: verbose clone/patch/compiler output goes to
`~/opt/agent-statusline/codex-patch/build.log`, and only milestones plus the
final result print to the terminal. Never drive this build by hand-running
`cargo`/`git` steps or by polling compiler output through the model.

Supported Codex versions and their exact upstream release commits live in
`codex-patch/supported-versions.tsv` (currently 0.150.1 through 0.153.0). The
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

## Cross-project dependency

`src/statusline/cache.sh`'s `statusline_read_static` shells out to
`~/opt/bootstrap-home/bin/get_host_color` for the deterministic per-host
color (falls back to a default if absent — not a hard dependency). That
script is owned by `bootstrap-home`, not this repo.

## Quota tracking (`src/quota_polling/` + `adhoc_quotas_analysis/`)

Folded in from the former `agent-quota-tracker` repo (merged 2026-08-31,
full git history preserved under the `adhoc_quotas_analysis/` prefix — the old repo's
"Cross-project dependency" section, describing this exact coupling as a
cross-repo one, is now obsolete; this section replaces it). The
LaunchAgent-scheduled pollers (`poll_claude.py`, `poll_codex.py`,
`poll_all.py`) were split out into their own `src/quota_polling/` tree the
same day, once deployed and running unattended made them a genuinely
different kind of thing from the not-scheduled, run-by-hand research
material (`recompute_*.py`, `analysis.ipynb`) that stayed behind in
`adhoc_quotas_analysis/` — see that directory's own `AGENTS.md` for the
actual investigation, findings, and gotchas (kept as its own file rather
than merged into this one, the same way `codex-patch/`'s own conventions
live in this file rather than README.md).

The coupling between `src/quota_polling/`/`adhoc_quotas_analysis/` and
`src/statusline/`/`providers/` is file-based, not a `source`/import — see
README.md's "Architecture" section for exactly which scripts read/write
`data/claude-quota-history.jsonl` and `data/codex-quota-history.jsonl`
(split from a single combined `data/quota-log.jsonl` on 2026-08-31 — see
`adhoc_quotas_analysis/AGENTS.md`'s "Naming history"). One thing worth
stating plainly here since it's easy to get backwards:
`src/statusline/push-claude-quota.sh` is the *primary* Claude
quota path now (free, rides existing traffic, never rate-limited);
`src/statusline/refresh-claude-quota.sh` +
`src/quota_polling/poll_claude.py` are a *fallback* for the one gap the push
path can't cover — a session that hasn't sent its first message yet, or a
machine-wide idle stretch with no statusline rendering anywhere at all.

`providers/claude-statusline-command.sh` touches `state/heartbeat/claude`
on every render specifically so `src/quota_polling/poll_claude.py` can tell a statusline
is live and poll faster (see `adhoc_quotas_analysis/AGENTS.md`'s "Architecture" section) —
this is the one piece of the old cross-repo coupling that's still real,
just intra-repo now instead of cross-repo.

## Tests

`bash tests/run.sh` before committing a change to `src/statusline/`, `providers/`,
`src/quota_polling/`, `adhoc_quotas_analysis/`, `install.sh`, `uninstall.sh`, or
`codex-patch/install-codex-statusline-patch.sh`.
See `tests/README.md` for what the suite covers and what it deliberately
doesn't (the real Codex `git clone` + `cargo build` path; live
Anthropic/Keychain calls — the Keychain read lives entirely in
`src/quota_polling/poll_claude.py`). It's hermetic — temp git repos, a temp `$HOME`, a
fixture quota log, `AGENT_STATUSLINE_SKIP_LAUNCHD=1` to keep `install.sh`'s
LaunchAgent step off the real `gui/$(id -u)` launchd domain — never touches
this machine's real `~/.claude`, `~/.codex`, or account state.
