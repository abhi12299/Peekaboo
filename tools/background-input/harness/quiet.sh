#!/bin/zsh
# Fork-only runs while the user leaves the Mac alone, on the same sums fair.sh gives the fork.
# Usage: quiet.sh [prefix]   (runs land in runs/<prefix>-fork-runN)
B=${0:A:h}; PREFIX=${1:-quiet}
FORK_SUMS=(531 86  847 62  394 57)
for i in 1 2 3; do
  X=${FORK_SUMS[2*i-1]} Y=${FORK_SUMS[2*i]} "$B/run.sh" fork native
  mv "$B/runs/fork-native" "$B/runs/$PREFIX-fork-run$i"
  python3 "$B/summarize.py" "$B/runs/$PREFIX-fork-run$i"
done
