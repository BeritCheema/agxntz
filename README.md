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
| Claude Code | `~/.claude/projects/**/*.jsonl` | good |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | good |
| OpenCode | `~/.local/share/opencode/opencode.db` (SQLite) | good |
| Grok CLI | `~/.grok/sessions/` (`GROK_HOME` honored) | heuristic |
| pi | `~/.pi/agent/sessions/` (`PI_CODING_AGENT_SESSION_DIR` honored) | good |
| Oh My Pi | `~/.omp/agent/sessions/` | good |

Everything is read-only: agxntz never modifies agent data. Detection combines
transcript-tail parsing with a process-liveness check (`ps`), polled every 2s.

### State rules

- **working** — transcript written to within the last 12s, or a turn is in
  flight (the last record is user input / a tool result and the agent owes a
  response — generation writes nothing until it produces output)
- **waiting** — assistant stopped on a pending tool call (permission prompt)
- **done** — assistant finished its turn with a text reply (debounced 30s to
  avoid flagging mid-turn status text); the session drops off 30 minutes
  after its last activity
- a session whose agent process is gone disappears immediately (unless done)

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
