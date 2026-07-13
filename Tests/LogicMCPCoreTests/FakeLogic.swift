import Foundation
@testable import LogicMCPCore

actor FakeLogic {
    struct FakeTrack {
        var name: String
        var volumeRaw: Int = 12443   // Logic's real 0.0 dB unity under the measured FaderCurve
        var pan: Int = 64
        var mute = false
        var solo = false
        var recArm = false
        var automationMode = "read"
        var sends: [(bus: String, level: Int)] = []
        var plugins: [FakePlugin] = []
    }
    struct FakePlugin {
        var name: String
        var params: [(name: String, value: Double)]
    }

    private enum Assignment { case pan, send, pluginSelect, pluginEdit(slot: Int, page: Int) }

    private let wire: InMemoryWire
    private(set) var tracks: [FakeTrack]
    private(set) var bankOffset = 0
    private(set) var isPlaying = false
    private(set) var isRecording = false
    private(set) var cycling = false
    private var selected = 0
    private var assignment: Assignment = .pan
    private var touched = Set<Int>()
    private var emitChain: Task<Void, Never>?
    /// When true, CHANNEL± is a no-op for mixer scrolling (models a Logic/surface
    /// where single-channel scroll is unavailable). Plugin-edit paging is unaffected.
    private let ignoreChannelScroll: Bool

    // MARK: - LCD display modelling (matches real Logic, per `logic-mcp lcdprobe`)

    /// How long the transient "Volume / -9.0 dB" banner lives before the name/pan rows are
    /// repainted. Default is short so tests are fast; `.zero` models a MISSED banner (none
    /// painted at all), which forces `set_volume` down its curve fallback.
    private let bannerLifetime: Duration
    // MARK: Two hidden MCU display TOGGLES (measured on real Logic via `lcdprobe`).
    /// AXIS 1 — `.assignPan` (0x2A) toggles between per-channel pan and the SINGLE-PARAMETER
    /// page. In the single-parameter page the top row is pinned to a parameter header
    /// ("Track 1 \"vox\" … Pan/Surround"), only V-Pot 0 is live, and every other V-Pot emits
    /// NO ring echo.
    private var singleParameterPage: Bool
    /// AXIS 2 — `.nameValue` (0x34) toggles the per-channel pan bottom row between signed
    /// VALUES ("0", "-30", "+63") and parameter NAMES ("Pan"). In the single-parameter page
    /// it changes the TOP row instead, so it cannot reach values from there.
    private var showingPanValues: Bool
    /// When true, `.assignPan` can NEVER leave the single-parameter page (a stuck surface) —
    /// used to prove `normalizeSurface`/`ensureNameRow` THROW rather than reading a pinned
    /// parameter view as track names.
    private let panStuck: Bool
    /// Counts every button PRESS the daemon sends. Lets tests assert a normalizer presses
    /// nothing when the surface is already in its known state.
    private(set) var pressCount = 0
    /// Optional model of Logic snapping pan: maps the commanded SIGNED pan (-64…63) to the
    /// value actually painted on the LCD. Applied only for display, so the tool's read can
    /// diverge from what it requested. Default identity.
    private let panSnap: (@Sendable (Int) -> Int)?
    private var bannerTask: Task<Void, Never>?

    var state: [FakeTrack] { tracks }

    /// Real Logic coalesces a fast burst of V-Pot deltas before refreshing the LED ring, so a
    /// sweep that returns to where it started (e.g. -47 → -64 → -47) emits NO ring echo at all.
    /// Set this to model that: the pan still moves, Logic just never echoes a ring.
    private let ringEchoes: Bool

    init(wire: InMemoryWire, tracks: [FakeTrack], ignoreChannelScroll: Bool = false,
         bannerLifetime: Duration = .milliseconds(200),
         singleParameterPage: Bool = false, showingPanValues: Bool = true,
         panStuck: Bool = false,
         ringEchoes: Bool = true,
         panSnap: (@Sendable (Int) -> Int)? = nil) {
        self.wire = wire
        self.tracks = tracks
        self.ignoreChannelScroll = ignoreChannelScroll
        self.bannerLifetime = bannerLifetime
        self.singleParameterPage = singleParameterPage
        self.showingPanValues = showingPanValues
        self.panStuck = panStuck
        self.ringEchoes = ringEchoes
        self.panSnap = panSnap
    }

    static func standardSession() -> [FakeTrack] {
        let names = ["Kick", "Snare", "HiHat", "Toms", "OH", "Room", "Bass", "Guitar L",
                     "Guitar R", "Keys", "Vocal", "Vocal Dbl", "BGV", "FX Ret", "Drum Bus", "Mix Bus"]
        return names.map { name in
            var t = FakeTrack(name: name)
            t.sends = [("Bus 1", 0), ("Bus 2", 0)]
            t.plugins = [FakePlugin(name: "ChanEQ", params: [
                ("LowFrq", 0.2), ("LowGain", 0.5), ("MidFrq", 0.5), ("MidGain", 0.5),
                ("MidQ", 0.4), ("HiFrq", 0.7), ("HiGain", 0.5), ("Out", 0.8),
                ("HPFrq", 0.1), ("HPOn", 0.0),
            ])]
            return t
        }
    }

    func start() {
        let stream = wire.packets()
        Task { [weak self] in
            for await packet in stream {
                guard let self else { break }
                if let command = MCUCodec.decodeCommand(packet) {
                    await self.handle(command)
                }
            }
        }
        emit(.deviceQuery)
    }

    /// Emits are chained so events reach the daemon in the order Logic would send them.
    private func emit(_ event: MCUEvent) {
        let bytes = MCUCodec.encode(event)
        let previous = emitChain
        emitChain = Task { [wire] in
            await previous?.value
            await wire.send(bytes)
        }
    }

    private func handle(_ command: MCUCommand) {
        switch command {
        case .hostConnectionQuery(let serial, _):
            emit(.hostConnectionReply(serial: serial))
            sendBankLCD()
            emit(.led(button: .play, state: isPlaying ? .on : .off))
        case .connectionConfirmation:
            break
        case .faderTouch(let ch, let isTouched):
            if isTouched { touched.insert(ch) } else { touched.remove(ch) }
        case .faderMove(let ch, let value):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].volumeRaw = value
            emit(.faderEcho(channel: ch, value: value))
            paintVolumeBanner(channel: ch, raw: value)
        case .buttonPress(let button):
            pressCount += 1
            handlePress(button)
        case .buttonRelease:
            break
        case .vpotTurn(let ch, let ticks):
            handleVPot(channel: ch, ticks: ticks)
        }
    }

    private func handlePress(_ button: MCUButton) {
        switch button {
        case .mute(let ch):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].mute.toggle()
            emit(.led(button: .mute(channel: ch), state: tracks[index].mute ? .on : .off))
        case .solo(let ch):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].solo.toggle()
            emit(.led(button: .solo(channel: ch), state: tracks[index].solo ? .on : .off))
        case .recArm(let ch):
            let index = bankOffset + ch
            guard index < tracks.count else { return }
            tracks[index].recArm.toggle()
            emit(.led(button: .recArm(channel: ch), state: tracks[index].recArm ? .on : .off))
        case .select(let ch):
            let previous = selected - bankOffset
            if (0..<8).contains(previous) {
                emit(.led(button: .select(channel: previous), state: .off))
            }
            selected = bankOffset + ch
            emit(.led(button: .select(channel: ch), state: .on))
        case .bankRight:
            // Real Logic: snap UP to the stride-8 grid, then clamp at the right edge.
            // The LAST bank window is clamped to maxOffset (overlaps the previous one),
            // it is NOT stride-aligned-with-blank-padding.
            let maxOffset = max(0, tracks.count - 8)
            let next = min(((bankOffset / 8) + 1) * 8, maxOffset)
            if next != bankOffset { bankOffset = next; sendBankLCD() }
        case .bankLeft:
            // Real Logic: snap BACK to the stride-8 grid (integer division), then clamp at 0.
            // From a clamped offset like 12 this goes to 8, NOT 4.
            let next = max(((bankOffset + 7) / 8 - 1) * 8, 0)
            if next != bankOffset { bankOffset = next; sendBankLCD() }
        case .play:
            isPlaying = true
            emit(.led(button: .play, state: .on))
            emit(.led(button: .stop, state: .off))
        case .stop:
            isPlaying = false
            isRecording = false
            emit(.led(button: .stop, state: .on))
            emit(.led(button: .play, state: .off))
            emit(.led(button: .record, state: .off))
        case .record:
            isRecording = true
            if !isPlaying { isPlaying = true; emit(.led(button: .play, state: .on)) }
            emit(.led(button: .record, state: .on))
        case .cycle:
            cycling.toggle()
            emit(.led(button: .cycle, state: cycling ? .on : .off))
        case .assignPan:
            assignment = .pan
            // AXIS 1 toggle: per-channel pan ⇄ single-parameter page. A stuck surface can
            // never leave the single-parameter page.
            singleParameterPage = panStuck ? true : !singleParameterPage
            repaintRows()
        case .nameValue:
            // AXIS 2 toggle. In per-channel pan it flips the BOTTOM row (values ⇄ names). In
            // the single-parameter page it changes the TOP row instead and does NOT reach
            // values — a normalizer that presses it there makes no progress, which is exactly
            // why axis 1 must be fixed first.
            if singleParameterPage {
                emit(.lcd(offset: 0, text: singleParamTop()))   // top changes; still not names
            } else {
                showingPanValues.toggle()
                sendPanLCD()
            }
        case .assignSend:
            assignment = .send
            sendSendLCD()
        case .assignPlugin:
            assignment = .pluginSelect
            sendPluginSelectLCD()
        case .vpotPress(let ch):
            if case .pluginSelect = assignment, ch < tracks[selected].plugins.count {
                assignment = .pluginEdit(slot: ch, page: 0)
                sendPluginEditLCD()
            }
        case .channelRight:
            if case .pluginEdit(let slot, let page) = assignment {
                // Plugin-edit mode: CHANNEL± pages plugin parameters.
                let paramCount = tracks[selected].plugins[slot].params.count
                if (page + 1) * 8 < paramCount {
                    assignment = .pluginEdit(slot: slot, page: page + 1)
                    sendPluginEditLCD()
                }
            } else if !ignoreChannelScroll {
                // Mixer mode: single-channel scroll, clamped at the same right edge as bank.
                let maxOffset = max(0, tracks.count - 8)
                let next = min(bankOffset + 1, maxOffset)
                if next != bankOffset { bankOffset = next; sendBankLCD() }
            }
        case .channelLeft:
            if case .pluginEdit(let slot, let page) = assignment {
                // Plugin-edit mode: CHANNEL± pages plugin parameters (page 0 is a no-op).
                if page > 0 {
                    assignment = .pluginEdit(slot: slot, page: page - 1)
                    sendPluginEditLCD()
                }
            } else if !ignoreChannelScroll {
                // Mixer mode: single-channel scroll, clamped at 0.
                let next = max(bankOffset - 1, 0)
                if next != bankOffset { bankOffset = next; sendBankLCD() }
            }
        case .automationRead, .automationWrite, .automationTouch, .automationLatch:
            let mode: String = switch button {
            case .automationWrite: "write"
            case .automationTouch: "touch"
            case .automationLatch: "latch"
            default: "read"
            }
            tracks[selected].automationMode = mode
            for b: MCUButton in [.automationRead, .automationWrite, .automationTouch, .automationLatch] {
                emit(.led(button: b, state: b == button ? .on : .off))
            }
        default:
            break
        }
    }

    private func handleVPot(channel: Int, ticks: Int) {
        switch assignment {
        case .pan:
            // In the single-parameter page only V-Pot 0 is live; every other V-Pot emits
            // NO ring echo and moves nothing (measured on real Logic).
            if singleParameterPage && channel != 0 { return }
            let index = bankOffset + channel
            guard index < tracks.count else { return }
            tracks[index].pan = max(0, min(127, tracks[index].pan + ticks))
            if ringEchoes { emit(.vpotRing(channel: channel, value: 1 + tracks[index].pan / 12)) }
            sendPanLCD()   // Logic prints the (possibly snapped) pan on the bottom row
        case .send:
            guard channel < tracks[selected].sends.count else { return }
            let level = max(0, min(127, tracks[selected].sends[channel].level + ticks))
            tracks[selected].sends[channel].level = level
            sendSendLCD()
        case .pluginEdit(let slot, let page):
            let paramIndex = page * 8 + channel
            guard paramIndex < tracks[selected].plugins[slot].params.count else { return }
            var value = tracks[selected].plugins[slot].params[paramIndex].value
            value = max(0, min(1, value + Double(ticks) * 0.05))
            tracks[selected].plugins[slot].params[paramIndex].value = value
            sendPluginEditLCD()
        case .pluginSelect:
            break
        }
    }

    private func cell(_ text: String) -> String {
        String(text.prefix(7)).padding(toLength: 7, withPad: " ", startingAt: 0)
    }

    private func sendBankLCD() {
        // Emit fader positions FIRST, then the LCD rows. Tests synchronize on the LCD event,
        // so echoes-before-LCD guarantees the handshake's resting echoes are already consumed
        // by the time a following moveFader opens its own event stream — otherwise it could
        // latch a stale resting-position echo instead of the fresh move it just sent.
        for ch in 0..<8 {
            let index = bankOffset + ch
            if index < tracks.count {
                emit(.faderEcho(channel: ch, value: tracks[index].volumeRaw))
            }
        }
        repaintRows()
    }

    /// Repaint the top row (track names, or the pinned parameter header when in the single-
    /// parameter page) and the pan bottom row, WITHOUT re-emitting fader positions — used by
    /// the banner revert, which must not look like a fader move.
    private func repaintRows() {
        if singleParameterPage {
            emit(.lcd(offset: 0, text: singleParamTop()))
        } else {
            var top = ""
            for ch in 0..<8 {
                let index = bankOffset + ch
                top += index < tracks.count ? cell(tracks[index].name) : "       "
            }
            emit(.lcd(offset: 0, text: top))
        }
        sendPanLCD()
    }

    /// Bottom row. Per-channel pan paints one live cell per strip — signed VALUES ("0",
    /// "-30", "+63") or the "Pan" NAME per axis 2, and "-" where a strip has no pan. The
    /// single-parameter page paints ONE live cell (V-Pot 0) and "-" for the other seven.
    private func sendPanLCD() {
        var bottom = ""
        if singleParameterPage {
            let index = bankOffset
            let head = index < tracks.count
                ? (showingPanValues ? panText(tracks[index].pan) : "Pan") : "-"
            bottom += cell(head)
            for _ in 1..<8 { bottom += cell("-") }
        } else {
            for ch in 0..<8 {
                let index = bankOffset + ch
                bottom += index < tracks.count
                    ? cell(showingPanValues ? panText(tracks[index].pan) : "Pan") : cell("-")
            }
        }
        emit(.lcd(offset: 56, text: bottom))
    }

    private func panText(_ storedPan: Int) -> String {
        let signed = storedPan - 64
        let displayed = panSnap?(signed) ?? signed
        return displayed > 0 ? "+\(displayed)" : "\(displayed)"
    }

    /// Paint the transient "Volume / <dB>" banner in the touched channel's 2-cell field
    /// (`min(channel, 6)`), then schedule the name/pan rows to return after `bannerLifetime`.
    /// The dB text is derived from `FaderCurve` so the fixture stays self-consistent.
    private func paintVolumeBanner(channel ch: Int, raw: Int) {
        guard bannerLifetime > .zero else { return }   // .zero => missed banner (curve fallback)
        let pair = min(ch, 6)
        let dbText = FaderCurve.dB(fromRaw: raw).map { String(format: "%.1f dB", $0) } ?? "-oo dB"
        emit(.lcd(offset: pair * 7, text: "Volume".padding(toLength: 14, withPad: " ", startingAt: 0)))
        emit(.lcd(offset: 56 + pair * 7, text: dbText.padding(toLength: 14, withPad: " ", startingAt: 0)))
        bannerTask?.cancel()
        let lifetime = bannerLifetime
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            await self?.revertBanner()
        }
    }

    private func revertBanner() {
        repaintRows()   // names (unless pinned) + pan; no fader echoes
    }

    /// The single-parameter page pins this parameter header on the TOP row. `isShowingTrackNames`
    /// must reject it (the "Pan/Surround" marker), so enumeration never reads it as track names.
    private func singleParamTop() -> String {
        var s = "Track 1 \"vox\"".padding(toLength: 44, withPad: " ", startingAt: 0)
        s += "Pan/Surround"   // 44 + 12 = 56
        return s
    }

    private func sendSendLCD() {
        var top = "", bottom = ""
        for ch in 0..<8 {
            if ch < tracks[selected].sends.count {
                let send = tracks[selected].sends[ch]
                top += cell(send.bus)
                bottom += cell(String(send.level))
            } else {
                top += "       "; bottom += "       "
            }
        }
        emit(.lcd(offset: 0, text: top))
        emit(.lcd(offset: 56, text: bottom))
    }

    private func sendPluginSelectLCD() {
        var top = ""
        for ch in 0..<8 {
            top += ch < tracks[selected].plugins.count ? cell(tracks[selected].plugins[ch].name) : "       "
        }
        emit(.lcd(offset: 0, text: top))
    }

    private func sendPluginEditLCD() {
        guard case .pluginEdit(let slot, let page) = assignment else { return }
        let params = tracks[selected].plugins[slot].params
        var top = "", bottom = ""
        for ch in 0..<8 {
            let index = page * 8 + ch
            if index < params.count {
                top += cell(params[index].name)
                bottom += cell(String(format: "%.2f", params[index].value))
            } else {
                top += "       "; bottom += "       "
            }
        }
        emit(.lcd(offset: 0, text: top))
        emit(.lcd(offset: 56, text: bottom))
    }
}
