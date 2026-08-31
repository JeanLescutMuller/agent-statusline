# agent-statusline

Shared Claude Code / Codex status line: thin provider adapters around the same
shell cache/format library and lazy caches. Claude keeps its three-line
layout. Codex displays those same three lines as a one-line carousel,
advancing every four seconds. Also tracks both agents' quota percentages
over time (`adhoc_quotas_analysis/`, folded in from the former `agent-quota-tracker` repo -
see "Quota tracking" below), since the statusline's own quota display and
the underlying research turned out to share the same account data.

Personal, user-space tool - safe to run on any machine you don't own (no
root/sudo assumed anywhere, aside from Codex's own install).

## Usage

```bash
bash install.sh
```

Idempotent: safe to re-run any time. It deploys the shared library and
provider adapters, migrates in-place from a legacy
`~/opt/bootstrap-home/statusline` runtime and (once) from a standalone
`agent-quota-tracker` install, deploys the quota pollers and their
LaunchAgent, and - only if `codex` is on `PATH` - builds/deploys the
status-line-command patch and wires `~/.codex/config.toml`. Requires
`python3` on `PATH`.

## Architecture

Three independent mandates share this repo:

- **Statusline architecture** — `lib/` + `providers/`, deployed by `install.sh`
  and invoked on every render by Claude Code / Codex. This is the runtime
  path: shared cache, formatting, and per-provider adapters.
- **Quota tracking** — `adhoc_quotas_analysis/`, folded in from the former
  `agent-quota-tracker` repo (full git history preserved under this prefix).
  A LaunchAgent-scheduled poller plus a free push from every Claude render,
  both writing to one shared log; separately, notebook-driven research into
  what the quota percentages actually mean. See "Quota tracking" below.
- **Codex patch** — `codex-patch/`, invoked once by `install.sh` (only when
  `codex` is on `PATH`) to give Codex's TUI a `status_line_command` extension
  point it doesn't ship with on the pinned version. Build-time only; nothing
  in it runs on a render.

The diagram below is the **runtime view only** — what actually runs when a
session renders its statusline, and what the quota LaunchAgent does on its
own schedule. `install.sh`/`utils.sh` (deploy-time) and `codex-patch/`
(build-time, one-off, never invoked on a render) are covered in their own
sections instead of diagrammed here.

```mermaid
%%{init: {"flowchart": {"curve": "linear"}}}%%
flowchart TB
    claudeS(["Claude Code sessions (N)"])
    codexS(["Codex TUI sessions (N)"])

    provclaude["providers/claude-statusline-command.sh
    one process per render, same script for every session"]
    provcodex["providers/codex-statusline-command.sh
    one process per render (~4s), same script for every session"]

    sharedlib[["lib/statusline-cache.sh
    lib/statusline-format.sh"]]

    subgraph state["~/opt/agent-statusline/state/ — shared cache files"]
        direction LR
        hbC[("heartbeat/claude")]
        hbX[("heartbeat/codex")]
        ccC[("quota/claude
        60s fallback cache")]
        ccX[("quota/codex
        60s cache")]
        ccOther[("system/metrics, git/&lt;cwd&gt;/*, static/*
        shared by both providers")]
    end

    pushscript["lib/statusline-push-claude-quota.sh
    runs when stdin has rate_limits, no network call"]
    refreshscript["lib/statusline-refresh-claude-quota.sh
    fallback: no rate_limits yet this session"]

    claudelog[("data/claude-quota-history.jsonl
    2 sources: claude / claude_statusline")]
    codexlog[("data/codex-quota-history.jsonl
    1 source: codex")]

    subgraph pollers["Scheduled — LaunchAgent, every 60s"]
        direction TB
        pollall["poll_all.py"]
        pollclaude["poll_claude.py"]
        pollcodex["poll_codex.py"]
    end

    anthropicusage["Anthropic
    GET /api/oauth/usage"]
    codexrpc["codex app-server
    JSON-RPC"]
    notebook["adhoc_quotas_analysis/analysis.ipynb
    research, run by hand"]

    claudeS -->|renders| provclaude
    codexS -->|"status_line_command"| provcodex

    provclaude --> sharedlib
    provcodex --> sharedlib
    sharedlib --> ccOther

    provclaude -->|touches every render| hbC
    provcodex -->|touches every render| hbX

    provclaude -->|"rate_limits on stdin"| pushscript
    pushscript -->|appends| claudelog
    provclaude -.->|"no rate_limits yet"| refreshscript
    refreshscript -.->|reads latest claude row| claudelog
    provclaude -.->|read/write| ccC

    provcodex -->|writes payload snapshot| ccX

    pollall --> pollclaude
    pollall --> pollcodex
    pollclaude -.->|checks freshness| hbC
    pollclaude -->|"~60s watched, ~5min idle"| anthropicusage
    pollclaude -->|appends| claudelog
    pollcodex -.->|checks freshness| hbX
    pollcodex -->|"~60s watched, ~5min idle"| codexrpc
    pollcodex -->|appends| codexlog

    claudelog --> notebook
    codexlog --> notebook
```

Two independent write paths feed `claude-quota-history.jsonl`, disambiguated
by `source`: the free per-render push (`claude_statusline`, rides existing
traffic) and the fixed-cadence poll (`claude`, this account's only caller of
that endpoint). `codex-quota-history.jsonl` has a single writer,
`poll_codex.py` — Codex has no equivalent free per-render push (see "Quota
tracking" below for why). The coupling between the render path and the poll
path is entirely file-based — a heartbeat file and a per-provider log —
never a direct script call in either direction; see "Quota tracking" below
for why each writer exists.

## Runtime layout

Deploys shared code and state under `~/opt/agent-statusline/`:

    ~/opt/agent-statusline/
    ├── lib/
    │   ├── statusline-cache.sh           shared lazy-cache primitives (stale-while-revalidate, locking)
    │   ├── statusline-format.sh          shared ANSI styling and segment formatting
    │   ├── statusline-push-claude-quota.sh     pushes live rate_limits to the claude quota log
    │   ├── statusline-refresh-claude-quota.sh  fallback: reads the claude quota log
    │   ├── statusline-refresh-git-local.sh     branch/untracked/unstaged/staged/conflicts
    │   ├── statusline-refresh-git-remote.sh    ahead/behind
    │   └── statusline-refresh-metrics.sh       used/total/percent memory
    ├── adhoc_quotas_analysis/            deployed poll_claude.py, poll_codex.py, poll_all.py, recompute_*.py
    ├── data/
    │   ├── claude-quota-history.jsonl    Claude poll + push quota log (see "Quota tracking")
    │   ├── codex-quota-history.jsonl     Codex poll quota log (see "Quota tracking")
    │   ├── token-events.jsonl            recomputed Claude token-usage detail (not scheduled, run by hand)
    │   └── codex-token-events.jsonl      recomputed Codex token-usage detail (not scheduled, run by hand)
    ├── state/
    │   ├── static/
    │   │   ├── hostname                  immutable short hostname
    │   │   └── host-color                terminal color the hostname is printed in
    │   ├── system/
    │   │   └── metrics                   used GiB, total GiB, percent
    │   ├── heartbeat/
    │   │   ├── claude                    epoch of the last Claude render (see below)
    │   │   └── codex                     epoch of the last Codex render (see below)
    │   ├── quota/
    │   │   ├── claude                    5h percent/reset, 7d percent/reset
    │   │   └── codex                     5h percent/reset, 7d percent/reset
    │   └── git/cwd/.../
    │       ├── local                     local Git snapshot for that cwd
    │       └── remote                    remote Git snapshot for that cwd
    ├── locks/                            atomic refresh locks
    ├── logs/
    │   ├── statusline.log                bounded shared refresh/write event log
    │   ├── statusline.log.1              previous log after 1 MiB rotation
    │   ├── quota-poll.log                quota LaunchAgent stdout
    │   └── quota-poll.err                quota LaunchAgent stderr
    └── com.jeanlescut.agent-statusline.plist   quota LaunchAgent (symlinked from ~/Library/LaunchAgents/)

Dynamic value files use ASCII file-separator delimiters and have a sibling
`.timestamp` containing their refresh epoch. Renderers read both with Bash
built-ins. Only the provider JSON payload requires `jq`.

## Lazy stale-while-revalidate flow

1. Read the existing value and timestamp.
2. If fresh, render it without starting a refresher.
3. If stale, try an atomic mkdir lock.
4. If another session owns the lock, immediately render the stale value.
5. The lock winner runs the relevant refresher synchronously with a hard timeout.
6. Success atomically replaces value and timestamp; failure keeps stale data.
7. A stale lock is atomically renamed to quarantine before removal.

There is no polling daemon or scheduler. Work happens only for data currently
being displayed, and sessions share machine-, provider-, and cwd-scoped
results.

The shared log records cache refresh/write events for both providers, including
failure exit codes, safe stderr, and stale-cache age. It deliberately does not
log every render: at 30 sessions and a four-second interval that would create
roughly 650,000 lines per day and add avoidable I/O. Epoch timestamps keep the
hot-path logger independent of another `date` subprocess.

| Cache | Scope | TTL | Refresh timeout |
|---|---|---:|---:|
| Hostname/color | machine | static | none |
| Memory | machine | 30s | 1s |
| Claude quotas | Claude account | 60s | 2s |
| Codex quotas | Codex account | 60s | payload update |
| Local Git | exact cwd | 8s | 1s |
| Remote Git | exact cwd | 30s | 1s |

Claude quotas mostly skip this cache entirely: `providers/claude-statusline-command.sh`
prefers the live `rate_limits` values already present on every render's stdin
payload — no cache, no staleness, since it's exactly as fresh as Claude
Code's own in-memory quota state. The 60s-TTL cache above is a fallback for
the one case stdin can't cover (a session that hasn't sent its first message
yet), reading the latest reading from the Claude quota log
(`~/opt/agent-statusline/data/claude-quota-history.jsonl`) instead of fetching
Anthropic's OAuth usage endpoint directly — see "Quota tracking" below for
why. Soft-fails closed if that log doesn't exist yet, same as any other
failed refresh.

Codex contributes its latest payload snapshot to the shared provider cache
because no separate stable local quota endpoint has been established -
`providers/codex-statusline-command.sh` makes no network call of its own.

## Quota tracking

`adhoc_quotas_analysis/` (folded in from the former `agent-quota-tracker` repo, full git
history preserved) empirically tracks both agents' quota percentages
over time in two append-only, per-provider logs:
`~/opt/agent-statusline/data/claude-quota-history.jsonl` and
`data/codex-quota-history.jsonl` (split from a single combined
`data/quota-log.jsonl` on 2026-08-31 - see `adhoc_quotas_analysis/AGENTS.md`'s
"Naming history"). Three independent writers across the two files,
disambiguated within `claude-quota-history.jsonl` by a `source` field,
because the underlying data has genuinely different persistence properties:

| File | `source` | Writer | Cadence | Why it exists |
|---|---|---|---|---|
| `claude-quota-history.jsonl` | `claude` | `adhoc_quotas_analysis/poll_claude.py` (LaunchAgent, `GET /api/oauth/usage`) | ~60s while a statusline is live, ~5min idle | That endpoint has no history - a missed reading is permanently lost. Unreliable (~21% 429 rate historically; can lock out for 3+ days - see `adhoc_quotas_analysis/AGENTS.md`). |
| `claude-quota-history.jsonl` | `claude_statusline` | `lib/statusline-push-claude-quota.sh` (every Claude render) | Bounded by real message pace, not render interval | Free: Claude Code already carries live `rate_limits` on every `/v1/messages` response, riding on the statusline's own stdin payload - no network call, and far more reliable than the poll endpoint. |
| `codex-quota-history.jsonl` | `codex` | `adhoc_quotas_analysis/poll_codex.py` (LaunchAgent, `codex app-server` JSON-RPC) | Skips while a Codex session is actively writing its own local snapshot; else ~60s while a Codex statusline is rendering (`heartbeat/codex`, same mechanism as Claude's), backing off to ~5min once nothing is open | Codex has no plain HTTP usage endpoint, and unlike Claude's rate_limits, its local session file already durably records this - so instead of a statusline push, it just needed the same "someone is watching" speedup Claude's poller has. |

Every `claude`/`codex` row also feeds `analysis.ipynb`'s research into what
these percentages actually mean (they track dollar-weighted API cost, not
raw token count - see `adhoc_quotas_analysis/AGENTS.md`'s "Findings" for the regression
behind that). `claude_statusline` rows carry a reduced shape - just the two
percentages, their resets, and `observed_at` (the transcript's own last
message timestamp, not append time) - since they're pushed far more often
than the poll rows and don't carry the full raw API response.

Concurrent writers append safely with no locking: every append is one
`write()` call under 4KB with the file opened `O_APPEND`, which POSIX
guarantees is atomic across processes. See `adhoc_quotas_analysis/AGENTS.md` for the full
investigation, findings, and gotchas - it's the single deepest document in
this repo and deliberately kept separate from this README.

## Codex status-line patch

Codex's TUI does not natively support a `status_line_command` the way this
project needs, on the supported pinned version. Everything for this lives in
`codex-patch/`, self-contained and separate from the statusline architecture
above. `install.sh` calls `codex-patch/install-codex-statusline-patch.sh`,
which:

- Clones `openai/codex` at the pinned commit for the installed Codex version
  (currently only 0.150.1 is supported; other versions are left unpatched).
- Applies `codex-patch/patches/codex-<version>-status-line-command.patch`.
- Builds a release binary with Cargo and deploys it as a
  `~/.codex/packages/standalone/releases/...` release, symlinked from
  `current`.
- Is idempotent: skips the clone/build entirely once the deployed binary's
  marker matches the pinned commit + patch hash.

Verbose clone/patch/compiler output is captured in
`~/opt/agent-statusline/codex-patch/build.log`, never streamed to the
terminal - only milestones and the final result print.

`install.sh` then owns just the `[tui]` status-line keys (`status_line`,
`status_line_use_colors`, `status_line_command`) in `~/.codex/config.toml`,
merging in `codex-patch/codex_tui.toml` via a `python3`/`tomllib` merge that
touches nothing else in that file.

## Source files

Statusline architecture (runs on every render):

- `lib/statusline-cache.sh`: paths, freshness, locking, timeouts, and atomic writes.
- `lib/statusline-format.sh`: shared colors, bars, limits, and Git formatting.
- `lib/statusline-refresh-*.sh`: one bounded refresh attempt, without cache policy.
- `lib/statusline-refresh-claude-quota.sh`: reads the latest `claude` poll reading from the Claude quota log - fallback path only, see "Quota tracking".
- `lib/statusline-push-claude-quota.sh`: appends a `claude_statusline` row to the Claude quota log from live stdin `rate_limits` - the primary path.
- `providers/claude-statusline-command.sh`: Claude adapter and multiline layout.
- `providers/codex-statusline-command.sh`: Codex adapter and one-line layout.
- `install.sh` + `utils.sh`: deployment, legacy-runtime migration, quota-poller/LaunchAgent deployment, and Codex config wiring.

Quota tracking (see "Quota tracking" above; own deep-dive docs in `adhoc_quotas_analysis/AGENTS.md`):

- `adhoc_quotas_analysis/poll_claude.py` / `adhoc_quotas_analysis/poll_codex.py` / `adhoc_quotas_analysis/poll_all.py`: the LaunchAgent-scheduled pollers.
- `adhoc_quotas_analysis/split_quota_log.py`: one-time, idempotent migration from the old combined `data/quota-log.jsonl` to the two per-provider files - run automatically by `install.sh`.
- `adhoc_quotas_analysis/recompute_token_events.py` / `adhoc_quotas_analysis/recompute_codex_events.py`: not scheduled, run by hand to rebuild per-event token-usage detail from local transcripts.
- `adhoc_quotas_analysis/analysis.ipynb`: the research notebook - what the quota percentages actually track.

Codex patch (build-time, one-off; see "Codex status-line patch" above):

- `codex-patch/install-codex-statusline-patch.sh`: clone/patch/build/deploy the binary.
- `codex-patch/patches/`: one `.patch` per supported Codex version.
- `codex-patch/codex_tui.toml`: template merged into `~/.codex/config.toml`'s `[tui]` table.

## Tests

```bash
bash tests/run.sh
```

A hermetic bash test suite covering every file above - see `tests/README.md`
for what's covered and, deliberately, what isn't (the real Codex `git clone`
+ `cargo build` path, and live Anthropic/Keychain calls).

## Offline testing

Set `STATUSLINE_RUNTIME_DIR` to a temporary directory and `STATUSLINE_LIB_DIR`
to this repository's `lib/` directory, then pipe a captured provider payload
into the corresponding renderer. The first render may refresh stale data;
subsequent Codex renders should start only Bash and one payload `jq`. That
`jq` also supplies the refresh epoch used for cache freshness and carousel
selection. `tests/run.sh` automates exactly this pattern.
