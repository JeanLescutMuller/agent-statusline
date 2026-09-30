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
├── USAGE_DATA_SOURCES.md         # CANONICAL: what usage data exists upstream, in which unit, at which granularity, for both agents.
├── USAGE_DATA_REFERENCE.md       # CANONICAL: what this repo captures, how, when, and where it lands.
│                                 # Other projects link to these rather than restating them. Keep them tested and dated.
├── providers/                    # statusline architecture: Claude/Codex payload adapters, call into src/statusline/
├── src/
│   ├── statusline/                # statusline architecture: shared cache/format lib + refresh scripts
│   │   └── push-claude-quota.sh      # appends to the claude quota log, and writes state/quota/claude directly (tag X)
│   ├── telemetry/                # local OTLP receiver for Claude Code's usage events + its KeepAlive LaunchAgent;
│   │                             # install.sh owns the telemetry keys in ~/.claude/settings.json's `env`
│   └── quota_polling/            # quota polling: LaunchAgent-scheduled, deployed, unattended production code
│       ├── poll_claude.py / poll_codex.py       # per-provider pollers
│       ├── poll_codex_plan_history.py           # daily Codex plan_limit_history fetch (fractional per-window history)
│       ├── poll_all.py                          # the actual LaunchAgent entry point, runs both as subprocesses
│       └── com.jeanlescut.agent-statusline.plist.template  # __PYTHON3__/__RUNTIME__ placeholders, filled by install.sh
├── adhoc_quotas_analysis/        # quota research: folded in from the former agent-quota-tracker repo,
│                                 # full git history preserved under this prefix (see its own AGENTS.md)
│   ├── split_quota_log.py        # one-time, idempotent log-split migration, run by hand only if you still have an old combined data/quota-log.jsonl
│   ├── recompute_codex_events.py # not scheduled, run by hand (Claude side is now inline in analysis.ipynb's own cells)
│   ├── window_gaps.py            # read-only, run by hand: 5h/7d window gap analysis behind CONCLUSIONS.md
│   ├── quota_model.py            # read-only, run by hand: %/token/USD conversions + Codex window timing behind CONCLUSIONS.md
│   ├── CONCLUSIONS.md            # established findings with evidence and caveats (dated entries)
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
`src/statusline/`/`providers/` is file-based, not a `source`/import, and
runs through **two different kinds of file** that are easy to conflate:

- `data/claude-quota-history.jsonl` / `data/codex-quota-history.jsonl` — one
  file **per provider** (split from a single combined `data/quota-log.jsonl`
  on 2026-08-31 — see `adhoc_quotas_analysis/AGENTS.md`'s "Naming history"),
  *not* one file per writer. Within `claude-quota-history.jsonl` specifically,
  two independent writers both append, disambiguated by a `source` field:
  `src/quota_polling/poll_claude.py` (`source: "claude"`) and
  `src/statusline/push-claude-quota.sh` (`source: "claude_statusline"`).
  Append-only, unconditional, no dedup, no ordering guarantee across the two
  writers — nothing reads this live any more (see below), it exists purely
  as raw material for `adhoc_quotas_analysis/analysis.ipynb`'s research.
- `state/quota/claude` / `state/quota/codex` — a single small file per
  provider holding only the *latest known reading*. The Claude file has six
  FS-delimited fields (`five_pct/five_reset/week_pct/week_reset/source/observed_at`,
  see `src/statusline/cache.sh`'s `statusline_write_quota_if_newer` and its
  Python mirror `src/quota_polling/_quota_common.py`'s
  `write_state_if_newer`). The Codex file has only four
  (`five_pct/five_reset/week_pct/week_reset`, resets as the TUI's display
  strings, not epochs), written solely by `providers/codex-statusline-command.sh`
  through `statusline_write_values_if_stale` with a 60s TTL tracked in a
  `state/quota/codex.timestamp` sidecar - no `source`, no `observed_at`, no
  freshness comparison. `providers/claude-statusline-command.sh` always
  displays whatever's in this file - not a fallback for the one case stdin
  can't cover, the *only* display path, live rate_limits on stdin or not
  (see that file's own comment for why: rate_limits on stdin is only
  that session's own last-known reading, and used to make every open
  session show its own possibly-different, possibly-stale number instead of
  the account's actual current usage). Both Claude writers -
  `push-claude-quota.sh` (tag `X`) and `poll_claude.py` (tag `P`) - write to
  it **directly**, each comparing its own reading's `observed_at` (when the
  reading was actually true, never write/render time - see
  `push-claude-quota.sh`'s own header comment for why that distinction
  matters) against whatever's already there and only overwriting if newer.
  Whichever producer has the genuinely freshest reading wins regardless of
  write order, so every open session converges on the same number within
  about one render cycle - no rescan of the historical log involved (that
  rescan - `refresh-claude-quota.sh` - and a since-removed third `S` "seed"
  tag were both cut in this redesign; see git history if you need the old
  shape).

One thing worth stating plainly since it's easy to get backwards:
`src/statusline/push-claude-quota.sh` is the *primary* Claude quota path now
(free, rides existing traffic, never rate-limited); `poll_claude.py` is a
*fallback* for the one gap the push path can't cover — a session that
hasn't sent its first message yet, or a machine-wide idle stretch with no
statusline rendering anywhere at all.

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
