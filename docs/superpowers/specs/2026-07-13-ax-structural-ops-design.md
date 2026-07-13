# logic-mcp Phase 3 — AX Structural Ops (Design)

**Date:** 2026-07-13
**Status:** Approved direction, pre-implementation
**Builds on:** Phase 2 (`2026-07-10-ax-mixer-core-design.md`, merged). **Redraws (again)** the
"structural ops = focus-stealing keystroke/vision half" boundary from `2026-07-08-logic-mcp-design.md`.

## Summary

Give the agent **structural control of Logic Pro** — create/delete/rename/select tracks, insert
plugins, set output routing, and snapshot the project — driven by **`AXPress` on menu items and
popup/dialog controls**, no-focus, and **verified by re-reading through the Phase 2 AX layer**.
Region ops (quantize, flex) and a standalone VisionVerifier are explicitly deferred.

## Why this phase, and why the original "keystroke/vision half" premise is wrong

The original design cast structural ops as the fragile half: Accessibility-tree walking *plus a
canonical CGEvent key-command set*, requiring Logic frontmost, with VisionVerifier to confirm
actions landed. Phase 2 already showed the mixer was far more AX-addressable than assumed. A
Phase-3 menu probe (real Logic 12.3, this session) shows the same is true for structure:

**Logic's menus are fully AX-readable AND `AXPress`-able — statically (no need to open the menu
first) and with Logic in the BACKGROUND** (`app.isActive == false` during the probe; nothing was
activated). Every menu item exposes an `AXPress` action and its key-command equivalent. Concretely:

- **`Track` menu:** `New Audio Track` (⇧⌘A), `New Software Instrument Track` (⇧⌘S), `New External
  MIDI Track` (⇧⌘X) — **direct actions, no dialog**; `New Tracks…` (⇧⌘N) — configurable dialog;
  `Rename Track`, `Delete Track`, `Delete Unused Tracks`, `Create Track Stack…`.
- **`File` menu:** `Project Alternatives → New Alternative… / Edit Alternatives…` (the checkpoint
  path); `Save`, `Save As…`, `Save A Copy As…`, `Revert to`.
- **`Mix` menu:** `Search and Add Plug-in…` (⌥⌘P) — a menu-driven plugin-insert path alongside the
  strip's plugin-slot popup; `Create Group`, `I/O Assignments…`.
- **`Edit` menu:** `Undo` (⌘Z), `Redo`, `Undo History…` — real Logic-native undo.

**Conclusion.** Structural ops are AX-menu/popup/dialog-driven: no synthesized keystrokes, no
required frontmost, no vision as actuator. This is the same reframing Phase 2 made for the mixer,
and it means the whole product can run with Logic in the background.

### What this does to VisionVerifier

The original design paired vision with structure because structure was assumed opaque. It isn't:
AX both drives and verifies. A screenshot is therefore at most an **on-error diagnostic**, never an
actuator. A standalone VisionVerifier is **deferred** — if wanted later, it's a thin
`screenshot(target)` tool plus attaching a capture to structured errors, addable without touching
this phase's tools.

## Goal

Deliver no-focus, self-verified structural control of tracks and plugins, reusing the Phase 2 AX
read layer as the verification oracle, with a working checkpoint as the safety spine.

## Non-goals (this phase)

- **Region ops:** `quantize_selection`, `enable_flex`. Quantize has no top-level menu — it needs
  region selection and a Quantize control in the Region inspector, a different (timing) cluster that
  aligns with the later FileGateway/MIDI work. **Phase 4.**
- **Standalone VisionVerifier / ScreenCaptureKit.** Deferred (see above).
- **CGEvent key-command set.** The menu probe shows it is unnecessary for these ops; not built. (A
  typed `run_key_command` escape hatch may return in a later phase if a genuinely menu-less op needs
  it.)
- **Content ops** (`import_midi`, `export_stems`, `analyze_audio`). FileGateway, later.

## Architecture

One new unit composes onto the existing AX layer (Phase 2: `AXProvider`/`SystemAXProvider`/
`FakeAXProvider`, `AXBridge`, `AXMixer`, `Daemon.ax`/`Daemon.axMixer`).

```
Daemon
 ├─ ax        : AXBridge        (Phase 2 — find strip, read/write controls, press, minMax, nudge)
 ├─ axMixer   : AXMixer         (Phase 2 — read whole mixer → shadow model; the VERIFICATION oracle)
 ├─ menu      : AXMenuDriver    (NEW — menu paths, popups, dialogs)
 ├─ model     : ProjectModel    (Phase 2)
 └─ journal   : UndoJournal
```

### `AXMenuDriver` (actor, behind `AXProvider`)

The one new capability: reach Logic's menus, popups, and dialogs. Testable against `FakeAXTree`
exactly like the Phase 2 AX code. Responsibilities:

- **Menu path press.** `press(path: ["Track", "New Audio Track"])` — from the app's `AXMenuBar`,
  descend `AXMenuBarItem → AXMenu → AXMenuItem` matching each level by **title** (case-insensitive),
  verify the item is enabled, `AXPress` it. Supports nested submenus (`["File","Project
  Alternatives","New Alternative…"]`). Menu structure is readable statically; if a level is empty
  until opened, open the parent first (press) then read.
- **Popup drive.** The strip's plugin-slot and output-routing buttons open popup `AXMenu`s. Open the
  popup (`AXPress`/`AXShowMenu` on the control), match the target item by title (with submenu
  descent for plugin categories), press it; on failure, dismiss (Escape / `AXCancel`) so no popup is
  left hanging.
- **Dialog drive.** The `New Tracks…` sheet: find the sheet window, set fields (count, format
  radio/checkbox, name text field) and press its `Create`/`Done` button. Reuses `AXBridge`'s
  element read/write; dialogs are AX-rich (Phase 2 confirmed).
- **Invariant:** never activates Logic / sets frontmost.

Keys on `role` + **menu-item title** / control description, never `AXIdentifier`.

### Verification reuses Phase 2 (the elegant part)

Every structural op is **act → re-read → confirm** against the Phase 2 read layer:
- `create_track` → press the menu item → `AXMixer.syncTracks()` → confirm a new strip with the
  expected name/kind exists; return it as re-read ground truth.
- `delete_track` → confirm the strip is gone. `rename_track` → confirm the new name. `set_output`
  → confirm the strip's output-dest description changed. `insert_plugin` → confirm the plugin group
  appears on the strip (`AXBridge.pluginGroups`).
No new verification machinery; the tools return verified ground truth by construction.

## Tool surface (Structure group)

| Tool | Mechanism | Verified by |
|---|---|---|
| `create_track(kind, name?)` | `Track → New Audio/Software Instrument/External MIDI Track` (direct); `New Tracks…` dialog when `kind`/count/options need it; `rename_track` if `name` given | `AXMixer.syncTracks` shows the new strip |
| `delete_track(name)` | select the strip's track, `Track → Delete Track` | strip absent on re-read; **auto-checkpoints first** |
| `rename_track(name, to)` | strip name `AXTextField` set-value, or `Track → Rename Track` | re-read name |
| `select_track(name)` | `AXPress` the track header / strip (Phase 2 exposes both) | selection reflected |
| `insert_plugin(track, slot, name)` | strip plugin-slot popup → category → plugin, OR `Mix → Search and Add Plug-in…` (probe decides which is reliable) | `AXBridge.pluginGroups` shows it |
| `set_output(track, dest)` | strip output-routing popup → dest | strip output description == dest |
| `checkpoint(label)` | `File → Project Alternatives → New Alternative…` (fallback `Save A Copy As…`) | alternative/copy exists |

MCP argument shapes follow the existing tools' conventions (`ToolFailure(layer:"ax")` on failure,
structured errors, never fabricate).

## Safety model — the spine of this phase

Structural ops create and destroy, so safety is first-class (mixing could always be nudged back):

- **`checkpoint(label)`** snapshots the project. Primary: `Project Alternatives → New Alternative…`.
  If unavailable (see Open Questions), fallback: `Save A Copy As…` to a timestamped copy. The phase
  must ship *a* working snapshot.
- **Auto-checkpoint before destructive ops.** `delete_track` creates a checkpoint if none exists for
  the current turn and refuses to run if it cannot. (Matches the original spec's safety model.)
- **Undo path.** Prefer Logic-native `Edit → Undo` (`⌘Z`) for structural ops (the menu exposes it),
  verified by re-read; fall back to checkpoint revert. The MCU-era `UndoJournal` stays for mix ops.

## Verification contract

Unchanged principle — every tool returns verified ground truth, here by re-reading the AX tree
after the action (via `AXMixer`/`AXBridge`). If the post-op read does not reflect the request, throw
`ToolFailure(layer:"ax", expected:, observed:)`. Never report assumed success; never fabricate.

## Open questions — resolved in the plan's first task (Phase 2 fixture-capture pattern)

1. **Is `checkpoint` viable via `Project Alternatives`?** The probe showed it **disabled** (as were
   `Save`/`Save As`, consistent with a no-unsaved-changes / project-format state). The plan's first
   task drives it on a scratch project to confirm it enables, else adopts the `Save A Copy As…`
   fallback. The safety model requires a working checkpoint before any destructive tool ships.
2. **Popup/dialog AX layouts**, captured as fixtures (extend `logic-mcp axdump`) before tool code:
   the `New Tracks…` sheet (fields + Create button), the plugin-insert popup vs `Search and Add
   Plug-in…` (which is reliably AX-navigable), and the output-routing popup (bus/output item titles).
3. **`insert_plugin` path choice** — strip popup (nested category menus) vs `Mix → Search and Add
   Plug-in…` (search field). Probe both; pick the one with a stable, title-addressable target.

## Testing

- **Unit:** `AXMenuDriver` against `FakeAXTree` — menu-path descent + press, enabled/ambiguity/
  not-found errors, popup open→select→dismiss, dialog fill+confirm, and the auto-checkpoint-before-
  destructive guard. Tool logic verified against a fake tree that models the post-op state (e.g. a
  `create_track` press adds a strip to the fake), mirroring Phase 2's dynamic-window fakes.
- **Integration:** a `logic-mcp smoke`-style structural pass against real Logic that is **net-zero**
  — `create_track` then `delete_track` to restore; `checkpoint` then clean up the alternative/copy;
  run on the `mcp_test` scratch project, Logic backgrounded. Structural mutations are not as trivially
  restorable as a fader value, so the smoke script must clean up after itself and the doc must say so.

## Risks and mitigations

- **Menu-title drift across Logic versions.** Titles are stable and human-facing (far more so than
  MCU LCD or `AXIdentifier`); the integration smoke runs on every Logic update; MCU still owns
  transport as a fallback. A menu-path miss degrades one tool with a clear structured error, not the
  daemon.
- **Destructive ops on real projects.** Auto-checkpoint + refuse-without-snapshot; `delete_track`
  is the only destructive tool this phase. Testing is net-zero + scratch-project only.
- **`checkpoint` may be unavailable** — the single biggest risk to the safety model; resolved by the
  plan's first task with a `Save A Copy As…` fallback (Open Question 1).
- **Dialog/popup fragility** — captured as fixtures first; opaque cases return structured errors, and
  the direct no-dialog track kinds (`New Audio/Software Instrument Track`) always work as a floor.

## Relationship to the original design (`2026-07-08`) and Phase 2

Phase 2 moved the mixer from MCU to AX because AX was no-focus *and* higher-fidelity. Phase 3 makes
the parallel move for structure: it is menu-driven and no-focus, not keystroke-driven and vision-
verified. The four-layer thesis stands, but two of its four layers (AX-primary mixer, AX-driven
structure) turned out to be one coherent no-focus Accessibility layer, and VisionVerifier keeps
shrinking toward optional diagnostics. FileGateway (audio/MIDI) remains the genuinely distinct layer.

## What Phase 4 looks like (context, not commitment)

Region/timing ops (`quantize_selection`, `enable_flex`) — region selection + inspector/Region-menu
controls — folded together with FileGateway's MIDI round-trip and audio analysis, since they share
the region/timeline model. A thin VisionVerifier (`screenshot`, error-attached captures) can ride
along if diagnostics warrant it.
