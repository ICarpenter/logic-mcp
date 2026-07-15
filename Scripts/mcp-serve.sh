#!/bin/sh
# MCP entry point for logic-mcp — ALWAYS launch the current code.
#
# `logic-mcp serve` is a long-lived process: the MCP client starts it once and keeps it for the
# session. Pointing the client straight at .build/debug/logic-mcp means a `swift build` swaps the
# binary on disk while the running process happily keeps executing its old in-memory code. That
# has already cost us 18 hours of a server advertising deleted tools and hiding new ones. Building
# HERE, on every connect, makes the process that starts and the tree on disk the same code by
# construction. (`ping` reports staleness for the case where you rebuild mid-session — see
# PingTool.swift.)
set -e

# Run from the repo root regardless of where the client invokes us from.
cd "$(dirname "$0")/.."

# >&2 is load-bearing: stdout IS the MCP JSON-RPC stdio channel. A single stray line of build
# chatter on stdout ("Compiling…", "Build complete!") corrupts the protocol handshake. All build
# output must go to stderr, where the client treats it as logs.
swift build >&2

# `set -e` above is also load-bearing: if the build FAILS we must die loudly here rather than fall
# through and exec a stale binary. A failed connection you can see beats a silently obsolete server.

# `exec` replaces this shell with the daemon, so stdio and signals (SIGTERM/SIGINT from the client)
# pass straight through to it instead of being trapped by a parent shell.
exec .build/debug/logic-mcp serve
