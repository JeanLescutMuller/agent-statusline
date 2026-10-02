# agent-statusline

Shared Claude Code / Codex status line: thin provider adapters around the same shell cache/format library and lazy caches. Claude keeps its three-line layout. Codex displays those same three lines as a one-line carousel, advancing every four seconds.

Personal, user-space tool - safe to run on any machine you don't own (no root/sudo assumed anywhere, aside from Codex's own install).

Usage tracking (quota percent, tokens and spend over time, pollers, telemetry, research) is a separate project, [`agent-usage-tracker`](https://github.com/JeanLescutMuller/agent-usage-tracker), split out of this repo on 2026-09-30. The statusline is complete without it; with it, the Claude line also gets the tracker's poller readings. See "agent-usage-tracker" below for the whole contract.

## Usage

```bash
bash install.sh
```

Idempotent: safe to re-run any time against a machine that already has agent-statusline installed. It deploys the shared library and provider adapters (symlinked from `~/.claude/statusline-command.sh` and `~/.codex/statusline-command.sh`), and - only if `codex` is on `PATH` - builds/deploys the status-line-command patch and wires `~/.codex/config.toml`. Requires `python3` and `jq` on `PATH`.

`install.sh` assumes a bare machine and carries no legacy-layout migration logic. To move to an incompatible on-disk layout (or just start clean), run:

```bash
bash uninstall.sh   # removes what install.sh deploys; preserves codex-patch/; flags anything else left over
bash install.sh     # fresh install
```

## Architecture

Two independent mandates share this repo:

- **Statusline architecture** — `src/statusline/` + `providers/`, deployed by `install.sh` and invoked on every render by Claude Code / Codex. This is the runtime path: shared cache, formatting, and per-provider adapters.
- **Codex patch** — `codex-patch/`, invoked once by `install.sh` (only when `codex` is on `PATH`) to give Codex's TUI a `status_line_command` extension point it doesn't ship with on the pinned version. Build-time only; nothing in it runs on a render.

The diagram below is the **runtime view only** — what runs when a session renders its statusline. Dashed boxes belong to agent-usage-tracker and are optional.

```mermaid
%%{init: {"flowchart": {"curve": "linear"}}}%%
flowchart TB
    claudeS(["Claude Code sessions (N)"])
    codexS(["Codex TUI sessions (N)"])

    provclaude["providers/claude-statusline-command.sh
    one process per render, same script for every session"]
    provcodex["providers/codex-statusline-command.sh
    one process per render (~4s), same script for every session"]

    sharedlib[["src/statusline/cache.sh
    src/statusline/format.sh"]]

    subgraph state["~/opt/agent-statusline/state/ — shared cache files"]
        direction LR
        hbC[("heartbeat/claude")]
        hbX[("heartbeat/codex")]
        ccC0[("quota/claude
        freshest stdin reading, tag X")]
        ccX[("quota/codex
        60s cache")]
        ccOther[("system/metrics, git/&lt;cwd&gt;/*, static/*
        shared by both providers")]
    end

    subgraph tracker["~/opt/agent-usage-tracker/ — optional, separate project"]
        direction LR
        ingest["bin/ingest-claude-statusline.sh"]
        ccC[("state/quota/claude
        freshest reading incl. polls, tag P/X")]
        pollers["pollers (LaunchAgent)"]
    end

    claudeS -->|renders| provclaude
    codexS -->|"status_line_command"| provcodex

    provclaude --> sharedlib
    provcodex --> sharedlib
    sharedlib --> ccOther

    provclaude -->|touches every render| hbC
    provcodex -->|touches every render| hbX
    provcodex -->|writes payload snapshot| ccX

    provclaude -->|"writes if newer, tag X"| ccC0
    provclaude -->|"reads back"| ccC0
    provclaude -->|"pipes its raw stdin payload"| ingest
    ingest -->|"writes if newer, tag X"| ccC
    provclaude -->|"reads back; the fresher of the two is shown"| ccC
    pollers -.->|"reads mtime"| hbC
    pollers -.->|"reads mtime"| hbX
    pollers -->|"writes if newer, tag P"| ccC

    style tracker stroke-dasharray: 5 5
```

## agent-usage-tracker

The whole contract between the two projects is three files, each written by exactly one side. Only `providers/claude-statusline-command.sh` touches the tracker, and neither project ever writes into the other's tree.

| Interface | Written by | Read by | What |
|---|---|---|---|
| `~/opt/agent-usage-tracker/bin/ingest-claude-statusline.sh` | tracker (deployed) | Claude provider runs it | Every Claude render pipes its raw stdin payload into it, unchanged, before display. The statusline knows nothing about which fields the tracker keeps or where. Output and failures are ignored; skipped if the script isn't executable. |
| `~/opt/agent-usage-tracker/state/quota/claude` | tracker (ingest `X`, poller `P`) | Claude provider | The tracker's freshest known 5h/7d reading, in the same six-field format as this repo's own `state/quota/claude` (below). Displayed only when its `observed_at` is newer than the own cache's. |
| `~/opt/agent-statusline/state/heartbeat/{claude,codex}` | statusline, every render | tracker's pollers | Only the mtime matters: "a statusline is on screen right now", so the pollers poll faster. |

`AGENT_USAGE_TRACKER_DIR` overrides the tracker's location (the tests point it at a stub).

**Why the Claude line doesn't just show its own stdin.** `rate_limits` on stdin is only *that session's* last-known reading, updated solely when that session gets a fresh API response, while the 5h/7d quota is account-wide. Three sessions that last talked to the API at three different moments would each show their own frozen snapshot, disagreeing with each other and with the true current usage. So every render writes its stdin reading into this repo's own `state/quota/claude`, stamped with `observed_at` (when the reading became true: the transcript's last timestamp, or now if there is none), only if it beats what is there; every open session then displays the freshest reading within about one render cycle. Freshness is per window: Claude sometimes sends a reading with only `seven_day`, and that never erases a known 5-hour value. The origin tag is displayed next to the percentage (`65% (X)`).

**What the tracker adds** is its poller's readings (tag `P`), which matter while no session has sent a message. At display time the provider compares the own cache with the tracker's file on `observed_at` and shows the fresher one, so the tracker can only ever make the display fresher: a stale or broken tracker loses the comparison, and a missing one is simply skipped. With no reading anywhere (a fresh session, nothing cached), the 5h/7d segments show `–`, never a made-up `0%`.

| Installed | Claude quota display |
|---|---|
| Both | Freshest of every session's stdin and the tracker's polls |
| Statusline only | Freshest of every session's stdin; `–` until any session has a reading |
| Tracker only | No statusline at all, so the tracker gets no payloads and records no push rows |

Codex never depends on the tracker: its provider caches its own payload's rate limits in `state/quota/codex` (below).

## Runtime layout

Deploys shared code and state under `~/opt/agent-statusline/`:

    ~/opt/agent-statusline/
    ├── src/statusline/
    │   ├── cache.sh                      shared lazy-cache primitives (stale-while-revalidate, locking)
    │   ├── format.sh                     shared ANSI styling and segment formatting
    │   ├── refresh-git-local.sh          branch/untracked/unstaged/staged/conflicts
    │   ├── refresh-git-remote.sh         ahead/behind
    │   └── refresh-metrics.sh            used/total/percent memory
    ├── providers/                        deployed adapters; ~/.claude and ~/.codex hold symlinks to these
    ├── state/
    │   ├── static/
    │   │   ├── hostname                  immutable short hostname
    │   │   └── host-color                terminal color the hostname is printed in
    │   ├── system/metrics                used GiB, total GiB, percent
    │   ├── heartbeat/
    │   │   ├── claude                    epoch of the last Claude render (read by agent-usage-tracker)
    │   │   └── codex                     epoch of the last Codex render (read by agent-usage-tracker)
    │   ├── quota/
    │   │   ├── claude                    freshest stdin reading of any session: 5h/7d percent+reset, tag X, observed_at
    │   │   └── codex                     5h percent/reset, 7d percent/reset, from the Codex payload
    │   ├── spin/                         per-provider spinner counters
    │   └── git/cwd/.../
    │       ├── local                     local Git snapshot for that cwd
    │       └── remote                    remote Git snapshot for that cwd
    ├── locks/                            atomic refresh locks
    ├── logs/
    │   ├── statusline.log                bounded shared refresh/write event log
    │   └── statusline.log.1              previous log after 1 MiB rotation
    └── codex-patch/                      Codex clone + build.log (kept by uninstall.sh)

Dynamic value files use ASCII file-separator delimiters and have a sibling `.timestamp` containing their refresh epoch. Renderers read both with Bash built-ins. Only the provider JSON payload requires `jq`.

## Lazy stale-while-revalidate flow

1. Read the existing value and timestamp.
2. If fresh, render it without starting a refresher.
3. If stale, try an atomic mkdir lock.
4. If another session owns the lock, immediately render the stale value.
5. The lock winner runs the relevant refresher synchronously with a hard timeout.
6. Success atomically replaces value and timestamp; failure keeps stale data.
7. A stale lock is atomically renamed to quarantine before removal.

There is no polling daemon or scheduler. Work happens only for data currently being displayed, and sessions share machine-, provider-, and cwd-scoped results.

The shared log records cache refresh/write events for both providers, including failure exit codes, safe stderr, and stale-cache age. It deliberately does not log every render: at 30 sessions and a four-second interval that would create roughly 650,000 lines per day and add avoidable I/O. Epoch timestamps keep the hot-path logger independent of another `date` subprocess.

| Cache | Scope | TTL | Refresh timeout |
|---|---|---:|---:|
| Hostname/color | machine | static | none |
| Memory | machine | 30s | 1s |
| Codex quotas | Codex account | 60s | payload update |
| Local Git | exact cwd | 8s | 1s |
| Remote Git | exact cwd | 30s | 1s |

Claude quotas aren't in this table: they are written on every render whose stdin has a newer reading than the cache, and compared with agent-usage-tracker's state file at display time (see "agent-usage-tracker" above). Codex contributes its latest payload snapshot to the shared provider cache because no separate stable local quota endpoint has been established - `providers/codex-statusline-command.sh` makes no network call of its own.

## Codex status-line patch

Codex's TUI does not natively support a `status_line_command` the way this project needs, on the supported pinned version. Everything for this lives in `codex-patch/`, self-contained and separate from the statusline architecture above. `install.sh` calls `codex-patch/install-codex-statusline-patch.sh`, which:

- Clones `openai/codex` at the exact release commit allowlisted in `codex-patch/supported-versions.tsv` (currently 0.150.1 through 0.154.0; unknown versions are left unpatched).
- Checks and applies the shared `codex-patch/patches/codex-status-line-command.patch`; almost all custom Rust lives in one isolated module to keep upstream integration points small.
- Builds a release binary with Cargo, pairs it with the matching official `codex-code-mode-host`, and deploys both as a `~/.codex/packages/standalone/releases/...` release, symlinked from `current`.
- Is idempotent: skips the clone/build entirely once the deployed binary's marker matches the pinned commit + patch hash.

Verbose clone/patch/compiler output is captured in `~/opt/agent-statusline/codex-patch/build.log`, never streamed to the terminal - only milestones and the final result print.

`install.sh` then runs `codex-patch/merge_codex_config.py`, which owns just the `[tui]` keys `status_line` and `status_line_use_colors` in `~/.codex/config.toml`, merging in `codex-patch/codex_tui.toml` via `tomllib` and touching nothing else in that file. It also removes the obsolete `[tui.status_line_command]` table written by older installers; the patched binary reads `CODEX_STATUS_LINE_COMMAND` or falls back to `~/.codex/statusline-command.sh`.

## Source files

Statusline architecture (runs on every render):

- `src/statusline/cache.sh`: paths, freshness, locking, timeouts, atomic writes, the heartbeat, and the quota state files (write-if-newer, freshest-of overlay, transcript `observed_at`).
- `src/statusline/format.sh`: shared colors, bars, limits, and Git formatting.
- `src/statusline/refresh-*.sh`: one bounded refresh attempt, without cache policy.
- `providers/claude-statusline-command.sh`: Claude adapter and multiline layout; the only file that touches agent-usage-tracker.
- `providers/codex-statusline-command.sh`: Codex adapter and one-line layout.
- `install.sh` + `utils.sh`: deployment and Codex config wiring - assumes a bare machine, no migration logic.
- `uninstall.sh`: removes everything `install.sh` deploys; preserves `codex-patch/` (and a pre-split `data/`, if one is left); flags anything else left over as an orphan.

Codex patch (build-time, one-off; see "Codex status-line patch" above):

- `codex-patch/install-codex-statusline-patch.sh`: clone/patch/build/deploy the binary.
- `codex-patch/supported-versions.tsv`: exact supported version/commit pairs.
- `codex-patch/patches/`: the shared cross-version patch.
- `codex-patch/codex_tui.toml`: template merged into `~/.codex/config.toml`'s `[tui]` table.
- `codex-patch/merge_codex_config.py`: the merge logic, run by `install.sh`'s "codex config" step.

## Tests

```bash
bash tests/run.sh
```

A hermetic bash test suite covering every file above - see `tests/README.md` for what's covered and, deliberately, what isn't (the real Codex `git clone` + `cargo build` path, and agent-usage-tracker itself, which is replaced by a stub).

## Offline testing

Set `STATUSLINE_RUNTIME_DIR` to a temporary directory, `STATUSLINE_LIB_DIR` to this repository's `src/statusline/` directory, and `AGENT_USAGE_TRACKER_DIR` to an empty directory, then pipe a captured provider payload into the corresponding renderer. The first render may refresh stale data; subsequent Codex renders should start only Bash and one payload `jq`. That `jq` also supplies the refresh epoch used for cache freshness and carousel selection. `tests/run.sh` automates exactly this pattern.
