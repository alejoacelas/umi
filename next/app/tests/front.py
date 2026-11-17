"""Brings the UmiNext under test to the front (activation from a script is only a request on
macOS 14+): System Events makes its process frontmost, picked by pid, since every UmiNext shares
one bundle id."""
import os, subprocess, time


def bring_to_front(D):
    pid = D({"cmd": "state"}).get("pid")
    for _ in range(3):
        if D({"cmd": "activate"}).get("key"):
            return True
        subprocess.run(["osascript", "-e",
                        f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'],
                       check=False, capture_output=True)
        time.sleep(0.5)
        if D({"cmd": "state"}).get("active"):
            return True
    return False
