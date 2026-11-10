import json, os, sys, time
agent, event = sys.argv[1], sys.argv[2]
raw = sys.stdin.read()
try: data = json.loads(raw)
except Exception: data = raw
with open(os.environ.get("HOOKLOG", os.path.join(os.path.dirname(__file__), "logs", agent + ".jsonl")), "a") as f:
    f.write(json.dumps({"ts": round(time.time(), 2), "agent": agent, "event": event, "ppid": os.getppid(), "input": data}) + "\n")
