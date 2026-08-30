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
`~/opt/agent-quota-tracker`. `test_provider_codex.sh` is the slow one: the
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
- Live Anthropic API calls or the real macOS Keychain - neither is reachable
  from this repo any more. Claude quota now comes from a fixture
  agent-quota-tracker log (`test_refresh_claude_quota.sh`); the real Keychain
  read lives in agent-quota-tracker's own `poll_claude.py`, a separate
  project with its own test story.

## Files

| File | Covers |
|---|---|
| `harness.sh` | The assert helpers + fixture/isolation utilities every test file sources |
| `test_format.sh` | `lib/statusline-format.sh` - pure functions |
| `test_cache.sh` | `lib/statusline-cache.sh` - freshness, locking, refresh/write, static read, log rotation |
| `test_refresh_git_local.sh` | `lib/statusline-refresh-git-local.sh` against real temp repos |
| `test_refresh_git_remote.sh` | `lib/statusline-refresh-git-remote.sh` against a real local bare remote |
| `test_refresh_metrics.sh` | `lib/statusline-refresh-metrics.sh` on the real host |
| `test_refresh_claude_quota.sh` | `lib/statusline-refresh-claude-quota.sh` - reading a fixture agent-quota-tracker log, including the epoch-parsing filter's three timestamp formats |
| `test_provider_claude.sh` | `providers/claude-statusline-command.sh` end to end |
| `test_provider_codex.sh` | `providers/codex-statusline-command.sh` end to end, including the real carousel rotation |
| `test_install.sh` | `install.sh` - idempotency, legacy migration, Codex-absent skip, the real TOML-merge heredoc |
| `test_codex_patch_guards.sh` | `codex-patch/install-codex-statusline-patch.sh` guard clauses only |
| `test_utils.sh` | `utils.sh` |
| `test_repo_hygiene.sh` | `bash -n` on every script, shellcheck if installed, and the `codex-patch/` vs `lib/`+`providers/` architecture boundary from README.md |

## Fixtures

`fixtures/` holds captured-payload JSON for the provider tests. `__CWD__` is
a placeholder each test substitutes with a real temp directory before piping
the payload in.
