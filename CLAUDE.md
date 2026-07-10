# logic-mcp

A local MCP server (Swift daemon, MCP over stdio) that gives Claude end-to-end control of Logic Pro — a "cockpit" for collaborating with an agent on production and engineering work.

## Status (as of 2026-07-09)

- **Design spec approved:** `docs/superpowers/specs/2026-07-08-logic-mcp-design.md` — read it first, it is the source of truth for architecture and scope.
- **Brainstorming is done.** Do not re-open design questions already settled in the spec.
- **Phase 1 (MCUBridge) is DONE and committed** (`d50a2bb`), and this session fixed five bugs on top of it,
  all verified against **real Logic Pro**. 126 tests green.
- **Read `.superpowers/sdd/HANDOFF.md` first.** It carries the current state, the one dangerous bug, and the
  mental model. Per-task history + all findings are in `.superpowers/sdd/progress.md`; the smoke-checklist
  results are in `docs/integration-smoke.md`.
- **DO NOT CALL `set_plugin_param`.** `get_plugin_params` can return (and `set_plugin_param` can WRITE) the
  wrong track's plugin: Logic's plugin view follows the SELECTED track, and `.select(channel:)` has not
  always landed before we read. Same blind-press-then-read breaks `set_send`. This is the top priority.
- **The idea that explains most of this codebase's bugs:** MCU assignment buttons (`.assignPan`, and almost
  certainly `.assignSend`/`.assignPlugin`) are **toggles**, not mode selectors. Observe the LCD and press
  only when the observed state is wrong — see `MixerNavigator.normalizeSurface()`. And verify by reading the
  value Logic PRINTS, never by inferring it from an echo.
- **First real smoke run (2026-07-09): 9 pass / 3 fail / 1 caveat.** Failures are items 7, 10, 11 (one root
  cause, above). `undo_last` works once, then acts as a redo.
- **Next steps:** (1) fix the select/assignment-view race behind plugins and sends; (2) test whether
  `settle()` ever returns while the transport is rolling — Logic streams meters, and every mix tool depends
  on it; (3) `undo_last` redo + dB-vs-raw drift.
- **Later phases:** FileGateway (analysis + MIDI round-trip), then AXDriver (structural ops), then
  VisionVerifier + shadow-model integration.

## Architecture in one paragraph

Logic Pro has no scripting API, so control goes through layered side doors, each behind typed MCP tools: (1) **MCUBridge** — Mackie Control emulation over virtual CoreMIDI ports; bidirectional (Logic echoes track names, fader positions, param values back), covers mixing/transport/plugin params without window focus; (2) **AXDriver** — Accessibility-tree walking + a canonical key-command set for structural ops (create track, insert plugin, routing, quantize/flex); (3) **FileGateway** — audio from the `.logicx` bundle + exported stems for DSP analysis, MIDI file round-trip; (4) **VisionVerifier** — screenshots for verification only, never as actuator. A cached **shadow project model** serves state queries. Every tool returns verified ground truth. Distribution: notarized Developer ID direct download (Accessibility rules out the Mac App Store).

## Working preferences (carried over from prior sessions)

- **No auto-commits.** Never commit during implementation; the user controls when to commit.
- **Subagent-driven development.** Use subagent execution for implementation work without asking.
- **No re-export wrapper/shim files.** Update consumer imports directly.
- **Superpowers flow.** brainstorm → spec → writing-plans → subagent execution with review checkpoints. Specs/plans live in `docs/superpowers/`.
- During brainstorming, skip the browser visual companion — text is fine.
