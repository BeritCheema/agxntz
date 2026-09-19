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

## Install

Download the latest `agxntz-<version>.zip` from the
[**Releases**](https://github.com/BeritCheema/agxntz/releases) page, unzip it,
and drag **agxntz.app** to your Applications folder. Launch it — a dot cluster
appears in the menu bar when agents are active (nothing shows when idle). To
quit, right-click the menu-bar item → **Quit**.

Requires macOS 14 (Sonoma) or later. Releases are signed with a Developer ID
and notarized by Apple, so they open without Gatekeeper warnings.

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

## Cutting a release (maintainers)

Releases are produced by GitHub Actions (`.github/workflows/release.yml`): push
a version tag and CI builds on macOS, signs with your Developer ID, notarizes
with Apple, and publishes a GitHub Release with the zipped app attached.

```sh
git tag v0.1.0
git push origin v0.1.0
```

This requires an [Apple Developer Program](https://developer.apple.com/programs/)
membership and these repository secrets
(**Settings → Secrets and variables → Actions**):

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Base64 of your **Developer ID Application** certificate exported as `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PWD` | Password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string (unlocks a throwaway CI keychain) |
| `SIGNING_IDENTITY` | The identity name, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `AC_APPLE_ID` | Your Apple ID email (for notarization) |
| `AC_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID |
| `AC_TEAM_ID` | Your 10-character Apple Developer Team ID |

To export the certificate: open **Keychain Access**, find your *Developer ID
Application* certificate, right-click → **Export** as `.p12`. Find your Team ID
and identity string at [developer.apple.com/account](https://developer.apple.com/account)
(Membership) or via `security find-identity -v -p codesigning`.

You can build a signed, notarized zip locally the same way CI does:

```sh
VERSION=0.1.0 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
AC_APPLE_ID="you@example.com" AC_PASSWORD="app-specific-pw" AC_TEAM_ID="TEAMID" \
make release
```

With no signing env vars, `make release` just produces an ad-hoc-signed zip for
local testing.

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
