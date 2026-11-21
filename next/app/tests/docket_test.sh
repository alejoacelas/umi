#!/bin/zsh
# Snooze-to-docket and task-link test; run under: lockf -k ~/umi-screen.lock zsh docket_test.sh
# Everything goes to /tmp/dock-test.log; a failed check also prints FAIL on stderr and exits 1.
exec 3>&2
exec > /tmp/dock-test.log 2>&1
set -x
source ~/umi-next-tools/d.sh  # this folder's docket_helpers.sh
ALLOW(){ for i in 1 2 3; do f=$(FRONT); [ "$f" = "UmiNext" ] || [ "$f" = "UserNotificationCenter" ] || [ "$f" = "universalAccessAuthWarn" ] || { echo "ALLOW skipped: frontmost $f"; continue; }; ~/umi-next-tools/click 778 367; sleep 1; done; }
H(){ osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $(MYPID)) to true" >/dev/null 2>&1; sleep 0.15; [ "$(FRONT)" = "UmiNext" ] || { echo "ABORT: hyper with $(FRONT) frontmost" >&2; pkill -f "umi-next-ui/next/app/build/UmiNext.app/Contents/MacOS/UmiNext$"; exit 9; }; ~/umi-next-tools/hyper $1; }
J(){ D eval "$1" | python3 -c "import json,sys;print(json.load(sys.stdin).get('result'))"; }
FAIL(){ echo "FAIL: $*"; echo "docket_test FAIL: $* (log: /tmp/dock-test.log)" >&3; screencapture -x /tmp/dock-fail.png; exit 1; }
# UNTIL JS WANT SECONDS: polls the page until JS gives WANT; false when it never does.
UNTIL(){ for _ in $(seq $3); do [ "$(J "$1")" = "$2" ] && return 0; sleep 1; done; return 1; }
DOCKET(){ J "(Umi.state.live['$1'] && Umi.state.live['$1'].docket || {}).state || 'none'"; }
cd ~/umi-next-ui && git checkout -q -- . && git fetch -q origin main && git checkout -q --detach origin/main && (cd next/app && ./build.sh --adhoc 2>&1 | grep -E "error|\.app$"); cd ~
pkill -f "umi-next-ui/next/app/build/UmiNext.app/Contents/MacOS/UmiNext$"; C daemon-stop --force; rm -f $UMI_NEXT_STATE_DIR/layout.json $UMI_NEXT_STATE_DIR/docket.json $UMI_NEXT_STATE_DIR/docket.log; rm -rf $UMI_NEXT_STATE_DIR/agents
rm -f /tmp/docket-hook-in-*.json(N); echo 0 > ~/.config/umi-next/hook-exit
# The task links' server: /tmp/umitask served at http://127.0.0.1:18765/ (one already running is used).
mkdir -p /tmp/umitask/umi
if ! curl -s -o /dev/null http://127.0.0.1:18765/; then
  python3 -m http.server 18765 --bind 127.0.0.1 --directory /tmp/umitask >/dev/null 2>&1 &
  SRV=$!; trap 'kill $SRV 2>/dev/null' EXIT; sleep 1
fi
open -n --env UMI_NEXT_DEBUG=1 --env UMI_NEXT_DEBUG_TASK_ORIGIN=http://127.0.0.1:18765/umi/ --env UMI_NEXT_CLAUDE_CMD=$HOME/umi-next-tools/claude-tok --env UMI_NEXT_STATE_DIR=$UMI_NEXT_STATE_DIR ~/umi-next-ui/next/app/build/UmiNext.app; sleep 4; 
K "keystroke \"cd ~/best/projects/2026-10-26-umi\""; K "key code 36"; sleep 1
K "keystroke \"d\" using command down"; sleep 1.5; K "keystroke \"dock1\""; K "key code 36"; sleep 3
DSID=$(J "Umi.model.sessionOf(Umi.model.activeTab().focused)"); echo "dock1 daemon session: $DSID"
for i in $(seq 40); do [ "$(J "Umi.state.live['$DSID'] && Umi.state.live['$DSID'].agent ? 'up' : 'no'")" = up ] && break; [ $((i % 4)) = 0 ] && [ "$(FRONT)" = UmiNext ] && ~/umi-next-tools/click 778 367; sleep 1; done
echo "claude up after ${i}s:"; C screen $DSID | grep -v '^ *$' | tail -3
[ "$(J "Umi.state.live['$DSID'] && Umi.state.live['$DSID'].agent ? 'up' : 'no'")" = up ] || { echo "ABORT: claude didn't start"; screencapture -x /tmp/dock-abort.png; exit 8; }
K "keystroke \"write a long original story of about 2500 words about a lighthouse keeper, no tools, then end with a last line: Status: done\""; K "key code 36"; sleep 8
echo "== streaming before docket:"; C screen $DSID | grep -v '^ *$' | tail -2
AGS=$(J "Umi.state.live['$DSID'].agent.agentSession"); echo "agent session: $AGS"
H d; sleep 1.5
echo "== after Hyper+D:"; SUM
J "JSON.stringify({pane: Umi.model.paneOfSession('$DSID')||null, docket: Umi.state.live['$DSID'].docket, review: Umi.model.review().map(g=>g.items.map(i=>i.id)), sidebarText: document.querySelector('#sidebar').innerText})"
DK=$(DOCKET $DSID); [[ $DK = (pending|running|on) ]] || FAIL "no docket mark on $DSID in the page after Hyper+D (state: $DK)"
python3 -c "import json,sys;sys.exit('$DSID' not in json.load(open('$UMI_NEXT_STATE_DIR/docket.json')))" || FAIL "$DSID not marked in docket.json after Hyper+D"
C ls | python3 -c "import json,sys;[print('  daemon:',s['id'],'alive',s['alive'],'clients',s['clients']) for s in json.load(sys.stdin) if s['id']=='$DSID']"
screencapture -x /tmp/dock1.png
for i in $(seq 90); do f=(/tmp/docket-hook-in-*.json(N)); (( $#f )) && break; sleep 2; done
echo "== hook got (after ~$((i*2)) s):"; f=(/tmp/docket-hook-in-*.json(N)); (( $#f )) || FAIL "the docket hook's input file /tmp/docket-hook-in-*.json never appeared"; cat $f </dev/null; echo
sleep 2; echo "== docket mark now:"; J "JSON.stringify(Umi.state.live['$DSID'].docket)"; tail -1 $UMI_NEXT_STATE_DIR/docket.log | cut -c1-300
K "keystroke \"d\" using command down"; sleep 2; echo "== picker:"; J "document.querySelector('.slot.picker .picker-list').innerText.replace(/\\n/g,' | ')"; screencapture -x /tmp/dock2.png
echo "== failing hook:"; echo 1 > ~/.config/umi-next/hook-exit
K "key code 48"; K "key code 48"; K "key code 36"; sleep 2; SSID=$(J "Umi.model.sessionOf(Umi.model.activeTab().focused)"); echo "shell session $SSID"
H d
UNTIL "(Umi.state.live['$SSID'] && Umi.state.live['$SSID'].docket || {}).state || 'none'" failed 15 || FAIL "no failed docket state on $SSID after the failing hook (state: $(DOCKET $SSID))"
J "JSON.stringify(Umi.state.live['$SSID'].docket)"
screencapture -x /tmp/dock3.png
echo 0 > ~/.config/umi-next/hook-exit
echo "== task link, live session:"
printf '{"folder":"projects/2026-10-26-umi","agent":"claude","session":"%s","next_session":"%s","title":"Dock test"}' $AGS $DSID > /tmp/umitask/umi/task1.json
curl -sf http://127.0.0.1:18765/umi/task1.json | grep -q "$DSID" || FAIL "http://127.0.0.1:18765/umi/task1.json doesn't serve /tmp/umitask/umi/task1.json"
open "umi-next://open?task=http%3A%2F%2F127.0.0.1%3A18765%2Fumi%2Ftask1.json"
UNTIL "Umi.model.sessionOf(Umi.model.activeTab().focused)" "$DSID" 10 || FAIL "after the task link the focused session is $(J "Umi.model.sessionOf(Umi.model.activeTab().focused)"), not $DSID"
J "JSON.stringify({tab: Umi.model.activeTab().name, focusedSession: Umi.model.sessionOf(Umi.model.activeTab().focused), docket: Umi.state.live['$DSID'].docket||null})"
sleep 1; D screen | grep -v '^ *$' | tail -3; screencapture -x /tmp/dock4.png
echo "== refused link:"; open "umi-next://open?task=https%3A%2F%2Fexample.com%2Fumi%2Fx.json"; sleep 2; screencapture -x /tmp/dock5.png
echo "== task link, dead session: Exit it first"
H tap; sleep 0.5; K "keystroke \"x\""; sleep 4
C ls | python3 -c "import json,sys;print('  alive:', [s['id'] for s in json.load(sys.stdin) if s['id']=='$DSID'])"
open "umi-next://open?task=http%3A%2F%2F127.0.0.1%3A18765%2Fumi%2Ftask1.json"; for i in 1 2 3 4 5; do sleep 3; [ "$(FRONT)" = UmiNext ] && ~/umi-next-tools/click 778 367; done; sleep 5
J "JSON.stringify({tab: Umi.model.activeTab().name, session: Umi.model.sessionOf(Umi.model.activeTab().focused), cwd: Umi.model.folderOf(Umi.model.activeTab().focused)})"
NS=$(J "Umi.model.sessionOf(Umi.model.activeTab().focused)"); C ls | python3 -c "import json,sys;[print('  new session:',s['id'],s['command'],s['cwd']) for s in json.load(sys.stdin) if s['id']=='$NS']"
D screen | grep -v '^ *$' | head -12; screencapture -x /tmp/dock6.png
echo DONE-DOCKET
