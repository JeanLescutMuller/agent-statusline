#!/bin/bash
# Unit tests for src/statusline/format.sh - pure functions, no filesystem or
# network, so these run fast and deterministic.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
source "$REPO_ROOT/src/statusline/format.sh"

strip_ansi() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

section "statusline_display_path"
statusline_display_path "$HOME" out; assert_eq "home dir collapses to ~" "~" "$out"
statusline_display_path "$HOME/proj/sub" out; assert_eq "home-prefixed path collapses" "~/proj/sub" "$out"
statusline_display_path "/etc/other" out; assert_eq "non-home path unchanged" "/etc/other" "$out"
statusline_display_path "${HOME}x/proj" out; assert_eq "home-lookalike prefix not collapsed" "${HOME}x/proj" "$out"

section "statusline_ordinal_suffix"
assert_eq "1 -> st" "st" "$(statusline_ordinal_suffix 1)"
assert_eq "2 -> nd" "nd" "$(statusline_ordinal_suffix 2)"
assert_eq "3 -> rd" "rd" "$(statusline_ordinal_suffix 3)"
assert_eq "4 -> th" "th" "$(statusline_ordinal_suffix 4)"
assert_eq "11 -> th" "th" "$(statusline_ordinal_suffix 11)"
assert_eq "12 -> th" "th" "$(statusline_ordinal_suffix 12)"
assert_eq "13 -> th" "th" "$(statusline_ordinal_suffix 13)"
assert_eq "21 -> st" "st" "$(statusline_ordinal_suffix 21)"
assert_eq "22 -> nd" "nd" "$(statusline_ordinal_suffix 22)"
assert_eq "23 -> rd" "rd" "$(statusline_ordinal_suffix 23)"
assert_eq "31 -> st" "st" "$(statusline_ordinal_suffix 31)"

section "statusline_severity_color (default 70% yellow threshold)"
statusline_severity_color 10 70 out; assert_eq "10% is green" "$STATUSLINE_GREEN" "$out"
statusline_severity_color 69 70 out; assert_eq "69% is still green" "$STATUSLINE_GREEN" "$out"
statusline_severity_color 70 70 out; assert_eq "70% crosses into yellow" "$STATUSLINE_YELLOW" "$out"
statusline_severity_color 89 70 out; assert_eq "89% is still yellow" "$STATUSLINE_YELLOW" "$out"
statusline_severity_color 90 70 out; assert_eq "90% crosses into red" "$STATUSLINE_RED" "$out"
statusline_severity_color 100 70 out; assert_eq "100% is red" "$STATUSLINE_RED" "$out"
statusline_severity_color 45 40 out; assert_eq "custom 40% threshold respected" "$STATUSLINE_YELLOW" "$out"

section "statusline_bar"
statusline_bar 0 8 "$STATUSLINE_GREEN" out
assert_eq "0% is fully empty" "░░░░░░░░" "$(strip_ansi "$out")"
statusline_bar 50 8 "$STATUSLINE_GREEN" out
assert_eq "50% fills half" "████░░░░" "$(strip_ansi "$out")"
statusline_bar 100 8 "$STATUSLINE_GREEN" out
assert_eq "100% fully fills" "████████" "$(strip_ansi "$out")"
statusline_bar 150 8 "$STATUSLINE_GREEN" out
assert_eq "over 100% clamps to full width, not overflow" "████████" "$(strip_ansi "$out")"

section "statusline_limit_segment"
statusline_limit_segment 5h "" "" 0 "" out
assert_contains "no reading: a dash" "$out" "–"
assert_not_contains "no reading: never a percent" "$out" "%"
statusline_limit_segment 5h 42 "" 0 "" out
assert_contains "under 100%: shows a bar and the percent" "$out" "42%"
assert_not_contains "under 100%: no Blocked text" "$out" "Blocked"
assert_not_contains "no source given: no (tag) suffix" "$out" "("
statusline_limit_segment 5h 42 "" 0 L out
assert_contains "source given: percent carries the (tag)" "$out" "42% (L)"
statusline_limit_segment 7d 100 1700000600 1700000000 "" out
assert_contains "at 100% with numeric reset: Blocked" "$out" "Blocked"
assert_contains "at 100% with numeric reset: shows remaining time" "$out" "resets in"
statusline_limit_segment 7d 100 1700000600 1700000000 P out
assert_contains "at 100%, source given: (tag) still appears" "$out" "resets in 0h 10m (P)"
statusline_limit_segment 7d 100 "tomorrow" 1700000000 "" out
assert_contains "at 100% with non-numeric reset: shown verbatim" "$out" "resets tomorrow"
statusline_limit_segment 7d 120 "" 0 "" out
assert_contains "over 100% with no reset info still renders a bar" "$out" "120%"

section "statusline_context_segment"
statusline_context_segment 10 out
assert_contains "under 40%: green" "$out" "$STATUSLINE_GREEN"
statusline_context_segment 50 out
assert_contains "over 40%: yellow kicks in" "$out" "$STATUSLINE_YELLOW"

section "statusline_git_segment"
statusline_git_segment "" 0 0 0 0 0 0 out
assert_eq "empty branch produces empty segment" "" "$out"

statusline_git_segment "main" 0 0 0 0 0 0 out
assert_contains "clean repo shows the branch" "$out" "main"
assert_not_contains "clean repo has no parenthetical" "$out" "("

statusline_git_segment "main" 2 0 0 0 0 0 out
assert_contains "untracked count shown" "$out" "?2"

statusline_git_segment "main" 0 3 0 0 0 0 out
assert_contains "unstaged count shown" "$out" "!3"

statusline_git_segment "main" 0 0 4 0 0 0 out
assert_contains "staged count shown" "$out" "✚4"

statusline_git_segment "main" 1 2 3 0 0 0 out
assert_contains "untracked+unstaged+staged combine in one parenthetical" "$out" "(${STATUSLINE_CYAN}?1${STATUSLINE_GRAY_3} !2 ${STATUSLINE_BLUE}✚3${STATUSLINE_GRAY_3})"

statusline_git_segment "main" 0 0 0 0 5 0 out
assert_contains "ahead count shown" "$out" "⇡5"

statusline_git_segment "main" 0 0 0 0 0 6 out
assert_contains "behind count shown" "$out" "⇣6"

statusline_git_segment "main" 0 0 0 2 0 0 out
assert_contains "conflict count shown" "$out" "✖2"

section "statusline_rotating_time"
statusline_rotating_time 0 "08/30 12:00:00" 1700000000 1600000000 out
assert_eq "index 0 always shows the raw datetime" "08/30 12:00:00" "$out"

statusline_rotating_time 1 "08/30 12:00:00" 1700000000 1600000000 out
assert_contains "index 1 with numeric week_reset formats a 7d reset line" "$out" "7d reset on"

statusline_rotating_time 1 "08/30 12:00:00" "unknown" 1600000000 out
assert_eq "index 1 with non-numeric week_reset falls back to datetime" "08/30 12:00:00" "$out"

statusline_rotating_time 2 "08/30 12:00:00" 1700000000 1600000000 out
assert_contains "index 2 with numeric five_reset formats a 5h reset line" "$out" "5h reset at"

statusline_rotating_time 2 "08/30 12:00:00" 1700000000 "unknown" out
assert_eq "index 2 with non-numeric five_reset falls back to datetime" "08/30 12:00:00" "$out"

section "statusline_spinner_frame"
statusline_spinner_frame 3 out; assert_eq "frame 3 picks the 4th glyph" "⠸" "$out"
statusline_spinner_frame 13 out; assert_eq "wraps around every 10 seconds" "⠸" "$out"
statusline_spinner_frame 0 out; assert_eq "frame 0 picks the 1st glyph" "⠋" "$out"

section "statusline_format_remaining"
statusline_format_remaining 0 out; assert_eq "0s floors to 1m, never 0m" "1m" "$out"
statusline_format_remaining -100 out; assert_eq "negative input clamps to 0 -> 1m" "1m" "$out"
statusline_format_remaining 30 out; assert_eq "30s rounds to 1m" "1m" "$out"
statusline_format_remaining 90 out; assert_eq "90s rounds to 2m" "2m" "$out"
statusline_format_remaining 3599 out; assert_eq "59m59s rounds up into 1h" "1h" "$out"
statusline_format_remaining 4200 out; assert_eq "70m rounds to 1h" "1h" "$out"
statusline_format_remaining 86399 out; assert_eq "23h59m59s rounds up into 1d" "1d" "$out"
statusline_format_remaining 90000 out; assert_eq "25h formats as 1d1h" "1d1h" "$out"
statusline_format_remaining 399600 out; assert_eq "4d15h formats with no space" "4d15h" "$out"

section "statusline_reset_severity_color (period=1000 for round numbers)"
statusline_reset_severity_color 0 1000 out; assert_eq "0% remaining is green" "$STATUSLINE_GREEN" "$out"
statusline_reset_severity_color 50 1000 out; assert_eq "5% remaining is still green" "$STATUSLINE_GREEN" "$out"
statusline_reset_severity_color 100 1000 out; assert_eq "10% remaining crosses into white" "$STATUSLINE_GRAY_1" "$out"
statusline_reset_severity_color 150 1000 out; assert_eq "15% remaining is still white" "$STATUSLINE_GRAY_1" "$out"
statusline_reset_severity_color 200 1000 out; assert_eq "20% remaining falls back to gray" "$STATUSLINE_GRAY_4" "$out"
statusline_reset_severity_color 10 0 out; assert_eq "zero-length period never divides by zero, stays gray" "$STATUSLINE_GRAY_4" "$out"

section "statusline_reset_part"
statusline_reset_part 1000 "" 18000 out
assert_eq "blank reset shows a gray placeholder" "${STATUSLINE_GRAY_4}--${STATUSLINE_RESET}" "$out"
statusline_reset_part 1000 "unknown" 18000 out
assert_eq "non-numeric reset shows the same placeholder" "${STATUSLINE_GRAY_4}--${STATUSLINE_RESET}" "$out"
statusline_reset_part 1000 1000 18000 out
assert_eq "reset exactly now shows 'now' in green" "${STATUSLINE_GREEN}now${STATUSLINE_RESET}" "$out"
statusline_reset_part 1000 500 18000 out
assert_eq "reset already in the past also shows 'now' in green" "${STATUSLINE_GREEN}now${STATUSLINE_RESET}" "$out"
statusline_reset_part 0 2000 18000 out
assert_contains "future reset formats the countdown" "$(strip_ansi "$out")" "33m"
assert_contains "...colored by its own severity" "$out" "$STATUSLINE_GRAY_1"

section "statusline_resets_segment"
statusline_resets_segment 0 2000 14400 out
plain="$(strip_ansi "$out")"
assert_eq "assembles both values behind a gray label" "Resets: 33m, 4h" "$plain"
statusline_resets_segment 0 "" "" out
assert_eq "both unknown falls back to two placeholders" "Resets: --, --" "$(strip_ansi "$out")"

harness_summary
