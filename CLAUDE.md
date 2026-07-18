# logic-mcp

A local MCP server (Swift daemon, MCP over stdio) that gives Claude end-to-end control of Logic Pro — a "cockpit" for collaborating with an agent on production and engineering work.

## Status (as of 2026-07-17)

- **Design specs:** `docs/superpowers/specs/2026-07-08-logic-mcp-design.md` (original architecture),
  `2026-07-10-ax-mixer-core-design.md` (Phase 2 boundary), `2026-07-13-ax-structural-ops-design.md` (Phase 3),
  `2026-07-15-plugin-control-suite-design.md` (Phase 4 Controls-view suite),
  `2026-07-17-plugin-write-path-actuation-design.md` (Phase 4 Plan 2a).
- **Read `.superpowers/sdd/HANDOFF.md` first.** It carries current state, the AX pivot, the recurring
  stale-handle lesson, and known limitations. Per-task history is in `progress.md`; real-Logic ground truth
  (mixer-slider ±1-nudge vs. **Controls-view slider absolute-set**, slider ranges, off-screen degradation, the
  two search popups, the plugin-window layout, and the Controls-view async timings) is in `ax-findings.md`.
  (All three live under `.superpowers/sdd/` and are gitignored — local only.)
- **Phases 1–3 + Phase 4 Plan 1 are SHIPPED to `main`; Phase 4 Plan 2a is in PR #10** — every phase live-verified
  on real Logic. Phase 1 = MCUBridge; Phase 2 = AX Mixer Core; Phase 3 = AX Structural Ops (+ fix PRs #3–#7);
  **Phase 4 Plan 1 = plugin Controls-view READ engine (#9); Phase 4 Plan 2a = plugin WRITE path** (`set_plugin_param`
  converge, `set_plugin_option`, `press_plugin_control`, undo) — **228 tests green, live smoke passes incl. a
  verified third-party (SketchCassette II) write.**
- **THE PIVOT:** Logic 12.3's mixer is fully **Accessibility-addressable AND AX writes land with Logic in the
  BACKGROUND** (no focus stolen). **AX is the primary no-focus read/write + self-verification path** for the
  mixer and structural ops; MCU is retained for transport, metering, and as a no-Accessibility fallback.
- **THE recurring bug class:** after ANY structural mutation, a handle/read captured beforehand is STALE
  (Logic re-renders strips; routing to a fresh bus inserts an Aux and shifts indices). ALWAYS re-resolve BY
  NAME (a fresh mixer walk) + settle-poll; never trust an AX return code across a mutation. Search-driven
  popups (insert_plugin, set_output) attach as a SIBLING of the strips and carry an `AXSearchField` —
  `AXSetValue` on it filters with no keystrokes; then pick the EXACT case-insensitive title match.
- **KEY real-Logic fact — TWO slider families, opposite semantics:** on the **MIXER** volume fader + pan knob,
  `AXUIElementSetAttributeValue` **nudges ±1 toward the target** (converge via `AXBridge.nudgeToRaw` /
  `axConvergeVolume` — do NOT "fix" into a single set). But on a **plugin Controls-view slider**, AXSetValue is
  **ABSOLUTE + linear** (proven live: Low Shelf Gain raw 0→−24 dB, 240→0, 480→+24) — so `set_plugin_param`
  **binary-searches the raw against the row's display string** (`AXBridge.convergeAdaptive`, default `.absolute`).
  The Plan-1 "railing" bug was the ±1 model applied to an absolute-set slider, oscillating rail-to-rail.
- **Controls-view async timings (all handled by settle-polls; the synchronous test fakes can't model them —
  they were only caught by the live smoke):** the AXTable populates async after the view switch
  (`settledControlTable`); a positive dB display is `+N dB` (`PluginDisplay` must accept a leading `+`); an enum
  popup's menu appears ~100 ms after the press and its selected value updates ~400 ms after the item press
  (`AXMenuDriver.selectEnumChoice` settle-polls both). Plugin-slider writes register NO Logic Edit▸Undo entry,
  so the three setters self-journal `undoArguments` and reverse via `undo_last`, never `undo_structural`.
- **AX cannot set Logic's track SELECTION** (`Fixtures/ax/selection.txt`). So `delete_track` is DISABLED (would
  delete the wrong track), `rename_track`/`checkpoint` are deferred, `select_track` was REMOVED, and `set_send`
  returns a structured "not available via AX" error. All unfixable without focus-stealing CGEvent clicks.
- **Open limitations (recorded, not bugs):** off-screen strips degrade `output`/`volumeDB` reads (names are
  fixed via the child name field; output/volume have no alternate AX source — needs a design call:
  scroll-into-view vs. last-known-good); no timeline/arrange addressing (regions, playhead, locators, MIDI).
- **NEXT PHASE (not started):** **Phase 4 Plan 2b** — the deferred remainder of the plugin-control suite: a
  persisted **learned-profile store**, `load_instrument` (software-instrument slot), preset load/list, and
  `learn_plugin`. Then two adjacent buckets: **header plugin controls** (bypass/compare — not addressable yet,
  they live outside the Controls table), and the **arrange/timeline** bucket (Phase 4a playhead/locators/regions,
  4b MIDI). Smaller recorded follow-ups from Plan 2a (in `progress.md`): a shared `resolveControl` DRY extraction,
  a transient `no plugin window` on software-instrument slots, and a few test-coverage gaps.

## Architecture in one paragraph

Logic Pro has no scripting API, so control goes through layered side doors, each behind typed MCP tools: (1) **MCUBridge** — Mackie Control emulation over virtual CoreMIDI ports; bidirectional (Logic echoes track names, fader positions, param values back), covers mixing/transport/plugin params without window focus; (2) **AXDriver** — Accessibility-tree walking + a canonical key-command set for structural ops (create track, insert plugin, routing, quantize/flex); (3) **FileGateway** — audio from the `.logicx` bundle + exported stems for DSP analysis, MIDI file round-trip; (4) **VisionVerifier** — screenshots for verification only, never as actuator. A cached **shadow project model** serves state queries. Every tool returns verified ground truth. Distribution: notarized Developer ID direct download (Accessibility rules out the Mac App Store).

## Working preferences (carried over from prior sessions)

- **No auto-commits.** Never commit during implementation; the user controls when to commit.
- **Subagent-driven development.** Use subagent execution for implementation work without asking.
- **No re-export wrapper/shim files.** Update consumer imports directly.
- **Superpowers flow.** brainstorm → spec → writing-plans → subagent execution with review checkpoints. Specs/plans live in `docs/superpowers/`.
- During brainstorming, skip the browser visual companion — text is fine.
