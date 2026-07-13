# logic-mcp Phase 2 — AX Mixer Core (Design)

**Date:** 2026-07-10
**Status:** Approved direction, pre-implementation
**Supersedes (in part):** the layer boundary drawn in `2026-07-08-logic-mcp-design.md`
(see "Relationship to the original design")

## Summary

Introduce an **Accessibility (AX) layer** as the *primary* read/write and
self-verification path for Logic Pro's mixer, addressing channel strips by full
track name with **no bank window, no window focus, and no calibration**. MCUBridge
is retained as a fallback and for what it does uniquely well (transport, real-time
metering, no-permission operation), but it is no longer the primary mixer channel.

This phase re-homes the mixer read path and the core mix write tools onto AX, and —
conditional on a first-task probe — re-homes the three tools that are currently
broken on MCU (`set_send`, `get_plugin_params`, `set_plugin_param`). Structural ops
(`create_track`, `insert_plugin`, routing, quantize, `checkpoint`) and VisionVerifier
are explicitly **deferred to Phase 3**.

## Why this phase, and why now

Phase 1 delivered MCU mixer/transport/plugin control, but the first real-Logic smoke
run scored 9 pass / 3 fail / 1 caveat, and the three failures share one root cause: the
MCU plugin/send view follows Logic's *selected* track, and the selection has not always
landed when we read — so `get_plugin_params` returned the **wrong track's** plugin and
`set_plugin_param` can **write** to it. That is the most dangerous bug in the project.

While scoping the next phase we probed Logic Pro 12.3's accessibility tree directly and
found it is **richly, deterministically addressable** — and, decisively, that **AX writes
to the mixer land while Logic is in the background, without stealing focus.** That single
fact overturns the original design's justification for MCU-as-primary (which rested on
"MCU works without focus; AX requires Logic frontmost"). For the mixer, AX is both
no-focus *and* strictly more reliable than MCU.

### Empirical findings that ground this design (Logic Pro 12.3, real, this session)

Read-side (recon walk of the AX tree, Logic **not** frontmost):

- The Mixer window exposes `AXLayoutArea desc="Mixer"` containing one
  `AXLayoutItem desc="<full track name>"` per channel strip — **full, untruncated
  names**, unlike MCU's 7-char LCD cells.
- Each strip contains, addressable by role+description:
  - `AXTextField desc="name" val=<name>` — the track/channel name (editable)
  - `AXButton sub=AXSwitch desc="mute" val=off|on [Press]` — **state readable, toggles**
  - `AXButton sub=AXSwitch desc="solo" val=off|on [Press]`
  - `AXSlider desc="volume fader" val=<0..N> [Increment,Decrement]`
  - `AXTextField title="volume fader level, 0.0 dB" desc="volume fader level"` —
    **the exact dB, as a string, for free** (no fader curve required)
  - `AXSlider desc="pan" val=<signed> [Increment,Decrement]`
  - `AXGroup desc="Read, automation enabled"` — automation mode, readable
  - `AXButton desc="Bus 9"` — output routing destination (shows current dest)
  - `AXButton desc="send button"`, `AXButton desc="audio plug-in"`,
    `AXButton desc="EQ" val=on|off` — send slot, insert slot, Channel EQ presence
- The arrange window ("… - Tracks") additionally exposes the Control Bar
  (Play/Record/Cycle as `AXCheckBox`, Tempo/Key/Time-Signature displays), track headers
  as `AXLayoutItem desc='Track 4 "bass"'`, and the full menu bar
  (File/Edit/Track/Navigate/Record/Mix/View/Window/Help).

Write-side (net-zero probe, Chrome frontmost the entire time, Logic never activated,
focus never stolen):

| Mechanism | Result (Logic backgrounded) |
|---|---|
| `AXPress` on the mute button | `off → on → off` ✅ |
| `AXIncrement` on the volume slider | `173 → 183 → 173` ✅ |
| `AXSetValue` on the pan slider (direct value write) | `0.0 → 1.0 → 0.0` ✅ (`settable=true`) |

**Conclusion the design rests on:** the real boundary is not "MCU = mixing vs AX =
structure." It is **direct element manipulation (AX or MCU — no focus) vs.
keyboard/menu/dialog-driven ops (need Logic frontmost)**. Within direct manipulation, AX
beats MCU at the mixer on every axis that caused a Phase 1 bug: exact values instead of a
calibrated curve; direct mute/solo/pan state instead of an LED cache; per-strip plugin
access instead of a selection race; full names instead of truncation.

### What this dissolves (rather than fixes)

- **Wrong-track plugin read/write** (Phase 1 open item #1, highest priority): AX plugin
  slots hang off `AXLayoutItem desc="<track>"` directly — there is no "selected track" to
  race. The fix is a better path, not an MCU repair.
- **`settle()` hangs during playback** (open item #2): AX reads element values
  synchronously and never waits for a quiet MIDI window. The mixer path stops depending on
  `settle()` at all. (We still deadline `settle()` — see MCU demotion.)
- **Shadow model never learns mute/solo/pan** (open item #5): a single AX mixer read
  populates all of it, with full names.

## Goal

Make AX the primary, self-verified, no-focus path for reading the mixer and for the core
mix write operations, and prove the AX layer end-to-end against real Logic — shipping the
dangerous-bug fix by routing plugin/send reads through AX.

## Non-goals (this phase)

- No structural ops: `create_track`, `insert_plugin`, routing creation, quantize/flex,
  `checkpoint`. These are menu/dialog/keystroke-driven, need Logic frontmost, and carry the
  version-fragile selector risk. **Phase 3.**
- No VisionVerifier. A self-verifying mixer (AX reads back the value it wrote) has almost
  nothing for vision to do. Vision earns its place alongside structural ops. **Phase 3.**
- No automatic AX→MCU fallback wiring. Tools are AX-primary; if Accessibility is
  unavailable they return a clear structured error. MCU stays intact in the tree but is not
  auto-invoked for the mixer. Automatic fallback is a deliberate later feature, once the AX
  path is trusted.
- No code-signing / TCC-entitlement work. The dev daemon inherits the host terminal's
  Accessibility grant through the process tree (verified: an unsigned probe binary read and
  wrote Logic's AX tree under iTerm's grant). A binary that holds its *own* grant is a
  **distribution** concern, deferred to the packaging phase.

## Architecture

Three new units compose onto the existing `Daemon` (which today holds `session`
[MCU], `model`, `navigator`, `journal`). Nothing about the MCP tool surface —
tool names, argument schemas, the "verified ground truth" contract — changes; only the
implementation behind the mixer tools swaps to AX.

```
Daemon
 ├─ session   : MCUSession        (retained — transport, metering, fallback)
 ├─ navigator : MixerNavigator    (retained — MCU banking, now fallback-only)
 ├─ ax        : AXBridge          (NEW — primary mixer read/write)
 ├─ axMixer   : AXMixer           (NEW — reads full mixer → ProjectModel)
 ├─ model     : ProjectModel      (unchanged shape; now populated from AX)
 └─ journal   : UndoJournal       (unchanged)
```

### 1. `AXProvider` (protocol) + `SystemAXProvider` + `FakeAXTree`

The test seam, mirroring the existing `MCUWire` / `InMemoryWire` split that made the MCU
layer unit-testable. This is the load-bearing decision of the phase: without it, every AX
tool is integration-test-only against real Logic.

- `AXProvider` — a narrow protocol over the AX operations the bridge needs: enumerate an
  element's children, read an attribute (`role`, `subrole`, `description`, `title`,
  `value`, `settable?`), perform an action (`AXPress`, `AXIncrement`, `AXDecrement`), and
  set a value (`AXSetValue`). Element identity is an opaque handle the protocol vends.
- `SystemAXProvider` — wraps the real `AXUIElement` C API (`ApplicationServices`).
- `FakeAXTree` — an in-memory node tree (role / subrole / description / title / value /
  actions / children) that mirrors the real mixer layout captured by `axdump`. Actions
  mutate the fake node's value, so a "press mute" flips `val` exactly as Logic does. Tool
  logic — find strip by name, parse the dB title, decide press-or-not, verify read-back —
  is exercised entirely against this fake.

**Invariant, asserted in tests:** neither provider activates Logic or sets
`kAXFrontmost`. No-focus operation is the whole point.

### 2. `AXBridge` (actor)

The AX analog of `MCUSession`. Holds the `AXProvider` and Logic's application element.
Responsibilities:

- **Locate the mixer surface.** Find the Mixer window (or the arrange window's mixer pane)
  and its `AXLayoutArea desc="Mixer"`. If absent, throw a structured error
  (`expected: "an open Mixer", observed: "no mixer surface"`) rather than guessing.
- **Find a strip by full name.** Match `AXLayoutItem desc == name` (case-insensitive,
  unique-prefix ok, matching `ProjectModel.track(named:)`'s rules). Duplicate names throw
  the same ambiguity error the model already produces.
- **Read a strip's controls:** name, volume `val` + dB parsed from the fader-level title,
  pan `val`, mute/solo `val`, output-dest description, EQ/plugin-slot presence.
- **Write a strip's controls:** `AXPress` (mute/solo), `AXSetValue` where settable
  (pan; volume if settable — probe), else `AXIncrement`/`AXDecrement` stepping to target.
- **Never** activates Logic.

Keyed on `role` + `description` + `value`, **never** on `AXIdentifier` (the `_NS:48`-style
ids are unstable across builds and layouts).

### 3. `AXMixer`

Reads the whole mixer into `ProjectModel` in one pass: full names, volume/dB, pan, mute,
solo, output. Replaces the MCU bank-walk as the source for `refresh_state`. Because AX
addresses every strip regardless of the visible bank, there is no banking, no overlap-
geometry, and no truncation to reconcile. Provides the per-strip accessors the tools call.

`ProjectModel` / `TrackState` already carry `index/name/volumeRaw/volumeDB/pan/mute/solo`;
this phase may add an `output: String?` field for routing destination. No breaking change.

### 4. `logic-mcp axdump` (CLI diagnostic) — deliverable #1

The AX analog of `lcdprobe`/`probe`, built **before** any tool code, because this
project's every real discovery has come from a diagnostic and every bug from acting blind.
Subcommands/modes:

- `axdump tree` — the full window/role tree to a depth (what recon did).
- `axdump strip <name>` — one strip's controls, their values, settable flags, and actions.
- `axdump plugin <name> <slot>` — open state of a plugin window and its control tree
  (resolves open question #1a).
- `axdump send <name>` — the send UI and whether levels are settable (open question #1b).

Unlike the MCU diagnostics, `axdump` does **not** contend for the virtual MIDI port, so it
can run while `serve` is live — but it still mutates UI (opening a plugin window), so it
restores what it opened.

### 5. MCU demotion (small, safety-critical)

- **Deadline `settle()`.** Give `MCUSession.settle()` an overall timeout so no surviving
  MCU path (transport, fallback) can hang the MCP client if Logic streams meters forever.
- Keep MCUBridge and its tests fully intact for transport, metering, and future fallback.
- **The guard.** The three currently-broken MCU tools (`set_send`, `get_plugin_params`,
  `set_plugin_param`) move to AX. Their old MCU implementations — the ones that press
  `.assignSend`/`.assignPlugin` and read whatever the *selected* track shows — are
  **disabled** this phase (the code stays in the tree, but the tools no longer invoke it),
  so the wrong-track read/write cannot recur even intermittently. Where AX cannot reach a
  given plugin/send, the tool returns a structured error; it never silently reactivates the
  MCU path and never fabricates data.

## Tool-by-tool changes

| Tool | Phase 2 change |
|---|---|
| `refresh_state`, `get_project_overview`, `get_track` | Read via `AXMixer` (full names, pan/mute/solo/output populated). |
| `set_volume` | AX-primary. `AXSetValue`/step the volume slider; return exact dB parsed from the fader-level title (`source:"ax"`). |
| `set_pan` | AX-primary. `AXSetValue` on the pan slider; return the pan Logic reports back. |
| `set_mute`, `set_solo` | AX-primary. Read `val`; `AXPress` only if it differs; verify by re-read. Idempotent by construction. |
| `set_automation_mode` | Read current mode from the automation `AXGroup`. Setting it may need the strip's automation popup — **probe**; if not cleanly settable via AX this phase, keep on MCU. |
| `set_send` | Re-home to AX. Where `axdump send` shows the level is not AX-settable, return a structured "send level not accessible via AX" error — do **not** fall back to the broken MCU send path. |
| `get_plugin_params`, `set_plugin_param` | Re-home to AX. Stock/AU-addressable plugins resolve; opaque (e.g. some third-party) plugins return a structured "parameters not accessible" error. **Never fabricate params** (a Phase 1 sin). The dangerous MCU plugin path is **disabled** this phase so the wrong-track write cannot recur — see the guard note below. |
| transport (`play`/`stop`/`record`/`toggle_cycle`) | Unchanged (MCU). Optionally cross-checked against the Control Bar's AX `val` — nice-to-have, not required. |

## Verification contract (unchanged principle, cleaner mechanism)

Every tool still returns verified ground truth. For AX, verification is a **synchronous
read-back of the same element** after the write — no echo races, no coalesced bursts, no
inferred state. `set_volume` returns the dB Logic itself renders in the fader-level title;
`set_pan`/`set_mute`/`set_solo` return the re-read `val`. If the post-write read does not
reflect the request, the tool throws with `{expected, observed}`.

## Open questions — resolved in the plan's first task, not guessed here

1. **AX reach of the two probe-dependent tools.**
   a. Are a plugin window's **parameter values** AX-addressable (stock AUs likely yes;
      third-party may be opaque)?
   b. Are **send levels** AX-settable from the strip's send UI?
   Each answer decides "move to AX now" vs "keep on MCU behind a guard."
2. **Mixer surface absent.** If neither the Mixer window nor the arrange mixer pane is
   open, the strips do not exist in the tree. Default: clear structured error telling the
   user to open the mixer. Auto-open (needs focus) is deferred.
3. **Duplicate track names.** AX gives full names, but two identical ones are still
   ambiguous. Reuse `ProjectModel`'s ambiguity error; consider an optional index later.
4. **Volume slider settability.** `AXSetValue` proven for pan; volume verified only via
   `AXIncrement`. Probe whether volume is directly settable (fast path) or must be stepped.

## Testing

- **Unit:** tool logic against `FakeAXTree` — find strip by name, dB-title parsing
  (including `-∞`/silence), press-only-if-different, read-back verification, ambiguity and
  missing-mixer errors. Assert the no-activation invariant.
- **Integration:** `axdump` plus a re-run of the smoke checklist against real Logic, with
  AX-specific items added (background write lands; wrong-track plugin read cannot recur;
  mute-by-hand-then-read reflects truth). This is the smoke gate for every Logic update.

## Risks and mitigations

- **AX fragility across Logic updates.** Keyed on role+description, never `AXIdentifier`;
  MCU remains a working fallback; the integration smoke suite runs on every Logic update.
- **Mixer must be open.** Mitigated by a clear structured error now, auto-open later.
- **Third-party plugin windows may be opaque.** Exactly what probe #1a settles before any
  plugin tool code is written; opaque → that tool stays on MCU behind its guard.
- **Two source-of-truth paths (AX and MCU) for the same state** could drift. Mitigated by
  making AX the single writer/reader for the mixer this phase and not auto-invoking MCU.

## Relationship to the original design (`2026-07-08`)

The original design is unchanged in intent — layered side doors, verified ground truth,
shadow model, skill packs. This phase **redraws one boundary**: the mixer moves from MCU
to AX as its primary actuator, because the no-focus advantage that justified MCU-as-primary
turns out to belong to AX as well, with better fidelity. MCU keeps the roles only it can
fill. The four-layer thesis (MCU / AX / File / Vision) stands; this is the first proof of
the AX layer, drawn tighter than the original "AX = structure only" sketch now that we know
what the tree actually exposes.

## What Phase 3 looks like (for context, not commitment)

Structural ops on AX + a minimal VisionVerifier: `create_track`, `insert_plugin`, routing,
quantize/flex, `checkpoint` (Project Alternatives), the canonical key-command set via
CGEvent — the focus-stealing, dialog-driven, version-fragile half — with screenshots
auto-attached to AX structured errors, where a picture actually helps.
