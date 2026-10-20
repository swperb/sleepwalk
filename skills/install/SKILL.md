---
name: install
description: Install or reinstall Sleepwalk's sleep watcher on this Mac, so busy Claude Code sessions are handed to the cloud when the lid closes. Use when the user runs /sleepwalk:install or asks to set up Sleepwalk.
---

Install Sleepwalk's sleep watcher by running:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" install --plugin
```

It builds a small Swift program with `swiftc`, loads it as a LaunchAgent and writes
`~/.claude/sleepwalk/config`. If `swiftc` is missing, tell the user to run
`xcode-select --install` and try again. If `jq` is missing, suggest `brew install jq`.

Then run `"${CLAUDE_PLUGIN_ROOT}/bin/sleepwalk" status` and tell the user, in two or three
sentences, that from now on a session that is in the middle of a turn when they close the
lid is pushed to its branch and continued by Claude Code on the web, and that it comes
back in a Terminal window when they open the lid. Mention that the settings are in
`~/.claude/sleepwalk/config` and that untracked, non-ignored files are included in the
handoff commit.
