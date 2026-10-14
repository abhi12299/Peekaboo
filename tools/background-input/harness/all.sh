#!/bin/zsh
B=${0:A:h}
for r in "codex native" "peekaboo native" "codex browser" "peekaboo browser"; do "$B/run.sh" ${=r}; echo "done $r $(cat $B/runs/${r// /-}/timing.txt)"; sleep 5; done
