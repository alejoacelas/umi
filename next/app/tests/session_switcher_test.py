#!/usr/bin/env python3
"""Exercise the session switcher with real macOS keys and clicks on mac-air-2.

lockf -k ~/umi-screen.lock python3 session_switcher_test.py UmiNext.app KEY_AND_CLICK_DIR [SCREENSHOT]
The app, daemon, shell sessions and web layer belong to the isolated run.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from debugsock import Debug, poll
from front import bring_to_front


def run(state, bundle, tools, screenshot):
    web = Path(__file__).resolve().parents[1] / 'web'
    bins = bundle / 'Contents/MacOS'
    env = dict(os.environ, UMI_NEXT_STATE_DIR=str(state), UMI_NEXT_WEB_DIR=str(web), UMI_NEXT_DEBUG='1')
    dbg = Debug(state, timeout=5, show_js=True)
    J, ev = dbg.J, dbg.ev
    log = (state / 'app.log').open('w')
    process = subprocess.Popen([str(bins / 'UmiNext')], env=env, stdout=log, stderr=log)

    def until(expr, description):
        return poll(lambda: J(f"Boolean({expr})"), 12, what=description)

    def in_front():
        assert dbg({'cmd': 'state'})['active'], 'test app lost keyboard focus'

    def key(code, *mods):
        in_front()
        subprocess.run([str(tools / 'key'), str(code), *mods], check=True)
        time.sleep(.12)

    def click(selector):
        pos = J(f"""(() => {{
          const el = document.querySelector('.slot.picker')?.querySelector({json.dumps(selector)});
          if (!el) return null;
          el.scrollIntoView({{block:'nearest'}});
          const r = el.getBoundingClientRect();
          return r.width && r.height && [r.x + r.width / 2, r.y + r.height / 2];
        }})()""")
        assert pos, selector
        in_front()
        origin = dbg({'cmd': 'state'})['contentOriginGlobal']
        subprocess.run([str(tools / 'click'), str(origin['x'] + pos[0]), str(origin['y'] + pos[1])], check=True)
        time.sleep(.15)

    def type_text(text):
        assert dbg({'cmd': 'keys', 'text': text})['ok']
        time.sleep(.12)

    def session(name, folder, event=None):
        cwd = state / folder
        cwd.mkdir(exist_ok=True)
        sid = subprocess.check_output([str(bins / 'umi-next-ctl'), 'new', '--by', 'user',
                                       '--name', name, '--cwd', str(cwd)], env=env, text=True).strip()
        if event:
            hook(sid, event)
        return sid

    def hook(sid, event):
        subprocess.run([str(bundle / 'Contents/Resources/umi-next-hook'), 'hook', event, '--agent', 'codex'],
                       input='{}', text=True, env={**env, 'UMI_NEXT_SESSION_ID': sid}, check=True)

    def split():
        key(2, 'cmd')
        until("document.activeElement?.matches('.slot.picker .picker-name')", 'focused switcher input')

    def mode():
        return J("Umi.model.focusedPane()?.picker?.mode || 'switcher'")

    def has_row(sid):
        return f"!!document.querySelector('.slot.picker [data-session=\"{sid}\"]')"

    def row(sid):
        return f'.picker-row[data-session="{sid}"]'

    try:
        poll(lambda: dbg({'cmd': 'state'}).get('webReady'), 30, swallow=(OSError,), what='ready test app')
        assert bring_to_front(dbg)
        original = J('Umi.model.activeTab().focused')
        waiting = session('Check the invoice', 'Accounts', 'PermissionRequest')
        running = session('Refresh charts', 'Forecast', 'UserPromptSubmit')
        sleeping = session('Review draft', 'Planning', 'UserPromptSubmit')
        snooze_ends = session('Review handoff', 'Design', 'UserPromptSubmit')
        idle = session('Shell', 'Notes')
        until(f"Umi.state.live[{json.dumps(idle)}]?.alive", 'daemon sessions in the app')
        ev(f"""Umi.app.update(() => {{
          const M = Umi.model, sid = {json.dumps(waiting)};
          const tab = M.addTab(M.newPane({{session:sid, attach:sid, cwd:Umi.state.live[sid].folder}}));
          window.switcherOpenPane = tab.focused;
          M.snooze({json.dumps(sleeping)}, 3600);
          M.snooze({json.dumps(snooze_ends)}, null);
          M.focusPane({json.dumps(original)});
        }}); 1""")
        split()
        until(has_row(waiting), 'waiting row')
        assert not J(has_row(sleeping))
        assert not J(has_row(snooze_ends))
        assert not J("Boolean(document.querySelector('.slot.picker [data-kind]')?.getClientRects().length)")
        labels = J("""(() => {
          const groups = {};
          let group;
          for (const el of document.querySelectorAll('.slot.picker .picker-section, .slot.picker .picker-row')) {
            if (el.dataset.group) group = el.dataset.group;
            if (el.dataset.session) groups[el.dataset.session] =
              [group, el.querySelector('b')?.textContent, el.querySelector('.dim')?.textContent];
          }
          return groups;
        })()""")
        assert labels[waiting] == ['needs', 'Check the invoice', 'Accounts'], labels
        assert labels[running] == ['busy', 'Refresh charts', 'Forecast'], labels
        assert labels[idle] == ['available', 'Shell', 'Notes'], labels
        print('ok cross-project waiting, running and idle shells have the correct headings, names and projects')

        dbg({'cmd': 'resize', 'w': 760, 'h': 630})
        time.sleep(.3)
        assert J("""(() => {
          const slot = document.querySelector('.slot.picker'), r = slot.getBoundingClientRect();
          const controls = [...slot.querySelectorAll('button,input,.picker-row')].filter(el => el.offsetWidth);
          return controls.length > 3 && controls.every(el => {
            const b = el.getBoundingClientRect(); return b.left >= r.left-1 && b.right <= r.right+1;
          });
        })()"""), 'controls overflow the narrow picker'
        if screenshot:
            subprocess.run(['screencapture', '-x', '-l', str(dbg({'cmd': 'state'})['windowNumber']),
                            str(screenshot)], check=True)
        click('[data-action=snoozed]')
        until(has_row(sleeping), 'expanded snoozed rows')
        click('[data-action=snoozed]')
        assert not J(has_row(sleeping))
        key(126)  # Up from the snooze disclosure selects a session.
        chosen = J("document.querySelector('.slot.picker .picker-row.sel')?.dataset.session")
        assert chosen
        hook(snooze_ends, 'Stop')
        until(has_row(snooze_ends), 'ended snooze reappears without interaction')
        assert J(f"""(() => {{
          const list = [...document.querySelectorAll('.slot.picker .picker-section,.slot.picker .picker-row')];
          return list.slice(0,list.findIndex(e => e.dataset.session === '{snooze_ends}')).reverse()
            .find(e => e.dataset.group)?.dataset.group === 'needs';
        }})()"""), 'completed snooze should be under Needs you'
        assert J("document.querySelector('.slot.picker .picker-row.sel')?.dataset.session") == chosen
        ev(f"Umi.app.update(() => Umi.model.snooze('{idle}', 1)); 1")
        assert not J(has_row(idle))
        until(f"document.querySelector('.slot.picker {row(idle)}')?.dataset.group === 'needs'",
              'timer wakes the snoozed shell')
        print('ok a finished turn and an elapsed timer both return snoozes to Needs you')

        type_text('planning')
        until(has_row(sleeping), 'project search includes a collapsed snooze')
        assert not J(has_row(waiting))
        key(36)
        until(f"Umi.model.sessionOf(Umi.model.activeTab().focused) === '{sleeping}'", 'returned to snoozed session')
        focused = J('Umi.model.activeTab().focused')
        until(f"Umi.state.panes['{focused}']?.session === '{sleeping}'", 'native attached original session')
        assert J(f"""(() => {{
          const slots=Umi.views.panes.slotRects(), r=slots['{focused}'];
          return !Umi.state.layout.meta.sessions['{sleeping}'].snooze && !!slots['{original}'] &&
            Object.entries(slots).every(([id,b]) => id==='{focused}' || b.x+b.w<=r.x+1);
        }})()""")
        print('ok project search finds a snooze; Enter restores its daemon session in the far-right slot')

        split()
        before_switch = J('Umi.model.activeTab().focused')
        type_text('invoice')
        until(has_row(waiting), 'name search locates the open session')
        click(row(waiting))
        until("Umi.model.activeTab().focused === window.switcherOpenPane", 'existing tab and pane focused')
        assert not J(f"!!Umi.model.findPane('{before_switch}')")
        assert J(f"Umi.state.panes[window.switcherOpenPane].session === '{waiting}'")
        assert J(f"!!Umi.model.findPane('{original}')")
        print('ok clicking an open session jumps to its original pane and removes the temporary picker')

        split()
        key(48)  # Tab from Search to + New
        key(36)
        assert mode() == 'new', mode()
        key(53)  # Escape
        assert mode() == 'switcher', mode()
        click('[data-page=history]')
        assert mode() == 'history', mode()
        click('[data-page=switcher]')
        assert mode() == 'switcher', mode()
        key(123, 'opt', 'cmd')  # Focus the terminal to the left, then click New once.
        until("Umi.model.focusedPane().view === 'terminal'", 'sibling terminal takes keyboard focus')
        click('[data-page=new]')
        assert mode() == 'new', 'first click in unfocused picker must open New'
        click('[data-kind=shell]')
        type_text('Test shell')
        key(36)
        until("Umi.model.focusedPane()?.view === 'terminal' && !!Umi.state.panes[Umi.model.activeTab().focused]?.session",
              'shell launched from New')
        sid = J('Umi.model.sessionOf(Umi.model.activeTab().focused)')
        until(f"Umi.state.live['{sid}']?.name === 'Test shell'", 'named shell in daemon')
        print('ok keyboard and mouse enter New and History, return to the switcher and start the named shell')
        assert not dbg({'cmd': 'state'})['webErrors']
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        subprocess.run([str(bins / 'umi-next-ctl'), 'daemon-stop', '--force'], env=env, capture_output=True)
        log.close()


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='umi-switcher-', dir='/tmp') as tmp:
        run(Path(tmp), Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(),
            Path(sys.argv[3]) if len(sys.argv) > 3 else None)
