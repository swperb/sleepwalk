---
name: install
description: Install or reinstall Sleepwalk's sleep watcher on this Mac, so busy Claude Code sessions are handed to the cloud when the lid closes. Use when the user runs /sleepwalk:install or asks to set up Sleepwalk.
---

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" install --plugin
```

It builds a small Swift program, loads it as a LaunchAgent and writes
`~/.claude/sleepwalk/config`. If it fails:

- `swiftc is required`: ask the user to run `xcode-select --install`, then try again.
- `jq is required`: suggest `brew install jq`.

Then run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" status --json` and check that `watcher` is
`"running"`. Tell the user, in two or three sentences:

- From now on, a session that is mid-turn when they close the lid is pushed to its
  branch and carries on in Claude Code on the web; it comes back in a Terminal window
  when they open the lid.
- Untracked files that are not in `.gitignore` go into that commit, so keep secrets
  ignored.
- Settings are in `~/.claude/sleepwalk/config`.

Mention that macOS may ask once whether Sleepwalk can read their projects folder, and
that they should allow it.
