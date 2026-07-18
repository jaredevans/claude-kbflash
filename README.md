# claude-kbflash

A Claude Code plugin that signals with the MacBook keyboard backlight when Claude is waiting for your input. When the idle notification fires, the backlight breathes twice — fade down, hold dark for a second, fade back up — then turns off and stays dark until you type, at which point your original brightness comes back. Permission prompts breathe continuously until you approve the tool.

macOS only, tested on Apple Silicon (macOS 26). Requires Xcode Command Line Tools for `clang`.

## What's here

| File | Purpose |
|------|---------|
| `kbflash.m` | Breathes the backlight N times (default 5); `0` = breathe until killed; `-w N` = breathe N times then backlight off until killed |
| `hooks/hooks.json` | Claude Code hook bindings |
| `hooks/kb-start.sh` | `Notification` hook — starts breathing on idle or permission prompts |
| `hooks/kb-stop.sh` | `UserPromptSubmit` / `PostToolUse` / `SessionEnd` hook — stops breathing |
| `.claude-plugin/` | Plugin manifest + marketplace entry |

## Build

```bash
clang -framework Foundation -o kbflash kbflash.m
```

You don't strictly need to pre-build `kbflash` — the start hook compiles it on first use if the binary is missing.

## Manual usage

```bash
./kbflash        # 5 breaths
./kbflash 10     # 10 breaths
./kbflash 0      # breathe until Ctrl-C / SIGTERM
./kbflash -w 2   # 2 breaths, then backlight off until Ctrl-C / SIGTERM
```

`kbflash` prints each step:

```
backlight brightness level saved (0.35)
backlight brightness level set to 1 (maximum)
start flashing (5 breaths)
flashing ended, brightness restored to original (0.35), auto-brightness on
```

## How it works

**Backlight control.** macOS has no public API for the keyboard backlight, and the old `ioreg`/HID tricks died with the T2/M-series machines. Both tools load the private `CoreBrightness.framework` at runtime with `dlopen` and drive its `KeyboardBrightnessClient` class: `copyKeyboardBacklightIDs` enumerates backlit keyboards, `setBrightness:forKeyboard:` / `brightnessForKeyboard:` read and write levels as 0.0–1.0 floats. No sudo or TCC permissions are needed. Being a private framework, this can break in any macOS release — if it does, expect `KeyboardBrightnessClient class not found` or an empty keyboard list.

**The breath.** `kbflash` saves the current brightness, jumps to maximum, then loops: fade max→off along a cosine ease (30 steps × 25 ms ≈ 0.75 s), hold at off for 1 s, fade off→max the same way — about 2.5 s per breath. When the count is exhausted (or a signal arrives), it restores the saved brightness and re-enables auto-brightness so macOS resumes managing the level. With `-w`, exhausting the count instead eases the backlight down to off and parks there (`pause()` in a loop) until a signal arrives, then restores as usual. Tuning knobs are at the top of the loop in `kbflash.m`: `rampSteps`, `stepDelay`, `holdDelay`.

**Clean shutdown.** `kbflash` installs SIGTERM/SIGINT handlers (without `SA_RESTART`, so signals interrupt the `usleep` calls promptly). A signal abandons the current breath and falls through to the same restore path — killing the process always leaves the keyboard as it found it.

## What happens when the plugin is installed

Install:

```
/plugin marketplace add /path/to/claude-kbflash
/plugin install claude-kbflash@claude-kbflash-marketplace
/reload-plugins
```

That registers the hooks below:

| Hook | Script | Effect |
|------|--------|--------|
| `Notification` | `kb-start.sh` | Idle → 2 breaths then backlight off; permission prompt → breathe until approved |
| `UserPromptSubmit` | `kb-stop.sh` | Stop breathing, restore brightness |
| `PostToolUse` | `kb-stop.sh` | Stop breathing after an approved tool runs (permission case) |
| `SessionEnd` | `kb-stop.sh` | Same cleanup on `/exit` |

Two situations start the backlight signal:

- **Idle:** ~60 s after a turn ends with no input, Claude Code fires the `Notification` hook with "Claude is waiting for your input". The 60 s threshold is built into Claude Code and is not configurable — only the notification on/off toggle is. The backlight breathes twice, then goes dark and stays dark. Typing a prompt restores it via `UserPromptSubmit`.
- **Permission:** the moment Claude needs approval for a tool, the `Notification` hook fires with "Claude needs your permission to use X" — no delay. This breathes continuously — it's urgent, unlike idle. Approving doesn't submit a prompt, so `PostToolUse` does the cleanup: the approved tool finishes, the hook fires, breathing stops (same trick govee-claude uses to clear red back to the working flash).

Mechanics: `kb-start.sh` reads the notification JSON from stdin and greps the message to classify it — idle launches `kbflash -w 2` (2 breaths, then off until killed), permission launches `kbflash 0` (breathe until killed). Either way the process runs detached with `nohup`, records its pid in `~/.claude/claude-kbflash/kbflash.pid`, and the script exits well inside the hook timeout. If a live pid is already recorded, it's a no-op — repeat notifications never stack a second breather. If the binary is missing, the script builds it first (errors go to `~/.claude/claude-kbflash/hook.log`). `kb-stop.sh` kills the recorded pid and removes the pidfile; the dying `kbflash` restores your original brightness and turns auto-brightness back on. When nothing is breathing, `kb-stop.sh` is a no-op, so the `PostToolUse` binding costs nothing during normal work.

Hooks never fail the session: every exit path in both scripts is `exit 0`, matching the "hooks are tiny clients that never break Claude" rule from govee-claude.

### Runtime files

```
~/.claude/claude-kbflash/
  kbflash.pid    pid of the running kbflash (absent when nothing is running)
  hook.log       compile errors from kb-start.sh (rare)
```

## Caveats

- **Multiple Claude sessions share one keyboard.** If session A is breathing and you type into session B, B's `UserPromptSubmit` stops A's breathing. Last-write-wins.
- **Auto-brightness is always re-enabled after a run**, regardless of its prior state. If you keep auto-brightness off, macOS may nudge the level after a flash; flip it back off in System Settings or edit the `enableAutoBrightness:YES` call.
- **Clamshell mode / external keyboards:** only Apple backlit keyboards enumerated by CoreBrightness are driven. With the lid closed there may be nothing to flash (`no backlit keyboard found`).

## Testing the hooks by hand

```bash
echo '{"message":"Claude is waiting for your input"}' | ./hooks/kb-start.sh        # 2 breaths, then backlight off
echo '{"message":"Claude needs your permission to use Bash"}' | ./hooks/kb-start.sh # breathes continuously
cat ~/.claude/claude-kbflash/kbflash.pid                                            # pid of the running kbflash
./hooks/kb-stop.sh                                                                  # stops it, restores brightness
```

An unrelated payload (`{"message":"Some other notification"}`) should do nothing.
