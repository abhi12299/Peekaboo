#!/bin/zsh
# Copy the fork's debug CLI to bin/peekaboo and sign it with the Apple Development
# certificate, so macOS keeps its Accessibility / Screen Recording grants across rebuilds.
# Build first: swift build -j 2 in Peekaboo/Apps/CLI. Restart the MCP server (/mcp) afterwards.
set -euo pipefail
HERE=${0:A:h}
SRC="$HERE/../Peekaboo/Apps/CLI/.build/out/Products/Debug/peekaboo"
cp "$SRC" "$HERE/peekaboo.tmp"
codesign --force --sign E05928BC1CC52FD1A3742CAB305F7BA74A4ABD62 --identifier boo.peekaboo.peekaboo "$HERE/peekaboo.tmp"
mv "$HERE/peekaboo.tmp" "$HERE/peekaboo"
codesign -dvv "$HERE/peekaboo" 2>&1 | grep -E '^(Authority=Apple Development|TeamIdentifier)'
"$HERE/peekaboo" --version
