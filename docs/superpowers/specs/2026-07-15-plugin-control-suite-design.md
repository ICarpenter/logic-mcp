# logic-mcp Phase 4 — Plugin-Control Suite + Learned Profiles (Design)

**Date:** 2026-07-15
**Status:** Approved direction, pre-implementation
**Builds on:** Phase 3 (`2026-07-13-ax-structural-ops-design.md`, merged — `create_track`,
`set_output`, `insert_plugin`, `undo_structural`) and the Phase 2 AX read/write layer
(`AXBridge`, `axEnterPlugin`, `nudgeToRaw`).

## Summary

We can **insert** a plugin but barely **operate** one. This phase gives the agent full no-focus,
self-verified control of an inserted plugin's controls — read/write every parameter (named,
unit-valued), press buttons/switches, select popups and presets — plus **load an instrument** into a
software-instrument track. The key enabler, **confirmed by a 2026-07-15 live probe across Apple,
JUCE, and proprietary-UI (UAD) plugins:** Logic's generic **"Controls" view** exposes every plugin's
AU parameters as one uniform, fully-labelled, unit-valued, settable table — vendor-agnostic. Reading
*that* table (instead of the plugin's custom Editor UI) dissolves the two hardest problems in the
original plan — anonymous-slider naming and the missing unit oracle — and makes third-party coverage
near-universal rather than best-effort. Underneath sits a **server-side learned-profile store**: the
engine profiles each plugin on first sight, persists an adapter-grade descriptor keyed by plugin
identity, and consults it thereafter — adapter fidelity with zero hand-written per-plugin code,
portable to any MCP harness, degrading honestly for the rare truly-opaque plugin. All AX, no focus
stolen, every write verified oracle-first.

## Why this phase

In a plugin's native **Editor** view (its custom UI), `get_plugin_params`/`set_plugin_param` are
insufficient — ground truth from the live Compressor window (`AXDialog title="Kick Drum"`) and the
2026-07-15 third-party probe:

- **Mode/circuit switches are `AXButton`s, not sliders** — seven `Vintage Opto` … `Platinum Digital`,
  plus `ON`/`OFF`/`AUTO`/`0 dB`/`-12 dB`, and an `AXPopUpButton value="Default Preset"`.
- **Most knobs are anonymous** — only Compressor `Threshold` carries a `description`; the rest are
  `AXSlider` with no name. Third-party is worse: **SketchCassette II** (JUCE) exposes ~30 settable
  sliders with unit values but **zero names**; **UAD AKG BX 20** is **fully opaque** — its custom view
  is one `AXGroup subrole="AXUnknown"` of unnamed, valueless blobs, i.e. no addressable controls at all.
- **Values are raw, with no guaranteed unit oracle** — the Compressor `dB = 0.5·raw − 50` mapping came
  from the *user's eyes*, not from AX. This breaks the "verify against an independent oracle" invariant.

### The 2026-07-15 live probe: Logic's Controls view is a universal surface

Every plugin window carries an `AXMenuButton description="view"` that toggles between **Editor** (the
custom UI) and **Controls** (Logic's Cocoa-generated AU parameter view). Switching to **Controls**
yields **one uniform, fully-labelled table for any plugin, regardless of vendor**:

```
AXScrollArea → AXTable → AXRow → AXCell →
  AXStaticText value="Dry/Wet:"      ← parameter NAME
  AXGroup      value="15 %"          ← display value WITH UNITS  (the oracle)
  AXSlider     value="5000" settable ← the settable control (raw)
      # enum params: AXPopUpButton value="Standard";  bool params: AXCheckBox
```

| Plugin | Vendor tech | Editor view | **Controls view** |
|---|---|---|---|
| Channel EQ / Compressor | Apple | named + anonymous sliders, no readout | uniform named + valued table |
| SketchCassette II | JUCE | settable sliders, unit values, **no names** | **named + valued + settable** |
| UAD AKG BX 20 | proprietary | **fully opaque** (`AXUnknown`, no controls) | **named + valued + settable** (17 params) |

**Consequence — the design reads the Controls view, not the Editor view.** That single choice
dissolves two of the three problems: **names** come from each row's `AXStaticText` (no geometry
correlation), and the **unit oracle** is each row's `AXGroup` display string (universal, third-party
included). What remains: press the header/preset controls, and give the agent **stable names** across
sessions. Names are already in the table, but hand-curating thousands of plugins doesn't scale and the
server must work under any harness (so knowledge can't live in agent-side skills) — hence the engine
**learns and caches** each plugin's table as data, server-side.

## Goal

No-focus, self-verified control of an inserted plugin's full control set (sliders, buttons, radios,
popups, presets) and instrument-slot loading, backed by a persisted learned-profile store that gives
adapter-grade addressing without per-plugin code and degrades honestly where AX is opaque.

## Non-goals (this phase)

- **Preset *save* / user-preset authoring.** Writes files and user-preset state — a FileGateway
  concern. Load / list / previous-next only.
- **Active-sweep and Vision calibration.** Not needed for the common case — the Controls view gives a
  live display string per parameter, so sets verify closed-loop without any stored raw↔unit curve.
  Sweeping a control against a Vision-OCR / user-anchored oracle (with restore + consent) is a real
  additional subsystem, **deferred**, and now only relevant to the rare opaque (no-AU-param) plugin.
  Profiles reserve a `calibration?` field for it.
- **Parameter automation / modulation.** This phase sets static values, not automation curves.
  (Automation mode stays where Phase 2/3 left it.)
- **Not opaque-plugin heroics.** The Controls view makes third-party coverage near-universal (proven
  on UAD + JUCE), so third-party is a first-class target, not best-effort. The one genuine gap — a
  plugin exposing *zero* AU parameters (none found in the probe) — is reported `opaque`, not worked
  around (no Vision/screen-scraping this phase).
- **Sends.** Unchanged — still the structured "not available via AX" error from Phase 2.

## Design

### Three layers

1. **Generic AX control engine** — walks an open plugin window, types each control, addresses it.
2. **Plugin profile store** — server-side, persisted; the engine learns into it and reads from it.
3. **Oracle-first verification** — per control kind, closed-loop where AX gives a readback, honest
   `verified:false` fallback where it doesn't.

### Layer 1 — the generic control engine (reads the Controls-view table)

After opening a plugin window, the engine **switches it to Controls view** (press the
`AXMenuButton description="view"`, select `Controls`) — because that view is the uniform,
fully-labelled surface, and because close-then-open reverts to Editor (probe finding). It then walks
the `AXTable` and yields one `Control` per `AXRow`/`AXCell`:

```
ControlKind = .slider | .toggle | .popup      // the three cell shapes the Controls table uses
Control = {
  index: Int            // row order, stable within a fingerprint
  name: String          // the cell's AXStaticText label, e.g. "Dry/Wet"  (trailing ":" trimmed)
  kind: ControlKind
  handle: AXHandle      // the AXSlider / AXCheckBox / AXPopUpButton — NEVER persisted; re-resolved
  settable: Bool
  display: String?      // the cell's AXGroup value string, e.g. "15 %", "0.0 dB", "Off", "Mono"
  choices: [String]?    // for .popup cells (AXPopUpButton)
}
```

- **Name and value are structural, not heuristic.** Each `AXCell` holds the label
  (`AXStaticText`), the human display+units (`AXGroup value=…`), and the control
  (`AXSlider`/`AXCheckBox`/`AXPopUpButton`) as siblings. No frame-geometry correlation, no
  confidence scoring, no reliance on a plugin's custom `description`s — the same walk works for
  Apple, JUCE, and proprietary-UI plugins alike.
- **Cell → kind.** `AXSlider`→`.slider` (continuous *or* stepped/enum — some enums render as a slider
  whose `AXGroup` shows text like `"A"`/`"Sine"`); `AXPopUpButton`→`.popup`; `AXCheckBox`→`.toggle`.
- **Header controls stay separate.** bypass, compare, previous/next, and the preset `AXPopUpButton`
  live in the window header (outside the table) and are addressed there — this is what
  `press_plugin_control` / `load_preset` drive.
- **Truly-opaque fallback.** A plugin exposing **no AU parameters** has an empty/absent Controls table
  (rare; UAD/JUCE both populated it). The engine then reports the window as opaque — honest, no
  fabrication.
- **No cross-call handle caching.** Every tool re-walks and re-resolves by name/index each call — the
  codebase's #1 bug class is a stale handle across a mutation. The profile stores *addressing metadata*
  (row order, names, kinds, choices), never live handles.

### Layer 2 — the plugin profile store (the stateful backbone)

MCP calls stay stateless; state lives in the long-lived daemon plus a persisted store — the same
shape as the existing shadow project model, but keyed by plugin and durable across restarts.

- **Identity / key.** `pluginName + version` (stock ⇒ Logic version from the build stamp;
  third-party ⇒ its own version string when exposed). One plugin ⇒ one profile file.
- **Structural fingerprint.** A hash of the control skeleton (ordered kinds + names + choice sets).
  On retrieval, if the live skeleton's fingerprint ≠ the stored one, the profile is **stale** →
  re-learn. This is how **morphing UIs** are handled: the Compressor showing different knobs per
  circuit model simply produces a different fingerprint; the store keeps per-fingerprint variants
  rather than one wrong static map. Same staleness discipline as the mixer shadow model's `staleAt`.
- **Storage.** `~/Library/Application Support/logic-mcp/profiles/<id>.json`, user-writable and
  surviving app updates. A **seed library** ships read-only in the repo (`Resources/Profiles/`) and is
  merged under the user store (user copy wins). Profiles are plain JSON — human-reviewable and
  shareable.
- **Profile contents** (per control): `index` (row order), `name`, `kind`, `settable`, `choices?`,
  and `unit?` (the display string's parsed unit/format — `%`, `Hz`, `dB`, enum-set — learned from the
  row's `AXGroup`). A reserved `calibration?` (raw↔display curve) stays empty this phase: since the
  Controls view already gives a live display string, sets verify closed-loop without a stored curve —
  the field is only for the deferred no-readout / active-sweep case.
- **In-memory cache.** The daemon lazy-loads a profile on first use and holds it for the process
  lifetime; writes go through to disk.

### Layer 3 — oracle-first verification, per control kind

- **Slider** — the row's `AXGroup` **display string is the oracle** (present for every param in the
  Controls view, third-party included). The tool accepts a unit string (`"-6 dB"`, `"25 %"`) *or*
  normalized 0–1, converges the raw `AXSlider` by nudging (`nudgeToRaw`; ±1 per set — ax-findings.md),
  and verifies the display string reached the target. `verified:false` is now the rare exception —
  only a plugin with no Controls table at all (opaque) falls back to raw with no unit claim.
- **Toggle** (`AXCheckBox`) — press, re-read the checkbox value; confirm it flipped. Closed-loop.
- **Popup** (`AXPopUpButton`, in-table enums and the header preset menu) — select the choice, then
  re-read the popup's displayed value == requested. Closed-loop.
- **Header button** (bypass, compare, previous/next preset) — press, and where the control exposes
  state (bypass/compare are `AXCheckBox`) verify it; momentary ones (prev/next) report `pressed`.

## Tool surface

| Tool | Kind | Behavior |
|---|---|---|
| `get_plugin_params` | upgraded | Switches to Controls view and returns the **unified control map** — every row as `{index, name, kind, display, choices?, settable}`. **Passive-learns and auto-caches** a profile (safe: reads only, moves nothing). |
| `set_plugin_param` | upgraded | Continuous/stepped sliders. Accepts normalized 0–1 **or** a unit string (`"-6 dB"`); converges the raw slider; verifies against the row's display string. |
| `set_plugin_option` | new | Selects a value in an **enum parameter** (in-table `AXPopUpButton` — e.g. Tape Type, and a Compressor circuit model if it renders as a popup) by choice name. |
| `press_plugin_control` | new | Toggles/presses a non-knob control by name — an in-table `AXCheckBox` (Direct, Power…) or a header button (bypass, compare, previous/next). Verifies state where the control exposes it. |
| `load_instrument` | new | Loads a named instrument into a software-instrument track's Instrument slot (search-popup mechanism; slot identity mapped in Task 0). |
| `load_preset` / `list_presets` | new, thin | Convenience over the header preset `AXPopUpButton` + previous/next arrows. |
| `learn_plugin` / `list_plugin_profiles` | new | Explicit (re)learn of the current slot (passive this phase) + introspection over the store. |

**Notes.** `load_preset` is a thin convenience over `set_plugin_option` on the header preset popup
(plus prev/next) — ergonomics, not separate machinery. A **circuit-model / mode switch** is no longer
a special "press a radio button" case: in Controls view it is just another parameter row, reached via
`set_plugin_option` (if a popup) or `set_plugin_param` (if a stepped slider).

## Data flow (any control tool)

1. Resolve the strip by name (fresh mixer walk).
2. **Close-then-open** the requested slot's plugin window (Phase 2 discipline — at most one window per
   track title, so we never read the wrong slot). Window detection must **not** require an `AXSlider`
   (an opaque Editor view has none — probe finding); detect by dialog title + `close` button + the
   `view` menu.
3. **Switch the window to Controls view** (press the `view` `AXMenuButton` → `Controls`) — close-then-
   open reverts to Editor, so this is done every time before reading the table.
4. Look up `(id, fingerprint)` in the profile store. **Hit + valid** ⇒ use the profile for addressing
   / choices. **Miss or stale** ⇒ derive live from the Controls table **and auto-persist a passive
   profile**.
5. Perform the action (nudge-converge / toggle / select).
6. **Verify oracle-first** for the control's kind (the row's display string for sliders); re-read from
   a fresh walk, never a captured handle.
7. Return the achieved state with an honest `verified` flag; journal mutations for undo.

## Error handling (structured `ToolFailure(layer:"ax")`, matching the codebase)

- Slot out of range / no plugin in slot → existing `axEnterPlugin` error (unchanged).
- Control not found by name/index → error listing the available control names/indices (as
  `set_plugin_param` does today).
- Popup/preset choice not found → error listing available choices from the live menu.
- Opaque plugin (empty/absent Controls table) → `get_plugin_params` returns an empty control list with
  an `opaque:true` note; setters return a structured "plugin exposes no addressable parameters".
- Instrument slot not present (audio track, no instrument slot) → structured "no instrument slot on
  this track".
- Slider set where the display string is unparseable (unexpected unit format) → the raw write still
  lands but returns `verified:false` with the raw value + the raw display string; it does not fail.

## Task 0 — live re-probe (partly done 2026-07-15; capture fixtures + close the gaps)

The 2026-07-15 probe already settled the two biggest unknowns — **the Controls view exists and is a
uniform named+valued+settable table for Apple, JUCE, and proprietary-UI plugins** (see the table
above), so anonymous-slider correlation and the missing-oracle problem are moot. Remaining before the
plan, capturing fixtures under `Tests/LogicMCPCoreTests/Fixtures/ax/`:

1. **The Controls-view raw scale + set behavior.** Sliders read raw integers (`0`, `5000`, `10000`,
   `1403`); confirm the min/max range (looks like 0–10000, center 5000) and that `nudgeToRaw` +
   display-string oracle converges reliably. Capture a Channel EQ / Compressor / SketchCassette /
   UAD row set.
2. **Enum rendering.** Which stepped params render as in-table `AXPopUpButton` vs an `AXSlider` whose
   `AXGroup` shows text (SketchCassette had both) — so `set_plugin_option` vs `set_plugin_param`
   dispatch is correct. Confirm where the **Compressor circuit model** lands in Controls view.
3. **The `view` switch mechanism.** Confirm pressing the `view` `AXMenuButton` and selecting
   `Controls` works no-focus and sticks for the read; capture the menu's items.
4. **Instrument slot + preset popup presentation** — slot identity vs FX slots; header preset menu
   flat vs hierarchical factory folders.
5. **Fingerprint stability** — capture the Compressor under two circuit models to confirm the
   skeleton (and thus fingerprint) changes as expected.

Known already from the probe (fold into the plan, not open questions): **third-party plugin names are
truncated in the strip's `AXGroup` description** (`UAD AKG BX 20`→`UAD AKG BX`, `SketchCassette
II`→`SketchCass`), so slot addressing and `insert_plugin`'s confirm must match by **prefix/contains,
not equality** (today's exact-match confirm false-negatives on these — observed live). And **window
detection must not require an `AXSlider`** (opaque Editor views have none).

## Testing

- **Fixture-parsing unit tests** (the established pattern — AX needs real Logic): Controls-table
  parsing (row → `{name, kind, display, choices, settable}`) across the captured Apple / JUCE / UAD
  fixtures; enum-as-popup vs enum-as-slider dispatch; display-string → unit parsing (`%`, `Hz`, `dB`,
  enum); the opaque (empty-table) fallback.
- **Profile-store tests**: learn-from-fixture → JSON round-trip; fingerprint computation + stale
  detection (feed a mutated skeleton, assert re-learn); seed-vs-user merge precedence; consult-with-
  fallback (miss ⇒ live derive + persist).
- **Live `smoke --plugins`**: end-to-end on `mcp_test` — learn a plugin, read the map, set a knob by
  unit (verified against the display string), select an enum/circuit-model, toggle a checkbox, select
  a preset, load an instrument, confirm focus is never stolen and the net effect undoes cleanly.
  Should exercise a third-party plugin (UAD or SketchCassette) to prove vendor-agnostic coverage.

## Open risks (carry into the plan)

- **Controls-view set convergence** — the raw slider scale (≈0–10000) plus the ±1 nudge means a set
  may need many steps; Task 0 must confirm `nudgeToRaw` + display-oracle converges quickly enough, and
  that stepped/enum sliders quantize cleanly.
- **The `view` switch adds a step to every call** — pressing `view → Controls` on each open (since
  close-then-open reverts to Editor) is extra AX traffic and a new failure point; needs a settle-poll
  confirm like the rest.
- **Truly-opaque plugins** — the probe found none (UAD and JUCE both populated the Controls table),
  but a plugin exposing zero AU parameters would be genuinely uncontrollable; the `opaque:true` path
  handles it honestly.
- **Morphing UIs** — some plugins restructure the parameter list on mode changes; per-fingerprint
  variants handle it but can multiply profile entries. Acceptable; monitor.
- **Instrument-slot identification** — depends on Task 0's tree; `load_instrument` is the most
  probe-dependent tool and may slip if the slot isn't cleanly addressable.

## First implementation step

Task 0 (capture the Controls-view fixtures + close the raw-scale / enum-dispatch / view-switch /
instrument-slot gaps) is the **plan's first task**, run live at implementation start. The two decisive
fixtures — UAD AKG BX 20 and SketchCassette II in Controls view — are already captured; the rest
(stock Channel EQ / Compressor Controls view, the `view` menu, the instrument slot, the preset menu)
are captured then. Those fixtures are what the parsing tests and each tool's details build on.
