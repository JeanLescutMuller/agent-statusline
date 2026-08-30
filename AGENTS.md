# agent-statusline development instructions

These instructions govern development of this repository. User-facing usage,
runtime layout, and the cache design are documented in `README.md` — this
file only covers things relevant to *working on* the project.

## Instruction-file scope

`CLAUDE.md` at the repository root is a compatibility symlink to this file.

## Repo layout

Two independent mandates, kept in separate trees — see README.md's
"Architecture" section for the call-graph diagram.

```
agent-statusline/
├── install.sh              # deploy: shared lib, adapters; drives codex-patch/ conditionally
├── utils.sh                # shared echo/color helpers for install.sh and the patch script
├── lib/                    # statusline architecture: shared cache/format lib + refresh scripts
├── providers/               # statusline architecture: Claude/Codex payload adapters, call into lib/
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

## Tests

`bash tests/run.sh` before committing a change to `lib/`, `providers/`,
`install.sh`, or `codex-patch/install-codex-statusline-patch.sh`. See
`tests/README.md` for what the suite covers and what it deliberately doesn't
(the real Codex `git clone` + `cargo build` path; live Anthropic/Keychain
calls). It's hermetic — temp git repos, a temp `$HOME`, stubbed
Keychain/curl — never touches this machine's real `~/.claude`, `~/.codex`,
or account state.
