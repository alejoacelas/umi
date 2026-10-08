"""Property-based and fault-injection tests of managed sessions (SPEC MA-3, MA-4, MA-7, MA-22, R-1).

Hypothesis drives random sequences of operations (send, interrupt, stop, crash, start another
session) against fake harnesses that themselves vary timing, noise and legal event orderings
(FAKE_CHAOS=<seed>, see fakes/README.md). After every sequence the invariants below must hold.
A failing sequence is shrunk to a minimal reproduction and printed.

ACCEPTANCE_CHAOS_EXAMPLES (default 12) sets how many sequences run.
"""

import os
import time
import uuid

import pytest
from hypothesis import HealthCheck, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, initialize, invariant, precondition, rule, run_state_machine_as_test

from harness import alive

pytestmark = [pytest.mark.chaos, pytest.mark.managed, pytest.mark.slow, pytest.mark.harness]

KINDS = ["claude", "codex"]
TERMINAL = {"DONE", "INTERRUPTED", "FAILED", "EXITED", "ERROR"}
LEGAL_STATUS = {"starting", "working", "idle", "needs_input", "exited", "error"}
BODIES = ["ECHO", "SLEEP 0.3", "SLEEP 1.5", "RUN echo hi", "GARBAGE ECHO", "STDERR_SPAM ECHO", "HUGE 0.3"]


def run_machine(inst, machine, examples, steps):
    machine.inst = inst
    run_state_machine_as_test(machine, settings=settings(
        max_examples=examples, stateful_step_count=steps, deadline=None, derandomize=False,
        suppress_health_check=list(HealthCheck)))


class Sessions(RuleBasedStateMachine):
    """A few sessions, poked at random. Invariants: exactly-once delivery, nothing pending forever,
    truthful statuses, nothing left running."""

    inst = None

    def __init__(self):
        super().__init__()
        self.sessions = []          # session ids
        self.messages = []          # (session, message id, nonce)

    # -- operations

    @initialize(kind=st.sampled_from(KINDS), seed=st.integers(1, 10_000))
    def first_session(self, kind, seed):
        self._start(kind, seed)

    @precondition(lambda self: len(self.sessions) < 3)
    @rule(kind=st.sampled_from(KINDS), seed=st.integers(1, 10_000))
    def another_session(self, kind, seed):
        self._start(kind, seed)

    def _start(self, kind, seed):
        n = uuid.uuid4().hex[:10]
        sid = self.inst.start_agent(kind, f"ECHO start {n}", name=f"chaos-{n}", chaos=seed)
        self.sessions.append(sid)
        message = self.inst.info(sid)["last_message"]["id"]
        self.messages.append((sid, message, n))

    @rule(which=st.integers(0, 2), body=st.sampled_from(BODIES))
    def send(self, which, body):
        sid = self.sessions[which % len(self.sessions)]
        n = uuid.uuid4().hex[:10]
        message = self.inst.send(sid, f"{body} {n}")
        self.messages.append((sid, message, n))

    @rule(which=st.integers(0, 2), pause=st.sampled_from([0, 0.1, 0.4]))
    def interrupt(self, which, pause):
        time.sleep(pause)
        self.inst.cli("agent", "interrupt", self.sessions[which % len(self.sessions)], check=False)

    @rule(which=st.integers(0, 2))
    def stop(self, which):
        self.inst.cli("agent", "stop", self.sessions[which % len(self.sessions)], check=False, timeout=60)

    @rule(which=st.integers(0, 2))
    def crash(self, which):
        sid = self.sessions[which % len(self.sessions)]
        n = uuid.uuid4().hex[:10]
        self.messages.append((sid, self.inst.send(sid, f"CRASH {n}"), n))

    @rule(which=st.integers(0, 2))
    def wait_a_little(self, which):
        self.inst.cli("agent", "wait", self.sessions[which % len(self.sessions)], "--timeout", "1", check=False)

    # -- invariants

    @invariant()
    def never_delivered_twice(self):
        counts = {}
        for r in self.inst.receipts():
            for _, _, n in self.messages:
                if n in (r.get("text") or ""):
                    counts[n] = counts.get(n, 0) + 1
        twice = {n: c for n, c in counts.items() if c > 1}
        assert not twice, f"delivered more than once: {twice}"

    @invariant()
    def statuses_are_legal(self):
        for s in self.inst.agents():
            if s["id"] in self.sessions:
                assert s["status"] in LEGAL_STATUS, s

    def teardown(self):
        leftover = []
        try:
            for sid, message, n in self.messages:
                code, out = self.inst.wait(sid, "--message", message, timeout=90)
                assert out["status"] in TERMINAL, f"message {n} still pending after 90 s: {out}"
                got = len(with_nonce(self.inst, n))
                if out["status"] == "DONE":
                    assert got == 1, f"message {n} answered but delivered {got} times"
                else:
                    assert got <= 1, f"message {n} delivered {got} times"
            for sid in self.sessions:
                assert self.inst.info(sid)["status"] in {"idle", "exited", "error"}, self.inst.info(sid)
        finally:
            nonces = [n for _, _, n in self.messages]
            pids = {r["pid"] for r in self.inst.receipts() if any(n in r.get("text", "") for n in nonces)}
            for sid in self.sessions:
                self.inst.cli("agent", "stop", sid, check=False, timeout=60)
            leftover = still_alive(pids, 20)
        assert not leftover, f"harness processes outlived `agent stop`: {leftover}"


def with_nonce(inst, n):
    return [r for r in inst.receipts() if n in (r.get("text") or "")]


def still_alive(pids, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline and any(alive(p) for p in pids):
        time.sleep(0.2)
    return [p for p in pids if alive(p)]


@pytest.mark.req("MA-3", "MA-4", "MA-7", "MA-22")
def test_random_operation_sequences(inst):
    examples = int(os.environ.get("ACCEPTANCE_CHAOS_EXAMPLES", "12"))
    run_machine(inst, Sessions, examples, steps=8)


@pytest.mark.req("MA-4", "MA-22", "R-1")
@pytest.mark.parametrize("seed", range(1, 9))
@pytest.mark.parametrize("kind", KINDS)
def test_burst_under_chaos(inst, kind, seed):
    """A burst of follow-ups, an interrupt in the middle, under one chaos seed."""
    n0 = uuid.uuid4().hex[:8]
    sid = inst.start_agent(kind, f"SLEEP 1 {n0}", name=f"burst-{kind}-{seed}-{n0}", chaos=seed)
    nonces = [uuid.uuid4().hex[:10] for _ in range(4)]
    messages = []
    for i, n in enumerate(nonces):
        messages.append(inst.send(sid, f"{'SLEEP 0.5' if i % 2 else 'ECHO'} {n}"))
        if i == 1:
            inst.cli("agent", "interrupt", sid, check=False)
    for message, n in zip(messages, nonces):
        code, out = inst.wait(sid, "--message", message, timeout=90)
        assert out["status"] in TERMINAL, out
        got = len(with_nonce(inst, n))
        assert got == 1 if out["status"] == "DONE" else got <= 1, (out["status"], got)
    pids = {r["pid"] for r in inst.receipts() if any(n in r.get("text", "") for n in [n0, *nonces])}
    inst.cli("agent", "stop", sid)
    assert not still_alive(pids, 15), "harness processes outlived `agent stop`"
