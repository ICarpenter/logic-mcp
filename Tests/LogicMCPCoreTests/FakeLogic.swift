import Foundation
@testable import LogicMCPCore

actor FakeLogic {
    struct FakeTrack {
        var name: String
        var volumeRaw: Int = 12288
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

    var state: [FakeTrack] { tracks }

    init(wire: InMemoryWire, tracks: [FakeTrack]) {
        self.wire = wire
        self.tracks = tracks
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
        case .buttonPress(let button):
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
            let lastBankStart = max(0, ((tracks.count - 1) / 8) * 8)
            let next = min(bankOffset + 8, lastBankStart)
            if next != bankOffset { bankOffset = next; sendBankLCD() }
        case .bankLeft:
            let next = max(0, bankOffset - 8)
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
            sendBankLCD()
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
                let paramCount = tracks[selected].plugins[slot].params.count
                if (page + 1) * 8 < paramCount {
                    assignment = .pluginEdit(slot: slot, page: page + 1)
                    sendPluginEditLCD()
                }
            }
        case .channelLeft:
            if case .pluginEdit(let slot, let page) = assignment, page > 0 {
                assignment = .pluginEdit(slot: slot, page: page - 1)
                sendPluginEditLCD()
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
            let index = bankOffset + channel
            guard index < tracks.count else { return }
            tracks[index].pan = max(0, min(127, tracks[index].pan + ticks))
            emit(.vpotRing(channel: channel, value: 1 + tracks[index].pan / 12))
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
        var top = ""
        for ch in 0..<8 {
            let index = bankOffset + ch
            top += index < tracks.count ? cell(tracks[index].name) : "       "
        }
        emit(.lcd(offset: 0, text: top))
        for ch in 0..<8 {
            let index = bankOffset + ch
            if index < tracks.count {
                emit(.faderEcho(channel: ch, value: tracks[index].volumeRaw))
            }
        }
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
