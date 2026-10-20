---
name: status
description: Show which Claude Code sessions Sleepwalk is tracking, which ones were handed to the cloud, and whether the sleep watcher is running. Use when the user runs /sleepwalk:status or asks what Sleepwalk did.
---

Run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" status` and the last 20 lines of
`~/.claude/sleepwalk/handoff.log`, then summarise for the user: which sessions are in the
cloud (with their claude.ai links), any failed handoffs and why, and whether the watcher
is running. If it is not running, suggest /sleepwalk:install.
