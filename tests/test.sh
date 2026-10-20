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
printf '\n' | WRAPUP_WAIT=3 "$TOOL" resume sess-aaaa >/dev/null
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

echo
[ "$fails" = 0 ] && echo "all tests passed" || { echo "$fails failed"; exit 1; }
