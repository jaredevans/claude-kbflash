#!/bin/bash
# Notification hook: signal with the keyboard backlight when Claude is
# waiting for input or needs permission. Reads the Notification JSON payload
# on stdin: idle "waiting for your input" gets 2 breaths then backlight off;
# permission prompts breathe until approved (same classification idea as
# govee-claude, minus the color distinction). Never fails the hook.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="${HOME}/.claude/claude-kbflash"
PIDFILE="${RUNTIME_DIR}/kbflash.pid"
mkdir -p "$RUNTIME_DIR"

# Idle: 2 breaths then backlight off until the user comes back.
# Permission: breathe until the tool is approved.
payload="$(cat)"
if printf '%s' "$payload" | grep -qi "waiting for your input"; then
    ARGS="-w 2"
elif printf '%s' "$payload" | grep -qi "permission"; then
    ARGS="0"
else
    exit 0
fi

# Already breathing? (stale pidfiles fail kill -0 and fall through)
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    exit 0
fi

BIN="${ROOT}/kbflash"
if [ ! -x "$BIN" ]; then
    clang -framework Foundation -o "$BIN" "${ROOT}/kbflash.m" \
        2>>"${RUNTIME_DIR}/hook.log" || exit 0
fi

nohup "$BIN" $ARGS >/dev/null 2>&1 &
echo $! > "$PIDFILE"
exit 0
