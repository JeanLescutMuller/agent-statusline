# Tests

Pure bash, no external test framework - `harness.sh` is a small assert-style
helper (`assert_eq`, `assert_contains`, `assert_file_exists`, ...) styled
after `utils.sh`'s own color/step conventions.

```bash
bash tests/run.sh          # everything, ~20-60s (see below)
bash tests/test_format.sh  # one file at a time; each is independently runnable
```

Every test is hermetic: real temp git repos, a real local bare "remote", and
a temp `$HOME` - nothing here touches your actual `~/.claude`, `~/.codex`, or
`~/opt/agent-statusline`. `test_provider_codex.sh` is the slow one: the
Codex adapter's carousel page is chosen from the real wall clock (not the
payload), so a few sections poll for real, bounded at 13s each, to observe
pages 1/2/3 as they come up.

## What's intentionally not covered

- The real `git clone` + `cargo build` path in
  `codex-patch/install-codex-statusline-patch.sh` - network- and
  minutes-of-compile-time-heavy, doesn't belong in a test suite. Its guard
  clauses (missing binary, unsupported version, missing patch file, and the
  important idempotent already-installed short-circuit) are covered in
  `test_codex_patch_guards.sh` without ever reaching that path.
- Live Anthropic API calls or the real macOS Keychain - `test_push_claude_quota.sh`
  and `test_quota_common.sh` cover the quota write paths against fixture
  transcripts/fixture state files instead; the real Keychain read and
  network poll live in `src/quota_polling/poll_claude.py`'s `fetch_token`/
  `fetch_usage`, untested here on purpose.

## Files

| File | Covers |
|---|---|
| `harness.sh` | The assert helpers + fixture/isolation utilities every test file sources |
| `test_format.sh` | `src/statusline/format.sh` - pure functions |
| `test_cache.sh` | `src/statusline/cache.sh` - freshness, locking, refresh/write, quota state-file writer/overlay, static read, log rotation |
| `test_split_by_scope.sh` | `adhoc_quotas_analysis/split_by_scope.py` on a fixture with every historical row shape: counts reconcile, untouched rows byte-identical, session fields moved, no percent in session files, idempotent re-run, sweep of a recreated old file, in-progress marker |
| `test_otlp_receiver.sh` | `src/telemetry/otlp_receiver.py` on a free local port: usage events kept and flattened, prompt/tool events dropped, protobuf / malformed / metrics requests answered without writing, localhost-only bind |
| `test_poll_codex_plan_history.sh` | `src/quota_polling/poll_codex_plan_history.py` - the raw row it logs, its 24h / 1h-retry cadence, error rows (HTTP, disconnect, missing auth), and that the bearer token never reaches the log; `urlopen` monkeypatched, fake `auth.json` |
| `test_poll_claude.sh` | `src/quota_polling/poll_claude.py`'s `fetch_usage` error handling - every transport failure (including `RemoteDisconnected`) becomes an error row instead of crashing the run; `urlopen` monkeypatched, no network |
| `test_quota_common.sh` | `src/quota_polling/_quota_common.py`'s `write_state_if_newer` - the Python-side mirror of `cache.sh`'s quota state-file writer, cross-checked for format agreement |
| `test_refresh_git_local.sh` | `src/statusline/refresh-git-local.sh` against real temp repos |
| `test_refresh_git_remote.sh` | `src/statusline/refresh-git-remote.sh` against a real local bare remote |
| `test_refresh_metrics.sh` | `src/statusline/refresh-metrics.sh` on the real host |
| `test_push_claude_quota.sh` | `src/statusline/push-claude-quota.sh` - history-log append (now unconditional, unrounded percents, session cost) and the `state/quota/claude` freshness-compared write (tag `X`) |
| `test_provider_claude.sh` | `providers/claude-statusline-command.sh` end to end, including the P/X source-tag overlay chain and cross-session convergence |
| `test_provider_codex.sh` | `providers/codex-statusline-command.sh` end to end, including the real carousel rotation |
| `test_install.sh` | `install.sh` - idempotency, Codex-absent skip, the real TOML-merge heredoc |
| `test_uninstall.sh` | `uninstall.sh` - full removal, `data/`/`codex-patch/` preserved, orphan reporting |
| `test_codex_patch_guards.sh` | `codex-patch/install-codex-statusline-patch.sh` guard clauses only |
| `test_utils.sh` | `utils.sh` |
| `test_repo_hygiene.sh` | `bash -n` on every script, shellcheck if installed, and the `codex-patch/` vs `src/statusline/`+`providers/` architecture boundary from README.md |

## Fixtures

`fixtures/` holds captured-payload JSON for the provider tests. `__CWD__` is
a placeholder each test substitutes with a real temp directory before piping
the payload in.
