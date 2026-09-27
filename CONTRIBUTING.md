# Contributing

agxntz has a few opinions. They are here so a pull request does not have to find them in
review.

## Getting set up

You need macOS 14 or later and Xcode's command line tools.

```sh
git clone <your fork>
cd agxntz
make run          # builds dist/agxntz.app and opens it
```

To try your build, quit the running copy of agxntz first. Launch with `--debug` to log
every state change to `~/.agxntz/debug.log`.

## Before you open a pull request

Run these:

```sh
swift build -c release
.build/release/agxntz --scan     # one detection pass: every session and its state
```

If you changed how an agent is detected, paste the `--scan` lines for that agent and say
what the agent was actually doing at the time. If you changed anything that draws,
attach a screenshot.

## House rules

**Read, never write.** agxntz only reads what agents already put on disk. It never
modifies their files, and it doesn't install hooks or plugins.

**Show only what the transcript supports.** A state is working, waiting or done because
the agent's own records say so. When they are ambiguous, prefer the answer that keeps a
live session visible over one that drops it.

**Stay light.** It runs all day. Parse only what changed since the last pass, and check
the CPU cost of anything added to the poll loop.

**Comments explain why, not what.** A comment earns its place by recording the transcript
quirk, the platform bug or the rejected alternative behind the code.

## Commits

One change per commit, with a short summary line:

```
Codex: a pending function_call is working, not waiting
Fix pinned ticker resetting on each poll
```

## Reporting a bug

Include your macOS version, which agent and its version, and the `--scan` line for the
session that looks wrong. Check the output for anything private before posting it.
