"""The user's own Claude Code and Codex folders, left as the suite found them.

Real-agent tests run the user's own `claude` and `codex` (their logins live there), and the agents
record what those runs did:
- Codex trusts a folder whose trust prompt a live test answers (`~/.codex/config.toml`), and keeps each
  thread: its rollout file, its rows in its state database, its line in the session index, its prompts
  in the history and its log rows;
- Claude Code keeps each session's transcript (`~/.claude/projects/…`), its prompts in the history, its
  to-dos, file history, session environment and debug log, and a folder's trust in `~/.claude.json`.

`Snapshot.take()` notes what exists before the run; `Snapshot.clean()` removes what the run added for
the tests' own folders (the acceptance folder, temporary `acc-*` and pytest folders) and the sessions run
in them, and nothing else. Every path is a parameter of `home`, so the cleanup itself can be tested on a
made-up home folder.
"""

import json
import os
import re
import shutil
import sqlite3
import tempfile

from harness import ROOT

TEMP_ROOTS = ("/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/")


def is_test_path(path, root=ROOT):
    """A folder the suite made: under the acceptance folder, or a temporary `acc-*` or pytest folder."""
    if not path:
        return False
    path = os.path.normpath(path)
    for base in {root, os.path.realpath(root)}:
        if path == base or path.startswith(base.rstrip("/") + "/"):
            return True
    if not path.startswith(TEMP_ROOTS):
        return False
    parts = path.split("/")
    return any(p.startswith("acc-") or p.startswith("pytest-of-") for p in parts)


def _rewrite(path, text):
    """Replace a file's contents atomically, keeping its mode."""
    mode = os.stat(path).st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".acc-clean-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def _filter_jsonl(path, drop, start=0):
    """Drop the lines of a JSON-lines file, from byte `start` on, for which `drop(record)` is true.
    Returns how many."""
    if not os.path.exists(path):
        return 0
    with open(path, "rb") as f:
        head = f.read(start).decode(errors="surrogateescape")
        lines = f.read().decode(errors="surrogateescape").splitlines(keepends=True)
    kept, removed = [head], 0
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            kept.append(line)
            continue
        if drop(record):
            removed += 1
        else:
            kept.append(line)
    if removed:
        _rewrite(path, "".join(kept).encode(errors="surrogateescape").decode(errors="replace"))
    return removed


PROJECT_HEADER = re.compile(r'^\[projects\."((?:[^"\\]|\\.)*)"\]\s*$')


def codex_project_paths(text):
    return {m.group(1) for m in (PROJECT_HEADER.match(line) for line in text.splitlines()) if m}


def remove_codex_projects(text, paths):
    """config.toml without the `[projects."P"]` tables for `paths` (each table runs to the next header)."""
    out, skipping = [], False
    for line in text.splitlines(keepends=True):
        m = PROJECT_HEADER.match(line)
        if m:
            skipping = m.group(1) in paths
            # The blank line that separated the table goes with it.
            if skipping and out and not out[-1].strip():
                out.pop()
        elif line.lstrip().startswith("["):
            skipping = False
        if not skipping:
            out.append(line)
    return "".join(out)


class Snapshot:
    def __init__(self, home=None, root=ROOT):
        self.home = home or os.path.expanduser("~")
        self.root = root
        self.removed = []

    # -- paths
    def p(self, *parts):
        return os.path.join(self.home, *parts)

    def test_path(self, path):
        return is_test_path(path, self.root)

    def _codex_threads(self):
        db = self.p(".codex", "state_5.sqlite")
        if not os.path.exists(db):
            return {}
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
        try:
            return {row[0]: (row[1], row[2]) for row in con.execute("select id, cwd, rollout_path from threads")}
        except sqlite3.Error:
            return {}
        finally:
            con.close()

    def _rollouts(self):
        base = self.p(".codex", "sessions")
        found = set()
        for dirpath, _, files in os.walk(base):
            found.update(os.path.join(dirpath, f) for f in files if f.endswith(".jsonl"))
        return found

    def _claude_json(self):
        path = self.p(".claude.json")
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def take(self):
        config = self.p(".codex", "config.toml")
        self.codex_projects = codex_project_paths(open(config).read()) if os.path.exists(config) else set()
        self.codex_threads = set(self._codex_threads())
        self.rollouts = self._rollouts()
        data = self._claude_json()
        self.claude_trust = set((data or {}).get("projects", {}))
        projects = self.p(".claude", "projects")
        self.claude_project_dirs = set(os.listdir(projects)) if os.path.isdir(projects) else set()
        # What each folder held: a live test's folder is reused run after run, so its transcripts
        # are added to a folder that was already there.
        self.claude_project_entries = {
            name: set(os.listdir(os.path.join(projects, name)))
            for name in self.claude_project_dirs if os.path.isdir(os.path.join(projects, name))}
        history = self.p(".claude", "history.jsonl")
        self.claude_history_size = os.path.getsize(history) if os.path.exists(history) else 0
        return self

    # -- cleaning
    def clean(self):
        """Remove what the run added for the tests' folders and sessions. Returns what was removed."""
        self._clean_codex()
        self._clean_claude()
        return self.removed

    def _clean_codex(self):
        threads = self._codex_threads()
        ids, rollouts = set(), set()
        for tid, (cwd, rollout) in threads.items():
            if tid not in self.codex_threads and self.test_path(cwd):
                ids.add(tid)
                if rollout:
                    rollouts.add(rollout)
        # Rollouts the database doesn't list (yet): their first line says the thread and folder.
        for path in self._rollouts() - self.rollouts:
            try:
                with open(path) as f:
                    meta = json.loads(f.readline()).get("payload", {})
            except (OSError, ValueError, AttributeError):
                continue
            if self.test_path(meta.get("cwd")):
                rollouts.add(path)
                if meta.get("id"):
                    ids.add(meta["id"])
        for path in rollouts:
            if os.path.exists(path) and path not in self.rollouts:
                os.remove(path)
                self.removed.append(path)
        if ids:
            marks = ",".join("?" * len(ids))
            for db, statements in (
                ("state_5.sqlite", [f"delete from thread_dynamic_tools where thread_id in ({marks})",
                                    f"delete from thread_attachments where thread_id in ({marks})",
                                    f"delete from thread_spawn_edges where child_thread_id in ({marks})",
                                    f"delete from thread_spawn_edges where parent_thread_id in ({marks})",
                                    f"delete from threads where id in ({marks})"]),
                ("logs_2.sqlite", [f"delete from logs where thread_id in ({marks})"]),
            ):
                path = self.p(".codex", db)
                if not os.path.exists(path):
                    continue
                con = sqlite3.connect(path, timeout=30)
                try:
                    with con:
                        for sql in statements:
                            try:
                                con.execute(sql, tuple(ids))
                            except sqlite3.OperationalError:
                                pass  # a table this Codex doesn't have
                finally:
                    con.close()
                self.removed.append(f"{path}: {len(ids)} thread(s)")
            n = _filter_jsonl(self.p(".codex", "session_index.jsonl"), lambda r: r.get("id") in ids)
            n += _filter_jsonl(self.p(".codex", "history.jsonl"), lambda r: r.get("session_id") in ids)
            if n:
                self.removed.append(f"~/.codex index and history: {n} line(s)")
        config = self.p(".codex", "config.toml")
        if os.path.exists(config):
            text = open(config).read()
            added = {p for p in codex_project_paths(text) - self.codex_projects if self.test_path(p)}
            if added:
                _rewrite(config, remove_codex_projects(text, added))
                self.removed.extend(f"{config}: trust of {p}" for p in sorted(added))

    @staticmethod
    def _transcript_cwd(folder, entries):
        """The folder a Claude Code project folder's transcripts were recorded in."""
        for entry in sorted(entries):
            if not entry.endswith(".jsonl"):
                continue
            try:
                with open(os.path.join(folder, entry), errors="replace") as f:
                    for line in f:
                        try:
                            cwd = json.loads(line).get("cwd")
                        except (ValueError, AttributeError):
                            continue
                        if cwd:
                            return cwd
            except OSError:
                continue
        return None

    def _clean_claude(self):
        projects = self.p(".claude", "projects")
        sessions = set()
        if os.path.isdir(projects):
            for name in os.listdir(projects):
                folder = os.path.join(projects, name)
                if not os.path.isdir(folder):
                    continue
                entries = set(os.listdir(folder))
                if name not in self.claude_project_dirs:
                    if self.test_path(self._transcript_cwd(folder, entries)):
                        sessions.update(e[:-6] for e in entries if e.endswith(".jsonl"))
                        shutil.rmtree(folder, ignore_errors=True)
                        self.removed.append(folder)
                    continue
                added = entries - self.claude_project_entries.get(name, set())
                if not added or not self.test_path(self._transcript_cwd(folder, entries)):
                    continue
                for entry in added:
                    path = os.path.join(folder, entry)
                    if entry.endswith(".jsonl"):
                        sessions.add(entry[:-6])
                    shutil.rmtree(path, ignore_errors=True) if os.path.isdir(path) else os.remove(path)
                    self.removed.append(path)
        n = _filter_jsonl(self.p(".claude", "history.jsonl"),
                          lambda r: self.test_path(r.get("project")) or r.get("sessionId") in sessions,
                          start=self.claude_history_size)
        if n:
            self.removed.append(f"~/.claude/history.jsonl: {n} line(s)")
        for sid in sessions:
            for path in (self.p(".claude", "debug", f"{sid}.txt"), self.p(".claude", "file-history", sid),
                         self.p(".claude", "session-env", sid)):
                if os.path.isdir(path):
                    shutil.rmtree(path, ignore_errors=True)
                    self.removed.append(path)
                elif os.path.exists(path):
                    os.remove(path)
                    self.removed.append(path)
            todos = self.p(".claude", "todos")
            if os.path.isdir(todos):
                for entry in os.listdir(todos):
                    if entry.startswith(sid):
                        os.remove(os.path.join(todos, entry))
                        self.removed.append(os.path.join(todos, entry))
        # A folder's trust (and Claude Code's other notes about it), outside ~/.claude.
        data = self._claude_json()
        if data and isinstance(data.get("projects"), dict):
            added = [k for k in data["projects"] if k not in self.claude_trust and self.test_path(k)]
            if added:
                path = self.p(".claude.json")
                fresh = self._claude_json() or data  # re-read just before writing
                for key in added:
                    fresh.get("projects", {}).pop(key, None)
                _rewrite(path, json.dumps(fresh, indent=2) + "\n")
                self.removed.extend(f"~/.claude.json: {k}" for k in added)
