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

Requires `piper-tts` and `pw-play` on PATH, plus `jq` and `awk`. `sox` generates the
list-item chime (a shipped asset is used if it is missing), and `fzf` is needed only
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

**AwesomeWM** — add to your `globalkeys` table (`gears.table.join`), for example in
`keybindings.lua`:

```lua
-- Absolute path so the bindings work regardless of awesome's PATH
local dictate = os.getenv("HOME") .. "/.local/bin/dictate"

awful.key({ modkey, "Control", "Shift" }, "space", function() awful.spawn({ dictate, "toggle" }) end,
  { description = "pause/resume reading", group = "dictate" }),
awful.key({ modkey, "Control", "Shift" }, "Right", function() awful.spawn({ dictate, "next" }) end,
  { description = "next chunk", group = "dictate" }),
awful.key({ modkey, "Control", "Shift" }, "Left", function() awful.spawn({ dictate, "prev" }) end,
  { description = "previous chunk", group = "dictate" }),
awful.key({ modkey, "Control", "Shift" }, "bracketright", function() awful.spawn({ dictate, "speed", "-0.05" }) end,
  { description = "read faster", group = "dictate" }),
awful.key({ modkey, "Control", "Shift" }, "bracketleft", function() awful.spawn({ dictate, "speed", "+0.05" }) end,
  { description = "read slower", group = "dictate" }),
awful.key({ modkey, "Control", "Shift" }, "Escape", function() awful.spawn({ dictate, "stop" }) end,
  { description = "stop reading", group = "dictate" }),
awful.key({ modkey, "Control", "Shift" }, "s", function()
  awful.spawn.easy_async({ dictate, "status" }, function(stdout, stderr)
    local text = stdout ~= "" and stdout or stderr
    if text == "" then text = "no session" end
    naughty.notify({ title = "dictate", text = text:gsub("%s+$", ""), timeout = 4 })
  end)
end, { description = "reading status", group = "dictate" }),
```

Passing an absolute path plus an argument table means the bindings need neither a shell
nor `~/.local/bin` on awesome's `PATH` — the usual reason these fail silently. Since a
detached session has no visible UI, the `s` binding pops the status line as a `naughty`
notification.

## How it works

### Tables

Markdown tables are unreadable read straight through, so each row is rewritten as
labelled sentences — the column header before each cell — and each row becomes its own
paragraph:

```
| Area            | Current Implementation                    | Why It Matters                  |
|-----------------|-------------------------------------------|---------------------------------|
| **Data entry**  | Typed into a Google Sheet                 | Fewer copy-paste mistakes       |
```

reads as:

> Area: Data entry. Current Implementation: Typed into a Google Sheet. Why It Matters:
> Fewer copy-paste mistakes.

Cells get a sentence-final period, so piper's `--sentence_silence` gives a short pause
between fields, and the paragraph break puts a longer pause between rows. Bold, code
ticks, and alignment colons are stripped; empty cells are skipped; a row with more
cells than headers falls back to "Column N".

Underscores become spaces rather than being deleted, so `domain_name` reads as
"domain name" instead of "domainname".

### Lists

Bullets lose their marker and gain punctuation, so a list reads as one flowing sentence
instead of a run of abrupt fragments: a comma after every item, a full stop after the
last. Items that already end in punctuation are left alone.

```
- Bulk add and CSV import/export for spreadsheet-style data entry
- Live status & scheduled-jobs dashboard (Turbo Streams)
- Per-domain stop control and manual re-validation
```

reads as:

> Bulk add and CSV import/export for spreadsheet-style data entry, Live status &
> scheduled-jobs dashboard (Turbo Streams), Per-domain stop control and manual
> re-validation.

Each item also starts its own chunk, marked by a soft chime — an 880 Hz sine, 280 ms,
faded in and out at -20 dBFS, so it sits well under the voice and tells you a new item
has begun without interrupting the reading. Because each item is its own chunk, seek
steps item by item through a list.

The chime is generated with `sox` at the voice's own sample rate; if `sox` is missing or
fails, `assets/chime-soft-22050.wav` is used instead, and if neither is available the
chime is simply skipped. `DICTATE_CHIME=off` disables it, `DICTATE_CHIME_DB=-14` makes
it more present. `demo/make_demo.sh` regenerates the demo and offers `bell` and `pluck`
alternatives.

Wrapped items are folded into one item before punctuating, so the comma lands at the end
rather than mid-sentence. Blank lines between items still count as one list, and nested
items are treated as continuing the list. Applies to `-`, `*`, and `+` bullets; numbered
lists are left as they are.

### Markup that is skipped

Raw HTML is dropped, so print scaffolding like
`<div style="page-break-before: always;"></div>` is silent rather than spelled out;
inline tags and `<!-- comments -->` go too. Heading `#` and blockquote `>` markers are
only stripped at the start of a line, so `C#`, `#1`, and `a > b` survive intact.

### Everything else

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
| `DICTATE_CHIME`        | `on`                     | `off` disables the list-item chime |
| `DICTATE_CHIME_DB`     | `-20`                    | Chime peak in dBFS; less negative = more present |
