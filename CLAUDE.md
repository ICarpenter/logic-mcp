# logic-mcp

A local MCP server (Swift daemon, MCP over stdio) that gives Claude end-to-end control of Logic Pro — a "cockpit" for collaborating with an agent on production and engineering work.

## Status (as of 2026-07-15)

- **Design specs:** `docs/superpowers/specs/2026-07-08-logic-mcp-design.md` (original architecture),
  `2026-07-10-ax-mixer-core-design.md` (Phase 2 boundary), `2026-07-13-ax-structural-ops-design.md` (Phase 3).
- **Read `.superpowers/sdd/HANDOFF.md` first.** It carries current state, the AX pivot, the recurring
  stale-handle lesson, and known limitations. Per-task history is in `progress.md`; real-Logic ground truth
  (the `AXSetValue` ±1-nudge, slider ranges, off-screen degradation, the two search popups, the plugin-window
  layout) is in `ax-findings.md`. (All three live under `.superpowers/sdd/` and are gitignored — local only.)
- **Phases 1–3 are SHIPPED to `main`; Phase 3 is LIVE-VERIFIED end-to-end** — the full `smoke --structure`
  passes (create_track → set_output → insert_plugin → undo×N → net-zero, focus never stolen), **198 tests green.**
  Phase 1 = MCUBridge; Phase 2 = AX Mixer Core; Phase 3 = AX Structural Ops (+ five 2026-07-15 fix PRs #3–#7).
- **THE PIVOT:** Logic 12.3's mixer is fully **Accessibility-addressable AND AX writes land with Logic in the
  BACKGROUND** (no focus stolen). **AX is the primary no-focus read/write + self-verification path** for the
  mixer and structural ops; MCU is retained for transport, metering, and as a no-Accessibility fallback.
- **THE recurring bug class:** after ANY structural mutation, a handle/read captured beforehand is STALE
  (Logic re-renders strips; routing to a fresh bus inserts an Aux and shifts indices). ALWAYS re-resolve BY
  NAME (a fresh mixer walk) + settle-poll; never trust an AX return code across a mutation. Search-driven
  popups (insert_plugin, set_output) attach as a SIBLING of the strips and carry an `AXSearchField` —
  `AXSetValue` on it filters with no keystrokes; then pick the EXACT case-insensitive title match.
- **KEY real-Logic fact:** `AXUIElementSetAttributeValue` on Logic sliders **nudges ±1 toward the target, it
  does NOT set absolutely.** Value writes CONVERGE by repeated nudging (`AXBridge.nudgeToRaw` for pan/plugins;
  `axConvergeVolume` for volume via the dB title). Do not "fix" this into a single set.
- **AX cannot set Logic's track SELECTION** (`Fixtures/ax/selection.txt`). So `delete_track` is DISABLED (would
  delete the wrong track), `rename_track`/`checkpoint` are deferred, `select_track` was REMOVED, and `set_send`
  returns a structured "not available via AX" error. All unfixable without focus-stealing CGEvent clicks.
- **Open limitations (recorded, not bugs):** off-screen strips degrade `output`/`volumeDB` reads (names are
  fixed via the child name field; output/volume have no alternate AX source — needs a design call:
  scroll-into-view vs. last-known-good); no timeline/arrange addressing (regions, playhead, locators, MIDI).
- **NEXT PHASE (not started — needs a brainstorm/design pass):** the **plugin-control tool suite** — operate a
  plugin's controls, not just insert it: press named buttons (a Compressor circuit model like "Vintage Opto"),
  select presets/switches (`AXPopUpButton`), correlate ANONYMOUS sliders to their separate label `AXTextField`s,
  and unit-aware `set_plugin_param` (dB/ms/ratio via captured per-param calibration). Adjacent unphased gaps:
  instrument-slot loading, and the arrange/timeline bucket (Phase 4a playhead/locators/regions, 4b MIDI).

## Architecture in one paragraph

Logic Pro has no scripting API, so control goes through layered side doors, each behind typed MCP tools: (1) **MCUBridge** — Mackie Control emulation over virtual CoreMIDI ports; bidirectional (Logic echoes track names, fader positions, param values back), covers mixing/transport/plugin params without window focus; (2) **AXDriver** — Accessibility-tree walking + a canonical key-command set for structural ops (create track, insert plugin, routing, quantize/flex); (3) **FileGateway** — audio from the `.logicx` bundle + exported stems for DSP analysis, MIDI file round-trip; (4) **VisionVerifier** — screenshots for verification only, never as actuator. A cached **shadow project model** serves state queries. Every tool returns verified ground truth. Distribution: notarized Developer ID direct download (Accessibility rules out the Mac App Store).

## Working preferences (carried over from prior sessions)

- **No auto-commits.** Never commit during implementation; the user controls when to commit.
- **Subagent-driven development.** Use subagent execution for implementation work without asking.
- **No re-export wrapper/shim files.** Update consumer imports directly.
- **Superpowers flow.** brainstorm → spec → writing-plans → subagent execution with review checkpoints. Specs/plans live in `docs/superpowers/`.
- During brainstorming, skip the browser visual companion — text is fine.
