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

## Phase 2 (AX Mixer Core) — what changed for this checklist (run against branch `feat/ax-mixer-core`)

The mixer tools now go through **Accessibility**, not MCU. Rebuild, reconnect `serve` (`/mcp`), open a
clean Mixer window, and run the checklist with **Logic in the BACKGROUND** (another app frontmost) —
verifying no-focus operation is now a first-class check, not just item 13. Updated expectations:

- **Items 3–6, 10–11 (volume/pan/mute/solo/plugin):** now AX-sourced. `set_volume` returns exact dB
  (`source:"ax"`), not a curve estimate. `get_plugin_params`/`set_plugin_param` are per-strip and safe
  (the old wrong-track hazard is gone) — **run `get_plugin_params` 5× and confirm the SAME track/params
  every time.**
- **Item 7 (`set_send`):** now returns a structured `layer:"ax"` "not available via AX in this release"
  error by design (sends aren't cleanly AX-settable yet). PASS = the structured error, not a working send.
- **New AX-specific checks (from the whole-branch review — these are the residual risks):**
  1. **Wrong-slot plugin:** open plugin A on a track in Logic's UI, then `get_plugin_params` for a
     *different* slot on the same track → confirm it returns the requested slot, not A's params.
  2. **Automation volume clobber:** `refresh_state`, note a track's `volumeDB`, `set_automation_mode` on it,
     `refresh_state` again → does its `volumeDB` drift to a curve estimate?
  3. **Mute-by-hand stale:** mute a track in Logic's UI, then `get_track` WITHOUT `refresh_state` → expect
     it reports the stale value (`stale:false`) until `refresh_state`; decide if acceptable.
  4. **Silence glyph:** drive a fader to −∞ and capture the exact `volume fader level` title string.
  5. **Plugin display:** `get_plugin_params` on a Channel EQ → confirm `display` shows "0.0 dB"/"1000 Hz",
     not raw engineering numbers.
  6. **Convergence:** `set_volume` to several dB targets and `set_pan` full-range → lands within tolerance
     without visibly slow/stepping behavior.

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
| 2026-07-16 | 12.3 (mcp_test) | **Read path PASS · Write path FAIL** | `get_plugin_params` (Controls view) fully works, no-focus held; `set_plugin_param` drives sliders to the RAIL. Actuation model wrong for Controls-view sliders — write path needs a rework next phase. Detail below. |
| 2026-07-11 | 12.3 (mcp_test, 20 strips) | AX smoke PASS (3 bugs found+fixed live) | Ran via `logic-mcp smoke` (drives the real AX tools, Logic backgrounded). See detail below. |
| 2026-07-09 | (mcp_test, 20 strips) | 9 pass / 3 fail / 1 caveat | Items 1-6, 8, 9, 13 pass. 7 + 10 + 11 FAIL (assignment-view race). 12 passes once, then acts as redo. |

### 2026-07-16 Phase 4 Plan 1 (Controls-view engine) smoke detail (Logic 12.3, branch `feat/plugin-control-core`)

Manual smoke of the plugin-control **read** and **write** tools on `vox`'s stock **Channel EQ**, Logic backgrounded (iTerm2 frontmost throughout).

**READ PATH — production-ready.**
- `get_plugin_params(vox, slot 0)` returned **all 44 Channel EQ controls** via Logic's generic Controls view: sliders (`Low Shelf Gain` = `0.0 dB`, `Peak 1 Frequency` = `100 Hz`), toggles (`Low Cut On/Off`), and popups (`Low Cut Slope` = `12 dB/Oct`) — every one **named, typed, and unit-valued**, `opaque:false`.
- **switch-to-Controls timing held** (spec Open-Risk #3): the fixed 40 ms sleeps sufficed here; the table read cleanly on the first try.
- **NO-FOCUS CONFIRMED** (Open-Risk #3, focus half): opening the plugin window + pressing the `view` AXMenuButton to switch views did **not** bring Logic forward — iTerm2 stayed frontmost. The one genuinely new backgrounded AX interaction is safe.

**WRITE PATH — broken; needs a real-Logic rework (next phase).**
- `set_plugin_param(vox, 0, "Low Shelf Gain", "-3 dB")` drove the slider to **`+24.0 dB`** (`verified:false`), reproduced **deterministically from a clean 0 dB start**. The normalized path (`value:0.5`) also failed to move it off the rail.
- **Root cause, decoded from raw values** (`axdump`): the Controls-view Gain slider is raw **0…480, linear, NOT inverted** — `raw 480 = +24 dB` (max), `240 = 0 dB` (center), `0 = −24 dB` (min), i.e. `dB = (raw−240)/10`, range **±24 dB**. So `+24` is simply the **ceiling**: the converger drove the slider to its max. `setNumber(lo=0)` should nudge the raw *down* from 240 toward 0, but the raw climbed 240 → 480.
- **The ±1-nudge-toward-target model does NOT hold for generic Controls-view Cocoa sliders.** That model (ax-findings.md) was validated on the **mixer volume fader + pan knob** — different controls. `AXSetValue` on the auto-generated Controls-table slider actuates differently (pushes to a rail regardless of target). The converger's **actuation primitive**, not just its direction, is wrong for plugin sliders. It fails *safe* (`verified:false`, no fabricated success), but cannot set a value.
- **`AXSetValue` on a Controls-view slider does NOT register in Logic's undo history** — so param writes aren't undoable. Cleanup caution: a follow-up `undo_structural` therefore hit the *next* stack item ("Undo Create Track") and removed a track; restore via **File ▸ Revert to Saved** (both the stuck value and the undone track are unsaved in-memory changes).
- **Toggles report `settable:false`** in Controls view (they're press-only, not `AXSetValue`) — a note for Plan 2's `press_plugin_control`.

**Fix for the next phase (write-path rework):** characterize how a Controls-view slider actually moves under AX — is `AXSetValue(v)` absolute on a different scale? do `AXIncrement`/`AXDecrement` step actions work? is there a fixed step? — then rewrite `AXBridge.convergeToDisplay` to that reality (direction probe at minimum; likely switch actuation to increment/decrement). Until then, **`set_plugin_param` is not trustworthy; `get_plugin_params` is.**

### 2026-07-11 AX Mixer Core smoke detail (Logic 12.3, branch `feat/ax-mixer-core`)
Driven by the new `logic-mcp smoke` subcommand (real `Daemon` + `SystemAXProvider`, Logic in the background the whole time).
- **NO-FOCUS CONFIRMED** — frontmost stayed iTerm2 before/after; Logic never came forward through every read and write. This is the phase's central thesis, proven on real Logic.
- **refresh_state** — all 20 tracks, FULL untruncated names, real dB, pan, and output routing; `pedla steel 5` correctly at pan 30. (MCU truncation + bank geometry gone.)
- **set_volume** `db:-6`→-6.0, `delta:+2`→-4.0, restore→within 0.1 dB (curve-free dB-title convergence).
- **set_pan** `-30`→-30 exact. **set_mute** on/off + idempotent, confirmed.
- **set_send** → structured "not available via AX" error (by design; sends retired from the wrong-track MCU path, deferred).
- **get_plugin_params** → all 25 real Channel EQ params; SAME track/params on repeat (no wrong-*track* hazard).
- **Three bugs found by the smoke (fake couldn't catch) and FIXED + re-verified live:**
  1. `set_mute`/`set_solo` "not confirmed" — `AXPress` updates the value async; immediate re-read was stale. Fixed with a poll-after-press.
  2. Wrong-SLOT plugin — `get_plugin_params(slot:1)` returned slot 0's already-open EQ window. Fixed by closing open plugin windows for the track before opening the requested slot.
  3. Volume convergence bailed ~1 dB short — the stuck-detection trusted an immediate post-nudge read (same async lag). Fixed with a settle-poll before declaring "stuck".
- **Known limitations still open** (see HANDOFF.md): plugin `display` shows raw engineering values ("240.0") not "0.0 dB"; slot 1 (an instrument, RetroSyn) returns "parameters not accessible" (effects vs instruments — confirm intended); `set_automation_mode` volume-clobber and stale-read-after-hand-edit not yet re-checked in this run.

### 2026-07-09 run detail
- **1 ping** pass. **2 refresh_state** pass (20 names, correct order, after the bank-clamp fix).
- **3 set_volume db:-6** pass — Logic printed exactly `-6.0`, `source:"logic"`.
- **4 set_volume delta:+2** pass — exactly `-4.0`. Integer `db` now accepted (was a hard error).
- **5 set_mute** pass, including the idempotent re-call. (Stale-LED-cache case still UNTESTED: needs a
  track muted BY HAND in Logic, which the daemon never saw, then `set_mute(on:false)`.)
- **6 set_pan** pass, visually confirmed (`pedlS5` right 30, `guitar` hard left). Returns the pan Logic
  prints, `source:"logic"`. Verification no longer uses the V-Pot ring echo — see below.
- **7 set_send** FAIL — `no send to 'Aux 1'`, `observed` shows the TRACK NAME row, not the send page.
- **8 play/stop** pass. **9 record without confirm** pass (structured refusal).
- **10 get_plugin_params** FAIL (racy). On an empty slot it once returned 8 FABRICATED params named `-`
  with blank displays instead of an error. On a slot that DOES hold an EQ it returned the real params
  once, then `no plugin in slot 0` minutes later. `observed` shows `Select BacVox guitar ...` — the
  transient banner from the `.select(channel:)` press, i.e. the LCD was read before Logic switched views.
- **11 set_plugin_param** FAIL — same cause; could not reach a plugin view reliably.
- **12 undo_last{n:3}** passes ONCE. A second `undo_last` re-applied the same mutations: undo operations
  are themselves journaled, so undo-then-undo is a REDO. Confirmed live.
- **13 background** pass — Logic was unfocused for the entire session; MCU needs no focus.

## Phase 1 deferred findings to validate on real Logic

Findings discovered/deferred during Phase 1 development against FakeLogic;
the real-Logic smoke above must specifically check each of these.

- [x] **CLOSED 2026-07-09. Handshake response bytes.** Real Logic engages the surface under the lenient
  serial-only handshake. It NEVER sends `hostConnectionReply` (0x02) at all, so `MCUSession`'s
  `.hostConnectionReply` branch is dead code against real Logic and `connected` is in practice set by the
  first inbound `.lcd`. Any readiness check must therefore NOT wait on 0x02, and must not treat
  `connected` as proof the OUTBOUND direction works. Original text: The MCU codec models the host-connection
  reply as serial-only, and the daemon never validates the 4-byte
  challenge-response (it also sets `connected=true` on the first LCD write as
  a fallback). Verify real Logic actually engages the surface under this
  lenient handshake. If it does **not** engage: capture the
  `F0 00 00 66 14 02 …` reply during setup and check whether the 4-byte
  challenge-response must be computed and echoed back before Logic will
  adopt the surface.
- [x] **CLOSED 2026-07-09. Fader curve calibration.** Measured, not estimated — see `logic-mcp calibrate`.
  Unity is raw 12443 (not 12288); the fader SATURATES at raw 14845 = +6.0 dB; silence extends to raw 7.
  Old anchors were wrong by up to 6.7 dB. 59 measured anchors; hold-out error now <= 0.1 dB, the resolution
  of Logic's own display. Original text: `FaderCurve.anchors` are v0 approximations;
  the raw↔dB round-trip error is largest in the **upper** part of the curve
  (raw ≈ 12472–16091, i.e. above unity/0 dB). When running the fader
  calibration sweep above, sample that upper region more densely than the
  listed values (e.g. add intermediate points between 0 and +6) so the
  anchors are well-constrained there, not just at the listed dB steps.
- [x] **CLOSED 2026-07-09. `set_pan` verification strength** — and it was worse than described. (1)
  `.assignPan` is a TOGGLE: pressing it unconditionally flipped Logic into a single-parameter page where
  only V-Pot 0 is live, so the sweep moved NOTHING on any other channel, alternating call to call. (2) The
  V-Pot ring echo is not a usable confirmation at all: Logic coalesces a fast delta burst before refreshing
  the ring, so a sweep returning to its start emits NO echo — the guard failed precisely when the pan was
  already correct. Fixed by `normalizeSurface()` (observe both display toggles, press only when wrong) and
  by verifying against the pan Logic PRINTS on the bottom LCD row. Original text: `set_pan` currently resolves on the
  **first** V-Pot ring echo of a multi-tick sweep, not the sweep's final
  settled position. During smoke item #6, confirm pan actually **lands** at
  the requested position on real Logic (not just that the ring moved), and
  note whether the coarse V-Pot ring resolution can or can't confirm the
  exact landing value — this is a candidate for a settle-after-sweep
  hardening pass if real Logic shows drift/overshoot.
- [x] **CONFIRMED BROKEN 2026-07-09. Plugin empty-slot heuristic — and worse: WRONG-TRACK reads.**
  `enterPluginEdit` presses `.select(channel:)`, `.assignPlugin`, `.vpotPress(slot)`, settling blind between
  each. Logic's plugin view follows the SELECTED track, and the selection has not always landed when we
  read. Live: `get_plugin_params("BacVox", 0)` returned `vox`'s Channel EQ — BacVox has no EQ. On an empty
  slot it once returned EIGHT FABRICATED params named `-` with blank displays instead of an error; on a slot
  that DOES hold an EQ it returned `no plugin in slot 0`. `set_plugin_param` shares the path, so it can
  WRITE to the wrong track's plugin. DO NOT USE `set_plugin_param` until fixed. Fix: press `.select`, wait
  for the SELECT LED echo on that exact channel (Logic does emit it), then switch views and WAIT for the
  expected view (param names / bus names) rather than settling blind. Never fabricate params. Same bug
  breaks `set_send` (item 7). Original text: `get_plugin_params` / `set_plugin_param`
  detect an empty slot by "LCD top line unchanged after `.vpotPress(slot)` ⇒
  no plugin in that slot." Validate this against real Logic: call
  `get_plugin_params` on a track's empty plugin slot and confirm it returns a
  structured error rather than fabricated params. Real Logic may render an
  empty slot differently (e.g. an explicit "No Plugin" label) — the
  heuristic still works as long as that view is distinguishable from the
  plugin-select view; confirm this is the case.
- [x] **CLOSED 2026-07-09 (benign). `set_mute`/`set_solo` skip-path trusts an unsynced LED cache.**
  Tested live both ways. Muting a track BY HAND while it is visible: Logic echoes the mute LED, cache is
  correct. Muting `Room` by hand while it sat OUTSIDE the window, with a stale "off" cached on its surface
  channel (left by unmuting `bass`): `set_mute(Room, on:false)` still worked. So **Logic re-sends mute LED
  states when the surface banks to a new window**, just as it re-sends fader positions, and the cache is
  refreshed before the skip check runs. The skip path is safe. NOTE the cache is keyed by SURFACE CHANNEL,
  not by track, so this safety depends entirely on that bank-time LED refresh. FOLLOW-UP (easy win): since
  Logic emits them, `MixerNavigator` should sync mute/solo into the shadow model on bank, mirroring
  `syncFadersFromSurface` — today `refresh_state` reports `mute:false` for a track muted outside the daemon.
  Original text:
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

## Plugin write-path smoke (`set_plugin_param` / `set_plugin_option` / `press_plugin_control`)

Verified live on `mcp_test` (2026-07-17, branch `feat/plugin-actuation`). Reconnect `/mcp` after any
rebuild (`ping` must show `stale:false`) or you test old code. Drive everything in the background —
Logic must never come frontmost.

1. **Stock slider by unit** — `set_plugin_param(vox, 0, "Low Shelf Gain", "-3 dB")` → `-3.0 dB`,
   `verified:true`. (This is the case that railed to +24 dB before the converger rewrite.)
2. **Stock slider normalized** — `set_plugin_param(vox, 0, "Low Shelf Gain", 0.5)` → `0.0 dB`, verified.
3. **Rail + undo** — `set_plugin_param(vox, 0, "Low Shelf Gain", "+24 dB")` → verified; then
   `undo_last(1)` re-drives it back to the prior value (validates the bisection rail-return + self-journal).
4. **Stock enum** — `set_plugin_option(vox, 0, "Low Cut Slope", "18")` → `18 dB/Oct`, verified.
5. **Stock toggle** — `press_plugin_control(vox, 0, "Low Cut On/Off")` flips the checkbox; verified by re-read.
6. **THIRD-PARTY write (ship gate)** — `insert_plugin(<scratch>, "SketchCassette II")`;
   `get_plugin_params` returns its named/unit-valued table; `set_plugin_param(<scratch>, n, "Comp. Dry/Wet",
   "50 %")` → `50.0 %`, `verified:true`; `set_plugin_option(<scratch>, n, "Tape Quality", "Master")` verified;
   a bogus choice returns the live choice list. Then `undo_structural` removes the insert (net-zero).

**Timing gotchas confirmed live (all handled by settle-polls):** the Controls table populates async after
the view switch (`settledControlTable`); a Logic dB display of a positive value is `+N dB` (the parser must
accept a leading `+`); an enum popup's menu appears ~100 ms after the press and its selected value updates
~400 ms after the item press (`selectEnumChoice` settle-polls both).
