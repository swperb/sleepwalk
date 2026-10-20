#!/bin/bash
# Tests sleepwalk end to end without touching the real ~/.claude, launchd or the
# network: a temporary home, a local bare git remote and a fake `claude` that records its
# arguments. Run: scripts/sleepwalk/test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$(cd "$HERE/.." && pwd)/bin/sleepwalk"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sleepwalk-test.XXXXXX")" && pwd)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT

export SLEEPWALK_HOME="$T/handoff"
export SLEEPWALK_SETTINGS="$T/settings.json"
export SLEEPWALK_PLIST="$T/agent.plist"
export SLEEPWALK_NO_LAUNCHD=1
export CLAUDE_BIN="$T/fake-claude"
export CLAUDE_CONFIG_FILE="$T/claude.json"
echo '{"projects": {}}' > "$CLAUDE_CONFIG_FILE"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export SLEEPWALK_NO_NOTIFY=1

fails=0
check() { # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}

# Behaves like the real CLI: creating a cloud session is interactive only, prints the
# session and then stays attached; messaging an existing one with -p prints JSON.
cat > "$CLAUDE_BIN" <<'EOF'
#!/bin/bash
n=$(ls "$SLEEPWALK_HOME" | grep -c '^claude-args-')
printf '%s\0' "$@" > "$SLEEPWALK_HOME/claude-args-$(printf %03d "$n")"
case " $* " in
  *" -p "*" --cloud session_01TEST "*) echo '{"ok":true,"session_id":"session_01TEST","url":"https://claude.ai/code/session_01TEST?from=cli"}' ;;
  *" -p "*" --cloud "*) echo '{"ok":false,"error":"Session not found"}'; exit 1 ;;
  *" --teleport "*) exit "${FAKE_TELEPORT_RC:-0}" ;;
  *" --cloud "*)
    [ -t 1 ] || { echo "Error: --cloud cannot be combined with --print." >&2; exit 1; }
    if [ "${FAKE_TRUST:-0}" = 1 ] && [ "$(jq -r --arg d "$PWD" '.projects[$d].hasTrustDialogAccepted // false' "$CLAUDE_CONFIG_FILE")" != true ]; then
      printf '\033[2GQuick\033[8Gsafety\033[15Gcheck:\033[22GIs this a project you trust?\r\n'
      IFS= read -rsn1 _ && echo answered >> "$SLEEPWALK_HOME/trust-answered"
      exit 1
    fi
    printf '\033[?25lCreated cloud session: test\r\nView: https://claude.ai/code/session_01TEST?from=cli&m=0\r\nResume with: claude --teleport session_01TEST\r\n'
    sleep 60 ;;
esac
EOF
chmod +x "$CLAUDE_BIN"

# A repository with an origin remote, on a feature branch, with uncommitted work.
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/repo"
( cd "$T/repo" && git remote add origin "$T/origin.git" && echo one > a.txt && git add a.txt \
  && git commit -q -m init && git push -q origin main && git switch -q -c feature \
  && echo two >> a.txt && echo new > b.txt )

# A transcript in Claude Code's JSONL shape.
cat > "$T/transcript.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ignore me</system-reminder>"},{"type":"text","text":"Add a fillet tool"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working on the fillet tool."},{"type":"tool_use","id":"x","name":"Bash","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"done"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"meta text"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass for the edge case."}]}}
EOF

hook() { # hook <event> [session] [cwd]
  jq -n --arg e "$1" --arg s "${2:-sess-aaaa1111}" --arg c "${3:-$T/repo}" --arg tp "$T/transcript.jsonl" \
    '{session_id: $s, hook_event_name: $e, cwd: $c, transcript_path: $tp}' | "$TOOL" hook
}
rec() { cat "$SLEEPWALK_HOME/sessions/${1:-sess-aaaa1111}.json"; }

# --- install writes hooks once, keeps other settings, and uninstall removes them.
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}' > "$SLEEPWALK_SETTINGS"
"$TOOL" install >/dev/null 2>&1
"$TOOL" install >/dev/null 2>&1
check "install adds one hook per event" \
  [ "$(jq '[.hooks[][] .hooks[] | select(.command | contains("sleepwalk"))] | length' "$SLEEPWALK_SETTINGS")" = 5 ]
check "install keeps other hooks and settings" \
  [ "$(jq -r '.model + " " + (.hooks.Stop | map(.hooks[].command) | join(","))' "$SLEEPWALK_SETTINGS")" = "opus say done,\"$SLEEPWALK_HOME/bin/sleepwalk\" hook" ]
check "PreToolUse hook matches every tool" [ "$(jq -r '.hooks.PreToolUse[0].matcher' "$SLEEPWALK_SETTINGS")" = "*" ]
check "install builds the sleep watcher" [ -x "$SLEEPWALK_HOME/bin/sleepwatch" ]
check "the watcher is signed with a fixed identifier" sh -c "codesign -dv '$SLEEPWALK_HOME/bin/sleepwatch' 2>&1 | grep -q '^Identifier=com.github.swperb.sleepwalk.sleepwatch\$'"
hash1="$(shasum "$SLEEPWALK_HOME/bin/sleepwatch")"
"$TOOL" install >/dev/null 2>&1
check "reinstalling keeps the same watcher binary" [ "$(shasum "$SLEEPWALK_HOME/bin/sleepwatch")" = "$hash1" ]
check "install writes the launch agent" grep -q "<string>$SLEEPWALK_HOME/bin/sleepwatch</string>" "$SLEEPWALK_PLIST"
check "install writes a commented config" grep -q '^# TRIGGER=lid' "$SLEEPWALK_HOME/config"

# --- Sleepwalk's own claude calls are not tracked.
SLEEPWALK_INTERNAL=1 hook UserPromptSubmit sess-int00000
check "internal claude calls make no session record" [ ! -f "$SLEEPWALK_HOME/sessions/sess-int00000.json" ]

# --- hooks track state.
hook SessionStart
check "SessionStart records an idle session" [ "$(rec | jq -r .state)" = idle ]
hook UserPromptSubmit
check "UserPromptSubmit marks it busy" [ "$(rec | jq -r .state)" = busy ]
hook Stop
check "Stop marks it idle" [ "$(rec | jq -r .state)" = idle ]

# --- sleep with the lid open, or with only idle sessions, does nothing.
SLEEPWALK_LID=open "$TOOL" sleep
check "lid open: no handoff" [ "$(rec | jq -r '.handoff.status // "none"')" = none ]
SLEEPWALK_LID=closed "$TOOL" sleep
check "idle session: no handoff" [ "$(rec | jq -r '.handoff.status // "none"')" = none ]

# --- a dry run writes the brief and changes nothing.
hook PreToolUse
SLEEPWALK_LID=closed "$TOOL" sleep --dry-run
brief="$SLEEPWALK_HOME/dry-run-brief-sess-aaaa1111.txt"
check "dry run leaves the tree uncommitted" [ -n "$(git -C "$T/repo" status --porcelain)" ]
check "brief names the branch" grep -q 'The branch feature holds' "$brief"
check "brief has the original request" grep -q '^USER: Add a fillet tool$' "$brief"
check "brief has the latest reply" grep -q '^CLAUDE: Tests pass for the edge case.$' "$brief"
check "brief drops reminders, tool results and meta" sh -c "! grep -qE 'ignore me|done\$|meta text' '$brief'"

# --- a real handoff commits, pushes and starts a cloud session.
SLEEPWALK_LID=closed "$TOOL" sleep
check "handoff records the cloud session" [ "$(rec | jq -r '.handoff.status + " " + .handoff.cloud_id + " " + .handoff.branch')" = "cloud session_01TEST feature" ]
check "handoff commits untracked files" [ -z "$(git -C "$T/repo" status --porcelain)" ]
check "handoff commit is signed off" sh -c "git -C '$T/repo' log -1 --format=%B | grep -q '^Signed-off-by: test'"
check "handoff pushes the branch" [ "$(git -C "$T/origin.git" rev-parse feature)" = "$(git -C "$T/repo" rev-parse HEAD)" ]
args="$(cat "$SLEEPWALK_HOME"/claude-args-* | tr '\0' '\n')"
check "the session is created with the holding prompt" sh -c "printf '%s' \"\$1\" | grep -q 'Your instructions arrive in the next message'" _ "$args"
check "the brief is sent to the new session" sh -c "printf '%s' \"\$1\" | grep -q '^session_01TEST\$' && printf '%s' \"\$1\" | grep -q 'Add a fillet tool'" _ "$args"
check "the create call does not use -p" sh -c "! tr '\\0' '\\n' < '$SLEEPWALK_HOME/claude-args-000' | grep -q '^-p\$'"
check "the attached client is stopped" sh -c "! pgrep -f 'fake-claude --cloud' >/dev/null"
check "the cloud url is recorded" [ "$(rec | jq -r .handoff.url)" = https://claude.ai/code/session_01TEST ]

check "the sleep step leaves no temporary files" sh -c "! ls '$SLEEPWALK_HOME' | grep -q 'sleep-candidates'"
check "the log says how long the handoff took" grep -qE 'to cloud session session_01TEST https://claude.ai/code/session_01TEST after [0-9]+s' "$SLEEPWALK_HOME/handoff.log"

# --- the paused local session is blocked.
out="$(hook PreToolUse)"
check "PreToolUse is denied while in the cloud" [ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision)" = deny ]
out="$(hook UserPromptSubmit)"
check "prompts are blocked while in the cloud" [ "$(printf '%s' "$out" | jq -r .decision)" = block ]
check "other sessions are not blocked" [ -z "$(hook PreToolUse sess-bbbb2222)" ]
hook SessionEnd sess-bbbb2222
hook SessionEnd
check "SessionEnd keeps a handed-off record" [ -f "$SLEEPWALK_HOME/sessions/sess-aaaa1111.json" ]
SLEEPWALK_LID=closed "$TOOL" sleep
check "a second sleep does not hand off again" [ "$(find "$SLEEPWALK_HOME" -name 'claude-args-*' | wc -l | tr -d ' ')" = 2 ]

# --- on main, the handoff moves the work to its own branch.
hook PreToolUse sess-cccc3333
( cd "$T/repo" && git switch -q main )
echo three > "$T/repo/c.txt"
SLEEPWALK_LID=closed "$TOOL" sleep
br="$(rec sess-cccc3333 | jq -r .handoff.branch)"
check "work on main goes to a sleepwalk/ branch" sh -c "case '$br' in sleepwalk/*-sess-ccc) exit 0;; *) exit 1;; esac"
check "main itself is not pushed with the WIP" [ "$(git -C "$T/origin.git" rev-parse main)" = "$(git -C "$T/repo" rev-parse main)" ]

# --- release unpauses and tells the cloud session to wrap up.
"$TOOL" release sess-cccc >/dev/null
check "release clears the handoff" [ "$(rec sess-cccc3333 | jq -r '.handoff.status // "none"')" = none ]
check "release messages the cloud session" sh -c "cat '$SLEEPWALK_HOME'/claude-args-* | tr '\0' '\n' | grep -q 'The user has opened their laptop'"

# --- resume teleports back (exec replaced by the fake claude). A pending Enter, like the
# one Terminal types to start the .command, must not cut the wait short.
touch "$SLEEPWALK_HOME/resume-sess-aaaa1111.command"
t0="$(date +%s)"
touch "$SLEEPWALK_HOME/net-up"
printf '\n' | SLEEPWALK_NETWORK=fake WRAPUP_WAIT=3 "$TOOL" resume sess-aaaa >/dev/null
check "a pending Enter does not skip the wait" [ $(( $(date +%s) - t0 )) -ge 3 ]
check "resume removes its .command file" [ ! -f "$SLEEPWALK_HOME/resume-sess-aaaa1111.command" ]
check "resume marks the session resumed" [ "$(rec | jq -r .handoff.status)" = resumed ]
check "resume runs claude --teleport <id>" sh -c "ls '$SLEEPWALK_HOME'/claude-args-* | tail -1 | xargs cat | tr '\0' ' ' | grep -q '^--teleport session_01TEST'"
check "the stale local copy stays blocked" [ "$(hook PreToolUse | jq -r .hookSpecificOutput.permissionDecision)" = deny ]

# --- two busy sessions in one tree: only the most recent is handed off.
hook Stop sess-cccc3333
hook PreToolUse sess-eeee5555
sleep 1
hook PreToolUse sess-ffff6666
( cd "$T/repo" && git switch -q feature && echo five > e.txt )
SLEEPWALK_LID=closed "$TOOL" sleep
check "the most recent session in a shared tree is handed off" [ "$(rec sess-ffff6666 | jq -r .handoff.status)" = cloud ]
check "the older session in that tree is left alone" [ "$(rec sess-eeee5555 | jq -r '.handoff.status // "none"')" = none ]
hook SessionEnd sess-eeee5555

# --- a session the cloud does not confirm is a failed handoff, not a paused one.
cat > "$T/fake-claude-lost" <<'EOF'
#!/bin/bash
case " $* " in
  *" -p "*) echo '{"ok":false,"error":"Session not found: session_01LOST"}'; exit 1 ;;
  *" --cloud "*) printf 'Resume with: claude --teleport session_01LOST\r\n'; sleep 60 ;;
esac
EOF
chmod +x "$T/fake-claude-lost"
hook PreToolUse sess-hhhh8888
echo six > "$T/repo/f.txt"
CLAUDE_BIN="$T/fake-claude-lost" SLEEP_BUDGET=10 SLEEPWALK_LID=closed "$TOOL" sleep
check "an unconfirmed cloud session fails the handoff" [ "$(rec sess-hhhh8888 | jq -r .handoff.status)" = failed ]
check "the log names the unconfirmed session" grep -q 'session_01LOST was created but did not accept the brief' "$SLEEPWALK_HOME/handoff.log"
check "the failed session is not blocked" [ -z "$(hook PreToolUse sess-hhhh8888)" ]
hook SessionEnd sess-hhhh8888

# --- wake with nothing handed off exits cleanly (it used to trip set -u in its trap).
check "wake exits cleanly" sh -c "SLEEPWALK_HOME='$T/empty-home' SLEEPWALK_LID=open '$TOOL' wake 2>&1 | grep -q unbound && exit 1 || exit 0"

# --- a failed push is recorded and does not pause the session.
hook PreToolUse sess-dddd4444
( cd "$T/repo" && git remote set-url origin "$T/missing.git" && echo four > d.txt )
SLEEPWALK_LID=closed "$TOOL" sleep
check "a failed push is recorded" [ "$(rec sess-dddd4444 | jq -r .handoff.status)" = failed ]
check "a failed session is not blocked" [ -z "$(hook PreToolUse sess-dddd4444)" ]
check "a failed push leaves the work uncommitted" sh -c "git -C '$T/repo' status --porcelain | grep -q 'd.txt'"
hook SessionEnd sess-dddd4444

# --- a "busy" session that has gone quiet (no Stop from the desktop app) is not handed
# off, unless its transcript shows it is still working.
hook PreToolUse sess-qqqq0000
jq --argjson t $(( $(date +%s) - 25 * 60 )) '.last_activity = $t' "$SLEEPWALK_HOME/sessions/sess-qqqq0000.json" > "$T/q.tmp" \
  && mv "$T/q.tmp" "$SLEEPWALK_HOME/sessions/sess-qqqq0000.json"
touch -t "$(date -v-25M +%Y%m%d%H%M.%S)" "$T/transcript.jsonl"
CLAUDE_BIN="$T/fake-claude-lost" SLEEPWALK_LID=closed "$TOOL" sleep
check "a busy session quiet for 25 minutes is left alone" [ "$(rec sess-qqqq0000 | jq -r '.handoff.status // "none"')" = none ]
touch "$T/transcript.jsonl"
hook PreToolUse sess-qqqq0000 >/dev/null; jq --argjson t $(( $(date +%s) - 25 * 60 )) '.last_activity = $t' "$SLEEPWALK_HOME/sessions/sess-qqqq0000.json" > "$T/q.tmp" \
  && mv "$T/q.tmp" "$SLEEPWALK_HOME/sessions/sess-qqqq0000.json"
CLAUDE_BIN="$T/fake-claude-lost" SLEEP_BUDGET=10 SLEEPWALK_LID=closed "$TOOL" sleep
check "but one whose transcript is still being written is handed off" [ "$(rec sess-qqqq0000 | jq -r '.handoff.status // "none"')" = failed ]
hook SessionEnd sess-qqqq0000

# --- folder trust. A repository whose parent is trusted, but not the repository itself.
mkrepo() { # mkrepo <name>: a repository on main with a pushed commit and uncommitted work
  git init -q --bare -b main "$T/$1.git"
  git init -q -b main "$T/$1"
  ( cd "$T/$1" && git remote add origin "$T/$1.git" && echo one > a.txt && git add a.txt \
    && git commit -q -m init && git push -q origin main && echo work > w.txt )
}
mkrepo trusted
jq -n --arg d "$T" '{projects: {($d): {hasTrustDialogAccepted: true}, "/elsewhere": "not an object"}}' > "$CLAUDE_CONFIG_FILE"
out="$(hook SessionStart sess-tr01 "$T/trusted")"
check "SessionStart asks about a folder trusted only through its parent" sh -c "printf '%s' \"\$1\" | grep -q 'sleepwalk trust \"$T/trusted\"'" _ "$out"
check "it asks only once per folder" [ -z "$(hook SessionStart sess-tr02 "$T/trusted")" ]
hook SessionEnd sess-tr02

hook PreToolUse sess-tr01 "$T/trusted"
t0="$(date +%s)"
FAKE_TRUST=1 SLEEPWALK_LID=closed "$TOOL" sleep
check "a folder trusted only through its parent fails fast" [ $(( $(date +%s) - t0 )) -le 6 ]
check "the trust prompt is never answered" [ ! -f "$SLEEPWALK_HOME/trust-answered" ]
check "the handoff is recorded as failed" [ "$(rec sess-tr01 | jq -r .handoff.status)" = failed ]
check "the log says how to trust the folder" grep -q "If you trust it, run: sleepwalk trust \"$T/trusted\"" "$SLEEPWALK_HOME/handoff.log"
check "the checkout is back on main" [ "$(git -C "$T/trusted" branch --show-current)" = main ]
check "the work is uncommitted again" [ "$(git -C "$T/trusted" status --porcelain)" = "?? w.txt" ]
check "the handoff branch is gone locally" [ -z "$(git -C "$T/trusted" branch --list 'sleepwalk/*')" ]
check "and from the remote" [ -z "$(git -C "$T/trusted.git" branch --list 'sleepwalk/*')" ]

"$TOOL" trust "$T/trusted" >/dev/null
check "sleepwalk trust records the folder itself" [ "$(jq -r --arg d "$T/trusted" '.projects[$d].hasTrustDialogAccepted' "$CLAUDE_CONFIG_FILE")" = true ]
check "sleepwalk trust keeps the rest of the config" [ "$(jq -r '.projects["/elsewhere"]' "$CLAUDE_CONFIG_FILE")" = "not an object" ]
hook PreToolUse sess-tr01 "$T/trusted"
FAKE_TRUST=1 SLEEPWALK_LID=closed "$TOOL" sleep
check "once trusted, the handoff goes through" [ "$(rec sess-tr01 | jq -r .handoff.status)" = cloud ]

# --- on an existing branch, a failed handoff puts the remote branch back where it was.
mkrepo untrusted
echo '{"projects": {}}' > "$CLAUDE_CONFIG_FILE"
( cd "$T/untrusted" && git switch -q -c topic && git push -q origin topic )
before="$(git -C "$T/untrusted.git" rev-parse topic)"
hook PreToolUse sess-un02 "$T/untrusted"
FAKE_TRUST=1 SLEEPWALK_LID=closed "$TOOL" sleep
check "the remote branch is put back" [ "$(git -C "$T/untrusted.git" rev-parse topic)" = "$before" ]
check "the local branch is put back" [ "$(git -C "$T/untrusted" rev-parse topic)" = "$before" ]

# --- no network at lid close: join the configured hotspot, then hand off.
cat > "$T/fake-networksetup" <<'EOF'
#!/bin/bash
case "$1" in
  -listallhardwareports) printf 'Hardware Port: Ethernet\nDevice: en1\n\nHardware Port: Wi-Fi\nDevice: en0\n' ;;
  -setairportnetwork) echo "$2 $3" > "$SLEEPWALK_HOME/joined"; touch "$SLEEPWALK_HOME/net-up" ;;
  -listpreferredwirelessnetworks) printf 'Preferred networks on %s:\n\tHome\n\tAlex\342\200\231s iPhone (2)\n\tSam\342\200\231s iPhone\n' "$2" ;;
esac
EOF
chmod +x "$T/fake-networksetup"
mkrepo hotspot
jq --arg d "$T/hotspot" '.projects[$d] = {hasTrustDialogAccepted: true}' "$CLAUDE_CONFIG_FILE" > "$T/c.tmp" && mv "$T/c.tmp" "$CLAUDE_CONFIG_FILE"
hook PreToolUse sess-hs01 "$T/hotspot"
rm -f "$SLEEPWALK_HOME/net-up"
SLEEPWALK_NETWORK=fake NETWORKSETUP="$T/fake-networksetup" HOTSPOT_SSID="Robin's iPhone" SLEEPWALK_LID=closed "$TOOL" sleep
check "with no network, sleep joins the hotspot on the Wi-Fi device" [ "$(cat "$SLEEPWALK_HOME/joined" 2>/dev/null)" = "en0 Robin's iPhone" ]
check "and then hands off" [ "$(rec sess-hs01 | jq -r .handoff.status)" = cloud ]
rm -f "$SLEEPWALK_HOME/joined"
hook PreToolUse sess-hs02 "$T/hotspot"
SLEEPWALK_NETWORK=fake NETWORKSETUP="$T/fake-networksetup" HOTSPOT_SSID="Robin's iPhone" SLEEPWALK_LID=closed "$TOOL" sleep
check "with a network, the hotspot is left alone" [ ! -f "$SLEEPWALK_HOME/joined" ]

# --- sleepwalk hotspot stores the saved name exactly, from a loosely typed one.
NETWORKSETUP="$T/fake-networksetup" "$TOOL" hotspot "alex's iphone (2)" >/dev/null
check "hotspot stores the saved spelling" sh -c ". '$SLEEPWALK_HOME/config'; [ \"\$HOTSPOT_SSID\" = \"\$(printf 'Alex\\342\\200\\231s iPhone (2)')\" ]"
check "hotspot refuses a name that is not saved" sh -c "! NETWORKSETUP='$T/fake-networksetup' '$TOOL' hotspot 'Nobody' 2>/dev/null"
check "hotspot lists the saved iPhones" sh -c "NETWORKSETUP='$T/fake-networksetup' '$TOOL' hotspot | grep -q 'Sam'"

"$TOOL" uninstall >/dev/null
check "uninstall removes only its hooks" [ "$(jq -c .hooks "$SLEEPWALK_SETTINGS")" = '{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}' ]

# --- the plugin install leaves settings.json to the plugin's own hooks.
out="$(hook SessionStart sess-gggg7777)"
check "SessionStart warns when the watcher is not installed" sh -c "printf '%s' \"\$1\" | grep -q '/sleepwalk:install'" _ "$out"
"$TOOL" install --plugin >/dev/null 2>&1
check "install --plugin adds no settings hooks" [ "$(jq '[.hooks[][] .hooks[] | select(.command | contains("sleepwalk"))] | length' "$SLEEPWALK_SETTINGS")" = 0 ]
check "install --plugin still writes the launch agent" [ -f "$SLEEPWALK_PLIST" ]
check "SessionStart is quiet once installed" [ -z "$(hook SessionStart sess-gggg7777)" ]

# --- the cloud brief: what was in flight, the task list, and no Sleepwalk notes. -------
# A synthetic transcript in the shapes Claude Code writes: a SessionStart hook attachment,
# tool_use / tool_result pairs, a background Bash whose completion arrives as a
# <task-notification> queue operation, a blocked call, TodoWrite plus a desktop-app plan
# step and Task tools, a call with no result yet, and a half-written last line.
mkrepo briefrepo
BT="$T/brief-transcript.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":"Run the migration in four steps, then write NOTES.md"}}'
  echo '{"type":"attachment","attachment":{"type":"hook_success","hookName":"SessionStart:startup","hookEvent":"SessionStart","content":"Sleepwalk: Claude Code trusts /x only through /. Ask the user. If they agree, run: sleepwalk trust \"/x\""}}'
  echo '{"type":"user","message":{"role":"user","content":"Sleepwalk is enabled but its sleep watcher is not installed, so nothing will be handed off when the lid closes."}}'
  for i in A B C; do
    jq -nc --arg t "FILLER-$i $(printf 'x%.0s' $(seq 1 1500))" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
  done
  for i in 0 1 2 3 4; do
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r'$i'","name":"Read","input":{"file_path":"/repo/early'$i'.txt"}}]}}'
    echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r'$i'","content":"ok"}]}}'
  done
  cat <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Starting the migration."},{"type":"tool_use","id":"t0","name":"TodoWrite","input":{"todos":[{"content":"Step 1","status":"completed","activeForm":"a"},{"content":"Step 2","status":"in_progress","activeForm":"b"},{"content":"Step 3","status":"pending","activeForm":"c"},{"content":"Write NOTES.md","status":"pending","activeForm":"d"}]}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t0","content":"Todos updated"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"make step1","description":"Step 1"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"step 1 ok","is_error":false}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make step2","run_in_background":true}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"Command running in background with ID: b1. Output is being written to: /tmp/b1.output"}]}}
{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>t2</tool-use-id>\n<status>completed</status>\n<summary>Background command completed (exit code 0)</summary>\n</task-notification>"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"mcp__ccd_turn__update_plan","input":{"advance":true}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"p1","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"k1","name":"TaskCreate","input":{"subject":"Tidy up","description":"d"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"k1","content":"Task #7 created successfully: Tidy up"}]},"toolUseResult":{"task":{"id":"7","subject":"Tidy up"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"k2","name":"TaskUpdate","input":{"taskId":"7","status":"in_progress"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"k2","content":"Updated task #7 status"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"make step3"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"<tool_use_error>Blocked: nope</tool_use_error>","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Step 3 was blocked; retrying.\n\nSeparately: Sleepwalk found this folder is only trusted through a parent. Do you want me to run `sleepwalk trust \"/x\"`?"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t5","name":"Write","input":{"file_path":"/repo/NOTES.md","content":"notes"}}]}}
{"type":"assistant","mess
EOF
} > "$BT"
jq -n --arg tp "$BT" --arg c "$T/briefrepo" '{session_id: "sess-brief01", hook_event_name: "PreToolUse", cwd: $c, transcript_path: $tp}' | "$TOOL" hook
BRIEF_CHARS=3000 SLEEPWALK_LID=closed "$TOOL" sleep --dry-run
bf="$SLEEPWALK_HOME/dry-run-brief-sess-brief01.txt"
bhas() { grep -qF -- "$1" "$bf"; }
check "brief: a finished call is marked done" bhas '- Bash: make step1  [done]'
check "brief: a background call that completed says so" bhas '- Bash: make step2 (in the background)  [ran in the background: completed]'
check "brief: a refused call shows its error" bhas '- Bash: make step3  [error: Blocked: nope]'
check "brief: a call with no result was still running" bhas '- Write: /repo/NOTES.md  [NO RESULT: still running'
check "brief: only the last 8 tool calls are listed" sh -c "grep -qF 'last 8 of 9 tool calls' '$bf' && ! grep -q 'early0' '$bf' && grep -q 'early1' '$bf'"
check "brief: task-list tools are not listed as work" sh -c "! grep -qE '^- (TodoWrite|TaskCreate|TaskUpdate|mcp__ccd_turn__update_plan)' '$bf'"
check "brief: the task list has the latest state" sh -c "sed -n '/^TASK LIST/,/^\$/p' '$bf' | tr '\n' '|' | grep -qF -- '- [completed] Step 1|- [completed] Step 2|- [in_progress] Step 3|- [pending] Write NOTES.md|- [in_progress] Tidy up|'"
check "brief: Sleepwalk's own notes and relays are dropped" sh -c "! grep -qiE 'sleepwalk trust|sleep watcher is not installed' '$bf'"
check "brief: the rest of that reply is kept" bhas 'CLAUDE: Step 3 was blocked; retrying.'
check "brief: the excerpt stays within BRIEF_CHARS" [ "$(sed -n '/^ORIGINAL REQUEST:/,$p' "$bf" | wc -c | tr -d ' ')" -le 3000 ]
check "brief: a long conversation is cut at its start" sh -c "grep -q 'FILLER-C' '$bf' && ! grep -q 'FILLER-A' '$bf'"
check "brief: git push uses the environment's remote, not origin" sh -c "grep -qF 'git push -u <remote> HEAD' '$bf' && grep -qF 'git remote -v' '$bf' && grep -qF 'claude --teleport' '$bf' && ! grep -qE 'git push [^<]*origin' '$bf'"
check "brief: says how to wrap up for the user" bhas 'end with a short summary for the user: what you did, what is left, and any decisions you made for them'
check "wrap-up message asks for a summary for the user" sh -c "cat '$SLEEPWALK_HOME'/claude-args-* | tr '\0' '\n' | grep -q 'any decisions you made for them'"
hook SessionEnd sess-brief01 "$T/briefrepo"

# === subagent hook events ===============================================================
# A subagent's tool calls carry its parent's session_id plus agent_id and agent_type, and
# the subagent's own cwd: an isolated .claude/worktrees/agent-* checkout. They must keep
# the session alive without moving its folder or changing its state. Self-contained.
git init -q --bare "$T/sa-origin.git"
git init -q -b main "$T/sa"
( cd "$T/sa" && git remote add origin "$T/sa-origin.git" && echo one > a.txt && git add a.txt \
  && git commit -q -m init && git push -q origin main && git switch -q -c feature \
  && git worktree add -q .claude/worktrees/agent-a1 -b agent-a1 \
  && git worktree add -q .claude/worktrees/agent-b2 -b agent-b2 \
  && echo main-work >> a.txt && echo sub-work > .claude/worktrees/agent-a1/s.txt )
SA="$T/sa"; SA_A1="$SA/.claude/worktrees/agent-a1"; SA_B2="$SA/.claude/worktrees/agent-b2"
cp "$T/transcript.jsonl" "$T/sa-transcript.jsonl"
sa_hook() { # sa_hook <event> <cwd> [agent_id] [session]
  jq -n --arg e "$1" --arg c "$2" --arg a "${3:-}" --arg s "${4:-sess-sa01}" --arg tp "$T/sa-transcript.jsonl" \
    '{session_id: $s, hook_event_name: $e, cwd: $c, transcript_path: $tp, permission_mode: "default"}
     + (if $a == "" then {} else {agent_id: $a, agent_type: "general-purpose"} end)' | "$TOOL" hook
}
sa_age() { # sa_age <minutes>: makes the session and its transcript look that old
  jq --argjson t $(( $(date +%s) - $1 * 60 )) '.last_activity = $t' "$SLEEPWALK_HOME/sessions/sess-sa01.json" > "$T/sa.tmp" \
    && mv "$T/sa.tmp" "$SLEEPWALK_HOME/sessions/sess-sa01.json"
  touch -t "$(date -v-"$1"M +%Y%m%d%H%M.%S)" "$T/sa-transcript.jsonl"
}
sa_hook UserPromptSubmit "$SA"
sa_hook PreToolUse "$SA"
sa_age 25
sa_hook PreToolUse "$SA_A1" a1a1a1a1
check "a subagent's tool call keeps the session's folder" [ "$(rec sess-sa01 | jq -r .cwd)" = "$SA" ]
check "and records the subagent's worktree" [ "$(rec sess-sa01 | jq -c .worktrees)" = "[\"$SA_A1\"]" ]
check "and counts as activity" [ $(( $(date +%s) - $(rec sess-sa01 | jq .last_activity) )) -lt 60 ]
sa_hook Stop "$SA_A1" a1a1a1a1
check "a subagent's Stop does not mark the session idle" [ "$(rec sess-sa01 | jq -r .state)" = busy ]
sa_hook SessionEnd "$SA_A1" a1a1a1a1
check "a subagent's SessionEnd does not drop the session" [ -f "$SLEEPWALK_HOME/sessions/sess-sa01.json" ]
sa_hook PreToolUse "$SA_B2"
check "without agent_id, a call from an agent worktree of the session's folder is a subagent's" \
  [ "$(rec sess-sa01 | jq -c '[.cwd, .worktrees]')" = "[\"$SA\",[\"$SA_A1\",\"$SA_B2\"]]" ]
sa_hook PreToolUse "$SA_A1" a1a1a1a1
check "worktrees are listed once, most recent last" [ "$(rec sess-sa01 | jq -c .worktrees)" = "[\"$SA_B2\",\"$SA_A1\"]" ]
sa_hook PreToolUse "$SA_A1" zzzz sess-sa99
check "a subagent event for an untracked session records nothing" [ ! -f "$SLEEPWALK_HOME/sessions/sess-sa99.json" ]

# A parent waiting on subagents writes nothing to its own transcript; their tool calls
# keep it eligible past STALE_MINUTES.
sa_age 25
SLEEPWALK_LID=closed "$TOOL" sleep --dry-run
check "a quiet parent with no subagent activity is not handed off" [ ! -f "$SLEEPWALK_HOME/dry-run-brief-sess-sa01.txt" ]
sa_hook PreToolUse "$SA_A1" a1a1a1a1
SLEEPWALK_LID=closed "$TOOL" sleep --dry-run
check "a parent whose subagents are working is handed off" [ -f "$SLEEPWALK_HOME/dry-run-brief-sess-sa01.txt" ]
check "the brief names the subagent worktree left with uncommitted work" \
  grep -q "^  - $SA_A1\$" "$SLEEPWALK_HOME/dry-run-brief-sess-sa01.txt"
check "but not a clean one" sh -c "! grep -q '$SA_B2' '$SLEEPWALK_HOME/dry-run-brief-sess-sa01.txt'"
check "the log names it too" grep -q "subagent worktree $SA_A1 has uncommitted changes" "$SLEEPWALK_HOME/handoff.log"

SLEEPWALK_LID=closed "$TOOL" sleep
check "the handoff pushes the session's own tree" [ "$(git -C "$T/sa-origin.git" show feature:a.txt 2>/dev/null | tail -1)" = main-work ]
check "without committing the agent worktrees into it" \
  [ -z "$(git -C "$T/sa-origin.git" ls-tree -r --name-only feature -- .claude)" ]
check "and leaves the subagent's uncommitted work in place" [ "$(git -C "$SA_A1" status --porcelain)" = "?? s.txt" ]
"$TOOL" release sess-sa01 >/dev/null
sa_hook SessionEnd "$SA"

# --- WIP commit: nested repositories, agent worktrees and large files ------------------
# Claude Code puts subagent worktrees in .claude/worktrees/<name>, and people keep other
# clones inside a checkout. `git add -A` would commit each as a broken gitlink (mode
# 160000, no .gitmodules); they must stay out of the WIP commit, as must files too big to
# push. A real submodule already in HEAD keeps working.
mkrepo sublib
mkrepo nestrepo
( cd "$T/nestrepo" && rm w.txt && head -c 1000 /dev/zero > data.bin \
  && git -c protocol.file.allow=always submodule add -q "$T/sublib.git" lib 2>/dev/null \
  && git add data.bin && git commit -q -m "add lib" && git push -q origin main \
  && git worktree add -q .claude/worktrees/agent-x -b agent-x \
  && git init -q scratch && echo x > scratch/f \
  && git init -q vendored && echo v > vendored/f && git -C vendored add f && git -C vendored commit -q -m v \
  && echo lib2 > lib/new.txt && git -C lib add new.txt && git -C lib commit -q -m lib2 \
  && echo work > w.txt && mkdir docs && echo n > "docs/my notes.txt" \
  && head -c 2097152 /dev/zero > big.bin && head -c 2097152 /dev/zero > data.bin )
nest_status() { git -C "$T/nestrepo" status --porcelain | sort | tr '\n' ' '; }
nest_before="$(nest_status)"
hook PreToolUse sess-nr01 "$T/nestrepo"
MAX_FILE_MB=1 SLEEPWALK_LID=closed "$TOOL" sleep --dry-run
nbrief="$SLEEPWALK_HOME/dry-run-brief-sess-nr01.txt"
check "dry run: the brief lists the large file left behind" grep -q 'big.bin' "$nbrief"
check "dry run: the brief lists the nested repositories left behind" sh -c "grep -q '.claude/worktrees/agent-x' '$nbrief' && grep -q 'scratch' '$nbrief'"
check "dry run: the tree is untouched" [ "$(nest_status)" = "$nest_before" ]
MAX_FILE_MB=1 SLEEPWALK_LID=closed "$TOOL" sleep
check "nested repos: the handoff goes through" [ "$(rec sess-nr01 | jq -r .handoff.status)" = cloud ]
nbr="$(rec sess-nr01 | jq -r .handoff.branch)"
check "the WIP commit has no gitlink but the real submodule" \
  [ "$(git -C "$T/nestrepo.git" ls-tree -r "$nbr" | awk '$2 == "commit" { print $4 }')" = lib ]
check "the real submodule's new commit is in the WIP commit" \
  [ "$(git -C "$T/nestrepo.git" rev-parse "$nbr:lib")" = "$(git -C "$T/nestrepo/lib" rev-parse HEAD)" ]
check "small untracked files are in the WIP commit" \
  sh -c "git -C '$T/nestrepo.git' cat-file -e '$nbr:w.txt' && git -C '$T/nestrepo.git' cat-file -e '$nbr:docs/my notes.txt'"
check "a large untracked file is left out" sh -c "! git -C '$T/nestrepo.git' cat-file -e '$nbr:big.bin' 2>/dev/null"
check "a large change to a tracked file is left out" [ "$(git -C "$T/nestrepo.git" cat-file -s "$nbr:data.bin")" = 1000 ]
check "what was left out stays in the tree, untouched" \
  [ "$(nest_status)" = " M data.bin ?? .claude/ ?? big.bin ?? scratch/ ?? vendored/ " ]
check "the agent worktree still works" [ "$(git -C "$T/nestrepo/.claude/worktrees/agent-x" branch --show-current)" = agent-x ]
check "the commit message lists what was left out" \
  sh -c "git -C '$T/nestrepo' log -1 --format=%b | grep -q 'big.bin' && git -C '$T/nestrepo' log -1 --format=%b | grep -q 'vendored'"
check "the cloud brief lists what was left out" sh -c "cat '$SLEEPWALK_HOME'/claude-args-* | tr '\0' '\n' | grep -q 'scratch/'"
check "the log lists what was left out" grep -q 'left out .claude/worktrees/agent-x/ (a nested git repository)' "$SLEEPWALK_HOME/handoff.log"

# A gitlink staged by hand is taken back out, also when the session runs in a subfolder.
mkrepo neststaged
( cd "$T/neststaged" && mkdir src && echo s > src/s.txt && git worktree add -q .claude/worktrees/agent-z -b agent-z \
  && git add -A 2>/dev/null )
hook PreToolUse sess-nr03 "$T/neststaged/src"
SLEEPWALK_LID=closed "$TOOL" sleep
nbr="$(rec sess-nr03 | jq -r .handoff.branch)"
check "a hand-staged gitlink: the handoff goes through" [ "$(rec sess-nr03 | jq -r .handoff.status)" = cloud ]
check "the hand-staged gitlink is not in the WIP commit" [ -z "$(git -C "$T/neststaged.git" ls-tree -r "$nbr" | awk '$2 == "commit"')" ]
check "files outside the session's subfolder are committed" git -C "$T/neststaged.git" cat-file -e "$nbr:w.txt"
check "the worktree is left untracked" [ "$(git -C "$T/neststaged" status --porcelain)" = "?? .claude/" ]

# A failed handoff in such a tree puts it back exactly as it was.
mkrepo nestundo
( cd "$T/nestundo" && git switch -q -c topic && git push -q origin topic \
  && git worktree add -q .claude/worktrees/agent-y -b agent-y && git init -q scratch \
  && head -c 2097152 /dev/zero > big.bin && echo more >> a.txt )
undo_state() { ( cd "$T/nestundo" && git status --porcelain | sort; git rev-parse HEAD; git branch --show-current; git diff | shasum ); }
undo_before="$(undo_state)"
hook PreToolUse sess-nr02 "$T/nestundo"
CLAUDE_BIN="$T/fake-claude-lost" MAX_FILE_MB=1 SLEEP_BUDGET=10 SLEEPWALK_LID=closed "$TOOL" sleep
check "nested repos: a failed handoff is recorded" [ "$(rec sess-nr02 | jq -r .handoff.status)" = failed ]
check "and the tree is exactly as it was" [ "$(undo_state)" = "$undo_before" ]
check "and the remote branch is back where it was" [ "$(git -C "$T/nestundo.git" rev-parse topic)" = "$(git -C "$T/nestundo" rev-parse HEAD)" ]

# === lid open -> resume ================================================================
# Wake order, watching the cloud branch, clean output, a failed teleport and no network.
# Runs in its own home so sessions from the tests above do not join in.
saved_home="$SLEEPWALK_HOME"
export SLEEPWALK_HOME="$T/handoff-wake" SLEEPWALK_NETWORK=fake
mkdir -p "$SLEEPWALK_HOME" && touch "$SLEEPWALK_HOME/net-up"
cat > "$T/fake-open" <<'EOF'
#!/bin/bash
basename "$1" >> "$SLEEPWALK_HOME/opened"
EOF
chmod +x "$T/fake-open"
opened() { cat "$SLEEPWALK_HOME/opened" 2>/dev/null | tr '\n' ' '; }
wrapups() { cat "$SLEEPWALK_HOME"/claude-args-* | tr '\0' '\n' | grep -c 'The user has opened'; }
wake() { SLEEPWALK_OPEN="$T/fake-open" SLEEPWALK_LID=open "$TOOL" wake; }
for r in wake1 wake2 wake3; do
  mkrepo "$r"
  jq --arg d "$T/$r" '.projects[$d] = {hasTrustDialogAccepted: true}' "$CLAUDE_CONFIG_FILE" > "$T/c.tmp" && mv "$T/c.tmp" "$CLAUDE_CONFIG_FILE"
done
hook PreToolUse sess-wk01 "$T/wake1"
hook PreToolUse sess-wk02 "$T/wake2"
SLEEPWALK_LID=closed "$TOOL" sleep
check "the handoff records the commit it pushed" [ "$(rec sess-wk01 | jq -r .handoff.sha)" = "$(git -C "$T/wake1" rev-parse HEAD)" ]

# Two sessions: one window each, oldest handoff first, after every cloud session is told.
for s in sess-wk01:100 sess-wk02:200; do
  f="$SLEEPWALK_HOME/sessions/${s%:*}.json"
  jq --argjson at "$(( $(date +%s) - ${s#*:} ))" '.handoff.at = $at' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
wake
check "wake opens one window per session, oldest handoff first" [ "$(opened)" = "resume-sess-wk02.command resume-sess-wk01.command " ]
check "wake tells each cloud session to wrap up" [ "$(rec sess-wk01 | jq -r .handoff.status) $(rec sess-wk02 | jq -r .handoff.status)" = "returning returning" ]
check "wake notes where the cloud branch stood" [ "$(rec sess-wk01 | jq -r .handoff.wrapup_sha)" = "$(rec sess-wk01 | jq -r .handoff.sha)" ]
check "wake leaves no lock behind" [ ! -d "$SLEEPWALK_HOME/wake.lock" ]

# The cloud session pushes while resume waits: resume goes once the branch is quiet.
br="$(rec sess-wk01 | jq -r .handoff.branch)"
git clone -q "$T/wake1.git" "$T/cloud1"
( cd "$T/cloud1" && git switch -q "$br" && echo cloud > cloud.txt && git add cloud.txt \
  && git commit -q -m "Cloud: finish the fillet tool" )
( sleep 2; git -C "$T/cloud1" push -q origin "$br" ) &
t0="$(date +%s)"
out="$(WRAPUP_WAIT=30 PUSH_QUIET=2 SLEEPWALK_POLL=1 "$TOOL" resume sess-wk01 < /dev/null 2>&1)"
took=$(( $(date +%s) - t0 ))
wait
check "resume goes soon after the cloud push, not after WRAPUP_WAIT" [ "$took" -lt 15 ]
check "resume lists the cloud session's new commits" sh -c "printf '%s' \"\$1\" | grep -q '^  [0-9a-f]* Cloud: finish the fillet tool\$'" _ "$out"
check "the header names the repository and branch" sh -c "printf '%s' \"\$1\" | grep -q '^Sleepwalk · wake1\$' && printf '%s' \"\$1\" | grep -q '^  branch  $br\$'" _ "$out"
check "output that is not a terminal has no escape codes" sh -c "! printf '%s' \"\$1\" | grep -q \"\$(printf '\\033')\"" _ "$out"
check "resume removes only its own .command file" [ ! -f "$SLEEPWALK_HOME/resume-sess-wk01.command" ] && [ -f "$SLEEPWALK_HOME/resume-sess-wk02.command" ]
check "resume teleports and marks the session resumed" sh -c "[ \"\$(jq -r .handoff.status '$SLEEPWALK_HOME/sessions/sess-wk01.json')\" = resumed ] && ls '$SLEEPWALK_HOME'/claude-args-* | tail -1 | xargs cat | tr '\0' ' ' | grep -q '^--teleport session_01TEST'"
check "resume leaves no lock or poll files" sh -c "! ls '$SLEEPWALK_HOME' | grep -q 'lock\|poll'"

# A teleport that fails says what to do next and leaves the session ready to retry.
out="$(FAKE_TELEPORT_RC=3 WRAPUP_WAIT=1 "$TOOL" resume sess-wk02 < /dev/null 2>&1)"; rc=$?
check "a failed teleport exits with its code" [ "$rc" = 3 ]
check "and says how to retry, release or open the web" sh -c "printf '%s' \"\$1\" | grep -q 'resume sess-wk02' && printf '%s' \"\$1\" | grep -q 'release sess-wk02' && printf '%s' \"\$1\" | grep -q 'https://claude.ai/code/session_01TEST'" _ "$out"
check "the session stays paused, waiting to come back" [ "$(rec sess-wk02 | jq -r .handoff.status)" = returning ]
told="$(wrapups)"
rm -f "$SLEEPWALK_HOME/opened"
wake
check "the next wake reopens it" [ "$(opened)" = "resume-sess-wk02.command " ]
check "without messaging the cloud session again" [ "$(wrapups)" = "$told" ]
rm -f "$SLEEPWALK_HOME/opened"
mkdir "$SLEEPWALK_HOME/resume-sess-wk02.lock" && echo $$ > "$SLEEPWALK_HOME/resume-sess-wk02.lock/pid"
wake
check "a session with a resume window running is left alone" [ -z "$(opened)" ]
check "a second resume of it refuses" sh -c "! '$TOOL' resume sess-wk02 < /dev/null 2>/dev/null"
rm -rf "$SLEEPWALK_HOME/resume-sess-wk02.lock"
WRAPUP_WAIT=1 "$TOOL" resume sess-wk02 < /dev/null > /dev/null 2>&1
check "a retry brings it back" [ "$(rec sess-wk02 | jq -r .handoff.status)" = resumed ]

# A wrap-up message that does not get through is sent again later.
hook PreToolUse sess-wk03 "$T/wake3"
SLEEPWALK_LID=closed "$TOOL" sleep
rm -f "$SLEEPWALK_HOME/opened"
CLAUDE_BIN="$T/fake-claude-lost" wake
check "a session the wrap-up did not reach stays in the cloud" [ "$(rec sess-wk03 | jq -r .handoff.status)" = cloud ]

# No network when the lid opens: resume says so, and wake waits until the Mac is online.
rm -f "$SLEEPWALK_HOME/net-up" "$SLEEPWALK_HOME/opened"
out="$(NETWORK_WAIT=1 "$TOOL" resume sess-wk03 < /dev/null 2>&1)"; rc=$?
check "resume with no network stops with next steps" sh -c "[ $rc = 1 ] && printf '%s' \"\$1\" | grep -q 'Still no network' && printf '%s' \"\$1\" | grep -q 'resume sess-wk03'" _ "$out"
check "and leaves the session as it was" [ "$(rec sess-wk03 | jq -r .handoff.status)" = cloud ]
NETWORK_WAIT=1 wake &
wpid=$!
sleep 5
check "with no network, wake keeps waiting past NETWORK_WAIT" kill -0 "$wpid"
check "and says so in one notification" [ "$(grep -c 'notify: Cloud handoff: No network yet' "$SLEEPWALK_HOME/handoff.log")" = 1 ]
check "nothing opens while offline" [ -z "$(opened)" ]
touch "$SLEEPWALK_HOME/net-up"
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$wpid" 2>/dev/null || break; sleep 1; done
kill "$wpid" 2>/dev/null
check "once online, wake brings the session back" [ "$(opened)" = "resume-sess-wk03.command " ]
check "and tells the cloud session to wrap up" [ "$(rec sess-wk03 | jq -r .handoff.status)" = returning ]

# On a terminal: a window title and a status line rewritten in place.
out="$(WRAPUP_WAIT=2 script -q /dev/null "$TOOL" resume sess-wk03 < /dev/null 2>&1)"
check "on a terminal, resume titles the window after the repository" sh -c "printf '%s' \"\$1\" | grep -q \"\$(printf '\\033]0;Sleepwalk · wake3\\007')\"" _ "$out"
check "and clears the screen of Terminal's login banner" sh -c "printf '%s' \"\$1\" | grep -q \"\$(printf '\\033\\[2J')\"" _ "$out"
check "and rewrites one status line in place" sh -c "printf '%s' \"\$1\" | grep -q \"\$(printf '\\r\\033\\[K')Waiting for the cloud session to push\"" _ "$out"

export SLEEPWALK_HOME="$saved_home"
unset SLEEPWALK_NETWORK

# === state hygiene: pruning, leftover files, log rotation, traps, concurrent writes.
# Uses its own home, so it neither depends on nor disturbs the tests above.
H="$T/hygiene"; S="$H/sessions"
sw() { SLEEPWALK_HOME="$H" "$TOOL" "$@"; }
hhook() { # hhook <event> <session> [cwd] [transcript]
  jq -n --arg e "$1" --arg s "$2" --arg c "${3:-$T/repo}" --arg tp "${4:-$T/old.jsonl}" \
    '{session_id: $s, hook_event_name: $e, cwd: $c, transcript_path: $tp}' | sw hook
}
hset() { # hset <session> <jq filter>: edits a record by hand
  jq --argjson now "$(date +%s)" "$2" "$S/$1.json" > "$S/$1.edit" && mv "$S/$1.edit" "$S/$1.json"
}
hhas() { [ -f "$S/$1.json" ]; }
echo old > "$T/old.jsonl"
touch -t "$(date -v-30d +%Y%m%d%H%M.%S)" "$T/old.jsonl"
mkdir -p "$H"; : > "$H/last-prune"   # hold off the hourly prune until it is under test

# --- prune: resumed sessions go after RESUMED_KEEP_HOURS, quiet ones after PRUNE_DAYS.
for s in st-res-old st-res-new st-quiet st-live st-notp st-cloud-new st-cloud-old; do hhook SessionStart "$s"; done
hset st-res-old '.state = "busy" | .handoff = {status: "resumed", cloud_id: "x", at: ($now - 90000), resumed_at: ($now - 90000)}'
hset st-res-new '.state = "busy" | .handoff = {status: "resumed", cloud_id: "x", at: ($now - 3600), resumed_at: ($now - 3600)}'
hset st-quiet '.last_activity = ($now - 8 * 86400)'
hset st-notp ".last_activity = (\$now - 2 * 86400) | .transcript_path = \"$T/no-such.jsonl\""
hset st-cloud-new '.last_activity = ($now - 3 * 86400) | .handoff = {status: "cloud", cloud_id: "x", at: ($now - 3 * 86400)}'
hset st-cloud-old '.last_activity = ($now - 8 * 86400) | .handoff = {status: "returning", cloud_id: "x", at: ($now - 8 * 86400)}'
touch "$H/resume-st-res-old.command" "$H/resume-st-cloud-new.command"
out="$(sw prune)"
check "prune forgets a session teleported back over a day ago" sh -c "[ ! -f '$S/st-res-old.json' ] && [ ! -f '$H/resume-st-res-old.command' ]"
check "prune keeps one teleported back an hour ago" hhas st-res-new
check "prune forgets a session quiet for 8 days" [ ! -f "$S/st-quiet.json" ]
check "prune forgets a quiet session whose transcript is gone" [ ! -f "$S/st-notp.json" ]
check "prune keeps an active session" hhas st-live
check "prune keeps a recent cloud handoff and its .command" sh -c "[ -f '$S/st-cloud-new.json' ] && [ -f '$H/resume-st-cloud-new.command' ]"
check "prune forgets a handoff never resumed in 8 days" [ ! -f "$S/st-cloud-old.json" ]
check "prune says how many it forgot" [ "$out" = "Pruned 4 session record(s)." ]
check "prune logs each record it forgets" grep -q 'pruned st-res-old: teleported back' "$H/handoff.log"

# --- orphaned resume .command files go on release, SessionEnd, prune, and after a day.
touch "$H/resume-st-gone.command" "$H/resume-st-res-new.command"
touch -t "$(date -v-2d +%Y%m%d%H%M.%S)" "$H/resume-st-cloud-new.command"
sw prune >/dev/null
check "prune removes a .command with no record" [ ! -f "$H/resume-st-gone.command" ]
check "prune removes a .command for a session no longer in the cloud" [ ! -f "$H/resume-st-res-new.command" ]
check "prune removes a .command unused for a day" [ ! -f "$H/resume-st-cloud-new.command" ]
check "but keeps the cloud session's record" hhas st-cloud-new
touch "$H/resume-st-cloud-new.command"
sw release st-cloud-new >/dev/null
check "release removes the session's .command" [ ! -f "$H/resume-st-cloud-new.command" ]
touch "$H/resume-st-live.command"
hhook SessionEnd st-live
check "SessionEnd removes the session's .command" [ ! -f "$H/resume-st-live.command" ]

# --- prune clears files left by killed processes, but not fresh ones.
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$S/st-x.json.123.tmp"
mkdir "$S/st-x.json.lock"; touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$S/st-x.json.lock"
touch "$S/st-y.json.456.tmp"
sw prune >/dev/null
check "prune removes an old temporary record" [ ! -f "$S/st-x.json.123.tmp" ]
check "prune removes an old record lock" [ ! -d "$S/st-x.json.lock" ]
check "prune leaves a fresh temporary record" [ -f "$S/st-y.json.456.tmp" ]
rm -f "$S/st-y.json.456.tmp"

# --- the hourly prune runs from SessionStart, not from every tool call.
hhook SessionStart st-stale; hset st-stale '.last_activity = ($now - 8 * 86400)'
hhook PreToolUse st-other
touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$H/last-prune"
hhook PreToolUse st-other
check "PreToolUse does not prune" hhas st-stale
out="$(hhook SessionStart st-other)"
check "SessionStart prunes once the last prune is an hour old" [ ! -f "$S/st-stale.json" ]
check "and says nothing to Claude about it" [ -z "$out" ]
hhook SessionStart st-stale; hset st-stale '.last_activity = ($now - 8 * 86400)'
hhook SessionStart st-other
check "it prunes at most once an hour" hhas st-stale

# --- logs rotate past LOG_MAX_KB.
head -c 3000 /dev/zero | tr '\0' x > "$H/handoff.log"
head -c 3000 /dev/zero | tr '\0' x > "$H/sleepwatch.log"
LOG_MAX_KB=2 DEBUG=1 hhook Stop st-other
check "handoff.log moves to handoff.log.1 past the limit" sh -c "[ \$(wc -c < '$H/handoff.log.1') -ge 3000 ] && [ \$(wc -c < '$H/handoff.log') -lt 200 ]"
check "the new log carries on" grep -q 'hook Stop st-other' "$H/handoff.log"
LOG_MAX_KB=2 sw prune >/dev/null
check "prune rotates sleepwatch.log in place" sh -c "[ -f '$H/sleepwatch.log.1' ] && [ ! -s '$H/sleepwatch.log' ]"

# --- records survive bad input and concurrent writers.
printf '{"session_id": ' > "$S/st-bad.json"
: > "$S/st-empty.json"
hhook UserPromptSubmit st-bad; hhook UserPromptSubmit st-empty
check "an unreadable record starts afresh" [ "$(jq -r .state "$S/st-bad.json")" = busy ]
check "an empty record starts afresh" [ "$(jq -r .state "$S/st-empty.json")" = busy ]
check "no temporary records are left behind" [ -z "$(find "$S" -name '*.tmp' -o -name '*.lock')" ]
for i in 1 2 3 4 5 6 7 8; do
  SLEEPWALK_HOME="$H" bash -c '. "$1" help >/dev/null; update_rec st-conc --arg k "$2" ".[\$k] = 1"' _ "$TOOL" "k$i" &
done
wait
check "concurrent writes to one record all land" [ "$(jq 'keys | length' "$S/st-conc.json")" = 8 ]
hhook SessionEnd st-bad; hhook SessionEnd st-empty; rm -f "$S/st-conc.json"

# --- sleep skips sessions whose folder is gone instead of using its own folder.
hhook PreToolUse st-nocwd "$T/vanished"
hhook PreToolUse st-emptycwd; hset st-emptycwd '.cwd = ""'
n0="$(find "$H" -maxdepth 1 -name 'claude-args-*' | wc -l | tr -d ' ')"
( cd "$T/repo" && SLEEPWALK_LID=closed SLEEPWALK_HOME="$H" "$TOOL" sleep )
check "sleep skips a session whose folder is gone" grep -q 'skip st-nocwd: working directory .*vanished is gone' "$H/handoff.log"
check "and one with no folder at all" grep -q 'skip st-emptycwd: working directory (none) is gone' "$H/handoff.log"
check "neither starts a cloud session" [ "$(find "$H" -maxdepth 1 -name 'claude-args-*' | wc -l | tr -d ' ')" = "$n0" ]
hhook SessionEnd st-nocwd; hhook SessionEnd st-emptycwd

# --- traps: set once, never inside a function, and safe when the step is stopped.
check "no trap is set inside a function" sh -c "! grep -nE '^[[:space:]]+trap ' '$TOOL'"
err="$(SLEEPWALK_LID=open sw wake 2>&1)"
check "wake leaves no lock and no errors" sh -c "[ -z \"\$1\" ] && [ ! -d '$H/wake.lock' ]" _ "$err"
mkrepo hygrepo
hhook PreToolUse st-term "$T/hygrepo"
CLAUDE_BIN="$T/fake-claude-lost" SLEEP_BUDGET=15 SLEEPWALK_LID=closed SLEEPWALK_HOME="$H" "$TOOL" sleep 2> "$T/term.err" &
p=$!
sleep 3; kill -TERM "$p"; wait "$p" 2>/dev/null; sleep 1
check "a stopped sleep step reports no errors" [ ! -s "$T/term.err" ]
check "a stopped sleep step removes its temporary file" sh -c "! ls '$H' | grep -q sleep-candidates"
check "a stopped sleep step stops its handoffs" sh -c "! pgrep -f '$T/fake-claude-lost' >/dev/null"

echo
[ "$fails" = 0 ] && echo "all tests passed" || { echo "$fails failed"; exit 1; }
