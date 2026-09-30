# TODO

## Native shared statusline renderer

Decided against (2026-09-13): unlikely to be worth it. Shell implementation
stays. Revisit only if a concrete measurement shows the Bash/jq/date
per-render subprocess cost is material at the desired refresh frequency.

## 7d rendering bug in Codex

Sometimes saw:
```
7d [█████░░░]o69%
```
in the Codex statusline — stray "o" character, cause unconfirmed. Possibly
already resolved by unrelated fixes since this was filed (2026-09-01 session
added debug instrumentation in `logs/codex-carousel.log` but didn't pin down
a root cause). Not seen recently (as of 2026-09-13) — leave closed, reopen
and investigate with the debug log if it recurs.
