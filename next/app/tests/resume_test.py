#!/usr/bin/env python3
"""A pane whose agent session is gone after a daemon restart comes back resuming that agent.

  resume_test.py APP

APP is a test copy (`build.sh --test NAME`). The script starts it off screen with its own state,
opens a real Claude session in a pane, restarts the app and its daemon (which ends every session),
and checks that the same pane runs `claude … --resume <the agent's session id>`. It needs `claude`
on PATH and types nothing into windows. It stops the app and daemon and moves the state to the Trash at the end.
"""
import json, os, plistlib, subprocess, sys, tempfile

app = os.path.abspath(sys.argv[1])
info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
# The script force-stops this copy's daemon and trashes its state: never the real UmiNext's.
if info["UmiNextStateName"] == "Umi-next":
    sys.exit("resume_test.py: APP must be a test copy (build.sh --test NAME), not the real UmiNext")
STATE = os.path.expanduser("~/Library/Application Support/" + info["UmiNextStateName"])
CLI = os.path.join(app, "Contents/MacOS/umi-next")
CTL = os.path.join(app, "Contents/MacOS/umi-next-ctl")
ENV = {k: v for k, v in os.environ.items() if not k.startswith("UMI_")}
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debugsock import Debug, poll  # noqa: E402

debug = Debug(STATE).result


def cli(*args):
    p = subprocess.run([CLI, *args], capture_output=True, text=True, env=ENV, timeout=60)
    if p.returncode:
        raise AssertionError(f"umi-next {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout


def until(fn, secs, what):
    return poll(fn, secs, every=0.25, swallow=Exception, what=what)


def launch():
    env = {**ENV, "UMI_NEXT_DEBUG": "1", "UMI_NEXT_OFFSCREEN": "1"}
    p = subprocess.Popen([os.path.join(app, "Contents/MacOS/UmiNext")], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        until(lambda: debug("1"), 30, "the app's debug socket")
    except BaseException:
        p.terminate()
        raise
    return p


def stop(p):
    p.terminate()
    p.wait(10)
    subprocess.run([CTL, "daemon-stop", "--force"], env={**ENV, "UMI_NEXT_STATE_DIR": STATE},
                   capture_output=True)


folder = tempfile.mkdtemp(prefix="umi-next-resume-")
subprocess.run(["git", "init", "-q", folder], check=True)
ok = False
proc = launch()
try:
    out = json.loads(cli("--json", "split", "right", "--cmd", "claude --dangerously-skip-permissions",
                         "--cwd", folder, "--name", "resume-me"))
    pane = out["pane"]
    # Claude asks once whether to trust a new folder; its default is "No, exit".
    def trusted():
        screen = cli("read", "--pane", pane)
        if "Yes, I trust" in screen:
            cli("keys", "--pane", pane, "down", "enter")
            return False
        return "bypass permissions" in screen
    until(trusted, 60, "Claude past the trust question")
    try:
        resume = until(lambda: json.loads(debug(f"JSON.stringify(Umi.model.findPane('{pane}')?.node.resume || null)") or "null"),
                       60, "the pane's resume record")
    except AssertionError:
        print("pane node:", debug(f"JSON.stringify(Umi.model.findPane('{pane}')?.node)"))
        print("live:", debug(f"JSON.stringify(Umi.state.live[Umi.model.findPane('{pane}')?.node.session])"))
        print("screen:", cli("read", "--pane", pane)[-600:])
        raise
    assert "--resume" in resume["cmd"], resume
    agent_id = resume["cmd"].split("--resume", 1)[1].split()[0]
    print("ok   pane", pane, "records", resume["cmd"])
    until(lambda: agent_id in open(os.path.join(STATE, "layout.json")).read(), 10, "the record in layout.json")
    print("ok   layout.json has it")

    stop(proc)
    proc = launch()
    sid = until(lambda: debug(f"Umi.model.findPane('{pane}')?.node.session || ''"), 30, "the pane's new session")
    def resumed():
        ps = subprocess.run(["ps", "-axo", "command"], capture_output=True, text=True).stdout
        return [l for l in ps.splitlines() if "claude" in l and f"--resume {agent_id}" in l and "umi-next" not in l]
    try:
        lines = until(resumed, 30, f"a claude process resuming {agent_id}")
    except AssertionError:
        print("pane node:", debug(f"JSON.stringify(Umi.model.findPane('{pane}')?.node)"))
        print("live:", debug(f"JSON.stringify(Umi.state.live['{sid}'])"))
        raise
    assert "--dangerously-skip-permissions" in lines[0], lines
    print("ok   after the daemon restart, pane", pane, "runs:", lines[0])
    ok = True
finally:
    stop(proc)
    subprocess.run(["trash", STATE, folder], capture_output=True)
print("all passed" if ok else "FAILED")
sys.exit(0 if ok else 1)
