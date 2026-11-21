#!/usr/bin/env python3
"""Exercise / folder ranking through a running isolated UmiNext's native history reader.

Run on mac-air-2: picker_history_test.py TEST_STATE_DIR
The app needs UMI_NEXT_DEBUG=1; UMI_NEXT_OFFSCREEN=1 is supported. Creates uniquely
named transcript fixtures and folders, then moves only those fixtures to the Trash.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import uuid

state = Path(sys.argv[1]).expanduser()
assert state.name.startswith('Umi-next-test-'), 'Use an isolated test app'


def ev(js):
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(str(state / 'debug.sock'))
        s.sendall(json.dumps({'cmd': 'eval', 'js': js}).encode() + b'\n')
        parts = []
        while data := s.recv(65536):
            parts.append(data)
    result = json.loads(b''.join(parts))
    assert not result.get('error'), result
    return result.get('result')


def js_json(js):
    return json.loads(ev(f'JSON.stringify({js})'))


def until(fn, description):
    deadline = time.time() + 30
    while time.time() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('Timed out: ' + description)


deadline = time.time() + 30
while True:
    try:
        if ev("typeof Umi !== 'undefined' && !!Umi.state.layout"):
            break
    except (OSError, AssertionError):
        pass
    if time.time() >= deadline:
        raise AssertionError('Test app did not become ready')
    time.sleep(.1)

home = Path.home()
root = Path(tempfile.mkdtemp(prefix='umi-picker-fixtures-', dir=home))
token = uuid.uuid4().hex[:10]
claude_dir = home / '.claude/projects' / ('umi-picker-test-' + token)
codex_dir = home / '.codex/sessions' / ('umi-picker-test-' + token)
folders = {name: root / name for name in ['zrank-a-unused', 'zrank-b-claude', 'zrank-c-codex', 'unrelated-project']}
for folder in folders.values():
    folder.mkdir()
claude_dir.mkdir(parents=True)
codex_dir.mkdir(parents=True)
for name in ['zrank-b-claude', 'unrelated-project']:
    sid = str(uuid.uuid4())
    (claude_dir / (sid + '.jsonl')).write_text(json.dumps({'type': 'user', 'sessionId': sid, 'cwd': str(folders[name]), 'message': {'content': 'fixture'}}) + '\n')
(codex_dir / ('rollout-' + token + '.jsonl')).write_text(json.dumps({'type': 'session_meta', 'payload': {'id': str(uuid.uuid4()), 'cwd': str(folders['zrank-c-codex'])}}) + '\n')

try:
    # Spy on the real response without changing the history reader or picker handler.
    ev("window.__historyResponse = null; window.__historyHandler = Umi.bridge.handlers.agentProjects; Umi.bridge.handlers.agentProjects = (msg) => { window.__historyResponse = msg.list; window.__historyHandler(msg); }; 1")
    ev(f"Umi.app.update(() => {{ window.__picker = Umi.model.split('row', 'picker', {{cwd: {json.dumps(str(folders['zrank-a-unused']))}}}); }}); 1")
    started = time.monotonic()
    ev("window.__pickerEl = document.querySelector('#panes .slot[data-pane=\"' + __picker.id + '\"]'); window.__input = __pickerEl.querySelector('.picker-name'); __input.dispatchEvent(new KeyboardEvent('keydown', {key:'/', bubbles:true, cancelable:true})); 1")
    history = until(lambda: js_json('window.__historyResponse'), 'native history response')
    assert str(folders['zrank-b-claude']) in history, history
    assert str(folders['zrank-c-codex']) in history, history
    print(f'ok native history includes Claude and Codex transcript folders ({time.monotonic() - started:.2f}s)')
    ev("window.__historyResponse = null; Umi.bridge.post({type:'agentProjects'}); 1")
    cached_at = time.monotonic()
    cached = until(lambda: js_json('window.__historyResponse'), 'cached native history response')
    assert cached == history
    print(f'ok repeated history request returns the same projects ({time.monotonic() - cached_at:.2f}s)')

    def query(value):
        ev(f"__input.value = {json.dumps(value)}; __input.dispatchEvent(new Event('input', {{bubbles:true}})); 1")

    def rows():
        return js_json("Array.from(__pickerEl.querySelectorAll('.picker-row b')).map(e => e.textContent)")

    query('zrank')
    result = until(lambda: (r if 'zrank-a-unused' in (r := rows()) and 'zrank-b-claude' in r and 'zrank-c-codex' in r else None), 'matching rows')
    assert result.index('zrank-b-claude') < result.index('zrank-a-unused'), result
    assert result.index('zrank-c-codex') < result.index('zrank-a-unused'), result
    assert 'unrelated-project' not in result, result
    print('ok rendered / search ranks both agent projects before unused matches and excludes nonmatches')
    query(str(root) + '/')
    result = until(lambda: (r if len(r := rows()) >= 5 else None), 'path rows')
    assert result[0] == 'This folder', result
    assert set(folders).issubset(result), result
    print('ok explicit path browsing retains This folder and child folders')
    query('zrank-b-claude')
    until(lambda: rows() and rows()[0] == 'zrank-b-claude', 'selected folder')
    ev("__input.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true, cancelable:true})); 1")
    assert js_json('__picker.cwd') == str(folders['zrank-b-claude'])
    assert js_json('__picker.picker.mode || null') is None
    print('ok Enter chooses the ranked folder and returns to session naming')
finally:
    try:
        ev("Umi.bridge.handlers.agentProjects = window.__historyHandler; Umi.app.update(() => Umi.model.removePane(__picker.id)); 1")
    finally:
        subprocess.run(['trash', str(claude_dir), str(codex_dir), str(root)], check=True)
