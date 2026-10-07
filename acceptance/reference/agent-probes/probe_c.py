"""Claude Code stream-json probes. Usage: python3 probe_c.py C1|C2|C3deny|C3allow|C3int|C4|C5|C7|C8"""
import json
import sys
import time
import uuid

from probelib import Claude, abbrev

SLEEP_PROMPT = "Use the Bash tool to run exactly `sleep 20; echo finished` and then reply with its output."


def is_tool_use(m, name="Bash"):
    if m.get("type") != "assistant":
        return False
    for c in m.get("message", {}).get("content", []) or []:
        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == name:
            return True
    return False


def finish(c, wait=30):
    c.close_stdin()
    rc = c.wait_exit(wait)
    print("EXIT CODE", rc)


def C1():
    c = Claude("C1", extra=["--permission-mode", "default"], auto_allow=True)
    print("INIT", c.init())
    u1 = c.user(SLEEP_PROMPT)
    c.wait_for(lambda m: is_tool_use(m), 60)
    time.sleep(3)
    rid = c.control("interrupt", rid="int1")
    c.wait_result(30)
    time.sleep(4)
    print("---- second message after interrupt")
    n = c.n()
    u2 = c.user("Reply with just the word banana.")
    c.wait_result(60, start=n)
    time.sleep(2)
    print("UUIDS", u1, u2)
    finish(c)


def C1b():
    """interrupt, then close stdin with no further turn: exit code?  Also interrupt while idle."""
    c = Claude("C1b", extra=["--permission-mode", "default"], auto_allow=True)
    c.init()
    c.control("interrupt", rid="int_idle")
    time.sleep(2)
    c.user(SLEEP_PROMPT)
    c.wait_for(lambda m: is_tool_use(m), 60)
    time.sleep(2)
    c.control("interrupt", rid="int1")
    c.wait_result(30)
    time.sleep(1)
    c.control("interrupt", rid="int_after")
    time.sleep(2)
    finish(c)


def C2():
    c = Claude("C2", extra=["--permission-mode", "default"], auto_allow=True)
    c.init()
    u1 = c.user(SLEEP_PROMPT)
    c.wait_for(lambda m: is_tool_use(m), 60)
    time.sleep(2)
    u2 = c.user("Reply with just the word banana.")
    time.sleep(2)
    c.control("interrupt", rid="int1")
    c.wait_result(30)
    print("---- waiting 15s to see if queued message gets delivered")
    time.sleep(15)
    print("UUIDS", u1, u2)
    finish(c)


def C3(mode):
    c = Claude("C3" + mode, extra=["--permission-mode", "default"])
    c.init()
    u1 = c.user("Create a file named x_%s.txt containing the text hi, using the Write tool. Then reply done." % mode)
    i, req = c.wait_for(lambda m: m.get("type") == "control_request"
                        and m.get("request", {}).get("subtype") == "can_use_tool", 60)
    print("CAN_USE_TOOL FULL:", json.dumps(req, indent=1))
    time.sleep(3)
    if mode == "deny":
        c.reply_perm(req, False, "no")
    elif mode == "allow":
        c.reply_perm(req, True)
    elif mode == "int":
        c.control("interrupt", rid="int1")
        time.sleep(3)
        # try answering after interrupt to see what happens
        c.reply_perm(req, True)
    c.wait_result(60)
    time.sleep(3)
    finish(c)


def C4():
    sid = str(uuid.uuid4())
    c = Claude("C4a", extra=["--session-id", sid, "--permission-mode", "default"])
    c.init()
    c.user("Remember the codeword PAPAYA. Reply with just 'ok'.")
    c.wait_result(60)
    finish(c)
    print("=========== resume", sid)
    c = Claude("C4b", extra=["--resume", sid, "--permission-mode", "default"])
    print("INIT", c.init())
    time.sleep(2)
    n = c.n()
    c.user("What was the codeword? Reply with one word.")
    c.wait_result(60, start=n)
    finish(c)
    print("=========== resume + new session-id")
    new = str(uuid.uuid4())
    c = Claude("C4c", extra=["--resume", sid, "--session-id", new, "--permission-mode", "default"])
    c.init(10)
    c.user("What was the codeword? Reply with one word.")
    c.wait_result(40)
    finish(c)
    print("NEW", new)
    print("=========== resume + fork-session + session-id")
    new2 = str(uuid.uuid4())
    c = Claude("C4d", extra=["--resume", sid, "--fork-session", "--session-id", new2, "--permission-mode", "default"])
    c.init(10)
    c.user("What was the codeword? Reply with one word.")
    c.wait_result(40)
    finish(c)
    print("NEW2", new2)
    print("=========== resume nonexistent uuid")
    c = Claude("C4e", extra=["--resume", str(uuid.uuid4())])
    c.init(10)
    c.user("hi")
    c.wait_result(15)
    finish(c, 15)
    print("=========== resume non-uuid string")
    c = Claude("C4f", extra=["--resume", "not-a-real-session"])
    c.init(10)
    c.user("hi")
    c.wait_result(15)
    finish(c, 15)
    print("SID", sid)


def C5():
    c = Claude("C5", extra=["--permission-mode", "default"], auto_allow=True)
    c.init()
    c.user("Use the Bash tool to run exactly `sleep 8; echo finished` and then reply with its output.")
    c.wait_for(lambda m: is_tool_use(m), 60)
    time.sleep(1)
    t0 = time.time()
    c.close_stdin()
    rc = c.wait_exit(60)
    print("EXIT CODE", rc, "after %.2fs" % (time.time() - t0))


def C5b():
    """close stdin right after sending the message (before any output)"""
    c = Claude("C5b", extra=["--permission-mode", "default"], auto_allow=True)
    c.init()
    c.user("Reply with just the word banana.")
    t0 = time.time()
    c.close_stdin()
    rc = c.wait_exit(60)
    print("EXIT CODE", rc, "after %.2fs" % (time.time() - t0))


def C7():
    c = Claude("C7", extra=["--dangerously-skip-permissions"])
    c.init()
    c.user("Use the Bash tool to run `echo hi > c7.txt; cat c7.txt` and reply with the output.")
    c.wait_result(60)
    finish(c)


def C8():
    c = Claude("C8", extra=["--permission-mode", "default"])
    c.init()
    c.write_raw("this is not json")
    time.sleep(2)
    c.write_raw('{"type":"bogus_type","foo":1}')
    time.sleep(2)
    c.write_raw('{"type":"control_request","request_id":"bad1","request":{"subtype":"no_such_subtype"}}')
    time.sleep(2)
    c.write_raw('{"type":"user","message":{"role":"user","content":"Reply with just the word banana."}}')
    c.wait_result(40)
    time.sleep(1)
    finish(c)




SID = "f4bf0e51-b815-4651-af1a-c11fb871f76f"  # session created by C4a (codeword PAPAYA)


def _quick(name, extra, text="What was the codeword? Reply with one word.", wait=40):
    c = Claude(name, extra=extra)
    c.init(10)
    c.user(text)
    c.wait_result(wait)
    time.sleep(1)
    finish(c, 20)
    return c


def C4c():
    _quick("C4c", ["--resume", SID, "--session-id", str(uuid.uuid4())])


def C4d():
    new2 = str(uuid.uuid4())
    c = _quick("C4d", ["--resume", SID, "--fork-session", "--session-id", new2])
    print("NEW2", new2)


def C4e():
    _quick("C4e", ["--resume", str(uuid.uuid4())], "hi", 15)


def C4f():
    _quick("C4f", ["--resume", "not-a-real-session"], "hi", 15)


def C4g():
    """resume with a uuid for which a session exists but was created in another cwd? -> use --session-id of existing id (duplicate)"""
    _quick("C4g", ["--session-id", SID], "What was the codeword? Reply with one word.", 20)


def _c8(name, line):
    c = Claude(name, extra=["--permission-mode", "default"])
    c.init()
    c.write_raw(line)
    time.sleep(2)
    c.user("Reply with just the word banana.")
    c.wait_result(30)
    time.sleep(1)
    finish(c, 15)


def C8a():
    _c8("C8a", "this is not json")


def C8b():
    _c8("C8b", '{"type":"bogus_type","foo":1}')


def C8c():
    _c8("C8c", '{"type":"control_request","request_id":"bad1","request":{"subtype":"no_such_subtype"}}')


def C8d():
    _c8("C8d", '{"type":"user","message":{"role":"user","content":"Reply with just the word apple."}}')


def C8e():
    _c8("C8e", '')




def C9():
    """mid-turn injection shape"""
    c = Claude("C9", extra=["--permission-mode", "default"], auto_allow=True)
    c.init()
    u1 = c.user("Use the Bash tool to run exactly `sleep 5; echo finished` and then reply with its output.")
    c.wait_for(lambda m: is_tool_use(m), 60)
    time.sleep(1)
    u2 = c.user("Also, at the end, say the word banana.")
    c.wait_result(60)
    time.sleep(3)
    print("UUIDS", u1, u2)
    finish(c)


def C9b():
    """two messages back-to-back while idle"""
    c = Claude("C9b", extra=["--permission-mode", "default"])
    c.init()
    u1 = c.user("Reply with just the word apple.")
    u2 = c.user("Reply with just the word pear.")
    i, r = c.wait_result(60)
    c.wait_result(60, start=i + 1)
    time.sleep(3)
    print("UUIDS", u1, u2)
    finish(c)



def CBash():
    c = Claude("CBash", extra=["--permission-mode", "default"])
    c.init()
    c.user("Use the Bash tool to run exactly `touch c3bash.txt` and then reply done.")
    i, req = c.wait_for(lambda m: m.get("type") == "control_request"
                        and m.get("request", {}).get("subtype") == "can_use_tool", 60)
    print("CAN_USE_TOOL FULL:", json.dumps(req, indent=1))
    c.reply_perm(req, False, "no")
    c.wait_result(60)
    finish(c)

if __name__ == "__main__":
    which = sys.argv[1]
    if which.startswith("C3"):
        C3(which[2:])
    else:
        globals()[which]()
