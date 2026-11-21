#!/usr/bin/env python3
"""Check picker agent icons and controls in an isolated UmiNext debug app on mac-air-2.

  picker_icons_test.py TEST_STATE_DIR [SCREENSHOT_PATH]
Uses fixture sessions and intercepts launches: no model calls or login needed.
"""
import json
import os
import shlex
import tempfile
from pathlib import Path
import socket
import subprocess
import sys
import time

state = Path(sys.argv[1]).expanduser()
assert state.name.startswith('Umi-next-test-'), 'Use an isolated test app'


def request(cmd):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(str(state / 'debug.sock'))
        sock.sendall(json.dumps(cmd).encode() + b'\n')
        data = b''
        while chunk := sock.recv(65536):
            data += chunk
    result = json.loads(data)
    assert not result.get('error'), result
    return result


def ev(js):
    return request({'cmd': 'eval', 'js': js}).get('result')


def value(js):
    return json.loads(ev('JSON.stringify(' + js + ')'))


def until(fn, description):
    until_time = time.monotonic() + 20
    while time.monotonic() < until_time:
        try:
            if result := fn():
                return result
        except (OSError, AssertionError):
            pass
        time.sleep(.1)
    raise AssertionError(description)


until(lambda: value("typeof Umi !== 'undefined' && !!Umi.state.layout && !!Umi.views.picker"), 'picker did not load')
ev("window.__iconSaved = {sessions:Umi.bridge.handlers.sessions, past:Umi.bridge.handlers.pastSessions, live:Umi.state.live, oldPast:Umi.state.past, start:Umi.model.startSession, commands:Umi.state.commands}; Umi.bridge.handlers.sessions = () => {}; Umi.bridge.handlers.pastSessions = () => {}; Umi.app.update(() => {window.__iconPicker = Umi.model.split('row','picker');}); 1")
try:
    ev("window.__iconEl = document.querySelector('.slot[data-pane=\"'+__iconPicker.id+'\"]'); window.__iconInput = __iconEl.querySelector('.picker-name'); __iconPicker.picker.project = '/icon-test-project'; Umi.state.live = Object.fromEntries(['claude','codex','antigravity','shell'].map(kind => [kind,{id:kind,kind,name:kind+' fixture',project:'/icon-test-project',folder:'/icon-test-project',alive:true,state:'waiting'}])); Umi.state.past = {'/icon-test-project':['claude','codex'].map(kind=>({kind,id:kind+'-past',title:kind+' past fixture',mtime:Date.now()/1000,cwd:'/icon-test-project'}))}; Umi.views.picker.refresh(__iconEl,__iconPicker); 1")
    kinds = ['claude', 'codex', 'antigravity', 'shell']
    labels = ['Claude Code', 'Codex', 'Antigravity', 'Shell']
    assert value("[...__iconEl.querySelectorAll('[data-session]')].map(e=>e.querySelector('b').textContent).sort()") == sorted(k + ' fixture' for k in kinds)
    for kind, label in zip(kinds, labels):
        assert value(f"__iconEl.querySelector('[data-session={kind}] .agent-icon').getAttribute('aria-label')") == label
        assert value(f"__iconEl.querySelector('[data-session={kind}] .agent-icon').getBoundingClientRect().width > 0")
    assert value("__iconEl.querySelector('.picker-kinds [aria-pressed=true] .agent-icon').getAttribute('aria-label')") == 'Claude Code'
    ev("__iconEl.querySelector('[data-page=history]').click(); 1")
    assert value("[...__iconEl.querySelectorAll('[data-past] .agent-icon')].map(e=>e.getAttribute('aria-label'))") == labels[:2]
    ev("__iconEl.querySelector('[data-page=switcher]').click(); __iconEl.querySelector('[data-page=new]').click(); 1")
    assert value("[...__iconEl.querySelectorAll('.picker-kinds [data-kind]')].map(e=>e.dataset.kind)") == kinds
    until(lambda: value("[...__iconEl.querySelectorAll('img')].every(i=>i.complete && i.naturalWidth>0)"), 'brand images failed to load')
    print('ok live rows and launch choices show their agent icons; History and New retain accessible icons')

    for kind, label in zip(kinds, labels):
        ev(f"__iconEl.querySelector('[data-kind={kind}]').click(); 1")
        assert value('__iconPicker.picker.kind') == kind
        assert value("__iconEl.querySelector('.picker-row .agent-icon').getAttribute('aria-label')") == label
        assert value("document.activeElement === __iconInput")
        assert value("__iconEl.querySelector('[aria-pressed=true]').dataset.kind") == kind
    print('ok every kind button updates selected state, new-session icon and input focus')

    for shift, expected in [(False, kinds), (True, ['shell', 'antigravity', 'codex', 'claude'])]:
        ev("__iconPicker.picker.kind = 'shell'; Umi.views.picker.refresh(__iconEl,__iconPicker); 1" if not shift else "__iconPicker.picker.kind = 'claude'; Umi.views.picker.refresh(__iconEl,__iconPicker); 1")
        for kind in expected:
            ev(f"__iconInput.dispatchEvent(new KeyboardEvent('keydown',{{key:'Tab',shiftKey:{str(shift).lower()},bubbles:true,cancelable:true}})); 1")
            assert value('__iconPicker.picker.kind') == kind
    print('ok Tab and Shift+Tab cycle all four kinds in both directions')

    ev("window.__iconLaunches=[]; Umi.state.commands={...Umi.state.commands,antigravity:'agy --dangerously-skip-permissions'}; Umi.model.startSession=(id,options)=>__iconLaunches.push(options); __iconEl.querySelector('[data-kind=antigravity]').click(); __iconInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true})); 1")
    assert value('__iconLaunches[0].cmd') == 'agy --dangerously-skip-permissions'
    print('ok Enter invokes the selected agent launch path without starting a real model')

    ev("window.__iconEl=document.querySelector('.slot[data-pane=\"'+__iconPicker.id+'\"]'); window.__iconInput=__iconEl.querySelector('.picker-name'); 1")
    for width in [1200, 900]:
        request({'cmd': 'resize', 'w': width, 'h': 760})
        time.sleep(.25)
        bounds = value("(() => {const p=__iconEl.getBoundingClientRect();return [...__iconEl.querySelectorAll('.picker-head input,.picker-kinds button')].map(e=>{const r=e.getBoundingClientRect();return {label:e.textContent,left:r.left,right:r.right,pLeft:p.left,pRight:p.right,width:r.width}});})()")
        assert all(b['width'] > 0 and b['left'] >= b['pLeft'] and b['right'] <= b['pRight'] + 1 for b in bounds), bounds
    print('ok controls stay inside narrow split pane at 900px window width')
    if len(sys.argv) > 2:
        subprocess.run(['screencapture', '-x', '-l', str(request({'cmd':'state'})['windowNumber']), sys.argv[2]], check=True)
        print('saved screenshot', sys.argv[2])
finally:
    ev("Umi.bridge.handlers.sessions=__iconSaved.sessions; Umi.bridge.handlers.pastSessions=__iconSaved.past; Umi.state.live=__iconSaved.live; Umi.state.past=__iconSaved.oldPast; Umi.model.startSession=__iconSaved.start; Umi.state.commands=__iconSaved.commands; Umi.app.update(()=>Umi.model.removePane(__iconPicker.id)); 1")

# A real daemon process named agy must reach the picker as Antigravity, without hooks.

fixture = Path(tempfile.mkdtemp(prefix='umi-icon-agent-', dir=Path.home()))
agent = fixture / 'agy'
agent.write_text('#!/bin/sh\nexec /bin/sleep 60\n')
agent.chmod(0o755)
app_path = Path(subprocess.check_output(['ps', '-p', str(request({'cmd': 'state'})['pid']), '-o', 'comm='], text=True).strip())
ctl = app_path.with_name('umi-next-ctl')
env = dict(os.environ, UMI_NEXT_STATE_DIR=str(state))
sid = None
try:
    assert value('Umi.state.commands.antigravity') == 'agy --dangerously-skip-permissions'
    sid = subprocess.check_output([str(ctl), 'new', '--cmd', shlex.quote(str(agent)), '--cwd', str(fixture), '--by', 'user', '--name', 'Antigravity native fixture'], env=env, text=True).strip()
    until(lambda: value(f"Umi.state.live[{json.dumps(sid)}]?.kind === 'antigravity'"), 'native agy kind missing')
    ev(f"Umi.app.update(() => {{ window.__nativePicker=Umi.model.split('row','picker',{{cwd:{json.dumps(str(fixture))}}}); __nativePicker.picker.project={json.dumps(str(fixture))}; }}); 1")
    until(lambda: value(f"[...document.querySelectorAll('.slot[data-pane=\"'+__nativePicker.id+'\"] .picker-row')].some(r=>r.querySelector('b')?.textContent==='Antigravity native fixture' && r.dataset.session==={json.dumps(sid)} && r.querySelector('.agent-icon')?.getAttribute('aria-label')==='Antigravity')"), 'native session row missing')
    print('ok real agy daemon session is identified as Antigravity and appears in the switcher; native launcher command is configured')
finally:
    if sid:
        subprocess.run([str(ctl), 'rm', sid, '--force'], env=env, check=True, capture_output=True)
    ev("if(window.__nativePicker) Umi.app.update(()=>Umi.model.removePane(__nativePicker.id)); 1")
    subprocess.run(['trash', str(fixture)], check=True)
