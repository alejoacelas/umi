"""Codex app-server probes. Usage: python3 probe_x.py X1|X2accept|X2decline|X3|X4|X4q|X5|X6|X7"""
import json
import os
import sys
import time
import uuid

from probelib import Codex, WORK


def item_started(kind):
    return lambda m: (m.get("method") == "item/started" and "id" not in m
                      and m["params"]["item"]["type"] == kind)


def turn_completed(m):
    return m.get("method") == "turn/completed" and "id" not in m


def is_server_req(m):
    return "id" in m and "method" in m


def new_thread(c, **kw):
    r = c.thread_start(**kw)
    tid = r["result"]["thread"]["id"]
    print("THREAD", tid, flush=True)
    return tid


def X1():
    c = Codex("X1")
    c.init()
    tid = new_thread(c)
    rid, cm = c.turn_start(tid, "Run `sleep 20; echo finished` in the shell, then reply with its output only.")
    i, resp = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
    turn_id = resp["result"]["turn"]["id"]
    c.wait_for(item_started("commandExecution"), 60)
    time.sleep(3)
    n = c.n()
    r = c.call("turn/interrupt", {"threadId": tid, "turnId": turn_id})
    print("INTERRUPT RESP", r)
    c.wait_for(turn_completed, 30, start=n)
    print("---- immediately new turn")
    n = c.n()
    rid2, cm2 = c.turn_start(tid, "Reply with just the word banana.")
    c.wait_for(turn_completed, 60, start=n)
    time.sleep(1)
    print("---- interrupt with no active turn / stale turn id")
    print(c.call("turn/interrupt", {"threadId": tid, "turnId": turn_id}))
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X2(decision):
    c = Codex("X2" + decision)
    c.init()
    tid = new_thread(c, approvalPolicy="untrusted", sandbox="read-only")
    fname = "y_%s.txt" % decision
    rid, cm = c.turn_start(tid, "Run exactly this shell command: `echo hi > %s` and then reply done." % fname)
    i, req = c.wait_for(is_server_req, 90)
    print("SERVER REQUEST FULL:", json.dumps(req, indent=1), flush=True)
    time.sleep(3)
    n = c.n()
    c.respond(req["id"], {"decision": decision})
    # answer any further approval requests the same way
    end = time.time() + 90
    seen = set([req["id"]])
    while time.time() < end:
        i, m = c.wait_for(lambda m: turn_completed(m) or (is_server_req(m) and m["id"] not in seen), 90, start=n)
        if m is None or turn_completed(m):
            break
        seen.add(m["id"])
        print("ANOTHER SERVER REQ", json.dumps(m)[:800], flush=True)
        c.respond(m["id"], {"decision": decision})
        n = i + 1
    time.sleep(1)
    print("FILE EXISTS", os.path.exists(os.path.join(WORK, fname)))
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X3():
    c = Codex("X3")
    c.init()
    tid = new_thread(c, approvalPolicy="untrusted", sandbox="read-only")
    rid, cm = c.turn_start(tid, "Run exactly this shell command: `echo hi > y_int.txt` and then reply done.")
    i, resp = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
    turn_id = resp["result"]["turn"]["id"]
    i, req = c.wait_for(is_server_req, 90)
    time.sleep(2)
    n = c.n()
    print("INTERRUPT RESP", c.call("turn/interrupt", {"threadId": tid, "turnId": turn_id}))
    c.wait_for(turn_completed, 30, start=n)
    time.sleep(2)
    print("---- late approval response")
    c.respond(req["id"], {"decision": "accept"})
    time.sleep(3)
    print("FILE EXISTS", os.path.exists(os.path.join(WORK, "y_int.txt")))
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X4():
    """Steer timing: turn/start right after final agentMessage completes, before turn/completed."""
    c = Codex("X4")
    c.init()
    tid = new_thread(c)
    for attempt in range(2):
        n = c.n()
        rid, cm = c.turn_start(tid, "Reply with just the word apple%d." % attempt)
        i, resp = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
        turn_id = resp["result"]["turn"]["id"]
        # wait for the final agent message, then immediately send another turn/start
        c.wait_for(lambda m: m.get("method") == "item/completed"
                   and m["params"]["item"]["type"] == "agentMessage", 60, start=n)
        rid2, cm2 = c.turn_start(tid, "Now reply with just the word pear%d." % attempt)
        i2, resp2 = c.wait_for(lambda m: m.get("id") == rid2 and "method" not in m)
        print("STEER-LATE RESP", json.dumps(resp2)[:400], "first turn", turn_id, flush=True)
        # wait until both turns done
        time.sleep(12)
    print("---- turn/steer with stale expectedTurnId")
    print(c.call("turn/steer", {"threadId": tid, "expectedTurnId": turn_id, "clientUserMessageId": str(uuid.uuid4()),
                                "input": [{"type": "text", "text": "x", "text_elements": []}]}))
    print("---- turns list")
    r = c.call("thread/turns/list", {"threadId": tid})
    for t in r.get("result", {}).get("data", []):
        print("TURN", t["id"], t["status"], [(it["type"], it.get("clientId"), it.get("text", "")[:40], it.get("phase")) for it in t["items"]])
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X4q():
    """Experimental queue API."""
    c = Codex("X4q")
    c.init()
    tid = new_thread(c)
    print("LIST EMPTY", c.call("thread/queue/list", {"threadId": tid}))
    rid, cm = c.turn_start(tid, "Run `sleep 6; echo finished` in the shell, then reply with its output only.")
    c.wait_for(item_started("commandExecution"), 60)
    qcm = str(uuid.uuid4())
    r = c.call("thread/queue/add", {"threadId": tid, "clientUserMessageId": qcm,
                                    "input": [{"type": "text", "text": "Reply with just the word queued.", "text_elements": []}]})
    print("QUEUE ADD", r)
    print("LIST", c.call("thread/queue/list", {"threadId": tid}))
    # see if it auto-starts when turn completes
    c.wait_for(turn_completed, 60)
    time.sleep(10)
    print("LIST AFTER", c.call("thread/queue/list", {"threadId": tid}))
    # add while idle, then start explicitly
    qcm2 = str(uuid.uuid4())
    r = c.call("thread/queue/add", {"threadId": tid, "clientUserMessageId": qcm2,
                                    "input": [{"type": "text", "text": "Reply with just the word idlequeued.", "text_elements": []}]})
    print("QUEUE ADD IDLE", r)
    time.sleep(5)
    print("LIST IDLE", c.call("thread/queue/list", {"threadId": tid}))
    print("QUEUE START", c.call("thread/queue/start", {"threadId": tid}))
    time.sleep(10)
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X5():
    a = Codex("X5a")
    a.init()
    tid = new_thread(a)
    rid, cm = a.turn_start(tid, "Run `sleep 15; echo finished` in the shell, then reply with its output only.")
    a.wait_for(item_started("commandExecution"), 60)
    b = Codex("X5b")
    b.init()
    r = b.call("thread/resume", {"threadId": tid, "excludeTurns": True})
    print("B RESUME", json.dumps(r)[:1500], flush=True)
    time.sleep(2)
    rid, cm = b.turn_start(tid, "Also say kiwi.")
    time.sleep(25)
    for p in (a, b):
        p.close_stdin()
        print("EXIT", p.name, p.wait_exit(15))


def X6():
    c = Codex("X6")
    c.init()
    tid = new_thread(c)
    rid, cm = c.turn_start(tid, "Run `sleep 10; echo finished` in the shell, then reply with its output only.")
    c.wait_for(item_started("commandExecution"), 60)
    time.sleep(1)
    t0 = time.time()
    c.close_stdin()
    rc = c.wait_exit(30)
    print("EXIT", rc, "after %.2fs" % (time.time() - t0))


def X7():
    c = Codex("X7")
    c.init()
    print("RESUME BAD UUID", c.call("thread/resume", {"threadId": str(uuid.uuid4())}))
    print("RESUME NON-UUID", c.call("thread/resume", {"threadId": "nope"}))
    print("START BAD MODEL", c.call("thread/start", {"model": "no-such-model-xyz", "cwd": WORK}))
    tid = new_thread(c)
    n = c.n()
    rid, cm = c.turn_start(tid, "Reply with hi.", model="no-such-model-xyz")
    c.wait_for(turn_completed, 60, start=n)
    time.sleep(1)
    print("TURN ON UNKNOWN THREAD", c.call("turn/start", {"threadId": str(uuid.uuid4()), "input": [{"type": "text", "text": "x", "text_elements": []}]}))
    print("INTERRUPT UNKNOWN THREAD", c.call("turn/interrupt", {"threadId": str(uuid.uuid4()), "turnId": "t"}))
    print("UNKNOWN METHOD", c.call("no/such/method", {}))
    c.write_raw("this is not json")
    time.sleep(1)
    c.close_stdin()
    print("EXIT", c.wait_exit(15))


def X8():
    c = Codex("X8")
    c.init()
    tid = new_thread(c)
    rid, cm = c.turn_start(tid, "First tell me in one short sentence what you are about to do, then run `ls` in the shell, then answer with the number of entries.")
    c.wait_for(turn_completed, 90)
    c.close_stdin()
    print("EXIT", c.wait_exit(15))




def X5c():
    """writer lock while idle; unsubscribe; resume after owner exits; resume of X6's abandoned thread"""
    a = Codex("X5c_a")
    a.init()
    tid = new_thread(a)
    rid, cm = a.turn_start(tid, "Remember the codeword MANGO. Reply with just ok.")
    a.wait_for(turn_completed, 60)
    b = Codex("X5c_b")
    b.init()
    print("B RESUME WHILE A IDLE", json.dumps(b.call("thread/resume", {"threadId": tid, "excludeTurns": True}))[:400], flush=True)
    print("A UNSUBSCRIBE", a.call("thread/unsubscribe", {"threadId": tid}), flush=True)
    time.sleep(1)
    r = b.call("thread/resume", {"threadId": tid, "excludeTurns": True})
    print("B RESUME AFTER UNSUBSCRIBE", json.dumps(r)[:600], flush=True)
    a.close_stdin(); print("A EXIT", a.wait_exit(15))
    if "error" in r:
        r = b.call("thread/resume", {"threadId": tid, "excludeTurns": True})
        print("B RESUME AFTER A EXIT", json.dumps(r)[:600], flush=True)
    n = b.n()
    b.turn_start(tid, "What was the codeword? One word.")
    b.wait_for(turn_completed, 60, start=n)
    # X6's abandoned thread
    x6 = None
    for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "logs", "X6.jsonl")):
        e = json.loads(l)
        if e["k"] == "out" and isinstance(e["m"], dict) and e["m"].get("id") == 2:
            x6 = e["m"]["result"]["thread"]["id"]
    r = b.call("thread/resume", {"threadId": x6})
    print("RESUME X6 THREAD", json.dumps(r)[:300], flush=True)
    r = b.call("thread/turns/list", {"threadId": x6})
    for t in r.get("result", {}).get("data", []):
        print("X6 TURN", t["id"], t["status"], t.get("error"), [(it["type"], it.get("status"), it.get("text", "")[:30]) for it in t["items"]])
    b.close_stdin(); print("B EXIT", b.wait_exit(15))


def X7b():
    """after systemError (bad model), can a valid turn run?  thread/start with bad model?"""
    c = Codex("X7b")
    c.init()
    r = c.call("thread/start", {"model": "no-such-model-xyz", "cwd": WORK})
    print("THREAD START BAD MODEL", json.dumps(r)[:300])
    tid = new_thread(c)
    n = c.n()
    c.turn_start(tid, "Reply with hi.", model="no-such-model-xyz")
    c.wait_for(turn_completed, 60, start=n)
    n = c.n()
    c.turn_start(tid, "Reply with just the word banana.", model=Codex.MODEL)
    c.wait_for(turn_completed, 60, start=n)
    c.close_stdin(); print("EXIT", c.wait_exit(15))


def X9():
    """race: turn/start at small offsets after the final agentMessage completes"""
    c = Codex("X9")
    c.init()
    tid = new_thread(c)
    for k, delay in enumerate([0.0, 0.015, 0.03, 0.045, 0.06]):
        n = c.n()
        rid, cm = c.turn_start(tid, "Reply with just the word apple%d." % k)
        i, resp = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
        t1 = resp["result"]["turn"]["id"]
        c.wait_for(lambda m: m.get("method") == "item/completed"
                   and m["params"]["item"]["type"] == "agentMessage", 60, start=n)
        time.sleep(delay)
        rid2, cm2 = c.turn_start(tid, "Now reply with just the word pear%d." % k)
        i2, resp2 = c.wait_for(lambda m: m.get("id") == rid2 and "method" not in m)
        t2 = resp2.get("result", {}).get("turn", {}).get("id")
        # wait until idle after everything
        end = time.time() + 30
        while time.time() < end:
            time.sleep(1)
            st = [o for (t, kk, o) in c.events[n:] if kk == "out" and isinstance(o, dict)
                  and o.get("method") == "thread/status/changed"]
            done = [o for (t, kk, o) in c.events[n:] if kk == "out" and isinstance(o, dict)
                    and o.get("method") == "turn/completed"]
            if st and st[-1]["params"]["status"]["type"] == "idle" and len(done) >= (1 if t1 == t2 else 2):
                break
        finals = [o["params"]["item"]["text"] for (t, kk, o) in c.events[n:] if kk == "out" and isinstance(o, dict)
                  and o.get("method") == "item/completed" and o["params"]["item"]["type"] == "agentMessage"]
        print("RACE delay=%.3f same_turn=%s finals=%s err=%s" % (delay, t1 == t2, finals, resp2.get("error")), flush=True)
    c.close_stdin(); print("EXIT", c.wait_exit(15))



def X10():
    c = Codex("X10")
    c.init()
    tid = new_thread(c)
    rid, cm = c.turn_start(tid, "Run `sleep 5; echo finished` in the shell, then reply with its output only.")
    i, resp = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
    turn_id = resp["result"]["turn"]["id"]
    c.wait_for(item_started("commandExecution"), 60)
    sc = str(uuid.uuid4())
    print("STEER WRONG", c.call("turn/steer", {"threadId": tid, "expectedTurnId": "01a10e2a-0000-7000-8000-000000000000", "clientUserMessageId": str(uuid.uuid4()),
                                "input": [{"type": "text", "text": "x", "text_elements": []}]}), flush=True)
    print("STEER OK", c.call("turn/steer", {"threadId": tid, "expectedTurnId": turn_id, "clientUserMessageId": sc,
                                "input": [{"type": "text", "text": "Also append the word kiwi to your reply.", "text_elements": []}]}), "clientId", sc, flush=True)
    c.wait_for(turn_completed, 60)
    c.close_stdin(); print("EXIT", c.wait_exit(15))



def X11():
    c = Codex("X11")
    print("BEFORE INIT", c.call("thread/start", {"cwd": WORK}), flush=True)
    c.init()
    print("DOUBLE INIT", c.call("initialize", {"clientInfo": {"name": "probe", "title": None, "version": "0"}}), flush=True)
    tid = new_thread(c)
    rid, cm = c.turn_start(tid, "Run `sleep 6; echo finished` in the shell, then reply with its output only.")
    i, resp = c.wait_for(lambda m: m.get("id") == rid and "method" not in m)
    turn_id = resp["result"]["turn"]["id"]
    c.wait_for(item_started("commandExecution"), 60)
    print("INTERRUPT WRONG ID", c.call("turn/interrupt", {"threadId": tid, "turnId": "01a10e2a-0000-7000-8000-000000000000"}), flush=True)
    c.wait_for(turn_completed, 60)
    c.close_stdin(); print("EXIT", c.wait_exit(15))


def X12():
    c = Codex("X12")
    c.init()
    tid = new_thread(c, approvalPolicy="untrusted", sandbox="read-only")
    c.turn_start(tid, "Run exactly this shell command: `echo hi > y_cancel.txt` and then reply done.")
    i, req = c.wait_for(is_server_req, 90)
    c.respond(req["id"], {"decision": "cancel"})
    c.wait_for(turn_completed, 60)
    time.sleep(1)
    c.close_stdin(); print("EXIT", c.wait_exit(15))

if __name__ == "__main__":
    w = sys.argv[1]
    if w.startswith("X2"):
        X2(w[2:])
    else:
        globals()[w]()
