# TestProjects

Canonical **seed** Logic Pro projects for evals and manual smoke testing. Logic can't run
headless in CI, so these give a reproducible baseline any developer (with Logic Pro) can drive
the MCP tools against — and a known state to reset to between runs.

## How to use these

These directories are **read-only seeds** — don't run tests against them in place. Instead:

1. Copy a seed into Logic's projects area, e.g.
   `cp -R TestProjects/mcp_test ~/Music/Logic/mcp_test`
2. Open it in Logic and drive the smoke (`logic-mcp smoke [--structure]`, or the checklist in
   `docs/integration-smoke.md`). Mutate it freely — prefer net-zero, but it's disposable.
3. To reset to a clean baseline, delete the working copy and re-copy from the seed.

## Format notes

- Projects are **folder-organized** (`.musicapps-project-folder` marker + the `.logicx` document
  inside), so git tracks the internal files individually rather than as one opaque macOS package.
- The core `ProjectData` is a **proprietary binary blob** — git can't diff it; you'll only ever
  see "ProjectData changed." That's expected. Treat each project as a binary seed.
- `.gitignore` here strips everything Logic regenerates (autosave, backups, undo data, the
  `WindowImage.jpg` preview) and forbids audio/media binaries, so a seed stays small and
  license-clean. **Keep seed projects lightweight — no audio, no bounces.**

## Projects

### `mcp_test/`
The standard mixer/structural test project used throughout Phase 1–4 development: 21 named tracks
(vox, guitar, bass, synth, drums, pedal steel, …), a handful of buses/auxes, and **stock plugins
only** (Channel EQ, Retro Synth) so it opens the same on any Logic install. It is the project the
AX smoke and `docs/integration-smoke.md` are written against.

Note: the mixer must have **more strips than fit on screen**, which is deliberate — it's what
exercises the off-screen-strip AX degradation the code handles. Open the **Mixer window** (⌘2)
before running AX tools.

## Adding a project

Save it folder-organized, remove any audio/bounces, `cp -R` it here, and commit only after a clean
save (so no autosave/backup churn sneaks in — the `.gitignore` is the backstop).
