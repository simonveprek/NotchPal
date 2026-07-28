# NotchPal

**Your coding agents, live in the notch.**

NotchPal is a tiny macOS menu bar agent that shows what Claude Code and OpenAI Codex
are doing right now — in the Dynamic Island area of your MacBook's notch.

> [!IMPORTANT]
> **NotchPal is source-available from this GitHub repository.** You may use it,
> copy it, modify it, fork it, and redistribute it. You may not sell NotchPal or
> charge for a product or service whose value substantially derives from it.
> Keep the license and attribution when sharing a copy.

Not "an agent is running". Not a spinner. The actual work:

```
◆  Reading NotchController.swift                      2:14
   lines 40–99 · NotchPal
```

```
◆  Running swift build -c release                       18s
   Build the package · NotchPal
```

```
◆  Patching EventServer.swift                          1:02
   and 3 more · NotchPal
```

When nothing is running, NotchPal shows nothing at all.

---

## Contents

- [Why](#why)
- [Requirements](#requirements)
- [Install](#install)
- [How it works](#how-it-works)
- [What it reports](#what-it-reports)
- [When the notch opens](#when-the-notch-opens)
- [Design notes](#design-notes)
- [Configuration](#configuration)
- [Privacy](#privacy)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Trademarks](#trademarks)
- [License](#license)

---

## Why

Agentic coding means long stretches where the model is working and you are not.
You end up alt-tabbing to a terminal to answer one of three questions:

1. Is it still going?
2. What is it doing?
3. Is it waiting on me?

The notch is dead space directly in your field of view. NotchPal puts those three
answers there, and gets out of the way the moment they stop mattering.

---

## Requirements

| | |
|---|---|
| macOS | 26 (Tahoe) or later |
| Xcode | 26 or later |
| Swift | 6.2 toolchain |
| Hardware | Any Mac. On Macs without a notch, the panel floats below the menu bar instead |

NotchPal works with either agent, or both at once. You do not need both installed.

---

## Install

NotchPal is intended to be cloned or downloaded from this GitHub repository and
built locally. Official source and updates live here; paid redistributions are
not authorized.

### From Xcode

```bash
git clone https://github.com/simonveprek/NotchPal.git
cd NotchPal
open Package.swift
```

Pick the **NotchPal** scheme and hit Run. A notch glyph appears in your menu bar and
a card drops down confirming that NotchPal is listening.

Then register the hooks — either from the menu bar item, or:

```bash
swift run NotchPal --install-hooks
```

### As an app bundle

NotchPal runs fine as a bare executable, but a bundle gives it a proper identity and
lets it launch at login like any other app.

```bash
make install
```

This builds `NotchPal.app`, copies it to `/Applications`, registers the hooks, and
launches it.

### Verify

```bash
swift run NotchPal --status
```

```
socket:   /Users/you/Library/Application Support/NotchPal/notchpal.sock
reporter: /path/to/.build/debug/notchpal-report
Claude Code: installed — /Users/you/.claude/settings.json
Codex: installed — /Users/you/.codex/hooks.json
```

For Codex, open `/hooks` once and trust the NotchPal command hook. Codex deliberately
skips new or changed non-managed hooks until their exact definition is reviewed.
Then start a session in either agent; the notch should come alive on your first prompt.

---

## How it works

Claude Code and Codex converged on nearly the same lifecycle hook contract — same
event names, same `session_id` / `cwd` / `hook_event_name` envelope, same
`tool_input` blob. NotchPal exploits that: **one decoder serves both agents.**

```
┌──────────────┐   hook JSON    ┌───────────────┐   1 line of JSON   ┌───────────┐
│ Claude Code  │ ─────────────► │notchpal-report│ ─────────────────► │ NotchPal  │
│    Codex     │   on stdin     │  (tiny CLI)   │   Unix socket      │ (menu bar)│
└──────────────┘                └───────────────┘                    └─────┬─────┘
                                                                           │
                                                                     ┌─────▼─────┐
                                                                     │   notch   │
                                                                     └───────────┘
```

**`notchpal-report`** is spawned by the agent for each lifecycle event. It parses the
payload, summarizes it into a short structured event, writes one line to a Unix
domain socket, and exits. It runs on the agent's critical path, so it follows two
absolute rules:

- **Always exit 0.** A non-zero exit from a hook can block the agent's tool call.
- **Never write to stdout.** Agents parse hook stdout as JSON control output.

If NotchPal is not running, the socket connect fails, and the reporter exits silently
in about a millisecond. There is no retry and no queue — a dropped status update
is worth far less than a stalled agent.

**`NotchPal`** listens on the socket, folds events into per-session state, and drives
[DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit).

### Where the hooks live

| Agent | File | Events |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PostToolUseFailure` `Stop` `StopFailure` `Notification` `PermissionRequest` `SubagentStart` `SubagentStop` `PreCompact` `PostCompact` |
| Codex | `~/.codex/hooks.json` | the same, minus the three Claude-only events |

NotchPal subscribes to the events that change what the notch should show, and no
others — every extra subscription is another process spawned on the agent's
critical path.

The installer is written to be a good guest in a file you own: existing keys are
preserved, a timestamped `.bak` is taken before every write, and uninstall removes
exactly what install added.

```bash
swift run NotchPal --uninstall-hooks
```

---

## What it reports

The whole point is that the detail survives the trip. Every tool gets its own
reading:

| Tool | Shows |
|---|---|
| `Read` | `Reading NotchController.swift` · `lines 40–99` |
| `Edit` | `Editing EventServer.swift` · `replacing every match` |
| `Write` | `Writing README.md` · `4.2 KB` |
| `apply_patch` (Codex) | `Patching schema.ts` · `and 3 more` |
| `Bash` | `Running swift build -c release` · the command's description |
| `Grep` | `Searching “TODO”` · `*.swift` |
| `Glob` | `Finding Sources/**/*.swift` |
| `WebFetch` | `Fetching developer.apple.com` · `/design/…` |
| `WebSearch` | `Searching “liquid glass”` · `web` |
| `Task` | `Delegating explore the parser` · `Explore` |
| `update_plan` (Codex) | `Working on Write the parser` · `step 2 of 3` |
| `mcp__github__create_issue` | `Calling create issue` · `github` |
| anything unknown | the tool name, de-underscored, rather than a blank |

Between tool calls it reports what just finished and how long it took:

```
◆  Continuing                                          1:47
   Last update: reading NotchController.swift in 0.4s · NotchPal
```

Durations are live. A tool call is timed from its `PreToolUse` to the matching
`PostToolUse` by `tool_use_id`, so overlapping calls do not confuse the clock.

---

## When the notch opens

An ambient display earns its place by being quiet.

| State | Notch |
|---|---|
| Nothing running | Hidden |
| Working | Compact — mark on the left, verb and timer on the right |
| Turn starts / ends | Expands for a couple of seconds, then settles |
| Agent needs permission | Expands and **stays** until it is resolved |
| You hover it | Expands, because that is you asking |
| You click a row | Dismisses that session |

Expanding on every tool call would strobe. If you want more, there is one setting
— *Expand when the work changes* — which expands briefly when the agent switches
between kinds of work (reading → running → editing). It is off by default.

### Sessions that never say goodbye

Interrupting a turn, quitting the CLI, or closing the terminal fires no `Stop` and
no `SessionEnd`. NotchPal notices staleness rather than waiting to be told. Reasoning,
continuation, and tool activity remain live for up to 30 minutes of silence; Codex
can legitimately reason for several minutes without emitting a hook event, so a
shorter timeout makes a live turn disappear and then reappear on its next tool call.

You can always click a row to dismiss it, or use **Forget sessions** in the menu.

---

## Design notes

### Liquid Glass, used once

Apple's guidance is explicit that Liquid Glass belongs to the navigation and
control layer, and that you should not stack it:

> Always avoid glass on glass. Stacking Liquid Glass elements can quickly make the
> interface feel cluttered.

On a notched Mac the panel is opaque black; on every other Mac DynamicNotchKit
floats a `.popover` material. Either way, the panel *is already* the material
layer. So NotchPal applies `.glassEffect` in exactly one place — the tinted disc
behind each agent's mark — where it is a genuine control-layer object above the
panel. It carries a `glassEffectID` inside a `GlassEffectContainer`, so when a
second agent starts the two discs fuse and separate.

Everything else on the card is plain vibrant type, which is what Apple tells you
to use on top of a material.

### The marks are vectors, not images

`Sources/NotchPal/Vector/SVGPath.swift` is a complete SVG path-data parser — full
grammar (`M m L l H h V v C c S s Q q T t A a Z z`), implicit repeated argument
sets, unseparated negative numbers, and proper elliptical-arc handling via
endpoint-to-centre conversion.

The two marks ship as their published path data and are parsed into SwiftUI
`Shape`s at launch. That means they are exact at any size, take any tint, animate
as real geometry, and the repo contains zero binary assets.

### Each agent moves differently

You should be able to tell which agent is working from the corner of your eye,
before reading anything. So the motion comes from each mark's own geometry:

- **Claude — pulse.** The burst collapses almost completely, then expands beyond
  its resting size. The full-range motion stays obvious even in the compact notch.
- **Codex — ratchet.** The knot has six-fold symmetry, so a sixth of a turn lands
  it exactly back on itself. Rather than sliding, it advances one notch at a time
  and rests — a mechanism stepping forward, not a wheel spinning.

Claude keeps its coral fill. The OpenAI knot is white for maximum contrast
against the black notch, with the surrounding glass retaining its green tint.

All motion derives from a pausable monotonic clock, so stopping mid-gesture
freezes rather than snapping back. `accessibilityReduceMotion` disables it all.

### What is deliberately absent

The expanded card shows three things: what, the detail behind it, and how long.
There is no agent name (the mark says that), no model name, no tool counter, and
no progress bar. An indeterminate bar cannot tell you anything the mark's own
motion does not already say.

---

## Configuration

Everything lives in the menu bar item.

| Setting | Default |
|---|---|
| Claude Code hooks | off until you turn them on |
| Codex hooks | off until you turn them on |
| Expand when the work changes | off |

Environment:

| Variable | Effect |
|---|---|
| `NOTCHPAL_SOCKET` | Override the socket path |
| `NOTCHPAL_VERBOSE=1` | Make `notchpal-report` log to stderr |

---

## Privacy

NotchPal is entirely local and makes no network calls of any kind.

- The transport is a **Unix domain socket**, `chmod 0600`, in your Application
  Support directory. Nothing is exposed to the network, and there is no port.
- Events are held **in memory only**. Nothing is written to disk, ever.
- Prompts and assistant messages are **truncated to 140 characters** in the
  reporter, before they leave the hook.
- Sessions are forgotten after 30 minutes of silence, and on quit.

Worth knowing: file paths, shell commands, and search patterns from your sessions
are rendered on screen. If you share your screen while an agent runs, that is what
will be visible.

---

## Troubleshooting

**The menu bar item is missing.**
You are probably running a build older than the AppKit status item change. NotchPal
creates its `NSStatusItem` directly rather than using SwiftUI's `MenuBarExtra`,
precisely because `MenuBarExtra` needs a bundled app and therefore never appears
when you Run an SPM executable from Xcode.

**The app launches and nothing happens.**
That is the expected first run. NotchPal has no window and no Dock icon. It shows a
card on launch confirming it is listening — if you missed it, use **Show status**
in the menu.

**Hooks are installed but the notch never moves.**

```bash
swift run NotchPal --status                    # is the reporter path right?
echo '{"session_id":"x","hook_event_name":"UserPromptSubmit","prompt":"hi"}' \
  | .build/debug/notchpal-report --agent claude --verbose
```

`delivered` means the socket is fine and the problem is the hook registration.
`no listener` means NotchPal is not running.

For Codex, also open `/hooks` and check that the NotchPal hooks are trusted.
Codex skips new or changed command hooks until you approve their current hash.

**Hooks say "update needed".**
The registered path points at a different copy of `notchpal-report` than the running
app — usually a debug build after installing to `/Applications`. Toggle the hooks
off and on.

**A session is stuck showing work that finished.**
Click the row to dismiss it, or **Forget sessions**. If it happens repeatedly with
long reasoning turns, raise `stallLimit` for `.thinking` in
`Sources/NotchPal/AgentSession.swift`.

---

## Development

```bash
swift build            # compile
swift test             # 19 tests, no simulator or network needed
make app               # assemble build/NotchPal.app
make status            # socket, reporter path, hook state

swift Scripts/make-icon.swift   # redraw Resources/AppIcon.icns
```

### The mark

The icon is a notch: a menu bar line that dips down and comes back out. It is the
same construction as the status item glyph in `Sources/NotchPal/NotchGlyph.swift`,
rendered at 1024pt — one mark at two sizes, not two that resemble each other.

Like the brand marks, it is drawn in code rather than stored as a binary asset,
so every size is rendered from the vector routine instead of downsampled, and a
reviewer can see what changed from the diff.

It is monochrome on purpose. A coral-to-green stroke naming both agents was tried
first, but the two hues cross through a muddy olive at the midpoint — exactly
where the glyph's most important detail sits. Colour belongs in the notch at
runtime, where it carries state; the icon stays quiet.

### Layout

```
Sources/
  NotchPalCore/           pure Foundation — no SwiftUI, so the reporter stays fast
    Agent.swift             which agents exist and where they keep config
    AgentEvent.swift        the wire model
    HookPayload.swift       hook JSON  →  AgentEvent   (both agents)
    ActivityDescriptor.swift tool_input →  a readable sentence
    HookInstaller.swift     merge/unmerge hooks in the agents' own config
    EventClient.swift       write one line, fail fast, never block the agent
    EventServer.swift       listen, frame by newline, deliver on main
  NotchPalReport/         the hook binary
  NotchPal/            the menu bar agent
    AppModel.swift          events → per-session state
    NotchController.swift   state → hidden / compact / expanded
    Views/                  the notch itself
    Vector/                 SVG path parser + the two marks
```

### Adding a tool description

One case in `ActivityDescriptor.describe`, one test in
`Tests/NotchPalCoreTests`. The bar is that the result should be more useful than the
tool name alone — if it is not, leave it to the default.

### Supporting another agent

If it can run a command on a lifecycle event and hand it JSON, it fits. Add a case
to `Agent`, teach `HookPayload` its event names, and give it a mark and a motion.

---

## Trademarks

The Claude mark is a trademark of **Anthropic**. The OpenAI mark is a trademark of
**OpenAI**. Neither company is affiliated with, sponsors, or endorses this project.

The marks appear here for one reason: to identify which of your agents is running.
That is nominative use, and NotchPal does not use them as its own branding — the app's
own mark is the notch glyph.

One thing to know if you fork this: the Claude path data comes from
[Simple Icons](https://simpleicons.org), whose icon files are CC0. The OpenAI path
data came from an **older Simple Icons release** — it is not in current versions.
Icons usually leave that set following a trademark request, so treat the OpenAI
mark with more care than the Anthropic one.

If you would rather not carry that at all, `BrandMark.data(for:)` is a single
function and swapping in neutral geometric glyphs is a one-line change.

## Credits

Built on [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) by
Kai Azim (MIT).

## License

**Source-available: use, modify, fork, and share; do not sell.**

NotchPal is licensed under the MIT License with the Commons Clause License
Condition v1.0. The MIT permissions remain except for the right to sell the
software as defined by the Commons Clause. This is source-available, not
OSI-approved open source. See [LICENSE](LICENSE) for the binding terms.
