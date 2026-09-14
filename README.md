# agxntz

Minimal macOS menu-bar monitor for local AI coding agents.

**Philosophy: minimal hindrance, glanceable status.** The menu bar shows one
compact element: a dot per active agent, colored by state — 🟢 working,
🟠 waiting for you, 🔵 done — packed into a small pyramid (1 bigger · 2
stacked · 3 stack+apex · 4 square · 5 square+apex · 6 two rows of three).
Beyond 6 agents the largest state group splits into its own element, and a
single state over 6 collapses to a `● N` count. No name, no icon, no words;
with no relevant agents at all, agxntz has no menu-bar presence whatsoever.

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
  avoid flagging mid-turn status text)

### Sub-agents (Claude Code & Codex)

When a Claude session spawns sub-agents, Claude Code writes each one's
transcript to `~/.claude/projects/<cwd>/<session-id>/subagents/agent-<id>.jsonl`.
agxntz reads these and shows, in the dropdown, one colored dot per live
sub-agent to the right of the "Claude" label. Click the dots to expand a
nested list under the parent showing each sub-agent's live activity and
elapsed time; each nested row has its own pin button to promote that
sub-agent to the menu bar. Sub-agents do not count toward the aggregate
menu-bar counters, and they drop from the list shortly after finishing.

Codex sub-agents work the same way: a spawned Codex sub-agent gets its own
rollout file whose `session_meta` carries `parent_thread_id` and an
`agent_nickname`. agxntz nests it under the parent Codex session (labeled by
nickname, e.g. "Cicero") instead of listing it as a separate Codex agent.

### Liveness & retention

There is no reliable per-session process signal for a passive monitor (unlike
runtimes such as cmux/herdr that own the agent process), so liveness is
best-effort, combining: a process holding the session's transcript file open
(`lsof`), a process of that kind running in the session's cwd or an ancestor
of it, and a coarse "is the kind running" fallback. From that:

- a session **backed by a live process** stays up to **30 min** after its last
  activity, so you notice completion
- a session whose **process looks gone** (killed / CLI closed) is kept only
  **~2 min**, then disappears. Actively-writing sessions always fall inside
  that window, so a genuinely live session is never dropped even if process
  detection misses it.

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

## Settings

A gear icon at the top-right of the dropdown (or **right-click → Settings…**)
opens a sidebar/detail Settings window:

- **Dashboard** — live agent overview, per-agent counts, and pinned sessions
- **Appearance** — pinned-ticker scroll speed and text size, dots-before-split
- **Behavior** — done/killed retention durations, rescan interval
- **Agents** — enable/disable each agent type

Settings persist and apply live.

## Controls

- **Left-click** counters or a pinned item → dropdown
- **Gear icon** (dropdown top-right) → Settings
- **Pin icon** on a row → keep that session in the menu bar (dot + live activity)
- **Right-click** → unpin / Settings… / quit

## Prior art

Detection approach informed by
[toki-monitor](https://github.com/korjwl1/toki-monitor) (Rust daemon +
SwiftUI menu bar, kqueue file watching) and
[lazyagent](https://github.com/illegalstudio/lazyagent) (Go, per-agent
session-directory adapters).
