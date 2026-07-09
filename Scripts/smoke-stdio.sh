#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=".build/debug/logic-mcp"
OUT=$( (printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ping","arguments":{}}}'; sleep 1) | "$BIN" serve )
if echo "$OUT" | grep -q '\\"ok\\":true'; then
  echo "SMOKE PASS"
else
  echo "SMOKE FAIL"; echo "$OUT"; exit 1
fi
