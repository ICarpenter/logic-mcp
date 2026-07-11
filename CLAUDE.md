# logic-mcp

A local MCP server (Swift daemon, MCP over stdio) that gives Claude end-to-end control of Logic Pro — a "cockpit" for collaborating with an agent on production and engineering work.

## Status (as of 2026-07-10)

- **Design spec approved:** `docs/superpowers/specs/2026-07-08-logic-mcp-design.md` is the original architecture.
  **Phase 2 redraws one boundary** — see `docs/superpowers/specs/2026-07-10-ax-mixer-core-design.md`.
- **Read `.superpowers/sdd/HANDOFF.md` first.** It carries current state, the AX pivot, and known limitations.
  Per-task history + all findings are in `.superpowers/sdd/progress.md`; real-Logic ground truth (the crucial
  `AXSetValue` ±1-nudge discovery, slider ranges, plugin/send layout) is in `.superpowers/sdd/ax-findings.md`.
- **Phase 1 (MCUBridge) DONE** (`d50a2bb` + fixes). **Phase 2 (AX Mixer Core) code-complete on branch
  `feat/ax-mixer-core`**, 141 tests green, reviewed per-task + whole-branch. **Real-Logic smoke still PENDING.**
- **THE PIVOT:** we discovered Logic 12.3's mixer is fully **Accessibility-addressable AND AX writes land with
  Logic in the BACKGROUND** (no focus stolen) — which was supposedly MCU's only edge. So **AX is now the primary
  no-focus read/write + self-verification path for the mixer**; MCU is retained for transport, metering, and as
  a no-Accessibility fallback. `set_volume`/`set_pan`/`set_mute`/`set_solo`/`refresh_state`/`get_*` all read/write
  via AX now (exact dB from a title string, direct pan value, `val=on/off` — none of MCU's calibration/echo/toggle
  hazards).
- **The dangerous wrong-track bug is RESOLVED, not fixed** — `get_plugin_params`/`set_plugin_param` address the
  plugin per-strip via the Accessibility tree (no "selected track" to race), so `set_plugin_param` is safe to call.
  The old MCU plugin/send paths are retired (zero callers). `set_send` currently returns a structured
  "not available via AX" error (sends aren't cleanly AX-settable yet — deferred).
- **KEY real-Logic fact (see ax-findings.md):** `AXUIElementSetAttributeValue` on Logic sliders **nudges ±1 toward
  the target, it does NOT set absolutely.** Every value write CONVERGES by repeated nudging (`AXBridge.nudgeToRaw`
  for pan/plugins; `axConvergeVolume` for volume via the dB title). Do not "fix" this into a single set.
- **Known limitations to verify/fix in the real-Logic smoke:** (1) `set_automation_mode` (last MCU tool) can
  refresh the current bank's `volumeDB` from the MCU curve estimate, drifting AX-accurate values; (2)
  `get/set_plugin_param` can target the WRONG SLOT if a plugin window for that track is already open (windows are
  keyed only by track title); (3) the shadow model never re-arms `staleAt`, so a hand-edit in Logic reads stale
  until `refresh_state`. Full smoke checklist: `docs/integration-smoke.md`.
- **Later phases:** Phase 3 = AX structural ops (`create_track`, `insert_plugin`, routing, quantize, `checkpoint`)
  + a minimal VisionVerifier (the focus-stealing, dialog/keystroke half). Then FileGateway (analysis + MIDI).

## Architecture in one paragraph

Logic Pro has no scripting API, so control goes through layered side doors, each behind typed MCP tools: (1) **MCUBridge** — Mackie Control emulation over virtual CoreMIDI ports; bidirectional (Logic echoes track names, fader positions, param values back), covers mixing/transport/plugin params without window focus; (2) **AXDriver** — Accessibility-tree walking + a canonical key-command set for structural ops (create track, insert plugin, routing, quantize/flex); (3) **FileGateway** — audio from the `.logicx` bundle + exported stems for DSP analysis, MIDI file round-trip; (4) **VisionVerifier** — screenshots for verification only, never as actuator. A cached **shadow project model** serves state queries. Every tool returns verified ground truth. Distribution: notarized Developer ID direct download (Accessibility rules out the Mac App Store).

## Working preferences (carried over from prior sessions)

- **No auto-commits.** Never commit during implementation; the user controls when to commit.
- **Subagent-driven development.** Use subagent execution for implementation work without asking.
- **No re-export wrapper/shim files.** Update consumer imports directly.
- **Superpowers flow.** brainstorm → spec → writing-plans → subagent execution with review checkpoints. Specs/plans live in `docs/superpowers/`.
- During brainstorming, skip the browser visual companion — text is fine.
