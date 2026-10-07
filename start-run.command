#!/bin/zsh -l
# Starts the unsupervised build run in this folder (opened in Terminal.app, which has the
# Accessibility permission the UI tests need).
cd "$(dirname "$0")"
exec claude --dangerously-skip-permissions "Read BRIEF.md in this folder and carry it out."
