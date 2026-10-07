# Acceptance suite

An outcome-only conformance suite for the agent terminal, in the style of a TCK or of
web-platform-tests. It treats a build as a black box. It drives the build through:
- its CLI;
- files and processes;
- the macOS accessibility tree.

A small per-build adapter (a target file) connects it to any implementation.

| File | What it is |
|---|---|
| `REQUESTS.md` | The user's requests, verbatim. They win when anything disagrees. |
| `SPEC.md` | Requirements as observable outcomes. Each has an ID, a check kind ([A] automated, [W] written) and a priority tier (fixed, core, negotiable). |
| `CLI.md` | The CLI contract that agents and scripts rely on. |
| `TEST_INTERFACE.md` | What a build must provide to be testable, the target file format, and how to run the suite. |
| `tests/` | pytest tests. Each is tagged `@pytest.mark.req("ID", …)`. `harness.py` is the black-box harness. |
| `fakes/` | Fake Claude Code and Codex harnesses: deterministic, with chaos mode, hostile triggers and delivery receipts. See `fakes/README.md`. |
| `reference/` | Research notes on the real harnesses' programmatic interfaces, with recorded logs and the probe scripts that produced them. |
| `CHECKS.md`, `checks/` | Written (approval) checks for look and feel, and the script that collects their evidence. |
| `targets/` | Target files: one per build under test. |

What the tests use:
- **Property-based tests** (`tests/test_chaos.py`, Hypothesis) generate operation sequences against
  fakes that vary timing and event order. They check invariants: exactly-once delivery, nothing
  pending forever, truthful statuses, no leftover processes.
- **Fault injection:** the fakes crash, hang, ignore SIGTERM, spawn detached children, flood output
  and print garbage on request.
- **Traceability:** every run writes `results/traceability.md`, one row per requirement with its tier,
  its tests and their status.

Quick start: see "Running" in `TEST_INTERFACE.md`.
