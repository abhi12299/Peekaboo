#!/bin/zsh
# Codex and the fork take turns, each on its own 3-digit x 2-digit sums, so no run starts with its own answer already on
# Calculator's display (the display persists between launches). Usage: fair.sh [prefix]   (runs land in runs/<prefix>-<agent>-runN)
B=${0:A:h}; PREFIX=${1:-fair}   # CODEX_MODEL overrides the Codex model (default gpt-6.1-sol)
CODEX_SUMS=(736 58  925 47  618 73)
FORK_SUMS=(531 86  847 62  394 57)
for i in 1 2 3; do
  for agent in codex fork; do
    if [[ $agent == fork ]]; then X=${FORK_SUMS[2*i-1]} Y=${FORK_SUMS[2*i]}; else X=${CODEX_SUMS[2*i-1]} Y=${CODEX_SUMS[2*i]}; fi
    X=$X Y=$Y CODEX_MODEL=${CODEX_MODEL:-gpt-6.1-sol} "$B/run.sh" $agent native
    mv "$B/runs/$agent-native" "$B/runs/$PREFIX-$agent-run$i"
    python3 "$B/summarize.py" "$B/runs/$PREFIX-$agent-run$i"
  done
done
