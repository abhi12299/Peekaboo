#!/bin/zsh
# Launch the throwaway Chrome (own profile) with the proof page and hand the front app back.
# Run while holding the desktop lock.
PAGE=${0:A:h}/dashboard.html
PROFILE=/private/tmp/claude-501/pb-chrome-web-profile
FRONT_PID=$(lsappinfo info -only pid $(lsappinfo front) | sed -n 's/.*pid = \([0-9]*\).*/\1/p')
echo "front before: pid $FRONT_PID"
open -g -n -a "Google Chrome" --args --user-data-dir=$PROFILE --no-first-run --no-default-browser-check \
  --window-size=1000,800 --window-position=200,120 "file://$PAGE#regions"
for i in {1..40}; do
  NOW=$(lsappinfo info -only pid $(lsappinfo front) | sed -n 's/.*pid = \([0-9]*\).*/\1/p')
  if [ "$NOW" != "$FRONT_PID" ]; then
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $FRONT_PID) to true" >/dev/null
  fi
  sleep 0.1
done
echo "front after: pid $(lsappinfo info -only pid $(lsappinfo front) | sed -n 's/.*pid = \([0-9]*\).*/\1/p')"
pgrep -f "user-data-dir=$PROFILE" | head -1
