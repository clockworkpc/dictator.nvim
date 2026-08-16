# dictate

Read a text or markdown file aloud with [Piper](https://github.com/OHF-Voice/piper1-gpl) TTS,
with transport controls: pause, resume, seek, live speed changes, and a terminal scrubber.

```
  dictate ── proposal-updated-20260816.md ── en_GB-alan-medium

  ▶  chunk 12/134  ███░░░░░░░░░░░░░░░░░░░  14%  ~18:42 left  speed 0.7

  ...the GoDaddy REST Auctions API went self-serve in August 2026...

  space pause  ←/→ seek  [/] speed  r restart chunk  d detach  q quit
```

## Install

```bash
git clone <this repo> ~/Development/dictate
ln -sfn ~/Development/dictate/dictate ~/.local/bin/dictate
```

Requires `piper-tts` and `pw-play` on PATH, plus `jq` and `awk`. `fzf` is needed only
for the `-i` voice picker. On Arch: `piper-tts-bin`, `piper-voices-en-gb`, `pipewire`.

## Usage

```
dictate [-i] [-b] INPUT [VOICE] [SPEED]   start reading (attaches the TUI unless -b)
dictate tui                               attach the scrubber to a running session
dictate pause | resume | toggle           pause / resume playback
dictate stop | quit                       stop playback and end the session
dictate speed N | +N | -N                 set length scale (lower = faster)
dictate seek N | +N | -N                  jump to / by chunk
dictate next | prev                       seek +1 / -1
dictate status                            one-line status
```

`VOICE` defaults to `alan`, resolved as `en_GB-<VOICE>-medium`. `SPEED` defaults to
`0.7` and is piper's length scale, so **lower is faster**.

```bash
dictate notes.md                  # alan, speed 0.7, TUI attached
dictate notes.md cori 0.9         # different voice, slower
dictate -i notes.md               # pick any installed voice with fzf
dictate -i notes.md 1.1           # picker + speed (VOICE may be omitted)
dictate -i notes.md cori          # "cori" pre-fills the picker's query
dictate -b notes.md               # start detached, no TUI
```

### Controlling a running session

Playback runs as a detached session, so the subcommands work from any shell — or from
a window-manager binding.

The state directory is resolved as `/run/user/$UID/dictate` whenever that exists, in
preference to `$XDG_RUNTIME_DIR`, so a hotkey-spawned process finds the same session a
terminal started even when the WM passes a stripped environment. `XDG_RUNTIME_DIR` is
also re-derived if missing, since `pw-play` needs it to reach the PipeWire socket.
Both were verified under `env -i`.

**Hyprland** (`~/.config/hypr/hyprland.conf`):

```
bind = SUPER SHIFT, space,  exec, dictate toggle
bind = SUPER SHIFT, right,  exec, dictate next
bind = SUPER SHIFT, left,   exec, dictate prev
bind = SUPER SHIFT, bracketright, exec, dictate speed -0.05
bind = SUPER SHIFT, bracketleft,  exec, dictate speed +0.05
bind = SUPER SHIFT, escape, exec, dictate stop
```

**AwesomeWM** (`~/.config/awesome/rc.lua`, after `globalkeys` is defined):

```lua
local dictate = os.getenv("HOME") .. "/.local/bin/dictate"

globalkeys = gears.table.join(globalkeys,
  awful.key({ modkey, "Shift" }, "space",  function() awful.spawn({dictate, "toggle"}) end,
            {description = "pause / resume", group = "dictate"}),
  awful.key({ modkey, "Shift" }, "Right",  function() awful.spawn({dictate, "next"}) end,
            {description = "next chunk", group = "dictate"}),
  awful.key({ modkey, "Shift" }, "Left",   function() awful.spawn({dictate, "prev"}) end,
            {description = "previous chunk", group = "dictate"}),
  awful.key({ modkey, "Shift" }, "]",      function() awful.spawn({dictate, "speed", "-0.05"}) end,
            {description = "faster", group = "dictate"}),
  awful.key({ modkey, "Shift" }, "[",      function() awful.spawn({dictate, "speed", "+0.05"}) end,
            {description = "slower", group = "dictate"}),
  awful.key({ modkey, "Shift" }, "Escape", function() awful.spawn({dictate, "stop"}) end,
            {description = "stop", group = "dictate"})
)
root.keys(globalkeys)
```

The Lua form passes an absolute path and an argument table, so it needs neither a shell
nor `~/.local/bin` on awesome's `PATH`. Adjust the modifiers to taste — `SUPER+space` is
a layout-switch or launcher binding in many configs.

## How it works

The input is markdown-stripped, split into ~320-character chunks on sentence and
paragraph boundaries, and synthesized one chunk at a time with `piper-tts`, played
through `pw-play`. The next chunk is synthesized while the current one plays, so gaps
stay short.

Session state lives in `$XDG_RUNTIME_DIR/dictate/session` as plain files (`idx`,
`state`, `speed`, `pid`, …), which is how the subcommands talk to the daemon.
Pause is `SIGSTOP`/`SIGCONT` on the player; seek and speed changes queue a command
and cut the current chunk short.

**Speed is baked in at synthesis time**, so changing it re-synthesizes from the current
chunk onward — it takes effect at the chunk boundary, not mid-sentence. Rendered chunks
are cached per speed for the life of the session, so seeking back is instant.

Progress is character-weighted, with a within-chunk fraction from the current wav's
duration, so the bar moves continuously and the estimate reflects measured
seconds-per-character rather than a guess.

## Environment

| Variable               | Default                  | Meaning                          |
| ---------------------- | ------------------------ | -------------------------------- |
| `PIPER_VOICE_ROOT`     | `/usr/share/piper-voices` | Where `-i` searches for `.onnx`  |
| `DICTATE_CHUNK_CHARS`  | `320`                    | Target chunk size; also seek granularity |
| `DICTATE_PLAYER`       | `pw-play`                | Player command (`paplay`, `aplay`) |
| `DICTATE_RUN_DIR`      | `/run/user/$UID/dictate` | Session state dir; override to run isolated sessions |
