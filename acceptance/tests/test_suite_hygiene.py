"""The suite itself: real-agent runs leave the user's own Claude Code and Codex folders as they found
them (tests/agent_config.py, run around every ACCEPTANCE_REAL session by conftest.py). Checked here on a
made-up home folder with what the agents write for a run: Codex's trust entry, thread rows, rollout,
index and history lines; Claude Code's transcript folder, history lines, per-session files and the
folder's trust in ~/.claude.json. What was there before stays, byte for byte."""

import json
import os
import sqlite3

from agent_config import ROOT, Snapshot, is_test_path


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def read(path):
    with open(path) as f:
        return f.read()


def make_codex_db(path, rows):
    con = sqlite3.connect(path)
    con.execute("create table threads (id text primary key, rollout_path text, cwd text)")
    con.execute("create table thread_dynamic_tools (thread_id text, position integer)")
    con.executemany("insert into threads values (?, ?, ?)", rows)
    con.commit()
    con.close()


def test_is_test_path():
    assert is_test_path(os.path.join(ROOT, ".work-real", "live-codex"))
    assert is_test_path("/private/var/folders/ab/T/acc-real-x1/work")
    assert is_test_path("/private/tmp/acc-ag20-q1p1fou0")
    assert is_test_path("/private/var/folders/ab/T/pytest-of-me/pytest-3/test_x0/proj")
    assert not is_test_path("/Users/me/dev/warp")
    assert not is_test_path("/private/tmp/warp-demo")
    assert not is_test_path(None)


def test_a_real_run_leaves_the_agents_folders_as_found(tmp_path):
    home = str(tmp_path)
    user_dir = "/Users/me/dev/project"
    live = os.path.join(ROOT, ".work-real", "live-codex")
    work = "/private/var/folders/ab/T/acc-real-x1/work"

    # Before the run: the user's own things.
    config_before = (f'model = "x"\n\n[projects."{user_dir}"]\ntrust_level = "trusted"\n\n'
                     '[plugins."tern@tern"]\nenabled = true\n')
    write(f"{home}/.codex/config.toml", config_before)
    old_rollout = f"{home}/.codex/sessions/2026/10/01/rollout-old.jsonl"
    write(old_rollout, json.dumps({"type": "session_meta", "payload": {"id": "old", "cwd": user_dir}}) + "\n")
    make_codex_db(f"{home}/.codex/state_5.sqlite", [("old", old_rollout, user_dir)])
    write(f"{home}/.codex/history.jsonl", json.dumps({"session_id": "old", "text": "hi"}) + "\n")
    write(f"{home}/.codex/session_index.jsonl", json.dumps({"id": "old"}) + "\n")
    write(f"{home}/.claude/projects/-Users-me-dev-project/u1.jsonl", json.dumps({"cwd": user_dir}) + "\n")
    # A live test's folder, from an earlier run: what's in it stays, what this run adds goes.
    live_claude = os.path.join(ROOT, ".work-real", "live-claude")
    reused = f"{home}/.claude/projects/live-claude-folder"
    write(f"{reused}/old.jsonl", json.dumps({"cwd": live_claude}) + "\n")
    claude_history_before = json.dumps({"project": user_dir, "sessionId": "u1", "display": "x"}) + "\n"
    write(f"{home}/.claude/history.jsonl", claude_history_before)
    write(f"{home}/.claude.json", json.dumps({"projects": {user_dir: {"hasTrustDialogAccepted": True}}}))

    snapshot = Snapshot(home=home).take()

    # The run: Codex trusts the live folder and keeps a thread; Claude Code keeps a session.
    write(f"{home}/.codex/config.toml",
          config_before + f'\n[projects."{live}"]\ntrust_level = "trusted"\n')
    new_rollout = f"{home}/.codex/sessions/2026/10/11/rollout-new.jsonl"
    write(new_rollout, json.dumps({"type": "session_meta", "payload": {"id": "t1", "cwd": live}}) + "\n")
    unlisted = f"{home}/.codex/sessions/2026/10/11/rollout-unlisted.jsonl"
    write(unlisted, json.dumps({"type": "session_meta", "payload": {"id": "t2", "cwd": work}}) + "\n")
    con = sqlite3.connect(f"{home}/.codex/state_5.sqlite")
    con.execute("insert into threads values ('t1', ?, ?)", (new_rollout, live))
    con.execute("insert into thread_dynamic_tools values ('t1', 0)")
    con.commit()
    con.close()
    with open(f"{home}/.codex/history.jsonl", "a") as f:
        f.write(json.dumps({"session_id": "t1", "text": "/exit"}) + "\n")
    with open(f"{home}/.codex/session_index.jsonl", "a") as f:
        f.write(json.dumps({"id": "t1"}) + "\n")
    write(f"{home}/.claude/projects/-private-var-folders-ab-T-acc-real-x1-work/s1.jsonl",
          json.dumps({"type": "summary"}) + "\n" + json.dumps({"cwd": work}) + "\n")
    write(f"{home}/.claude/debug/s1.txt", "log")
    write(f"{reused}/s2.jsonl", json.dumps({"cwd": live_claude}) + "\n")
    write(f"{reused}/s2/subagents/a.jsonl", "{}\n")
    write(f"{home}/.claude/session-env/s2/env", "x")
    write(f"{home}/.claude/session-env/s1/env", "x")
    with open(f"{home}/.claude/history.jsonl", "a") as f:
        f.write(json.dumps({"project": work, "sessionId": "s1", "display": "/exit"}) + "\n")
    data = json.loads(read(f"{home}/.claude.json"))
    data["projects"][work] = {"hasTrustDialogAccepted": True}
    write(f"{home}/.claude.json", json.dumps(data))
    # Meanwhile the user's own Claude Code noted something about their folder: that stays.
    data["projects"][user_dir]["lastCost"] = 1
    write(f"{home}/.claude.json", json.dumps(data))

    removed = snapshot.clean()
    assert removed

    assert read(f"{home}/.codex/config.toml") == config_before
    assert not os.path.exists(new_rollout) and not os.path.exists(unlisted) and os.path.exists(old_rollout)
    con = sqlite3.connect(f"{home}/.codex/state_5.sqlite")
    assert [r[0] for r in con.execute("select id from threads")] == ["old"]
    assert list(con.execute("select * from thread_dynamic_tools")) == []
    con.close()
    assert read(f"{home}/.codex/history.jsonl") == json.dumps({"session_id": "old", "text": "hi"}) + "\n"
    assert read(f"{home}/.codex/session_index.jsonl") == json.dumps({"id": "old"}) + "\n"
    assert sorted(os.listdir(f"{home}/.claude/projects")) == ["-Users-me-dev-project", "live-claude-folder"]
    assert os.listdir(reused) == ["old.jsonl"]
    assert not os.path.exists(f"{home}/.claude/session-env/s2")
    assert not os.path.exists(f"{home}/.claude/debug/s1.txt")
    assert not os.path.exists(f"{home}/.claude/session-env/s1")
    assert read(f"{home}/.claude/history.jsonl") == claude_history_before
    assert json.loads(read(f"{home}/.claude.json")) == {
        "projects": {user_dir: {"hasTrustDialogAccepted": True, "lastCost": 1}}}


def test_history_from_before_the_run_is_never_touched(tmp_path):
    """Lines already in Claude Code's history, even for a test folder (an earlier run), stay."""
    home = str(tmp_path)
    old = json.dumps({"project": "/private/tmp/acc-old", "sessionId": "x", "display": "y"}) + "\n"
    write(f"{home}/.claude/history.jsonl", old)
    snapshot = Snapshot(home=home).take()
    with open(f"{home}/.claude/history.jsonl", "a") as f:
        f.write(json.dumps({"project": "/private/tmp/acc-new", "sessionId": "z", "display": "w"}) + "\n")
    snapshot.clean()
    assert read(f"{home}/.claude/history.jsonl") == old
