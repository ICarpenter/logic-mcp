# logic-mcp — Agent Control of Logic Pro (Design)

**Date:** 2026-07-08
**Status:** Approved design, pre-implementation
**Working name:** `logic-mcp`

## Goal

A local MCP server that lets a coding agent (Claude Code / Claude Desktop, later a dedicated cockpit UI) control Logic Pro end to end: create and edit tracks, insert FX, manage routing, change parameters, write and edit MIDI, quantize/flex, analyze audio from the project (timing, spectrum), and collaborate with the user as a production/engineering assistant. Extension points ("holes") allow musicianship — music theory, mix recipes, analysis interpretation — to be packaged and iterated independently of the control core.

## Constraints and key decisions

1. **Logic Pro has no scripting API.** No AppleScript dictionary of substance, no Shortcuts actions, no host-control from Audio Units. All control goes through side doors: MIDI control-surface protocols, the macOS Accessibility API, key commands, and the filesystem.
2. **Distribution: notarized Developer ID direct download** (not Mac App Store). The Accessibility API — required for track creation, routing, flex, and structural edits — is banned from sandboxed App Store apps. Direct download is the norm for pro audio (UAD, iZotope, Ableton all ship this way). An App-Store-safe "lite" subset (MIDI + file analysis only) remains possible later because the layers are cleanly separated.
3. **MCP server first.** The control layer ships as a local MCP server so existing Claude clients can drive it immediately; a product/cockpit UI can wrap the same server later. An Audio Unit **cannot** be the controller (AU sandbox is track-scoped); an AU cockpit UI + audio tap is a possible later addition, not v1.
4. **Single Swift daemon, MCP over stdio** (official Swift MCP SDK). Every control path is a native macOS framework: CoreMIDI (MCU bridge), AXUIElement (accessibility), CGEvent (key commands), ScreenCaptureKit (verification), Accelerate/vDSP (DSP). One binary, one notarized artifact, no cross-language IPC.
5. **Reverse-engineered internals are out of scope.** No Logic Remote protocol, no writing `.logicx` binary internals. Reading audio files out of the project bundle is fine (they are plain audio files).

## Architecture

```
Claude (Code / Desktop / future cockpit UI)
        │  MCP (stdio) — typed tools, resources, prompts
        ▼
┌──────────────────── logic-mcp daemon (Swift) ────────────────────┐
│  Tool Registry ──► Shadow Project Model (cached state)           │
│        │                    ▲      ▲                              │
│        ▼                    │      │                              │
│  ┌──────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐  │
│  │ MCUBridge │  │  AXDriver   │  │ FileGateway │  │ Vision     │  │
│  │ virtual   │  │ AX tree +   │  │ bundle audio│  │ Verifier   │  │
│  │ MIDI ⇄MCU │  │ key cmds    │  │ MIDI codec  │  │ screenshots│  │
│  └─────┬────┘  └──────┬──────┘  └──────┬──────┘  └─────┬──────┘  │
└────────┼──────────────┼────────────────┼───────────────┼─────────┘
         ▼              ▼                ▼               ▼
      Logic Pro (control surface, UI, .logicx bundle, window)
```

### Components

**MCUBridge** — emulates a Mackie Control Universal on virtual CoreMIDI ports that Logic auto-detects as a control surface. Bidirectional: fader/encoder/transport commands out; **state feedback in** — LCD text (track names, parameter names/values), fader position echoes, meter data, transport position. Banks through channels to enumerate the mixer; uses the MCU plugin view to page through loaded plugin parameters. This is the precise, version-stable read/write channel for mixing and plugin parameters. Works without window focus.

**AXDriver** — deterministic accessibility-tree walking (never vision-guided): find the track header named "Bass", open an insert slot popup, drive the New Track dialog, invoke menus. Dispatches Logic key commands via CGEvent against a **canonical key-command set** installed into Logic during setup, so mappings are known constants. Requires Logic frontmost.

**FileGateway** — reads audio files from the `.logicx` bundle; orchestrates "Export All Tracks as Audio Files" (via AXDriver) when time-aligned stems are needed; runs onset/spectral/pitch DSP (Accelerate); encodes and decodes standard MIDI files for the composition round-trip (agent supplies JSON note lists; the gateway builds the SMF and drives the import).

**VisionVerifier** — ScreenCaptureKit captures of Logic's window. Used **only** to confirm actions landed and to attach diagnostics to structured errors. Never the primary actuator.

**Shadow Project Model** — cached project state: tracks, channel strips, sends, plugin chains, parameter values, tempo/key/markers. Populated from MCU feedback + AX scans; invalidated by the daemon's own writes; lazily rescanned when stale; exposed as an MCP resource. Claude reasons against this instead of re-scraping per question.

### Setup experience (one-time, guided)

1. Grant Accessibility and Screen Recording permissions in System Settings.
2. Point the daemon at the user's projects folder (file access).
3. Installer adds the control surface in Logic (auto-detected via virtual MIDI ports) and imports the canonical key-command set.
4. MIDI requires no permission at all.

## Tool surface

**Design contract:** every tool returns *verified ground truth*, never assumed success. `set_volume` returns the dB value Logic echoed back over the MCU wire; `create_track` returns the track as re-read from the AX tree. Failures return structured errors (see Error handling).

Representative signatures by group:

- **Query** — `get_project_overview()`, `get_track(name)`, `get_plugin_params(track, slot)`, `refresh_state(scope)`, `screenshot(target)`.
- **Mix** (MCUBridge) — `set_volume(track, db|delta)`, `set_pan(track, position)`, `set_send(track, bus, level)`, `set_mute(track, on)`, `set_solo(track, on)`, `set_plugin_param(track, slot, param, value)`, `set_automation_mode(track, mode)`; transport: `play()`, `stop()`, `record()`, `locate(bar)`, `set_cycle(start, end)`.
- **Structure** (AXDriver) — `create_track(kind, name, instrument?)`, `insert_plugin(track, position, name)`, `set_output(track, dest)`, `create_bus_send(track, bus)`, `select_track(name)`, `select_region(track, index|range)`, `quantize_selection(grid, strength)`, `enable_flex(track, mode)`, `run_key_command(name)` (typed escape hatch into the canonical set), `checkpoint(label)`, `undo_last(n)`.
- **Content** (FileGateway) — `import_midi(notes, track, position)`, `export_midi(region)`, `export_stems(tracks?)`, `analyze_audio(track, analyses)` (named analyses: onsets, spectrum, key, tuning — extensible without changing the tool surface), `compare_timing(track, reference)`.

### Data flow examples

*"Bring the vocal down 2 dB"* → `set_volume("Vocal", delta: -2)` → MCUBridge banks to the Vocal channel, sends the fader move as pitch-bend, Logic echoes the new position, bridge converts to dB, updates the shadow model, returns `{volume: -6.2}`. Sub-second; no pixels, no focus.

*"Is the bass in time with the drums?"* → `compare_timing("Bass", reference: "Drums")` → FileGateway exports both stems time-aligned (AXDriver drives the export dialog), runs onset detection on each, matches bass onsets against drum onsets and the tempo grid → returns a drift report ("bass onsets average 21ms late; worst cluster bars 9–16; 84% within ±10ms elsewhere"). Claude interprets via the analysis-interpretation skill pack and can offer `quantize_selection` or a flex pass.

## Skill packs (the extension points)

The daemon is a dumb, precise actuator; **taste ships as skill packs** — versioned bundles of MCP prompts + resources in a user-extendable directory (markdown + JSON):

- `music-theory` — harmony, voice leading, progression guidance.
- `mix-cookbook` — FX-chain recipes per instrument/genre.
- `analysis-interpretation` — how to read drift/spectral reports and choose fixes.

Users and third parties can add packs (genre templates, new recipes) without touching notarized native code. New DSP analyses are the one extension that requires a daemon update; `analyze_audio`'s named-analysis parameter keeps the tool surface stable as the menu grows.

## Safety model

- **Checkpoints.** `checkpoint(label)` snapshots via Logic's native Project Alternatives (key-command driven). Structure and content tools auto-checkpoint if none exists for the current conversation turn. Destructive ops (delete track, replace region) refuse to run without one. Rollback = revert to alternative.
- **Undo journal.** Every mutation is logged with its prior value from the shadow model. `undo_last(n)` restores mix moves deterministically over MCU; structural ops fall back to Logic's ⌘Z with verification, or checkpoint revert.
- **Focus discipline.** MCU operations run without window focus (mixing works with Logic in the background). AXDriver ops require Logic frontmost; the daemon detects recent user keyboard/mouse activity and queues structural work rather than stealing focus mid-typing.
- **Recording never arms itself.** `record()` requires an explicit user request; the tool description states this so the agent enforces it as well.

## Error handling and version drift

Every operation is **act → verify → report**, with verification native to its layer: MCU echo, AX re-read, vision as last resort. Failures return `{error, layer, expected, observed, screenshot?}` so the agent can retry, reroute (menu path instead of key command), or ask the user. Idempotent ops auto-retry once; non-idempotent ops verify state before any retry.

AX selectors live in a **versioned adapter manifest** keyed to the Logic Pro version. On version mismatch or selector drift the daemon reports *degraded capability* ("structure tools unavailable pending adapter update — mixer control unaffected") rather than failing mysteriously. Graceful degradation is the payoff of the layering: the fragile AX layer degrades; MCU, file, and vision layers keep working.

## Testing

- **Unit:** MCUBridge against golden MIDI transcripts recorded from real Logic sessions; DSP against synthetic audio fixtures with known onsets/pitches.
- **Integration:** a fixture `.logicx` project plus a scripted scenario suite run against real Logic on a Mac (create tracks → verify AX tree; fader round-trips → verify echoes; export stems → checksum; timing analysis → known drift). This suite is the smoke gate for every Logic update.
- **Dogfood:** daily use via Claude Code on real sessions — the reason for MCP-first.

## v1 scope

| In v1 | Deferred |
|---|---|
| MCU mixer + transport + plugin params | Flex Pitch note-level editing |
| `create_track`, `insert_plugin`, select, quantize, routing basics | Automation curve drawing (v1.5: write automation via MCU control moves during playback in Latch mode) |
| MIDI import/export, stem export, onset/timing analysis | Cockpit UI; App Store lite SKU |
| Checkpoints, undo journal, shadow model v0 | Score editor and multi-window AX flows |
| Two skill packs: `mix-cookbook`, `analysis-interpretation` | Third-party skill pack registry; `music-theory` pack |

The four v1 demo slices, each proving one layer: **mix moves via chat** (MCUBridge), **project scaffolding** (AXDriver), **timing/audio analysis** (FileGateway), **MIDI round-trip** (FileGateway + AXDriver).

## Risks and mitigations

- **MCU LCD truncation.** The MCU LCD gives ~7 characters per channel, so track names arrive truncated. Mitigation: reconcile truncated MCU names against full names from AX scans in the shadow model; tools address tracks by full name.
- **AX fragility across Logic updates.** Mitigated by the adapter manifest, degraded-capability reporting, and the integration smoke suite run on every Logic update.
- **MCU emulation is a real protocol project.** The protocol is well documented by the reverse-engineering community and stable for decades, but budget implementation time for the state machine and LCD parsing.
- **Focus-stealing UX.** Structural ops move focus and windows. Mitigated by activity detection + queueing; the cockpit UI (later) can surface a "working…" state.
- **Plugin parameter names via LCD are terse.** Parameter paging returns abbreviated names; the shadow model may need a per-plugin name dictionary built up over time (start with Logic stock plugins).

## Out of scope

- Reverse-engineering the Logic Remote protocol or the `.logicx` binary format (reading bundled audio files is in scope).
- Windows/other DAWs. The tool surface is intentionally DAW-shaped, not Logic-shaped, so a future Ableton/Reaper backend is conceivable, but no abstraction work is spent on it now.
- Embedded agent/billing. v1 assumes the user brings Claude via an MCP client.
