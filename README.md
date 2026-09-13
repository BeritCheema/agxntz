# agxntz

Minimal macOS menu-bar monitor for local AI coding agents.

**Philosophy: minimal hindrance, glanceable status.** The menu bar shows only
colored counters — 🟢 working, 🟠 waiting for you, 🔵 done. No name, no icon,
no words. States with zero agents show nothing; with no relevant agents at
all, agxntz has no menu-bar presence whatsoever.

Clicking the counters opens a compact dropdown that goes straight into
Working → Waiting → Done groups (empty groups omitted). Each row shows the
project, what the agent is doing right now, elapsed time on the current task,
and the agent/runtime as secondary info. Every row has a pin: pinned sessions
get their own menu-bar item showing a colored dot plus the live activity text.

## Supported agents

| Agent | Source watched | State quality |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` + optional hooks | best (hooks) / good (heuristic) |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | good |
| OpenCode | `~/.local/share/opencode/storage/{session,message}` | good |
| Grok CLI | `~/.grok/sessions/` (`GROK_HOME` honored) | heuristic |
| pi | `~/.pi/agent/sessions/` (`PI_CODING_AGENT_SESSION_DIR` honored) | heuristic |

Everything is read-only: agxntz never modifies agent data. Detection combines
transcript-tail parsing with a process-liveness check (`ps`), polled every 2s.

### State rules

- **working** — transcript written to within the last 12s (or a fresh hook event)
- **waiting** — assistant stopped on a pending tool call (permission prompt),
  or a `Notification` hook fired
- **done** — assistant finished its turn; the session drops off 30 minutes
  after its last activity
- a session whose agent process is gone disappears immediately (unless done)

### Claude Code hooks (recommended)

For exact state (instead of heuristics), install the hooks — either from the
right-click menu on the counters, or:

```sh
dist/agxntz.app/Contents/MacOS/agxntz --install-claude-hooks
```

This writes a shim to `~/.agxntz/claude-hook.sh` and registers it in
`~/.claude/settings.json` for `UserPromptSubmit`, `PreToolUse`, `Notification`,
`Stop`, `SubagentStop`, and `SessionEnd`. Events land in
`~/.agxntz/claude-events.jsonl` (auto-trimmed).

## Build & run

Requires macOS 14+ and Xcode command-line tools.

```sh
make run     # build, bundle dist/agxntz.app (ad-hoc signed), and open it
make app     # just build the bundle
```

Debug helpers:

```sh
.build/debug/agxntz --scan   # one detection pass, printed to stdout
```

## Controls

- **Left-click** counters or a pinned item → dropdown
- **Pin icon** on a row → keep that session in the menu bar (dot + live activity)
- **Right-click** → unpin / install Claude hooks / quit

## Prior art

Detection approach informed by
[toki-monitor](https://github.com/korjwl1/toki-monitor) (Rust daemon +
SwiftUI menu bar, kqueue file watching) and
[lazyagent](https://github.com/illegalstudio/lazyagent) (Go, per-agent
session-directory adapters).
