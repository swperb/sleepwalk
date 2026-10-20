---
name: resume
description: Bring a Claude Code session that Sleepwalk handed to the cloud back to this Mac. Use when the user runs /sleepwalk:resume, or when a tool call was blocked because this session was handed off.
---

1. Run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" status --json` and pick the sessions whose
   `handoff.status` is `cloud` or `returning`. If there are none, say so and stop.
2. Do not run `resume` yourself: `claude --teleport` needs an interactive terminal. For
   each session, name the repository and its claude.ai link, and give the command to run
   in a terminal (the first 8 characters of the id are enough):
   `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" resume <session>`
3. If the user would rather keep working in this local copy, offer
   `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" release <session>` instead. Warn first that the
   cloud session's commits stay on its branch until they pull them.
