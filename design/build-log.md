# Build log

One section per step of [plan.md](plan.md): status, what changed, what was verified and how, and
the choices Alejo should check.

## Step 0: start from Warp parity

**Status:** merged into main (`51ffb464f`).

- `origin/warp/parity` (`4d875c54f`, the 0.9.0 code plus the build-signing fix that release
  needed) merged into main with no conflicts.
- Verified: the merge had no conflicts. The only code on main that `warp/parity` lacked is
  `ad31dda32` (comment boxes grow), one Swift file. The suite runs on the merged tree in step 1.

**For Alejo to check:** the `v0.9.0` tag on GitHub points at `cc9933747` (main's head when it was
published: the design documents), not at the `warp/parity` commit the release was built from,
because `release.sh` lets `gh release create` tag the default branch. The binaries are right; the
tag's source isn't. Releases from main after this step don't have the problem.
