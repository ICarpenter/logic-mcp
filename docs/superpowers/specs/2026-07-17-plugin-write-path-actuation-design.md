# logic-mcp Phase 4 · Plan 2a — Plugin Write-Path Actuation (Design)

**Date:** 2026-07-17
**Status:** Approved direction, pre-implementation
**Builds on:** Phase 4 · Plan 1 (`2026-07-15-plugin-control-suite-design.md` + `…-plugin-control-core.md`,
merged as #9 — Controls-view read engine: `controlTable`, `switchToControlsView`, `pluginWindow`,
`convergeToDisplay`, `get_plugin_params`, `set_plugin_param`) and the Phase 2 AX read/write layer
(`AXBridge`, `AXMenuDriver`, `nudgeToRaw`, `settledValue`).

## Summary

Plan 1 shipped a **production-ready read path** — `get_plugin_params` drives Logic's generic
**Controls view** (a uniform `AXTable` of named, unit-valued rows) and returns every parameter of any
plugin, vendor-agnostic (proven live on Apple Channel EQ + captured on UAD/JUCE), no focus stolen. But
the **write path is broken**: `set_plugin_param` drives a Controls-view Cocoa slider to the rail instead
of converging, `AXCheckBox` controls read `settable:false` (they are press-only), and there is no way to
select an in-table enum. This phase makes the **write** half of the Controls view work: read/write every
parameter by unit, select enum options, and press toggles/buttons — all no-focus and self-verified against
the row's live display string.

The core unknown is **how a Controls-view Cocoa slider actually moves under AX** — the mixer's
`±1-nudge` model does not apply here (confirmed live). The phase opens with a **live actuation probe**
(Task 0) that characterizes the primitive and, from that, selects the converger's search strategy. The
undo mechanism for plugin writes is likewise resolved by that probe; a guard against the observed
"wrong-thing-undone" hazard ships unconditionally.

## Scope

**In scope (all AX, no focus, each self-verified via re-read):**

- **`set_plugin_param` rework** — actually set a continuous/stepped slider param by unit string
  (`"-3 dB"`, `"25 %"`) *or* normalized `0–1`, converging against the row's display oracle.
- **`set_plugin_option`** (new) — select a value in an in-table enum `AXPopUpButton` by choice name.
- **`press_plugin_control`** (new) — press/toggle an in-table `AXCheckBox` or a header button
  (bypass, compare) by name.

**Deferred to a later plan (Plan 2b):** the persisted **profile store** (learned per-plugin addressing),
**`load_instrument`**, **preset load/list** (the header preset menu — a larger hierarchical surface),
and **`learn_plugin`**. The read path already gives stable names without a persisted store, so those are
separable.

**Non-goals (unchanged from the suite design):** preset *save* / user-preset authoring; active-sweep /
Vision calibration; parameter automation curves; sends. Opaque plugins (no AU params) remain reported
`opaque`, not worked around.

## Why this phase — the ground truth

From the 2026-07-16 Plan-1 smoke (`vox` Channel EQ in Controls view; see `.superpowers/sdd/ax-findings.md`):

- **The `±1-nudge-toward-target` model does NOT hold for Controls-view Cocoa sliders.** That model was
  validated on the mixer volume fader + pan knob — different AX controls. `convergeToDisplay`'s inner move
  is `setNumber(hi or lo, of: slider)`, expecting a one-unit nudge toward the rail; on the Channel EQ Gain
  slider the raw instead **jumped to the rail**. Repro: `set_plugin_param(vox,0,"Low Shelf Gain","-3 dB")`
  → `+24.0 dB` (the ceiling), `verified:false`, deterministic. Normalized `0.5` also failed to move it off
  the rail. The converger fails **safe** (never a fabricated `verified:true`) but cannot set a value.
- **Known oracle for the probe.** Low Shelf Gain raw is **0…480, linear**: `dB = (raw − 240) / 10`,
  range ±24 dB (`raw 240 = 0 dB`, `raw 480 = +24 dB`). A clean scale to characterize the primitive against.
- **`AXCheckBox` controls report `settable:false`** — they are `AXPress`-only, which is exactly why the
  setter can't touch them. Relevant to `press_plugin_control`.
- **`AXSetValue` on a Controls-view slider does not create a Logic undo entry** — so a plugin-param write
  leaves nothing on Logic's Edit▸Undo stack, and a follow-up `undo_structural` silently hit the *next*
  stack item ("Undo Create Track") and deleted a real track. The safety hazard this phase must close.
- **Timing/focus that worked (Plan 1):** switch-to-Controls settled within a 40 ms sleep and never stole
  focus. The read path is trustworthy; only the write path is reworked here.

## Approach — adaptive oracle-converger (chosen over closed-form / hybrid)

The converger keeps the **display string as its convergence oracle** (the payoff of the Controls view: a
live, unit-labelled readback for every param, third-party included) and replaces the railing inner move
with a search strategy **selected by Task 0's finding**:

- **If `AXSetValue` is absolute** (on the slider's `AXMinValue…AXMaxValue`, or on a normalized `0…1`
  scale): **binary-search the raw against the display.** Set a midpoint, read the display number, bisect
  toward the unit target. O(log range) (~9 steps on a 0…480 slider), needs **no per-param calibration
  curve**, and tolerates **nonlinear scales** (dB is linear here; Hz/% often are not) because it only ever
  trusts the measured display, never a computed mapping. This sidesteps the calibration subsystem the
  suite deferred.
- **If only the step actions move it** (`AXSetValue` unusable; `AXIncrement`/`AXDecrement` step by a fixed
  amount): **step-converge** toward the target, re-reading the display each step — the same
  "converge against an oracle" loop the mixer already uses, with `perform(.increment/.decrement)` as the
  primitive instead of `setNumber`.

**Rejected alternatives.** *Closed-form compute-and-set* assumes `AXSetValue` is cleanly absolute (the
smoke already contradicts this) and needs the deferred per-param calibration curve. *Hybrid coarse+fine*
optimizes before the probe even tells us the primitive. The adaptive converger is robust to the unknown,
matches the codebase's "converge against an independent oracle, never trust a single write" invariant, and
degrades honestly.

## Task 0 — the live actuation probe (decision gate, first task)

Before rewriting anything, a live probe on real Logic characterizes the primitive and captures fixtures.
This mirrors the "Task 0 live re-probe" of Phases 3 and 4·Plan 1. It measures, on the Channel EQ
Low Shelf Gain slider (known oracle above):

1. **`AXSetValue(v)`** swept across `AXMinValue…AXMaxValue` (and a couple of `0…1` values) — is it
   **absolute** (lands at `v`), **normalized**, or neither? Record the raw→display map at several points.
2. **`AXIncrement`/`AXDecrement`** step actions — do they move the raw by a fixed, predictable amount, and
   by how much?
3. **Undo registration** — does the winning primitive create a Logic Edit▸Undo entry? (Resolves the undo
   mechanism, below.)
4. **Enum popup presentation** — press an in-table enum `AXPopUpButton` and record whether it opens a
   **plain `AXMenu` of `AXMenuItem`s** (expected for a small fixed enum → new `selectEnumChoice` helper) or
   attaches an **`AXSearchField`** (→ reuse `selectRoutingDestination`-style search). Confirm where the
   Compressor **circuit model** ("Vintage Opto" …) lands — enum popup vs stepped slider.
5. **Third-party confirmation** — repeat the winning slider primitive on a UAD/SketchCassette slider, since
   a live third-party verified write is the ship gate.

**Output:** captured fixtures under `Tests/LogicMCPCoreTests/Fixtures/ax/` + a one-paragraph finding that
selects (a) the converger search strategy, (b) the undo branch, (c) the enum-select mechanism. The plan is
written so implementation is unblocked whichever way each resolves.

## Design

### Layer 1 — the slider converger (`AXBridge.convergeToDisplay` rewrite)

Replace the railing `setNumber(hi/lo)` inner move with the probe-selected strategy. Cross-cutting details:

- **Direction probe.** One measured move at the start records the sign of *display-delta per raw-increase*,
  resolving **inverse params** (display decreases as raw rises) generically — instead of the current
  hard-coded "display increases with raw" assumption.
- **Settled reads.** The async-write staleness guard (`settledValue(of:unlessChangedFrom:)`) stays: an
  immediate re-read can return the pre-write value and masquerade as a boundary. Binary search reads the
  *display* after the *raw* settles.
- **Oracle + tolerance.** The tolerance is the display's own quantum (e.g. a 0.1 dB readout → 0.05), so
  "converged" means "the readout the user sees matches the request." The display string is the sole
  convergence oracle; the raw is only a search coordinate.
- **Honest stall.** If the target can't be reached within tolerance (coarse quantization, genuine
  boundary), return the achieved display number with `verified:false` and the real display string — never a
  fabricated success. `verified:false` becomes the rare exception (opaque / unparseable display), not the
  norm it is today.

`set_plugin_param` accepts a unit string or normalized `0–1` (unchanged surface), resolves the row from a
fresh Controls-table walk, requires `.slider` kind, converges, and returns the achieved display + `verified`.

### Layer 2 — enum select (`set_plugin_option`)

In-table enum params render as `AXPopUpButton`. Two mechanisms depending on Task 0's finding (4):

- **Plain `AXMenu` (expected for small fixed enums):** a **new** `AXMenuDriver.selectEnumChoice(from
  popup:, choice:)` — press the popup, walk its `AXMenu` children, pick the **exact case-insensitive**
  `AXMenuItem` title match, verify by re-reading the popup's displayed value == requested. This is new code,
  distinct from the search-driven catalog popups.
- **`AXSearchField` (if an enum surprisingly presents one):** reuse the existing
  `selectRoutingDestination`-style search mechanism.

`controlTable` is **extended to populate `choices`** for `.popup` rows (today hard-coded `nil`) by reading
the popup's menu items — so `get_plugin_params` advertises the choices and the tool returns a clean
"choice not found; available: …" error from live data.

> **Note — mechanism correction (carry into implementation):** the existing `set_output` /
> `insert_plugin` popups are **search-driven** (`selectRoutingDestination` / `selectPluginFromPopup`,
> both via an `AXSearchField` + `setString`), used because the routing/plugin catalogs are huge. There is
> **no `selectPopupLeaf`**; the Phase-3 nested-submenu walk was replaced by the search-driven approach in
> fix #7. The only plain menu-walk helpers are `pressMenuPath`/`pressMenuItemWithPrefix` (global menu bar).
> A small in-table enum is a different UI shape and most likely needs the new `selectEnumChoice` walk.

If the **circuit-model / mode switch** renders as a popup, it is reached via `set_plugin_option` with no
special radio-button machinery; if it renders as a stepped slider, via `set_plugin_param`. Task 0 (4)
decides.

### Layer 3 — press toggles & buttons (`press_plugin_control`)

In-table `AXCheckBox` controls are press-only (`settable:false` — the smoke's finding), so this tool presses
via `perform(.press, on:)` and verifies closed-loop where the control exposes state:

- `AXCheckBox` → re-read its value, confirm it flipped.
- Header button (bypass, compare) → press; where it exposes state (bypass/compare are checkboxes) confirm
  it, else report `pressed`. Header controls live outside the table and are addressed by their own
  description, same walk as the `view` menu.

All three tools verify against a **fresh re-read**, never a captured handle — the standing stale-handle
discipline.

### Undo & safety

**Unconditional guard (independent of the probe).** The smoke's damage came from a category confusion: a
plugin write left nothing on Logic's Edit▸Undo stack, so `undo_structural` (which replays Edit▸Undo)
silently hit the next item and deleted a track. Regardless of the mechanism decision, plugin-param writes
must **never be mistaken for a structural op**: they are not recorded on the structural-undo path, and
`undo_structural` is unchanged (replay Edit▸Undo) — we simply stop assuming a plugin write is on that
stack. This closes the "wrong-thing-undone" hazard even in the worst case.

**Mechanism (resolved by Task 0's undo measurement).**

- **If the winning primitive registers a Logic undo entry** → plugin writes ride Logic's own undo,
  reachable via `undo_structural`; verify a matching Edit▸Undo item appears (the by-name prefix match
  already used for structural ops).
- **If it does not** → self-journal: capture the control's prior display/raw *before* the write (already
  read from the row) and register an entry in **our own** `undo_last` journal whose undo action re-drives
  the control back via the same reworked converger. Reversible through *our* path without touching Logic's
  stack; re-driving is just another verified converge, inheriting the oracle guarantee.

If the mechanism is non-undoable *and* reverse-actuation is lossy (a param whose display can't be re-hit
exactly), the tool reports that honestly rather than claiming a clean undo.

## Error handling (structured `ToolFailure(layer:"ax")`)

- Slot empty / out of range → existing `axEnterPluginControls` error, unchanged.
- Control not found by name → error listing available control names (as `set_plugin_param` does today).
- `set_plugin_option` choice not found → error listing the live choices (now that `controlTable` populates
  them).
- Wrong control kind (`set_plugin_param` on a `.toggle`/`.popup`, or `press_plugin_control` on a `.slider`)
  → structured "wrong control kind; use <the right tool>" — kind-mismatches fail loud, never mis-actuate.
- Converge can't reach target (coarse display / boundary) → achieved value + `verified:false` + real
  display string; **does not throw** (a landed-but-imprecise write is data, not an error).
- Opaque plugin (empty Controls table) → the Plan-1 "exposes no addressable parameters" path, unchanged.

## Testing

The established two-tier pattern (AX needs real Logic → unit tests parse captured fixtures):

- **Fixture-parsing unit tests** against Task 0's captures: enum-popup `choices` population; the probe's
  raw→display characterization decoded correctly; direction-probe sign detection (a synthetic
  inverse-display fixture); binary-search vs step-converge selection; the kind-mismatch guards and their
  errors.
- **Converger tests** on `FakeAXProvider` with `setValueLatency>0`: binary search converges on a linear
  scale, on a coarse (quantized) display, and on an inverse-display param; honest `verified:false` on an
  unreachable target. Extends the Plan-1 converge tests (which used a synchronous fake). The fakes are
  extended to model the actual probed primitive (absolute-set or increment/decrement) so tests exercise the
  real convergence shape.

## Done-criteria — the live `smoke --plugins` (ship gate)

On `mcp_test.logicx`, no focus stolen throughout, net-zero at the end:

1. Set a **stock** param by unit **and** by normalized value — Channel EQ Gain to `-3 dB` (the exact case
   that railed), converged and **verified against the display oracle**.
2. Select an in-table **enum** (`set_plugin_option`) and **press a toggle/button** (`press_plugin_control`),
   each verified by re-read.
3. **A verified write on a third-party plugin** (UAD or SketchCassette) — the hard ship requirement.
4. The undo path (whichever Task 0 selects) cleanly restores; the `undo_structural` guard prevents any
   wrong-item undo.

## Open risks (carry into the plan)

- **The primitive may be neither clean-absolute nor clean-step.** The smoke saw `setNumber(min)` drive the
  display to *max* — not obviously either model. Task 0 must disambiguate before the converger is written;
  if it is genuinely erratic, the plan escalates (a narrower probe, or falling back to increment/decrement).
- **Binary search on a coarse display** may not pin an exact unit (multiple raws share one readout) — then
  `verified:false` with the nearest achievable value is the honest result, not a failure.
- **The `view` switch + table-populate still use single-shot 40 ms sleeps** (Plan-1 deferred #3). Any new
  write that depends on a freshly-read table inherits that timing risk; add a settle-poll where a write
  reads back through it.
- **Enum presentation is unconfirmed** — `set_plugin_option`'s mechanism (plain menu vs search field) is
  Task-0-gated; the tool is the most probe-dependent piece and may need the search path instead.
- **Third-party undo behavior** may differ from stock; the ship gate exercises a third-party write, so the
  undo branch must hold there too.

## First implementation step

Task 0 (the live actuation probe) is the plan's first task, run live at implementation start. Its finding
selects the converger strategy, the undo branch, and the enum-select mechanism; its captured fixtures are
what the parsing and converger tests build on.
