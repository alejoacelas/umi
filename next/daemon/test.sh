#!/bin/bash
# Build, then run the headless tests (each uses its own temp UMI_NEXT_STATE_DIR).
# Extra arguments go to pytest, e.g. ./test.sh -k latency
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/build.sh"
cd "$here/tests"
exec uv run --no-project --with pytest --with pyte python -m pytest -v -p no:cacheprovider "$@" test_daemon.py
