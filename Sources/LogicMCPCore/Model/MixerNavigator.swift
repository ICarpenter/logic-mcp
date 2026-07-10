import Foundation

public actor MixerNavigator {
    private let session: MCUSession
    private let model: ProjectModel
    private(set) var bankOffset = 0
    private let settleWindow = Duration.milliseconds(150)
    /// How long to wait for a transient banner / pinned parameter row to give way to track
    /// names before attempting recovery. Real Logic's transient banner lives ~2s; the extra
    /// margin covers redraw latency. Injectable so tests can run fast.
    private let bannerTimeout: Duration

    public init(session: MCUSession, model: ProjectModel,
                bannerTimeout: Duration = .milliseconds(2500)) {
        self.session = session
        self.model = model
        self.bannerTimeout = bannerTimeout
    }

    private func lcdTop() async -> String {
        await session.surface.lcdTop
    }

    /// Drive the two hidden MCU display toggles to the ONE known state every mix tool relies
    /// on: per-channel pan with signed VALUES on the bottom row. Each axis is OBSERVED from
    /// the LCD; a button is pressed only when the observed state differs from the target, and
    /// the surface is re-observed after every press — never press blind, never assume a press
    /// landed. Order matters: axis 1 (`.assignPan`, per-channel vs single-parameter) is fixed
    /// before axis 2 (`.nameValue`, values vs names), because in the single-parameter page
    /// `.nameValue` changes the TOP row instead of the bottom.
    public func normalizeSurface() async throws {
        for _ in 0..<3 {
            let bottom = await session.surface.lcdBottom
            if !SurfaceDisplay.isPerChannelPan(bottom) {
                await session.press(.assignPan)
                await session.settle(settleWindow)
                continue
            }
            if !SurfaceDisplay.isShowingValues(bottom) {
                await session.press(.nameValue)
                await session.settle(settleWindow)
                continue
            }
            return   // per-channel pan, values shown — the known state
        }
        throw ToolFailure(
            error: "could not reach a known mixer display state", layer: "mcu",
            expected: "per-channel pan with signed values on the bottom LCD row",
            observed: "the surface did not settle into per-channel pan + values after three presses")
    }

    private func pressAndSettle(_ button: MCUButton) async -> Bool {
        let before = await lcdTop()
        await session.press(button)
        await session.settle(settleWindow)
        return await lcdTop() != before
    }

    private func bankFullyLeft() async {
        while await pressAndSettle(.bankLeft) {}
        bankOffset = 0
    }

    private func currentBankNames() async -> [String] {
        let surface = await session.surface
        return (0..<8).map { surface.lcdCell(line: 0, channel: $0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func syncFadersFromSurface() async {
        let surface = await session.surface
        for ch in 0..<8 {
            let raw = surface.faderRaw[ch]
            guard raw >= 0 else { continue }
            let index = bankOffset + ch
            await model.updateTrack(index: index) {
                $0.volumeRaw = raw
                $0.volumeDB = FaderCurve.dB(fromRaw: raw)
                $0.volumeIsSilent = FaderCurve.isSilent(raw: raw)
            }
        }
    }

    /// Guarantee the top LCD row is the track-NAME row before anything reads it as names.
    ///
    /// Two hazards leave a parameter/assignment view on that row: a TRANSIENT volume/pan
    /// banner (expires within ~2s — just wait it out), and the PERSISTENT single-parameter
    /// page from an `.assignPan` toggle (the row stays `Track 1 "vox" … Pan/Surround` and
    /// banking does not clear it). Recovery for the persistent case is `normalizeSurface`,
    /// whose `.assignPan` press returns the surface to per-channel pan — which is exactly
    /// what repaints the track names on the top row.
    ///
    /// NOTE: normalizing may also flip Logic's Name/Value setting to values. That side effect
    /// is accepted deliberately — the alternative is `enumerateTracks` silently reading
    /// "Pan/Surround" as a track name — but it is a real change to Logic's surface state.
    public func ensureNameRow() async throws {
        if await showsNames() { return }
        // Transient banner: it reverts to names on its own within the banner's lifetime.
        if await pollForNames(within: bannerTimeout) { return }
        // Persistent single-parameter page: normalize back to per-channel pan (repaints the
        // names), then wait out any transient banner the normalization itself may have raised.
        try await normalizeSurface()
        if await pollForNames(within: bannerTimeout) { return }
        throw ToolFailure(
            error: "mixer LCD is showing a parameter view, not track names", layer: "mcu",
            expected: "track names on the top LCD row",
            observed: "a pinned parameter/assignment view that would not restore names")
    }

    private func showsNames() async -> Bool {
        SurfaceDisplay.isShowingTrackNames(await lcdTop())
    }

    private func pollForNames(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await showsNames() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return await showsNames()
    }

    public func enumerateTracks() async throws -> [String] {
        // A transient banner or a pinned parameter view on the name row would be read as
        // track names; make sure the row shows names first (recovering the pin if needed).
        try await ensureNameRow()
        // Collect every distinct bank window, left to right. Real Logic snaps bankRight
        // UP to the stride-8 grid and CLAMPS the last window to maxOffset, so the terminal
        // window OVERLAPS the previous one — it does not pad with blank cells. Concatenating
        // windows naively would therefore over-count and duplicate the overlap.
        await bankFullyLeft()
        var windows: [[String]] = [await currentBankNames()]
        guard windows[0].contains(where: { !$0.isEmpty }) else {
            throw ToolFailure(error: "mixer LCD is empty", layer: "mcu",
                              expected: "track names on the LCD",
                              observed: "blank display — is Logic running with the control surface installed?")
        }
        while windows.count < 32, await pressAndSettle(.bankRight) {
            windows.append(await currentBankNames())
        }
        let b = windows.count

        let names: [String]
        if b == 1 {
            names = windows[0].filter { !$0.isEmpty }
        } else {
            // b >= 2: recover the terminal window's true width. One bankLeft lands us
            // exactly on the penultimate stride offset 8*(b-2) (guaranteed by bankLeft's
            // snap-to-grid). From there, channelRight steps one strip at a time to the same
            // right edge the terminal bank clamped to; the number of successful steps `d`
            // (1...8) is exactly how many of the terminal window's cells are NEW tracks.
            _ = await pressAndSettle(.bankLeft)
            var d = 0
            while d < 8, await pressAndSettle(.channelRight) { d += 1 }
            let terminalAfterScroll = await currentBankNames()
            let terminal = windows[b - 1]

            if d >= 1 && terminalAfterScroll == terminal {
                // Head: all cells of the first b-1 (full, non-overlapping) windows.
                // Tail: only the LAST d cells of the terminal window — the genuinely new
                // tracks past the overlap. (tail == d falls out of N = 8*(b-1) + d.)
                let head = windows[0..<(b - 1)].flatMap { $0 }
                let tail = terminal.suffix(d)
                names = head + tail
            } else {
                // FALLBACK (pre-fix behavior): CHANNEL± was ignored (d == 0) or the terminal
                // self-check failed. Degrade to concatenating every window's non-blank cells.
                // This over-reports when the terminal bank overlaps, but it is no worse than
                // the status quo before this fix and never crashes — kept for the case where
                // single-channel scroll is unavailable on the surface.
                names = windows.flatMap { $0.filter { !$0.isEmpty } }
            }
        }
        await bankFullyLeft()   // resync bankOffset = 0 before publishing
        await model.replaceTracks(names)
        await syncFadersFromSurface()
        return names
    }

    public func bank(toShow globalIndex: Int) async throws -> Int {
        // bankOffset tracks Logic's REAL leftmost-strip index. The window that shows
        // `globalIndex` is the stride-8 grid offset containing it, clamped to maxOffset
        // (the terminal window is clamped, not stride-aligned).
        let count = await model.snapshot.tracks.count
        let maxOffset = max(0, count - 8)
        let desired = min((globalIndex / 8) * 8, maxOffset)
        while bankOffset < desired {
            guard await pressAndSettle(.bankRight) else {
                throw ToolFailure(error: "cannot bank to track \(globalIndex)", layer: "mcu",
                                  expected: "bank window containing index \(globalIndex)",
                                  observed: "mixer ends at offset \(bankOffset)")
            }
            bankOffset = min(((bankOffset / 8) + 1) * 8, maxOffset)
        }
        while bankOffset > desired {
            guard await pressAndSettle(.bankLeft) else { break }
            bankOffset = max(((bankOffset + 7) / 8 - 1) * 8, 0)
        }
        await syncFadersFromSurface()
        return globalIndex - bankOffset
    }

    public func resolve(_ name: String) async throws -> TrackState {
        if await model.snapshot.staleAt != nil {
            _ = try await enumerateTracks()
        }
        return try await model.track(named: name)
    }
}
