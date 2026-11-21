#!/usr/bin/env python3
"""Verify saved and modern Codex titles through native history and rendered picker rows.

Run only on mac-air-2 against an isolated debug app:
  picker_titles_test.py TEST_STATE_DIR [SCREENSHOT_PATH]
Creates uniquely named transcript/index fixtures, then removes only its own index
row and trashes its fixture folders. No model sessions are launched.
"""
import json,os,socket,time,uuid,tempfile,subprocess,sys
from pathlib import Path
state=Path(sys.argv[1]).expanduser()
assert state.name.startswith('Umi-next-test-'), 'Use an isolated test app'
def d(cmd):
 with socket.socket(socket.AF_UNIX) as s:
  s.connect(str(state/'debug.sock'));s.sendall(json.dumps(cmd).encode()+b'\n');buf=b''
  while c:=s.recv(65536):buf+=c
 return json.loads(buf)
def e(js):
 r=d({'cmd':'eval','js':js});assert not r.get('error'),r;return r['result']
def v(js):return json.loads(e('JSON.stringify('+js+')'))
def until(fn):
 for _ in range(200):
  try:
   if x:=fn(): return x
  except (OSError,AssertionError):pass
  time.sleep(.1)
 raise AssertionError('Timed out')
until(lambda:v("typeof Umi !== 'undefined' && !!Umi.state.layout"))
home=Path.home();root=Path(tempfile.mkdtemp(prefix='umi-title-fixture-',dir=home))
folder=home/'.codex/sessions'/('umi-title-fixture-'+uuid.uuid4().hex)
folder.mkdir(parents=True)
indexed=str(uuid.uuid4());prompt=str(uuid.uuid4())
index=home/'.codex/session_index.jsonl';was_present=index.exists()
line=json.dumps({'id':indexed,'thread_name':'Saved meaningful session name','updated_at':'2026-11-21T12:00:00Z'})+'\n'
def write_transcript(sid,records):
 p=folder/('rollout-test-'+sid+'.jsonl')
 p.write_text('\n'.join(json.dumps(x) for x in [{'type':'session_meta','payload':{'id':sid,'cwd':str(root)}}]+records)+'\n')
write_transcript(indexed,[{'type':'session_meta','payload':{'id':str(uuid.uuid4()),'cwd':str(root)}}])
write_transcript(prompt,[{'type':'response_item','payload':{'type':'message','role':'developer','content':[{'type':'input_text','text':'Preamble '*40000}]}},{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'# AGENTS.md instructions for this directory\nDo not use this as the session title.'},{'type':'input_text','text':'<environment_context>fixture</environment_context>'}]}},{'type':'response_item','payload':{'type':'message','role':'user','content':[{'type':'input_text','text':'Find the memory leak'}]}}])
# Existing JSONL is not replaced: append only a unique fixture row, preserving even a missing final newline.
original=index.read_bytes() if was_present else b''
separator='\n' if original and not original.endswith(b'\n') else ''
with index.open('a') as f:f.write(separator+line)
try:
 e(f"window.__titleReply=null; window.__titleHandler=Umi.bridge.handlers.pastSessions; Umi.bridge.handlers.pastSessions=m=>{{if(m.project==={json.dumps(str(root))}) window.__titleReply=m.list; __titleHandler(m);}}; Umi.app.update(()=>{{window.__titlePicker=Umi.model.split('row','picker',{{cwd:{json.dumps(str(root))}}});__titlePicker.picker.project={json.dumps(str(root))};}}); Umi.bridge.post({{type:'pastSessions',project:{json.dumps(str(root))}}}); 1")
 rows=until(lambda:v('window.__titleReply'))
 titles={r['id']:r['title'] for r in rows}
 assert titles[indexed]=='Saved meaningful session name',titles
 assert titles[prompt]=='Find the memory leak',titles
 rendered=until(lambda:v("[...document.querySelectorAll('.slot[data-pane=\"'+__titlePicker.id+'\"] .picker-row b')].map(e=>e.textContent)"))
 assert 'Saved meaningful session name' in rendered and 'Find the memory leak' in rendered,rendered
 assert not any(t.startswith('rollout-') for t in rendered),rendered
 print('PASS native history returns saved Codex name and modern user prompt after >256KB preamble; rendered list shows both without rollout filenames')
 if len(sys.argv)>2:subprocess.run(['screencapture','-x','-l',str(d({'cmd':'state'})['windowNumber']),sys.argv[2]],check=True)
finally:
 try:
  e('Umi.bridge.handlers.pastSessions=__titleHandler;if(window.__titlePicker)Umi.app.update(()=>Umi.model.removePane(__titlePicker.id));1')
 finally:
  # Remove only our UUID's exact row; retain any concurrent history/index writes.
  current=index.read_text();assert current.count(line)==1
  cleaned=current.replace(line,'',1)
  if not was_present and cleaned=='':subprocess.run(['trash',str(index)],check=True)
  else:
   if separator and cleaned==original.decode()+separator:cleaned=original.decode()
   tmp=index.with_name('umi-title-cleanup-'+uuid.uuid4().hex)
   tmp.write_text(cleaned);tmp.chmod(index.stat().st_mode & 0o777);os.replace(tmp,index)
  subprocess.run(['trash',str(root),str(folder)],check=True)
