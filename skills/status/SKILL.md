---
name: status
description: Show which Claude Code sessions Sleepwalk is tracking, which ones were handed to the cloud, and whether the sleep watcher is running. Use when the user runs /sleepwalk:status or asks what Sleepwalk did.
---

Run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" status --json`. It prints:

- `watcher`: `"running"` or `"stopped"`
- `last_sleep`, `last_wake`: epoch seconds, or null
- `sessions`: one record per session, newest first, with `session_id`, `cwd`, `state`
  (`busy` or `idle`), `last_activity` (epoch seconds) and, when handed off, `handoff`
  with `status` (`cloud`, `returning`, `resumed` or `failed`), `url`, `branch`, `at` and,
  on failure, `error`.

Reply in a few short lines, most important first:

1. If the watcher is stopped, say so first: nothing will be handed off until the user
   runs /sleepwalk:install.
2. Each session in the cloud or coming back: the repository folder name, the branch, how
   long ago it was handed off, and its claude.ai link. Point to /sleepwalk:resume.
3. Each failed handoff and its `error`. For more detail, read the last 20 lines of
   `~/.claude/sleepwalk/handoff.log`.
4. One line for the rest, such as "2 other sessions, 1 working", and when the Mac last
   slept and woke.

Write times as ages ("2h ago"). Leave out session ids unless the user needs one for a
command, and skip idle sessions older than a few days. If there is nothing to report,
say so in one sentence.
