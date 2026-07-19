# logic-mcp Phase 5 · Plan A — Arrange "Control Room" (Design)

**Date:** 2026-07-18
**Status:** Approved direction, pre-implementation
**Builds on:** Phase 4 (the plugin Controls-view engine — the `convergeAdaptive` slider converger,
`AXMenuDriver.selectEnumChoice` plain-menu popup select, `press_plugin_control`'s press-toggle pattern,
and the settle-poll discipline), Phase 3 (menu-driven structural ops, `delete_track` guard, `undo_structural`),
and the Phase 2 AX read/write layer (`AXBridge`, fresh-walk resolution, `nudgeToRaw`).

## Summary

The 2026-07-18 feasibility probe (see `.superpowers/sdd/ax-findings.md` → "ARRANGE / GLOBAL-TRACK / MIDI
feasibility probe") proved Logic's arrange window is broadly AX-addressable no-focus. This plan opens
**Phase 5 "Arrange/Timeline"** with its foundation layer: the **"Control Room"** — the project-global
scalars and transport/navigation that live in the arrange window's **Control Bar**, plus the
**track-selection primitive the mixer never had** and the `delete_track` re-enable it unlocks. Everything is
AX, no focus stolen, each write self-verified against a fresh re-read. It deliberately stops short of the
List-Editor event engine (Plan B) and MIDI (Plan C).

The two things we have only *read*, never *actuated*, gate the plan: **how the control-bar sliders move
under `AXSetValue`** (the mixer nudges ±1, the plugin Controls view is absolute — this is a third slider
family of unknown behavior) and **whether pressing the arrange header's `Has Focus` radio actually sets
selection no-focus**. Both are resolved by a live probe (Task 0) that opens implementation, exactly as every
prior phase.

## Scope

**In scope (all AX, no-focus, each self-verified via a fresh re-read):**

- **`set_tempo(bpm)`** — the control-bar `AXSlider description="Tempo"`. Semantics: sets the tempo *at the
  current playhead position*; with the playhead at the start (or when the project has no tempo changes) that
  is the project tempo. Multi-event tempo maps are Plan B.
- **`set_time_signature(sig)`** / **`set_key_signature(key)`** — the control-bar `AXPopUpButton`s (plain
  `AXMenu` select via `selectEnumChoice`).
- **`set_playhead(bar[, beat])`** — the `AXSlider description="bar"` / `="beat"` (clean integer values).
- **`set_cycle(startBar, endBar[, enabled])`** — the `Cycle` toggle + the `Start Marker` / `End Marker`
  timeline indicators. **Task-0-gated:** the locator values read as *encoded* integers, so set-by-bar must be
  shown to converge; if it can't, `set_cycle` cleanly defers to Plan B and Plan A ships playhead-only nav.
- **`select_track(name)`** *(new — see note below)* — press the arrange header's `AXRadioButton
  description="Has Focus"` for the named track. **Task-0-gated** on press-to-select working no-focus.
- **`delete_track` re-enable** — currently DISABLED (it would delete the wrong track because the mixer can't
  set selection). With a confirmed `select_track`, it becomes: select the named track → confirm focus →
  delete. Depends on `select_track`.
- **`rename_track`** — **Task-0 spike;** included only if setting the arrange track-name `AXTextField`
  commits no-focus (it was deferred in Phase 3 because AX text edits needed keystrokes ⇒ focus).
- **Reads** folded into `get_project_overview`: tempo, time signature, key signature, playhead, cycle range.

**Deferred (later plans, not this one):**
- The **List-Editor table engine** — tempo events (global+regional), signature/marker events, and region
  Position/Name/Length — is **Plan B**.
- **MIDI note CRUD** (descended Event List) and **MIDI file import** are **Plan C**.
- **Region loop toggle** (region-inspector `Loop:` checkbox — a press-only `AXCheckBox`, already located in
  the probe) is **Plan B**, where region-selection machinery lives.
- **Track automation curves** — no List-Editor tab, no node element; the recorded gap. Not addressed.

**Non-goals (this plan):** multi-event tempo/signature maps (Plan B); duplicating mixer controls that
already exist (arrange-header mute/solo/volume/pan — the mixer path from Phase 2 stands); scrolling the
arrange or marquee/tool selection; the `Display Mode` / zoom controls.

## Why this phase — the ground truth (from ax-findings.md, 2026-07-18)

The `… - Tracks` window's `AXGroup description="Control Bar"` exposes, no-focus:

- `AXSlider description="Tempo" value="120" settable=true`.
- `AXGroup description="Playhead Position"` → `AXSlider description="bar"` + `="beat"`, both `settable=true`.
- Time-ruler `AXValueIndicator subrole="AXTimeline"`: `Playhead thumb`, `Start Marker`, `End Marker` all
  `settable=true` — but their values are **encoded integers** (e.g. `End Marker = 2111062325329920`), not bars.
- `AXPopUpButton description="Time Signature" value="4/4"` and `="Key Signature" value="C Major"`.
- Transport as checkboxes/buttons (`Cycle`, `Play`, `Record`, `Rewind`, `Forward`, `Go to Beginning`, `Set
  Punch In/Out Locator`, `Count In`, `Metronome`).

The arrange header (`AXGroup description="Tracks header"` → per-track `AXLayoutItem "Track N “name”"`)
carries `AXRadioButton description="Has Focus"` — the selected track's reads `value="1"`. This is a
selection surface the mixer does not expose. **Two actuation unknowns remain** (we have only read these):
the control-bar slider write primitive, and whether `AXPress` on `Has Focus` sets selection. Task 0 settles
both.

> **Naming note — `select_track` is being REINTRODUCED, deliberately.** Phase 3 REMOVED a mixer-based
> `select_track` because it was a redundant false-positive (the mixer cannot set selection —
> `Fixtures/ax/selection.txt`). The Plan-A `select_track` is a **different surface** (the arrange header's
> `Has Focus` radio) and is only shipped if Task 0 proves it genuinely sets selection. This is not a revert;
> it is a new capability on a newly-mapped surface.

## Task 0 — the live actuation probe (decision gate, first task)

Run live on real Logic at implementation start (mirrors every prior phase's Task 0). Uses the read-only
`axdump deep`/`press` diagnostics already added to `Sources/logic-mcp/AXDump.swift`. It measures and captures
fixtures under `Tests/LogicMCPCoreTests/Fixtures/ax/`:

1. **Control-bar write primitive.** `AXSetValue` swept on the `Tempo` and `bar`/`beat` sliders — is it
   **absolute** (lands at `v`), **±1-nudge** (mixer-style), or neither? This selects the converger
   (`convergeAdaptive .absolute` vs `nudgeToRaw`). Record raw→display at several points.
2. **Popup select** on `Time Signature` / `Key Signature` — confirm `selectEnumChoice` (press popup → plain
   `AXMenu` → item match → settle-poll the popup value) works no-focus; capture the menu items.
3. **`Has Focus` press-to-select.** `AXPress` the target track's `Has Focus` radio, then re-read every
   header's `Has Focus`: does exactly the intended one become `1` and the rest `0`, no focus stolen? This is
   the make-or-break for `select_track` / `delete_track` / `rename_track`.
4. **Cycle locator encoding.** Read `Start`/`End Marker` raw + any display string; determine whether a
   set-by-bar can converge (encoded-value → bar oracle). Decides whether `set_cycle` ships in Plan A or
   defers to Plan B.
5. **`rename_track` commit.** Set the arrange track-name `AXTextField` value and re-read: does it commit
   no-focus? Decides whether `rename_track` ships or stays deferred.
6. **Undo registration.** After a `set_tempo` / signature edit, does Logic's Edit▸Undo gain a matching entry
   (→ `undo_structural` by-name prefix match) or not (→ self-journal via `undo_last`)?

**Output:** captured fixtures + a one-paragraph finding selecting (a) the converger, (b) `set_cycle`
inclusion, (c) `select_track`/`delete_track`/`rename_track` inclusion, (d) the undo branch. The plan is
written so implementation is unblocked whichever way each resolves — the degraded floor is "control-bar
scalars + playhead nav" (all proven `settable=true`), which ships regardless.

## Design

### Layer 1 — the control-bar engine (`AXBridge`)

A new locator + typed accessors, parallel to the existing mixer/plugin engines and honoring the same
fresh-walk discipline (the arrange window re-renders headers on selection and structural changes, so a
handle captured across a mutation is STALE — always re-resolve by name):

- `arrangeWindow()` — the `AXWindow` whose title ends `- Tracks` (distinct from `- Mixer: Tracks`).
- `controlBar()` — its `AXGroup description="Control Bar"`; typed getters for the `Tempo` slider, the
  `Playhead Position` `bar`/`beat` sliders, the `Time Signature` / `Key Signature` popups, the `Cycle`
  checkbox, and the ruler `Start`/`End Marker` indicators.
- `arrangeHeaders()` — the per-track `AXLayoutItem "Track N “name”"` list, each with its `Has Focus` radio
  and name field, resolved **by track name** (trimmed of the `Track N “…”` wrapper).

Slider writes go through the probe-selected converger (`convergeAdaptive` if absolute, `nudgeToRaw` if
nudge), converging against the control's display/value oracle with a settle-poll (`settledValue`) — never
trusting a single write. Popups reuse `selectEnumChoice` unchanged.

### Layer 2 — the tools

- **`set_tempo(bpm)`** — resolve the control bar (fresh), converge the `Tempo` slider to `bpm`, verify
  against the re-read value/display; return achieved bpm + `verified`. Document the tempo-at-playhead
  semantics in the tool description.
- **`set_time_signature(sig)` / `set_key_signature(key)`** — `selectEnumChoice` on the popup; verify the
  popup's displayed value == request (settle-polled, per the Phase-4 ~400 ms lag lesson).
- **`set_playhead(bar[, beat])`** — set the `bar` (and optional `beat`) sliders; verify by re-read.
- **`set_cycle(startBar, endBar[, enabled])`** — press `Cycle` to the requested enabled state (press-only
  checkbox); converge `Start`/`End Marker` to the requested bars (mechanism per Task 0); verify. Deferred
  cleanly if Task 0 shows the locator encoding won't converge.
- **`select_track(name)`** — fresh arrange-header walk → find the header by name → `AXPress` its `Has Focus`
  radio → re-read ALL headers' `Has Focus` and confirm exactly the intended one is `1`. Non-destructive;
  no undo entry.
- **`delete_track(name)`** — `select_track(name)`, then **re-read to CONFIRM** the intended track is the sole
  focused one; only then run the Phase-3 delete path (the tool that was disabled). Verify by diff (the name
  is gone / track count dropped by one). Undo via `undo_structural`. **If selection is not confirmed, REFUSE
  — never delete on an unconfirmed selection** (this is the whole reason it was disabled).
- **`rename_track(name, newName)`** *(conditional on Task 0)* — select the track, set the name field, verify
  the commit by re-read; undo via `undo_structural`. If Task 0 shows text edits don't commit no-focus, the
  tool returns a structured "not available via AX" error and stays deferred.

### Undo & safety

- **Tempo / signature / key edits** — undo branch selected by Task 0 (6): ride Logic Edit▸Undo via
  `undo_structural` (by-name prefix match) if an entry appears, else self-journal via `undo_last` (capture
  the prior display before the write; reverse by re-driving through the same converger).
- **Playhead / cycle** — navigation, non-destructive; no undo entry (a re-set is idempotent).
- **`select_track`** — non-destructive; no undo.
- **`delete_track` / `rename_track`** — ride Logic Edit▸Undo (`undo_structural`), same as Phase 3.
- **The delete guard is load-bearing:** `delete_track` MUST confirm — via a fresh re-read of `Has Focus`
  after `select_track` — that exactly the intended track is focused before acting. This closes the
  wrong-track hazard that disabled the tool.

## Error handling (structured `ToolFailure(layer:"ax")`)

- No arrange (`- Tracks`) window found → error (Logic not open / no project).
- Control bar / a named control absent → error naming the missing control.
- Popup choice not found → error listing the live choices.
- Converge can't reach target (encoded/coarse value) → achieved value + `verified:false` + the real display;
  does not throw.
- `select_track`: name not among the arrange headers → error listing the available track names.
- `delete_track`: selection not confirmed after `select_track` → **refuse** with a structured error (never
  delete an unconfirmed selection).
- `rename_track` (if Task 0 shows no no-focus commit) → structured "rename not available via AX (text commit
  needs focus)".
- `set_cycle` (if Task 0 shows locator encoding won't converge) → structured "cycle-by-bar deferred to a
  later plan".

## Testing

The established two-tier pattern (AX needs real Logic → unit tests parse captured fixtures):

- **Fixture-parsing unit tests** against Task 0's captures: control-bar group parse (tempo/playhead/popups/
  cycle located correctly); popup `choices` population; playhead/tempo value decode; `Has Focus` selection
  parse (exactly-one-focused across a header set); cycle-locator decode; the error paths (choice-not-found,
  name-not-found, unconfirmed-selection-refuses).
- **Converger tests** on `FakeAXProvider` with `setValueLatency>0`: the probe-selected primitive converges
  on tempo/playhead; honest `verified:false` on an unreachable/encoded target. Extend `FakeAXProvider` to
  model the arrange window (a control bar + a set of track headers each with a `Has Focus` radio), so
  `select_track` / `delete_track` (select→confirm→delete→diff) exercise their real shape.
- **Live `smoke --arrange`** (ship gate, below).

## Done-criteria — the live `smoke --arrange` (ship gate)

On `mcp_test.logicx`, no focus stolen throughout, net-zero at the end:

1. `set_tempo` to a new BPM — converged, verified against the re-read value.
2. `set_time_signature` + `set_key_signature` — selected, verified against the popup display.
3. `set_playhead` to a bar (+beat) — verified; **and** (if Task 0 green) `set_cycle` to a bar range —
   verified against the locators.
4. `select_track(name)` → `Has Focus` confirms exactly that track; `delete_track` the selected track → it is
   gone; `undo_structural` → it is back. Net-zero.
5. (If `rename_track` shipped) rename a track, verify, and undo.

## Open risks (carry into the plan)

- **Control-bar write primitive is a third, uncharacterized slider family** (mixer nudges, plugin Controls is
  absolute) — Task 0 must disambiguate before the converger is wired.
- **Cycle locator encoding** may block set-by-bar → `set_cycle` defers to Plan B (playhead nav still ships).
- **`Has Focus` press may not set selection no-focus** → `select_track` / `delete_track` / `rename_track` all
  slip; Plan A degrades to control-bar scalars + playhead/cycle nav (still a shippable, useful increment).
- **`rename_track` text-commit** likely still needs focus → stays deferred (the Phase-3 finding).
- **Arrange-window staleness** — selection and structural changes re-render the headers; always re-resolve by
  name and settle-poll (the codebase's #1 bug class).
- **`set_tempo`-at-playhead semantics** — if the project already has tempo changes, this edits the segment at
  the playhead, not "the" project tempo; document it. True tempo-map editing is Plan B.

## First implementation step

Task 0 (the live actuation probe) is the plan's first task, run live at implementation start. Its finding
selects the converger, the `set_cycle` / `select_track` / `delete_track` / `rename_track` inclusion, and the
undo branch; its captured fixtures are what the parsing and converger tests build on.
