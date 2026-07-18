#!/bin/bash
# UserPromptSubmit / SessionEnd hook: stop keyboard-backlight breathing.
# kbflash restores the original brightness itself on SIGTERM, so a plain
# kill is enough. Never fails the hook.
set -u

PIDFILE="${HOME}/.claude/claude-kbflash/kbflash.pid"
[ -f "$PIDFILE" ] || exit 0
kill "$(cat "$PIDFILE")" 2>/dev/null
rm -f "$PIDFILE"
exit 0
