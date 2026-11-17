# helpers on mac-air-2
export UMI_NEXT_STATE_DIR=~/umi-next-ui-state
D(){ python3 ~/umi-next-ui/next/app/umi-next-ui-debug "$@"; }
# Keys only ever go to this UmiNext (my build, by pid; every UmiNext shares one bundle id).
MYPID(){ pgrep -f "umi-next-ui/next/app/build/UmiNext.app/Contents/MacOS/UmiNext$" | head -1; }
FRONTPID(){ osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true'; }
FRONT(){ [ "$(FRONTPID)" = "$(MYPID)" ] && echo UmiNext || echo other; }
K(){ osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $(MYPID)) to true" >/dev/null 2>&1; sleep 0.15; if [ "$(FRONT)" != "UmiNext" ]; then echo "ABORT: my UmiNext is not in front" >&2; exit 9; fi; osascript -e "tell application \"System Events\" to $1"; sleep 0.4; }
WIN(){ D state | python3 -c "import json,sys;print(json.load(sys.stdin)['windowNumber'])"; }
SHOT(){ screencapture -x -l$(WIN) /tmp/$1.png; }
SUM(){ D state | python3 -c "
import json,sys; s=json.load(sys.stdin)
print('active', s['layout']['activeTab'], 'focused', s['focusedPane'], 'pending', s['pendingPanes'], 'mismatches', s['mismatches'])
for p in s['panes']: print(' ', p['id'], 'visible' if p['visible'] else 'hidden ', 'frame', [p['frame'][k] for k in 'xywh'], 'slot', [p['webRect'][k] for k in 'xywh'] if 'webRect' in p else None, 'grid', p['grid'], 'FR' if p['firstResponder'] else '')
"; }
# global click at window content point
CL(){ ~/umi-next-tools/click $(D state | python3 -c "import json,sys;o=json.load(sys.stdin)['contentOriginGlobal'];print(o['x']+$1, o['y']+$2)"); sleep 0.4; }
C(){ ~/umi-next-ui/next/app/build/UmiNext.app/Contents/MacOS/umi-next-ctl "$@"; }
