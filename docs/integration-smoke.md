# Integration smoke — real Logic Pro

Manual gate. Run on every Logic Pro update and before tagging a release.
Prereqs: Logic Pro open with a test project of ≥10 named tracks; daemon built
(`swift build`).

## One-time control-surface setup
1. Run `.build/debug/logic-mcp capture --out /tmp/setup.jsonl` (creates the
   virtual ports; leave it running).
2. Logic → Control Surfaces → Setup… → New → Install… → Mackie Designs |
   Mackie Control → Add. Set Output Port and Input Port to "logic-mcp MCU".
3. Confirm the transcript records LCD SysEx (track names) — that's Logic
   adopting the surface. Ctrl-C.

## Smoke checklist (via any MCP client pointed at `.build/debug/logic-mcp serve`)
| # | Call | Verify in Logic |
|---|------|-----------------|
| 1 | `ping` | returns ok |
| 2 | `refresh_state` | returned names match the project's first-7-chars track names, in order |
| 3 | `set_volume {track, db: -6}` | channel fader moves; Logic shows −6.0 ±0.5 dB |
| 4 | `set_volume {track, delta: +2}` | fader lands at −4.0 ±0.5 dB; tool returns ≈ −4.0 |
| 5 | `set_mute {on: true}` then `{on: false}` | mute button lights, then clears; idempotent re-call is a no-op |
| 6 | `set_pan {position: -30}` | channel strip shows ≈ L30 (see pan note, Task 12) |
| 7 | `set_send {bus, level: 90}` | send knob moves; tool's `level` matches Logic's readout |
| 8 | `play` / `stop` | transport runs/stops; tool returns verified state |
| 9 | `record` without confirm | refuses (structured error) |
| 10 | `get_plugin_params` on a Channel EQ | param names/displays match the plugin header readouts |
| 11 | `set_plugin_param` | knob moves in the plugin UI; returned display matches |
| 12 | `undo_last {n: 3}` | the last three mix moves visibly revert |
| 13 | Background test: hide Logic behind another app, repeat #3 | still works (MCU needs no focus) |

Record outcomes in this file's log section with the Logic version.

## Fader calibration (updates `FaderCurve.anchors`)
1. `logic-mcp capture --out /tmp/sweep.jsonl` with the surface installed.
2. In Logic, drag one fader slowly to each of: +6, +3, 0, −6, −12, −21, −30,
   −42, −54, −72, then to −∞. Type exact values into the volume field
   (double-click it) so each is precise; pause ~1s between values.
3. For each pause, take the last `E0`-status "in" line, decode raw = hh<<7|ll,
   and replace the matching `FaderCurve.anchors` entry.
4. `swift test --filter FaderCurveTests` must still pass (monotonic, round-trip).

## Send/plugin transcript fixtures
While captured: press SEND and PLUG-IN assignment modes from the tool flows
(`set_send`, `get_plugin_params`) and save the transcripts to
`Tests/LogicMCPCoreTests/Fixtures/` (e.g. `send_page.jsonl`,
`plugin_edit.jsonl`). If real layouts differ from FakeLogic's, update
FakeLogic to match the transcript and re-run the suite.

## Log
| Date | Logic version | Result | Notes |
|------|---------------|--------|-------|

## Phase 1 deferred findings to validate on real Logic

Findings discovered/deferred during Phase 1 development against FakeLogic;
the real-Logic smoke above must specifically check each of these.

- [ ] **Handshake response bytes.** The MCU codec models the host-connection
  reply as serial-only, and the daemon never validates the 4-byte
  challenge-response (it also sets `connected=true` on the first LCD write as
  a fallback). Verify real Logic actually engages the surface under this
  lenient handshake. If it does **not** engage: capture the
  `F0 00 00 66 14 02 …` reply during setup and check whether the 4-byte
  challenge-response must be computed and echoed back before Logic will
  adopt the surface.
- [ ] **Fader curve calibration.** `FaderCurve.anchors` are v0 approximations;
  the raw↔dB round-trip error is largest in the **upper** part of the curve
  (raw ≈ 12472–16091, i.e. above unity/0 dB). When running the fader
  calibration sweep above, sample that upper region more densely than the
  listed values (e.g. add intermediate points between 0 and +6) so the
  anchors are well-constrained there, not just at the listed dB steps.
- [ ] **`set_pan` verification strength.** `set_pan` currently resolves on the
  **first** V-Pot ring echo of a multi-tick sweep, not the sweep's final
  settled position. During smoke item #6, confirm pan actually **lands** at
  the requested position on real Logic (not just that the ring moved), and
  note whether the coarse V-Pot ring resolution can or can't confirm the
  exact landing value — this is a candidate for a settle-after-sweep
  hardening pass if real Logic shows drift/overshoot.
- [ ] **Plugin empty-slot heuristic.** `get_plugin_params` / `set_plugin_param`
  detect an empty slot by "LCD top line unchanged after `.vpotPress(slot)` ⇒
  no plugin in that slot." Validate this against real Logic: call
  `get_plugin_params` on a track's empty plugin slot and confirm it returns a
  structured error rather than fabricated params. Real Logic may render an
  empty slot differently (e.g. an explicit "No Plugin" label) — the
  heuristic still works as long as that view is distinguishable from the
  plugin-select view; confirm this is the case.
- [ ] **`set_mute`/`set_solo` skip-path trusts an unsynced LED cache.**
  `set_mute`/`set_solo` skip the button press (and the echo wait) when the
  cached surface LED already matches the requested state, then return that
  cached value **without** MCU verification. The LED cache is only populated
  by LED echoes seen this session — it is **not** synced when banking to a
  channel, so a track already muted/soloed before the daemon connected has a
  stale ("not on") cache. Real-Logic check:
  1. Mute a track manually in Logic, then call `set_mute(on:false)` —
     confirm it actually unmutes and the report matches (today it may skip
     and falsely report `mute:false` while the track is still muted).
  2. Call `set_mute(on:true)` on that already-muted track — confirm
     behavior.
  3. If Logic emits mute/solo LED states when the surface banks to a channel
     (as it does for faders), the fix is to sync LED state on bank in
     `MixerNavigator` (mirroring `syncFadersFromSurface`) and model it in
     `FakeLogic.sendBankLCD` — confirm whether Logic actually emits these on
     bank before doing that work.
- [ ] **No serialization around the shared bank-then-operate critical
  section.** Each mix/send/plugin tool resolves+banks to a channel then acts
  on it; nothing serializes the compound sequence across concurrent
  `tools/call` requests, so two concurrent calls could interleave (tool A
  banks to 0-7, suspends; tool B re-banks to 8-15; A's move lands on the
  wrong track). Harmless under sequential single-agent use. Before any
  multi-client/pipelined use:
  1. Confirm whether the swift-sdk `Server`/`StdioTransport` dispatches
     `tools/call` serially.
  2. If not, add a daemon-level serialization guard around tool invocation.
  3. Note: `undo_last` re-enters the registry (it calls other tools), so a
     naive non-reentrant lock would **deadlock** — any guard must be
     reentrant-safe or scoped to exclude the undo replay path.
