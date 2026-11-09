# Performance stress test

`umi_perf.py` runs an isolated Umi (its own `UMI_STATE_DIR`), drives it hard through the `umi` CLI and the
fake agents, and records per scenario: hangs and hitches (`xctrace`, plus the app's own recorder in
`<state>/logs/perf`), CPU, wakeups, memory (phys_footprint, also the editor's WebKit processes), and how
long CLI calls take to answer. It opens windows: run it on the other Mac, under the screen lock.

```sh
cd acceptance
lockf -k ~/umi-screen.lock uv run python perf/umi_perf.py [--app path/to/Umi.app]   # ~15 min
uv run python perf/umi_perf.py --scenarios panes,flood,idle --idle-secs 60          # a subset (start with panes)
lockf -k ~/umi-screen.lock uv run python perf/umi_perf.py --soak 4                  # loop for 4 hours
```

Results go to `logs/perf/<time>/` at the repository root: `summary.md` (the table), `summary.json`,
`samples.jsonl` (one resource sample a second), `cli.jsonl` (every CLI call and its time), `recorder.jsonl`,
and `traces/` (the `.trace` files and their exported tables). `--help` lists the options.
`baseline-*.md` are earlier summaries to compare a fix against.
