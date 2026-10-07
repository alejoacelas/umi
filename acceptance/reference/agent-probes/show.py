"""Compact viewer for probe logs. Usage: python3 show.py LOGNAME [--full TYPE]"""
import json
import os
import sys

from probelib import LOGS, abbrev, CODEX_SKIP


def blocks(content):
    if isinstance(content, str):
        return repr(content[:100])
    out = []
    for b in content or []:
        if not isinstance(b, dict):
            out.append(str(b)[:60])
            continue
        t = b.get("type")
        if t == "text":
            out.append("text:%r" % b.get("text", "")[:120])
        elif t == "thinking":
            out.append("thinking(%d)" % len(b.get("thinking", "")))
        elif t == "tool_use":
            out.append("tool_use[%s %s %s]" % (b.get("id"), b.get("name"), json.dumps(b.get("input"))[:120]))
        elif t == "tool_result":
            c = b.get("content")
            out.append("tool_result[%s err=%s %r]" % (b.get("tool_use_id"), b.get("is_error"), str(c)[:120]))
        else:
            out.append(t)
    return " | ".join(out)


def fmt_claude(m):
    t = m.get("type")
    rest = {k: v for k, v in m.items() if k not in ("message", "type", "subtype", "uuid", "session_id")}
    if t in ("assistant", "user"):
        msg = m.get("message", {})
        return "%s %s keys=%s %s" % (t.upper(), blocks(msg.get("content")),
                                     sorted(rest.keys()),
                                     json.dumps(abbrev({k: rest[k] for k in rest if k in ("isReplay", "parent_tool_use_id", "tool_use_result", "user_message_uuid", "error")}, 80)))
    if t == "result":
        r = {k: v for k, v in m.items() if k not in ("usage", "modelUsage")}
        return "RESULT " + json.dumps(abbrev(r, 200))
    if t == "system" and m.get("subtype") == "init":
        return "SYSTEM/init " + json.dumps({k: m.get(k) for k in ("session_id", "permissionMode", "model", "uuid")})
    if t == "system" and m.get("subtype") == "session_state_changed":
        return "STATE %s" % m.get("state")
    if t == "command_lifecycle":
        return "LIFECYCLE %s %s" % (m.get("command_uuid"), m.get("state"))
    if t == "control_response":
        r = m.get("response", {})
        if r.get("request_id") == "init1":
            return "CONTROL_RESPONSE init1 keys=%s" % sorted((r.get("response") or {}).keys())
    if t in ("rate_limit_event",):
        return "rate_limit_event"
    if t == "system" and m.get("subtype") == "thinking_tokens":
        return None
    return json.dumps(abbrev(m, 300))


def fmt_codex(m):
    meth = m.get("method")
    if meth in CODEX_SKIP:
        return None
    return json.dumps(abbrev(m, 300))


def main():
    name = sys.argv[1]
    codex = name.startswith("X")
    for line in open(os.path.join(LOGS, name + ".jsonl")):
        e = json.loads(line)
        k, m = e["k"], e["m"]
        if k == "out":
            s = fmt_codex(m) if codex else fmt_claude(m)
            if s is None:
                continue
        elif k == "in":
            if not codex and isinstance(m, dict) and m.get("type") == "user":
                s = "SEND user uuid=%s %r" % (m.get("uuid"), str(m["message"]["content"])[:80])
            else:
                s = json.dumps(abbrev(m, 200)) if not isinstance(m, str) else m
        else:
            s = json.dumps(m)[:400] if not isinstance(m, str) else m[:400]
        print("%6.2f %-4s %s" % (e["t"], k, s[:1200]))


if __name__ == "__main__":
    main()
