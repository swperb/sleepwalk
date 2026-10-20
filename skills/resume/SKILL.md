---
name: resume
description: Bring a Claude Code session that Sleepwalk handed to the cloud back to this Mac. Use when the user runs /sleepwalk:resume, or when a tool call was blocked because this session was handed off.
---

1. Run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" status` to find sessions whose handoff is
   `cloud` or `returning`.
2. `claude --teleport` needs an interactive terminal, so do not run `resume` yourself.
   Give the user the command to run in a terminal, one per session:
   `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" resume <session>`.
3. If the user would rather keep working in this local copy and ignore the cloud work,
   offer to run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" release <session>` instead, after
   warning that the cloud session's commits stay on its branch until they pull them.
