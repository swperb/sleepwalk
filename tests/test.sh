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
git init -q --bare "$T/origin.git"
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
  git init -q --bare "$T/$1.git"
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
for s in sess-wk01:200 sess-wk02:100; do
  f="$SLEEPWALK_HOME/sessions/${s%:*}.json"
  jq --argjson at "${s#*:}" '.handoff.at = $at' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
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

echo
[ "$fails" = 0 ] && echo "all tests passed" || { echo "$fails failed"; exit 1; }
